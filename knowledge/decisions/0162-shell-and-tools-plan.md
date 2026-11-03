# 0162: The Plan for M11, the Shell and Tools

Status: accepted
Date: 2026-11-02
Related: `0018` (the shell language isn't Hemera), `0044` (entries as manifests), `0136` (Ctrl-C an `Interrupt`),
`0139` (the lifecycle channel), `0157` to `0161` (the powerbox, sessions), `../design/shell.md`,
`../design/lessons.md` §4, `../roadmap.md` M11

## Context
M11 is the first usable system: a shell whose language has typed values, calls programs through their manifests with
grants for arguments, connects them with typed streams, and renders results; and the tools a user needs. `shell.md`
left its syntax, its name, how a pipeline's input is marked, and functions as programs open, and `lessons.md` §4
proposed four things to decide when M11 is planned. Typed values also can't reach a program yet: an entry's parameters
are handles only.

## Decision
Chosen with the owner as M11 started:
- **The language** is `shell.md` §2's sketch: calls with positional and `--named` arguments matched to manifests,
  `let`, `|`, `cmd or { ... }`, `try`/`catch`, `cmd?`, paths beneath the shell's `Dir`s, sizes and durations as
  literals. It's called **shell**: the program is `shell`, scripts end in `.shell`.
- **A pipeline's input** goes to the `Stream[T]` parameter named `input`.
- **Shell functions** are local to a script or a session; a script, with its `param` line, is what becomes a program.
- **`Stream[T]`** is Hemera's `std`: batches of records in a ring of shared memory, a channel carrying notices and
  backpressure; `Stream[u8]` is a byte stream.
- **Entries take typed values**: any parameter of a type a schema describes. The launcher writes the values,
  schema-encoded, into one page granted as `arguments`, and base's runtime decodes each into its parameter by name
  before `main`; handle parameters stay grants of their names.
- **Tools are separate programs** with manifests, from the bundle store; pipeline stages (`where`, `sort`, `take`,
  `map`, `group`) and a few essentials (`cd`, `let`, `help`, `jobs`) are built into the shell.
- **The editor** is small but real: full screen on the `Terminal` it's given, a `File` to edit, moving, inserting,
  deleting, undo, search and save.
- **All of `lessons.md` §4**: automatic snapshots per volume and `recover` for what `remove` removed; `Progress` on the
  lifecycle channel, drawn on the job's line, and Ctrl-C sending `Stop`; errors rendered with the parameter they came
  from and hints from the manifest; completion inserting the stored bytes, and "did you mean" for a path that matches
  only after Unicode normalization.

In five stages, as the roadmap has them, each in parts with as-built records, committed as they pass:
- **11a**, Hemera's `std` and the compiler: entry value parameters; `Stream[T]`; the terminal client and a line
  editor; time zones (TZif, RFC 8536); a linear-time regular expression engine (RE2's design).
- **11b**, the language and calls through manifests: the parser and interpreter, values, manifests read from the
  bundle store, arguments checked and turned into grants and values, errors; the shell as the session's first program,
  in echo's place.
- **11c**, pipelines and rendering: `Stream[T]` between programs, the built-in stages, results rendered from their
  schemas.
- **11d**, interactive use: completion, help, history, jobs with `Stop` and `Progress`.
- **11e**, the tools and scripts as programs: listing, copying, moving, removing and recovering, search, a viewer and
  pager, the process tree, snapshots, grants, installing, the editor; scripts with `param` lines run with only their
  grants.

## Alternatives considered
- **Nushell's or fish's syntax**: familiar, but neither is built around manifests and grants.
- **The first `Stream` parameter, or an annotation, as the input**: a name is visible in the manifest and needs nothing
  new from reflection.
- **Batches as messages**: simpler, but every record copied through the kernel.
- **One arguments record per entry**: less compiler work, but every tool wraps its options in a struct.
- **File tools built into the shell**: faster to write, but then they aren't programs others can call with grants.

## Consequences
- Every program's entry can take what the shell gives it, so tools and services alike are callable from the shell.
- The manifest is the schema of the entry's type; help from documentation comments needs those in it, which 11d adds.
