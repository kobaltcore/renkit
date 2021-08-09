import os
# import osproc
import base64
import system
import cligen
import streams
import strutils
import strformat
import parsetoml

# import nimpy
# import nimpy / py_lib

# pyInitLibPath("/usr/local/Cellar/python@3.9/3.9.6/Frameworks/Python.framework/Versions/3.9/lib/libpython3.9.dylib")
# pyInitLibPath(execProcess("which python").strip())
# pyInitLibPath(execProcess("python -c 'from distutils import sysconfig; print(sysconfig.get_config_var(\"LIBDIR\"))' | xargs -I{} find {} -name \"libpython*\" -maxdepth 1").strip())

import renutil

type KeyboardInterrupt = object of CatchableError

proc handler() {.noconv.} =
  raise newException(KeyboardInterrupt, "Keyboard Interrupt")

setControlCHook(handler)

proc task_post_clean(version: string, registry: string, output_dir: string) =
  cleanup(version, registry)
  for kind, path in walkDir(output_dir):
    if kind != pcFile:
      continue
    if path.endswith(".apk") and not path.endswith("-universal-release.apk"):
      removeFile(path)

proc task_pre_keystore() =
  # overwrite keystore file with the one from config.toml
  discard

proc task_post_notarize() =
  # run renotize
  discard

proc build(
  input_dir: string,
  output_dir: string,
  config: string,
  registry = ""
) =
  ## Builds a Ren'Py project with the specified configuration.
  var registry_path: string

  let config = parseFile(config)

  if registry != "":
    registry_path = get_registry(registry)
  elif "registry" in config["renutil"]:
    registry_path = get_registry(config["renutil"]["registry"].getStr())
  else:
    registry_path = get_registry(registry)

  if not dirExists(input_dir):
    createDir(input_dir)

  if dirExists(output_dir):
    removeDir(output_dir)

  createDir(output_dir)

  var renutil_target_version = config["renutil"]["version"].getStr()

  if renutil_target_version == "latest":
    renutil_target_version = list_available()[0]

  if not (renutil_target_version in list_installed(registry_path)):
    echo(&"Installing Renpy {renutil_target_version}")
    install(renutil_target_version, registry_path)

  let keystore_path = joinPath(
    registry_path,
    renutil_target_version,
    "rapt",
    "android.keystore"
  )
  let keystore_path_backup = joinPath(
    registry_path,
    renutil_target_version,
    "rapt",
    "android.keystore.original"
  )

  if config["tasks"]["keystore"].getBool():
    var keystore = getEnv("RC_KEYSTORE")
    if keystore == "":
      keystore = config["task_keystore"]["keystore"].getStr()
    if keystore == "":
      echo("Keystore override was requested, but no keystore could be found.")
      quit(1)
    if not fileExists(keystore_path_backup):
      moveFile(keystore_path, keystore_path_backup)
    let stream_out = newFileStream(keystore_path, fmWrite)
    stream_out.write(decode(keystore))
    stream_out.close()

  # setCurrentDir("tasks")

  # let pysys = pyImport("sys")
  # echo pysys.version
  # echo pysys.path

  # let clean = pyImport("tasks.clean")
  # echo clean
  # echo "Current dir is: ", os.getcwd().to(string)

  # return

  if config["build"]["android"].getBool():
    echo("Building Android package.")
    try:
      launch(
        renutil_target_version,
        false,
        false,
        &"android_build {input_dir} assembleRelease --destination {output_dir}",
        registry_path
      )
    except KeyboardInterrupt:
      echo("Aborted.")
      quit(1)

  var platforms_to_build: seq[string]
  if config["build"]["pc"].getBool():
    platforms_to_build.add("pc")
  if config["build"]["mac"].getBool():
    platforms_to_build.add("mac")

  if len(platforms_to_build) > 0:
    var cmd = &"distribute {input_dir} --destination {output_dir}"
    for package in platforms_to_build:
      cmd = cmd & &" --package {package}"
    let joined_packages = join(platforms_to_build, ", ")
    echo(&"Building {joined_packages} packages.")
    echo cmd
    try:
      launch(
        renutil_target_version,
        false,
        false,
        cmd,
        registry_path
      )
    except KeyboardInterrupt:
      echo("Aborted.")
      quit(1)

  if config["tasks"]["clean"].getBool():
    task_post_clean(renutil_target_version, registry_path, output_dir)

  if config["tasks"]["notarize"].getBool():
    task_post_notarize()

  if config["tasks"]["keystore"].getBool() and fileExists(keystore_path_backup):
    moveFile(keystore_path_backup, keystore_path)

when isMainModule:
  dispatchMulti(
    [build, help = {
        "input_dir": "The Ren'Py project to build",
        "output_dir": "The directory to output distributions to.",
        "config": "The configuration file to use.",
        "registry": "The registry to use. Defaults to ~/.renutil",
    }],
  )
