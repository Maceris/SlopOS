# 0139: 10a3, the Lifecycle Channel, the Secure Attention Key's Programs and the Trusted Path's Budget, as Built

Status: accepted
Date: 2026-11-01
Related: `0136` (M10's plan), `0138` (10a2), `0097` (the lifecycle channel and `Ping`, the trusted path's budgets),
`0134` (the panic record), `../design/shell.md` §6, `../design/console-and-sessions.md` §3

## Context
`0136`'s 10a3: the lifecycle channel in `std` with `Stop` and `Ping`, answered on its own fiber; the secure attention
key's screen listing the session's programs with their use, those not responding marked, and ending them; the trusted
path's services on a reserved budget at the highest user priority; the last boot's panic record shown. Hemera's runtime
had no threads on SlopOS, so `Ping` couldn't be answered apart from the program's code. Chosen with the owner as 10a3
started: real runtime threads on SlopOS first.

## Decision
- **Threads in Hemera's runtime on SlopOS** (`base/runtime/slop_os_threads.hsc`): `runtime.thread_create` and
  `thread_start` make a kernel thread in the process's address space, on a stack of its own mapped from the startup
  block's free range (256 KiB, or a fixed size asked for), its carrier block in its `Thread`; joining waits for the
  thread's `SIGNAL_TERMINATED` and gives its stack back. The kernel has no wait on an address yet, so `wait_on_value`
  spins, as without an operating system.
- **The lifecycle channel** (`base/runtime/slop_os_lifecycle.hsc`, `std/os/slop_os`'s `lifecycle`): a launch's
  `lifecycle` option gives the program its end as the grant `lifecycle`; base's runtime starts a thread of its own on a
  16 KiB stack before `main`, from the entry, which answers `Ping` with `Pong` and its sequence and `Stop` with
  `Stopping`, so answering doesn't depend on the program's code. Messages are 8 bytes, a kind and a sequence, through
  the kernel's copying channel calls, like base's events doorbell: no mapping and no generated protocol code in base.
  A program learns of a `Stop` from `lifecycle.stop_requested()`, or a `User` packet on a port it asked for one on
  (`lifecycle.on_stop`). Rather than a fiber, a thread: the program's own code has no fibers to share.
- **The supervisor** gives every program it launches a lifecycle channel, keeping its end, and serves the terminal
  service a **session** channel (`src/protocols/session`) for the console's programs (echo and hello) until 10c's session
  manager: `List` answers each running program's memory in use and its budget, and whether it answered a `Ping` within
  250 ms; `End` sends `Stop`, waits 2 s, kills it if it's still running, and doesn't start it again.
- **The secure attention key's panel** lists them, the chosen one inverse, those that didn't answer marked "not
  responding": Up and Down choose, E (or Delete) ends the chosen one, Esc or Enter goes back. echo ends with 0 when it's
  asked to stop.
- **The trusted path's budget**: the input and terminal services run on `TRUSTED_PATH_CPU`, priority 250, above
  everything people run (200), a tenth of a CPU each of their own, which they lend to no server; the test of lending
  lends echo's instead of the terminal service's.
- **The last boot's panic record**: the root task gives the supervisor the `last_panic` module, which gives it to the
  terminal service, which shows its first line on the panel and says so on the status line until the panel's been seen.

## Alternatives considered
- **A raw lifecycle thread without general threads**: less, but `runtime.thread_create` was wanted on SlopOS anyway.
- **The program's own loop answering `Ping`**: a program that never called it would be "not responding".
- **The lifecycle channel as a generated `std` protocol**: base, which serves it, can't use `std`'s protocol code.
- **The terminal service ending programs itself**: it holds no process handles, and shouldn't; whoever runs the
  session does.

## Consequences
- Every program on SlopOS has a second thread while it has a lifecycle channel, and 16 KiB more of its budget.
- "Not responding" now means the process doesn't run at all (stopped, or starved), since the runtime's thread answers
  while `main` is busy; whether a program's own loop is stuck is the program's to say, later (`Progress`, M11).
- 10c's session manager serves the session protocol in the supervisor's place, for a session's programs.
- With the input service, the terminal service and echo each a tenth of a CPU, a one-CPU machine's root CPU budget is
  now split whole (5 budgets and the default); another fixed share needs a smaller one somewhere.
- edu_dma's budget went from 1 MiB to 2 MiB: with the lifecycle thread's stack, its first log record with an address
  had no heap for the type's schema, and Hemera's logger (since a95db13) drops such a record rather than ending the
  program, so the line the test expects was lost.
