# 0176: 11d, the Interactive Shell, as Built

Status: accepted
Date: 2026-11-05
Related: `0162` (M11's plan), `0169` to `0172` (the shell so far), `0174` (11d's plan), `0175` (testing),
`../design/shell.md` §6, `../design/software.md` §2

## Context
11d, after the documentation phase of `0174`: help from programs' documentation, completion, history, jobs with Ctrl-C
and `Progress`, then the shell as the session's first program. The bugs the documentation review found in the shell
(`../documentation-rewrite-findings.md`) were set aside for it too.

## Decision
- **The shell's bugs**, all fixed: each line is freed once run; a failed wait is an error, not a spin; a failed launch
  closes both lifecycle ends and the grants' copies; the pipeline's writer is kept as it is after its last put; a
  list's items start after aligning; grouping by a field named `count` or `items` names the value `key`; the smallest
  i64 is shown as itself; table widths, and the `^` under an error, are the columns text takes; arithmetic and number
  literals past 64 bits are an error ("that's too big"); `$file-name` fills in the whole name.
- **The language as a library**: its syntax, values and rendering, scopes, checked arithmetic, bare words, the
  stages' sorting and grouping, and values written and read by manifests moved to `src/shell_language`, a library
  the shell imports, since programs don't share code. Nothing in it makes a system call, so it's tested on the host
  (`unit_tests.py`), with Hemera's property tests: drawn lines parse or fail inside them, numbers parse to themselves
  or are too big, sums, differences and products are checked against references that can't overflow, and records
  read back as written.
- **Documentation**: the build writes each program's `main`'s documentation comment beside its manifest, as
  `<name>.docs`, a record of `bundle.Documentation`: its summary, details, each `@param`, `@return`, `@error` and the
  other tags, a paragraph's lines joined. A bundle refers to it third, after the program and the manifest (all zeros
  without one). The programs protocol gained `List(index)`, a boot root's program's name at a time, and
  `Describe(name)`, its documentation's record. `std`'s `schema.read_value[T]` reads one, checked.
- **The bundle store's Read**: an object Get gives stays open while the store runs, at most 64, and help and completion
  use several a program. `Read(hash)` gives a copy, its owning handle moving to the client, keeping nothing open, for
  objects up to 1 MiB; the session manager reads roots, bundles, manifests and documentation so, and keeps Get for
  executables, which processes map.
- **help**: alone, the built-ins and stages with a sentence each; with a name, a built-in's sentence, a shell
  function's parameters, or a program's summary, details, each parameter with its type from the manifest (or how the
  shell gives it, for a grant) and its documentation, then what it gives back, its errors and its notes.
- **Completion**: the line editor's Tab, through `std`'s `terminal.set_completer[D]`, which keeps the rawptr in `std`.
  In a command's place, the built-ins (the stages only after `|`), the shell's functions and the programs; `--name`,
  the command's parameters; `$name`, the names bound; after an enum's `--name`, its members; any other argument, the
  entries of the directory beneath the home its path would be in. Listed, each has what it is beside it: a built-in's
  sentence, a program's summary (asked for when 24 or fewer are listed), a parameter's type and documentation.
  `std`'s completions gained descriptions, and a lone candidate gets a space after it unless it ends with `/`.
- **History**: the session manager gives the shell `data`, `apps/.shell` in the user's home, a name no installation
  can have. The shell reads its `history` there when it starts and writes it after each line, so it's the user's,
  across their sessions, and not another user's.
- **Jobs**: everything the shell waits for is on its terminal client's port: programs' ends from `FIRST_KEY` on, their
  lifecycle channels under their key plus `LIFECYCLE_KEY`. `std`'s terminal client gives back a packet under another
  key as `Other`, and `read_line` returns it in the middle of a line, going on with that line next time; its
  `interrupted` says whether Ctrl-C has come, without waiting. In the foreground, the shell checks for it while it waits
  for programs, for their output to open, and every 50 ms while reading it (`stream.next_bytes_before`); Ctrl-C sends
  each program `Stop` on its lifecycle channel and kills those still running after 2 seconds (`STOP_GRACE`). A line
  ending with `&` runs its programs in the background as job n, none given the terminal; `jobs` lists them, `wait n`
  (or the newest) finishes one as in the foreground and gives its value, and `stop n` ends one. What a job's last
  program writes waits for `wait`. `exit` takes nothing.
- **Progress**: a program says how far along it is with `lifecycle.report_progress(done, total)`, a new lifecycle
  message, `SLOP_OS_LIFECYCLE_PROGRESS`, whose sequence is thousandths. The shell shows it in the input line while a
  job runs in the foreground, and `jobs` beside a running job.
- **The first program**: the shell, from the bundle store, is each session's first program; echo when there's no shell
  in the store, or with `use_echo` on the command line, which the tests of echo and the powerbox use. A user's session
  ends when its first program lets go of the terminal connection it was started with, so `exit` logs out, and the
  login screen comes back on the console it was shown on; the session with no user, of a boot with no accounts, has no
  login to go back to, and stays.
- **Tests**: boot tests of help and completion, history across sessions, and jobs; the earlier shell tests gained the
  fixes' cases. `test_shell_calls` can `--sleep`, saying its progress, and be `--stubborn`, and takes its terminal as
  optional.

## Consequences
- Type-ahead while a program runs in the foreground stays queued, but a Ctrl-C behind it is seen only once the shell
  reads it, and a Ctrl-C drops what was typed before it.
- A background job whose last program writes more than its stream holds waits for `wait`; jobs aren't drained as they
  go, and one with output is never said to have ended at the prompt.
- Every server, the session manager's programs connection among them, ignores a request that breaks its protocol's
  rules, so a client that sends one waits for an answer forever. Found here, from a request built in the wrong order;
  left for a later look across the services.
- The bundle store still keeps every Get's object open; executables of programs run once stay open until it restarts.
