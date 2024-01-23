use anyhow::{anyhow, Result};
use clap::{Parser, Subcommand};
use itertools::Itertools;
use renkit::common::Version;
use renkit::renconstruct::config::{Config, TaskOptions};
use renkit::renconstruct::tasks::{
    task_convert_images_pre, task_keystore_post, task_keystore_pre, task_notarize_post, Task,
    TaskContext,
};
use renkit::renutil::{get_registry, install, launch};
use std::collections::HashSet;
use std::fs;
use std::path::PathBuf;

#[derive(Parser)]
#[command(author, version, about, long_about = None)]
struct Cli {
    /// The path to the registry directory to use. [default: ~/.renutil]
    #[arg(short = 'r', long)]
    registry: Option<PathBuf>,
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Builds a Ren'Py project with the specified configuration.
    Build {
        input_dir: PathBuf,
        output_dir: PathBuf,
        /// The config file to use. [default: renconstruct.toml]
        #[arg(short = 'c', long = "config")]
        config_path: Option<PathBuf>,
    },
}

async fn build(
    input_dir: &PathBuf,
    output_dir: &PathBuf,
    config_path: Option<PathBuf>,
) -> Result<()> {
    // TODO: custom task support

    let config_path = config_path.unwrap_or("renconstruct.toml".into());

    if !config_path.exists() {
        return Err(anyhow!("Config file does not exist"));
    }

    let config_raw = fs::read_to_string(config_path)?;
    let config: Config = toml::from_str(config_raw.as_str())?;

    if !input_dir.exists() {
        return Err(anyhow!("Input directory does not exist"));
    }

    if !config.build.pc
        && !config.build.win
        && !config.build.linux
        && !config.build.mac
        && !config.build.web
        && !config.build.steam
        && !config.build.market
        && !config.build.android_apk
        && !config.build.android_aab
    {
        return Err(anyhow!("No build options enabled"));
    }

    if config.build.web && config.renutil.version < Version::from_str("8.2.0").unwrap() {
        return Err(anyhow!(
            "Web build support requires Ren'Py 8.2.0 or higher."
        ));
    }

    if config.build.android_aab && config.renutil.version < Version::from_str("7.5.0").unwrap() {
        return Err(anyhow!(
            "Android App Bundle build support requires Ren'Py 7.5.0 or higher."
        ));
    }

    if config.build.android_apk || config.build.android_aab {
        let has_keystore_task = config
            .tasks
            .iter()
            .find(|(_, v)| match v.options {
                TaskOptions::Keystore { .. } => v.enabled,
                _ => false,
            })
            .is_some();

        if !has_keystore_task {
            return Err(anyhow!(
                "Android build support requires a keystore task to be active."
            ));
        }
    }

    let registry = get_registry(config.renutil.registry);

    if config.options.clear_output_dir {
        println!("Clearing output directory");
        fs::remove_dir_all(output_dir)?;
    }

    fs::create_dir_all(output_dir)?;

    let active_builds = {
        let mut active_builds = HashSet::<String>::new();

        if config.build.pc {
            active_builds.insert("pc".into());
        }
        if config.build.win {
            active_builds.insert("win".into());
        }
        if config.build.linux {
            active_builds.insert("linux".into());
        }
        if config.build.mac {
            active_builds.insert("mac".into());
        }
        if config.build.web {
            active_builds.insert("web".into());
        }
        if config.build.steam {
            active_builds.insert("steam".into());
        }
        if config.build.market {
            active_builds.insert("market".into());
        }
        if config.build.android_apk {
            active_builds.insert("android_apk".into());
        }
        if config.build.android_aab {
            active_builds.insert("android_aab".into());
        }

        active_builds
    };

    let active_tasks = config
        .tasks
        .iter()
        .filter(|(_, v)| v.enabled)
        .filter(|(_, v)| (!v.on_builds.is_disjoint(&active_builds)) || v.on_builds.is_empty())
        .map(|(k, v)| {
            // TODO: handle python object instantiation here so the instance lives
            // for the entire duration of the build.
            return Task {
                name: k.clone(),
                kind: v.clone(),
            };
        })
        .collect::<Vec<_>>();

    for task in active_tasks.iter().sorted_by(|a, b| {
        a.kind
            .priorities
            .pre_build
            .cmp(&b.kind.priorities.pre_build)
    }) {
        match &task.kind.options {
            TaskOptions::Keystore(opts) => {
                println!("[Pre] Running task: {}", task.name);
                let ctx = TaskContext {
                    version: config.renutil.version.clone(),
                    input_dir: input_dir.clone(),
                    output_dir: output_dir.clone(),
                    renpy_path: registry.join(&config.renutil.version.to_string()),
                };
                task_keystore_pre(&ctx, &opts)?
            }
            TaskOptions::ConvertImages(opts) => {
                println!("[Pre] Running task: {}", task.name);
                let ctx = TaskContext {
                    version: config.renutil.version.clone(),
                    input_dir: input_dir.clone(),
                    output_dir: output_dir.clone(),
                    renpy_path: registry.join(&config.renutil.version.to_string()),
                };
                task_convert_images_pre(&ctx, &opts)?
            }
            TaskOptions::Custom(opts) => {
                println!("[Pre] Running task: {}", task.name);
                // let ctx = TaskContext {
                //     version: config.renutil.version.clone(),
                //     input_dir: input_dir.clone(),
                //     output_dir: output_dir.clone(),
                //     renpy_path: registry.join(&config.renutil.version.to_string()),
                // };
                // run pre build hook if it exists
            }
            _ => {}
        };
    }

    if !config.renutil.version.is_installed(&registry) {
        println!("Installing Ren'Py {}", config.renutil.version);

        install(
            &registry,
            &config.renutil.version,
            false,
            false,
            config.renutil.update_pickle,
        )
        .await?;
    }

    if config.build.android_apk {
        println!("Building Android APK package.");

        if config.renutil.version >= Version::from_str("7.5.0").unwrap() {
            let args = vec![
                "android_build".into(),
                input_dir.to_string_lossy().to_string(),
                "--dest".into(),
                output_dir.to_string_lossy().to_string(),
            ];

            launch(&registry, &config.renutil.version, false, false, &args)?;
        } else {
            let args = vec![
                "android_build".into(),
                input_dir.to_string_lossy().to_string(),
                "assembleRelease".into(),
                "--dest".into(),
                output_dir.to_string_lossy().to_string(),
            ];

            launch(&registry, &config.renutil.version, false, false, &args)?;
        }
    }

    if config.build.android_aab {
        println!("Building Android App Bundle package.");
        if config.renutil.version >= Version::from_str("7.5.0").unwrap() {
            let args = vec![
                "android_build".into(),
                input_dir.to_string_lossy().to_string(),
                "--bundle".into(),
                "--dest".into(),
                output_dir.to_string_lossy().to_string(),
            ];

            launch(&registry, &config.renutil.version, false, false, &args)?;
        }
    }

    // TODO: This needs testing once 8.2.0 is released.
    if config.build.web {
        println!("Building Web package.");

        let args = vec![
            "web_build".into(),
            input_dir.to_string_lossy().to_string(),
            "--dest".into(),
            output_dir.to_string_lossy().to_string(),
        ];

        launch(&registry, &config.renutil.version, false, false, &args)?;
    }

    println!("Building other packages.");
    let mut args = vec![
        "distribute".into(),
        input_dir.to_string_lossy().to_string(),
        "--destination".into(),
        output_dir.to_string_lossy().to_string(),
    ];
    if config.build.pc {
        args.push("--package".into());
        args.push("pc".into());
    }
    if config.build.win {
        args.push("--package".into());
        args.push("win".into());
    }
    if config.build.linux {
        args.push("--package".into());
        args.push("linux".into());
    }
    if config.build.mac {
        args.push("--package".into());
        args.push("mac".into());
    }
    if config.build.web {
        args.push("--package".into());
        args.push("web".into());
    }
    if config.build.steam {
        args.push("--package".into());
        args.push("steam".into());
    }
    if config.build.market {
        args.push("--package".into());
        args.push("market".into());
    }
    launch(&registry, &config.renutil.version, false, false, &args)?;

    for task in active_tasks.iter().sorted_by(|a, b| {
        a.kind
            .priorities
            .post_build
            .cmp(&b.kind.priorities.post_build)
    }) {
        match &task.kind.options {
            TaskOptions::Keystore(opts) => {
                println!("[Post] Running task: {}", task.name);
                let ctx = TaskContext {
                    version: config.renutil.version.clone(),
                    input_dir: input_dir.clone(),
                    output_dir: output_dir.clone(),
                    renpy_path: registry.join(&config.renutil.version.to_string()),
                };
                task_keystore_post(&ctx, &opts)?
            }
            TaskOptions::Notarize(opts) => {
                println!("[Post] Running task: {}", task.name);
                let ctx = TaskContext {
                    version: config.renutil.version.clone(),
                    input_dir: input_dir.clone(),
                    output_dir: output_dir.clone(),
                    renpy_path: registry.join(&config.renutil.version.to_string()),
                };
                task_notarize_post(&ctx, &opts)?
            }
            TaskOptions::Custom(opts) => {
                println!("[Post] Running task: {}", task.name);
                // let ctx = TaskContext {
                //     version: config.renutil.version.clone(),
                //     input_dir: input_dir.clone(),
                //     output_dir: output_dir.clone(),
                //     renpy_path: registry.join(&config.renutil.version.to_string()),
                // };
                // run post build hook if it exists
            }
            _ => {}
        };
    }

    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();

    match &cli.command {
        Commands::Build {
            input_dir,
            output_dir,
            config_path,
        } => build(input_dir, output_dir, config_path.clone()).await?,
    }

    Ok(())
}
