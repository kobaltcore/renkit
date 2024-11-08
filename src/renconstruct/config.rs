use crate::version::Version;
use rustpython_vm::PyObjectRef;
use serde::{Deserialize, Deserializer, Serialize};
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
        Ok(version) => Ok(version),
        Err(e) => Err(serde::de::Error::custom(format!(
            "Invalid version: {buf} - {e}"
        ))),
    }
}

fn default_avif_quality() -> f32 {
    85.0
}

fn default_webp_quality() -> f32 {
    90.0
}

fn default_as_true() -> bool {
    true
}

fn default_convert_images_extensions() -> Vec<String> {
    vec!["png".into(), "jpg".into(), "jpeg".into()]
}

#[derive(Debug, Clone, Deserialize, Default)]
pub enum ImageFormat {
    #[default]
    #[serde(alias = "webp")]
    WebP,
    #[serde(alias = "avif")]
    Avif,
    #[serde(alias = "hybrid-webp-avif")]
    HybridWebPAvif,
    // #[serde(alias = "jpeg-xl")]
    // JpegXl,
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
pub struct LintOptions {}

#[derive(Debug, Clone, Deserialize)]
pub struct KeystoreOptions {
    pub keystore_apk: String,
    pub keystore_aab: String,
    pub alias: Option<String>,
    pub password: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct ConvertImagesOptions {
    pub format: ImageFormat,
    #[serde(default = "default_avif_quality")]
    pub avif_quality: f32,
    #[serde(default = "default_webp_quality")]
    pub webp_quality: f32,
    pub paths: HashMap<String, ConvertImagesPathConfig>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct NotarizeOptions {
    pub bundle_id: String,
    pub key_file: PathBuf,
    pub cert_file: PathBuf,
    pub app_store_key_file: PathBuf,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(untagged)]
pub enum CustomOptionValue {
    String(String),
    Bool(bool),
    Int(usize),
    Float(f64),
    Array(Vec<CustomOptionValue>),
    Dict(HashMap<String, CustomOptionValue>),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CustomOptions {
    #[serde(skip)]
    pub task_handle_pre: Option<PyObjectRef>,
    #[serde(skip)]
    pub task_handle_post: Option<PyObjectRef>,
    #[serde(flatten)]
    pub options: HashMap<String, CustomOptionValue>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "type")]
pub enum TaskOptions {
    #[serde(rename = "lint")]
    Lint(LintOptions),
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

#[derive(Debug, Deserialize, Hash, PartialEq, Eq)]
#[serde(untagged)]
pub enum BuildOption {
    Known(KnownBuildOption),
    Custom(String),
}

#[derive(Debug, Deserialize, Hash, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum KnownBuildOption {
    Pc,
    Win,
    Linux,
    Mac,
    Web,
    Steam,
    Market,
    AndroidApk,
    AndroidAab,
}

#[derive(Debug, Deserialize)]
pub struct Config {
    pub builds: HashMap<BuildOption, bool>,
    #[serde(default)]
    pub options: RenconstructOptions,
    pub renutil: RenutilOptions,
    pub tasks: HashMap<String, GeneralTaskOptions>,
}

#[derive(Debug, Deserialize, Default)]
pub struct RenconstructOptions {
    pub task_dir: Option<PathBuf>,
    #[serde(default)]
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
