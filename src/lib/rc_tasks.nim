import std/os
import std/json
import std/osproc
import std/base64
import std/streams
import std/strutils
import std/sequtils
import std/strformat

import semver

import common
import ../renutil
import ../renotize

proc task_pre_convert_images*(
  config: JsonNode,
  input_dir: string,
  output_dir: string,
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

    discard execProcesses(cmds, n = countProcessors(), options = {poUsePath})

proc task_post_clean*(
  config: JsonNode,
  input_dir: string,
  output_dir: string,
) =
  let version = config{"renutil", "version"}.getStr().parseVersion()
  let registry = config{"renutil", "registry"}.getStr()
  cleanup($version, registry)
  if version < newVersion(7, 4, 9):
    for kind, path in walkDir(output_dir):
      if kind != pcFile:
        continue
      if path.endswith(".apk") and not path.endswith("-universal-release.apk"):
        removeFile(path)

proc task_post_notarize*(
  config: JsonNode,
  input_dir: string,
  output_dir: string,
) =
  let files = walkFiles(joinPath(output_dir, "*-mac.zip")).to_seq
  if files.len != 1:
    echo "Could not find macOS ZIP file."
    quit(1)
  full_run(files[0], config{"tasks", "notarize"})

proc task_pre_keystore*(
  config: JsonNode,
  input_dir: string,
  output_dir: string,
) =
  let
    version = config{"renutil", "version"}.getStr()
    registry = config{"renutil", "registry"}.getStr()
    keystore_path = joinPath(registry, version, "rapt", "android.keystore")
    keystore_path_backup = joinPath(registry, version, "rapt", "android.keystore.original")
    keystore_bundle_path = joinPath(registry, version, "rapt", "bundle.keystore")
    keystore_bundle_path_backup = joinPath(registry, version, "rapt", "bundle.keystore.original")

  var keystore = getEnv("RC_KEYSTORE_APK")

  if keystore == "":
    keystore = config{"tasks", "keystore", "keystore_apk"}.getStr()

  if keystore == "":
    echo "Keystore override was requested, but no APK keystore could be found."
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
    echo "Keystore override was requested, but no AAB keystore could be found."
    quit(1)

  if not fileExists(keystore_bundle_path_backup):
    moveFile(keystore_bundle_path, keystore_bundle_path_backup)

  let stream_out_ks_bundle = newFileStream(keystore_bundle_path, fmWrite)
  stream_out_ks_bundle.write(decode(keystore))
  stream_out_ks_bundle.close()

proc task_post_keystore*(
  config: JsonNode,
  input_dir: string,
  output_dir: string,
) =
  let
    version = config{"renutil", "version"}.getStr()
    registry = config{"renutil", "registry"}.getStr()
    keystore_path = joinPath(registry, version, "rapt", "android.keystore")
    keystore_path_backup = joinPath(registry, version, "rapt", "android.keystore.original")
    keystore_bundle_path = joinPath(registry, version, "rapt", "bundle.keystore")
    keystore_bundle_path_backup = joinPath(registry, version, "rapt", "bundle.keystore.original")

  if fileExists(keystore_path_backup):
    moveFile(keystore_path_backup, keystore_path)

  if fileExists(keystore_bundle_path_backup):
    moveFile(keystore_bundle_path_backup, keystore_bundle_path)
