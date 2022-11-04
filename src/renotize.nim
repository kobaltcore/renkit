import std/os
import std/nre
import std/json
import std/osproc
import std/options
import std/strutils
import std/sequtils
import std/strformat

import parsetoml
import zippy/ziparchives
when isMainModule: import cligen

import lib/common

const rcodesignBin = staticRead("../rcodesign")

let rcodesignPath = getTempDir() / "rcodesign"
if execCmdEx(&"{rcodesignPath} -V").exitCode != 0:
  writeFile(rcodesignPath, rcodesignBin)
  setFilePermissions(rcodesignPath, {fpUserRead, fpUserWrite, fpUserExec})

type KeyboardInterrupt = object of CatchableError

proc handler() {.noconv.} =
  raise newException(KeyboardInterrupt, "Keyboard Interrupt")

setControlCHook(handler)

proc unpackApp*(inputFile: string, outputDir = "") =
  ## Unpacks the given ZIP file to the target directory.
  var targetDir = outputDir
  if targetDir != "" and dirExists(targetDir):
    removeDir(targetDir)
  if targetDir == "":
    targetDir = inputFile
    removeSuffix(targetDir, ".zip")

  extractAll(inputFile, targetDir)

  let extractedFile = walkDirs(joinPath(targetDir, "*.app")).toSeq()[0]
  let newTargetDir = joinPath(splitPath(targetDir)[0], splitPath(extractedFile)[1])
  moveFile(extractedFile, newTargetDir)
  removeDir(targetDir)

proc signApp*(inputFile: string, identity: string) =
  ## Signs a .app bundle with the given Developer Identity.
  let entitlements = """<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/></dict></plist>"""

  writeFile("entitlements.plist", entitlements)

  discard execCmd(&"{rcodesignPath}")
  let cmd = &"codesign --entitlements=entitlements.plist --options=runtime --timestamp -s '{identity}' -f --deep --no-strict {inputFile}"
  discard execShellCmd(cmd)

  removeFile("entitlements.plist")

proc notarizeApp*(
  inputFile: string,
  bundleId: string,
  appleId: string,
  password: string,
  altoolExtra = "",
): string =
  ## Notarizes a .app bundle with the given Developer Account and bundle ID.
  var appZip = inputFile
  removeSuffix(appZip, ".app")
  appZip = &"{appZip}-app.zip"

  let archive = ZipArchive()
  let (head, tail) = splitPath(inputFile)
  archive.addDir(head, tail)
  archive.writeZipArchive(appZip)

  let cmd = &"xcrun altool {altoolExtra} -u {appleId} -p {password} --notarize-app --primary-bundle-id {bundleId} -f {appZip}"
  let output = execProcess(cmd)
  echo output

  let match = find(output, re"RequestUUID = ([A-z0-9-]+)")
  if match.isNone:
    echo "Could not retrieve UUID"
    quit(1)

  let uuid = match.get.captures[0]

  return uuid

proc stapleApp*(inputFile: string) =
  ## Staples a notarization certificate to a .app bundle.
  let cmd = &"xcrun stapler staple {inputFile}"
  discard execShellCmd(cmd)

proc packDmg*(
  inputFile: string,
  outputFile: string,
  volumeName = "",
) =
  ## Packages a .app bundle into a .dmg file.
  var vName = volumeName
  if volumeName == "":
    vName = splitFile(inputFile).name
  let cmd = &"hdiutil create -fs HFS+ -format UDBZ -ov -volname {vName} -srcfolder {inputFile} {outputFile}"
  discard execShellCmd(cmd)

proc signDmg*(inputFile: string, identity: string) =
  ## Signs a .dmg file with the given Developer Identity.
  let cmd = &"codesign --timestamp -s {identity} -f {inputFile}"
  discard execShellCmd(cmd)

proc notarizeDmg*(
  inputFile: string,
  bundleId: string,
  appleId: string,
  password: string,
  altoolExtra = "",
): string =
  ## Notarizes a .dmg file with the given Developer Account and bundle ID.
  let cmd = &"xcrun altool {altoolExtra} -u {appleId} -p {password} --notarize-app --primary-bundle-id {bundleId} -f {inputFile}"
  let output = execProcess(cmd)
  echo output

  let match = find(output, re"RequestUUID = ([A-z0-9-]+)")
  if match.isNone:
    echo "Could not retrieve UUID"
    quit(1)

  let uuid = match.get.captures[0]

  return uuid

proc stapleDmg*(inputFile: string) =
  ## Staples a notarization certificate to a .dmg file.
  let cmd = &"xcrun stapler staple {inputFile}"
  discard execShellCmd(cmd)

proc status*(
  uuid: string,
  appleId: string,
  password: string,
  altoolExtra = "",
): string =
  ## Checks the status of a notarization operation given its UUID.
  let cmd = &"xcrun altool {altoolExtra} -u {appleId} -p {password} --notarization-info {uuid} --output-format json"
  let data = parseJson(execProcess(cmd))

  var status = "not started"
  if "notarization-info" in data:
    status = data["notarization-info"]["Status"].getStr()

  return status

proc fullRun*(inputFile: string, config: JsonNode) =
  # Programmatic interface for the full run operation to allow
  # dynamically passing in configuration data from memory at runtime.
  let
    altoolExtra = config["altool_extra"].getStr()
    bundleId = config["bundle_id"].getStr()
    identity = config["identity"].getStr()
    appleId = config["apple_id"].getStr()
    password = config["password"].getStr()

  var
    uuid: string
    status: string

  echo "Unpacking app"
  unpack_app(inputFile)

  let appFile = walkDirs(joinPath(splitPath(inputFile)[0], "*.app")).toSeq()[0]

  echo "Signing app"
  sign_app(appFile, identity)

  echo "Notarizing app"
  uuid = notarize_app(appFile, bundleId, appleId, password, altoolExtra)

  echo "Waiting for notarization"
  status = status(uuid, appleId, password, altoolExtra)
  while status != "success" and status != "invalid":
    echo "."
    status = status(uuid, appleId, password, altoolExtra)
    sleep(10_000)

  echo "Stapling app"
  staple_app(appFile)

  echo "Signing stapled app"
  sign_app(appFile, identity)

  let (dir, name, _) = splitFile(appFile)
  let dmgFile = &"{joinPath(dir, name)}.dmg"

  echo "Packing DMG"
  pack_dmg(appFile, dmgFile)

  echo "Signing DMG"
  sign_dmg(dmgFile, identity)

  echo "Notarizing DMG"
  uuid = notarize_dmg(dmgFile, bundleId, appleId, password, altoolExtra)

  echo "Waiting for notarization"
  status = status(uuid, appleId, password, altoolExtra)
  while status != "success" and status != "invalid":
    echo "."
    status = status(uuid, appleId, password, altoolExtra)
    sleep(10_000)

  echo "Stapling DMG"
  staple_dmg(dmgFile)

  echo "Cleaning up"
  removeFile("*-app.zip")
  removeDir("extracted distro")

  echo "Done"

proc fullRunCli*(inputFile: string, config = "") =
  ## Fully notarize a given .app bundle, creating a signed
  ## and notarized artifact for distribution.
  let configObj = if config == "":
    %*{
      "apple_id": getEnv("RN_APPLE_ID"),
      "password": getEnv("RN_PASSWORD"),
      "identity": getEnv("RN_IDENTITY"),
      "bundle_id": getEnv("RN_BUNDLE_ID"),
      "altool_extra": getEnv("RN_ALTOOL_EXTRA"),
    }
  else:
    parsetoml.parseFile(config).convert_to_json()

  let emptyKey = block:
    var result = false
    for k, v in configObj:
      if k == "altool_extra":
        continue
      if v.getStr() == "":
        result = true
        break
    result

  if emptyKey:
    echo "No configuration data was found via config file or environment."
    quit(1)

  full_run(inputFile, config_obj)

when isMainModule:
  dispatchMulti(
    [unpack_app, help = {
        "input_file": "The path to the ZIP file containing the .app bundle.",
        "output_dir": "The directory to extract the .app bundle to.",
    }],
    [sign_app, help = {
        "input_file": "The path to the .app bundle.",
        "identity": "The ID of your developer certificate.",
    }],
    [notarize_app, help = {
        "input_file": "The path to the .app bundle.",
        "bundle_id": "The name/ID to use for the notarized bundle.",
        "apple_id": "Your Apple ID, generally your e-Mail.",
        "password": "Your app-specific password.",
        "altool_extra": "Extra arguments for altool.",
    }],
    [staple_app, help = {
        "input_file": "The path to the .app bundle.",
    }],
    [pack_dmg, help = {
        "input_file": "The path to the .app bundle.",
        "output_file": "The name of the DMG file to write to.",
        "volume_name": "The name to use for the DMG volume. By default the base name of the input file."
    }],
    [sign_dmg, help = {
        "input_file": "The path to the .dmg file.",
        "identity": "The ID of your developer certificate.",
    }],
    [notarize_dmg, help = {
        "input_file": "The path to the .dmg file.",
        "bundle_id": "The name/ID to use for the notarized bundle.",
        "apple_id": "Your Apple ID, generally your e-Mail.",
        "password": "Your app-specific password.",
        "altool_extra": "Extra arguments for altool.",
    }],
    [staple_dmg, help = {
        "input_file": "The path to the .dmg file.",
    }],
    [status, help = {
        "uuid": "The UUID of the notarization operation.",
        "apple_id": "Your Apple ID, generally your e-Mail.",
        "password": "Your app-specific password.",
        "altool_extra": "Extra arguments for altool.",
    }],
    [full_run_cli, cmdName = "full_run", help = {
        "input_file": "The path to the the ZIP file containing the .app bundle.",
        "config": "The path to the config.toml file to use for this process.",
    }],
  )
