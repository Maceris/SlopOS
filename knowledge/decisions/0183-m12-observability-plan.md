# 0183: M12, Observability and Debugging, Planned

Status: accepted, chosen with the project's owner; 12a, 12b and 12c built
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

## As Built: 12a
- **Fault kinds.** A fault stop's `number` is a `FAULT_` kind (`std/os/slop_os`): read, write and execute for a page
  fault, and invalid instruction, breakpoint, single step, arithmetic, alignment, protection and floating point for
  the rest, with `fault_name` to name one. Before, every fault that wasn't a page fault said `0xff`.
- **A launch's fault intercept.** `os.LaunchOptions.faults` attaches an intercept of the program's faults between
  making its process and loading it, so even its first instruction's fault is caught. `os.Launched` gives the
  intercept, a rightless handle to the program's address space (`process_read_memory` needs none), and where its
  image is: the process manager's `Loaded` now carries a `Started`, the first thread and the image's address.
- **`STOP_FAULT_LIMITED`.** Found while wiring the supervisor: a holder stops being an exception port and becomes a
  hazard if it's waiting on the crashed process when it faults, as the supervisor's thirty-odd synchronous asks
  can. With this point bit, which launches use, a fault stop not let go within a second ends its process as F6 would,
  through a timer on the thread (`fire_fault_stop`). A debugger (12b) leaves it out.
- **Reports.** `src/crash_reports` makes a report of a fault stop: the fault, the thread's registers, up to 32 frames
  walked through frame pointers (Hemera keeps them in every function) with `process_read_memory`, and the image's
  address; logs it as a typed record, `crash: %` with the `CrashReport`; and lets the thread go, killed, before the
  holder kills the process. Memory isn't dumped: nothing asks for it yet.
- **Holders.** The shell for its programs, polling its jobs' intercepts while it waits on their output too; the
  supervisor for the system's services, which are then started again as any that ended; the session manager for a
  session's programs. Each logs `<name> crashed: <fault>`.
- **Symbols.** `symbols`, a program that holds the crashed program's file and nothing else, names offsets by the
  file's `.symtab`: a function and the offset into it. The shell keeps each crash's program file, and its `crashes`
  built-in shows the reports, oldest first, each frame named through `symbols`. Lines from DWARF wait for 12b, where
  the debugger needs them anyway; so do schemas in the bundle store. The supervisor's and session manager's reports
  are logged with offsets in the image, unnamed; a tool to read them back needs a typed query of the events service,
  which 12a doesn't add.
- **Lockups.** `lockups.hsc`: each CPU's tick notes its heartbeat and checks every other ticking CPU's is within 5
  seconds. A stuck CPU on x86-64 is sent an NMI (`arch_interface.send_nmi`), which notes the program counter it
  interrupted, logged as an offset in the kernel; then the kernel stops with `Lockup` (8), which the panic record
  keeps. The registers and stack aren't written to the panic record: that one address is logged. AArch64 has no
  NMI without pseudo-NMIs, so it reports which CPU, and stops. A CPU waking from tickless idle renews its heartbeat
  before it counts as ticking, or another sees it stale.
- **Retention.** A source keeps its budget of records: 4 MiB by default (the system's services), 1 MiB for a
  session's programs, which the session manager sets with the events protocol's new `Budget`. A source's file is
  moved to `.old` before a write once it holds half its budget, so each new file starts whole. Found on the way: the
  file server's `Rename` doesn't replace, so every source's file grew after its first move; `.old` is deleted first
  now. The configuration doesn't raise budgets yet.
- **Tests.** The shell's `test_shell_calls 2 crash` traps, is reported, `crashes` names `main` and `hemera_entry`,
  and the shell goes on; `test_crash` crashes the update service, which the supervisor reports and starts again;
  `test_installations` crashes the counter last; `test_control` checks a launch's intercept, a report's frames and
  `STOP_FAULT_LIMITED`; `test_lockup` spins CPU 1 with interrupts off; `test_events` drops a source's oldest records
  past the smallest budget. On both architectures.

## As Built: 12b
- **The kernel.** `thread_set_debug` sets a parked thread's debugging state, a `ThreadDebug`: whether it single-steps,
  and up to four hardware breakpoints (`Execute`) and watchpoints (`Write`, `ReadWrite`, of 1, 2, 4 or 8 bytes).
  x86-64 uses DR0 to DR3, DR7 and RFLAGS.TF, decoding a debug exception by DR6; AArch64 the breakpoint and watchpoint
  registers for EL0 alone, after unlocking the OS lock, and software step (MDSCR_EL1.SS, SPSR.SS). The state is loaded
  as the thread returns to user mode and turned off at every entry, since x86-64's breakpoints would otherwise fire on
  the kernel's own accesses to user memory, and the debug exception's entry can't return to the kernel. A hit is a
  fault stop: `FAULT_BREAKPOINT`, `FAULT_SINGLE_STEP`, or a new `FAULT_WATCHPOINT` with the address. Hardware
  breakpoints, not written ones: a program's code is shared, read-only, from the bundle store.
- **Also the kernel.** `intercept_set` changes where an intercept stops. A thread suspended while it waits has its
  registers read, as it began the wait; they aren't written, as the wait's end writes its results there. Pages nothing
  has touched were already brought in for a debugger's reads (`present_user_page`); code the bundle store hasn't
  supplied yet still can't be read.
- **Hemera.** `read_dr` and `write_dr` intrinsics, lowered as the control registers are; `LaunchFaults.debugging`, an
  intercept from the start that stops at every call's entry and at faults without a limit.
- **The program.** `debug name arguments`, a shell built-in, runs a program stopped at its first system call, before
  its main, and reads commands at a `(debug)` prompt: `break` by function, its offset found by name through `symbols`;
  `watch` by address; `delete`, `step`, `continue`, `where`, `registers`, `threads`, `print`, `quit`. A stop at a
  breakpoint or watchpoint is stepped past with the slots off, which also covers x86-64's breakpoints being faults and
  AArch64's watchpoints stopping before the access.
- **Not yet.** Lines from DWARF and values through Hemera's schemas: programs aren't built with debug info, and the
  bundle store doesn't keep it; `print` shows 8 bytes as a number. Fibers aren't listed, only threads. Breakpoints are
  given to the stopped thread, not to every thread. Attaching to a process the shell didn't start, through the
  powerbox, isn't built: `debug` debugs what it starts. Each stays for a later stage.
- **Found on the way.** An entry value that's an empty string or list, pointing somewhere, read as missing, ending the
  program with 126: its writer gave a distance past what it wrote. Hemera's schema reader takes an empty one as null now.
- **Tests.** `test_control` drives a thread through a hardware breakpoint, a step and a watchpoint on both
  architectures; a boot test debugs `test_shell_calls`: a breakpoint on its main, a step, its stack, and its end.

## As Built: 12c
- **One thread at a time, by the recorder.** The recorder (`src/recording`) holds an intercept of every call at its
  entry and exit (`STOP_ALL_CALLS`, new: calls 64 and up couldn't stop before) and of every new thread before its first
  instruction (`STOP_THREAD_START`, new). It lets one thread run its own code at a time, from a start or a call's end to
  its next call, and records each decision: a thread started, entered a call (its number, its argument words, the bytes
  of the buffers it reads), left it (its result and the bytes it wrote), was let run, read the counter. The replayer
  walks the same events in the same order, so the threads interleave as recorded: a program of several carriers is
  replayed exactly, as chosen, without a token in `std`.
- **The deterministic mode in Hemera** is what makes that safe: base's `runtime.deterministic_turn`, which
  `wait_on_value`, `std`'s spin lock and its fiber pools' idle spins call, makes a system call in the mode, so a thread
  waiting for another without one still comes to a call, where the recorder can let the other run. A launch turns it on
  with a grant `deterministic`. A program's own spin on memory, without a call, would still hold the others back.
- **What's answered, what runs again.** A replay answers from the recording every call on a channel or a port, the
  clock's and the kernel log's; the rest, which change only the program's own objects, run again, their results checked.
  Each call's shape (which words are buffers, read or written) comes from `std`'s table's type descriptions at run
  time. The program is built with the recording's seeds (the process manager's `Load` takes them now, and `Started`
  says them), so its layout, its handles and its `context.random` are the same, and argument words compare exactly.
- **The counter.** `process_set_traps` with `TRAP_COUNTER` traps a process's counter reads (x86-64's CR4.TSD, AArch64's
  CNTKCTL_EL1); the kernel runs the read and stops the thread at `FAULT_COUNTER` with the value, which the recorder
  keeps and the replayer puts in the instruction's register.
- **The divergence report** is the first event that doesn't happen as recorded: a call's number, argument words or read
  bytes, an executed call's result, or a thread that did something else, said as what it did instead ("thread 2 was to
  read the counter, but made call clock_monotonic"), or nothing within five seconds.
- **The shell.** `record name arguments` and `replay name arguments`; the recording is kept in the shell's memory, the
  last one, not written to a file as a typed recording yet. A recording isn't given the clock page, which is shared
  memory, not a call; nor a log ring.
- **Not yet.** Handles received on a channel can't be replayed, as the replay doesn't have them; channels aren't given
  without `map`, so a program mapping one isn't replayable; the recording isn't kept past the shell.
- **Found on the way.** `port_wait` with an empty packet buffer seemed not to keep its deadline; the test pauses on a
  port of its own now, and the kernel's behaviour is left to look into.
- **Tests.** `test_control` traps a counter read and changes its value; a boot test records `test_replay`'s threads,
  replays them exactly, and replays them with another count, which diverges, and says where. On both architectures.
