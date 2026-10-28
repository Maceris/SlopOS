# Observability: Events, Crash Reports, Debugging, Replay

Status: **proposed** 2026-10-24, for roadmap M9 (the events service) and M12; log records decided 2026-10-27 (`../decisions/0092`). Builds on `../decisions/0009`
(logging as a startup grant, replay through system calls), `0017` and `0056` (process control and intercepts),
`0024` (replay is opt-in), `0053` (kernel-copied channel access for recorded processes) and
`../problems-and-directions.md` §14. The choices still to make are at the end and in `../open-questions.md`,
*Observability*.

## 1. What Goes Wrong Elsewhere

| Problem | Where | SlopOS answer |
|---|---|---|
| Logs are text, grepped and parsed; a logged value containing a newline forges a log line | syslog, most applications | A record is a format string and typed arguments; rendering happens when it's read (§2) |
| Formatting costs time even for records nobody reads | Most logging libraries | Arguments are copied in their layout, not formatted (§2) |
| Every program can write to the shared log and claim to be anyone | syslog | Records are labeled by the events service from the connection they arrived on (`0014`) |
| Crash dumps contain all of a process's memory, and go wherever the system sends them | core files, Windows Error Reporting | A crash report is registers, a stack trace and image hashes, for the process's owner; memory only on request (§3) |
| One tracer per process, signals in the way, attach races; restricted after the fact (Yama) | `ptrace` | Process-control rights over a subtree, already built (`0017`, `0056`) |
| Unwinding needs frame pointers that were compiled out | SysV/Linux until 2023–24 | Hemera keeps a base pointer in every function (`system-abi.md` §3) |
| Record and replay exists only where performance counters allow it, and serializes threads | rr on Linux | Every nondeterministic input is a system call result already (`0009`); exact replay for a process on one carrier (§5) |
| Tracing and profiling need a VM in the kernel, and are privileged by a global switch | eBPF, DTrace, `perf_event_paranoid` | Capabilities over a subtree, with fixed kernel mechanisms (§6) |

## 2. The Events Service (M9)

- **A record** is: the monotonic time, the level, an identifier for the format string, and the arguments in their
  protocol layout with their schema hashes. The format string itself is stored once per program, by its hash, from
  the program's bundle.
- **Writing:** `std`'s logger for SlopOS (the program's `context.logger`) appends records to a ring shared with the
  events service, so logging is no system call per record. The service drains it. A full ring drops the newest
  records and counts the drops, which are recorded too.
- **Labels:** the service labels each record with its connection's label (`0014`), so a program can't claim another
  source.
- **Storage:** records are kept per source, with a budget per source paid by its owner; a session's programs' records
  go to that user's volume, so they're encrypted with the rest of the user's data. The system's go to the system
  volume.
- **Reading:** a query by source, time, level and typed fields of the arguments, through their schemas; `Watch` for
  live tailing. Records render as text through Hemera's format rules (`%` and the type's information), so they read
  like `runtime.log_info`'s output.
- **The debug log** (`0058`) stays for the root task and for boot, before the events service runs.

On the Hemera side, the logger interface already hands over the format string and the arguments; what's missing (a
type's schema hash, writing a value from its `TypeInfo`, naming the format string) is in
`../hemera-proposals/typed-log-records.md`.

## 3. Crash Reports (12a)

- A fault the process doesn't handle stops its thread at its subtree's exception port (`0056`), which the supervisor
  or the shell holds for what it started.
- The holder writes a **crash report** to the events service: the fault (`Fault`), the registers, a stack trace
  walked through frame pointers from the stopped thread's registers with `read_memory`, the stacks of the process's
  other threads and fibers if asked, and the hash and load address of each image.
- **Symbols** come from the DWARF the compiler emits (Hemera's `--debug`, `docs/compilation.md`), kept in the bundle
  store beside the program by hash, so reports from a running system are symbolized when read, without symbols in
  the running image.
- Memory is dumped only when the holder asks for it, into the owner's storage.

## 4. The Debugger (12b)

- A program holding a process handle with `inspect`, `read_memory`, `write_state` and `intercept` (`0017`), from the
  shell for its own jobs, or from the powerbox for another process of the session.
- **Breakpoints** are `int3` or `brk` written with `write_state`, caught as faults at the exception port.
  **Single-stepping** and **hardware watchpoints** need the kernel (the trap flag and debug registers on x86-64,
  `MDSCR_EL1` and the watchpoint registers on AArch64), set per thread through `write_state`.
- **Values** are shown through DWARF's types where it has them and Hemera's `TypeInfo` schemas where the program
  was built with them, so unions, optionals and views show as Hemera values.
- **Fibers** are listed as well as threads, found through the carrier blocks, since a fiber that's suspended has its
  return address on its own segment (Hemera `docs/multitasking.md`).

## 5. Record and Replay (12c)

- **Recording:** the recorder starts the program with every system call intercepted at its exit (`0056`) and its
  channels without the `map` right, so every read goes through the kernel (`0053`, `0024`). It writes the startup
  block, then each call's number, arguments and result, and the bytes each read returned, to a typed recording file.
- **Replaying:** the replayer starts the same bundle hash with the same startup block and answers each system call
  from the recording at its entry, skipping it (`0056`'s Skip). A call that doesn't match the recording (a different
  number or arguments) stops the replay at that point, which is the divergence report.
- **Exact for one carrier:** a process whose fibers all run on one carrier thread is deterministic between system
  calls. Several carriers race on shared memory without system calls; the recorder pins them to one CPU and records
  the order of their system calls, which replays exactly only if they don't race. That limit is documented, not
  solved (rr solves it with performance counters, which the threat model keeps from being ambient).
- **Hardware side doors:** `RDTSC` is trapped for a recorded process (`CR4.TSD`, set at its context switches, as
  `0009` keeps open); `RDRAND` and `CPUID` stay a convention.
- **Later:** checkpoints of a replay (copying the address space through `read_memory`) for going backwards.

## 6. Tracing and Profiling (12d)

- **IPC tracing** of a process is interception at its channel calls' entry and exit, for recorded or traced processes;
  direct shared-memory IPC isn't traced, as `0024` accepts.
- **The system trace ring:** the kernel writes scheduler events (switches, wakes, budget exhaustion) and IPC wakes
  to a ring per CPU, readable through a tracing capability the root task holds and the configuration grants.
- **Sampling:** a profiling capability over a process subtree asks the kernel to sample, at each tick, the running
  thread's user program counter and its frame-pointer chain (read with fault handling, bounded in depth), delivered as
  packets to a port. Symbols as in §3.

## 7. Open Questions

- Whether the debugger reads Hemera's types from DWARF alone, or Hemera's own schemas are worth carrying beside it.
- How long the events service keeps records by default, and who decides for a session's programs.
- Whether exact replay of several carriers is worth a deterministic scheduling mode in `std` (one carrier at a time,
  switched only at system calls) instead of the kernel.
