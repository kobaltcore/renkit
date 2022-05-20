import std/strutils
import std/httpclient

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
