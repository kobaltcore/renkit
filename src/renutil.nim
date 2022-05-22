import system
import std/os
import std/nre
import std/osproc
import std/streams
import std/strtabs
import std/xmltree
import std/strformat
import std/algorithm
import std/htmlparser
import std/httpclient

import cligen
import zippy/ziparchives

import common
import natsort

type KeyboardInterrupt = object of CatchableError

proc handler() {.noconv.} =
  raise newException(KeyboardInterrupt, "Keyboard Interrupt")

setControlCHook(handler)

proc get_registry*(registry: string = ""): string =
  var registry_path: string

  if registry == "":
    registry_path = joinPath(getHomeDir(), ".renutil")
  else:
    registry_path = registry

  if not dirExists(registry_path):
    createDir(registry_path)

  return absolutePath(registry_path)

proc list_installed*(registry: string): seq[string] =
  var versions: seq[string]
  for kind, path in walkDir(registry):
    if kind != pcDir:
      continue
    versions.add(lastPathPart(path))
  return sorted(versions, Descending)

proc is_installed*(version: string, registry: string): bool =
  return list_installed(registry).contains(version)

proc list_available*(): seq[string] =
  var versions: seq[string]

  let client = newHttpClient()
  let html = parseHtml(client.getContent("https://www.renpy.org/dl"))

  for a in html.findAll("a"):
    if not a.attrs.hasKey("href"):
      continue

    let url = a.attrs["href"]
    let version = normalizePathEnd(url)
    let match = version.match(re"^(?P<major>0|[1-9]\d*)\.(?P<minor>0|[1-9]\d*)\.(?P<patch>0|[1-9]\d*)(?:-(?P<prerelease>(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)(?:\.(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?(?:\+(?P<buildmetadata>[0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?$")

    if match.isNone:
      continue

    versions.add(version)

  return sorted(versions, naturalCmp).reversed

proc list*(n = 0, all = false, registry = "") =
  ## List all available versions of Ren'Py, either local or remote.
  let registry_path = get_registry(registry)

  let versions = case all:
    of true:
      list_available()
    of false:
      list_installed(registry_path)

  let limit = if n < 1 or n > high(versions): high(versions) else: n

  for version in versions[0..limit]:
    echo version

proc get_exe*(version: string, registry: string): (string, string) =
  var
    arch: string
    exe = "python"

  case hostOS:
    of "windows":
      exe = "python.exe"
      case hostCPU:
        of "amd64":
          if version < "7.4": # Pre-v8 strain
            arch = "windows-x86_64"
          elif version < "8.0.0": # Python 2 strain
            arch = "py2-windows-x86_64"
          else: # Python 3 strain
            arch = "py3-windows-x86_64"
        else:
          if version < "7.4": # Pre-v8 strain
            arch = "windows-i686"
          elif version < "8.0.0": # Python 2 strain
            arch = "py2-windows-i686"
          else: # Python 3 strain
            arch = "py3-windows-i686"
    of "linux":
      case hostCPU:
        of "amd64":
          if version < "7.4": # Pre-v8 strain
            arch = "linux-x86_64"
          elif version < "8.0.0": # Python 2 strain
            arch = "py2-linux-x86_64"
          else: # Python 3 strain
            arch = "py3-linux-x86_64"
        else:
          if version < "7.4": # Pre-v8 strain
            arch = "linux-i686"
          elif version < "8.0.0": # Python 2 strain
            arch = "py2-linux-i686"
          else: # Python 3 strain
            arch = "py3-linux-i686"
    of "macosx":
      if version < "7.4": # Pre-v8 strain
        arch = "darwin-x86_64"
      elif version <= "7.4.8": # Weird naming scheme change just for this version
        arch = "mac-x86_64"
      elif version < "8.0.0": # Python 2 strain
        arch = "py2-mac-x86_64"
      else: # Python 3 strain
        arch = "py3-mac-x86_64"

  let python = joinPath(registry, version, "lib", arch, exe)
  let base_file = joinPath(registry, version, "renpy.py")
  return (python, base_file)

proc show*(version: string, registry = "") =
  ## Show information about a specific version of Ren'Py.
  let registry_path = get_registry(registry)

  echo &"Version: {version}"
  if is_installed(version, registry_path):
    let (python, base_file) = get_exe(version, registry_path)
    echo "Installed: Yes"
    echo &"Location: {joinPath(registry_path, version)}"
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
  let registry_path = get_registry(registry)

  if not is_installed(version, registry_path):
    echo &"{version} is not installed."
    quit(1)

  let (python, base_file) = get_exe(version, registry_path)
  let base_cmd = &"{python} -EO {base_file}"

  let cmd = case direct:
    of true:
      &"{base_cmd} {args}"
    of false:
      &"{base_cmd} {quoteShell(joinPath(registry_path, version, \"launcher\"))} {args}"

  if headless:
    putEnv("SDL_AUDIODRIVER", "dummy")
    putEnv("SDL_VIDEODRIVER", "dummy")

  discard execShellCmd(cmd)

proc install*(
  version: string,
  registry = "",
  no_cleanup = false,
  force = false
) =
  ## Install the given version of Ren'Py.
  let registry_path = get_registry(registry)

  if is_installed(version, registry_path) and not force:
    echo &"{version} is already installed."
    quit(1)

  let target_dir = joinPath(registry_path, version)
  if force and dirExists(target_dir):
    removeDir(target_dir)

  let steam_url = &"https://www.renpy.org/dl/{version}/renpy-{version}-steam.zip"
  let steam_file = joinPath(
    registry_path,
    &"renpy-{version}-steam.zip"
  )

  let web_url = &"https://www.renpy.org/dl/{version}/renpy-{version}-web.zip"
  let web_file = joinPath(
    registry_path,
    &"renpy-{version}-web.zip"
  )

  let rapt_url = &"https://www.renpy.org/dl/{version}/renpy-{version}-rapt.zip"
  let rapt_file = joinPath(
    registry_path,
    &"renpy-{version}-rapt.zip"
  )

  let sdk_url = &"https://www.renpy.org/dl/{version}/renpy-{version}-sdk.zip"
  let sdk_file = joinPath(
    registry_path,
    &"renpy-{version}-sdk.zip"
  )

  if not fileExists(steam_file):
    try:
      echo "Downloading Steam support"
      download(steam_url, steam_file)
    except HttpRequestError:
      if getCurrentExceptionMsg() == "404 Not Found":
        echo "Not supported on this version, skipping"
      else:
        raise getCurrentException()
    except KeyboardInterrupt:
      echo "Aborted, cleaning up."
      removeFile(steam_file)
      quit(1)

  if not fileExists(web_file):
    try:
      echo "Downloading Web Support"
      download(web_url, web_file)
    except KeyboardInterrupt:
      echo "Aborted, cleaning up."
      removeFile(web_file)
      quit(1)

  if not fileExists(rapt_file):
    try:
      echo "Downloading RAPT"
      download(rapt_url, rapt_file)
    except KeyboardInterrupt:
      echo "Aborted, cleaning up."
      removeFile(rapt_file)
      quit(1)

  if not fileExists(sdk_file):
    try:
      echo "Downloading Ren'Py"
      download(sdk_url, sdk_file)
    except KeyboardInterrupt:
      echo "Aborted, cleaning up."
      removeFile(sdk_file)
      removeFile(rapt_file)
      quit(1)

  echo "Extracting"
  let path_extracted = joinPath(registry_path, "extracted")

  ### SDK

  extractAll(sdk_file, path_extracted)

  moveDir(
    joinPath(path_extracted, &"renpy-{version}-sdk"),
    joinPath(registry_path, version)
  )

  removeDir(path_extracted)

  ### Steam

  if fileExists(steam_file):
    extractAll(steam_file, path_extracted)

    for path in walkDirRec(path_extracted):
      copyFile(path, joinPath(registry_path, version, relativePath(path, path_extracted)))

    removeDir(path_extracted)

  ### Web

  extractAll(web_file, path_extracted)

  moveDir(
    joinPath(path_extracted, "web"),
    joinPath(registry_path, version, "web")
  )

  removeDir(path_extracted)

  ### RAPT

  extractAll(rapt_file, path_extracted)

  moveDir(
    joinPath(path_extracted, "rapt"),
    joinPath(registry_path, version, "rapt")
  )

  removeDir(path_extracted)

  ###

  if not no_cleanup:
    removeFile(steam_file)
    removeFile(web_file)
    removeFile(rapt_file)
    removeFile(sdk_file)

  echo "Setting up permissions"
  let (python, base_file) = get_exe(version, registry_path)

  let paths = case hostOS:
    of "windows":
      [
          joinPath(splitPath(python)[0], "python.exe"),
          joinPath(splitPath(python)[0], "pythonw.exe"),
          joinPath(splitPath(python)[0], "renpy.exe"),
          joinPath(splitPath(python)[0], "zsync.exe"),
          joinPath(splitPath(python)[0], "zsyncmake.exe"),
          joinPath(registry_path, version, "rapt", "prototype", "gradlew.exe"),
          joinPath(registry_path, version, "rapt", "project", "gradlew.exe"),
      ]
    else:
      [
          joinPath(splitPath(python)[0], "python"),
          joinPath(splitPath(python)[0], "pythonw"),
          joinPath(splitPath(python)[0], "renpy"),
          joinPath(splitPath(python)[0], "zsync"),
          joinPath(splitPath(python)[0], "zsyncmake"),
          joinPath(registry_path, version, "rapt", "prototype", "gradlew"),
          joinPath(registry_path, version, "rapt", "project", "gradlew"),
      ]

  for path in paths:
    if fileExists(path):
      setFilePermissions(path, {fpUserRead, fpUserExec})

  let original_dir = getCurrentDir()
  setCurrentDir(joinPath(registry_path, version, "rapt"))

  if not fileExists("android.keystore"):
    echo "Generating Application Keystore"
    let java_home = getEnv("JAVA_HOME")
    if java_home == "":
      echo "JAVA_HOME is empty. Please check if you need to install OpenJDK 8."
      quit(1)
    let keytool_path = quoteShell(joinPath(java_home, "bin", "keytool"))
    let dname = "renutil"
    discard execProcess(&"{keytool_path} -genkey -keystore android.keystore -alias android -keyalg RSA -keysize 2048 -keypass android -storepass android -dname CN={dname} -validity 20000")

  if not fileExists("bundle.keystore"):
    echo "Generating Bundle Keystore"
    let java_home = getEnv("JAVA_HOME")
    if java_home == "":
      echo "JAVA_HOME is empty. Please check if you need to install OpenJDK 8."
      quit(1)
    let keytool_path = quoteShell(joinPath(java_home, "bin", "keytool"))
    let dname = "renutil"
    discard execProcess(&"{keytool_path} -genkey -keystore bundle.keystore -alias android -keyalg RSA -keysize 2048 -keypass android -storepass android -dname CN={dname} -validity 20000")

  echo "Preparing RAPT"
  let interface_file_source = joinPath(target_dir, "rapt", "buildlib", "rapt", "interface.py")
  let interface_file_target = joinPath(target_dir, "rapt", "buildlib", "rapt", "interface.py.new")

  var strm_in = newFileStream(interface_file_source, fmRead)
  var strm_out = newFileStream(interface_file_target, fmWrite)

  var
    line = ""
    is_patched = false
  let ssl_patch = "import ssl; ssl._create_default_https_context = ssl._create_unverified_context"

  while strm_in.readLine(line):
    if line == ssl_patch:
      is_patched = true
    if not is_patched and line == "":
      strm_out.writeLine(ssl_patch)
      is_patched = true
    else:
      strm_out.writeLine(line)

  strm_in.close()
  strm_out.close()

  removeFile(interface_file_source)
  moveFile(interface_file_target, interface_file_source)

  # TODO: tweak gradle.properties RAM allocation

  echo "Installing RAPT"
  if version >= "7.5.0":
    # in versions above 7.5.0, the RAPT installer tries to import renpy.compat
    # this is not in the path by default, and since PYTHONPATH is ignored, we
    # symlink it instead to make it visible during installation.
    createSymlink(
      joinPath(registry_path, version, "renpy"),
      joinPath(registry_path, version, "rapt", "renpy")
    )

  putEnv("RAPT_NO_TERMS", "1")
  let err = execCmd(&"{python} -EO android.py installsdk")

  setCurrentDir(original_dir)

proc cleanup*(version: string, registry = "") =
  ## Cleans up temporary directories for the given version of Ren'Py.
  let registry_path = get_registry(registry)

  if not is_installed(version, registry_path):
    echo &"{version} is not installed."
    quit(1)

  let paths = [
    joinPath(registry_path, version, "tmp"),
    joinPath(registry_path, version, "rapt", "assets"),
    joinPath(registry_path, version, "rapt", "bin"),
    joinPath(registry_path, version, "rapt", "project", "app", "build"),
    joinPath(
      registry_path, version,
      "rapt", "project", "app",
      "src", "main", "assets"
    ),
  ]

  for path in paths:
    if dirExists(path):
      removeDir(path)

proc uninstall*(version: string, registry = "") =
  ## Uninstalls the given version of Ren'Py.
  let registry_path = get_registry(registry)

  if not is_installed(version, registry_path):
    echo &"{version} is not installed."
    quit(1)

  removeDir(joinPath(registry_path, version))

when isMainModule:
  dispatchMulti(
    [list, help = {
        "n": "The number of items to show. Shows all by default.",
        "all": "If given, shows remote versions.",
        "registry": "The registry to use. Defaults to ~/.renutil",
    }],
    [show, help = {
        "version": "The version to show.",
        "registry": "The registry to use. Defaults to ~/.renutil",
    }],
    [launch, help = {
        "version": "The version to launch.",
        "headless": "If given, disables audio and video drivers for headless operation.",
        "direct": "If given, invokes Ren'Py directly without the launcher project.",
        "args": "The arguments to forward to Ren'Py.",
        "registry": "The registry to use. Defaults to ~/.renutil",
    }],
    [install, help = {
        "version": "The version to install.",
        "registry": "The registry to use. Defaults to ~/.renutil",
        "no-cleanup": "If given, retains installation files.",
    }],
    [cleanup, help = {
        "version": "The version to clean up.",
        "registry": "The registry to use. Defaults to ~/.renutil",
    }],
    [uninstall, help = {
        "version": "The version to uninstall.",
        "registry": "The registry to use. Defaults to ~/.renutil",
    }],
  )
