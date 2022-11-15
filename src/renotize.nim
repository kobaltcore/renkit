import std/os
import std/json
import std/osproc
import std/strutils
import std/sequtils
import std/browsers
import std/strformat

import zippy/ziparchives
when isMainModule: import cligen

const rcodesignBin = staticRead("../rcodesign")

let rcodesignPath = getTempDir() / "rcodesign"
if execCmdEx(&"{rcodesignPath} -V").exitCode != 0:
  writeFile(rcodesignPath, rcodesignBin)
  setFilePermissions(rcodesignPath, {fpUserRead, fpUserWrite, fpUserExec})

type KeyboardInterrupt = object of CatchableError

proc handler() {.noconv.} =
  raise newException(KeyboardInterrupt, "Keyboard Interrupt")

setControlCHook(handler)

proc provision*() =
  ## Utility method to provision required information for notarization using a step-by-step process.
  # generate private key for code signing request
  discard execCmd("openssl genrsa -out private-key.pem 2048")

  # generate CSR
  discard execCmd(&"{rcodesignPath} generate-certificate-signing-request --pem-source private-key.pem --csr-pem-path csr.pem")

  # upload CSR to apple
  echo "This next step should be completed in the browser."
  echo "Press 'Enter' to open the browser and continue."
  discard readLine(stdin)
  openDefaultBrowser("https://developer.apple.com/account/resources/certificates/add")

  # print step by step instructions
  echo "1. Select 'Developer ID Application' as the certificate type"
  echo "2. Click 'Continue'"
  echo "3. Select the G2 Sub-CA (Xcode 11.4.1 or later) Profile Type"
  echo "4. Select 'csr.pem' using the file picker"
  echo "5. Click 'Continue'"
  echo "6. Click the 'Download' button to download your certificate"
  echo "8. Save the certificate next to the private-key.pem and csr.pem files"

  echo "Press 'Enter' when you have saved the certificate"
  discard readLine(stdin)

  let certFiles = walkFiles(getCurrentDir() / "*.cer").toSeq()
  if certFiles.len == 0:
    echo "No .cer file found in current directory"
    quit(1)

  echo "This next step should be completed in the browser."
  echo "Press 'Enter' to open the browser and continue."
  discard readLine(stdin)
  openDefaultBrowser("https://appstoreconnect.apple.com/access/users")

  echo "1. Click on 'Keys'"
  echo "2. If this is your first time, click on 'Request Access' and wait until it is granted"
  echo "3. Click on 'Generate API Key'"
  echo "4. Enter a name for the key"
  echo "5. For Access, select 'Developer'"
  echo "6. Click on 'Generate'"
  echo "7. Copy the Issuer ID and enter it here: ('Enter' to confirm)"
  let issuerId = readLine(stdin).strip()
  if issuerId.len == 0:
    echo "Issuer ID cannot be empty"
    quit(1)
  echo "8. Copy the Key ID and enter it here: ('Enter' to confirm)"
  let keyId = readLine(stdin).strip()
  if keyId.len == 0:
    echo "Key ID cannot be empty"
    quit(1)
  echo "7. Next to the entry of the newly-created key in the list, click on 'Download API Key'"
  echo "8. In the following pop-up, Click on 'Download'"
  echo "10. Save the downloaded .p8 file next to the private-key.pem and csr.pem files"

  echo "Press 'Enter' when you have saved the certificate"
  discard readLine(stdin)

  # find the first file ending in .p8
  let p8Files = walkFiles(getCurrentDir() / "*.p8").toSeq()
  if p8Files.len == 0:
    echo "No .p8 file found in current directory"
    quit(1)
  discard execCmdEx(&"{rcodesignPath} encode-app-store-connect-api-key -o app-store-key.json {issuerId} {keyId} {p8Files[0]}")

  echo "Success!"
  echo "You can now sign your app using these two files:"
  echo "  - private-key.pem"
  echo &"  - {certFiles[0]}"
  echo "You can also use this file to notarize your app:"
  echo "  - app-store-key.json"

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

proc signApp*(inputFile: string, keyFile: string, certFile: string) =
  ## Signs a .app bundle with the given Developer Identity.
  let entitlements = """<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/></dict></plist>"""

  writeFile("entitlements.plist", entitlements)

  discard execCmd(&"{rcodesignPath} sign -e entitlements.plist --pem-source {keyFile} --der-source {certFile} {inputFile}")

  removeFile("entitlements.plist")

proc notarizeApp*(inputFile: string, appStoreKeyFile: string): string =
  ## Notarizes a .app bundle with the given Developer Account and bundle ID.
  discard execCmd(&"{rcodesignPath} notary-submit --api-key-path {appStoreKeyFile} --staple {inputFile}")

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

proc signDmg*(inputFile: string, keyFile: string, certFile: string) =
  ## Signs a .dmg file with the given Developer Identity.
  discard execCmd(&"{rcodesignPath} sign -e entitlements.plist --pem-source {keyFile} --der-source {certFile} {inputFile}")

proc notarizeDmg*(inputFile: string, appStoreKeyFile: string): string =
  ## Notarizes a .dmg file with the given Developer Account and bundle ID.
  discard execCmd(&"{rcodesignPath} notary-submit --api-key-path {appStoreKeyFile} --staple {inputFile}")

proc status*(uuid: string, appStoreKeyFile: string): string =
  ## Checks the status of a notarization operation given its UUID.
  let data = parseJson(execProcess(&"{rcodesignPath} notary-log --api-key-path {appStoreKeyFile} {uuid}"))

  var status = "not started"
  if "notarization-info" in data:
    status = data["notarization-info"]["Status"].getStr()

  return status

proc fullRun*(inputFile, keyFile, certFile, appStoreKeyFile: string) =
  # Programmatic interface for the full run operation to allow
  # dynamically passing in configuration data from memory at runtime.
  echo "Unpacking app"
  unpackApp(inputFile)

  let appFile = walkDirs(joinPath(splitPath(inputFile)[0], "*.app")).toSeq()[0]

  echo "Signing app"
  signApp(appFile, keyFile, certFile)

  echo "Notarizing app"
  echo notarizeApp(appFile, appStoreKeyFile)

  echo "Signing stapled app"
  signApp(appFile, keyFile, certFile)

  let (dir, name, _) = splitFile(appFile)
  let dmgFile = &"{joinPath(dir, name)}.dmg"

  echo "Packing DMG"
  packDmg(appFile, dmgFile)

  echo "Signing DMG"
  signDmg(dmgFile, keyFile, certFile)

  echo "Notarizing DMG"
  echo notarizeDmg(dmgFile, appStoreKeyFile)

  echo "Cleaning up"
  removeFile("*-app.zip")
  removeDir("extracted distro")

  echo "Done"

proc fullRunCli*(inputFile: string, keyFile = "", certFile = "", appStoreKeyFile = "") =
  ## Fully notarize a given .app bundle, creating a signed
  ## and notarized artifact for distribution.
  var
    keyFileInt: string
    certFileInt: string
    appStoreKeyFileInt: string

  if keyFile == "":
    keyFileInt = getEnv("RN_KEY_FILE")
  else:
    keyFileInt = keyFile
  if certFile == "":
    certFileInt = getEnv("RN_CERT_FILE")
  else:
    certFileInt = certFile
  if appStoreKeyFile == "":
    appStoreKeyFileInt = getEnv("RN_APP_STORE_KEY_FILE")
  else:
    appStoreKeyFileInt = appStoreKeyFile

  if keyFileInt == "" or certFileInt == "" or appStoreKeyFileInt == "":
    echo "No configuration data was found via config file or environment."
    quit(1)

  fullRun(inputFile, keyFileInt, certFileInt, appStoreKeyFileInt)

when isMainModule:
  dispatchMulti(
    [provision],
    [unpackApp, cmdName="unpack-app", help = {
        "input_file": "The path to the ZIP file containing the .app bundle.",
        "output_dir": "The directory to extract the .app bundle to.",
    }],
    [signApp, cmdName="sign-app", help = {
        "input_file": "The path to the .app bundle.",
        "keyFile": "The private key generated via the 'provision' command.",
        "certFile": "The certificate file obtained via the 'provision' command.",
    }],
    [notarizeApp, cmdName="notarize-app", help = {
        "input_file": "The path to the .app bundle.",
        "appStoreKeyFile": "The app-store-key.json file obtained via the 'provision' command.",
    }],
    [packDmg, cmdName="pack-dmg", help = {
        "input_file": "The path to the .app bundle.",
        "output_file": "The name of the DMG file to write to.",
        "volume_name": "The name to use for the DMG volume. By default the base name of the input file."
    }],
    [signDmg, cmdName="sign-dmg", help = {
        "input_file": "The path to the .dmg file.",
        "keyFile": "The private key generated via the 'provision' command.",
        "certFile": "The certificate file obtained via the 'provision' command.",
    }],
    [notarizeDmg, cmdName="notarize-dmg", help = {
        "input_file": "The path to the .dmg file.",
        "appStoreKeyFile": "The app-store-key.json file obtained via the 'provision' command.",
    }],
    [status, help = {
        "uuid": "The UUID of the notarization operation.",
        "appStoreKeyFile": "The app-store-key.json file obtained via the 'provision' command.",
    }],
    [fullRunCli, cmdName = "full-run", help = {
        "input_file": "The path to the the ZIP file containing the .app bundle.",
        "keyFile": "The private key generated via the 'provision' command.",
        "certFile": "The certificate file obtained via the 'provision' command.",
        "appStoreKeyFile": "The app-store-key.json file obtained via the 'provision' command.",
    }],
  )
