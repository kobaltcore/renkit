![](docs/banner.jpg "renkit logo")

# renkit

A collection of tools to help you organise and use Ren'Py instances from the command line. Especially useful for headless servers.

renkit consists of three tools:
1. `renutil` manages Ren'Py instances and takes care of installing, launching and removing them.
2. `renotize` notarizes built distributions of Ren'Py games for macOS, from any source OS.
3. `renconstruct` automates the build process for Ren'Py games start to finish.

renkit is written in Nim and compiled into standalone executables, batteries included, so it's easy to use anywhere. Currently it supports the following platforms:
- `Linux` amd64
- `macOS` amd64 / arm64
- `Windows` amd64 / i386

## Installation

### Homebrew (macOS)

```bash
brew tap kobaltcore/renkit
brew install renkit --no-quarantine
```

### wget (Linux / macOS)

```bash
wget -qO- https://github.com/kobaltcore/renkit/releases/download/v2.4.0/renkit-linux-amd64.zip | tar xz
```

### Manual (Linux / Windows / macOS)

Download the pre-built binaries for your operating system and architecture from the [releases](https://github.com/kobaltcore/renkit/releases) page and extract the resulting tar file.

After this, either add the binaries to your PATH or use them from within the download directory.

Please note that on Windows, `renotize` and `renconstruct` require the [Visual C++ 2015 Redistributable Update 3 RC](https://www.microsoft.com/en-us/download/details.aspx?id=52685) so please download and install it first.

## renutil

### List all installed versions
```bash
renutil list
```

### List all remote versions
```bash
renutil list -a
```

### Show information about a specific version
```bash
renutil show -v 7.5.0
```

### Launch the Ren'Py Launcher
```bash
renutil launch -v 7.5.0
```

### Launch a Ren'Py project directly
```bash
renutil launch -v 7.5.0 -d -a ~/my-project
```

### Install a specific version
```bash
renutil install -v 7.5.0
```

### Remove a specific version
```bash
renutil uninstall -v 7.5.0
```

### Clean up an instance after use
```bash
renutil clean -v 7.5.0
```

### Full Usage
```bash
Usage is like:
    renutil {SUBCMD} [subcommand-opts & args]
where subcommand syntaxes are as follows:

  list [optional-params]
    List all available versions of RenPy, either local or remote.
  Options:
      -n=, --n=         int     0      The number of items to show. Shows all by default.
      -a, --all         bool    false  If given, shows remote versions.
      -r=, --registry=  string  ""     The path to the registry directory to use. Defaults to ~/.renutil

  show [REQUIRED,optional-params]
    Show information about a specific version of RenPy.
  Options:
      -v=, --version=   string  REQUIRED  The version to show.
      -r=, --registry=  string  ""        The path to the registry directory to use. Defaults to ~/.renutil

  launch [REQUIRED,optional-params]
    Launch the given version of RenPy.
  Options:
      -v=, --version=   string  REQUIRED  The version to launch.
      --headless        bool    false     If given, disables audio and video drivers for headless operation.
      -d, --direct      bool    false     If given, invokes RenPy directly without the launcher project.
      -a=, --args=      string  ""        The arguments to forward to RenPy.
      -r=, --registry=  string  ""        The path to the registry directory to use. Defaults to ~/.renutil

  install [REQUIRED,optional-params]
    Install the given version of RenPy.
  Options:
      -v=, --version=   string  REQUIRED  The version to install.
      -r=, --registry=  string  ""        The path to the registry directory to use. Defaults to ~/.renutil
      -n, --no-cleanup  bool    false     If given, retains installation files.
      -f, --force       bool    false     Overwrites any existing data for this version, if it\'s already installed.

  cleanup [REQUIRED,optional-params]
    Cleans up temporary directories for the given version of RenPy.
  Options:
      -v=, --version=   string  REQUIRED  The version to clean up.
      -r=, --registry=  string  ""        The path to the registry directory to use. Defaults to ~/.renutil

  uninstall [REQUIRED,optional-params]
    Uninstalls the given version of RenPy.
  Options:
      -v=, --version=   string  REQUIRED  The version to uninstall.
      -r=, --registry=  string  ""        The path to the registry directory to use. Defaults to ~/.renutil
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
Converts the selected images in the given directories to WebP to save space on-disk. This task specifically replaces every selected file with its WebP version but does not change the file extension to ensure that all paths to assets and sprites remain the same.

This task takes a dynamic set of properties where each key is the path to a directory containing image files to be converted and its value is a table of configuration options for that particular path. That way, various paths can be converted with different options for more flexibility.

Paths are evaluated relative to the base directory of the game, i.e. `game/images/bg`. Absolute paths should not be used.

Each path may specify the following properties:
- `extensions`: The list of file extensions to use. All files with an extension in this list will be converted. Defaults to `["png", "jpg"]`.
- `recursive`: Whether to scan the given directory recursively or not. Defaults to `true`. If not recursive, will only take the images directly in the given directory.
- `lossless`: Whether to convert to lossless WebP or lossy WebP. Defaults to `true`. Lossy WebP produces smaller files but may introduce artifacts, so is better suited for things like backgrounds, while lossless WebP should be used for i.e. character sprites.

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

### Full Usage
```bash
Usage is like:
    renconstruct {SUBCMD} [subcommand-opts & args]
where subcommand syntaxes are as follows:

  build [REQUIRED,optional-params]
    Builds a RenPy project with the specified configuration.
  Options:
      -i=, --input_dir=   string  REQUIRED  The path to the RenPy project to build.
      -o=, --output_dir=  string  REQUIRED  The directory to output distributions to.
      -c=, --config=      string  REQUIRED  The path to the configuration file to use.
      -r=, --registry=    string  ""        The path to the registry directory to use. Defaults to ~/.renutil
      -v=, --version=     string  ""        The target version of RenPy for renutil. Defaults to the version specified in the config file.
```

## renotize

### Writing a config file
renotize uses a TOML file for configuration to supply the information required to sign apps for macOS. An empty template is provided in this repository under [docs/renotize.toml](docs/renotize.toml).

It consists of the following keys:
- `apple_id`: The e-Mail address belonging to the Apple ID you want to use for signing applications.
- `password`: An app-specific password generated through the [management portal](https://appleid.apple.com/account/manage) of your Apple ID.
- `identity`: The identity associated with your Developer Certificate which can be found in `Keychain Access` under the category "My Certificates". It starts with `Developer ID Application:`, however it suffices to provide the 10-character code in the title of the certificate.
- `bundle`: The internal name for your app. This is typically the reverse domain notation of your website plus your application name, i.e. `com.example.mygame`.
- `altool_extra`: An optional string that will be passed on to all `altool` runs in all commands. Useful for selecting an organization when your Apple ID belongs to multiple, for example. Typically you will not have to touch this and you can leave it empty.

### Fully notarize a freshly-generated .app bundle
```bash
renotize full_run -i ~/out/my-project.zip -c my-config.toml
```

### Full Usage
```bash
Usage is like:
    renotize {SUBCMD} [subcommand-opts & args]
where subcommand syntaxes are as follows:

  provision [optional-params]
    Utility method to provision required information for notarization using a step-by-step process.
  Options:

  unpack-app [REQUIRED,optional-params]
    Unpacks the given ZIP file to the target directory.
  Options:
      -i=, --inputFile=         string  REQUIRED  The path to the ZIP file containing the .app bundle.
      -b=, --bundleIdentifier=  string  REQUIRED  set bundleIdentifier
      -o=, --outputDir=         string  ""        The directory to extract the .app bundle to.

  sign-app [REQUIRED,optional-params]
    Signs a .app bundle with the given Developer Identity.
  Options:
      -i=, --inputFile=  string  REQUIRED  The path to the .app bundle.
      -k=, --keyFile=    string  REQUIRED  The private key generated via the 'provision' command.
      -c=, --certFile=   string  REQUIRED  The certificate file obtained via the 'provision' command.

  notarize-app [REQUIRED,optional-params]
    Notarizes a .app bundle with the given Developer Account and bundle ID.
  Options:
      -i=, --inputFile=        string  REQUIRED  The path to the .app bundle.
      -a=, --appStoreKeyFile=  string  REQUIRED  The app-store-key.json file obtained via the 'provision' command.

  pack-dmg [REQUIRED,optional-params]
    Packages a .app bundle into a .dmg file.
  Options:
      -i=, --inputFile=   string  REQUIRED  The path to the .app bundle.
      -o=, --outputFile=  string  REQUIRED  The name of the DMG file to write to.
      -v=, --volumeName=  string  ""        The name to use for the DMG volume. By default the base name of the input file.

  sign-dmg [REQUIRED,optional-params]
    Signs a .dmg file with the given Developer Identity.
  Options:
      -i=, --inputFile=  string  REQUIRED  The path to the .dmg file.
      -k=, --keyFile=    string  REQUIRED  The private key generated via the 'provision' command.
      -c=, --certFile=   string  REQUIRED  The certificate file obtained via the 'provision' command.

  notarize-dmg [REQUIRED,optional-params]
    Notarizes a .dmg file with the given Developer Account and bundle ID.
  Options:
      -i=, --inputFile=        string  REQUIRED  The path to the .dmg file.
      -a=, --appStoreKeyFile=  string  REQUIRED  The app-store-key.json file obtained via the 'provision' command.

  status [REQUIRED,optional-params]
    Checks the status of a notarization operation given its UUID.
  Options:
      -u=, --uuid=             string  REQUIRED  The UUID of the notarization operation.
      -a=, --appStoreKeyFile=  string  REQUIRED  The app-store-key.json file obtained via the 'provision' command.

  full-run [REQUIRED,optional-params]
    Fully notarize a given .app bundle, creating a signed and notarized artifact for distribution.
  Options:
      -i=, --inputFile=         string  REQUIRED  The path to the the ZIP file containing the .app bundle.
      -b=, --bundleIdentifier=  string  ""        The internal identifier of the .app bundle.
      -k=, --keyFile=           string  ""        The private key generated via the 'provision' command.
      -c=, --certFile=          string  ""        The certificate file obtained via the 'provision' command.
      -a=, --appStoreKeyFile=   string  ""        The app-store-key.json file obtained via the 'provision' command.
      -j=, --jsonBundleFile=    string  ""        The renotize.json file obtained via the 'provision' command. If this is set, the
                                                  other arguments are ignored.
```

<a href="https://www.flaticon.com/free-icons/shipping-and-delivery" title="shipping and delivery icons">Shipping and delivery icons created by Ongicon - Flaticon</a>
