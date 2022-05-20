import std/strutils
import std/strformat

import suru
import suru/fractional_bar
import suru/common_displays

proc humanize_bytes(bytes: int): string =
  case bytes.abs:
    of 0..1_000:
      &"{bytes.float:.1f}b" # bytes
    of 1_001..1_000_000:
      &"{bytes.float / 1000:.1f}kb" # kilobytes
    of 1_000_001..1_000_000_000:
      &"{bytes.float / 1000 / 1000:.1f}mb" # megabytes
    else:
      &"{bytes.float / 1000 / 1000 / 1000:.1f}gb" # gigabytes

proc suru_progress_display*(ssb: SingleSuruBar): string =
  if ssb.total > 0:
    let total_str = $ssb.total.humanize_bytes
    &"{ssb.progress.humanize_bytes.align(total_str.len, ' ')}/{total_str}"
  else:
    let progressStr = $ssb.progress
    &"{progressStr.align(progressStr.len, ' ')}/" & "?".repeat(progressStr.len)

proc suru_format*(ssb: SingleSuruBar): string {.gcsafe.} =
  &"{ssb.percentDisplay}|{ssb.barDisplay}| {ssb.suru_progress_display} [{ssb.timeDisplay}, {ssb.speedDisplay}]"
