# 0169: 11b1, the Shell Language's Core, as Built

Status: accepted
Date: 2026-11-02
Related: `0162` (M11's plan), `0166` (the line editor), `../design/shell.md` §2

## Context
11b's first part: the shell program, its language's syntax, values and evaluation, before calls reach programs (11b2).
Three of the syntax's details were chosen with the owner as it started.

## Decision
- **Chosen**: a command's argument names a variable with `$name`, so a bare word is always a word, never silently a
  variable; in expressions names are bare. Unquoted words in arguments are read by their parameter's type (a string, a
  path, a number, an enum's member). Scripts' functions are `fn name(a: T) { ... }`, statements are separated by line
  breaks or `;`, comments run from `#` to the line's end, and `"...$name..."` fills in variables in double quotes.
- **The program** (`src/apps/shell`): reads lines with `std/terminal`'s line editor, prompt `> `, parses each into a
  tree, evaluates its statements in turn, shows each one's value when it has one, and on an error shows it with the
  line and a mark under where it was, and runs nothing more of the line.
- **The syntax** as built: `let name = pipeline`; a pipeline's `|` (11c), `?` and `or { ... }`; a call is a bare word
  in command position with its arguments kept as written (`--name`, `$name`, `"text"`, `(expression)`, `[list]` or a
  bare word); anything else is an expression: `or`, `and`, `not`, comparisons, `+ - * /`, unary `-`, `.field` and
  `[index]`, literals (integers, sizes in B, KiB to TiB and kB to TB, durations in ns to d, strings with escapes,
  `true`, `false`, `null`), `$name` or a bare name, `( )`, `[a, b]` and `{name: value}`.
- **Values**: null, bool, integers, sizes, durations, text, paths, lists and records; arithmetic within a kind, a size
  or a duration scaled by an integer, strings joined by `+`; comparisons within a kind. Rendering is the shell's: a
  size in the largest unit with a decimal, a duration in its largest whole unit, a list an item a line, a record a field
  a line, text quoted only inside them.
- **Built in**: `print` and `exit`; a variable alone in command position is its value.
- **Until it's the first program** (11d), the session manager starts it in echo's place only with `use_shell` on the
  boot's command line, from the bundle store, its manifest checked.
- **Tests**: a boot test logs in with `use_shell` and has the shell evaluate `let`, a size sum, a string filled in, a
  list's item, a record's field, a duration comparison, and two errors.

## Consequences
- Each line's tree and values are kept for the session (no arena per line yet); a long session grows.
- Calls to programs, through their manifests, are 11b2.
