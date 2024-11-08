use crate::renutil::{Instance, Local, Remote};
use anyhow::Result;
use reqwest::Url;
use std::path::Path;

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct Version {
    pub major: u32,
    pub minor: u32,
    pub patch: u32,
    pub hotfix: u32,
    pub nightly: bool,
}

impl Version {
    pub fn from_str(s: &str) -> Result<Self> {
        let reg = regex::Regex::new(r"^(\d+)\.(\d+)(?:\.(\d+))?(?:\.(\d+))?(\+nightly)?$").unwrap();
        match reg.captures(s) {
            Some(caps) => {
                let major = caps.get(1).unwrap().as_str().parse::<u32>()?;
                let minor = caps.get(2).unwrap().as_str().parse::<u32>()?;
                let patch = match caps.get(3) {
                    Some(m) => m.as_str().parse::<u32>()?,
                    None => 0,
                };
                let hotfix = match caps.get(4) {
                    Some(m) => m.as_str().parse::<u32>()?,
                    None => 0,
                };
                let nightly = caps.get(5).is_some();
                Ok(Self {
                    major,
                    minor,
                    patch,
                    hotfix,
                    nightly,
                })
            }
            None => Err(anyhow::anyhow!("Invalid version string.")),
        }
    }

    #[must_use]
    pub fn is_installed(&self, registry: &Path) -> bool {
        registry.join(self.to_string()).exists()
    }

    pub fn to_local(&self, registry: &Path) -> Result<Instance<Local>, std::io::Error> {
        if self.is_installed(registry) {
            Ok(Instance::new(self.clone()))
        } else {
            Err(std::io::Error::new(
                std::io::ErrorKind::NotFound,
                format!("Version {self} is not installed."),
            ))
        }
    }

    pub fn to_remote(&self, registry: &Path) -> Result<Instance<Remote>, std::io::Error> {
        if self.is_installed(registry) {
            Err(std::io::Error::new(
                std::io::ErrorKind::AlreadyExists,
                format!("Version {self} is installed."),
            ))
        } else {
            Ok(Instance::new(self.clone()))
        }
    }

    pub fn sdk_url(&self) -> Result<Url> {
        let supports_arm = self >= &Version::from_str("7.5.0").unwrap();

        if self.nightly {
            if supports_arm {
                return Url::parse(&format!(
                    "https://nightly.renpy.org/{self}/renpy-{self}-sdkarm.tar.bz2"
                ))
                .map_err(|e| anyhow::anyhow!(e));
            }
            Url::parse(&format!(
                "https://nightly.renpy.org/{self}/renpy-{self}-sdk.zip"
            ))
            .map_err(|e| anyhow::anyhow!(e))
        } else {
            if supports_arm {
                return Url::parse(&format!(
                    "https://www.renpy.org/dl/{self}/renpy-{self}-sdkarm.tar.bz2"
                ))
                .map_err(|e| anyhow::anyhow!(e));
            }
            Url::parse(&format!(
                "https://www.renpy.org/dl/{self}/renpy-{self}-sdk.zip"
            ))
            .map_err(|e| anyhow::anyhow!(e))
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

#[cfg(test)]
mod tests {
    #[test]
    fn version_links() {
        let v = super::Version::from_str("8.3.0").unwrap();
        assert_eq!(
            v.sdk_url().unwrap(),
            "https://www.renpy.org/dl/8.3.0/renpy-8.3.0-sdk.zip"
                .parse()
                .unwrap()
        );
        assert_eq!(
            v.rapt_url().unwrap(),
            "https://www.renpy.org/dl/8.3.0/renpy-8.3.0-rapt.zip"
                .parse()
                .unwrap()
        );
        assert_eq!(
            v.steam_url().unwrap(),
            "https://www.renpy.org/dl/8.3.0/renpy-8.3.0-steam.zip"
                .parse()
                .unwrap()
        );
        assert_eq!(
            v.web_url().unwrap(),
            "https://www.renpy.org/dl/8.3.0/renpy-8.3.0-web.zip"
                .parse()
                .unwrap()
        );

        let v = super::Version::from_str("8.3.0.24041601+nightly").unwrap();
        assert_eq!(
            v.sdk_url().unwrap(),
            "https://nightly.renpy.org/8.3.0.24041601+nightly/renpy-8.3.0.24041601+nightly-sdk.zip"
                .parse()
                .unwrap()
        );
        assert_eq!(
            v.rapt_url().unwrap(),
            "https://nightly.renpy.org/8.3.0.24041601+nightly/renpy-8.3.0.24041601+nightly-rapt.zip"
                .parse()
                .unwrap()
        );
        assert_eq!(
            v.steam_url().unwrap(),
            "https://nightly.renpy.org/8.3.0.24041601+nightly/renpy-8.3.0.24041601+nightly-steam.zip"
                .parse()
                .unwrap()
        );
        assert_eq!(
            v.web_url().unwrap(),
            "https://nightly.renpy.org/8.3.0.24041601+nightly/renpy-8.3.0.24041601+nightly-web.zip"
                .parse()
                .unwrap()
        );
    }

    #[test]
    fn version_parsing() {
        let v = super::Version::from_str("7.4.0").unwrap();
        assert_eq!(v.major, 7);
        assert_eq!(v.minor, 4);
        assert_eq!(v.patch, 0);
        assert_eq!(v.hotfix, 0);
        assert!(!v.nightly);

        let v = super::Version::from_str("8.3.0.24041601+nightly").unwrap();
        assert_eq!(v.major, 8);
        assert_eq!(v.minor, 3);
        assert_eq!(v.patch, 0);
        assert_eq!(v.hotfix, 24041601);
        assert!(v.nightly);

        assert!(
            super::Version::from_str("999999999999999999999999999999.3.0.24041601+nightly")
                .is_err()
        );
        assert!(
            super::Version::from_str("8.999999999999999999999999999999.0.24041601+nightly")
                .is_err()
        );
        assert!(
            super::Version::from_str("8.3.999999999999999999999999999999.24041601+nightly")
                .is_err()
        );

        assert!(super::Version::from_str("bad-version-string").is_err());
    }
}
