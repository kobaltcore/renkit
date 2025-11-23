use crate::common::canonicalize_normalized;
use crate::version::Version;
use anyhow::{Result, anyhow};
use bzip2::read::BzDecoder;
use lol_html::{HtmlRewriter, Settings, element};
#[cfg(target_family = "unix")]
use std::os::unix::fs::PermissionsExt;
use std::{
    env, fs,
    io::{BufRead, BufReader},
    marker::PhantomData,
    path::PathBuf,
    process::{Command, ExitStatus, Stdio},
    str::FromStr,
    sync::{Arc, Mutex},
    thread,
};
use tar::Archive;
use trauma::{download::Download, downloader::DownloaderBuilder};
use zip::read::root_dir_common_filter;

pub trait InstanceState {}

pub struct Local;
pub struct Remote;

impl InstanceState for Local {}
impl InstanceState for Remote {}

pub struct Instance<S: InstanceState> {
    pub version: Version,
    _marker: PhantomData<S>,
}

impl<S: InstanceState> Instance<S> {
    #[must_use]
    pub fn new(version: Version) -> Self {
        Self {
            version,
            _marker: PhantomData,
        }
    }

    #[must_use]
    pub fn path(&self, registry: &PathBuf) -> PathBuf {
        let base_path = canonicalize_normalized(registry).expect("Unable to canonicalize path.");
        base_path.join(self.version.to_string())
    }
}

impl Instance<Local> {
    pub fn architecture(&self) -> Result<&str> {
        let host_os = std::env::consts::OS;
        let architecture = std::env::consts::ARCH;

        match host_os {
            "windows" => match architecture {
                "x86_64" => {
                    if self.version < Version::from_str("7.4.0").unwrap() {
                        Ok("windows-x86_64")
                    } else if self.version < Version::from_str("8.0.0").unwrap() {
                        Ok("py2-windows-x86_64")
                    } else {
                        Ok("py3-windows-x86_64")
                    }
                }
                "x86" => {
                    if self.version < Version::from_str("7.4.0").unwrap() {
                        Ok("windows-i686")
                    } else if self.version < Version::from_str("8.0.0").unwrap() {
                        Ok("py2-windows-i686")
                    } else {
                        Ok("py3-windows-i686")
                    }
                }
                _ => Err(anyhow!("Unsupported architecture: {}", architecture)),
            },
            "linux" => match architecture {
                "x86_64" => {
                    if self.version < Version::from_str("7.4.0").unwrap() {
                        Ok("linux-x86_64")
                    } else if self.version < Version::from_str("8.0.0").unwrap() {
                        Ok("py2-linux-x86_64")
                    } else {
                        Ok("py3-linux-x86_64")
                    }
                }
                "x86" => {
                    if self.version < Version::from_str("7.4.0").unwrap() {
                        Ok("linux-i686")
                    } else if self.version < Version::from_str("8.0.0").unwrap() {
                        Ok("py2-linux-i686")
                    } else {
                        Ok("py3-linux-i686")
                    }
                }
                "arm" => {
                    if self.version < Version::from_str("7.5.0").unwrap() {
                        Err(anyhow!("Unsupported architecture: {}", architecture))
                    } else if self.version < Version::from_str("8.0.0").unwrap() {
                        Ok("py2-linux-armv7l")
                    } else {
                        Ok("py3-linux-armv7l")
                    }
                }
                "aarch64" => {
                    if self.version < Version::from_str("7.5.0").unwrap() {
                        Err(anyhow!("Unsupported architecture: {}", architecture))
                    } else if self.version < Version::from_str("8.0.0").unwrap() {
                        Ok("py2-linux-aarch64")
                    } else {
                        Ok("py3-linux-aarch64")
                    }
                }
                _ => Err(anyhow!("Unsupported architecture: {}", architecture)),
            },
            "macos" => {
                if self.version < Version::from_str("7.4.0").unwrap() {
                    Ok("darwin-x86_64")
                } else if self.version <= Version::from_str("7.4.11").unwrap() {
                    Ok("mac-x86_64")
                } else if self.version < Version::from_str("8.0.0").unwrap() {
                    Ok("py2-mac-x86_64")
                } else if self.version <= Version::from_str("8.0.3").unwrap() {
                    Ok("py3-mac-x86_64")
                } else {
                    Ok("py3-mac-universal")
                }
            }
            _ => Err(anyhow!("Unsupported OS: {}", host_os)),
        }
    }

    pub fn python(&self, registry: &PathBuf) -> Result<PathBuf> {
        let exe = match std::env::consts::OS {
            "windows" => "python.exe",
            _ => "python",
        };

        match self.architecture() {
            Ok(arch) => Ok(self.path(registry).join("lib").join(arch).join(exe)),
            Err(e) => Err(e),
        }
    }

    #[must_use]
    pub fn entrypoint(&self, registry: &PathBuf) -> PathBuf {
        self.path(registry).join("renpy.py")
    }
}

impl std::fmt::Display for Version {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let Version {
            major,
            minor,
            patch,
            hotfix,
            nightly,
        } = self;
        {
            write!(f, "{major}.{minor}.{patch}")?;
            if *hotfix > 0 {
                write!(f, ".{hotfix}")?;
            }
            if *nightly {
                write!(f, "+nightly")?;
            }
            Ok(())
        }
    }
}

#[must_use]
pub fn get_registry(registry: Option<PathBuf>) -> PathBuf {
    let registry = registry
        .or_else(|| match home::home_dir() {
            Some(mut path) => {
                path.push(".renutil");
                Some(path)
            }
            None => None,
        })
        .expect("Unable to detect home directory.");

    if !registry.exists() {
        std::fs::create_dir_all(&registry).expect("Unable to create registry directory.");
    }

    registry
}

pub async fn get_available_versions(registry: &PathBuf, online: bool) -> Result<Vec<Version>> {
    let mut versions = vec![];

    if online {
        for (i, url) in ["https://nightly.renpy.org", "https://www.renpy.org/dl"]
            .iter()
            .enumerate()
        {
            let body = reqwest::get(*url).await?.text().await?;

            let mut rewriter = HtmlRewriter::new(
                Settings {
                    element_content_handlers: vec![element!("a[href]", |el| {
                        let href = el
                            .get_attribute("href")
                            .ok_or(anyhow!("Unable to get attribute."))?;
                        let href = match i {
                            0 => &href,
                            _ => href
                                .strip_suffix("/")
                                .ok_or(anyhow!("Unable to strip suffix."))?,
                        };

                        if let Ok(version) = Version::from_str(href) {
                            versions.push(version);
                        }

                        Ok(())
                    })],
                    ..Settings::default()
                },
                |_: &[u8]| {},
            );
            rewriter.write(body.as_bytes())?;
            rewriter.end()?;
        }
    } else {
        for entry in fs::read_dir(registry)? {
            let entry = entry?;
            let path = entry.path();
            let path = path
                .file_name()
                .ok_or(anyhow!("Unable to get file name."))?
                .to_str()
                .ok_or(anyhow!("Unable to get file name."))?;

            if let Ok(version) = Version::from_str(path) {
                versions.push(version);
            }
        }
    }

    Ok(versions)
}

pub async fn list(registry: &PathBuf, online: bool, num: usize, nightly: bool) -> Result<()> {
    let versions = get_available_versions(registry, online).await?;

    let mut versions = if online {
        versions
            .iter()
            .filter(|v| !v.nightly || nightly)
            .collect::<Vec<&Version>>()
    } else {
        versions.iter().collect::<Vec<&Version>>()
    };

    versions.sort_by(|a, b| b.cmp(a));

    for version in versions.iter().take(num) {
        println!("{version}");
    }

    Ok(())
}

pub async fn show(registry: &PathBuf, version: &Version) -> Result<()> {
    if version.is_installed(registry) {
        println!("Version: {version}");
    } else {
        let versions = get_available_versions(registry, true).await?;
        if !versions.contains(version) {
            anyhow::bail!("{} is not a valid version of Ren'Py.", version);
        }
    }

    if version.is_installed(registry) {
        let instance = version
            .to_local(registry)
            .expect("Unable to get local instance.");

        println!("Installed: Yes");

        let location = instance.path(registry);
        let location = location.to_string_lossy();

        println!("Location: {location}");

        let architecture = instance
            .architecture()
            .expect("Unable to get architecture.");

        println!("Architecture: {architecture}");
    } else {
        println!("Installed: No");
    }
    println!("SDK URL: {}", version.sdk_url()?);
    println!("RAPT URL: {}", version.rapt_url()?);

    Ok(())
}

pub async fn launch(
    registry: &PathBuf,
    version: Option<&Version>,
    headless: bool,
    direct: bool,
    args: &[String],
    check_status: bool,
    auto_install: bool,
) -> Result<(ExitStatus, String, String)> {
    let auto_install = match std::env::var("RENUTIL_AUTOINSTALL") {
        Ok(val) => {
            let val = val.to_lowercase();
            if val == "true" || val == "1" {
                auto_install
            } else {
                false
            }
        }
        Err(_) => auto_install,
    };

    if !direct && version.is_none() {
        anyhow::bail!("Launcher mode requires a version to be specified via '-v <version>'.");
    }

    let version = match version {
        Some(version) => Some(version.clone()),
        None => {
            if args.is_empty() {
                None
            } else {
                let path = PathBuf::from(&args[0]);
                if path.exists() {
                    let renpy_version_path = path.join(".renpy-version");
                    if renpy_version_path.exists() {
                        let file_content = fs::read_to_string(renpy_version_path)?;
                        Some(Version::from_str(file_content.trim())?)
                    } else {
                        None
                    }
                } else {
                    None
                }
            }
        }
    };

    let Some(version) = version else {
        anyhow::bail!(
            "Could not determine Ren'Py version to launch with, supply it via '-v <version>'."
        );
    };

    println!("Ren'Py Version: {version}");

    if !version.is_installed(registry) && auto_install {
        install(registry, &version, false, false, false).await?;
    }

    let instance = version.to_local(registry)?;

    let python = instance.python(registry)?;
    let python = python.to_str().unwrap();

    let entrypoint = instance.entrypoint(registry);
    let entrypoint = entrypoint.to_str().unwrap();

    let rpy_log_val_orig = std::env::var("RENPY_LOG_TO_STDOUT").ok();
    unsafe { std::env::set_var("RENPY_LOG_TO_STDOUT", "1") };

    let mut cmd = Command::new(python);

    let cmd = cmd.stdout(Stdio::piped()).stderr(Stdio::piped());

    cmd.arg("-EO").arg(entrypoint);

    if direct {
        cmd.args(args);
    } else {
        let launcher_path = instance.path(registry).join("launcher");
        let launcher_path = launcher_path.to_str().unwrap();
        cmd.arg(launcher_path).args(args);
    }

    if headless {
        unsafe {
            std::env::set_var("SDL_AUDIODRIVER", "dummy");
            std::env::set_var("SDL_VIDEODRIVER", "dummy");
        };
    }

    let mut child = cmd.spawn()?;

    let child_stdout = child.stdout.take().unwrap();
    let child_stderr = child.stderr.take().unwrap();

    // We do some thread magic here to both print stdout and stderr as they come in,
    // as well as capturing them to return them once the process has exited.

    let bufread_stdout = BufReader::new(child_stdout);
    let bufread_stderr = BufReader::new(child_stderr);
    let result_stdout = Arc::new(Mutex::new(vec![]));
    let result_stdout_clone = result_stdout.clone();
    let h_stdout = thread::spawn(move || {
        for line in bufread_stdout.lines() {
            let line = line.unwrap();
            println!("{line}");
            let mut handle = result_stdout_clone.lock().unwrap();
            handle.push(line);
        }
    });

    let result_stderr = Arc::new(Mutex::new(vec![]));
    let result_stderr_clone = result_stderr.clone();
    let h_stderr = thread::spawn(move || {
        for line in bufread_stderr.lines() {
            let line = line.unwrap();
            eprintln!("{line}");
            let mut handle = result_stderr_clone.lock().unwrap();
            handle.push(line);
        }
    });

    h_stdout.join().unwrap();
    h_stderr.join().unwrap();

    let status = child.wait()?;

    if check_status && !status.success() {
        anyhow::bail!(
            "Unable to launch Ren'Py: Status {}",
            status.code().unwrap_or(1)
        );
    }

    unsafe {
        match rpy_log_val_orig {
            Some(val) => std::env::set_var("RENPY_LOG_TO_STDOUT", val),
            None => std::env::remove_var("RENPY_LOG_TO_STDOUT"),
        }
    }

    let out_stdout = result_stdout.lock().unwrap().join("\n");
    let out_stderr = result_stderr.lock().unwrap().join("\n");

    Ok((status, out_stdout, out_stderr))
}

pub async fn install(
    registry: &PathBuf,
    version: &Version,
    no_cleanup: bool,
    force: bool,
    update_pickle: bool,
) -> Result<()> {
    let versions = get_available_versions(registry, true).await?;
    if !versions.contains(version) {
        anyhow::bail!("{} is not a valid version of Ren'Py.", version);
    }

    let java_home = if let Ok(val) = env::var("JAVA_HOME") {
        PathBuf::from(val)
    } else {
        let jdk_version = if version >= &Version::from_str("8.2.0").unwrap() {
            "21"
        } else {
            "8"
        };
        anyhow::bail!(
            "JAVA_HOME is not set. Please check if you need to install OpenJDK {jdk_version}"
        );
    };

    if version.is_installed(registry) {
        if force {
            println!("Forcing uninstallation of existing version {version}.");
            uninstall(registry, version)?;
        } else {
            return Err(anyhow!("Version {} is already installed.", version));
        }
    }

    let instance = version
        .to_remote(registry)
        .expect("Unable to get remote instance.");

    let base_path = instance.path(registry);

    fs::create_dir_all(&base_path).expect("Unable to create directory.");

    let sdk_url = version.sdk_url()?;
    let rapt_url = version.rapt_url()?;
    let steam_url = version.steam_url()?;
    let web_url = version.web_url()?;

    println!("Downloading Ren'Py {version}...");
    let downloads = vec![
        Download::new(
            &sdk_url,
            sdk_url.path_segments().unwrap().next_back().unwrap(),
        ),
        Download::new(
            &rapt_url,
            rapt_url.path_segments().unwrap().next_back().unwrap(),
        ),
        Download::new(
            &steam_url,
            steam_url.path_segments().unwrap().next_back().unwrap(),
        ),
        Download::new(
            &web_url,
            web_url.path_segments().unwrap().next_back().unwrap(),
        ),
    ];
    let downloader = DownloaderBuilder::new().directory(registry.clone()).build();
    downloader.download(&downloads).await;

    println!("Extracting SDK");

    let sdk_zip_path = registry.join(sdk_url.path_segments().unwrap().next_back().unwrap());

    if sdk_zip_path.extension().unwrap() == "bz2" {
        let compressed_file = fs::File::open(&sdk_zip_path)?;
        let tar_path = sdk_zip_path.with_extension("");
        let mut tar_file = fs::File::create(&tar_path)?;

        let mut decompressor = BzDecoder::new(compressed_file);
        std::io::copy(&mut decompressor, &mut tar_file)?;

        let tar_file = fs::File::open(&tar_path).unwrap();
        let mut tar_archive = Archive::new(tar_file);
        for file in tar_archive.entries().unwrap() {
            let mut file = file?;
            let path = file.path()?.components().skip(1).collect::<PathBuf>();
            if path.as_os_str().is_empty() {
                continue;
            }
            file.unpack(base_path.join(path))?;
        }

        fs::remove_file(tar_path)?;
    } else {
        let zip_data = fs::File::open(&sdk_zip_path)?;
        let mut zip = zip::ZipArchive::new(zip_data)?;
        zip.extract_unwrapped_root_dir(&base_path, root_dir_common_filter)?;
    }

    println!("Extracting RAPT");

    let rapt_zip_path = registry.join(rapt_url.path_segments().unwrap().next_back().unwrap());

    let zip_data = fs::File::open(&rapt_zip_path)?;
    let mut zip = zip::ZipArchive::new(zip_data)?;
    zip.extract_unwrapped_root_dir(&base_path.join("rapt"), root_dir_common_filter)?;

    let steam_zip_path = registry.join(steam_url.path_segments().unwrap().next_back().unwrap());
    if steam_zip_path.exists() {
        println!("Extracting Steam support");

        let zip_data = fs::File::open(&steam_zip_path)?;
        let mut zip = zip::ZipArchive::new(zip_data)?;
        zip.extract_unwrapped_root_dir(&base_path.join("lib"), root_dir_common_filter)?;
    }

    let web_zip_path = registry.join(web_url.path_segments().unwrap().next_back().unwrap());
    if web_zip_path.exists() {
        println!("Extracting Web support");

        let zip_data = fs::File::open(&web_zip_path)?;
        let mut zip = zip::ZipArchive::new(zip_data)?;
        zip.extract_unwrapped_root_dir(&base_path.join("web"), root_dir_common_filter)?;
    }

    if !no_cleanup {
        println!("Cleaning up temporary files");
        fs::remove_file(sdk_zip_path).expect("Unable to remove SDK archive.");
        fs::remove_file(rapt_zip_path).expect("Unable to remove RAPT archive.");
        if steam_zip_path.exists() {
            fs::remove_file(steam_zip_path).expect("Unable to remove Steam archive.");
        }
        if web_zip_path.exists() {
            fs::remove_file(web_zip_path).expect("Unable to remove Web archive.");
        }
    }

    let instance = version.to_local(registry)?;

    let python = instance.python(registry)?;

    #[cfg(target_family = "unix")]
    {
        let python_parent = python.parent().ok_or(anyhow!("Unable to get parent."))?;

        let paths = [
            python.clone(),
            python_parent.join("pythonw"),
            python_parent.join("renpy"),
            python_parent.join("zsync"),
            python_parent.join("zsyncmake"),
            base_path.join("rapt/prototype/gradlew"),
            base_path.join("rapt/project/gradlew"),
        ];

        for path in paths.iter().filter(|p| p.exists()) {
            println!(
                "Setting executable permissions for {}.",
                path.to_string_lossy()
            );
            fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
        }
    }

    let keytool = java_home.join("bin").join("keytool");

    let android_keystore = base_path.join("rapt").join("android.keystore");
    let android_keystore_str = android_keystore.to_str().unwrap();
    #[cfg(target_family = "windows")]
    let android_keystore_str = android_keystore_str.replace("\\\\?\\", "");
    #[cfg(target_family = "windows")]
    let android_keystore_str = android_keystore_str.as_str();
    if !android_keystore.exists() {
        println!("Generating Android keystore");

        let mut cmd = Command::new(&keytool);
        cmd.args([
            "-genkey",
            "-keystore",
            android_keystore_str,
            "-alias",
            "android",
            "-keyalg",
            "RSA",
            "-keysize",
            "2048",
            "-keypass",
            "android",
            "-storepass",
            "android",
            "-dname",
            "CN=renutil",
            "-validity",
            "20000",
        ]);
        match cmd.status() {
            Ok(status) => {
                if !status.success() {
                    match status.code() {
                        Some(code) => {
                            anyhow::bail!(
                                "Unable to generate Android keystore: Exit code {code}\nCommand: {cmd:?}"
                            );
                        }
                        None => {
                            anyhow::bail!(
                                "Unable to generate Android keystore: Terminated by signal\nCommand: {cmd:?}"
                            );
                        }
                    }
                }
            }
            Err(e) => {
                anyhow::bail!("Unable to generate Android keystore: {e}\nCommand: {cmd:?}");
            }
        }
    }

    let bundle_keystore = base_path.join("rapt").join("android.keystore");
    if !bundle_keystore.exists() {
        println!("Generating Bundle keystore (reusing Android keystore)");

        fs::copy(android_keystore, bundle_keystore)?;
    }

    println!("Patching SSL issue in RAPT");
    let interface_path = base_path.join("rapt/buildlib/rapt/interface.py");
    let content = fs::read_to_string(&interface_path)?;
    let mut lines: Vec<&str> = content.split('\n').collect();
    // insert as the second line, in case we have a __future__ import, which always goes first
    lines.insert(
        1,
        "import ssl; ssl._create_default_https_context = ssl._create_unverified_context",
    );
    fs::write(&interface_path, lines.join("\n"))?;

    #[cfg(target_family = "windows")]
    {
        println!("Patching extended path issue in RAPT on Windows");
        // On Windows, the RAPT plat.py file has an issue with using extended paths by default.
        // This is a problem because Java's classpath does not support them.
        // This leads to it not finding the CheckJDK class, leading to an installation failure.
        // We crudely patch this by replacing the __file__ variable with a version that removes the extended path prefix.
        let plat_path = base_path.join("rapt/buildlib/rapt/plat.py");
        let content = fs::read_to_string(&plat_path)?;
        fs::write(
            &plat_path,
            content.replace("__file__", r"__file__.replace('\\\\?\\', '')"),
        )?;
    }

    println!("Installing RAPT");
    // in versions above 7.5.0, the RAPT installer tries to import renpy.compat
    // this is not in the path by default, and since PYTHONPATH is ignored, we
    // symlink it instead to make it visible during installation.
    if version >= &Version::from_str("7.5.0").unwrap() {
        #[cfg(target_family = "windows")]
        std::os::windows::fs::symlink_dir(base_path.join("renpy"), base_path.join("rapt/renpy"))?;
        #[cfg(target_family = "unix")]
        std::os::unix::fs::symlink(base_path.join("renpy"), base_path.join("rapt/renpy"))?;
    }

    println!("Patching import issue in android.py");
    // it imports pygame_sdl2 but never uses it. it's not in sys.path by default, which makes it annoying to deal with
    let interface_path = base_path.join("rapt/android.py");
    let content = fs::read_to_string(&interface_path)?;
    let lines: Vec<&str> = content
        .split('\n')
        .filter(|line| !line.contains("import pygame_sdl2"))
        .collect();
    fs::write(&interface_path, lines.join("\n"))?;

    unsafe { env::set_var("RAPT_NO_TERMS", "1") };

    let android_py = base_path.join("rapt/android.py");
    let mut cmd = Command::new(&python);
    cmd.args(["-EO", android_py.to_str().unwrap(), "installsdk"]);
    cmd.current_dir(base_path.join("rapt"));

    let status = cmd.status()?;
    if !status.success() {
        anyhow::bail!("Unable to install Android SDK.");
    }

    println!("Increasing Gradle RAM limit to 8Gb");
    let paths = [
        base_path.join("rapt/prototype/gradle.properties"),
        base_path.join("rapt/project/gradle.properties"),
    ];

    let re = regex::Regex::new(r"org\.gradle\.jvmargs=-Xmx(\d+)g").unwrap();
    for path in paths.iter().filter(|p| p.exists()) {
        let content = fs::read_to_string(path)?;
        let content = re
            .replace_all(&content, "org.gradle.jvmargs=-Xmx8g")
            .to_string();
        fs::write(path, content)?;
    }

    println!("Installing Android SDK");
    #[cfg(target_family = "windows")]
    let mut sdkmanager = base_path.join("rapt/Sdk/cmdline-tools/latest/bin/sdkmanager.exe");
    #[cfg(target_family = "windows")]
    {
        if !sdkmanager.exists() {
            // This can be a batch file now, for some reason.
            let new_sdkmanager = base_path.join("rapt/Sdk/cmdline-tools/latest/bin/sdkmanager.bat");
            sdkmanager = new_sdkmanager;
        }
    }
    #[cfg(target_family = "unix")]
    let mut sdkmanager = base_path.join("rapt/Sdk/cmdline-tools/latest/bin/sdkmanager");

    // On older versions of Ren'Py, the SDK manager is in a different location.
    if !sdkmanager.exists() {
        #[cfg(target_family = "windows")]
        let new_sdkmanager = base_path.join("rapt/Sdk/tools/bin/sdkmanager.exe");
        #[cfg(target_family = "unix")]
        let new_sdkmanager = base_path.join("rapt/Sdk/tools/bin/sdkmanager");
        sdkmanager = new_sdkmanager;
    }

    let mut cmd = Command::new(&sdkmanager);
    cmd.arg("build-tools;29.0.2");
    let status = cmd.status()?;
    if !status.success() {
        anyhow::bail!("Unable to install Android SDK build tools.");
    }

    if update_pickle {
        println!("Increasing default pickle protocol from 2 to 5");
        let pickle_path = base_path.join("renpy/compat/pickle.py");
        let content = fs::read_to_string(&pickle_path)?;
        fs::write(
            &pickle_path,
            content.replace("PROTOCOL = 2", "PROTOCOL = 5"),
        )?;
    }

    Ok(())
}

pub fn cleanup(registry: &PathBuf, version: &Version) -> Result<()> {
    let instance = version.to_local(registry)?;

    let path = instance.path(registry);

    let paths = [
        path.join("tmp"),
        path.join("rapt/assets"),
        path.join("rapt/bin"),
        path.join("rapt/project/app/build"),
        path.join("rapt/project/app/src/main/assets"),
    ];

    for path in paths.iter().filter(|p| p.exists()) {
        println!("Cleaning up {}", path.to_string_lossy());
        fs::remove_dir_all(path)?;
    }

    Ok(())
}

pub fn uninstall(registry: &PathBuf, version: &Version) -> Result<()> {
    let instance = version.to_local(registry)?;

    let path = instance.path(registry);

    fs::remove_dir_all(path)?;

    Ok(())
}
