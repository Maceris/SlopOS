# 0147: The Line Being Typed Stays Below Output

Status: accepted
Date: 2026-11-02
Related: `0136` (M10's plan, the terminal protocol), `0137` (the terminal service), `0146` (where it came up),
`../design/console-and-sessions.md` §2

## Context
The terminal service writes text where the cursor is, and line editing is the reading program's (`console-and-sessions.md`
§2). Output from another program while a line's being typed landed in the middle of it: typed at the banner, echo's
`ping from the host` and hello's line came out as `ping from the hosthello: heap and random numbers working`. The owner
asked for a shell's behaviour, output above the line being typed, and for the reader to say which line that is rather
than the service guessing.

## Decision
- **`InputLine(text, cursor)`** in the terminal protocol (Hemera's `std/os/slop_os/terminal`, `terminal.input_line`):
  the program reading input hands the terminal the line it's editing, UTF-8, and the cursor as a byte offset in it. An
  empty one takes it away. From a client that isn't reading input, it's ignored; when the reader goes, its line goes.
- **The terminal service keeps it below the output**, in lines: drawn from the start of the row after the output's,
  if that row has something on it, made safe a cluster at a time as written text is (a line break or tab in it shown as
  its substitute), with the cursor where the program says. Before anything else is written, cleared, moved or scrolled
  it's taken away, its rows cleared and the cursor put back where the output left off; after, it's drawn again. The
  lines' grid counts its scrolls, so where the output left off is found again after drawing the line scrolled it.
  While a program has a screen of its own, there's no input line; it's drawn again when it goes back to lines.
- **echo** hands its line to the terminal as it's edited, rather than writing each key's text; when a line's done it
  takes it away, writes it as typed, then answers it; Ctrl-C writes the line with `^C`.
- **Test**: half a line typed at the banner, the rest once hello's line has come: hello's line comes out whole, and the
  line's written as typed and answered.

## Alternatives considered
- **The service tracking what the reader wrote since its last line break**: no protocol change, but a guess that the
  reader's own cursor moves, clears and styles could make wrong.
- **Program output written where the cursor is**, as a terminal in cooked mode does: what came up.

## Consequences
- The future shell's line editor uses `InputLine` for its line and prompt, and 10b4's setup screen has none to keep:
  it's the terminal service's own.
- A program that edits a line by writing it, as echo did, still works, with output landing in it as before.
