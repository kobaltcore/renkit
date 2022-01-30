import strformat

# Package

version = "1.1.1"
author = "kobaltcore"
description = "A collection of tools to help you organise and use Ren'Py instances from the command line. Especially useful for headless servers."
license = "MIT"
srcDir = "src"
bin = @["renutil", "renotize", "renconstruct"]

# Dependencies

requires "nim >= 1.6.2"
requires "zippy >= 0.6.2"
requires "cligen >= 1.5.9"
requires "semver >= 1.1.1"
requires "parsetoml >= 0.6.0"

# Tasks

task gendoc, "Generates documentation for this project":
  exec("nimble doc --outdir:docs --project src/*.nim")

task renutil, "Executes 'nimble run' with extra compiler options.":
  let args = join(commandLineParams[3..^1], " ")
  exec(&"nimble -d:ssl --gc:orc run renutil {args}")

task renotize, "Executes 'nimble run' with extra compiler options.":
  let args = join(commandLineParams[3..^1], " ")
  exec(&"nimble -d:ssl --gc:orc run renotize {args}")

task renconstruct, "Executes 'nimble run' with extra compiler options.":
  let args = join(commandLineParams[3..^1], " ")
  exec(&"nimble -d:ssl --gc:orc run renconstruct {args}")

task build_all_macos, "Executes 'nimble build' with extra compiler options.":
  exec("nimble build -d:ssl -d:release --opt:size --gc:orc --os:macosx -d:strip -y")
  exec("mkdir -p bin/macos && mv renutil bin/macos && mv renotize bin/macos && mv renconstruct bin/macos")

task build_all_windows, "Executes 'nimble build' with extra compiler options.":
  exec("nimble build -d:ssl -d:release --opt:size --gc:orc -d:mingw -d:strip -y")
  exec("mkdir -p bin/windows && mv renutil.exe bin/windows && mv renotize.exe bin/windows && mv renconstruct.exe bin/windows")

task build_all_linux, "Executes 'nimble build' with extra compiler options.":
  exec("nimble build -d:ssl -d:release --opt:size --gc:orc --os:linux -d:strip -y")
  exec("mkdir -p bin/linux && mv renutil bin/linux && mv renotize bin/linux && mv renconstruct bin/linux")
