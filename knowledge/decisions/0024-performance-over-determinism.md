# 0024: Performance Over Determinism: Direct IPC by Default, Replay Opt-In

Status: accepted
Date: 2026-10-04
Amends: `0009` (the replay rule)

## Context
`0009` says *all nondeterminism a process sees arrives as a syscall result*, so a recorder
can capture it. The IPC design (`../design/ipc.md`) moves messages through rings shared
between processes, with the kernel involved only for wakeups and handle transfer. Reading a
shared ring isn't a syscall, and how much a reader finds there depends on timing, so
direct IPC breaks `0009`'s rule as stated. Routing every message through the kernel would
keep the rule, at a cost on every message of every program.

`0009` already accepts one exception of this kind: a program that reads `RDRAND` or `RDTSC`
directly is simply not replayable, and that isn't a security issue.

## Decision
**When performance and determinism conflict, performance wins.** Replay is a facility a
process can be run under, not a property every process pays for.

**Channels have two access modes over the same rings and message format** (`../design/ipc.md` §6):
- **Direct** (the default): the process maps the rings and reads and writes them without
  syscalls. Wakeups and handle transfers are the only kernel entries.
- **Through the kernel:** `channel_read` / `channel_write` copy through the kernel. Every
  receive is a syscall result, so `0009`'s rule holds.

**Which mode a process uses is decided by whether its channel ends carry the `map` right.**
`std` uses direct access whenever it has `map`, and the kernel path otherwise. The peer
can't tell the difference.
- A **recorder** launches the process it records with ends that lack `map`. Every channel
  that process receives later passes through grants the recorder controls, so the recorder
  can strip `map` from those too. The recorded process is fully replayable, and slower.
- A process that has `map` and uses it **opts out of strict replay**, in the same way as one
  that reads `RDRAND`. The direct mode is never forbidden, and nothing checks whether a
  process "should" be replayable.

**`0009`'s rule, amended:** *all nondeterminism a process sees arrives either as a syscall
result, or through shared memory or hardware side doors it was able to use. A process can be
replayed exactly if it was run without the second kind.* Data races between threads were
already in the second kind.

## Alternatives considered
- **All IPC through the kernel:** keeps `0009` intact, but adds two kernel entries and a copy
  to every message for the sake of a debugging feature most runs never use.
- **Direct IPC only, replay given up:** loses a differentiating feature
  (`../problems-and-directions.md` §14) when keeping it costs only a second code path in
  `std`.
- **Record shared rings by snapshotting memory** (as rr does for some shared mappings):
  heavy, and races with the peer anyway.

## Consequences
- `std`'s channel layer has two backends and must keep them behaviourally identical. Both
  sit behind one interface, and tests run against both.
- The same pattern is available for any future shared-memory facility (a mapped port
  completion ring, a shared clock page): direct by default, a kernel path for recording.
  `0009` rejected a vDSO-style time page for the default path; under this decision such a
  page could return as the direct mode if syscall cost for time turns out to matter.
- The tiebreaker "performance over determinism" applies to future decisions too, where the
  determinism in question is replay rather than security.
