![](docs/banner.jpg "renkit logo")

# renkit

A collection of tools to help you organise and use Ren'Py instances from the command line. Especially useful for headless servers.

renkit consists of three tools:
1. `renutil` manages Ren'Py instances and takes care of installing, launching and removing them.
2. `renotize` notarizes built distributions of Ren'Py games for macOS, from any source OS `renkit` supports.
3. `renconstruct` automates the build process for Ren'Py games from start to finish.

renkit is written in Rust and compiled into standalone executables, batteries included, so it's easy to use anywhere. Currently it supports the following platforms:

| OS      | amd64 | aarch64 |
|---------|-------|---------|
| Linux   | ✅     | ❌       |
| macOS   | ✅     | ✅       |
| Windows | ✅     | ❌       |

## Installation

### Automatic

`renkit` comes with several installation options for the various supported platforms. Please check out the available options for the [latest release](https://github.com/kobaltcore/renkit/releases/latest).

### Manual (Linux / Windows / macOS)

Download the pre-built binaries for your operating system and architecture for the [latest release](https://github.com/kobaltcore/renkit/releases/latest) and extract the resulting tar file.

After this, either add the binaries to your PATH or use them directly from within the download directory.

## renutil

### List installed versions
```bash
renutil list
```

### List remote versions
```bash
renutil list -o
```

### Show information about a specific version
```bash
renutil show 8.2.0
```

### Launch the Ren'Py Launcher
```bash
renutil launch 8.2.0
```

### Launch a Ren'Py project directly
```bash
renutil launch 8.2.0 -d -- ~/my-project
```

We use the double dash (`--`) to separate the arguments for Ren'Py from `renutil`'s. This way, you can even pass things like `--help` through to the underlying program without `renutil` interfering.

### Install a specific version
```bash
renutil install 8.2.0
```

### Remove a specific version
```bash
renutil uninstall 8.2.0
```

### Clean up an instance after use
```bash
renutil clean 8.2.0
```

## renconstruct

### Writing a config file
renconstruct uses a TOML file for configuration to supply the information required to complete the build process for the various supported platforms. An empty template is provided in this repository under [docs/renconstruct.toml](docs/renconstruct.toml).

It consists of the sections listed below, which govern the behavior of renconstruct itself as well as the built-in and custom tasks that may be optionally activated.

All tasks have the following shared properties:
- `enabled`: Whether the task should run or not. Defaults to `false`.
- `priorities`: A table of two optional configuration options that governs the priority of a task relative to other tasks. Higher values equate to earlier execution respective to the build stage.
  - `pre_build`: The priority of the pre-build stage of this task. Pre-build tasks run before any distributions are built. Defaults to `0`.
  - `post_build`: The priority of the post-build stage of this task. Post-build tasks run afer every distribution has been built. Defaults to `0`.
- `on_builds`: A list of build names that govern whether the task should run or not. For example, if `on_builds = ["mac"]` then the given task will only run if the `mac` build is enabled in this run of `renconstruct`.

#### `tasks.clean`
Runs the `clean` operation from `renutil` which removes temporary build artifacts from Ren'Py and additionally cleans out all APK files except for the universal one if building for Android platforms.

#### `tasks.notarize`
Notarizes the macOS artifact for distribution. Same as the configuration for `renotize` below.

- `apple_id`: The e-Mail address belonging to the Apple ID you want to use for signing applications.
- `password`: An app-specific password generated through the [management portal](https://appleid.apple.com/account/manage) of your Apple ID.
- `identity`: The identity associated with your Developer Certificate which can be found in `Keychain Access` under the category "My Certificates". It starts with `Developer ID Application:`, however it suffices to provide the 10-character code in the title of the certificate.
- `bundle`: The internal name for your app. This is typically the reverse domain notation of your website plus your application name, i.e. `com.example.mygame`.
- `altool_extra`: An optional string that will be passed on to all `altool` runs in all commands. Useful for selecting an organization when your Apple ID belongs to multiple, for example. Typically you will not have to touch this and you can leave it empty.

#### `tasks.keystore`
Overwrites the auto-generated keystore with the given one. This is useful for distributing releases via the Play Store, which requires the same keystore to be used for all builds, for example.

- `keystore_apk`: The base-64 encoded binary keystore file for the APK bundles.
- `keystore_aab`: The base-64 encoded binary keystore file for the AAB bundles.

#### `tasks.convert_images`
Converts the selected images in the given directories to WebP or AVIF to save space on-disk. This task specifically replaces every selected file with its converted version but does not change the file extension to ensure that all paths to assets and sprites remain the same.

This task takes a dynamic set of properties where each key is the path to a directory containing image files to be converted and its value is a table of configuration options for that particular path. That way, various paths can be converted with different options for more flexibility.

Paths are evaluated relative to the base directory of the game, i.e. `game/images/bg`. Absolute paths should not be used.

Each path may specify the following properties:
- `extensions`: The list of file extensions to use. All files with an extension in this list will be converted. Defaults to `["png", "jpg"]`.
- `recursive`: Whether to scan the given directory recursively or not. Defaults to `true`. If not recursive, will only take the images directly in the given directory.
- `lossless`: Whether to convert to lossless WebP or lossy WebP. Defaults to `true`. Lossy WebP produces smaller files but may introduce artifacts, so is better suited for things like backgrounds, while lossless WebP should be used for i.e. character sprites.

The image format to use may be specified at the task-level using the `format` key, which may be either `webp` (default) or `avif`. Do note that AVIF is only supported in Ren'Py `>=8.1.0`.

#### `build`
Specifies which distributions to build. Each of these keys may have a value of `true` or `false`.

- `pc`: Build the Windows/Linux distribution
- `win`: Build the Windows distribution
- `linux`: Build the Linux distribution
- `mac`: Build the macOS distribution
- `web`: Build the Web distribution (only on Ren'Py `>=7.3.0`)
- `steam`: Build the Steam distribution
- `market`: Build the external marketplace distribution (i.e. Itch.io)
- `android_apk`: Build the Android distribution as an APK
- `android_aab`: Build the Android distribution as an AAB

#### `options`
Various `renconstruct`-specific options.

- `clear_output_dir`: Whether to clear the output directory on invocation or not. Useful for repeated runs where you want to persist previous results. Defaults to `false`.
- `tasks`: The path to a directory containing custom Python task definitions. Only active if Python support is enabled. Defaults to `null`.

#### `renutil`
Options to pass to `renutil`.

- `version`: The version of Ren'Py to use while building the distributions.
- `registry`: The path where `renutil` data is stored. Mostly useful for CI environments.

### Custom Tasks
`renconstruct` supports the addition of custom tasks which can run at any point in the build process to tweak config settings, modify files, convert files between formats, rename files and folders on disk and many other things.

To make itself extendable, `renconstruct` uses Python to allow users to create their own custom tasks. This is a fully optional feature as it relies on Python being installed on the system where it is invoked. Please note that `renconstruct` does not ship with its own Python interpreter!

On startup, it will attempt to find the Python version available in the current shell. If it is successful, Python support will be enabled and custom tasks can be loaded. If it fails, Python support will be disabled and only built-in tasks will be available. If you want to override `renconstruct`'s Python selection, you may supply the path to your `libpython` shared library via the environment variable `RC_LIBPYTHON`, which will take precedence over its internal Python search locations.

With enabled Python support, the `options.tasks` configuration option will be used to scan the directory given there for `.py` files. All tasks in all Python files within this directory and any of its subdirectories will be loaded into `renconstruct` and will be available to configure via the config file. Multiple tasks may be present in a single Python file.

To create a custom task, create a class with the suffix `Task` (case sensitive):
```python
class ChangeFileTask:
    def __init__(self, config, input_dir, output_dir):
        self.config = config
        self.input_dir = input_dir
        self.output_dir = output_dir

    @classmethod
    def validate_config(cls, config):
        return config

    def pre_build(self):
        print("pre-build")

    def post_build(self):
        print("post-build")
```

Tasks are duck-typed, meaning that they do not need to inherit from a base class, so long as they conform to `renconstruct`'s interface.

This interface consists of three methods and the constructor. The `__init__` method *must* take these three arguments:
- `config`: A dict of config values which represents the parsed and validated `renconstruct.toml` file.
- `input_dir`: A string representing the path to the input directory of the build process.
- `output_dir`: A string representing the path to the output directory of the build process.

You may do any kind of additional setup work in the constructor that your task requires.

#### `validate_config`
A class method that is called before the task is instantiated to validate its own section of the config file. Every custom task will have its own configuration options which are of arbitrary nature and can thus only be validated by the task itself. The name of the custom config section is derived from the class name by removing the `Task` suffix and converting the rest of the name to snake case. In the example above, `ChangeFileTask` would turn into the config section `tasks.change_file`.

Custom tasks share all of the common properties explained at the start of this section but may otherwise contain arbitrary keys and values.

#### `pre_build`
This is an optional method that, if given, will cause the custom task to execute it during the pre-build stage.

#### `post_build`
This is an optional method that, if given, will cause the custom task to execute it during the post-build stage.

### Build a set of distributions
```bash
renconstruct build -i ~/my-project -o out/ -c my-config.toml
```

## renotize

### Acquiring notarization certificates
renotize requires a few pieces of information to be able to notarize your application. These are:
- `bundle_identifier`: The internal name for your app. This is typically the reverse domain notation of your website plus your application name, i.e. `com.example.mygame`.
- `key_file`: The path to the private key file for your Developer Certificate. This is typically a `.pem` file.
- `cert_file`: The path to the public certificate file for your Developer Certificate. This is typically a `.cer` file.
- `app_store_key_file`: The path to the combined key file for your App Store connection. This is typically a `.json` file.
- `json_bundle_file`: `renotize`'s custom certificate format which bundles the above three certificates into one file for easier consumption by the program.

It is required to either supply `key_file`, `cert_file` and `app_store_key_file` **or** `json_bundle_file`. If you supply the latter, the former will be ignored.

`renotize` provides a `provision` command which will guide you through the process of acquiring the required certificates step by step. It will also generate a `renotize.json` file which you can then pass to `renotize` as the `json_bundle_file` parameter.

> <picture>
>   <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/Mqxx/GitHub-Markdown/main/blockquotes/badge/light-theme/info.svg">
>   <img alt="Info" src="https://raw.githubusercontent.com/Mqxx/GitHub-Markdown/main/blockquotes/badge/dark-theme/info.svg">
> </picture><br>
>
> Note that for the provisioning process to work, your shell must have access to the `openssl` command.

### Fully notarize a freshly-generated .app bundle
```bash
renotize full-run -i ~/out/my-project.zip -b com.example.mygame -k certificates/private-key.pem -c certificates/developerID_application.cer -a certificates/app-store-key.json
# alternatively, using the combined json bundle
renotize full-run -i ~/out/my-project.zip -b com.example.mygame -j certificates/renotize.json
```

### Verify Notarization
For an App bundle:
```bash
spctl -a -t exec -vv MyGame.dmg
```

For a DMG:
```bash
spctl -a -t open -vvv --context context:primary-signature MyGame.dmg
```

<a href="https://www.flaticon.com/free-icons/shipping-and-delivery" title="shipping and delivery icons">Shipping and delivery icons created by Ongicon - Flaticon</a>
