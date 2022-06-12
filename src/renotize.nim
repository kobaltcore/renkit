import std/os
import std/nre
import std/json
import std/osproc
import std/options
import std/strutils
import std/sequtils
import std/strformat

import cligen
import parsetoml
import zippy/internal
import zippy/ziparchives

import lib/common

type KeyboardInterrupt = object of CatchableError

proc handler() {.noconv.} =
  raise newException(KeyboardInterrupt, "Keyboard Interrupt")

setControlCHook(handler)

proc unpack_app*(input_file: string, output_dir = "") =
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
  let entitlements = """<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/></dict></plist>"""

  writeFile("entitlements.plist", entitlements)

  let cmd = &"codesign --entitlements=entitlements.plist --options=runtime --timestamp -s '{identity}' -f --deep --no-strict {input_file}"
  discard execShellCmd(cmd)

  removeFile("entitlements.plist")

proc addDir(archive: ZipArchive, base, relative: string) =
  if relative.len > 0 and relative notin archive.contents:
    archive.contents[(relative & os.DirSep).toUnixPath()] =
      ArchiveEntry(kind: ekDirectory)

  for kind, path in walkDir(base / relative, relative = true):
    case kind:
    of pcFile:
      archive.contents[(relative / path).toUnixPath()] = ArchiveEntry(
        kind: ekFile,
        contents: readFile(base / relative / path),
        lastModified: getLastModificationTime(base / relative / path),
      )
    of pcDir:
      archive.addDir(base, relative / path)
    else:
      discard

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
  let cmd = &"xcrun stapler staple {input_file}"
  discard execShellCmd(cmd)

proc pack_dmg*(
  input_file: string,
  output_file: string,
  volume_name = "",
) =
  var v_name = volume_name
  if volume_name == "":
    v_name = splitFile(input_file).name
  let cmd = &"hdiutil create -fs HFS+ -format UDBZ -ov -volname {v_name} -srcfolder {input_file} {output_file}"
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

proc full_run_prog*(input_file: string, config: JsonNode) =
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

proc full_run*(input_file: string, config: string) =
  let config = parsetoml.parseFile(config).convert_to_json()
  full_run_prog(input_file, config)

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
