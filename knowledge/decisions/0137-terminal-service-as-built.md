# 0137: 10a1, the Terminal Protocol and Service, as Built

Status: accepted
Date: 2026-11-01
Related: `0136` (M10's plan), `0075` and `0077` (the console service it replaces), `0043` (the trusted path),
`../design/console-and-sessions.md` §2, `../../docs/specs/programs.md`

## Context
`0136`'s 10a1: the terminal protocol in `std` (styled runs, cursor and region operations, key, paste, resize and
interrupt events, `Features`), the terminal service replacing the console service, the VT adapter on the serial line,
Unicode widths from tables shared with `std`'s client, and visible substitutes for control, bidirectional and
invisible characters. Chosen with the owner as 10a1 started: the Unicode tables are Hemera's, a general-purpose
`std/unicode` generated from the Unicode Character Database 17.0.0, and the terminal protocol is `std`'s, in
`std/os/slop_os/terminal` beside the file protocols.

## Decision
- **Hemera's `std/unicode`** (Freestanding): UTF-8 decoding and encoding, each code point's grapheme break,
  Extended_Pictographic, Indic conjunct break, default-ignorable and width in one table of 2349 runs (14 KiB), UAX #29's
  extended grapheme clusters (every rule, GB9c included), and a cluster's columns: the widest code point's, 2 for an
  emoji asked for with U+FE0F and for a flag, 1 with U+FE0E. `_generator/generate.py` writes the table from the UCD;
  every case of `GraphemeBreakTest.txt` passes (Hemera's hosted test `SplitsGraphemeClusters`).
- **The terminal protocol** (`std/os/slop_os/terminal`): `Write` (text, runs, link targets), `MoveCursor`,
  `ShowCursor`, `Clear`, `Scroll`, `Screen`, `Bell`, `Describe` (answered with `Features`), `Read` (held, answered with
  `Input`'s events and their text) and `Connect`. Output isn't answered. `design/console-and-sessions.md`'s `SetRegion`
  became `Screen(bool)`: a screen of the program's own, or back to its lines, as a VT's alternate screen is. Its plain
  types are outside the `#if OS == .SlopOS`, so the VT adapter's tests run hosted; a `Relative`'s elements can't hold
  enums or bools, so a `Color`'s kind and an `Event`'s are bytes, made and read by `palette`, `rgb`, `color_kind`,
  `event_of` and `kind_of`, as `input`'s events are.
- **`safe_text`**: a cluster at a time, C0 controls become their Control Pictures, C1 controls, bidirectional controls
  and default ignorables are written out (`⟨U+202E⟩`), bytes that aren't UTF-8 become U+FFFD; a variation selector
  after what it varies and a ZWJ inside an emoji sequence are kept. Line breaks (LF, CR LF, CR) break the line, and a
  tab is spaces to the next stop of 8, rather than a substitute, since programs print tables with them.
- **The VT adapter** (`src/vt`): SGR for styles (the 16 colours, 256 and 24-bit), CUP, CHA, EL, ED, DECSTBM with SU and
  SD, DECTCEM, the alternate screen and OSC 8 links (targets kept to printable ASCII); and a decoder: keys with their
  HID usages, xterm's modifier parameter, SS3 and `~` keys, Alt as ESC first, Ctrl and a letter, bracketed paste as one
  `Paste`, Ctrl-C as `Interrupt`, and a code point or a sequence cut between two reads finished by the next.
- **The terminal service** (`src/services/terminal_service`, the service `terminal`): the console's one terminal, 80 by
  24. On lines, text streams to the serial line as it comes, so the host's own terminal keeps its scrollback; `Clear`
  on lines clears the line being written, which is how a program redraws a line it edits. Output waits in a 16 KiB
  queue, with at most two `Write`s in flight on the serial line, whose 1 KiB ring holds that many. The first client to
  `Read` owns the input until it goes. The first keyboard is still typed through a US layout here, until 10a2's input
  service.
- **echo** (`src/apps/echo`): the console's reader until 10c's sessions, doing what the console service did itself:
  showing what's typed, Backspace by grapheme cluster, Ctrl-C dropping the line, and `echo: ` and the line.
- **Not yet, for 10a2**: a screen model kept by the service (for the status line, the framebuffer and redrawing after
  the secure attention key's screens), scrollback, and resizing.

## Alternatives considered
- **Python's `unicodedata`** for the tables: Unicode 15.1, without grapheme break properties.
- **The protocol in SlopOS's `src/protocols`**, moved to `std` in M11: one more move, when `std`'s line editor needs it.
- **A screen model from the start**, redrawn by damage: it would rewrite lines on the serial line where streaming
  appends them, and nothing needs it until the status line.

## Consequences
- The console service and `console_log` are gone; `hello` writes through the terminal protocol, and the supervisor
  starts `terminal` and `echo` (in the recovery generation too).
- The boot tests' log lines are `terminal:` and `echo:` where they were `console:`.
- Found on the way: Hemera's shim for calls through `.c` function values used System V's convention for UEFI on x86-64,
  which is Microsoft's; fixed in Hemera, so SlopOS's bootloader boots on x86-64 again.
