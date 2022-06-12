import std/os
import std/json
import std/strutils
import std/sequtils
import std/httpclient

import parsetoml

import suru

import suru_utils

proc download*(url, path: string) =
  var bar: SuruBar = initSuruBar()

  proc onProgressChanged(total, progress, speed: BiggestInt) =
    bar[0].progress = progress.int
    bar.update(500_000_000)

  let client = newHttpClient()

  let r = client.head(url)
  let content_lengths = seq[string](r.headers.getOrDefault("Content-Length"))
  let content_length = case content_lengths.len:
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

proc convert_to_json*(value: TomlValueRef): JsonNode =
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

proc find_files*(
  input_dir: string,
  path: string,
  extensions: seq[string],
  recursive = true
): seq[string] =
  let full_path = joinPath(input_dir, path)

  if recursive:
    for file in walkDirRec(full_path):
      for ext in extensions:
        if file.endsWith(ext):
          result.add(file)
  else:
    for file in walkFiles(joinPath(full_path, "*")):
      for ext in extensions:
        if file.endsWith(ext):
          result.add(file)
