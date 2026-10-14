# 0036: Syscall Interception at Entry and Exit Only

Status: accepted
Date: 2026-10-13
Related: `0009` (replay), `0017` (process control), `0023` (one kernel stack per CPU), `0035`

## Context
Recording, replay and debugging need to stop threads at system calls and change their results.
`../design/kernel.md` §4 proposed how to do that within the one-kernel-stack design.

## Decision
- **A thread stops only at syscall boundaries**, at entry and at exit, where its whole state is its
  saved user registers. Stopping never needs a continuation.
- **Attaching** needs the `intercept` right, and covers the target's whole subtree, with a filter
  over syscalls and stop points (`intercept_attach`).
- **Resuming** is `Continue` (with any changed registers) or, at entry, `Skip` (return the results
  the interceptor wrote), which is how a replayer injects results.
- **Blocked threads:** stopping one doesn't cancel its wait, and there is no `EINTR`. A wait that
  completes leaves the thread stopped at its exit point.
- **Detaching** resumes every stopped thread with `Continue`.
- With nothing attached, the cost is one flag test at entry and one at exit.

## Alternatives considered
Stopping anywhere (ptrace-style) needs per-thread kernel stacks or continuations for every kernel
path, which `0023` rules out.

## Consequences
- Processes using rings directly aren't strictly replayable. Recorders give them channel ends
  without the `map` right (`0024`, `../design/kernel.md` §4).
