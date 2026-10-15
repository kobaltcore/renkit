use super::config::{
    ConvertImagesOptions, GeneralTaskOptions, ImageFormat, KeystoreOptions, LintOptions,
    NotarizeOptions,
};
use crate::{
    common::canonicalize_normalized, renotize::full_run, renutil::launch, version::Version,
};
use anyhow::{Result, anyhow, bail};
use base64::prelude::*;
use command_executor::{
    command::Command, shutdown_mode::ShutdownMode, thread_pool_builder::ThreadPoolBuilder,
};
use imgref::ImgRef;
use indicatif::{ProgressBar, ProgressStyle};
// use jpegxl_rs::encode::{EncoderFrame, EncoderResult, EncoderSpeed};
// use jpegxl_rs::encoder_builder;
use image::ImageReader;
use jwalk::WalkDir;
use ravif::Encoder;
use rgb::FromSlice;
use serde_json::Value;
use std::{
    collections::HashMap,
    env, fs,
    io::Read,
    path::{Path, PathBuf},
    str::FromStr,
    thread,
};

#[derive(Debug)]
pub struct Task {
    pub name: String,
    pub kind: GeneralTaskOptions,
}

#[derive(Debug, Clone)]
pub struct TaskContext {
    pub version: Version,
    pub input_dir: PathBuf,
    pub output_dir: PathBuf,
    pub renpy_path: PathBuf,
    pub registry: PathBuf,
    pub on_builds: HashMap<String, Option<String>>,
}

pub struct ProcessingCommand {
    pub image_format: ImageFormat,
    pub path: PathBuf,
    pub lossless: bool,
    pub webp_quality: f32,
    pub avif_quality: f32,
}

impl ProcessingCommand {
    fn new(
        image_format: ImageFormat,
        path: PathBuf,
        lossless: bool,
        webp_quality: f32,
        avif_quality: f32,
    ) -> ProcessingCommand {
        ProcessingCommand {
            image_format,
            path,
            lossless,
            webp_quality,
            avif_quality,
        }
    }
}

fn encode_avif(path: &PathBuf, quality: f32) -> Result<()> {
    let image = ImageReader::open(path)?.decode()?.to_rgba8();
    let image = ImgRef::new(
        image.as_rgba(),
        image.width() as usize,
        image.height() as usize,
    );

    // Test results from my own experiments (running DSSIM comparisons against the original PNGs):
    // Q92: min: 0.00019111 max: 0.00081404 avg: 0.000361435797101449
    // Q90: min: 0.00024517 max: 0.00109436 avg: 0.000517433478260870
    // Q85: min: 0.00048456 max: 0.00254822 avg: 0.001188083995859214
    // Q80: min: 0.00055154 max: 0.00298501 avg: 0.001368737412008282
    // Q50: min: 0.00142641 max: 0.01011350 avg: 0.003927716728778467
    // result: quality cutoff at about 0.001, so Q85 is a good default

    let avif_enc = Encoder::new()
        .with_quality(quality)
        .with_speed(3)
        .with_num_threads(Some(2));
    let img = avif_enc.encode_rgba(image)?;

    fs::write(path, &img.avif_file)?;

    Ok(())
}

fn encode_webp(path: &PathBuf, quality: f32, lossless: bool) -> Result<()> {
    let image = ImageReader::open(path)?.decode()?.to_rgba8();

    // Preserve the existing libwebp settings; the remaining defaults match.
    let config = webpx::EncoderConfig::new()
        .lossless(lossless)
        .quality(if lossless { 100.0 } else { quality })
        .method(6)
        .sns_strength(50)
        .filter_strength(60)
        .filter_sharpness(0)
        .preprocessing(if lossless { 0 } else { 4 })
        .sharp_yuv(!lossless);
    let result = config
        .encode_rgba(&image, image.width(), image.height(), webpx::Unstoppable)
        .map_err(|err| anyhow!("Error encoding WebP image: {err}"))?;

    fs::write(path, result)?;

    Ok(())
}

#[cfg(test)]
mod webp_tests {
    use super::*;
    use image::{Rgba, RgbaImage};

    fn fixture() -> RgbaImage {
        RgbaImage::from_fn(48, 32, |x, y| {
            Rgba([
                (x * 5) as u8,
                (y * 7) as u8,
                ((x * 13 + y * 17) % 256) as u8,
                [0, 64, 128, 255][(x % 4) as usize],
            ])
        })
    }

    #[test]
    fn lossless_webp_preserves_visible_pixels_and_alpha() -> Result<()> {
        let directory = tempfile::tempdir()?;
        let path = directory.path().join("image.png");
        let original = fixture();
        original.save(&path)?;

        encode_webp(&path, 90.0, true)?;
        let decoded = image::load_from_memory(&fs::read(&path)?)?.to_rgba8();

        assert_eq!(decoded.dimensions(), original.dimensions());
        for (before, after) in original.pixels().zip(decoded.pixels()) {
            assert_eq!(before[3], after[3]);
            // The existing exact=false setting allows hidden RGB to change.
            if before[3] != 0 {
                assert_eq!(before, after);
            }
        }
        Ok(())
    }

    #[test]
    fn lossy_webp_preserves_alpha_and_applies_quality() -> Result<()> {
        let directory = tempfile::tempdir()?;
        let path = directory.path().join("image.png");
        let original = fixture();
        let mut outputs = Vec::new();

        for quality in [10.0, 90.0] {
            original.save(&path)?;
            encode_webp(&path, quality, false)?;
            let encoded = fs::read(&path)?;
            let decoded = image::load_from_memory(&encoded)?.to_rgba8();

            assert_eq!(decoded.dimensions(), original.dimensions());
            for (before, after) in original.pixels().zip(decoded.pixels()) {
                assert_eq!(before[3], after[3]);
            }
            assert!(
                original
                    .pixels()
                    .zip(decoded.pixels())
                    .any(|(before, after)| { before[3] != 0 && before.0[..3] != after.0[..3] })
            );
            outputs.push(encoded);
        }

        assert_ne!(outputs[0], outputs[1]);
        Ok(())
    }
}

impl Command for ProcessingCommand {
    fn execute(&self) -> Result<()> {
        match self.image_format {
            // ImageFormat::JpegXl => {
            //     let image = ImageReader::open(&self.path)?.decode()?.to_rgba8();
            //     // let mut encoder = match self.lossless {
            //     //     true => encoder_builder()
            //     //         .has_alpha(true)
            //     //         .quality(0.5)
            //     //         .speed(EncoderSpeed::Kitten)
            //     //         .build()?,
            //     //     false => encoder_builder()
            //     //         .has_alpha(true)
            //     //         .quality(1.0)
            //     //         .speed(EncoderSpeed::Kitten)
            //     //         .build()?,
            //     // };
            //     let mut encoder = encoder_builder()
            //         .has_alpha(true)
            //         .quality(1.0)
            //         .speed(EncoderSpeed::Kitten)
            //         .build()?;
            //     let buffer: EncoderResult<f32> = encoder.encode_frame(
            //         &EncoderFrame::new(image.as_raw()).num_channels(4),
            //         image.width(),
            //         image.height(),
            //     )?;
            //     fs::write(&self.path, &buffer.data)?;
            // }
            ImageFormat::HybridWebPAvif => {
                if self.lossless {
                    encode_webp(&self.path, self.webp_quality, true)?;
                } else {
                    encode_avif(&self.path, self.avif_quality)?;
                }
            }
            ImageFormat::Avif => {
                if self.lossless {
                    bail!("Lossless AVIF is not supported.");
                }
                encode_avif(&self.path, self.avif_quality)?;
            }
            ImageFormat::WebP => encode_webp(&self.path, self.webp_quality, self.lossless)?,
        }

        Ok(())
    }
}

pub async fn task_lint_pre(ctx: &TaskContext, _options: &LintOptions) -> Result<()> {
    let (status, _stdout, _stderr) = launch(
        &ctx.registry,
        Some(&ctx.version),
        true,
        true,
        &[ctx.input_dir.to_string_lossy().to_string(), "lint".into()],
        false,
        false,
    )
    .await?;

    if !status.success() {
        bail!("Lint failed with status code: {}", status);
    }

    Ok(())
}

pub fn task_keystore_pre(ctx: &TaskContext, options: &KeystoreOptions) -> Result<()> {
    let android_path;
    let android_path_backup;
    let bundle_path;
    let bundle_path_backup;

    let local_properties_path = ctx.renpy_path.join("rapt/project/local.properties");
    let local_properties_path_backup = ctx
        .renpy_path
        .join("rapt/project/local.properties.original");
    let bundle_properties_path = ctx.renpy_path.join("rapt/project/bundle.properties");
    let bundle_properties_path_backup = ctx
        .renpy_path
        .join("rapt/project/bundle.properties.original");

    if ctx.version < Version::from_str("7.6.0").unwrap()
        && ctx.version < Version::from_str("8.1.0").unwrap()
    {
        android_path = ctx.renpy_path.join("rapt/android.keystore");
        android_path_backup = ctx.renpy_path.join("rapt/android.keystore.original");
        bundle_path = ctx.renpy_path.join("rapt/bundle.keystore");
        bundle_path_backup = ctx.renpy_path.join("rapt/bundle.keystore.original");
    } else {
        android_path = ctx.input_dir.join("android.keystore");
        android_path_backup = ctx.input_dir.join("android.keystore.original");
        bundle_path = ctx.input_dir.join("bundle.keystore");
        bundle_path_backup = ctx.input_dir.join("bundle.keystore.original");
    }

    if android_path.exists() && !android_path_backup.exists() {
        fs::copy(&android_path, &android_path_backup)?;
    }

    if bundle_path.exists() && !bundle_path_backup.exists() {
        fs::copy(&bundle_path, &bundle_path_backup)?;
    }

    if local_properties_path.exists() && !local_properties_path_backup.exists() {
        fs::copy(&local_properties_path, &local_properties_path_backup)?;
    }

    if bundle_properties_path.exists() && !bundle_properties_path_backup.exists() {
        fs::copy(&bundle_properties_path, &bundle_properties_path_backup)?;
    }

    let android_keystore = match env::var("RC_KEYSTORE_APK") {
        Ok(val) => BASE64_STANDARD.decode(val)?,
        Err(_) => BASE64_STANDARD.decode(options.keystore_apk.clone())?,
    };
    fs::write(&android_path, android_keystore)?;

    let bundle_keystore = match env::var("RC_KEYSTORE_AAB") {
        Ok(val) => BASE64_STANDARD.decode(val)?,
        Err(_) => BASE64_STANDARD.decode(options.keystore_aab.clone())?,
    };
    fs::write(&bundle_path, bundle_keystore)?;

    // We need to disable the update_keystores option in android.json
    // otherwise Ren'Py will overwrite our changes to the property files.

    // find android file
    let mut found_android_json = false;
    for path in [
        // newly-introduced naming convention in 8.1
        ctx.input_dir.join("android.json"),
        // filename before 8.1
        ctx.input_dir.join(".android.json"),
    ] {
        if path.exists() {
            found_android_json = true;
            let mut config: HashMap<String, Value> =
                serde_json::from_str(&fs::read_to_string(&path)?)?;
            config.insert("update_keystores".to_string(), Value::Bool(false));
            fs::write(&path, serde_json::to_string(&config)?)?;
            break;
        }
    }

    // if neither file exists, create one
    if !found_android_json {
        let path = ctx.input_dir.join("android.json");
        let mut config = HashMap::new();
        config.insert("update_keystores".to_string(), Value::Bool(false));
        fs::write(&path, serde_json::to_string_pretty(&config)?)?;
    }

    // set alias and password in rapt/project/local.properties and rapt/project/bundle.properties
    // both files should have the same content except for the key.store property
    // Example contents from default Ren'Py project:
    // key.alias=android
    // key.store.password=android
    // key.alias.password=android
    // key.store=/Applications/renpy-sdk/rapt/android.keystore
    // sdk.dir=/Applications/renpy-sdk/rapt/Sdk

    let password = match env::var("RC_KEYSTORE_PASSWORD") {
        Ok(val) => val,
        Err(_) => options.password.clone().unwrap_or("android".to_string()),
    };

    let property_contents = format!(
        "key.alias={}\nkey.store.password={}\nkey.alias.password={}\nkey.store={}\nsdk.dir={}",
        options.alias.clone().unwrap_or("android".to_string()),
        password,
        password,
        canonicalize_normalized(android_path)?
            .to_string_lossy()
            .replace('\\', "/"),
        ctx.renpy_path.to_string_lossy()
    );
    fs::write(&local_properties_path, &property_contents)?;
    fs::write(
        &bundle_properties_path,
        property_contents.replace("android.keystore", "bundle.keystore"),
    )?;

    Ok(())
}

pub fn task_keystore_post(ctx: &TaskContext, _options: &KeystoreOptions) -> Result<()> {
    let android_path;
    let android_path_backup;
    let bundle_path;
    let bundle_path_backup;

    let local_properties_path = ctx.renpy_path.join("rapt/project/local.properties");
    let local_properties_path_backup = ctx
        .renpy_path
        .join("rapt/project/local.properties.original");
    let bundle_properties_path = ctx.renpy_path.join("rapt/project/bundle.properties");
    let bundle_properties_path_backup = ctx
        .renpy_path
        .join("rapt/project/bundle.properties.original");

    if ctx.version < Version::from_str("7.6.0").unwrap()
        && ctx.version < Version::from_str("8.1.0").unwrap()
    {
        android_path = ctx.renpy_path.join("rapt/android.keystore");
        android_path_backup = ctx.renpy_path.join("rapt/android.keystore.original");
        bundle_path = ctx.renpy_path.join("rapt/bundle.keystore");
        bundle_path_backup = ctx.renpy_path.join("rapt/bundle.keystore.original");
    } else {
        android_path = ctx.input_dir.join("android.keystore");
        android_path_backup = ctx.input_dir.join("android.keystore.original");
        bundle_path = ctx.input_dir.join("bundle.keystore");
        bundle_path_backup = ctx.input_dir.join("bundle.keystore.original");
    }

    if android_path_backup.exists() {
        fs::copy(&android_path_backup, &android_path)?;
        fs::remove_file(&android_path_backup)?;
    } else {
        fs::remove_file(&android_path)?;
    }

    if bundle_path_backup.exists() {
        fs::copy(&bundle_path_backup, &bundle_path)?;
        fs::remove_file(&bundle_path_backup)?;
    } else {
        fs::remove_file(&bundle_path)?;
    }

    if local_properties_path_backup.exists() {
        fs::copy(&local_properties_path_backup, &local_properties_path)?;
        fs::remove_file(&local_properties_path_backup)?;
    } else {
        fs::remove_file(&local_properties_path)?;
    }

    if bundle_properties_path_backup.exists() {
        fs::copy(&bundle_properties_path_backup, &bundle_properties_path)?;
        fs::remove_file(&bundle_properties_path_backup)?;
    } else {
        fs::remove_file(&bundle_properties_path)?;
    }

    Ok(())
}

pub fn task_convert_images_pre(ctx: &TaskContext, options: &ConvertImagesOptions) -> Result<()> {
    let mut files = vec![];

    for (path, opts) in &options.paths {
        let path = ctx.input_dir.join(path);
        if !path.exists() {
            println!("Path does not exist: {}", path.display());
            continue;
        }

        for entry in if opts.recursive {
            WalkDir::new(path)
        } else {
            WalkDir::new(path).max_depth(1)
        } {
            match entry {
                Ok(entry) => {
                    if entry.path().is_dir() {
                        continue;
                    }
                    if let Some(ext) = entry.path().extension() {
                        if !opts.extensions.contains(&ext.to_string_lossy().to_string()) {
                            continue;
                        }
                        // read first 16 bytes
                        let mut buf = [0; 12];
                        let mut file = fs::File::open(entry.path())?;
                        file.read_exact(&mut buf)?;
                        drop(file);
                        if String::from_utf8_lossy(&buf[0..4]).to_string().as_str() == "RIFF" {
                            continue;
                        }
                        if String::from_utf8_lossy(&buf[4..12]).to_string().as_str() == "ftypavif" {
                            continue;
                        }
                        files.push((entry.path(), opts.lossless));
                    }
                }
                Err(err) => println!("Error: {err}"),
            }
        }
    }

    let bar =ProgressBar::new(files.len() as u64).with_style(
        ProgressStyle::with_template(
            "{bar:48.green/black} {human_pos:>5.green}/{human_len:<5.green} {per_sec:.red} eta {eta:.blue}",
        )
        .unwrap()
        .progress_chars("━╾╴─"),
    );

    let num_cpus = (num_cpus::get() - 1).max(1);

    let mut pool = ThreadPoolBuilder::new()
        .with_name_str("pool-name")
        .with_tasks(num_cpus)
        .with_queue_size(num_cpus * 2)
        .with_shutdown_mode(ShutdownMode::CompletePending)
        .build()?;

    for (path, lossless) in files {
        pool.submit(Box::new(ProcessingCommand::new(
            options.format.clone(),
            path,
            lossless,
            options.webp_quality,
            options.avif_quality,
        )));
        bar.inc(1);
    }

    pool.shutdown();
    pool.join()?;

    bar.finish();

    Ok(())
}

pub fn task_notarize_post(ctx: &TaskContext, options: &NotarizeOptions) -> Result<()> {
    for path in ctx.on_builds.values() {
        let path = Path::new(path.as_ref().expect("Build path not found"));

        if path.is_file() && path.extension().unwrap() == "zip" {
            thread::scope(|s| {
                s.spawn(move || {
                    full_run(
                        path,
                        &options.bundle_id,
                        &options.key_file,
                        &options.cert_file,
                        &options.app_store_key_file,
                        !options.no_zip,
                        !options.no_dmg,
                    )
                })
                .join()
                .unwrap()
                .unwrap();
            });
        } else {
            let mut app_bundles = vec![];
            for entry in WalkDir::new(path) {
                match entry {
                    Ok(entry) => {
                        let path = entry.path();
                        if path.is_file() {
                            continue;
                        }
                        if let Some(ext) = path.extension()
                            && ext == "app"
                        {
                            app_bundles.push(path);
                        }
                    }
                    Err(err) => println!("Error: {err}"),
                }
            }

            for bundle in app_bundles {
                thread::scope(|s| {
                    s.spawn(move || {
                        full_run(
                            &bundle,
                            &options.bundle_id,
                            &options.key_file,
                            &options.cert_file,
                            &options.app_store_key_file,
                            !options.no_zip,
                            !options.no_dmg,
                        )
                    })
                    .join()
                    .unwrap()
                    .unwrap();
                });
            }
        }
    }

    Ok(())
}
