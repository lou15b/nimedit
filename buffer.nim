# Implementation uses a gap buffer with explicit undo stack.

import strutils, unicode
import styles, highlighters
import sdl2, sdl2/ttf
import buffertype, unihelp, languages
from os import splitFile

const
  tabWidth = 2

include drawbuffer

proc newBuffer*(heading: string; mgr: ptr StyleManager): Buffer =
  new(result)
  result.front = @[]
  result.back = @[]
  result.filename = ""
  result.heading = heading
  result.actions = @[]
  result.mgr = mgr
  result.eofChar = '\L'
  result.readOnly = -2

proc clear*(result: Buffer) =
  result.front.setLen 0
  result.back.setLen 0
  result.actions.setLen 0
  result.currentLine = 0
  result.firstLine = 0
  result.numberOfLines = 0
  result.desiredCol = 0
  result.cursor = 0

proc fullText*(b: Buffer): string =
  result = newStringOfCap(b.front.len + b.back.len)
  for i in 0..<b.front.len:
    result.add b.front[i].c
  for i in countdown(b.back.len-1, 0):
    result.add b.back[i].c

template edit(b: Buffer) =
  b.undoIdx = b.actions.len-1

proc prepareForEdit(b: Buffer) =
  if b.cursor < b.front.len:
    for i in countdown(b.front.len-1, b.cursor):
      b.back.add(b.front[i])
    setLen(b.front, b.cursor)
  elif b.cursor > b.front.len:
    let chars = max(b.cursor - b.front.len, 0)
    var took = 0
    for i in countdown(b.back.len-1, max(b.back.len-chars, 0)):
      b.front.add(b.back[i])
      inc took
    setLen(b.back, b.back.len - took)
    #if b.cursor != b.front.len:
    #  echo b.cursor, " ", b.front.len
    b.cursor = b.front.len
  assert b.cursor == b.front.len
  b.changed = true

proc scroll(b: Buffer; amount: int) =
  inc b.currentLine, amount
  if b.currentLine < b.firstLine:
    b.firstLine = b.currentLine
  elif b.currentLine > b.firstLine + b.span-1:
    inc b.firstLine

proc getColumn*(b: Buffer): int =
  var i = b.cursor
  while i > 0 and b[i-1] != '\L':
    dec i
  while i < b.cursor and b[i] != '\L':
    i += graphemeLen(b, i)
    inc result

proc getLastLine*(b: Buffer): string =
  var i = b.len
  while i > 0 and b[i-1] != '\L': dec i
  result = ""
  for j in i..<b.len:
    result.add b[j]

proc left*(b: Buffer; jump: bool) =
  if b.cursor > 0:
    let r = lastRune(b, b.cursor-1)
    if r[0] == Rune('\L'):
      scroll(b, -1)
    b.cursor -= r[1]
    b.desiredCol = getColumn(b)

proc right*(b: Buffer; jump: bool) =
  if b.cursor < b.front.len+b.back.len:
    if b[b.cursor] == '\L':
      scroll(b, 1)
    b.cursor += graphemeLen(b, b.cursor)
    b.desiredCol = getColumn(b)

proc getLine*(b: Buffer): int = b.currentLine

proc up*(b: Buffer; jump: bool) =
  var col = b.desiredCol
  var i = b.cursor

  # move to the *start* of this line
  while i >= 1 and b[i-1] != '\L': dec i
  if i >= 1 and b[i-1] == '\L':
    # move up 1 line:
    dec i
    # move to the *start* of this line
    while i >= 1 and b[i-1] != '\L': dec i
    # move to the desired column:
    while i >= 0 and col > 0 and b[i] != '\L':
      i += graphemeLen(b, i)
      dec col
    scroll(b, -1)
  b.cursor = i
  if b.cursor < 0: b.cursor = 0

proc down*(b: Buffer; jump: bool) =
  var col = b.desiredCol

  let L = b.front.len+b.back.len
  while b.cursor < L:
    if b[b.cursor] == '\L':
      scroll(b, 1)
      break
    b.cursor += 1
  b.cursor += 1

  while b.cursor < L and col > 0:
    if b[b.cursor] == '\L': break
    dec col
    b.cursor += 1
  if b.cursor > L: b.cursor = L
  if b.cursor < 0: b.cursor = 0

proc rawInsert*(b: Buffer; s: string) =
  for i in 0..<s.len:
    case s[i]
    of '\L':
      b.front.add Cell(c: '\L')
      inc b.numberOfLines
      inc b.currentLine
    of '\C':
      if i < s.len-1 and s[i+1] != '\L':
        b.front.add Cell(c: '\L')
        inc b.numberOfLines
        inc b.currentLine
    of '\t':
      for i in 1..tabWidth:
        b.front.add Cell(c: ' ')
    else:
      b.front.add Cell(c: s[i])
  b.cursor += s.len

proc loadFromFile*(b: Buffer; filename: string) =
  clear(b)
  b.filename = filename
  b.lang = fileExtToLanguage(splitFile(filename).ext)
  let s = readFile(filename)
  for i in 0..<s.len:
    case s[i]
    of '\L':
      b.front.add Cell(c: '\L')
      inc b.numberOfLines
      if b.lineending.isNil:
        b.lineending = "\L"
    of '\C':
      if i < s.len-1 and s[i+1] != '\L':
        b.front.add Cell(c: '\L')
        inc b.numberOfLines
        if b.lineending.isNil:
          b.lineending = "\C"
      elif b.lineending.isNil:
        b.lineending = "\C\L"
    of '\t':
      for i in 1..tabWidth:
        b.front.add Cell(c: ' ')
    else:
      b.front.add Cell(c: s[i])
  if b.lang != langNone:
    highlightEverything(b, b.lang)

proc save*(b: Buffer) =
  if b.filename.len == 0: b.filename = b.heading
  let f = open(b.filename, fmWrite)
  if b.lineending.isNil:
    b.lineending = "\L"
  let L = b.len
  var i = 0
  while i < L:
    let ch = b[i]
    if ch > ' ':
      f.write(ch)
    elif ch == ' ':
      let j = i
      while b[i] == ' ': inc i
      if b[i] == '\L':
        f.write(b.lineending)
      else:
        for ii in j..i-1:
          f.write(' ')
        dec i
    elif ch == '\L':
      f.write(b.lineending)
    else:
      f.write(ch)
    inc(i)
  f.close
  b.changed = false

proc saveAs*(b: Buffer; filename: string) =
  b.filename = filename
  save(b)

proc insert*(b: Buffer; s: string) =
  if b.cursor <= b.readOnly: return
  prepareForEdit(b)
  setLen(b.actions, clamp(b.undoIdx+1, 0, b.actions.len))
  if b.actions.len > 0 and b.actions[^1].k == ins:
    b.actions[^1].word.add s
  else:
    b.actions.add(Action(k: ins, pos: b.cursor, word: s))
  if s[^1] in Whitespace: b.actions[^1].k = insFinished
  edit(b)
  rawInsert(b, s)
  b.desiredCol = getColumn(b)

proc rawBackspace(b: Buffer; overrideUtf8=false): string =
  assert b.cursor == b.front.len
  var x = 0
  let ch = b.front[b.cursor-1].c
  if ch.ord < 128 or overrideUtf8:
    x = 1
    if ch == '\L': dec b.numberOfLines
  else:
    while true:
      let (r, L) = lastRune(b, b.cursor-1-x)
      inc(x, L)
      if L > 1 and isCombining(r): discard
      else: break
  # we need to reverse this string here:
  result = newString(x)
  var j = 0
  for i in countdown(b.front.len-1, b.front.len-x):
    result[j] = b.front[i].c
    inc j
  b.cursor -= result.len
  b.front.setLen(b.cursor)

proc backspace*(b: Buffer; overrideUtf8=false) =
  if b.cursor <= 0: return
  if b.cursor-1 <= b.readOnly: return
  prepareForEdit(b)
  setLen(b.actions, clamp(b.undoIdx+1, 0, b.actions.len))
  let ch = b.rawBackspace(overrideUtf8)
  if b.actions.len > 0 and b.actions[^1].k == dele:
    b.actions[^1].word.add ch
  else:
    b.actions.add(Action(k: dele, pos: b.cursor, word: ch))
  edit(b)
  if ch.len == 1 and ch[0] in Whitespace: b.actions[^1].k = delFinished
  b.desiredCol = getColumn(b)

proc applyUndo(b: Buffer; a: Action) =
  if a.k <= insFinished:
    b.cursor = a.pos + a.word.len
    prepareForEdit(b)
    b.cursor = a.pos
    # reverse op of insert is delete:
    b.front.setLen(b.cursor)
  else:
    b.cursor = a.pos
    prepareForEdit(b)
    # reverse op of delete is insert:
    for i in countdown(a.word.len-1, 0):
      b.front.add Cell(c: a.word[i])
    b.cursor += a.word.len

proc applyRedo(b: Buffer; a: Action) =
  if a.k <= insFinished:
    b.cursor = a.pos
    prepareForEdit(b)
    # reverse op of delete is insert:
    for i in countup(0, a.word.len-1):
      b.front.add Cell(c: a.word[i])
    b.cursor += a.word.len
  else:
    b.cursor = a.pos + a.word.len
    prepareForEdit(b)
    b.cursor = a.pos
    # reverse op of insert is delete:
    b.front.setLen(b.cursor)

proc undo*(b: Buffer) =
  when defined(debugUndo):
    echo "undo ----------------------------------------"
    for i, x in b.actions:
      if i == b.undoIdx:
        echo x, "*"
      else:
        echo x
  if b.undoIdx >= 0 and b.undoIdx < b.actions.len:
    applyUndo(b, b.actions[b.undoIdx])
    dec(b.undoIdx)

proc redo*(b: Buffer) =
  when defined(debugUndo):
    echo "redo ----------------------------------------"
    inc(b.undoIdx)
    for i, x in b.actions:
      if i == b.undoIdx:
        echo x, "*"
      else:
        echo x
  if b.undoIdx >= 0 and b.undoIdx < b.actions.len:
    applyRedo(b, b.actions[b.undoIdx])
  else:
    dec b.undoIdx
