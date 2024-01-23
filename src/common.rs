use crate::renutil::{Instance, Local, Remote};
use std::path::PathBuf;

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct Version {
    pub major: u32,
    pub minor: u32,
    pub patch: u32,
    pub hotfix: u32,
}

impl Version {
    pub fn from_str(s: &str) -> Option<Self> {
        let reg = regex::Regex::new(r"^(\d+)\.(\d+)(?:\.(\d+))?(?:\.(\d+))?$").unwrap();
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
                Some(Self {
                    major,
                    minor,
                    patch,
                    hotfix,
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
}
