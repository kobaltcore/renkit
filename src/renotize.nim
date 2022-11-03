import std/os
import std/nre
import std/json
import std/osproc
import std/options
import std/strutils
import std/sequtils
import std/strformat
import std/tempfiles

import parsetoml
import zippy/ziparchives
when isMainModule: import cligen

import lib/common

const rcodesignBin = staticRead("../rcodesign")

let (cfile, rcodesignPath) = createTempFile("renkit", "rcodesign")
cfile.write(rcodesignBin)
cfile.close()
setFilePermissions(rcodesignPath, {fpUserRead, fpUserWrite, fpUserExec})

type KeyboardInterrupt = object of CatchableError

proc handler() {.noconv.} =
  raise newException(KeyboardInterrupt, "Keyboard Interrupt")

setControlCHook(handler)

proc unpack_app*(input_file: string, output_dir = "") =
  ## Unpacks the given ZIP file to the target directory.
  var target_dir = output_dir
  if target_dir != "" and dirExists(target_dir):
    removeDir(target_dir)
  if target_dir == "":
    target_dir = input_file
    removeSuffix(target_dir, ".zip")

  extractAll(input_file, target_dir)

  let extracted_file = walkDirs(joinPath(target_dir, "*.app")).toSeq()[0]
  let new_target_dir = joinPath(splitPath(target_dir)[0], splitPath(extracted_file)[1])
  moveFile(extracted_file, new_target_dir)
  removeDir(target_dir)

proc sign_app*(input_file: string, identity: string) =
  ## Signs a .app bundle with the given Developer Identity.
  let entitlements = """<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/></dict></plist>"""

  writeFile("entitlements.plist", entitlements)

  discard execCmd(&"{rcodesignPath}")
  let cmd = &"codesign --entitlements=entitlements.plist --options=runtime --timestamp -s '{identity}' -f --deep --no-strict {input_file}"
  discard execShellCmd(cmd)

  removeFile("entitlements.plist")

proc notarize_app*(
  input_file: string,
  bundle_id: string,
  apple_id: string,
  password: string,
  altool_extra = "",
): string =
  ## Notarizes a .app bundle with the given Developer Account and bundle ID.
  var app_zip = input_file
  removeSuffix(app_zip, ".app")
  app_zip = &"{app_zip}-app.zip"

  let archive = ZipArchive()
  let (head, tail) = splitPath(input_file)
  archive.addDir(head, tail)
  archive.writeZipArchive(app_zip)

  let cmd = &"xcrun altool {altool_extra} -u {apple_id} -p {password} --notarize-app --primary-bundle-id {bundle_id} -f {app_zip}"
  let output = execProcess(cmd)
  echo output

  let match = find(output, re"RequestUUID = ([A-z0-9-]+)")
  if match.isNone:
    echo "Could not retrieve UUID"
    quit(1)

  let uuid = match.get.captures[0]

  return uuid

proc staple_app*(input_file: string) =
  ## Staples a notarization certificate to a .app bundle.
  let cmd = &"xcrun stapler staple {input_file}"
  discard execShellCmd(cmd)

proc pack_dmg*(
  input_file: string,
  output_file: string,
  volume_name = "",
) =
  ## Packages a .app bundle into a .dmg file.
  var v_name = volume_name
  if volume_name == "":
    v_name = splitFile(input_file).name
  let cmd = &"hdiutil create -fs HFS+ -format UDBZ -ov -volname {v_name} -srcfolder {input_file} {output_file}"
  discard execShellCmd(cmd)

proc sign_dmg*(input_file: string, identity: string) =
  ## Signs a .dmg file with the given Developer Identity.
  let cmd = &"codesign --timestamp -s {identity} -f {input_file}"
  discard execShellCmd(cmd)

proc notarize_dmg*(
  input_file: string,
  bundle_id: string,
  apple_id: string,
  password: string,
  altool_extra = "",
): string =
  ## Notarizes a .dmg file with the given Developer Account and bundle ID.
  let cmd = &"xcrun altool {altool_extra} -u {apple_id} -p {password} --notarize-app --primary-bundle-id {bundle_id} -f {input_file}"
  let output = execProcess(cmd)
  echo output

  let match = find(output, re"RequestUUID = ([A-z0-9-]+)")
  if match.isNone:
    echo "Could not retrieve UUID"
    quit(1)

  let uuid = match.get.captures[0]

  return uuid

proc staple_dmg*(input_file: string) =
  ## Staples a notarization certificate to a .dmg file.
  let cmd = &"xcrun stapler staple {input_file}"
  discard execShellCmd(cmd)

proc status*(
  uuid: string,
  apple_id: string,
  password: string,
  altool_extra = "",
): string =
  ## Checks the status of a notarization operation given its UUID.
  let cmd = &"xcrun altool {altool_extra} -u {apple_id} -p {password} --notarization-info {uuid} --output-format json"
  let data = parseJson(execProcess(cmd))

  var status = "not started"
  if "notarization-info" in data:
    status = data["notarization-info"]["Status"].getStr()

  return status

proc full_run*(input_file: string, config: JsonNode) =
  # Programmatic interface for the full run operation to allow
  # dynamically passing in configuration data from memory at runtime.
  let
    altool_extra = config["altool_extra"].getStr()
    bundle_id = config["bundle_id"].getStr()
    identity = config["identity"].getStr()
    apple_id = config["apple_id"].getStr()
    password = config["password"].getStr()

  var
    uuid: string
    status: string

  echo "Unpacking app"
  unpack_app(input_file)

  let app_file = walkDirs(joinPath(splitPath(input_file)[0], "*.app")).toSeq()[0]

  echo "Signing app"
  sign_app(app_file, identity)

  echo "Notarizing app"
  uuid = notarize_app(app_file, bundle_id, apple_id, password, altool_extra)

  echo "Waiting for notarization"
  status = status(uuid, apple_id, password, altool_extra)
  while status != "success" and status != "invalid":
    echo "."
    status = status(uuid, apple_id, password, altool_extra)
    sleep(10_000)

  echo "Stapling app"
  staple_app(app_file)

  echo "Signing stapled app"
  sign_app(app_file, identity)

  let (dir, name, ext) = splitFile(app_file)
  let dmg_file = &"{joinPath(dir, name)}.dmg"

  echo "Packing DMG"
  pack_dmg(app_file, dmg_file)

  echo "Signing DMG"
  sign_dmg(dmg_file, identity)

  echo "Notarizing DMG"
  uuid = notarize_dmg(dmg_file, bundle_id, apple_id, password, altool_extra)

  echo "Waiting for notarization"
  status = status(uuid, apple_id, password, altool_extra)
  while status != "success" and status != "invalid":
    echo "."
    status = status(uuid, apple_id, password, altool_extra)
    sleep(10_000)

  echo "Stapling DMG"
  staple_dmg(dmg_file)

  echo "Cleaning up"
  removeFile("*-app.zip")
  removeDir("extracted distro")

  echo "Done"

proc full_run_cli*(input_file: string, config = "") =
  ## Fully notarize a given .app bundle, creating a signed
  ## and notarized artifact for distribution.
  let config_obj = if config == "":
    %*{
      "apple_id": getEnv("RN_APPLE_ID"),
      "password": getEnv("RN_PASSWORD"),
      "identity": getEnv("RN_IDENTITY"),
      "bundle_id": getEnv("RN_BUNDLE_ID"),
      "altool_extra": getEnv("RN_ALTOOL_EXTRA"),
    }
  else:
    parsetoml.parseFile(config).convert_to_json()

  let empty_key = block:
    var result = false
    for k, v in config_obj:
      if k == "altool_extra":
        continue
      if v.getStr() == "":
        result = true
        break
    result

  if empty_key:
    echo "No configuration data was found via config file or environment."
    quit(1)

  full_run(input_file, config_obj)

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
