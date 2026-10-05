# Proposal: Clock and Random Source in `Context`

Status: **adopted** into `base/runtime` (2026-10-03), from SlopOS `decisions/0009`.
`Context` gained `clock: ptr[Clock]` and `random: ptr[Random]` (required, not optional).
`base/runtime/time.hsc` holds `Clock`, `Instant`, `MonotonicTime`, `Duration` and
`ClockError` (`Unavailable`, `NotSynchronized`); `base/runtime/random.hsc` holds `Random`.
The function pointers take `data: mut rawptr`, and `Random.fill` takes `bytes: mut u8[]`.
Both questions at the end are answered: required fields, and the types live in `base/runtime`.

**Naming differs from the proposal below.** `Instant` is the *wall-clock* type (seconds +
nanoseconds since the Unix epoch, as in Java's `java.time.Instant`), returned by `wall`.
Monotonic readings are `MonotonicTime :: distinct alias i64`, returned by `monotonic`. There
is no separate `Time` type. The text below keeps the original proposal's names. Follow-ups
are in "After adoption" at the end.

## Problem
Hemera's FAQ already lists "the state of a global random number generator" and "a cached
state of the current time" as globals the context system replaces ("The context system
handles passing around things like RNG state…"). But `base/runtime/context.hsc` has no RNG
or clock field, and `std/time.now() -> Time` takes nothing, so where the time comes from is
hidden.

SlopOS needs both to be replaceable per call tree:
- **Replay and testing.** Every source of nondeterminism must come through something a test,
  debugger or replayer can substitute (`decisions/0009`). Today a function that calls
  `now()` can't be tested at a fixed time.
- **No ambient authority.** On SlopOS, wall-clock time and entropy come from server
  connections the program was granted, so `std` needs somewhere to keep those connections.
  `context` is that place, exactly as it is for the allocator and logger.

## Proposed change
Two fields, following the existing `Logger` pattern (a struct of function pointers plus a
`data` pointer):

```
Context :: struct {
    allocator : Allocator,
    logger : ptr[Logger],
    clock : ptr[Clock],          // new
    random : ptr[Random],        // new
    ...
}

Clock :: struct {
    data: rawptr,
    // Monotonic: never goes backwards, unrelated to the calendar. Always available.
    monotonic: fn(data: rawptr) -> Instant,
    // Wall clock: may be unavailable (no clock granted, or not yet synchronized).
    wall: fn(data: rawptr) -> Result[Time, ClockError],    //HEMERA(guess): Result spelling
}

Random :: struct {
    data: rawptr,                 // generator state, owned by whoever installed it
    fill: fn(data: rawptr, bytes: []u8),
}
```

## Notes on the design
- **Monotonic and wall time are different types.** `std_proposal/time` currently has one
  `Time { nanoseconds: i64 }` with no stated epoch. Proposal: `Instant` (monotonic, only
  comparable and subtractable, giving a `Duration`) and `Time` (wall clock, calendar
  functions). Mixing them up is a classic bug that types can rule out.
- **`random` is a generator, not an entropy source.** The default `std` installs a CSPRNG
  seeded once from the OS at startup. Replaying a program only needs that seed. Tests
  install a seeded deterministic generator. Code wanting raw OS entropy (key generation)
  can use a separate `std` call that asks the OS directly.
- **Freestanding / kernel.** With `OS == .None`, there's no default. The kernel installs a
  `Clock` backed by the arch timer (`monotonic_now`) whose `wall` returns `NotSupported`, and
  a `Random` seeded from `RDSEED`. Ties to the "context before any allocator exists" item in
  `../hemera-feedback.md`: early boot needs sensible placeholders for every required field.
- **Cost.** One pointer each in `Context`, which is copied on `push_context`. Like the
  logger, it costs nothing for code that doesn't use it.
- **Thread safety.** `Random` state is mutable. Like any context field, a new thread
  starts with whatever context it's given, so `std`'s thread creation should give each
  thread its own generator, forked from the parent's, so threads don't share state without
  synchronization.

## Questions for the Hemera side
- Required fields (like `allocator`) or optional (`ptr[Clock]?`)?
- Should `Instant`/`Duration`/`Time` live in `base/runtime` (needed by the `Clock` signature)
  or in `std/time` with `base` holding only the function-pointer shape?

## After adoption
Done since adoption (2026-10-03): the `Duration` comments were fixed; the missing `Time` was
settled by using `Instant` as the wall-clock type and adding `MonotonicTime`; and
`std_proposal/time` now uses `Instant` instead of its old `Time { nanoseconds: i64 }`.

Still open, all small:
- **Threads share the generator.** Answered on the Hemera side (2026-10-04) by a rule rather
  than forking: threads and fibers copy the creator's context, and anything reachable from it
  must be thread-safe or owned by the new thread or fiber (Hemera `docs/multitasking.md`,
  *Contexts*). So `std`'s default `Random` must be thread-safe, for example by keeping
  generator state per carrier inside a no-yield region.
- **`MonotonicTime` has no stated unit.** Presumably nanoseconds (an `i64` of nanoseconds
  covers about 292 years). Worth a comment, and eventually a way to subtract two readings
  into a `Duration`.
- **`Instant.seconds` is unsigned.** Clock readings never predate 1970, but `Instant` is
  also the type for calendar times and file timestamps in `std` (`date(t: Instant)`), which
  can. Java's `Instant` uses signed seconds for this reason.
- **SlopOS side:** `std_proposal/time.now()` should read `context.clock.wall` once it's
  filled in, and decide what to do with `ClockError`.
