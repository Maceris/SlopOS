# Proposal: Clock and Random Source in `Context`

Status: **adopted** into `base/runtime` (2026-10-03), from SlopOS `decisions/0009`.
`Context` has required `clock: ptr[Clock]` and `random: ptr[Random]` fields;
`base/runtime/time.hsc` (`Clock`, `Instant`, `MonotonicTime`, `Duration`, `ClockError`) and
`base/runtime/random.hsc` (`Random`) are the reference for the types. This document keeps
the reasons and what SlopOS still has to do on its side.

## Why
Every source of nondeterminism must come through something a test, debugger or replayer
can substitute (`decisions/0009`), and on SlopOS wall-clock time and entropy come from
server connections the program was granted (no ambient authority). `context` is where
`std` keeps those, exactly as it does for the allocator and logger.

## Design notes that still apply
- **Monotonic and wall time are different types.** `MonotonicTime` (nanoseconds, never goes
  backwards, unrelated to the calendar) versus `Instant` (wall clock, seconds + nanoseconds
  since the Unix epoch). Mixing them up is a classic bug that types rule out.
- **`random` is a generator, not an entropy source.** The default `std` installs a CSPRNG
  seeded once from the OS at startup; replaying a program only needs that seed. Tests
  install a seeded deterministic generator. Code wanting raw OS entropy (key generation)
  uses a separate `std` call that asks the OS directly.
- **Thread safety.** Threads and fibers copy their creator's context, and anything
  reachable from it must be thread-safe or owned by the new thread or fiber (Hemera
  `docs/multitasking.md`, *Contexts*). So `std`'s default `Random` must be thread-safe, for
  example by keeping generator state per carrier inside a no-yield region.
- **Freestanding / kernel.** With `OS == .None` there's no default. The kernel installs a
  `Clock` backed by the arch timer whose `wall` returns `ClockError.Unavailable`, and a
  `Random` seeded from `RDSEED`. Early boot needs placeholders for every required field
  (`../hemera-feedback.md`, item 9).

## Still open
- **Hemera:** no way to subtract two `MonotonicTime` readings into a `Duration`.
- **SlopOS:** `std_proposal/time.now()` is still a stub. It should read
  `context.clock.wall` and decide what to do with `ClockError`.
