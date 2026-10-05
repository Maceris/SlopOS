# 0009: The Ambient Floor, Startup Grants, and Replay Through Syscalls

Status: accepted (replay rule amended by `0024`)
Date: 2026-10-02

## Context
Principle 1 (no ambient authority) needs a precise floor: what can a process do while
holding no capability at all? `../problems-and-directions.md` §14 also wants record/replay,
which requires every source of nondeterminism to enter a process somewhere it can be
recorded. The two goals overlap but aren't the same. Replay needs nondeterminism to be
*observable*. Confinement (a sandbox that can't tell the time) would need it to be
*withholdable*. Only replay is a goal.

## Decision
**Replay is the goal for time and randomness, not confinement.** The rule is: *all
nondeterminism a process sees arrives as a syscall result* (an IPC receive is a syscall
too). A recorder captures syscall results, and a replayer returns them again.

**Truly ambient (no handle needed):**
- Executing instructions and using memory already mapped into the process.
- Syscalls that operate on handles the process holds.
- Reading **monotonic time** from the kernel (a syscall, so it's recorded).
- Blocking with a timeout or deadline. Whether a wait timed out is a recorded syscall result.
- `yield` and `exit`.

**Granted at startup, never ambient:** everything else, as handles in the typed spawn
context (§7). Typical grants are the process's own address space and memory budget
(`0011`), a limited handle to itself, and whatever the launcher chooses for logging. A
launcher, debugger or recorder can withhold, attenuate or substitute any of them.
- **Logging** is a startup grant: a handle to a file, a data store or the events service.
  Each program decides what logging means through its own `context.logger`, and what that
  logger can do is bounded by the capabilities the program was given.
- **Wall-clock time** is a server protocol (`clock`, `../design/layers.md` L3). RTC, NTP and
  time zones are policy and stay out of the kernel.
- **Entropy** is a server protocol (`entropy`, L3). A program seeds a `std` CSPRNG from it,
  so replay only has to record the seed, not every random byte.

**Hardware side doors are closed by convention, not enforcement.** `RDTSC`, `RDRAND`,
`RDSEED`, `RDPID` and `CPUID` give nondeterministic results without a syscall. `RDRAND` and
`RDSEED` can't be trapped on bare metal, so a rule against them can't be enforced against
hostile code. Programs built with the SlopOS toolchain use `std`'s clock and random source
instead of these instructions. A house-rule check (`0007`) can restrict the corresponding
intrinsics to the packages that implement those sources. A program that bypasses this simply
isn't replayable; it isn't a security issue.

**Syscall interception for debuggers.** The kernel provides an interception facility usable
by holders of the `debug` right on a process: stop the target at syscall entry and exit,
read or replace arguments and results, and inject results without running the call. Record
and replay are built on this in user space, as a debugger that records results and later
answers them.

## Alternatives considered
- **Time and entropy as capabilities for confinement.** Withholding time can't actually
  confine a process (a thread counting in a loop is a clock), and it would make timeouts
  and every `std` time function need a handle. Rejected: timing and covert channels are out
  of scope.
- **vDSO-style shared time page.** Fastest way to read time, but reads of shared memory
  can't be recorded. Rejected for the default path. Could return later as an opt-in if
  syscall cost for time turns out to matter, with the process marked not replayable.
- **Trapping `RDTSC` with CR4.TSD.** Possible, and could be done per process at context
  switch. Not needed under the convention. Kept as an option for recorded processes if the
  convention proves too leaky in practice.
- **Entropy as a kernel object.** The kernel needs RDSEED for itself anyway, but user space
  gets entropy from the L3 service so the kernel stays policy-free. The root task can seed
  the entropy service from the boot seed before any hardware RNG driver is running (`0012`).

## Consequences
- `std` on SlopOS reads monotonic time through a syscall, wall time through a `clock`
  connection, and randomness from a CSPRNG seeded from an `entropy` connection. Hemera's
  `Context` should carry a clock and a random source so code can be tested and replayed
  without changes: `../hemera-proposals/context-clock-random.md`.
- Multithreaded processes racing on shared memory are a source of nondeterminism this
  decision doesn't cover. Replaying them needs the schedule recorded too (rr serializes
  threads onto one core). Out of scope for now.
- The interception facility has to be designed with the syscall ABI and the IPC primitive
  (open questions under *Kernel*). It is the one place where one process can act on
  another's syscalls, so it must be gated by `debug` and nothing else.
