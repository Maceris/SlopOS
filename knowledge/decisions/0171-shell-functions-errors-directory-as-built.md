# 0171: 11b3, Shell Functions, Errors and the Shell's Directory, as Built

Status: accepted
Date: 2026-11-02
Related: `0162` (M11's plan), `0169` (the language's core), `0170` (calls), `../design/shell.md` §2, §5

## Context
11b's last part: the rest of the language `0162` chose (`fn`, `try`/`catch`, `cmd?`) and the `cd` built-in, since
paths are resolved beneath the shell's directories.

## Decision
- **Functions**: `fn name(a: type = default, b) { body }`, local to the session. A function of the same name replaces
  one before it; the built-ins' names (`print`, `exit`, `cd`) can't be used. A call matches arguments to parameters
  as a program's are matched (`0170`): by position and `--name`, with a bool's `--name` alone true. A bare word is
  read by the parameter's type (`int`, `size`, `duration`, `bool`, `string`, `path`, `list`, `record`, or none for
  anything), and a value of another type is an error naming the parameter. A missing parameter takes its default, a
  bool's is false, and any other is an error. The body runs in a scope of its own, in the caller's. Its value is its
  last statement's, or `return`'s. Calls nest at most 64 deep.
- **Errors** (`shell.md` §5): an error in a function's body ends what's running, shown as `in name: ...`, and nothing
  handles it, unless its statement has `?`, which makes it the function's own error for its caller to handle. `or {
  ... }` and `try { ... } catch e { ... }` handle the errors that aren't fatal; `catch` binds the error as a record of
  `message` and `at`. At the top, `?` changes nothing.
- **The shell's directory**: `cd path` sets it, and `cd` alone sets the home. It has to be a directory there. A path
  resolves as follows: `~` is the home, `~/` starts from it, and anything else starts from the shell's directory. `.`
  is where it is, and `..` is the directory above, never above the home; a leading `/` is refused. Calls' paths
  resolve the same way (`0170`). The prompt shows the directory: `~/apps> `. A directory's failures read as a person's
  words: "there's nothing there", "that isn't a directory".
- **Tests**: a boot test defines and calls a typed function by position and by name, with a word that isn't its
  type; catches an error as a record; checks that `?` lets a caller's `or` handle a function's error and that its
  absence doesn't; checks that `return` ends a function; and checks `cd` into the home's `apps`, beyond the home, and
  to nothing.

## Consequences
- A function is defined on one line until the line editor continues lines (11d) or scripts run (11e).
- 11b is done: the language, calls through manifests, errors, and the shell in echo's place with `use_shell`. Making
  it the session's first program by default waits for 11d, as planned.
