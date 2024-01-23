use crate::common::Version;
use anyhow::anyhow;
use anyhow::Result;
use lol_html::{element, HtmlRewriter, Settings};
use std::env;
use std::io::Cursor;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::Command;
use std::{fs, marker::PhantomData, path::PathBuf};
use trauma::download::Download;
use trauma::downloader::DownloaderBuilder;

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
    pub fn new(version: Version) -> Self {
        Self {
            version,
            _marker: PhantomData,
        }
    }

    pub fn path(&self, registry: &PathBuf) -> PathBuf {
        let base_path = fs::canonicalize(registry).expect("Unable to canonicalize path.");
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
                _ => panic!("Unsupported architecture: {}", architecture),
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
                _ => panic!("Unsupported architecture: {}", architecture),
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

    pub fn entrypoint(&self, registry: &PathBuf) -> PathBuf {
        self.path(registry).join("renpy.py")
    }
}

impl std::fmt::Display for Version {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Version {
                major,
                minor,
                patch,
                hotfix,
            } => {
                write!(f, "{}.{}.{}", major, minor, patch)?;
                if *hotfix > 0 {
                    write!(f, ".{}", hotfix)?;
                }
                Ok(())
            }
        }
    }
}

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
    let body = reqwest::get("https://www.renpy.org/dl")
        .await?
        .text()
        .await?;

    let mut versions = vec![];

    if online {
        let mut rewriter = HtmlRewriter::new(
            Settings {
                element_content_handlers: vec![element!("a[href]", |el| {
                    let href = el
                        .get_attribute("href")
                        .ok_or(anyhow!("Unable to get attribute."))?;
                    let href = href
                        .strip_suffix("/")
                        .ok_or(anyhow!("Unable to strip suffix."))?;

                    match Version::from_str(href) {
                        Some(version) => {
                            versions.push(version);
                        }
                        None => {}
                    }

                    Ok(())
                })],
                ..Settings::default()
            },
            |_: &[u8]| {},
        );
        rewriter.write(body.as_bytes())?;
        rewriter.end()?;
    } else {
        for entry in fs::read_dir(registry)? {
            let entry = entry?;
            let path = entry.path();
            let path = path
                .file_name()
                .ok_or(anyhow!("Unable to get file name."))?
                .to_str()
                .ok_or(anyhow!("Unable to get file name."))?;

            match Version::from_str(path) {
                Some(version) => {
                    versions.push(version);
                }
                None => {}
            }
        }
    }

    Ok(versions)
}

pub async fn list(registry: &PathBuf, online: bool, num: usize) -> Result<()> {
    let mut versions = get_available_versions(registry, online).await?;

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
    println!("SDK URL: https://www.renpy.org/dl/{version}/renpy-{version}-sdk.zip");
    println!("RAPT URL: https://www.renpy.org/dl/{version}/renpy-{version}-rapt.zip");

    Ok(())
}

pub fn launch(
    registry: &PathBuf,
    version: &Version,
    headless: bool,
    direct: bool,
    args: &[String],
) -> Result<()> {
    let instance = version.to_local(registry)?;

    let python = instance.python(registry)?;
    let python = python.to_str().unwrap();

    let entrypoint = instance.entrypoint(registry);
    let entrypoint = entrypoint.to_str().unwrap();

    let mut cmd = Command::new(python);

    cmd.arg("-EO").arg(entrypoint);

    match direct {
        true => cmd.args(args),
        false => {
            let launcher_path = instance.path(registry).join("launcher");
            let launcher_path = launcher_path.to_str().unwrap();
            cmd.arg(launcher_path).args(args)
        }
    };

    if headless {
        std::env::set_var("SDL_AUDIODRIVER", "dummy");
        std::env::set_var("SDL_VIDEODRIVER", "dummy");
    }

    let status = cmd.status()?;
    if !status.success() {
        anyhow::bail!("Unable to launch Ren'Py.");
    }

    Ok(())
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

    let java_home = match env::var("JAVA_HOME") {
        Ok(val) => PathBuf::from(val),
        Err(_) => {
            let jdk_version = match version >= &Version::from_str("8.2.0").unwrap() {
                true => "21",
                false => "8",
            };
            anyhow::bail!(
                "JAVA_HOME is not set. Please check if you need to install OpenJDK {jdk_version}"
            );
        }
    };

    if version.is_installed(registry) {
        if force {
            println!("Forcing uninstallation of existing version {}.", version);
            uninstall(registry, version)?;
        } else {
            panic!("Version {} is already installed.", version);
        }
    }

    let instance = version
        .to_remote(registry)
        .expect("Unable to get remote instance.");

    let base_path = instance.path(registry);

    fs::create_dir_all(&base_path).expect("Unable to create directory.");

    let sdk_url = format!("https://www.renpy.org/dl/{version}/renpy-{version}-sdk.zip");
    let rapt_url = format!("https://www.renpy.org/dl/{version}/renpy-{version}-rapt.zip");
    let steam_url = format!("https://www.renpy.org/dl/{version}/renpy-{version}-steam.zip");
    let web_url = format!("https://www.renpy.org/dl/{version}/renpy-{version}-web.zip");

    println!("Downloading Ren'Py {version}...");
    let downloads = vec![
        Download::try_from(sdk_url.as_str()).unwrap(),
        Download::try_from(rapt_url.as_str()).unwrap(),
        Download::try_from(steam_url.as_str()).unwrap(),
        Download::try_from(web_url.as_str()).unwrap(),
    ];
    let downloader = DownloaderBuilder::new().directory(registry.clone()).build();
    downloader.download(&downloads).await;

    println!("Extracting SDK");

    let sdk_zip_path = registry.join(format!("renpy-{version}-sdk.zip"));

    let sdk_zip = fs::read(&sdk_zip_path)?;
    zip_extract::extract(Cursor::new(sdk_zip), &base_path, true)?;

    println!("Extracting RAPT");

    let rapt_zip_path = registry.join(format!("renpy-{version}-rapt.zip"));

    let rapt_zip = fs::read(&rapt_zip_path)?;
    zip_extract::extract(Cursor::new(rapt_zip), &base_path.join("rapt"), true)?;

    let steam_zip_path = registry.join(format!("renpy-{version}-steam.zip"));
    if steam_zip_path.exists() {
        println!("Extracting Steam support");

        let steam_zip = fs::read(&steam_zip_path)?;
        zip_extract::extract(Cursor::new(steam_zip), &base_path.join("lib"), true)?;
    }

    let web_zip_path = registry.join(format!("renpy-{version}-web.zip"));
    if web_zip_path.exists() {
        println!("Extracting Web support");

        let web_zip = fs::read(&web_zip_path)?;

        zip_extract::extract(Cursor::new(web_zip), &base_path.join("web"), true)?;
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
    let python_parent = python.parent().ok_or(anyhow!("Unable to get parent."))?;

    #[cfg(target_family = "windows")]
    let paths = [
        python.clone(),
        python_parent.join("pythonw.exe"),
        python_parent.join("renpy.exe"),
        python_parent.join("zsync.exe"),
        python_parent.join("zsyncmake.exe"),
        base_path.join("rapt/prototype/gradlew.exe"),
        base_path.join("rapt/project/gradlew.exe"),
    ];
    #[cfg(target_family = "unix")]
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

    let original_dir = env::current_dir()?;
    env::set_current_dir(base_path.join("rapt"))?;

    let keytool = java_home.join("bin/keytool");

    let android_keystore = Path::new("android.keystore");
    if !android_keystore.exists() {
        println!("Generating Android keystore");

        let mut cmd = Command::new(&keytool);
        cmd.args([
            "-genkey",
            "-keystore",
            "android.keystore",
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
        let status = cmd.status()?;
        if !status.success() {
            anyhow::bail!("Unable to generate Android keystore.");
        }
    }

    let bundle_keystore = Path::new("bundle.keystore");
    if !bundle_keystore.exists() {
        println!("Generating Bundle keystore (reusing Android keystore)");

        fs::copy("android.keystore", "bundle.keystore")?;
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

    env::set_var("RAPT_NO_TERMS", "1");

    let mut cmd = Command::new(&python);
    cmd.args(["-EO", "android.py", "installsdk"]);
    let status = cmd.status()?;
    if !status.success() {
        anyhow::bail!("Unable to install Android SDK.");
    }

    env::set_current_dir(original_dir)?;

    println!("Increasing Gradle RAM limit to 8Gb");
    let paths = [
        base_path.join("rapt/prototype/gradle.properties"),
        base_path.join("rapt/project/gradle.properties"),
    ];

    let re = regex::Regex::new(r"org\.gradle\.jvmargs=-Xmx(\d+)g").unwrap();
    for path in paths.iter().filter(|p| p.exists()) {
        let content = fs::read_to_string(&path)?;
        let content = re
            .replace_all(&content, "org.gradle.jvmargs=-Xmx8g")
            .to_string();
        fs::write(&path, content)?;
    }

    println!("Installing Android SDK");
    #[cfg(target_family = "windows")]
    let mut sdkmanager = base_path.join("rapt/Sdk/cmdline-tools/latest/bin/sdkmanager.exe");
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
