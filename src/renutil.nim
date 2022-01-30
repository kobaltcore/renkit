import os
import nre
import osproc
import system
import cligen
import streams
import strtabs
import xmltree
import strutils
import strformat
import algorithm
import httpclient
import htmlparser
import zippy/ziparchives

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

  return sorted(versions, Descending)

proc list*(n = 0, all = false, registry = "") =
  ## List all available versions of Ren'Py, either local or remote.
  var versions: seq[string]

  var limit = n - 1

  let registry_path = get_registry(registry)

  if all:
    versions = list_available()
  else:
    versions = list_installed(registry_path)

  if limit < 0 or limit > high(versions):
    limit = high(versions)

  for version in versions[0..limit]:
    echo version

proc get_exe*(version: string, registry: string): (string, string) =
  var
    arch: string
    exe = "python"

  if hostOS == "windows":
    if hostCPU == "amd64":
      arch = "windows-x86_64"
    else:
      arch = "windows-i686"
    exe = "python.exe"
  elif hostOS == "linux":
    if hostCPU == "amd64":
      arch = "linux-x86_64"
    else:
      arch = "linux-i686"
  elif hostOS == "macosx":
    if version < "7.4":
      arch = "darwin-x86_64"
    elif version < "8.0":
      arch = "mac-x86_64"
    else:
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
  var cmd: string

  let registry_path = get_registry(registry)

  if not is_installed(version, registry_path):
    echo &"{version} is not installed."
    quit(1)

  let (python, base_file) = get_exe(version, registry_path)
  let base_cmd = &"{python} -EO {base_file}"

  if direct:
    cmd = &"{base_cmd} {args}"
  else:
    let launcher_path = joinPath(registry_path, version, "launcher")
    cmd = &"{base_cmd} {launcher_path} {args}"

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

  let sdk_url = &"https://www.renpy.org/dl/{version}/renpy-{version}-sdk.zip"
  let sdk_file = joinPath(
    registry_path,
    &"renpy-{version}-sdk.zip"
  )

  let rapt_url = &"https://www.renpy.org/dl/{version}/renpy-{version}-rapt.zip"
  let rapt_file = joinPath(
    registry_path,
    &"renpy-{version}-rapt.zip"
  )

  let web_url = &"https://www.renpy.org/dl/{version}/renpy-{version}-web.zip"
  let web_file = joinPath(
    registry_path,
    &"renpy-{version}-web.zip"
  )

  proc onProgressChanged(total, progress, speed: BiggestInt) =
    let prog = int((int(progress) / int(total)) * 100)
    echo &"{prog}% @ {int(speed) / 1_000_000:.2f}Mb/s"

  let client = newHttpClient()
  client.onProgressChanged = onProgressChanged

  try:
    echo "Downloading RAPT"
    client.downloadFile(rapt_url, rapt_file)
  except KeyboardInterrupt:
    echo "Aborted, cleaning up."
    removeFile(rapt_file)
    quit(1)

  try:
    echo "Downloading Web"
    client.downloadFile(web_url, web_file)
  except KeyboardInterrupt:
    echo "Aborted, cleaning up."
    removeFile(web_file)
    quit(1)

  try:
    echo "Downloading Ren'Py"
    client.downloadFile(sdk_url, sdk_file)
  except KeyboardInterrupt:
    echo "Aborted, cleaning up."
    removeFile(sdk_file)
    removeFile(rapt_file)
    quit(1)

  echo "Extracting"
  extractAll(sdk_file, joinPath(registry_path, "extracted"))

  moveDir(
    joinPath(registry_path, "extracted", &"renpy-{version}-sdk"),
    joinPath(registry_path, version)
  )

  removeDir(joinPath(registry_path, "extracted"))

  extractAll(web_file, joinPath(registry_path, "extracted"))

  moveDir(
    joinPath(registry_path, "extracted", "web"),
    joinPath(registry_path, version, "web")
  )

  removeDir(joinPath(registry_path, "extracted"))

  extractAll(rapt_file, joinPath(registry_path, "extracted"))

  moveDir(
    joinPath(registry_path, "extracted", "rapt"),
    joinPath(registry_path, version, "rapt")
  )

  removeDir(joinPath(registry_path, "extracted"))

  if not no_cleanup:
    removeFile(web_file)
    removeFile(sdk_file)
    removeFile(rapt_file)

  echo "Setting up permissions"
  let (python, base_file) = get_exe(version, registry_path)

  var paths: array[0..6, string]
  if hostOS == "windows":
    paths = [
        joinPath(splitPath(python)[0], "python.exe"),
        joinPath(splitPath(python)[0], "pythonw.exe"),
        joinPath(splitPath(python)[0], "renpy.exe"),
        joinPath(splitPath(python)[0], "zsync.exe"),
        joinPath(splitPath(python)[0], "zsyncmake.exe"),
        joinPath(registry_path, version, "rapt", "prototype", "gradlew.exe"),
        joinPath(registry_path, version, "rapt", "project", "gradlew.exe"),
    ]
  else:
    paths = [
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
    let keytool_path = joinPath(java_home, "bin", "keytool")
    let dname = "renutil"
    discard execProcess(&"{keytool_path} -genkey -keystore android.keystore -alias android -keyalg RSA -keysize 2048 -keypass android -storepass android -dname CN={dname} -validity 20000")

  if not fileExists("bundle.keystore"):
    echo "Generating Bundle Keystore"
    let java_home = getEnv("JAVA_HOME")
    if java_home == "":
      echo "JAVA_HOME is empty. Please check if you need to install OpenJDK 8."
      quit(1)
    let keytool_path = joinPath(java_home, "bin", "keytool")
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
  putEnv("RAPT_NO_TERMS", "1")
  discard execCmd(&"{python} -EO android.py installsdk")

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
