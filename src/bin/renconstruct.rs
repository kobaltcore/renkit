use anyhow::{anyhow, Result};
use clap::{Parser, Subcommand};
use itertools::Itertools;
use jwalk::WalkDir;
use renkit::renconstruct::config::{Config, CustomOptionValue, TaskOptions};
use renkit::renconstruct::tasks::{
    task_convert_images_pre, task_keystore_post, task_keystore_pre, task_lint_pre,
    task_notarize_post, Task, TaskContext,
};
use renkit::renutil::{get_registry, install, launch};
use renkit::version::Version;
use rustpython::vm::builtins::{PyList, PyStr};
use rustpython::vm::convert::ToPyObject;
use rustpython::vm::function::FuncArgs;
use rustpython_vm::builtins::PyDict;
use rustpython_vm::{import, Interpreter, PyObjectRef, VirtualMachine};
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

fn to_pyobject(opt: &CustomOptionValue, vm: &VirtualMachine) -> PyObjectRef {
    match opt {
        CustomOptionValue::String(val) => PyStr::from(val.clone()).to_pyobject(vm),
        CustomOptionValue::Bool(val) => val.to_pyobject(vm),
        CustomOptionValue::Int(val) => val.to_pyobject(vm),
        CustomOptionValue::Float(val) => val.to_pyobject(vm),
        CustomOptionValue::Array(val) => {
            let val: Vec<PyObjectRef> = val.iter().map(|e| to_pyobject(e, vm)).collect();
            PyList::from(val).to_pyobject(vm)
        }
    }
}

#[tokio::main]
async fn build(
    vm: &VirtualMachine,
    input_dir: &PathBuf,
    output_dir: &PathBuf,
    config_path: Option<PathBuf>,
    cli_registry: Option<PathBuf>,
) -> Result<()> {
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

    if config.options.clear_output_dir {
        println!("Clearing output directory");
        if output_dir.exists() {
            fs::remove_dir_all(output_dir)?;
        }
    }

    fs::create_dir_all(output_dir)?;

    let registry = if cli_registry.is_some() {
        get_registry(cli_registry)
    } else {
        get_registry(config.renutil.registry)
    };

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

    let mut active_builds = {
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

    let mut tasks = config.tasks;

    if let Some(task_dir) = config.options.task_dir {
        if !task_dir.exists() {
            return Err(anyhow!("Task directory does not exist"));
        }

        println!("Loading custom tasks from {}", task_dir.to_string_lossy());

        vm.insert_sys_path(vm.new_pyobj(task_dir.to_str())).unwrap();

        let mut paths = vec![];

        for entry in WalkDir::new(&task_dir) {
            match entry {
                Ok(entry) => {
                    let path = entry.path();
                    if path.is_dir() {
                        continue;
                    }
                    match path.extension() {
                        Some(ext) => {
                            if ext != "py" {
                                continue;
                            }
                            paths.push(PyStr::from(path.to_string_lossy()).to_pyobject(vm));
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

        let paths = PyList::from(paths).to_pyobject(vm);

        let rc_dispatch = match import::import_frozen(vm, "rc_dispatch") {
            Ok(res) => res,
            Err(e) => {
                vm.print_exception(e);
                panic!();
            }
        };

        let dispatch = rc_dispatch.get_attr("dispatch", vm).unwrap();

        let result = dispatch
            .call_with_args(FuncArgs::from(vec![paths]), vm)
            .unwrap();
        let result = result.to_sequence(vm).list(vm).unwrap();

        for val in result.borrow_vec().iter() {
            let name_slug = val
                .get_item("name_slug", vm)
                .unwrap()
                .str(vm)
                .unwrap()
                .to_string();
            let class = val.get_item("class", vm).unwrap();

            match tasks
                .iter_mut()
                .filter(|(name, _)| **name == name_slug)
                .next()
            {
                Some((_, opts)) => {
                    let options = match &opts.options {
                        TaskOptions::Custom(opts) => {
                            let py_dict = PyDict::new_ref(&vm.ctx);
                            for (k, v) in &opts.options {
                                py_dict.set_item(k, to_pyobject(v, vm), vm).unwrap()
                            }
                            py_dict.to_pyobject(vm)
                        }
                        _ => panic!("Task type mismatch."),
                    };

                    let class_new = class.get_attr("__new__", vm).unwrap();
                    let instance = class_new.call((class,), vm).unwrap();
                    let instance_init = instance.get_attr("__init__", vm).unwrap();
                    let input_dir_py = PyStr::from(input_dir.to_string_lossy()).to_pyobject(vm);
                    let output_dir_py = PyStr::from(output_dir.to_string_lossy()).to_pyobject(vm);
                    if let Err(e) = instance_init.call((options, input_dir_py, output_dir_py), vm) {
                        vm.print_exception(e);
                        panic!();
                    }

                    match &mut opts.options {
                        TaskOptions::Custom(opts) => {
                            if instance.has_attr("pre_build", vm).unwrap() {
                                opts.task_handle_pre =
                                    Some(instance.get_attr("pre_build", vm).unwrap());
                            }
                            if instance.has_attr("post_build", vm).unwrap() {
                                opts.task_handle_post =
                                    Some(instance.get_attr("post_build", vm).unwrap());
                            }
                        }
                        _ => panic!("Task type mismatch."),
                    };
                }
                None => {}
            }
        }
    }

    let active_tasks = tasks
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
        let registry = registry.clone();
        match &task.kind.options {
            TaskOptions::Notarize(_) => {}
            TaskOptions::Lint(opts) => {
                let ctx = TaskContext {
                    version: config.renutil.version.clone(),
                    input_dir: input_dir.clone(),
                    output_dir: output_dir.clone(),
                    renpy_path: registry.join(&config.renutil.version.to_string()),
                    registry,
                };
                task_lint_pre(&ctx, opts)?
            }
            TaskOptions::Keystore(opts) => {
                println!("[Pre] Running task: {}", task.name);
                let ctx = TaskContext {
                    version: config.renutil.version.clone(),
                    input_dir: input_dir.clone(),
                    output_dir: output_dir.clone(),
                    renpy_path: registry.join(&config.renutil.version.to_string()),
                    registry,
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
                    registry,
                };
                task_convert_images_pre(&ctx, &opts)?
            }
            TaskOptions::Custom(opts) => {
                println!("[Pre] Running task: {}", task.name);
                if let Some(handler) = &opts.task_handle_pre {
                    handler.call((), vm).unwrap();
                }
            }
        };
    }

    if config.build.android_apk {
        println!("Building Android APK package.");
        active_builds.remove("android_apk");
        if config.renutil.version >= Version::from_str("7.5.0").unwrap() {
            let args = vec![
                "android_build".into(),
                input_dir.to_string_lossy().to_string(),
                "--dest".into(),
                output_dir.to_string_lossy().to_string(),
            ];

            launch(
                &registry,
                &config.renutil.version,
                false,
                false,
                &args,
                true,
                false,
                None,
            )?;
        } else {
            let args = vec![
                "android_build".into(),
                input_dir.to_string_lossy().to_string(),
                "assembleRelease".into(),
                "--dest".into(),
                output_dir.to_string_lossy().to_string(),
            ];

            launch(
                &registry,
                &config.renutil.version,
                false,
                false,
                &args,
                true,
                false,
                None,
            )?;
        }
    }

    if config.build.android_aab {
        println!("Building Android App Bundle package.");
        active_builds.remove("android_aab");
        if config.renutil.version >= Version::from_str("7.5.0").unwrap() {
            let args = vec![
                "android_build".into(),
                input_dir.to_string_lossy().to_string(),
                "--bundle".into(),
                "--dest".into(),
                output_dir.to_string_lossy().to_string(),
            ];

            launch(
                &registry,
                &config.renutil.version,
                false,
                false,
                &args,
                true,
                false,
                None,
            )?;
        }
    }

    if config.build.web {
        println!("Building Web package.");
        active_builds.remove("web");

        // The web build clears the destination directory when it runs, which is undesirable
        // As such, we contain it in a subfolder and move it out afterwards.
        let web_dir = output_dir.join("web");
        fs::create_dir_all(&web_dir)?;

        let args = vec![
            "web_build".into(),
            input_dir.to_string_lossy().to_string(),
            "--dest".into(),
            web_dir.to_string_lossy().to_string(),
        ];

        launch(
            &registry,
            &config.renutil.version,
            false,
            false,
            &args,
            true,
            false,
            None,
        )?;

        fs::remove_dir_all(web_dir)?;
    }

    if active_builds.len() > 0 {
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
        if config.build.steam {
            args.push("--package".into());
            args.push("steam".into());
        }
        if config.build.market {
            args.push("--package".into());
            args.push("market".into());
        }

        launch(
            &registry,
            &config.renutil.version,
            false,
            false,
            &args,
            true,
            false,
            None,
        )?;
    }

    for task in active_tasks.iter().sorted_by(|a, b| {
        a.kind
            .priorities
            .post_build
            .cmp(&b.kind.priorities.post_build)
    }) {
        let registry = registry.clone();
        match &task.kind.options {
            TaskOptions::Keystore(opts) => {
                println!("[Post] Running task: {}", task.name);
                let ctx = TaskContext {
                    version: config.renutil.version.clone(),
                    input_dir: input_dir.clone(),
                    output_dir: output_dir.clone(),
                    renpy_path: registry.join(&config.renutil.version.to_string()),
                    registry,
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
                    registry,
                };
                task_notarize_post(&ctx, &opts)?
            }
            TaskOptions::Custom(opts) => {
                println!("[Post] Running task: {}", task.name);
                if let Some(handler) = &opts.task_handle_post {
                    handler.call((), vm).unwrap();
                }
            }
            _ => {}
        };
    }

    Ok(())
}

fn main() -> Result<()> {
    let cli = Cli::parse();

    Interpreter::with_init(Default::default(), |vm| {
        vm.add_native_modules(rustpython_stdlib::get_module_inits());
        vm.add_frozen(rustpython_pylib::FROZEN_STDLIB);
        vm.add_frozen(rustpython_vm::py_freeze!(dir = "./py"));
    })
    .enter(|vm| match &cli.command {
        Commands::Build {
            input_dir,
            output_dir,
            config_path,
        } => build(vm, input_dir, output_dir, config_path.clone(), cli.registry),
    })
}
