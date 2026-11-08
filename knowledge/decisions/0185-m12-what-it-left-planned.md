# 0185: What M12 Left, Planned

Status: accepted, chosen with the project's owner
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
