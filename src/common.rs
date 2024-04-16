use crate::renutil::{Instance, Local, Remote};
use anyhow::Result;
use jwalk::{ClientState, DirEntry};
use reqwest::Url;
use std::{
    fs::File,
    io::{Read, Seek, Write},
    path::PathBuf,
};
use zip::{write::FileOptions, ZipWriter};

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct Version {
    pub major: u32,
    pub minor: u32,
    pub patch: u32,
    pub hotfix: u32,
    pub nightly: bool,
}

impl Version {
    pub fn from_str(s: &str) -> Option<Self> {
        let reg = regex::Regex::new(r"^(\d+)\.(\d+)(?:\.(\d+))?(?:\.(\d+))?(\+nightly)?$").unwrap();
        match reg.captures(s) {
            Some(caps) => {
                let major = caps.get(1).unwrap().as_str().parse::<u32>().unwrap();
                let minor = caps.get(2).unwrap().as_str().parse::<u32>().unwrap();
                let patch = caps
                    .get(3)
                    .map(|m| m.as_str().parse::<u32>().unwrap())
                    .unwrap_or(0);
                let hotfix = caps
                    .get(4)
                    .map(|m| m.as_str().parse::<u32>().unwrap())
                    .unwrap_or(0);
                let nightly = caps.get(5).is_some();
                Some(Self {
                    major,
                    minor,
                    patch,
                    hotfix,
                    nightly,
                })
            }
            None => None,
        }
    }

    pub fn is_installed(&self, registry: &PathBuf) -> bool {
        registry.join(self.to_string()).exists()
    }

    pub fn to_local(&self, registry: &PathBuf) -> Result<Instance<Local>, std::io::Error> {
        if self.is_installed(registry) {
            Ok(Instance::new(self.clone()))
        } else {
            Err(std::io::Error::new(
                std::io::ErrorKind::NotFound,
                format!("Version {} is not installed.", self),
            ))
        }
    }

    pub fn to_remote(&self, registry: &PathBuf) -> Result<Instance<Remote>, std::io::Error> {
        if self.is_installed(registry) {
            Err(std::io::Error::new(
                std::io::ErrorKind::AlreadyExists,
                format!("Version {} is installed.", self),
            ))
        } else {
            Ok(Instance::new(self.clone()))
        }
    }

    pub fn sdk_url(&self) -> Result<Url> {
        match self.nightly {
            true => Url::parse(&format!(
                "https://nightly.renpy.org/{self}/renpy-{self}-sdk.zip"
            ))
            .map_err(|e| anyhow::anyhow!(e)),
            false => Url::parse(&format!(
                "https://www.renpy.org/dl/{self}/renpy-{self}-sdk.zip"
            ))
            .map_err(|e| anyhow::anyhow!(e)),
        }
    }

    pub fn rapt_url(&self) -> Result<Url> {
        match self.nightly {
            true => Url::parse(&format!(
                "https://nightly.renpy.org/{self}/renpy-{self}-rapt.zip"
            ))
            .map_err(|e| anyhow::anyhow!(e)),
            false => Url::parse(&format!(
                "https://www.renpy.org/dl/{self}/renpy-{self}-rapt.zip"
            ))
            .map_err(|e| anyhow::anyhow!(e)),
        }
    }

    pub fn steam_url(&self) -> Result<Url> {
        match self.nightly {
            true => Url::parse(&format!(
                "https://nightly.renpy.org/{self}/renpy-{self}-steam.zip"
            ))
            .map_err(|e| anyhow::anyhow!(e)),
            false => Url::parse(&format!(
                "https://www.renpy.org/dl/{self}/renpy-{self}-steam.zip"
            ))
            .map_err(|e| anyhow::anyhow!(e)),
        }
    }

    pub fn web_url(&self) -> Result<Url> {
        match self.nightly {
            true => Url::parse(&format!(
                "https://nightly.renpy.org/{self}/renpy-{self}-web.zip"
            ))
            .map_err(|e| anyhow::anyhow!(e)),
            false => Url::parse(&format!(
                "https://www.renpy.org/dl/{self}/renpy-{self}-web.zip"
            ))
            .map_err(|e| anyhow::anyhow!(e)),
        }
    }
}

pub fn zip_dir<T, C>(
    it: &mut dyn Iterator<Item = jwalk::Result<DirEntry<C>>>,
    prefix: Option<&PathBuf>,
    writer: T,
    method: zip::CompressionMethod,
) -> Result<()>
where
    T: Write + Seek,
    C: ClientState,
{
    let mut zip = ZipWriter::new(writer);
    let options = FileOptions::default()
        .compression_method(method)
        .unix_permissions(0o755);

    let mut buffer = Vec::new();
    for entry in it {
        let path = entry?.path();
        let name = match prefix {
            Some(p) => path.strip_prefix(p).unwrap(),
            None => path.as_path(),
        };

        // Write file or directory explicitly
        // Some unzip tools unzip files with directory paths correctly, some do not!
        if path.is_file() {
            // println!("adding file {path:?} as {name:?} ...");
            #[allow(deprecated)]
            zip.start_file_from_path(name, options)?;
            let mut f = File::open(path)?;

            f.read_to_end(&mut buffer)?;
            zip.write_all(&buffer)?;
            buffer.clear();
        } else if !name.as_os_str().is_empty() {
            // Only if not root! Avoids path spec / warning
            // and mapname conversion failed error on unzip
            // println!("adding dir {path:?} as {name:?} ...");
            #[allow(deprecated)]
            zip.add_directory_from_path(name, options)?;
        }
    }

    zip.finish()?;

    Ok(())
}
