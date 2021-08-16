import os
import nre
import json
import osproc
import cligen
import options
import strutils
import strformat
import parsetoml
import zippy/ziparchives

type KeyboardInterrupt = object of CatchableError

proc handler() {.noconv.} =
  raise newException(KeyboardInterrupt, "Keyboard Interrupt")

setControlCHook(handler)

proc unpack_app*(input_file: string, output_dir = "") =
  var target_dir = output_dir
  if target_dir != "" and dirExists(target_dir):
    removeDir(target_dir)
  if target_dir == "":
    target_dir = splitPath(input_file)[0]
  extractAll(input_file, target_dir)

proc sign_app*(input_file: string, identity: string) =
  let entitlements = """<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/></dict></plist>"""

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
  var app_zip = input_file
  removeSuffix(app_zip, ".app")
  app_zip = &"{app_zip}-app.zip"

  createZipArchive(input_file, app_zip)

  let cmd = &"xcrun altool {altool_extra} -u {apple_id} -p {password} --notarize-app --primary-bundle-id {bundle_id} -f {app_zip}"
  let output = execProcess(cmd)
  echo(output)

  let match = find(output, re"RequestUUID = ([A-z0-9-]+)")
  if match.isNone:
    echo("Could not retrieve UUID")
    quit(1)

  let uuid = match.get.captures[1]

  return uuid

proc staple_app*(input_file: string) =
  let cmd = &"xcrun stapler staple {input_file}"
  discard execShellCmd(cmd)

proc pack_dmg*(
  input_file: string,
  output_file: string,
  volume_name = "",
) =
  let cmd = &"hdiutil create -fs HFS+ -format UDBZ -ov -volname {volume_name} -srcfolder {input_file} {output_file}"
  discard execShellCmd(cmd)

proc sign_dmg*(input_file: string, identity: string) =
  let cmd = &"codesign --timestamp -s {identity} -f {input_file}"
  discard execShellCmd(cmd)

proc notarize_dmg*(
  input_file: string,
  bundle_id: string,
  apple_id: string,
  password: string,
  altool_extra = "",
): string =
  # zip input, then notarize that zip file

  let cmd = &"xcrun altool {altool_extra} -u {apple_id} -p {password} --notarize-app --primary-bundle-id {bundle_id} -f {input_file}"
  let output = execProcess(cmd)
  echo(output)

  let match = find(output, re"RequestUUID = ([A-z0-9-]+)")
  if match.isNone:
    echo("Could not retrieve UUID")
    quit(1)

  let uuid = match.get.captures[1]

  return uuid

proc staple_dmg*(input_file: string) =
  let cmd = &"xcrun stapler staple {input_file}"
  discard execShellCmd(cmd)

proc status*(
  uuid: string,
  apple_id: string,
  password: string,
  altool_extra = "",
): string =
  let cmd = &"xcrun altool {altool_extra} -u {apple_id} -p {password} --notarization-info {uuid} --output-format json"
  let data = parseJson(execProcess(cmd))

  var status = "not started"
  if "notarization-info" in data:
    status = data["notarization-info"]["Status"].getStr()

  return status

proc full_run*(input_file: string, config: string) =
  var
    uuid: string
    status: string
    base_name: string

  let config = parsetoml.parseFile(config)
  let altool_extra = config["config"]["altool_extra"].getStr()
  let bundle_id = config["config"]["bundle_id"].getStr()
  let identity = config["config"]["identity"].getStr()
  let apple_id = config["config"]["apple_id"].getStr()
  let password = config["config"]["password"].getStr()

  unpack_app(input_file)

  base_name = input_file
  removeSuffix(base_name, ".zip")

  let app_file = &"{base_name}.app"
  let dmg_file = &"{base_name}.dmg"

  sign_app(&"{base_name}.app", identity)

  uuid = notarize_app(app_file, bundle_id, apple_id, password, altool_extra)

  status = status(uuid, apple_id, password, altool_extra)
  while status != "success" or status != "invalid":
    status = status(uuid, apple_id, password, altool_extra)
    sleep(10_000)

  staple_app(app_file)

  sign_app(app_file, identity)

  pack_dmg(app_file, dmg_file, base_name)

  sign_dmg(dmg_file, identity)

  uuid = notarize_dmg(dmg_file, bundle_id, apple_id, password, altool_extra)

  status = status(uuid, apple_id, password, altool_extra)
  while status != "success" or status != "invalid":
    status = status(uuid, apple_id, password, altool_extra)
    sleep(10_000)

  staple_dmg(dmg_file)

  removeFile("*-app.zip")
  removeDir("extracted distro")

when isMainModule:
  dispatchMulti(
    [unpack_app],
    [sign_app],
    [notarize_app],
    [staple_app],
    [pack_dmg],
    [sign_dmg],
    [notarize_dmg],
    [staple_dmg],
    [status],
    [full_run],
  )
