use crate::common::Version;
use serde::{Deserialize, Deserializer};
use std::{
    collections::{HashMap, HashSet},
    path::PathBuf,
};

fn deserialize_version<'de, D>(deserializer: D) -> Result<Version, D::Error>
where
    D: Deserializer<'de>,
{
    let buf = String::deserialize(deserializer)?;
    match Version::from_str(&buf) {
        Some(version) => Ok(version),
        None => Err(serde::de::Error::custom(format!(
            "Invalid version: {}",
            buf
        ))),
    }
}

fn default_as_true() -> bool {
    true
}

fn default_convert_images_extensions() -> Vec<String> {
    vec!["png".into(), "jpg".into(), "jpeg".into()]
}

#[derive(Debug, Clone, Deserialize)]
pub enum ImageFormat {
    #[serde(alias = "webp")]
    WebP,
    #[serde(alias = "avif")]
    Avif,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ConvertImagesPathConfig {
    #[serde(default = "default_as_true")]
    pub recursive: bool,
    #[serde(default = "default_as_true")]
    pub lossless: bool,
    #[serde(default = "default_convert_images_extensions")]
    pub extensions: Vec<String>,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct PriorityOptions {
    #[serde(default)]
    pub pre_build: usize,
    #[serde(default)]
    pub post_build: usize,
}

#[derive(Debug, Clone, Deserialize)]
pub struct KeystoreOptions {
    pub keystore_apk: String,
    pub keystore_aab: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ConvertImagesOptions {
    pub format: ImageFormat,
    pub paths: HashMap<String, ConvertImagesPathConfig>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct NotarizeOptions {
    pub bundle_id: String,
    pub key_file: PathBuf,
    pub cert_file: PathBuf,
    pub app_store_key_file: PathBuf,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CustomOptions {
    pub options: HashMap<String, String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "type")]
pub enum TaskOptions {
    #[serde(rename = "keystore")]
    Keystore(KeystoreOptions),
    #[serde(rename = "convert_images")]
    ConvertImages(ConvertImagesOptions),
    #[serde(rename = "notarize")]
    Notarize(NotarizeOptions),
    #[serde(rename = "custom")]
    Custom(CustomOptions),
}

#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "type")]
pub struct GeneralTaskOptions {
    pub enabled: bool,
    #[serde(default)]
    pub on_builds: HashSet<String>,
    #[serde(default)]
    pub priorities: PriorityOptions,
    #[serde(flatten)]
    pub options: TaskOptions,
}

#[derive(Debug, Deserialize)]
pub struct Config {
    pub build: BuildOptions,
    pub options: RenconstructOptions,
    pub renutil: RenutilOptions,
    pub tasks: HashMap<String, GeneralTaskOptions>,
}

#[derive(Debug, Deserialize)]
pub struct RenconstructOptions {
    pub task_dir: Option<PathBuf>,
    pub clear_output_dir: bool,
}

#[derive(Debug, Deserialize)]
pub struct RenutilOptions {
    #[serde(deserialize_with = "deserialize_version")]
    pub version: Version,
    pub registry: Option<PathBuf>,
    #[serde(default)]
    pub update_pickle: bool,
}

#[derive(Debug, Deserialize)]
pub struct BuildOptions {
    #[serde(default)]
    pub pc: bool,
    #[serde(default)]
    pub win: bool,
    #[serde(default)]
    pub linux: bool,
    #[serde(default)]
    pub mac: bool,
    #[serde(default)]
    pub web: bool,
    #[serde(default)]
    pub steam: bool,
    #[serde(default)]
    pub market: bool,
    #[serde(default)]
    pub android_apk: bool,
    #[serde(default)]
    pub android_aab: bool,
}
