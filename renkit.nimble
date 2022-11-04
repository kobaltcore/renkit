import strformat

# Package

version = "2.4.0"
author = "kobaltcore"
description = "A collection of tools to help you organise and use Ren'Py instances from the command line. Especially useful for headless servers."
license = "MIT"
srcDir = "src"
bin = @["renutil", "renotize", "renconstruct"]

# Dependencies

requires "nim >= 1.6.8"
requires "suru >= 0.3.1"
requires "nimpy >= 0.2.0"
requires "zippy >= 0.9.12"
requires "semver >= 1.1.1"
requires "cligen >= 1.5.23"
requires "parsetoml >= 0.6.0"

# Tasks

const currentArch = block:
  var result = ""
  if hostCPU == "arm64":
    result = "aarch64"
  elif hostCPU == "i386":
    result = "i686"
  elif hostCPU == "amd64":
    result = "x86_64"
  result

const currentOS = block:
  var result = ""
  if hostOS == "macosx":
    result = "apple-darwin"
  elif hostOS == "linux":
    result = "unknown-linux-musl"
  elif hostOS == "windows":
    result = "pc-windows-msvc"
  result

when hostOS == "macosx":
  const rcodesign_url = &"https://github.com/indygreg/apple-platform-rs/releases/download/apple-codesign%2F0.20.0/apple-codesign-0.20.0-macos-universal.tar.gz"
  const rcodesign_cmd = &"wget {rcodesign_url} -qO- | tar xz --include '*/rcodesign' --strip-components 1"
else:
  const rcodesign_url = &"https://github.com/indygreg/apple-platform-rs/releases/download/apple-codesign%2F0.20.0/apple-codesign-0.20.0-{currentArch}-{currentOS}.tar.gz"
  const rcodesign_cmd = &"wget {rcodesign_url} -qO- | tar xz --no-anchored 'rcodesign' --strip-components 1"

task gendoc, "Generates documentation for this project":
  exec("nimble doc --outdir:docs --project src/*.nim")

task renutil, "Executes 'nimble run' with extra compiler options.":
  let args = join(commandLineParams[3..^1], " ")
  exec(&"nimble -d:ssl --mm:orc run renutil {args}")

task renotize, "Executes 'nimble run' with extra compiler options.":
  let args = join(commandLineParams[3..^1], " ")
  if not fileExists("rcodesign"):
    exec(rcodesign_cmd)
  exec(&"nimble -d:ssl --mm:orc run renotize {args}")

task renconstruct, "Executes 'nimble run' with extra compiler options.":
  let args = join(commandLineParams[3..^1], " ")
  if not fileExists("rcodesign"):
    exec(rcodesign_cmd)
  exec(&"nimble -d:ssl --mm:orc run renconstruct {args}")

task build_macos_amd64, "Builds for macOS (amd64)":
  exec(rcodesign_cmd)
  exec("nimble build -d:ssl -d:release --opt:size --mm:orc -d:strip --os:macosx -y")
  exec("mkdir -p bin/amd64/macos && mv renutil bin/amd64/macos && mv renotize bin/amd64/macos && mv renconstruct bin/amd64/macos")

task build_macos_arm64, "Builds for macOS (arm64)":
  exec(rcodesign_cmd)
  exec("nimble build -d:ssl -d:release --opt:size --mm:orc -d:strip --os:macosx -y")
  exec("mkdir -p bin/arm64/macos && mv renutil bin/arm64/macos && mv renotize bin/arm64/macos && mv renconstruct bin/arm64/macos")

task build_linux_amd64, "Builds for linux (amd64)":
  exec(rcodesign_cmd)
  exec("nimble build -d:ssl -d:release --opt:size --mm:orc -d:strip --os:linux --cpu:amd64 -y")
  exec("mkdir -p bin/amd64/linux && mv renutil bin/amd64/linux && mv renotize bin/amd64/linux && mv renconstruct bin/amd64/linux")
  exec("upx --best bin/amd64/linux/*")

task build_linux_i386, "Builds for linux (i386)":
  exec(rcodesign_cmd)
  exec("nimble build -d:ssl -d:release --opt:size --mm:orc -d:strip --os:linux --cpu:i386 -y")
  exec("mkdir -p bin/i386/linux && mv renutil bin/i386/linux && mv renotize bin/i386/linux && mv renconstruct bin/i386/linux")
  exec("upx --best bin/i386/linux/*")

task build_windows_amd64, "Builds for Windows (amd64)":
  exec(rcodesign_cmd)
  exec("nimble build -d:ssl -d:release --opt:size --mm:orc -d:strip -d:mingw --cpu:amd64 -y")
  exec("mkdir -p bin/amd64/windows && mv renutil.exe bin/amd64/windows && mv renotize.exe bin/amd64/windows && mv renconstruct.exe bin/amd64/windows")
  exec("upx --best bin/amd64/windows/*")

task build_windows_i386, "Builds for Windows (i386)":
  exec(rcodesign_cmd)
  exec("nimble build -d:ssl -d:release --opt:size --mm:orc -d:strip -d:mingw --cpu:i386 -y")
  exec("mkdir -p bin/i386/windows && mv renutil.exe bin/i386/windows && mv renotize.exe bin/i386/windows && mv renconstruct.exe bin/i386/windows")
  exec("upx --best bin/i386/windows/*")
