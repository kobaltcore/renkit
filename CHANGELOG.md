# Version 6.0.0

This release adds support for task parallelization, automatically executing tasks in parallel where possible. It additionally enables optional task multi-instancing, enabling duplicate invocations of tasks with different parameters.

## Removal of Interactive Mode

This was added to Ren'Py as an experimental feature but [subsequently removed](https://github.com/renpy/renpy/issues/5607#issuecomment-2201742647). It is now relegated to a custom extension, which is not in the scope of this project. Due to changing the public-facing API of `renutil`, this is a breaking change.

## Bug Fixes

The `keytool` path for generating Android keystores is now properly joined on Windows systems, fixing a bug where the keystore generation could fail on Windows due to incorrect pathing.

## Improvements

Better output when keystores fail to generate: `renconstruct` will now print the command it used to generate the keystore, making it easier to debug issues.

## Task Parallelization

By default, nothing about the execution order of tasks will change. They will execute sequentially exactly as they did before. However, tasks can now be marked as `sandboxed` to enable parallel execution:

```toml
[tasks.example]
type = "custom"
sandboxed = true
```

`sandboxed` in the context of `renconstruct` is a _promise_ from the user that the task will not modify any global state or have any side effects outside of the task's own scope. For example, a task that creates a file will do so in a way that does not affect itself or others if it were run with different parameters.

Under this guarantee, `reconstruct` will execute tasks in parallel if they are marked as `sandboxed`, occur in the same build stage and have the same priority level. Thus, if task A runs pre-build and task B runs post-build, they can _not_ be executed in parallel.
However, if task A and task B are both marked as `sandboxed` and occur in the same stage with the same priority level, they _can_ be executed in parallel. `renconstruct` will automatically detect parallelism opportunities and inform you of this in the logs.

## Task Multi-Instancing

The ability to run tasks in parallel also made it more sensible for tasks to be able to run multiple instances of themselves. This is useful for tasks that themselves don't have any internal parallelism opportunities, but can be run multiple times in parallel, for example image processing tasks like resizing to various scales for different directories.
As such, tasks now take a new, optional parameter `name` which is used to identify the task instance and takes over the duty of the section title in the configuration file.

```toml
[tasks.example]  # <== This previously determined the task that would run
type = "custom"

[tasks.my_random_identifier]  # <== Tasks can now have arbitrary names, allowing multi-instancing
type = "custom"
name = "example"  # <== This is now a task parameter
```

Before this change, the names of task sections in the config file were a limiting factor as only one section could be named `tasks.example` and could thus refer to that specific custom task. Now tasks can be named arbitrarily, allowing for multiple instances of the same task to be run in parallel. The following invokes the task `ExamleTask` twice, with different names:

```toml
[tasks.random_task_id_1]
type = "custom"
name = "example"

[tasks.random_task_id_2]
type = "custom"
name = "example"
```

To remain backwards-compatible with existing configuration files, the task section names will be used as a fallback when the `name` parameter is not specified, but a warning will be printed to the console to update to the new format.

# Version 5.0.0

This release introduces several new features, some of which include breaking changes.

## Introduction of `.renpy-version`

`renutil launch` now supports reading a `.renpy-version` file in the project directory to determine the Ren'Py version to use when launching a project in `--direct` mode. This file should contain a single line with the Ren'Py version to use (optionally containing trailing newline). If the file is not present, `renutil` will require the version to be specified as an argument.

This breaks the CLI API as `renutil launch` now doesn't require a version anymore. It can still be specified as an optional argument via the new `-v <version>` flag. If it is specified, the version given in the `.renpy-version` file will be ignored.

## Auto-installation of Ren'Py when using `renutil launch`

If the Ren'Py version requested when invoking `renutil launch` is not installed, `renutil` will now automatically download and install it by default. This feature can be disabled either by supplying the `--no-auto-install` flag or setting the `RENUTIL_AUTOINSTALL` environment variable to `false` or `0`. The `--no-auto-install` flag will override `RENUTIL_AUTOINSTALL=true` for that specific invocation.

## `renconstruct` Task System Rework

The task system in `renconstruct` has been reworked to allow for more flexibility in defining tasks. While this is mostly backwards-compatible, there are some breaking changes:

- Custom tasks must now accept two additional parameters in their `__init__` method:

  1. `renpy_path`: Path to the Ren'Py installation used to build the distributions.
  2. `registry`: Path to the registry directory containing the Ren'Py installation(s).

- The `pre_build` and `post_build` methods of custom tasks must now accept an additional parameter:

  1. `on_builds`: A dictionary mapping build names to the paths of the built distributions. The values of this dictionary will be `None` during `pre_build` because nothing has been built at that point. Example: `{ "mac": "output/mygame-1.0-mac.zip" }`. Tasks can then opt to either do processing per build artifact or globally, allowing them to -for example- handle ZIP files differently than directory outputs.

## Support for nested values in config files

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

## Support for building custom distributions

[Custom packages](https://www.renpy.org/doc/html/build.html#build.package) are now supported, which can now be built like any other package (provided they exist for the target game that is being built). They can be specified by name like any other package:

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
