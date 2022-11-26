import system
import std/os
import std/sugar
import std/osproc
import std/streams
import std/strtabs
import std/xmltree
import std/strformat
import std/algorithm
import std/htmlparser

import puppy
import regex
import semver
import cligen
import zippy/ziparchives

import lib/common

type KeyboardInterrupt = object of CatchableError

proc handler() {.noconv.} =
  raise newException(KeyboardInterrupt, "Keyboard Interrupt")

setControlCHook(handler)

proc getRegistry*(registry: string = ""): string =
  var registryPath: string

  if registry == "":
    registryPath = joinPath(getHomeDir(), ".renutil")
  else:
    registryPath = registry

  if not dirExists(registryPath):
    createDir(registryPath)

  return absolutePath(registryPath)

proc listInstalled*(registry: string): seq[Version] =
  var versions: seq[Version]
  for kind, path in walkDir(registry):
    if kind != pcDir:
      continue
    versions.add(parseVersion(lastPathPart(path)))
  return sorted(versions, Descending)

proc isInstalled*(version: Version, registry: string): bool =
  return listInstalled(registry).contains(version)

proc listAvailable*(): seq[Version] =
  var versions: seq[Version]

  let req = Request(url: parseUrl("https://www.renpy.org/dl"), verb: "get")
  let html = parseHtml(fetch(req).body)

  for a in html.findAll("a"):
    if not a.attrs.hasKey("href"):
      continue

    let url = a.attrs["href"]
    let version = normalizePathEnd(url)
    let didMatch = version.match(re"^(?P<major>0|[1-9]\d*)\.(?P<minor>0|[1-9]\d*)\.(?P<patch>0|[1-9]\d*)(?:-(?P<prerelease>(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)(?:\.(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?(?:\+(?P<buildmetadata>[0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?$")

    if not didMatch:
      continue

    versions.add(parseVersion(version))

  return sorted(versions, (x, y: Version) => compare(x, y)).reversed

proc list*(n = 0, all = false, registry = "") =
  ## List all available versions of Ren'Py, either local or remote.
  let registryPath = getRegistry(registry)

  let versions = case all:
    of true:
      listAvailable()
    of false:
      listInstalled(registryPath)

  let limit = if n < 1 or n > high(versions): high(versions) + 1 else: n

  for version in versions[0..<limit]:
    echo version

proc getExe*(version: Version, registry: string): (string, string) =
  var
    arch: string
    exe = "python"

  case hostOS:
    of "windows":
      exe = "python.exe"
      case hostCPU:
        of "amd64":
          if version < newVersion(7, 4, 0): # Pre-v8 strain
            arch = "windows-x86_64"
          elif version < newVersion(8, 0, 0): # Python 2 strain
            arch = "py2-windows-x86_64"
          else: # Python 3 strain
            arch = "py3-windows-x86_64"
        else:
          if version < newVersion(7, 4, 0): # Pre-v8 strain
            arch = "windows-i686"
          elif version < newVersion(8, 0, 0): # Python 2 strain
            arch = "py2-windows-i686"
          else: # Python 3 strain
            arch = "py3-windows-i686"
    of "linux":
      case hostCPU:
        of "amd64":
          if version < newVersion(7, 4, 0): # Pre-v8 strain
            arch = "linux-x86_64"
          elif version < newVersion(8, 0, 0): # Python 2 strain
            arch = "py2-linux-x86_64"
          else: # Python 3 strain
            arch = "py3-linux-x86_64"
        else:
          if version < newVersion(7, 4, 0): # Pre-v8 strain
            arch = "linux-i686"
          elif version < newVersion(8, 0, 0): # Python 2 strain
            arch = "py2-linux-i686"
          else: # Python 3 strain
            arch = "py3-linux-i686"
    of "macosx":
      if version < newVersion(7, 4, 0): # Pre-v8 strain
        arch = "darwin-x86_64"
      elif version <= newVersion(7, 4, 11): # Weird naming scheme change just for these versions
        arch = "mac-x86_64"
      elif version < newVersion(8, 0, 0): # Python 2 strain
        arch = "py2-mac-x86_64"
      elif version <= newVersion(8, 0, 3): # Python 3 strain with weird naming scheme
        arch = "py3-mac-x86_64"
      else: # Python 3 strain with universal naming scheme
        arch = "py3-mac-universal"

  let python = joinPath(registry, $version, "lib", arch, exe)
  let baseFile = joinPath(registry, $version, "renpy.py")
  return (python, baseFile)

proc show*(version: string, registry = "") =
  ## Show information about a specific version of Ren'Py.
  let version = parseVersion(version)
  let registryPath = getRegistry(registry)

  echo &"Version: {version}"
  if isInstalled(version, registryPath):
    let (python, _) = getExe(version, registryPath)
    echo "Installed: Yes"
    echo &"Location: {joinPath(registryPath, $version)}"
    echo &"Architecture: {splitPath(splitPath(python)[0])[1]}"
  else:
    echo "Installed: No"
  echo &"SDK URL: https://www.renpy.org/dl/{version}/renpy-{version}-sdk.zip"
  echo &"RAPT URL: https://www.renpy.org/dl/{version}/renpy-{version}-rapt.zip"

proc launch*(
  version: string,
  headless = false,
  direct = false,
  args = "",
  registry = ""
) =
  ## Launch the given version of Ren'Py.
  let version = parseVersion(version)
  let registryPath = getRegistry(registry)

  if not isInstalled(version, registryPath):
    echo &"{version} is not installed."
    quit(1)

  let (python, baseFile) = getExe(version, registryPath)
  let baseCmd = &"{python} -EO {baseFile}"

  let cmd = case direct:
    of true:
      &"{baseCmd} {args}"
    of false:
      &"{baseCmd} {quoteShell(joinPath(registryPath, $version, \"launcher\"))} {args}"

  if headless:
    putEnv("SDL_AUDIODRIVER", "dummy")
    putEnv("SDL_VIDEODRIVER", "dummy")

  discard execShellCmd(cmd)

proc install*(
  version: string,
  registry = "",
  noCleanup = false,
  force = false
) =
  ## Install the given version of Ren'Py.
  let version = parseVersion(version)
  let registryPath = getRegistry(registry)

  if isInstalled(version, registryPath) and not force:
    echo &"{version} is already installed."
    quit(1)

  let targetDir = joinPath(registryPath, $version)
  if force and dirExists(targetDir):
    removeDir(targetDir)

  let steamUrl = &"https://www.renpy.org/dl/{version}/renpy-{version}-steam.zip"
  let steamFile = joinPath(
    registryPath,
    &"renpy-{version}-steam.zip"
  )

  let webUrl = &"https://www.renpy.org/dl/{version}/renpy-{version}-web.zip"
  let webFile = joinPath(
    registryPath,
    &"renpy-{version}-web.zip"
  )

  let raptUrl = &"https://www.renpy.org/dl/{version}/renpy-{version}-rapt.zip"
  let raptFile = joinPath(
    registryPath,
    &"renpy-{version}-rapt.zip"
  )

  let sdkUrl = &"https://www.renpy.org/dl/{version}/renpy-{version}-sdk.zip"
  let sdkFile = joinPath(
    registryPath,
    &"renpy-{version}-sdk.zip"
  )

  if not fileExists(steamFile):
    try:
      echo "Downloading Steam support"
      download(steamUrl, steamFile)
    except ValueError:
      if getCurrentExceptionMsg() == "404 Not Found":
        echo "Not supported on this version, skipping"
      else:
        raise getCurrentException()
    except KeyboardInterrupt:
      echo "Aborted, cleaning up."
      removeFile(steamFile)
      quit(1)

  if not fileExists(webFile):
    try:
      echo "Downloading Web Support"
      download(webUrl, webFile)
    except KeyboardInterrupt:
      echo "Aborted, cleaning up."
      removeFile(webFile)
      quit(1)

  if not fileExists(raptFile):
    try:
      echo "Downloading RAPT"
      download(raptUrl, raptFile)
    except KeyboardInterrupt:
      echo "Aborted, cleaning up."
      removeFile(raptFile)
      quit(1)

  if not fileExists(sdkFile):
    try:
      echo "Downloading Ren'Py"
      download(sdkUrl, sdkFile)
    except KeyboardInterrupt:
      echo "Aborted, cleaning up."
      removeFile(sdkFile)
      removeFile(raptFile)
      quit(1)

  echo "Extracting"
  let pathExtracted = joinPath(registryPath, "extracted")

  # SDK

  extractAll(sdkFile, pathExtracted)

  moveDir(
    joinPath(pathExtracted, &"renpy-{version}-sdk"),
    joinPath(registryPath, $version)
  )

  removeDir(pathExtracted)

  # Steam

  if fileExists(steamFile):
    extractAll(steamFile, pathExtracted)

    for path in walkDirRec(pathExtracted):
      copyFile(path, joinPath(registryPath, $version, relativePath(path, pathExtracted)))

    removeDir(pathExtracted)

  # Web

  extractAll(webFile, pathExtracted)

  moveDir(
    joinPath(pathExtracted, "web"),
    joinPath(registryPath, $version, "web")
  )

  removeDir(pathExtracted)

  # RAPT

  extractAll(raptFile, pathExtracted)

  moveDir(
    joinPath(pathExtracted, "rapt"),
    joinPath(registryPath, $version, "rapt")
  )

  removeDir(pathExtracted)

  if not noCleanup:
    removeFile(steamFile)
    removeFile(webFile)
    removeFile(raptFile)
    removeFile(sdkFile)

  echo "Setting up permissions"
  let (python, _) = getExe(version, registryPath)

  let paths = case hostOS:
    of "windows":
      [
          joinPath(splitPath(python)[0], "python.exe"),
          joinPath(splitPath(python)[0], "pythonw.exe"),
          joinPath(splitPath(python)[0], "renpy.exe"),
          joinPath(splitPath(python)[0], "zsync.exe"),
          joinPath(splitPath(python)[0], "zsyncmake.exe"),
          joinPath(registryPath, $version, "rapt", "prototype", "gradlew.exe"),
          joinPath(registryPath, $version, "rapt", "project", "gradlew.exe"),
      ]
    else:
      [
          joinPath(splitPath(python)[0], "python"),
          joinPath(splitPath(python)[0], "pythonw"),
          joinPath(splitPath(python)[0], "renpy"),
          joinPath(splitPath(python)[0], "zsync"),
          joinPath(splitPath(python)[0], "zsyncmake"),
          joinPath(registryPath, $version, "rapt", "prototype", "gradlew"),
          joinPath(registryPath, $version, "rapt", "project", "gradlew"),
      ]

  for path in paths:
    if fileExists(path):
      setFilePermissions(path, {fpUserRead, fpUserExec})

  let originalDir = getCurrentDir()
  setCurrentDir(joinPath(registryPath, $version, "rapt"))

  if not fileExists("android.keystore"):
    echo "Generating Application Keystore"
    let javaHome = getEnv("JAVA_HOME")
    if javaHome == "":
      echo "JAVA_HOME is empty. Please check if you need to install OpenJDK 8."
      quit(1)
    let keytoolPath = quoteShell(joinPath(javaHome, "bin", "keytool"))
    let dname = "renutil"
    discard execProcess(&"{keytoolPath} -genkey -keystore android.keystore -alias android -keyalg RSA -keysize 2048 -keypass android -storepass android -dname CN={dname} -validity 20000")

  if not fileExists("bundle.keystore"):
    echo "Generating Bundle Keystore"
    let javaHome = getEnv("JAVA_HOME")
    if javaHome == "":
      echo "JAVA_HOME is empty. Please check if you need to install OpenJDK 8."
      quit(1)
    let keytoolPath = quoteShell(joinPath(javaHome, "bin", "keytool"))
    let dname = "renutil"
    discard execProcess(&"{keytoolPath} -genkey -keystore bundle.keystore -alias android -keyalg RSA -keysize 2048 -keypass android -storepass android -dname CN={dname} -validity 20000")

  echo "Preparing RAPT"
  let interfaceFileSource = joinPath(targetDir, "rapt", "buildlib", "rapt", "interface.py")
  let interfaceFileTarget = joinPath(targetDir, "rapt", "buildlib", "rapt", "interface.py.new")

  var streamIn = newFileStream(interfaceFileSource, fmRead)
  var streamOut = newFileStream(interfaceFileTarget, fmWrite)

  var
    line = ""
    isPatched = false
  let sslPatch = "import ssl; ssl._create_default_https_context = ssl._create_unverified_context"

  while streamIn.readLine(line):
    if line == sslPatch:
      isPatched = true
    if not isPatched and line == "":
      streamOut.writeLine(sslPatch)
      isPatched = true
    else:
      streamOut.writeLine(line)

  streamIn.close()
  streamOut.close()

  removeFile(interfaceFileSource)
  moveFile(interfaceFileTarget, interfaceFileSource)

  # TODO: tweak gradle.properties RAM allocation

  echo "Installing RAPT"
  if version >= newVersion(7, 5, 0):
    # in versions above 7.5.0, the RAPT installer tries to import renpy.compat
    # this is not in the path by default, and since PYTHONPATH is ignored, we
    # symlink it instead to make it visible during installation.
    createSymlink(
      joinPath(registryPath, $version, "renpy"),
      joinPath(registryPath, $version, "rapt", "renpy")
    )

  putEnv("RAPT_NO_TERMS", "1")
  discard execCmd(&"{python} -EO android.py installsdk")

  setCurrentDir(originalDir)

  echo "Ensuring Android SDK is installed"
  let sdkmanagerPath = case hostOS:
    of "windows":
      joinPath(
        registryPath,
        $version,
        "rapt",
        "Sdk",
        "cmdline-tools",
        "latest",
        "bin",
        "sdkmanager.exe"
      )
    else:
      joinPath(
        registryPath,
        $version,
        "rapt",
        "Sdk",
        "cmdline-tools",
        "latest",
        "bin",
        "sdkmanager"
      )
  discard execCmd(&"{sdkmanagerPath} 'build-tools;29.0.2'")

  if version >= newVersion(8, 0, 0):
    echo "Increasing default pickle protocol from 2 to 5"
    let pickleFileSource = joinPath(registryPath, $version, "renpy", "compat", "pickle.py")
    let pickleFileTarget = joinPath(registryPath, $version, "renpy", "compat", "pickle.py.new")

    streamIn = newFileStream(pickleFileSource, fmRead)
    streamOut = newFileStream(pickleFileTarget, fmWrite)

    line = ""
    while streamIn.readLine(line):
      if line == "PROTOCOL = 2":
        streamOut.writeLine("PROTOCOL = 5")
      else:
        streamOut.writeLine(line)

    streamIn.close()
    streamOut.close()

    removeFile(pickleFileSource)
    moveFile(pickleFileTarget, pickleFileSource)

proc cleanup*(version: string, registry = "") =
  ## Cleans up temporary directories for the given version of Ren'Py.
  let version = parseVersion(version)
  let registryPath = getRegistry(registry)

  if not isInstalled(version, registryPath):
    echo &"{version} is not installed."
    quit(1)

  let paths = [
    joinPath(registryPath, $version, "tmp"),
    joinPath(registryPath, $version, "rapt", "assets"),
    joinPath(registryPath, $version, "rapt", "bin"),
    joinPath(registryPath, $version, "rapt", "project", "app", "build"),
    joinPath(
      registryPath, $version,
      "rapt", "project", "app",
      "src", "main", "assets"
    ),
  ]

  for path in paths:
    if dirExists(path):
      removeDir(path)

proc uninstall*(version: string, registry = "") =
  ## Uninstalls the given version of Ren'Py.
  let version = parseVersion(version)
  let registryPath = getRegistry(registry)

  if not isInstalled(version, registryPath):
    echo &"{version} is not installed."
    quit(1)

  removeDir(joinPath(registryPath, $version))

when isMainModule:
  dispatchMulti(
    [list, help = {
        "n": "The number of items to show. Shows all by default.",
        "all": "If given, shows remote versions.",
        "registry": "The path to the registry directory to use. Defaults to ~/.renutil",
    }],
    [show, help = {
        "version": "The version to show.",
        "registry": "The path to the registry directory to use. Defaults to ~/.renutil",
    }],
    [launch, help = {
        "version": "The version to launch.",
        "headless": "If given, disables audio and video drivers for headless operation.",
        "direct": "If given, invokes Ren'Py directly without the launcher project.",
        "args": "The arguments to forward to Ren'Py.",
        "registry": "The path to the registry directory to use. Defaults to ~/.renutil",
    }],
    [install, help = {
        "version": "The version to install.",
        "registry": "The path to the registry directory to use. Defaults to ~/.renutil",
        "no-cleanup": "If given, retains installation files.",
    }],
    [cleanup, help = {
        "version": "The version to clean up.",
        "registry": "The path to the registry directory to use. Defaults to ~/.renutil",
    }],
    [uninstall, help = {
        "version": "The version to uninstall.",
        "registry": "The path to the registry directory to use. Defaults to ~/.renutil",
    }],
  )
