# Version 5.0.0-alpha.1

This release introduces several new features, some of which include breaking changes.

## Introduction of `.renpy-version`

`renutil launch` now supports reading a `.renpy-version` file in the project directory to determine the Ren'Py version to use when launching a project in `--direct` mode. This file should contain a single line with the Ren'Py version to use (optionally containing trailing newline). If the file is not present, `renutil` will require the version to be specified as an argument.

This breaks the CLI API as `renutil launch` now doesn't require a version anymore. It can still be specified as an optional argument via the new `-v <version>` flag. If it is specified, the version given in the `.renpy-version` file will be ignored.

## Auto-installation of Ren'Py when using `renutil launch`

If the Ren'Py version requested when invoking `renutil launch` is not installed, `renutil` will now automatically download and install it by default. This feature can be disabled either by supplying the `--no-auto-install` flag or setting the `RENUTIL_AUTOINSTALL` environment variable to `false` or `0`. The `--no-auto-install` flag will override `RENUTIL_AUTOINSTALL=true` for that specific invocation.

# Version 4.5.0-alpha.1

This release adds support for nested dict-like values for custom tasks (see #24), allowing for properties like:

```toml
[tasks.example]
type = "custom"
enabled = true

[tasks.example.dict_config_val]
key = "value"
```

This will result in the following config structure:

```json
{ "dict_config_val": { "key": "value" } }
```

It also brings support for [custom packages](https://www.renpy.org/doc/html/build.html#build.package) which can now be built like any other package (provided they exist for the target game that is being built). They can be specified by name like any other package:

```toml
[builds]
pc = true
mac = true
custom = true
```

In addition, many of the dependencies that `renkit` relies on have been updated to their latest versions.

# Version 4.4.0

This release adds ARM-based Linux systems as a target for built distributions on Ren'Py versions above and including 7.5.0. These libraries are shipped separately by Ren'Py at the current point in time, so `renutil` will now take care of installing them when available.

# Version 4.3.0

This release adds support for Keystore aliases and passwords when building Android application bundles. They may be specified in the `renconstruct` config file or via environment variables (for use inside CI environments).

Build selection in `renconstruct` has been fixed: In some cases `renconstruct` would go on to build other packages even if only Android packages were enabled.

`renutil` will now print the exit code if Ren'Py fails to launch.

# Version 4.2.0

This release introduces two new features:

1. Support for nightly versions of Ren'Py
2. An interactive REPL for Ren'Py versions above `8.3.0` (introduced via https://github.com/renpy/renpy/issues/5455)

The interactive REPL allows for the ability to send Python commands directly into a running instance of a Ren'Py game, where they will be executed within the context of an interaction. Code can either be supplied through an interactive text prompt in the terminal or directly via the command line while the game is running.

# Version 4.1.0

This release changes the notarization process to be more useful on non-Apple platforms.

Specifically, `renotize` will now:

1. Sign and notarize the `.app` bundle on all platforms, replacing the original ZIP file with its notarized version.
2. On macOS, it will additionally sign and notarize a DMG image.

# Version 4.0.3

This minor release implements better output during notarization to make it easier to follow what the tool is doing at any given moment (see #15), specifically with view of the potentially-long notarization wait times from Apple's servers.

# Version 4.0.2

This minor release fixes two bugs reported in #13 and #14.

# Version 4.0.1

This is a minor maintenance release to reduce compatibility issues with openssl on recent Linux systems and images. renkit should now be compatible with more Linux distributions than before.

# Version 4.0.0

First major release of the `renkit` Rust rewrite.
