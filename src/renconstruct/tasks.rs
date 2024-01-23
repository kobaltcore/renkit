use super::config::{
    ConvertImagesOptions, GeneralTaskOptions, ImageFormat, KeystoreOptions, NotarizeOptions,
};
use crate::common::Version;
use crate::renotize::full_run;
use anyhow::Result;
use base64::prelude::*;
use command_executor::command::Command;
use command_executor::shutdown_mode::ShutdownMode;
use command_executor::thread_pool_builder::ThreadPoolBuilder;
use imgref::ImgRef;
use indicatif::{ProgressBar, ProgressStyle};
use jwalk::WalkDir;
use ravif::Encoder;
use rgb::FromSlice;
use std::io::Read;
use std::path::PathBuf;
use std::{env, fs};
use {anyhow::anyhow, image::io::Reader as ImageReader, image::EncodableLayout};

#[derive(Debug)]
pub struct Task {
    pub name: String,
    pub kind: GeneralTaskOptions,
    // TODO: add some kind of handle to call custom tasks here
}

#[derive(Debug, Clone)]
pub struct TaskContext {
    pub version: Version,
    pub input_dir: PathBuf,
    pub output_dir: PathBuf,
    pub renpy_path: PathBuf,
}

pub struct ProcessingCommand {
    pub image_format: ImageFormat,
    pub path: PathBuf,
    pub lossless: bool,
}

impl ProcessingCommand {
    fn new(image_format: ImageFormat, path: PathBuf, lossless: bool) -> ProcessingCommand {
        ProcessingCommand {
            image_format,
            path,
            lossless,
        }
    }
}

impl Command for ProcessingCommand {
    fn execute(&self) -> Result<()> {
        match self.image_format {
            ImageFormat::Avif => {
                let image = ImageReader::open(&self.path)?.decode()?;
                let image = image.to_rgba8();
                let image = ImgRef::new(
                    image.as_rgba(),
                    image.width() as usize,
                    image.height() as usize,
                );

                let avif_enc = Encoder::new()
                    .with_quality(90.0)
                    .with_speed(5)
                    .with_num_threads(Some(1));
                let img = avif_enc.encode_rgba(image)?;

                fs::write(&self.path, &img.avif_file)?;
            }
            ImageFormat::WebP => {
                let image = ImageReader::open(&self.path)?.decode()?;
                let image = image.to_rgba8();

                let enc = webp::Encoder::from_rgba(&image, image.width(), image.height());

                let result = match self.lossless {
                    true => {
                        // -lossless -z 9 -m 6
                        enc.encode_advanced(&webp::WebPConfig {
                            lossless: 1,
                            quality: 100.0,
                            method: 6,
                            image_hint: libwebp_sys::WebPImageHint::WEBP_HINT_PICTURE,
                            target_size: 0,
                            target_PSNR: 0.0,
                            segments: 4,
                            sns_strength: 50,
                            filter_strength: 60,
                            filter_sharpness: 0,
                            filter_type: 0,
                            autofilter: 0,
                            alpha_compression: 1,
                            alpha_filtering: 1,
                            alpha_quality: 100,
                            pass: 5,
                            show_compressed: 0,
                            preprocessing: 0,
                            partitions: 0,
                            partition_limit: 0,
                            emulate_jpeg_size: 0,
                            thread_level: 0,
                            low_memory: 0,
                            near_lossless: 0,
                            exact: 0,
                            use_delta_palette: 0,
                            use_sharp_yuv: 1,
                            qmin: 0,
                            qmax: 100,
                        })
                        .map_err(|err| anyhow!("Error encoding WebP image: {:?}", err))?
                    }
                    false => {
                        // -q 90 -m 6 -sharp_yuv -pre 4
                        enc.encode_advanced(&webp::WebPConfig {
                            lossless: 1,
                            quality: 90.0,
                            method: 6,
                            image_hint: libwebp_sys::WebPImageHint::WEBP_HINT_PICTURE,
                            target_size: 0,
                            target_PSNR: 0.0,
                            segments: 4,
                            sns_strength: 50,
                            filter_strength: 60,
                            filter_sharpness: 0,
                            filter_type: 0,
                            autofilter: 0,
                            alpha_compression: 1,
                            alpha_filtering: 1,
                            alpha_quality: 100,
                            pass: 5,
                            show_compressed: 0,
                            preprocessing: 4,
                            partitions: 0,
                            partition_limit: 0,
                            emulate_jpeg_size: 0,
                            thread_level: 0,
                            low_memory: 0,
                            near_lossless: 0,
                            exact: 0,
                            use_delta_palette: 0,
                            use_sharp_yuv: 1,
                            qmin: 0,
                            qmax: 90,
                        })
                        .map_err(|err| anyhow!("Error encoding WebP image: {:?}", err))?
                    }
                };

                fs::write(&self.path, &result.as_bytes())?;
            }
        }

        Ok(())
    }
}

pub fn task_keystore_pre(ctx: &TaskContext, options: &KeystoreOptions) -> Result<()> {
    let android_path;
    let android_path_backup;
    let bundle_path;
    let bundle_path_backup;

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
    };

    if android_path.exists() && !android_path_backup.exists() {
        fs::copy(&android_path, &android_path_backup)?;
    }

    if bundle_path.exists() && !bundle_path_backup.exists() {
        fs::copy(&bundle_path, &bundle_path_backup)?;
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

    Ok(())
}

pub fn task_keystore_post(ctx: &TaskContext, _options: &KeystoreOptions) -> Result<()> {
    let android_path;
    let android_path_backup;
    let bundle_path;
    let bundle_path_backup;

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
    };

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

        for entry in match opts.recursive {
            true => WalkDir::new(path),
            false => WalkDir::new(path).max_depth(1),
        } {
            match entry {
                Ok(entry) => {
                    if entry.path().is_dir() {
                        continue;
                    }
                    match entry.path().extension() {
                        Some(ext) => {
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
                            if String::from_utf8_lossy(&buf[4..12]).to_string().as_str()
                                == "ftypavif"
                            {
                                continue;
                            }
                            files.push((entry.path(), opts.lossless));
                        }
                        None => continue,
                    }
                }
                Err(err) => {
                    println!("Error: {}", err);
                    continue;
                }
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
        )));
        bar.inc(1);
    }

    pool.shutdown();
    pool.join()?;

    bar.finish();

    Ok(())
}

pub fn task_notarize_post(ctx: &TaskContext, options: &NotarizeOptions) -> Result<()> {
    // find path ending in '-mac.zip'
    let zip_path = fs::read_dir(&ctx.input_dir)?.find_map(|entry| {
        let entry = entry.unwrap();
        let path = entry.path();
        if path.extension().unwrap() == "zip" {
            if path
                .file_stem()
                .unwrap()
                .to_str()
                .unwrap()
                .ends_with("-mac")
            {
                Some(path)
            } else {
                None
            }
        } else {
            None
        }
    });

    match zip_path {
        Some(path) => {
            full_run(
                &path,
                &options.bundle_id,
                &options.key_file,
                &options.cert_file,
                &options.app_store_key_file,
            )?;
        }
        None => {
            return Err(anyhow!("Could not find mac zip file."));
        }
    }

    Ok(())
}
