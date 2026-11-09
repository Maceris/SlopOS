# 0185: What M12 Left, Planned

Status: accepted, chosen with the project's owner; built, 12e to 12h
Date: 2026-11-08
Related: `0011` (memory budgets), `0017` and `0056` (process control and intercepts), `0026` (the carrier register),
`0037` (scheduling and lending), `0041` (the per-thread page), `0134` (the panic record), `0160` (elevation), `0182`
(P4's elevation for the power capability), `0183` (M12), `0184` (an empty port wait), `../design/scheduling.md` §3,
`../design/lessons.md` §6, `../roadmap.md` M12

## Context
`0183`'s four stages are built, but its as-built records leave some of its plan for later. Two of those are in the
roadmap's own description of M12: values shown through Hemera's types, and fibers listed. Two were assigned to M12 by
`0101`'s catch-up: the per-thread page (`0041`) and what services spent on each process's behalf. Others are smaller:
attaching through the powerbox, breakpoints on every thread, a recording kept as a file, received handles in a replay,
the administrator's `trace`, and four found while building (reports read back, configured budgets, a lockup's
registers, AArch64's lockups).

None of these waits on a later milestone: the powerbox and elevation are built (10d, P4), and so is lending
(`0037`; the volume server binds a loan per connection). A survey of Hemera found:
- **Lines** are there: `--debug` writes `.debug_line` and a `DW_TAG_subprogram` per function. Programs just aren't
  built with it, and nothing on SlopOS reads it.
- **Values** aren't: Hemera's DWARF has no variables, parameters, locations or types, and nothing maps a variable to a
  `TypeInfo`. Type descriptors are only emitted for the types `type_info_of` reaches.
- **Fibers** have no complete list: a pool's queues hold the runnable ones, and a parked fiber is reachable only from
  its waiter. But each thread's carrier block is in its pinned register (r14, x28), so a debugger can find the
  running fiber and the pool from a stopped thread's registers.

## Decision
Chosen with the project's owner:
- **Values are described by full DWARF types too**: base, struct, union, enum, pointer, array and subroutine types,
  with variables and parameters and their locations, so gdb and lldb show Hemera values on hosted targets as well.
  Each type also carries a Hemera vendor attribute naming its type in the program's schema file. That's what SlopOS's
  debugger and crash reports use, so unions, optionals and views show as Hemera values (`0183`'s choice).
- **Breakpoints and watchpoints are process-wide**: a new call sets a process's slots, which the kernel loads for
  every thread of it, including ones started later, as it returns to user mode. Stepping stays per thread.
- **In a replay, calls on handles received from the recording are answered from it.** Mapped channels stay a
  documented limit: their traffic is shared memory, not calls.
- **All four smaller items are in**: supervisor reports read back and named, budgets from the configuration, a
  lockup's registers in the panic record, and pseudo-NMIs on AArch64.

Decided here:
- **Debug info lives in a debug file beside the program**, as its manifest and documentation do (`0174`). It holds the
  ELF's DWARF sections, split out at link time, and the schema of every type the DWARF names. The bundle store keeps
  it by the program's hash. Programs ship stripped; `symbols` is handed the debug file instead of the ELF.
- **Fibers are found from the carrier register.** `std`'s fiber pool keeps every live fiber on one intrusive list, not
  just the runnable ones. The debugger finds the pool from a stopped thread's r14 or x28, and walks the list with
  `process_read_memory`, laid out by the schemas of `CarrierBlock`, `PoolCarrier`, `FiberPool` and `Fiber` in the
  debug file. Nothing in the ABI depends on `std`'s layout.
- **The per-thread page holds the CPU budget binding and the running fiber**, as `../design/scheduling.md` §3
  proposed. The fiber scheduler writes both on its resume path. The kernel resolves the binding at its next accounting
  point, falling back to the thread's own budget if the handle is stale. Its trace and samples record the fiber, so a
  profile or trace of a server says which fiber's work it was.
- **Reading the system's reports, tracing the whole system, and attaching to another user's process take an
  administrator**, through elevation. Attaching to one's own session's processes takes the powerbox's question on the
  trusted path, each time.

In four stages, each with an as-built record here:
- **12e, debug information.**
  - **Hemera:** DWARF variables, parameters, locations and full types, each type with its schema's index. A link step
    splits the DWARF into the debug file, with the schemas.
  - **The build:** every SlopOS program built with `--debug`, its debug file written beside it, and the generation
    builder putting it in the bundle store.
  - **`symbols`:** reads `.debug_line`, `.debug_info` and the schemas: a function and line for an offset, the offsets
    of a file and line, a function's variables and their locations and types.
  - **The debugger:** `break` by file and line, `where` and crash reports with lines, and `print name`: a variable
    shown as a Hemera value, rendered through its schema with `std/schema`.
  - **Tests:** a crash report names its lines; the shell's debugger breaks at a line and prints a struct, an optional,
    a union and a view; Hemera's tests check the DWARF with LLVM's tools on hosted targets.
- **12f, the debugger's reach.**
  - **The kernel:** `process_set_debug`, a process's breakpoint and watchpoint slots. A thread's own slots are then
    only for stepping.
  - **`std`:** every live fiber on its pool's list, with its state.
  - **The debugger:** `fibers` lists them, each with its state and stack, named through `symbols`. Breakpoints are
    process-wide.
  - **Attaching:** `debug attach name`. The shell asks its session's powerbox, which asks on the trusted path; on yes,
    the session manager attaches an intercept to the program and gives the shell its handle. A process of another
    user's session takes an administrator.
  - **Tests:** a breakpoint hit by a second thread started after it was set; a fiber parked on a port listed with its
    stack; an attach allowed and one refused, on both architectures.
- **12g, recordings and the system's view.**
  - **Recordings as files:** `record name arguments to path` writes the recording as a typed file through the
    schema, `replay path` replays one, and a recording keeps the program's hash, so it refuses a different build.
  - **Received handles:** a handle value that came in a recorded message is marked, and every later call taking it is
    answered from the recording.
  - **`trace seconds`:** an administrator's tool, through elevation as `shut-down` is. The terminal service asks the
    supervisor, which holds the trace right, to trace for that long, then gives back the events, named by process and
    thread.
  - **Reports read back:** the events service's `Query` gives a record's typed bytes, and `crashes system` lists the
    supervisor's and session manager's reports, named through `symbols` like the shell's own. It takes an
    administrator.
  - **Budgets from the configuration:** a service's events budget from its system configuration, and a user's
    programs' from their account's settings.
  - **Tests:** a recording written, read back and replayed exactly; a program that receives a channel end replayed; a
    trace through elevation; a supervisor report named; a configured budget kept.
- **12h, attribution and lockups.**
  - **The per-thread page** (`0041`): mapped by `thread_create`, its layout in `slop_os`. It holds the budget binding
    and the running fiber, which `std`'s fiber scheduler writes and `std`'s connection framework sets to a
    connection's loan.
  - **Attribution:** the kernel counts each CPU budget's time, and how much of it was run by processes other than the
    one that made it, and memory charged to a budget by another process (`0011`). The shell's jobs each get a child
    CPU budget of the shell's. `processes` shows each process's own time and memory, and what services spent on its
    behalf.
  - **Lockups:** the NMI writes the stuck CPU's registers and a stack walked through frame pointers into the panic
    record. On AArch64 the kernel masks interrupts through GICv3's priority mask (`ICC_PMR_EL1`) rather than
    `DAIF.I`, so a highest-priority SGI acts as the NMI. Without GICv3's NMI support it reports which CPU, as now.
  - **Tests:** a client of the volume server shown with the server's time spent on its loan; a fiber's samples named
    by fiber; `test_lockup` on both architectures with the stuck CPU's registers and stack in the next boot's log.

## Alternatives considered
- **Schemas linked from DWARF, without DWARF types:** less compiler work, but hosted debuggers would show names
  without types.
- **The debugger applying breakpoints to each thread:** no kernel change, but a race with every running thread and
  every new one.
- **Making mapped channels replayable** by recording their rings at each notify: large, and it records shared memory
  the program can change at any time.
- **Debug info in the ELF:** one file, but every program larger in memory and on disk for what only a debugger reads.
- **Fibers found through the per-thread page:** it would tie the ABI to `std`'s layout, which `0041` keeps private.
- **Leaving the smaller items for later milestones:** none of them waits on one, and M12 is the milestone for them.

## Consequences
- Hemera's DWARF grows to full variables and types, with a vendor attribute, tested on hosted targets.
- Every SlopOS program has a debug file in the bundle store; generations grow by about the programs' own size.
- `slop_os` gains `process_set_debug` and the per-thread page's layout; the system call table and spec change.
- `std`'s fiber pool keeps a list of every fiber, one pointer pair per fiber.
- AArch64's interrupt masking moves to the priority mask, which every interrupt path depends on.
- M12 ends with 12h, and the roadmap's M12 has nothing left for later.

## As Built: 12e
- **Hemera's DWARF.** With `--debug`, each local and parameter is a DWARF variable at a stack slot of its own, which
  the optimizer may still move, its location then a list of ranges. Its type is described in full: base types, structs,
  `#union` structs, tagged unions as a struct of the tag and each variant's values overlapping, an optional that's a
  pointer as that pointer, enums as their backing integer by name (MLIR has no enumerators), pointers, arrays, and
  strings, views and dynamic arrays as their structs. A pointer to a struct or union points to its declaration alone,
  which a debugger finds by name, so no description refers back to itself. gdb on the Linux VM shows them. It's DWARF 4,
  LLVM's default, which is simpler to read than 5.
- **The debug file.** A SlopOS program with debug info is linked twice: with its DWARF, into `<name>.debug`, after
  `"HDBG"` and its size, then the debug table, and without, as the program. The table names each local's type as a
  schema, written by the compiler itself (`write_schema`, the bytes `runtime.schema_try_write` gives), since compile-time
  code can't be relied on to run there: the functions it would call may never have been checked. A vendor attribute in
  the DWARF was planned for the link, but MLIR can't add one, so the table is keyed by the function's linkage name, the
  local's name and its line, which the DWARF has too. Every SlopOS program is built with debug info now; the program
  stays the size it was (14 MB of programs became 15), as Hemera leaves the runtime's table of functions' names out
  when the debug file names them. That table names every function, so none could be dropped after inlining: it made
  the programs twice their size at first.
- **Size.** The debug files are 61 MB beside 15 MB of programs, 40 MB of it for the bundle store's programs. A copy of
  each program's code is in its debug file's ELF, which `objcopy --only-keep-debug` would drop, but that takes LLVM's
  objcopy library in the compiler; left. So the store builder puts them in only with `--debug-files`, which `boot.py`
  passes with its own `--debug-files`, on a disk 48 MB larger; the tests that debug ask for them.
- **The bundle** gains `debug`, the debug file's hash, after `documentation`, and the programs protocol `Debug(name)`,
  answered with `DebugFile`, the file, as `Describe` is with documentation.
- **`symbols`** reads a debug file as well as a program: the ELF after its header, its `.symtab` as before, and its DWARF
  (`dwarf.hsc`): `line <offset>` gives `file:line` from `.debug_line`, `where <file>:<line>` the line's lowest address,
  and `locals <offset>` the innermost function holding the offset, an inlined call's if it's in one, with each local's
  name, line and place: in memory at a register plus an offset (the frame base's, or another's), in a register, at an
  address, a constant, or in pieces of those, from its location list's entry for the offset. Line 0, code no line is
  for, like a trap the compiler shares between bounds checks, is said as unknown.
- **The debugger.** `break file:line`; `where` with each frame's line; and `print name`, which asks `symbols` for the
  locals at the stopped thread's program counter, gathers the value's bytes from its pieces, and shows it through its
  schema from the table, reading what its strings and views point to in the program: `Point{x = 3, y = -4, label =
  "corner"}`, `Some(7)`, `Box(2, 5)`, `[10, 20, 30]`. Only the stopped frame's locals; one the optimizer keeps nowhere
  is said to be so. Crash reports, in `crashes`, give each frame's line when the program has a debug file.
- **Tests.** Hemera's `SplitsSlopOSDebugInfo` checks the program has no DWARF and its debug file has it, and the table
  has `main`'s parameters with their schemas. A boot test debugs `test_debug`, whose locals are each read through
  volatile loads so they're all in memory at the line it breaks at: a breakpoint by file and line, its stack with
  lines, its struct, optional, union and view printed, a name that isn't a local, and a crash's report naming its line.
  On both architectures. `boot.py` gains `--expect-console-end`, for a line whose start changes.

## As Built: 12f
- **Process-wide slots.** `process_set_debug` (89) sets a process's breakpoints and watchpoints, under a lock of its own
  (`LockRank.ProcessDebug`) and a flag read first, so a process that isn't debugged costs nothing returning to user
  mode. Every thread of it loads them as it returns, those started later too, unless it's single-stepping
  (`thread_set_debug` with step), when it loads its own state, so a step past a breakpoint doesn't stop at it again. The
  debugger sets its slots on the process, and a thread's own state only to step.
- **Fibers.** `std`'s fiber pool keeps every fiber spawned that hasn't finished on one list, under a lock apart from
  the shared queue's, through two links base's `Fiber` gained. The debug table names the runtime's types by
  `package.name` after its functions (`runtime.CarrierBlock`, `runtime.Fiber`, `fiber.FiberPool`,
  `fiber.PoolCarrier`), and the debugger's `fibers` reads the stopped thread's carrier register (r14, x28), its carrier
  block's scheduler data, the pool and its list, each laid out by those schemas, nothing of `std`'s in the ABI. A
  suspended fiber's stack is walked from where `fiber_suspend` left it (the continuation and the top frame, at fixed
  offsets from `saved_sp`), and named through `symbols`.
- **Attaching.** `debug attach name`: the shell asks its session's powerbox (`RequestDebug`, with a copy of its port).
  The powerbox asks the session manager where the program runs (`Locate`), then the user on the trusted path, or for
  another user's session's program the administrator, through elevation (prompt kinds `Debug` and `DebugOther`; the
  elevation screen's new `Confirm` step takes Enter for the user's own). Once it's allowed, the powerbox asks the
  session manager to attach (`Attach`), on a programs connection the session manager gives it at launch, the only one
  `Locate` and `Attach` are taken on. The session manager closes its own fault intercept on the program, as a process
  has one, attaches one on the shell's port, and gives back the process (inspect and write state), the intercept, the
  address space and the image, which the powerbox passes on. The shell suspends the program's threads; `quit` clears
  its slots, resumes them and closes the intercept, letting it run on, unintercepted from then. The administrator's
  path is built but not boot-tested: it would take a second user's session at once.
- **Found on the way.** A thread a SlopOS program starts began with its stack pointer 16-byte aligned, where x86-64
  expects it 8 below, as after a call: its frames were 8 bytes off, and an aligned store faulted, as `test_debug`'s
  fiber pool's did. Base's `slop_os_start_thread` gives the top less 8 on x86-64 now. And a launch kept the program's
  address space with no rights, so it couldn't be moved on to a debugger; it has `RIGHT_TRANSFER` now. The debugger's
  `threads` said `thread %`: a format with two placeholders written together.
- **Tests.** A breakpoint set by function before `test_debug 2` starts its second thread is hit there; that thread
  carries a fiber pool, whose two fibers are listed, the waiting one suspended in `test_debug.wait_for_done`. The
  debugger attaches to `counter`, the system's installation, once the user allows it on the trusted path: its threads
  suspended, listed and walked, and let go; asked again, Escape refuses it. On both architectures.

## As Built: 12g
- **Recordings as files.** `record name arguments to path` keeps the recording as a typed file, `recording.RecordingFile`:
  the program's name, its arguments as typed, the BLAKE3 hash of its file, the seeds, and the events and their bytes.
  A protocol message is at most 4 KiB and a recording is far more, so the shell lays the file's value out itself, on the
  heap, as a message's is; and a typed file's lists hold only plain data, so each event is kept as a `StoredEvent`, its
  kind a number checked as it's read back. `replay from path` runs the program it names with its arguments, refusing
  another build of it.
- **Received handles.** Each call's shape now says which argument words are handles, which written buffers hold them,
  and whether it gives one back. A replay keeps the handles an answered call gave the program from the recording, and
  gives the program a placeholder for each, a port of its own, in the same place in its handle table, checking the
  number: without one, every handle made after would be numbered otherwise, and the replay would diverge. A call taking
  a received handle is answered from the recording too, but for the `handle_` calls, which run again on the
  placeholder. And `channel_send_handles` runs again rather than being answered, as it moves the handles out of the
  program's table, as it did when recorded; nothing it stages goes anywhere without the write, which is answered.
- **`trace seconds`.** The shell asks the powerbox (`RequestTrace`), the trusted path asks the administrator (prompt kind
  `Trace`), and once they're right the terminal service asks the supervisor for a trace connection (power's
  `TraceConnection`), the new `trace` protocol, which goes back to the shell. The supervisor traces for as long as it's
  asked, draining the kernel's rings into each thread's counts as its loop goes round, its loop's deadline the trace's
  end, and answers with each service's switches and wakes, the busiest first, threads of no service as "others".
- **`crashes system`.** Likewise for the system's log (prompt kind `SystemLog`, power's `EventsConnection`): the
  supervisor gives the events service another client's end (`Connect`), whose other end goes to the shell. The events
  service's `Found` now gives a record's first argument's schema hash and value, as written, so the shell reads the
  supervisor's and session manager's reports back as `CrashReport`s, asking for errors only, and names their frames
  through the programs' files, with lines from their debug files. The supervisor's reports went nowhere before: it
  starts before the events service, so its logger had no ring. Base's new `slop_os_adopt_events_ring` takes a ring
  given later, and the supervisor opens its own source, "supervisor", once it's started the events service.
- **Budgets from the configuration.** A service's `events_budget` in `system_config` (its record's, 0 for the default),
  which the supervisor sets as it opens the service's ring; and a user's `events_budget` in their `SessionSettings`,
  which the session manager reads as their session starts, for each of its programs. `hello` has 2 MiB, which a boot
  test sees set. There's no shell command to set a user's settings yet, so the user's isn't boot-tested.
- **Found on the way.** The trace connection's port key was the supervisor's `CRASH_KEY` already; an administrator's
  connections need 8 KiB rings, as a channel's message is at most half its ring, and a record with its argument or a
  trace's rows are bigger than 512 bytes. A shell build once stopped in the compiler's JIT, a relocation out of range
  in `RuntimeDyld`, and didn't again. And the shell twice trapped on AArch64 printing a local, in a full run, not caught
  again: `symbols` ran on 8 MiB plus twice its file, split off the shell's 16 MiB, and wasn't waited for, so two asks
  close together could leave the shell short. It's given 2 MiB plus twice its file now, and `ask_symbols` waits for it
  to end, so its budget's back before the next.
- **Tests.** `test_replay 5 1` passes itself a channel end, writes on and closes what it receives, and is recorded to a
  file and replayed from it exactly; a file that isn't there is refused. A trace through elevation lists services'
  switches. `crashes system`, once the administrator allows it, shows the update service's crash that `test_crash`
  caused, its frames named. On both architectures.

## As Built: 12h
- **The per-thread page** is a page of the thread's own memory, which it gives the kernel (`thread_set_page`, call
  92), rather than one `thread_create` maps: most threads never need one, so base makes it the first time a fiber runs
  on the thread or a budget is bound (`runtime.note_running_fiber`, `runtime.bind_cpu_budget`), a page of its own
  mapped as `map_pages` maps any, and given back when the thread ends. Its layout is `slop_os.ThreadPage`, checked
  against base's `SlopOsThreadPage`: the budget binding, a handle, and the running fiber. The kernel reads it through
  the direct map, only while its memory object lives, and never writes it.
- **The binding** is resolved in the scheduler's pass at each entry, once the thread is charged, when it changed since
  the last: the handle's CPU budget if it's one with `RIGHT_CPU_BUDGET_BIND`, else the process's own. For a server
  that's its next system call. `thread_use_cpu_budget` still works, holding until the page's binding changes. std's
  fiber scheduler notes each fiber as it resumes it, with the budget it's bound to (`Fiber.cpu_budget`), and nothing
  once it's back; the volume server binds each connection's loan through the page instead of a system call.
- **The fiber** goes into each sample (`Sample.fiber`) and each switch in the trace (`TraceKind.Switch`'s other).
  `profile` says samples by fiber after its functions: each fiber's count and the function of its most sampled place.
- **Attribution:** each process counts its threads' time; each CPU budget, the time threads of processes not on it ran
  on it, a loan's (`process_cpu_info`, call 90, and `cpu_budget_describe`'s new `lent`); and a memory budget's objects
  owned by processes not on it are added up on request (`memory_budget_others`, call 91). `processes` shows each
  process's `cpu`, `lent` and `charged`. Hello's budget is the scheduler's default, which the volume server is on too,
  so what it runs for hello isn't another's: the lending test checks echo's budget, which is its own.
- **Not built: a child CPU budget for each shell job.** Session programs have no CPU budget handle of their own (they
  run on the session manager's), so the shell has none to split; each job's own time is counted per process anyway.
  It waits for session programs to get CPU budgets, which the roadmap's Before M13 stage plans (C1).
- **Lockups:** the NMI keeps the stuck CPU's registers and the return addresses its frame pointers chain, walked only
  within its kernel stack, each further up; the reporting CPU logs them as fatal lines, which the panic record keeps.
  On AArch64 the kernel masks interrupts with GICv3's priority mask: `0x80` in the kernel, with PSTATE's I clear, which
  only SGI 4's priority (`0x20`) passes; `0xf0` in user mode and idle. The GIC gives `ICC_IAR1_EL1` only what the mask
  lets through, so each exception takes an IRQ's ID before setting it; and every `eret` to user mode or idle sets I
  first, then the mask back. The entry returns for the NMI, to kernel code too, the interrupted mask restored. `test_nmi`
  stays x86-64's: the boot code it runs in has I set.
- **Tests:** `test_profile 500 1` spins on a fiber, and its profile says those samples by fiber; the lending test sees
  the volume server's time on echo's budget, through the page's binding; and `test_lockup` with `panic_reset` keeps the
  stuck CPU's registers and stack in the record the next boot finds (and doesn't lock up again on that boot). On both
  architectures. `processes` shows the new columns in the installations test.

