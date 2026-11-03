# 0166: 11a3, the Terminal Client and Line Editor, as Built

Status: accepted
Date: 2026-11-02
Related: `0164` (`std/terminal`), `0147` (the input line), `0139` (the lifecycle channel), `0137` (the terminal protocol)

## Context
`0164`: a terminal client and a line editor in Hemera's `std/terminal`, shared by the shell, the editor and any tool.

## Decision
- **The client**: `terminal.open` on a terminal connection; `write`, `write_line` and `show_input` (the input line);
  `next_event`, one event at a time, its text the client's until the next call, a `Read` held for more whenever
  what came is used up. It asks to be woken when the program's asked to stop, and says `Stop` instead of an event
  then; `HangUp` once the terminal's gone.
- **The line editor**: `read_line` with a prompt, the prompt and the line shown as the terminal's input line. Left
  and Right move a grapheme cluster, Home and End (or Ctrl-A, Ctrl-E) to the ends; Backspace and Delete take a cluster
  out, Ctrl-U and Ctrl-K what's before and after the cursor, Ctrl-W the word before it; Up and Down go through history
  (the line typed before kept to come back to); Tab asks a completer, putting in the one candidate or what several
  share, or writing them above the line; a paste is inserted with its line breaks as spaces, so it never runs a line;
  Enter writes the prompt and the line, keeps the line in history (200 lines, no repeats), and gives it; Ctrl-C writes
  it with `^C` and drops it.
- **echo** reads lines with it, in place of its own editing.
- **Tests**: a boot test types "abd", Left, "c" and Enter, then Up, Home, "z" and Enter, and sees `abcd` and `zabcd`
  answered.

## Consequences
- The shell gets its line editing, history and completion hook from `std`; its completer fills in candidates from
  manifests (11d).
