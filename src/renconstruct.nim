import os
import base64
import system
import cligen
import tables
import semver
import streams
import strutils
import strformat
import parsetoml
# import strtabs
# import xmltree
# import xmlparser

import renutil

type KeyboardInterrupt = object of CatchableError

proc handler() {.noconv.} =
  raise newException(KeyboardInterrupt, "Keyboard Interrupt")

setControlCHook(handler)

type
  kv_tuple = tuple[key, val: string]

proc task_post_clean(
  version: string,
  version_semver: Version,
  registry: string,
  output_dir: string
) =
  cleanup(version, registry)
  for kind, path in walkDir(output_dir):
    if kind != pcFile:
      continue
    if version_semver < newVersion(7, 4, 9):
      if path.endswith(".apk") and not path.endswith("-universal-release.apk"):
        removeFile(path)

proc task_pre_keystore() =
  # overwrite keystore file with the one from config.toml
  discard

proc task_post_notarize() =
  # run renotize
  discard

proc validate*(config: var TomlValueRef) =
  if "build" notin config:
    echo "Section 'build' not found, please add it."
    quit(1)

  if "pc" notin config["build"]:
    config{"pc"} = TomlValueRef(kind: TomlValueKind.Bool, boolVal: false)
  if "win" notin config["build"]:
    config{"win"} = TomlValueRef(kind: TomlValueKind.Bool, boolVal: false)
  if "mac" notin config["build"]:
    config{"mac"} = TomlValueRef(kind: TomlValueKind.Bool, boolVal: false)
  if "web" notin config["build"]:
    config{"web"} = TomlValueRef(kind: TomlValueKind.Bool, boolVal: false)
  if "steam" notin config["build"]:
    config{"steam"} = TomlValueRef(kind: TomlValueKind.Bool, boolVal: false)
  if "market" notin config["build"]:
    config{"market"} = TomlValueRef(kind: TomlValueKind.Bool, boolVal: false)
  if "android_apk" notin config["build"]:
    config{"android_apk"} = TomlValueRef(kind: TomlValueKind.Bool, boolVal: false)
  if "android_aab" notin config["build"]:
    config{"android_aab"} = TomlValueRef(kind: TomlValueKind.Bool, boolVal: false)

  var found_true = false
  for k, v in config["build"].getTable():
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

  if "tasks" notin config:
    config{"tasks", "keystore"} = TomlValueRef(kind: TomlValueKind.Bool, boolVal: false)
    config{"tasks", "clean"} = TomlValueRef(kind: TomlValueKind.Bool, boolVal: false)
    config{"tasks", "notarize"} = TomlValueRef(kind: TomlValueKind.Bool, boolVal: false)
    config{"tasks", "manifest"} = TomlValueRef(kind: TomlValueKind.Bool, boolVal: false)
    config{"tasks", "convert_images"} = TomlValueRef(kind: TomlValueKind.Bool, boolVal: false)

  if "keystore" in config["tasks"]:
    if config["tasks"]["keystore"].getBool() and "task_keystore" notin config:
      echo "Task 'keystore' is enabled but no 'task_keystore' section was found."
      quit(1)
  else:
    config{"keystore"} = TomlValueRef(kind: TomlValueKind.Bool, boolVal: false)

  if "clean" notin config["tasks"]:
    config{"clean"} = TomlValueRef(kind: TomlValueKind.Bool, boolVal: false)

  if "notarize" in config["tasks"]:
    if config["tasks"]["notarize"].getBool() and "task_notarize" notin config:
      echo "Task 'notarize' is enabled but no 'task_notarize' section was found."
      quit(1)
  else:
    config{"notarize"} = TomlValueRef(kind: TomlValueKind.Bool, boolVal: false)

  if "manifest" in config["tasks"]:
    if config["tasks"]["manifest"].getBool() and "task_manifest" notin config:
      echo "Task 'meanifest' is enabled but no 'task_manifest' section was found."
      quit(1)
  else:
    config{"manifest"} = TomlValueRef(kind: TomlValueKind.Bool, boolVal: false)

  if "convert_images" in config["tasks"]:
    if config["tasks"]["convert_images"].getBool() and "task_convert_images" notin config:
      echo "Task 'convert_images' is enabled but no 'task_convert_images' section was found."
      quit(1)
  else:
    config{"convert_images"} = TomlValueRef(kind: TomlValueKind.Bool, boolVal: false)

proc build*(
  input_dir: string,
  output_dir: string,
  config: string,
  registry = ""
) =
  ## Builds a Ren'Py project with the specified configuration.
  var registry_path: string

  var config = parseFile(config)

  config.validate()

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

  let renutil_target_version_semver = parseVersion(renutil_target_version)

  if not (renutil_target_version in list_installed(registry_path)):
    echo(&"Installing Ren'Py {renutil_target_version}")
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

  let keystore_bundle_path = joinPath(
    registry_path,
    renutil_target_version,
    "rapt",
    "bundle.keystore"
  )

  let keystore_bundle_path_backup = joinPath(
    registry_path,
    renutil_target_version,
    "rapt",
    "bundle.keystore.original"
  )

  if config["tasks"]["keystore"].getBool():
    var keystore = getEnv(
      "RC_KEYSTORE_APK",
      getEnv("RC_KEYSTORE"), # for backwards-compatibility
    )

    if keystore == "" and "keystore_apk" in config["task_keystore"]:
      keystore = config["task_keystore"]["keystore_apk"].getStr()
    if keystore == "":
      keystore = config["task_keystore"]["keystore"].getStr()

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
      keystore = config["task_keystore"]["keystore_aab"].getStr()

    if keystore == "":
      echo("Keystore override was requested, but no AAB keystore could be found.")
      quit(1)

    if not fileExists(keystore_bundle_path_backup):
      moveFile(keystore_bundle_path, keystore_bundle_path_backup)

    let stream_out_ks_bundle = newFileStream(keystore_bundle_path, fmWrite)
    stream_out_ks_bundle.write(decode(keystore))
    stream_out_ks_bundle.close()

  # update manifest file
  discard """
  let manifest_path = joinPath(
    registry_path,
    renutil_target_version,
    "rapt",
    "templates",
    "app-AndroidManifest.xml",
  )
  let data = loadXml(manifest_path)
  let application_tag = data.findAll("application")[0]

  let dict: StringTableRef = application_tag.attrs
  if config["tasks"]["manifest"].getBool() and
    config["task_manifest"]["legacy_storage"].getBool():
    dict["android:requestLegacyExternalStorage"] = "true"
  else:
    dict["android:requestLegacyExternalStorage"] = "false"

  var kv_list = newSeq[kv_tuple]()
  for k, v in dict:
    kv_list.add((k, v))

  application_tag.attrs = kv_list.toXmlAttributes

  let f = open(manifest_path, fmWrite)
  f.write("<?xml version=\"1.0\" encoding=\"utf-8\"?>")
  f.write($data)
  f.close()
  """

  if config["build"]["android_apk"].getBool() or
    config["build"]["android"].getBool(): # for backwards-compatibility with older config files
    echo("Building Android APK package.")
    if renutil_target_version_semver >= newVersion(7, 4, 9):
      launch(
        renutil_target_version,
        false,
        false,
        &"android_build {input_dir} --dest {absolutePath(output_dir)}",
        registry_path
      )
    else:
      launch(
        renutil_target_version,
        false,
        false,
        &"android_build {input_dir} assembleRelease --dest {absolutePath(output_dir)}",
        registry_path
      )

  if config["build"]["android_aab"].getBool():
    echo("Building Android AAB package.")
    if renutil_target_version_semver >= newVersion(7, 4, 9):
      launch(
        renutil_target_version,
        false,
        false,
        &"android_build {input_dir} --bundle --dest {absolutePath(output_dir)}",
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
    var cmd = &"distribute {input_dir} --destination {absolutePath(output_dir)}"
    for package in platforms_to_build:
      cmd = cmd & &" --package {package}"
    let joined_packages = join(platforms_to_build, ", ")

    echo(&"Building {joined_packages} packages.")
    launch(
      renutil_target_version,
      false,
      false,
      cmd,
      registry_path
    )

  if config["tasks"]["notarize"].getBool():
    task_post_notarize()

  if config["tasks"]["clean"].getBool():
    task_post_clean(
      renutil_target_version,
      renutil_target_version_semver,
      registry_path,
      output_dir
    )

  if config["tasks"]["keystore"].getBool() and fileExists(keystore_path_backup):
    moveFile(keystore_path_backup, keystore_path)
    moveFile(keystore_bundle_path_backup, keystore_bundle_path)

when isMainModule:
  try:
    dispatchMulti(
      [build, help = {
          "input_dir": "The Ren'Py project to build.",
          "output_dir": "The directory to output distributions to.",
          "config": "The configuration file to use.",
          "registry": "The registry to use. Defaults to ~/.renutil",
      }],
    )
  except KeyboardInterrupt:
    echo "\nAborted by SIGINT"
    quit(1)
