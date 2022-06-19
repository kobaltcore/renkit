import system
import std/os
import std/json
import std/base64
import std/osproc
import std/tables
import std/streams
import std/strutils
import std/sequtils
import std/strformat

import semver
import cligen
import parsetoml

import renutil
import renotize
import lib/common

type KeyboardInterrupt = object of CatchableError

proc handler() {.noconv.} =
  raise newException(KeyboardInterrupt, "Keyboard Interrupt")

setControlCHook(handler)

proc task_pre_convert_images(
  input_dir: string,
  config: JsonNode,
  n = countProcessors(),
) =
  for path, options in config{"tasks", "convert_images"}:
    if path == "enabled":
      continue

    let
      lossless = options{"lossless"}.getBool(true)
      recursive = options{"recursive"}.getBool(true)
      extensions = options{"extensions"}.getElems(@[%"png", %"jpg"]).mapIt(it.getStr())

    let files = input_dir.find_files(path, extensions, recursive)

    var attributes: seq[string]
    if recursive:
      attributes.add("recursive")
    if lossless:
      attributes.add("lossless")

    if attributes.len == 0:
      echo &"Processing {path} with {files.len} files"
    else:
      echo &"Processing {path} with {files.len} files ({attributes.join(\", \")})"

    var cmds: seq[string]
    if lossless:
      for file in files:
        cmds.add(&"cwebp -q 90 -m 6 -sharp_yuv -pre 4 {quoteShell(file)} -o {quoteShell(file)}")
    else:
      for file in files:
        cmds.add(&"cwebp -lossless -z 9 -m 6 {quoteShell(file)} -o {quoteShell(file)}")

    discard execProcesses(cmds, n = n, options = {poUsePath})

proc task_post_clean(
  version: Version,
  registry: string,
  output_dir: string
) =
  cleanup($version, registry)
  if version < newVersion(7, 4, 9):
    for kind, path in walkDir(output_dir):
      if kind != pcFile:
        continue
      if path.endswith(".apk") and not path.endswith("-universal-release.apk"):
        removeFile(path)

proc task_post_notarize(input_file: string, config: JsonNode) =
  full_run(input_file, config{"tasks", "notarize"})

proc validate*(config: JsonNode) =
  if "build" notin config:
    echo "Section 'build' not found, please add it."
    quit(1)

  if "pc" notin config["build"]:
    config{"pc"} = %false
  if "win" notin config["build"]:
    config{"win"} = %false
  if "linux" notin config["build"]:
    config{"linux"} = %false
  if "mac" notin config["build"]:
    config{"mac"} = %false
  if "web" notin config["build"]:
    config{"web"} = %false
  if "steam" notin config["build"]:
    config{"steam"} = %false
  if "market" notin config["build"]:
    config{"market"} = %false
  if "android_apk" notin config["build"]:
    config{"android_apk"} = %false
  if "android_aab" notin config["build"]:
    config{"android_aab"} = %false

  var found_true = false
  for k, v in config["build"]:
    if v.getBool():
      found_true = true
      break

  if not found_true:
    echo "No option is enabled in the 'build' section."
    quit(1)

  if "renutil" notin config:
    echo "Section 'renutil' not found, please add it."
    quit(1)

  if "version" notin config["renutil"]:
    echo "Please specify the Ren'Py version in the 'renutil' section."
    quit(1)

  if config{"renutil", "version"}.getStr() == "latest":
    config{"renutil", "version"} = %list_available()[0]

  let renpy_version = config{"renutil", "version"}.getStr()
  echo &"Using Ren'Py version {renpy_version}"

  if config{"build", "web"}.getBool() and renpy_version < "7.3.0":
    echo "The 'web' build is not supported on versions below 7.3.0."
    quit(1)

  if "tasks" notin config:
    config{"tasks", "clean", "enabled"} = %false
    config{"tasks", "notarize", "enabled"} = %false
    config{"tasks", "keystore", "enabled"} = %false
    config{"tasks", "convert_images", "enabled"} = %false

  if "clean" notin config["tasks"]:
    config{"tasks", "clean", "enabled"} = %false

  if "notarize" notin config["tasks"]:
    config{"tasks", "notarize", "enabled"} = %false

  if "keystore" notin config["tasks"]:
    config{"tasks", "keystore", "enabled"} = %false

  if "convert_images" notin config["tasks"]:
    config{"tasks", "convert_images", "enabled"} = %false

  if "options" notin config:
    config{"options", "clear_output_dir"} = %false

  if "clear_output_dir" notin config["options"]:
    config{"options", "clear_output_dir"} = %false

proc build*(
  input_dir: string,
  output_dir: string,
  config: string,
  registry = ""
) =
  ## Builds a Ren'Py project with the specified configuration.
  var registry_path: string

  var config = parsetoml.parseFile(config).convert_to_json()

  config.validate()

  if registry != "":
    registry_path = get_registry(registry)
  elif "registry" in config["renutil"]:
    registry_path = get_registry(config["renutil"]["registry"].getStr())
  else:
    registry_path = get_registry(registry)

  # scan for tasks
  # each task is a file with a shebang that takes care of running itself
  # we pass in input_dir, output_dir, config
  #!/usr/bin/env bash
  # let success = execShellCmd(&"./test.py {input_dir} {output_dir} {quoteShell($config.convert_to_json)}")
  # if success != 0:
  #   echo "Task failed"
  #   return

  if not dirExists(input_dir):
    echo(&"Game directory '{input_dir}' does not exist.")
    quit(1)

  if config["options"]["clear_output_dir"].getBool() and dirExists(output_dir):
    removeDir(output_dir)

  createDir(output_dir)

  let renutil_target_version = parseVersion(config["renutil"]["version"].getStr())

  if not is_installed(renutil_target_version, registry_path):
    echo(&"Installing Ren'Py {renutil_target_version}")
    install($renutil_target_version, registry_path)

  if config{"tasks", "convert_images", "enabled"}.getBool():
    echo "Converting images"
    task_pre_convert_images(input_dir, config)

  let keystore_path = joinPath(
    registry_path,
    $renutil_target_version,
    "rapt",
    "android.keystore"
  )

  let keystore_path_backup = joinPath(
    registry_path,
    $renutil_target_version,
    "rapt",
    "android.keystore.original"
  )

  let keystore_bundle_path = joinPath(
    registry_path,
    $renutil_target_version,
    "rapt",
    "bundle.keystore"
  )

  let keystore_bundle_path_backup = joinPath(
    registry_path,
    $renutil_target_version,
    "rapt",
    "bundle.keystore.original"
  )

  if config{"tasks", "keystore", "enabled"}.getBool():
    var keystore = getEnv("RC_KEYSTORE_APK")

    if keystore == "":
      keystore = config{"tasks", "keystore", "keystore_apk"}.getStr()

    if keystore == "":
      echo("Keystore override was requested, but no APK keystore could be found.")
      quit(1)

    if not fileExists(keystore_path_backup):
      moveFile(keystore_path, keystore_path_backup)

    let stream_out_ks_apk = newFileStream(keystore_path, fmWrite)
    stream_out_ks_apk.write(decode(keystore))
    stream_out_ks_apk.close()

    keystore = getEnv("RC_KEYSTORE_AAB")

    if keystore == "":
      keystore = config{"tasks", "keystore", "keystore_aab"}.getStr()

    if keystore == "":
      echo("Keystore override was requested, but no AAB keystore could be found.")
      quit(1)

    if not fileExists(keystore_bundle_path_backup):
      moveFile(keystore_bundle_path, keystore_bundle_path_backup)

    let stream_out_ks_bundle = newFileStream(keystore_bundle_path, fmWrite)
    stream_out_ks_bundle.write(decode(keystore))
    stream_out_ks_bundle.close()

  if config["build"]["android_apk"].getBool() or
    config{"build", "android"}.getBool(): # for backwards-compatibility with older config files
    echo("Building Android APK package.")
    if renutil_target_version >= newVersion(7, 4, 9):
      launch(
        $renutil_target_version,
        false,
        false,
        &"android_build {quoteShell(input_dir)} --dest {quoteShell(absolutePath(output_dir))}",
        registry_path
      )
    else:
      launch(
        $renutil_target_version,
        false,
        false,
        &"android_build {quoteShell(input_dir)} assembleRelease --dest {quoteShell(absolutePath(output_dir))}",
        registry_path
      )

  if config["build"]["android_aab"].getBool():
    echo("Building Android AAB package.")
    if renutil_target_version >= newVersion(7, 4, 9):
      launch(
        $renutil_target_version,
        false,
        false,
        &"android_build {quoteShell(input_dir)} --bundle --dest {quoteShell(absolutePath(output_dir))}",
        registry_path
      )
    else:
      echo "Not supported for Ren'Py versions <7.4.9"
      quit(1)

  var platforms_to_build: seq[string]
  if "pc" in config["build"] and config["build"]["pc"].getBool():
    platforms_to_build.add("pc")
  if "mac" in config["build"] and config["build"]["mac"].getBool():
    platforms_to_build.add("mac")
  if "win" in config["build"] and config["build"]["win"].getBool():
    platforms_to_build.add("win")
  if "linux" in config["build"] and config["build"]["linux"].getBool():
    platforms_to_build.add("linux")
  if "market" in config["build"] and config["build"]["market"].getBool():
    platforms_to_build.add("market")
  if "steam" in config["build"] and config["build"]["steam"].getBool():
    platforms_to_build.add("steam")
  if "web" in config["build"] and config["build"]["web"].getBool():
    # make out_dir = {project-name}-{version}-web directory in output directory
    # modify build command:
    # --destination {out_dir} --packagedest joinPath(out_dir, "game") --package web --no-archive
    # TODO: somehow trigger repack_for_progressive_download()
    # copy files from {version}/web except for hash.txt to the web output directory
    # modify index.html and replace %%TITLE%% with the game's display name
    platforms_to_build.add("web")

  if len(platforms_to_build) > 0:
    var cmd = &"distribute {quoteShell(input_dir)} --destination {quoteShell(absolutePath(output_dir))}"
    for package in platforms_to_build:
      cmd = cmd & &" --package {package}"
    let joined_packages = join(platforms_to_build, ", ")

    echo(&"Building {joined_packages} packages.")
    launch(
      $renutil_target_version,
      false,
      false,
      cmd,
      registry_path
    )

  if config{"tasks", "notarize", "enabled"}.getBool():
    let files = walkFiles(joinPath(output_dir, "*-mac.zip")).to_seq
    if files.len != 1:
      echo "Could not find Mac ZIP file."
      quit(1)
    task_post_notarize(files[0], config)

  if config{"tasks", "clean", "enabled"}.getBool():
    task_post_clean(
      renutil_target_version,
      registry_path,
      output_dir
    )

  if config{"tasks", "keystore", "enabled"}.getBool() and fileExists(keystore_path_backup):
    moveFile(keystore_path_backup, keystore_path)
    moveFile(keystore_bundle_path_backup, keystore_bundle_path)

when isMainModule:
  try:
    dispatchMulti(
      [build, help = {
          "input_dir": "The path to the Ren'Py project to build.",
          "output_dir": "The directory to output distributions to.",
          "config": "The path to the configuration file to use.",
          "registry": "The path to the registry directory to use. Defaults to ~/.renutil",
      }],
    )
  except KeyboardInterrupt:
    echo "\nAborted by SIGINT"
    quit(1)
