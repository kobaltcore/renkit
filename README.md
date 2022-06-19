![](docs/banner.jpg "renkit logo")

# renkit

A collection of tools to help you organise and use Ren'Py instances from the command line. Especially useful for headless servers.

renkit consists of three tools:
1. `renutil` manages Ren'Py instances and takes care of installing, launching and removing them.
2. `renotize` is a macOS-exclusive tool which notarizes built distributions of Ren'Py games for macOS.
3. `renconstruct` automates the build process for Ren'Py games start to finish.

renkit is written in Nim and compiled into standalone executables, so it's easy to use anywhere. Currently it supports the following platforms:
- `Linux` amd64
- `macOS` amd64 / arm64
- `Windows` amd64 / i386

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
      -f, --force       bool    false     set force

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

It consists of the following sections:

#### `tasks.clean`
Runs the `clean` operation from `renutil` which removes temporary build artifacts from Ren'Py and additionally cleans out all APK files except for the universal one if building for Android platforms.

- `enabled`: Whether the task should run or not. Defaults to `false`.

#### `tasks.notarize`
Notarizes the macOS artifact for distribution. Same as the configuration for `renotize` below.

- `enabled`: Whether the task should run or not. Defaults to `false`.
- `apple_id`: The e-Mail address belonging to the Apple ID you want to use for signing applications.
- `password`: An app-specific password generated through the [management portal](https://appleid.apple.com/account/manage) of your Apple ID.
- `identity`: The identity associated with your Developer Certificate which can be found in `Keychain Access` under the category "My Certificates". It starts with `Developer ID Application:`, however it suffices to provide the 10-character code in the title of the certificate.
- `bundle`: The internal name for your app. This is typically the reverse domain notation of your website plus your application name, i.e. `com.example.mygame`.
- `altool_extra`: An optional string that will be passed on to all `altool` runs in all commands. Useful for selecting an organization when your Apple ID belongs to multiple, for example. Typically you will not have to touch this and you can leave it empty.

#### `tasks.keystore`
Overwrites the auto-generated keystore with the given one. This is useful for distributing releases via the Play Store, which requires the same keystore to be used for all builds, for example.

- `enabled`: Whether the task should run or not. Defaults to `false`.
- `keystore_apk`: The base-64 encoded binary keystore file for the APK bundles.
- `keystore_aab`: The base-64 encoded binary keystore file for the AAB bundles.

#### `tasks.convert_images`
Converts the selected images in the given directories to WebP to save space on-disk. This task specifically replaces every selected file with its WebP version but does not change the file extension to ensure that all paths to assets and sprites remain the same.

- `enabled`: Whether the task should run or not. Defaults to `false`.

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

#### `renutil`
Options to pass to `renutil`.

- `version`: The version of Ren'Py to use while building the distributions.
- `registry`: The path where `renutil` data is stored. Mostly useful for CI environments.

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
```

## renotize

### Writing a config file
renotize uses a TOML file for configuration to supply the information required to sign apps on macOS. An empty template is provided in this repository under [docs/renotize.toml](docs/renotize.toml).

It consists of the following keys:
- `apple_id`: The e-Mail address belonging to the Apple ID you want to use for signing applications.
- `password`: An app-specific password generated through the [management portal](https://appleid.apple.com/account/manage) of your Apple ID.
- `identity`: The identity associated with your Developer Certificate which can be found in `Keychain Access` under the category "My Certificates". It starts with `Developer ID Application:`, however it suffices to provide the 10-character code in the title of the certificate.
- `bundle`: The internal name for your app. This is typically the reverse domain notation of your website plus your application name, i.e. `com.example.mygame`.
- `altool_extra`: An optional string that will be passed on to all `altool` runs in all commands. Useful for selecting an organization when your Apple ID belongs to multiple, for example. Typically you will not have to touch this and you can leave it empty.

### Full Usage
```bash
Usage is like:
    renotize {SUBCMD} [subcommand-opts & args]
where subcommand syntaxes are as follows:

  unpack_app [REQUIRED,optional-params]
    Unpacks the given ZIP file to the target directory.
  Options:
      -i=, --input_file=  string  REQUIRED  The path to the ZIP file containing the .app bundle.
      -o=, --output_dir=  string  ""        The directory to extract the .app bundle to.

  sign_app [REQUIRED,optional-params]
    Signs a .app bundle with the given Developer Identity.
  Options:
      -i=, --input_file=  string  REQUIRED  The path to the .app bundle.
      --identity=         string  REQUIRED  The ID of your developer certificate.

  notarize_app [REQUIRED,optional-params]
    Notarizes a .app bundle with the given Developer Account and bundle ID.
  Options:
      -i=, --input_file=  string  REQUIRED  The path to the .app bundle.
      -b=, --bundle_id=   string  REQUIRED  The name/ID to use for the notarized bundle.
      -a=, --apple_id=    string  REQUIRED  Your Apple ID, generally your e-Mail.
      -p=, --password=    string  REQUIRED  Your app-specific password.
      --altool_extra=     string  ""        Extra arguments for altool.

  staple_app [REQUIRED,optional-params]
    Staples a notarization certificate to a .app bundle.
  Options:
      -i=, --input_file=  string  REQUIRED  The path to the .app bundle.

  pack_dmg [REQUIRED,optional-params]
    Packages a .app bundle into a .dmg file.
  Options:
      -i=, --input_file=   string  REQUIRED  The path to the .app bundle.
      -o=, --output_file=  string  REQUIRED  The name of the DMG file to write to.
      -v=, --volume_name=  string  ""        The name to use for the DMG volume. By default the base name of the input file.

  sign_dmg [REQUIRED,optional-params]
    Signs a .dmg file with the given Developer Identity.
  Options:
      -i=, --input_file=  string  REQUIRED  The path to the .dmg file.
      --identity=         string  REQUIRED  The ID of your developer certificate.

  notarize_dmg [REQUIRED,optional-params]
    Notarizes a .dmg file with the given Developer Account and bundle ID.
  Options:
      -i=, --input_file=  string  REQUIRED  The path to the .dmg file.
      -b=, --bundle_id=   string  REQUIRED  The name/ID to use for the notarized bundle.
      -a=, --apple_id=    string  REQUIRED  Your Apple ID, generally your e-Mail.
      -p=, --password=    string  REQUIRED  Your app-specific password.
      --altool_extra=     string  ""        Extra arguments for altool.

  staple_dmg [REQUIRED,optional-params]
    Staples a notarization certificate to a .dmg file.
  Options:
      -i=, --input_file=  string  REQUIRED  The path to the .dmg file.

  status [REQUIRED,optional-params]
    Checks the status of a notarization operation given its UUID.
  Options:
      -u=, --uuid=      string  REQUIRED  The UUID of the notarization operation.
      -a=, --apple_id=  string  REQUIRED  Your Apple ID, generally your e-Mail.
      -p=, --password=  string  REQUIRED  Your app-specific password.
      --altool_extra=   string  ""        Extra arguments for altool.

  full_run [REQUIRED,optional-params]
    Fully notarize a given .app bundle, creating a signed and notarized artifact for distribution.
  Options:
      -i=, --input_file=  string  REQUIRED  The path to the the ZIP file containing the .app bundle.
      -c=, --config=      string  REQUIRED  The path to the config.toml file to use for this process.
```

<a href="https://www.flaticon.com/free-icons/shipping-and-delivery" title="shipping and delivery icons">Shipping and delivery icons created by Ongicon - Flaticon</a>
