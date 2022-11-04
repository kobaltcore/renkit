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

proc taskPreConvertImages*(
  config: JsonNode,
  inputDir: string,
  outputDir: string,
) =
  for path, options in config{"tasks", "convert_images"}:
    if path == "enabled":
      continue

    let
      lossless = options{"lossless"}.getBool(true)
      recursive = options{"recursive"}.getBool(true)
      extensions = options{"extensions"}.getElems(@[%"png", %"jpg"]).mapIt(it.getStr())

    let files = inputDir.findFiles(path, extensions, recursive)

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
        cmds.add(&"cwebp -lossless -z 9 -m 6 {quoteShell(file)} -o {quoteShell(file)}")
    else:
      for file in files:
        cmds.add(&"cwebp -q 90 -m 6 -sharp_yuv -pre 4 {quoteShell(file)} -o {quoteShell(file)}")

    discard execProcesses(cmds, n = countProcessors(), options = {poUsePath})

proc taskPostClean*(
  config: JsonNode,
  inputDir: string,
  outputDir: string,
) =
  let version = config{"renutil", "version"}.getStr().parseVersion()
  let registry = config{"renutil", "registry"}.getStr()
  cleanup($version, registry)
  if version < newVersion(7, 4, 9):
    for kind, path in walkDir(outputDir):
      if kind != pcFile:
        continue
      if path.endswith(".apk") and not path.endswith("-universal-release.apk"):
        removeFile(path)

proc taskPostNotarize*(
  config: JsonNode,
  inputDir: string,
  outputDir: string,
) =
  let files = walkFiles(joinPath(outputDir, "*-mac.zip")).toSeq
  if files.len != 1:
    echo "Could not find macOS ZIP file."
    quit(1)
  fullRun(
    files[0],
    config{"tasks", "notarize", "key_file"}.getStr(),
    config{"tasks", "notarize", "cert_file"}.getStr(),
    config{"tasks", "notarize", "app_store_key_file"}.getStr()
  )

proc taskPreKeystore*(
  config: JsonNode,
  inputDir: string,
  outputDir: string,
) =
  let
    version = config{"renutil", "version"}.getStr()
    registry = config{"renutil", "registry"}.getStr()
    keystorePath = joinPath(registry, version, "rapt", "android.keystore")
    keystorePathBackup = joinPath(registry, version, "rapt", "android.keystore.original")
    keystoreBundlePath = joinPath(registry, version, "rapt", "bundle.keystore")
    keystoreBundlePathBackup = joinPath(registry, version, "rapt", "bundle.keystore.original")

  var keystore = getEnv("RC_KEYSTORE_APK")

  if keystore == "":
    keystore = config{"tasks", "keystore", "keystore_apk"}.getStr()

  if keystore == "":
    echo "Keystore override was requested, but no APK keystore could be found."
    quit(1)

  if not fileExists(keystorePathBackup):
    moveFile(keystorePath, keystorePathBackup)

  let streamOutKsApk = newFileStream(keystorePath, fmWrite)
  streamOutKsApk.write(decode(keystore))
  streamOutKsApk.close()

  keystore = getEnv("RC_KEYSTORE_AAB")

  if keystore == "":
    keystore = config{"tasks", "keystore", "keystore_aab"}.getStr()

  if keystore == "":
    echo "Keystore override was requested, but no AAB keystore could be found."
    quit(1)

  if not fileExists(keystoreBundlePathBackup):
    moveFile(keystoreBundlePath, keystoreBundlePathBackup)

  let streamOutKsBundle = newFileStream(keystoreBundlePath, fmWrite)
  streamOutKsBundle.write(decode(keystore))
  streamOutKsBundle.close()

proc taskPostKeystore*(
  config: JsonNode,
  inputDir: string,
  outputDir: string,
) =
  let
    version = config{"renutil", "version"}.getStr()
    registry = config{"renutil", "registry"}.getStr()
    keystorePath = joinPath(registry, version, "rapt", "android.keystore")
    keystorePathBackup = joinPath(registry, version, "rapt", "android.keystore.original")
    keystoreBundlePath = joinPath(registry, version, "rapt", "bundle.keystore")
    keystoreBundlePathBackup = joinPath(registry, version, "rapt", "bundle.keystore.original")

  if fileExists(keystorePathBackup):
    moveFile(keystorePathBackup, keystorePath)

  if fileExists(keystoreBundlePathBackup):
    moveFile(keystoreBundlePathBackup, keystoreBundlePath)
