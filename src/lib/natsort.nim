import pegs
import strutils
import unidecode
import parseutils

type
  Kind = enum fString, fNumber

  KeyItem = object
    case kind: Kind
    of fString: str: string
    of fNumber: num: Natural

  Key = seq[KeyItem]

func cmp(a, b: Key): int =
  ## Compare two keys.
  for i in 0..<min(a.len, b.len):
    let ai = a[i]
    let bi = b[i]
    if ai.kind == bi.kind:
      result = if ai.kind == fString: cmp(ai.str, bi.str) else: cmp(ai.num, bi.num)
      if result != 0: return
    else:
      return if ai.kind == fString: 1 else: -1
  result = if a.len < b.len: -1 else: (if a.len == b.len: 0 else: 1)

proc natOrderKey(str: string): Key =
  ## Return the natural order key for a string.
  # Transform UTF-8 text into ASCII text.
  var s = str.unidecode()

  # Remove leading and trailing white spaces.
  s = s.strip()

  # Make all whitespace characters equivalent and remove adjacent spaces.
  s = s.replace(peg"\s+", " ")

  # Switch to lower case.
  s = s.toLowerAscii()

  # Split into fields.
  var idx = 0
  var val: int
  while idx < s.len:
    var n = s.skipUntil(Digits, start = idx)
    if n != 0:
      result.add KeyItem(kind: fString, str: s[idx..<(idx + n)])
      inc idx, n
    n = s.parseInt(val, start = idx)
    if n != 0:
      result.add KeyItem(kind: fNumber, num: val)
      inc idx, n

proc naturalCmp*(a, b: string): int =
  ## Natural order comparison function.
  cmp(a.natOrderKey, b.natOrderKey)
