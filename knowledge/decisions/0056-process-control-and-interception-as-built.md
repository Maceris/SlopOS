# 0056: Process Control and Interception as Built

Status: accepted
Date: 2026-10-23
Related: `0009` (replay through interception), `0017` (process-control rights), `0023` (stops only at call
boundaries), `0054` (faults), `../design/kernel.md` §4 and §5, `../design/ipc.md` §3, `../roadmap.md` M5

## Context
M5's fourth stage, third part (4c). `../design/kernel.md` §4 designs syscall interception (stops at entry
and exit, `Continue` and `Skip`, waits not cancelled, detaching resumes), and `0017` the five process
rights over a subtree. Left open: how much of it to build now, where faults go (§5's open question), and
how a debugger names another process's threads and memory. Until now a fault outside committed memory
destroyed the thread.

## Decision
Chosen with the project's owner:
- **All of `0017`**: the rights `inspect`, `read_memory`, `write_state`, `intercept` and `kill`;
  intercepts with a syscall filter and entry and exit stops; register access; suspend and resume; memory
  access; kill; and a signal when a process or thread ends, for supervisors.
- **Faults go to the subtree's exception port**: an intercept that asks for faults stops the faulting
  thread, which the debugger can fix and retry, or kill. With none, the thread is destroyed, as before.
  Pagers per memory object wait for memory-mapped files.
- **Everything goes through the process handle**: memory calls take the process and an address space in
  its subtree; thread calls take the process and a thread ID, from `ProcessThreads` or a stop.

As built:
- **Holding a thread** (a suspend or a stop) parks it only where its whole state is its saved registers
  (`0023`): a running thread at its CPU's next schedule (an IPI if it's elsewhere), a queued one at once,
  a blocked one when its wait is over and its results are written, before it runs. Registers can be
  read and written only while it's parked. Nothing else changes in the scheduler's fast path but a test
  of the held bits.
- **An intercept reports stops through one port binding**, counting them in a `Stop` packet, with the
  stopped threads on the intercept's own list, which `InterceptNext` reports one by one. The design's
  "packet slot in the TCB" would need a binding per thread in the debugger's port; one binding and a list
  keep stopping allocation-free and the port's keys the debugger's own.
- **`Continue` at an entry makes the call again from user mode**: the thread's instruction pointer goes back
  to the system call instruction (`arch.restart_syscall`, a new arch-interface function) and it skips that
  entry stop once. The kernel has one stack per CPU and no continuation, so a stopped call can't be
  resumed in the kernel; going back through user mode costs one more entry and needs nothing kept.
- **Exit stops come after the result is written**: at the end of a call that didn't block, and after a
  blocked call's wait completes, before the thread runs.
- **One intercept per process**; the nearest intercepted process above a thread is the one it stops for,
  so a debugger inside an intercepted subtree can debug its own children. When nothing is intercepted, a
  stop costs one counter test.
- **Registers** are exposed by index in an order the ABI fixes per architecture (arch-interface functions
  `user_register_count`, `get_user_register`, `set_user_register`); writing refuses kernel addresses for the
  instruction and stack pointers, and changes only the flags user mode can.
- **Threads are found by ID** on a kernel-wide list, checked to be in the subtree by walking owners up, and
  processes' and threads' ends raise `SIGNAL_TERMINATED` on up to two watching bindings each.
- **An intercept is charged to the attaching process's budget**: `InterceptAttach` takes no budget argument.

## Alternatives considered
- **Interception only**: a debugger could stop threads but not read their memory or suspend them.
- **A per-thread stop packet** (`../design/kernel.md` §4 as written): see above.
- **Resuming a stopped call in the kernel**: needs a continuation per thread, against the one-stack design.
- **Memory and registers only through the intercept**: a process monitor with `inspect` alone couldn't list
  or read anything.

## Consequences
- A recorder needs `intercept`, `read_memory` and `write_state`; a replayer answers calls at their entry
  with `Skip`.
- Memory is read and written through page tables, so pages of a memory object no thread has touched can't
  be read yet; pagers and a fill-on-read for debuggers come later.
- Finding a thread by ID walks every thread; a per-process index can come when it matters.
- `std`'s debugger and supervisor libraries (M6) build on these calls.
