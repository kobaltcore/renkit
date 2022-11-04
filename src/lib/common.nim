import std/os
import std/json
import std/strutils
import std/sequtils
import std/httpclient

import suru
import semver
import parsetoml
import zippy/internal
import zippy/ziparchives

import suru_utils

proc toString*(s: seq[char]): string =
  result = newStringOfCap(len(s))
  for ch in s:
    add(result, ch)

proc toSnakeCase*(s: string): string =
  var newString: seq[char]
  for i, c in s:
    if c.isUpperAscii():
      if i != 0:
        newString.add("_")
      newString.add(c.toLowerAscii())
    else:
      newString.add(c)
  return newString.to_string

proc download*(url, path: string) =
  var bar: SuruBar = initSuruBar()

  proc onProgressChanged(total, progress, speed: BiggestInt) =
    bar[0].progress = progress.int
    bar.update(500_000_000)

  let client = newHttpClient()

  let r = client.head(url)
  let contentLengths = seq[string](r.headers.getOrDefault("Content-Length"))
  let contentLength = case contentLengths.len:
    of 1:
      if content_lengths[0] == "": -1 else: content_lengths[0].parseint
    else:
      -1

  bar.format = suru_format
  bar[0].total = content_length
  bar.setup()

  client.onProgressChanged = onProgressChanged

  try:
    client.downloadFile(url, path)
  finally:
    bar[0].progress = bar[0].total
    bar.update(10_000_000)
    bar.finish()

proc convertToJson*(value: TomlValueRef): JsonNode =
  case value.kind:
    of TomlValueKind.Int:
      %value.intVal
    of TomlValueKind.Float:
      %value.floatVal
    of TomlValueKind.Bool:
      %value.boolVal
    of TomlValueKind.Datetime:
      %value.dateTimeVal
    of TomlValueKind.Date:
      %value.dateVal
    of TomlValueKind.Time:
      %value.timeVal
    of TomlValueKind.String:
      %value.stringVal
    of TomlValueKind.Array:
      if value.arrayVal.len == 0:
        %[]
      elif value.arrayVal[0].kind == TomlValueKind.Table:
        %value.arrayVal.map(convert_to_json)
      else:
        %*value.arrayVal.map(convert_to_json)
    of TomlValueKind.Table:
      result = %*{}
      for k, v in value.tableVal:
        result[k] = v.convert_to_json
      return result
    of TomlValueKind.None:
      %nil

proc findFiles*(
  inputDir: string,
  path: string,
  extensions: seq[string],
  recursive = true
): seq[string] =
  let fullPath = joinPath(inputDir, path)

  if recursive:
    for file in walkDirRec(fullPath):
      for ext in extensions:
        if file.endsWith(ext):
          result.add(file)
  else:
    for file in walkFiles(joinPath(fullPath, "*")):
      for ext in extensions:
        if file.endsWith(ext):
          result.add(file)

proc isNumeric(s: string): bool =
  result = true
  for c in s:
    if not isDigit(c):
      return false

proc compare*(v1: Version, v2: Version, ignoreBuild: bool = false): int =
  ## Compare two versions
  ##
  ## -1 == v1 is less than v2
  ## 0 == v1 is equal to v2
  ## 1 == v1 is greater than v2

  let cmpMajor = cmp(v1.major, v2.major)
  let cmpMinor = cmp(v1.minor, v2.minor)
  let cmpPatch = cmp(v1.patch, v2.patch)

  if cmpMajor != 0:
    return cmpMajor
  if cmpMinor != 0:
    return cmpMinor
  if cmpPatch != 0:
    return cmpPatch

  if not ignoreBuild:
    # Comparison if a version has no prerelease versions
    if len(v1.build) == 0 and len(v2.build) == 0:
      return 0
    elif len(v1.build) == 0 and len(v2.build) > 0:
      return 1
    elif len(v1.build) > 0 and len(v2.build) == 0:
      return -1

    # split build version by dots and compare each identifier
    var
      i = 0
      build1 = split(v1.build, ".")
      build2 = split(v2.build, ".")
      comp: int
    while i < len(build1) and i < len(build2):
      if isNumeric(build1[i]) and isNumeric(build2[i]):
        comp = cmp(parseInt(build1[i]), parseInt(build2[i]))
      else:
        comp = cmp(build1[i], build2[i])
      if comp == 0:
        inc(i)
        continue
      else:
        return comp
      inc(i)

    # If build versions are the equal but one have further build version
    if i == len(build1) and i == len(build2):
      return 0
    elif i == len(build1) and i < len(build2):
      return -1
    else:
      return 1

  return 0

proc addDir*(archive: ZipArchive, base, relative: string) =
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
