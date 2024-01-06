import std/os
import std/json
import std/osproc
import std/base64
import std/streams
import std/strutils
import std/sequtils
import std/strformat

import nimpy
import semver

import common
import ../renutil
import ../renotize

type
  TaskContext* = object
    webpPath*: string
    cavifPath*: string
    gamePath*: string
    outputPath*: string

  Task* = object
    name*: string
    instance*: PyObject
    call*: proc(ctx: TaskContext, config: JsonNode, inputDir: string, outputDir: string)
    builds*: seq[string]
    priority*: int

proc taskPreConvertImages*(
  ctx: TaskContext,
  config: JsonNode,
  inputDir: string,
  outputDir: string,
) =
  let format = config{"tasks", "convert_images", "format"}.getStr()
  for path, options in config{"tasks", "convert_images"}:
    if path == "enabled" or path == "format":
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
        if format == "webp":
          cmds.add(&"{ctx.webpPath} -lossless -z 9 -m 6 {quoteShell(file)} -o {quoteShell(file)}")
        elif format == "avif":
          cmds.add(&"{ctx.cavifPath} -f -Q92 -s3 {quoteShell(file)} -o {quoteShell(file)}")
    else:
      for file in files:
        if format == "webp":
          cmds.add(&"{ctx.webpPath} -q 90 -m 6 -sharp_yuv -pre 4 {quoteShell(file)} -o {quoteShell(file)}")
        elif format == "avif":
          cmds.add(&"{ctx.cavifPath} -f -Q92 -s3 {quoteShell(file)} -o {quoteShell(file)}")

    if execProcesses(cmds, n = countProcessors(), options = {poUsePath}) != 0:
      echo "Failed to convert images."
      quit(1)

proc taskPostClean*(
  ctx: TaskContext,
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
  ctx: TaskContext,
  config: JsonNode,
  inputDir: string,
  outputDir: string,
) =
  let files = walkFiles(joinPath(outputDir, "*-mac.zip")).toSeq
  if files.len != 1:
    echo "Could not find macOS ZIP file."
    quit(1)
  fullRunCli(
    files[0],
    config{"tasks", "notarize", "bundle_identifier"}.getStr(),
    config{"tasks", "notarize", "key_file"}.getStr(),
    config{"tasks", "notarize", "cert_file"}.getStr(),
    config{"tasks", "notarize", "app_store_key_file"}.getStr(),
    config{"tasks", "notarize", "json_bundle_file"}.getStr(),
  )

proc taskPreKeystore*(
  ctx: TaskContext,
  config: JsonNode,
  inputDir: string,
  outputDir: string,
) =
  let
    version = config{"renutil", "version"}.getStr()
    version_parsed = parseVersion(config{"renutil", "version"}.getStr())
    registry = config{"renutil", "registry"}.getStr()

  var
    keystorePath: string
    keystorePathBackup: string
    keystoreBundlePath: string
    keystoreBundlePathBackup: string

  if version_parsed.isLessThan(newVersion(7, 6, 0)) or version_parsed.isLessThan(newVersion(8, 1, 0)):
    keystorePath = joinPath(registry, version, "rapt", "android.keystore")
    keystorePathBackup = joinPath(registry, version, "rapt", "android.keystore.original")
    keystoreBundlePath = joinPath(registry, version, "rapt", "bundle.keystore")
    keystoreBundlePathBackup = joinPath(registry, version, "rapt", "bundle.keystore.original")
  else:
    keystorePath = joinPath(ctx.gamePath, "android.keystore")
    keystorePathBackup = joinPath(ctx.gamePath, "android.keystore.original")
    keystoreBundlePath = joinPath(ctx.gamePath, "bundle.keystore")
    keystoreBundlePathBackup = joinPath(ctx.gamePath, "bundle.keystore.original")

  var keystore = getEnv("RC_KEYSTORE_APK")

  if keystore == "":
    keystore = config{"tasks", "keystore", "keystore_apk"}.getStr()

  if keystore == "":
    echo "Keystore override was requested, but no APK keystore could be found."
    quit(1)

  if fileExists(keystorePath) and not fileExists(keystorePathBackup):
    echo &"Backing up keystore {keystorePath} to {keystorePathBackup}"
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

  if fileExists(keystoreBundlePath) and not fileExists(keystoreBundlePathBackup):
    echo &"Backing up keystore bundle {keystoreBundlePath} to {keystoreBundlePathBackup}"
    moveFile(keystoreBundlePath, keystoreBundlePathBackup)

  echo &"Writing keystore bundle to {keystoreBundlePath}"
  let streamOutKsBundle = newFileStream(keystoreBundlePath, fmWrite)
  streamOutKsBundle.write(decode(keystore))
  streamOutKsBundle.close()

proc taskPostKeystore*(
  ctx: TaskContext,
  config: JsonNode,
  inputDir: string,
  outputDir: string,
) =
  let
    version = config{"renutil", "version"}.getStr()
    version_parsed = parseVersion(config{"renutil", "version"}.getStr())
    registry = config{"renutil", "registry"}.getStr()

  var
    keystorePath: string
    keystorePathBackup: string
    keystoreBundlePath: string
    keystoreBundlePathBackup: string

  if not version_parsed.isLessThan(newVersion(7, 6, 0)) or not version_parsed.isLessThan(newVersion(8, 1, 0)):
    keystorePath = joinPath(registry, version, "rapt", "android.keystore")
    keystorePathBackup = joinPath(registry, version, "rapt", "android.keystore.original")
    keystoreBundlePath = joinPath(registry, version, "rapt", "bundle.keystore")
    keystoreBundlePathBackup = joinPath(registry, version, "rapt", "bundle.keystore.original")
  else:
    keystorePath = joinPath(ctx.gamePath, "android.keystore")
    keystorePathBackup = joinPath(ctx.gamePath, "android.keystore.original")
    keystoreBundlePath = joinPath(ctx.gamePath, "bundle.keystore")
    keystoreBundlePathBackup = joinPath(ctx.gamePath, "bundle.keystore.original")

  if fileExists(keystorePathBackup):
    moveFile(keystorePathBackup, keystorePath)

  if fileExists(keystoreBundlePathBackup):
    moveFile(keystoreBundlePathBackup, keystoreBundlePath)
