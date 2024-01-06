import strformat

# Package

version = "3.4.1"
author = "kobaltcore"
description = "A collection of tools to help you organise and use Ren'Py instances from the command line. Especially useful for headless servers."
license = "MIT"
srcDir = "src"
bin = @["renutil", "renotize", "renconstruct"]

# Dependencies

requires "nim >= 2.0.0"
requires "suru >= 0.3.1"
requires "nimpy >= 0.2.0"
requires "puppy >= 2.1.0"
requires "regex >= 0.23.0"
requires "zippy >= 0.10.10"
requires "plists >= 0.2.0"
requires "semver >= 1.2.1"
requires "cligen >= 1.6.17"
requires "parsetoml >= 0.7.1"

# Tasks
proc getRcodesignUrl(osName="", archName=""): string =
  let currentArch = block:
    var result = ""
    if hostCPU == "arm64":
      result = "aarch64"
    elif hostCPU == "amd64":
      result = "x86_64"
    result

  let currentOS = block:
    var result = ""
    if hostOS == "macosx":
      result = "apple-darwin"
    elif hostOS == "linux":
      result = "unknown-linux-musl"
    elif hostOS == "windows":
      result = "pc-windows-msvc"
    result

  let finalOS = if osName == "": currentOS else: osName
  let finalArch = if archName == "": currentArch else: archName

  let rcodesignUrl = case finalOS:
    of "pc-windows-msvc":
      &"https://github.com/indygreg/apple-platform-rs/releases/download/apple-codesign%2F0.26.0/apple-codesign-0.26.0-{finalArch}-{finalOS}.zip"
    else:
      &"https://github.com/indygreg/apple-platform-rs/releases/download/apple-codesign%2F0.26.0/apple-codesign-0.26.0-{finalArch}-{finalOS}.tar.gz"

  if hostOS == "macosx":
    if finalOS == "pc-windows-msvc":
      result = &"echo 'Downloading {rcodesignUrl}' && wget {rcodesignUrl} -qO- | tar xz --include '*/rcodesign.exe' --strip-components 1"
    else:
      result = &"echo 'Downloading {rcodesignUrl}' && wget {rcodesignUrl} -qO- | tar xz --include '*/rcodesign' --strip-components 1"
  else:
    if finalOS == "pc-windows-msvc":
      result = &"echo 'Downloading {rcodesignUrl}' && wget {rcodesignUrl} -qO- | bsdtar -xOf- '*/rcodesign.exe' > rcodesign.exe"
    else:
      result = &"echo 'Downloading {rcodesignUrl}' && wget {rcodesignUrl} -qO- | bsdtar -xOf- '*/rcodesign' > rcodesign"

proc getWebpUrl(osName="", archName=""): string =
  let currentArch = block:
    var result = ""
    if hostCPU == "arm64":
      result = "arm64"
    elif hostCPU == "amd64":
      result = "x86-64"
    result

  let currentOS = block:
    var result = ""
    if hostOS == "macosx":
      result = "mac"
    elif hostOS == "linux":
      result = "linux"
    elif hostOS == "windows":
      result = "windows"
    result

  let finalOS = if osName == "": currentOS else: osName
  let finalArch = if archName == "": currentArch else: archName

  let webpUrl = case finalOS:
    of "windows":
      &"https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.3.2-{finalOS}-{finalArch}.zip"
    else:
      &"https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.3.2-{finalOS}-{finalArch}.tar.gz"

  if hostOS == "macosx":
    if finalOS == "windows":
      result = &"echo 'Downloading {webpUrl}' && wget {webpUrl} -qO- | tar xz --include '*/cwebp.exe' --strip-components 2"
    else:
      result = &"echo 'Downloading {webpUrl}' && wget {webpUrl} -qO- | tar xz --include '*/cwebp' --strip-components 2"
  else:
    if finalOS == "windows":
      result = &"echo 'Downloading {webpUrl}' && wget {webpUrl} -qO- | bsdtar -xOf- '*/cwebp.exe' > cwebp.exe"
    else:
      result = &"echo 'Downloading {webpUrl}' && wget {webpUrl} -qO- | bsdtar -xOf- '*/cwebp' > cwebp"

proc getCavifUrl(osName=""): string =
  let currentOS = block:
    var result = ""
    if hostOS == "macosx":
      result = "mac"
    elif hostOS == "linux":
      result = "linux-generic"
    elif hostOS == "windows":
      result = "win"
    result

  let finalOS = if osName == "": currentOS else: osName

  let cavifUrl = &"https://github.com/kornelski/cavif-rs/releases/download/v1.5.4/cavif-1.5.4.zip"

  if finalOS == "win":
    result = &"echo 'Downloading {cavifUrl}' && wget {cavifUrl} -qO cavif.zip && unzip -oj cavif.zip {finalOS}/cavif.exe && rm cavif.zip"
  else:
    result = &"echo 'Downloading {cavifUrl}' && wget {cavifUrl} -qO cavif.zip && unzip -oj cavif.zip {finalOS}/cavif && rm cavif.zip"

task gendoc, "Generates documentation for this project":
  exec("nimble doc --outdir:docs --project src/*.nim")

task renutil, "Executes 'nimble run' with extra compiler options.":
  let args = join(commandLineParams[3..^1], " ")
  exec(&"nimble --styleCheck:hint run renutil {args}")

task renotize, "Executes 'nimble run' with extra compiler options.":
  let args = join(commandLineParams[3..^1], " ")
  if not fileExists("rcodesign"):
    exec(getRcodesignUrl())
  exec(&"nimble --styleCheck:hint run renotize {args}")

task renconstruct, "Executes 'nimble run' with extra compiler options.":
  let args = join(commandLineParams[3..^1], " ")
  if not fileExists("cavif"):
    exec(getCavifUrl())
  if not fileExists("cwebp"):
    exec(getWebpUrl())
  if not fileExists("rcodesign"):
    exec(getRcodesignUrl())
  exec(&"nimble --styleCheck:hint run renconstruct {args}")

task build_macos_amd64, "Builds for macOS (amd64)":
  exec(getCavifUrl("mac"))
  exec(getWebpUrl("mac", "x86-64"))
  exec(getRcodesignUrl("apple-darwin", "x86_64"))
  exec("nimble build --styleCheck:hint -d:release --opt:size -d:strip --os:macosx -y")
  exec("mkdir -p bin/amd64/macos && mv renutil bin/amd64/macos && mv renotize bin/amd64/macos && mv renconstruct bin/amd64/macos")
  # exec("upx --best bin/amd64/macos/*")

task build_macos_arm64, "Builds for macOS (arm64)":
  exec(getCavifUrl("mac"))
  exec(getWebpUrl("mac", "arm64"))
  exec(getRcodesignUrl("apple-darwin", "aarch64"))
  exec("nimble build --styleCheck:hint -d:release --opt:size -d:strip --os:macosx -y")
  exec("mkdir -p bin/arm64/macos && mv renutil bin/arm64/macos && mv renotize bin/arm64/macos && mv renconstruct bin/arm64/macos")
  # when hostCPU != "arm64":
  #   exec("upx --best bin/arm64/macos/*")

task build_linux_amd64, "Builds for linux (amd64)":
  exec(getCavifUrl("linux-generic"))
  exec(getWebpUrl("linux", "x86-64"))
  exec(getRcodesignUrl("unknown-linux-musl", "x86_64"))
  exec("nimble build --styleCheck:hint -d:release --opt:size -d:strip --os:linux --cpu:amd64 -y")
  exec("mkdir -p bin/amd64/linux && mv renutil bin/amd64/linux && mv renotize bin/amd64/linux && mv renconstruct bin/amd64/linux")
  # exec("upx --best bin/amd64/linux/*")

task build_windows_amd64, "Builds for Windows (amd64)":
  exec(getCavifUrl("win"))
  exec(getWebpUrl("windows", "x64"))
  exec(getRcodesignUrl("pc-windows-msvc", "x86_64"))
  exec("nimble build --styleCheck:hint -d:release --opt:size -d:strip -d:mingw --cpu:amd64 -y")
  exec("mkdir -p bin/amd64/windows && mv renutil.exe bin/amd64/windows && mv renotize.exe bin/amd64/windows && mv renconstruct.exe bin/amd64/windows")
  # exec("upx --best bin/amd64/windows/*")
