# 0183: M12, Observability and Debugging, Planned

Status: accepted, chosen with the project's owner; not started
Date: 2026-11-08
Related: `0009` (replay through system calls), `0017` and `0056` (process control and intercepts), `0024` (replay is
opt-in), `0041` (the per-thread page), `0053` (kernel-copied channel access), `0093` (the events service), `0134` (the
panic record), `0181` (a fault ends its process), `0182` (P), `../design/observability.md`,
`../design/lessons.md` §6 and §9.4, `../roadmap.md` M12

## Context
P is done, and M12 is next (`0072`). `../design/observability.md` proposed its four stages in 2026-10. Since then:
- **Intercepts:** they're built (`0056`). They stop a subtree's threads at system calls and at faults the kernel
  can't resolve, so an intercept is the subtree's exception port. `process_read_memory` reads another process's
  memory.
- **Faults:** a fault no intercept takes now ends its whole process (`0181`'s F6), and the supervisor starts it
  again, with nothing kept of why.
- **Debug info:** Hemera emits DWARF with `--debug`, and `hemera --symbolize` names an image's offsets.
- **The events service** keeps each source's records until memory or its file fills, then counts what it drops.

The design note left two questions open: whether Hemera's own schemas go beside DWARF, and what replay promises for a
process of several carriers. It also left proposals from `lessons.md` to decide when M12 is planned.

## Decision
Chosen with the project's owner:
- **DWARF and Hemera's schemas.** DWARF gives functions, lines and frames. Hemera's `TypeInfo` schemas, which `std`'s
  `schema` already writes, are kept beside it in the bundle store by the program's hash, so the debugger and crash
  reports show unions, optionals and views as Hemera values, not DWARF's approximations of them.
- **Replay is exact with several carriers too**, through a deterministic mode in Hemera's `std`. Under it, one
  carrier runs at a time and they switch only at system calls, so a recording replays exactly, slower. Without it,
  replay is exact for one carrier and best effort for several.
- **The events service keeps a budget per source:**
  - each source's records, up to a size its owner pays for: 4 MiB for the system's services, 1 MiB for a session's
    programs;
  - the oldest dropped first, and no expiry by time;
  - the system configuration raises a service's budget, and a user their programs'.
- **Attaching the debugger to a process the shell didn't start:** the session's powerbox asks on the trusted path,
  each time. The shell's own jobs need no asking, as it holds their process control already.
- **Tracing the whole system takes an administrator**, through elevation, as `shut-down` does (`0182`'s P4): the
  trace ring shows every process's scheduling and IPC, other users' sessions' too. Profiling one's own jobs needs
  nothing more.

And decided here, of what `lessons.md` proposed:
- **DWARF is parsed by a decoder process holding nothing else** (`lessons.md` §9.4), as everything that parses data
  from outside the system is.
- **Lockup detection** comes in 12a; P's watchdog already resets a hung system (`0182`'s P5).
- **The process tree shows what services spent on each process's behalf** (§6.1), in 12d.
- **The boot timeline**, from the trace ring, comes in 12d.

Four parts, each with an as-built record:
- **12a, crash reports, symbols and lockups.**
  - **Exception ports:** the supervisor, the session manager and the shell each hold an intercept, of faults alone,
    on what they start.
  - **The report:** at a fault, the holder writes a crash report to the events service as a typed record:
    - the fault and the faulting thread's registers;
    - a stack walked through frame pointers with `process_read_memory`, bounded;
    - each loaded image's hash and load address, from the process manager.

    Then it ends the process, which is started again as now. Memory is dumped only if the holder's configuration
    asks.
  - **Symbols:** the build keeps each program's DWARF and schemas in the bundle store beside it. A `crashes` tool
    lists reports and shows one symbolized, through the decoder process.
  - **Lockups:** each CPU's tick checks every other CPU passed a quiescent point within a few seconds. A stuck one is
    sent an NMI, which writes its registers and stack into the panic record and stops the kernel.
  - **Retention:** the events service's budget per source.
  - **Tests:** a test program that faults is reported, symbolized and started again; a CPU made to spin with
    interrupts off is caught; a source past its budget drops its oldest records.
- **12b, the debugger.**
  - **The kernel:** single-stepping (the trap flag; AArch64's `MDSCR_EL1.SS`) and hardware watchpoints (the debug
    registers; AArch64's watchpoint registers), per thread, through `write_state`. Also reading pages nothing has
    touched yet (`0056`'s catch-up).
  - **The program:** a `debug` tool in the shell, for one of its jobs, or another of the session's processes through
    the powerbox. It has breakpoints by function or line from DWARF, stepping, watchpoints, threads and fibers
    listed, and values shown through the schemas.
  - **Tests:** a test program driven through a breakpoint, a step, a watchpoint and its values, on both
    architectures.
- **12c, record and replay.**
  - **The recorder:** it starts a program with every system call intercepted at its exit and its channels without
    `map`, and writes a typed recording of each call and what it read.
  - **The replayer:** it starts the same bundle and answers each call from the recording, skipping it. A call that
    doesn't match stops it, which is the divergence report.
  - **The kernel:** it traps `RDTSC` for a recorded process.
  - **Hemera's `std`:** the deterministic mode, which the recorder turns on for what it records.
  - **Tests:** a program of several carriers, recorded and replayed exactly, its divergence reported when its input's
    changed.
- **12d, tracing and profiling.**
  - **The kernel:** a trace ring per CPU of scheduler events and IPC wakes, behind a tracing capability; a sampling
    capability over a subtree, the running thread's program counter and frame-pointer chain at each tick, delivered
    to a port; and the per-thread page shared with the kernel (`0041`'s catch-up).
  - **Tools:** `trace` and `profile`, symbolized as crash reports are. The boot timeline from the trace ring. The
    process tree showing what was lent to each process.
  - **Tests:** a trace of a known exchange, and a profile of a program that spins in a known function.

## Alternatives
- **DWARF alone:** one source, but a union shown as a struct and a tag, a view as a pointer and a count.
- **Exact replay for one carrier only:** no Hemera work, and the limit documented, as the design note had it.
- **Records kept for seven days, then by size:** an expiry the user didn't ask for, on a machine that's often off.
- **Symbolizing in the crashed program's holder:** simpler, but it'd parse DWARF, which came from outside the
  system, holding the supervisor's authority.

## Consequences
- `../open-questions.md`' observability questions are answered.
- Hemera gains the deterministic mode in 12c. It's `std`'s, so it's tested in Hemera too.
- The build package keeps each program's DWARF and schemas, and the generation builder puts them in the bundle store.
