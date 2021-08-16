# RenKit

A collection of tools to help you organise and use Ren'Py instances from the command line. Especially useful for headless servers.

RenKit consists of three tools:
1. `renutil` manages Ren'Py instances and takes care of installing, launching and removing them.
2. `renotize` is a macOS-exclusive tool which notarizes built distributions of Ren'Py games for macOS.
3. `renconstruct` automates the build process for Ren'Py games start to finish.

RenKit is written in Nim and compiled into standalone executables, so it's easy to use anywhere. Currently it supports the three main platforms, Windows, Linux and macOS on x86.

## renutil

```bash
Usage is like:
    renutil {SUBCMD} [subcommand-opts & args]
where subcommand syntaxes are as follows:

  list [optional-params]
    List all available versions of RenPy, either local or remote.
  Options:
      -n=, --n=         int     0      The number of items to show. Shows all by default.
      -a, --all         bool    false  If given, shows remote versions.
      -r=, --registry=  string  ""     The registry to use. Defaults to ~/.renutil

  show [required&optional-params]
    Show information about a specific version of RenPy.
  Options:
      -v=, --version=   string  REQUIRED  The version to show.
      -r=, --registry=  string  ""        The registry to use. Defaults to ~/.renutil

  launch [required&optional-params]
    Launch the given version of RenPy.
  Options:
      -v=, --version=   string  REQUIRED  The version to launch.
      --headless        bool    false     If given, disables audio and video drivers for headless operation.
      -d, --direct      bool    false     If given, invokes RenPy directly without the launcher project.
      -a=, --args=      string  ""        The arguments to forward to RenPy.
      -r=, --registry=  string  ""        The registry to use. Defaults to ~/.renutil

  install [required&optional-params]
    Install the given version of RenPy.
  Options:
      -v=, --version=   string  REQUIRED  The version to install.
      -r=, --registry=  string  ""        The registry to use. Defaults to ~/.renutil
      -n, --no-cleanup  bool    false     If given, retains installation files.
      -f, --force       bool    false     set force

  cleanup [required&optional-params]
    Cleans up temporary directories for the given version of RenPy.
  Options:
      -v=, --version=   string  REQUIRED  The version to clean up.
      -r=, --registry=  string  ""        The registry to use. Defaults to ~/.renutil

  uninstall [required&optional-params]
    Uninstalls the given version of RenPy.
  Options:
      -v=, --version=   string  REQUIRED  The version to uninstall.
      -r=, --registry=  string  ""        The registry to use. Defaults to ~/.renutil
```

## renconstruct

```bash
Usage is like:
    renconstruct {SUBCMD} [subcommand-opts & args]
where subcommand syntaxes are as follows:

  build [required&optional-params]
    Builds a RenPy project with the specified configuration.
  Options:
      -i=, --input_dir=   string  REQUIRED  The RenPy project to build.
      -o=, --output_dir=  string  REQUIRED  The directory to output distributions to.
      -c=, --config=      string  REQUIRED  The configuration file to use.
      -r=, --registry=    string  ""        The registry to use. Defaults to ~/.renutil
```

## renotize

```bash

```
