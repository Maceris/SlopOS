# 0128: Pa, Tickless Idle, as Built

Status: accepted
Date: 2026-10-31
Related: `0127` (Perf's stages), `0050` (ticks), `0051` (quiescent-state reclamation), `0049` (IPIs)

## Context
`0050` had every CPU tick 100 times a second, idle or not. `0127`: a CPU with nothing to run arms its timer only for
what it has to wake for.

## Decision
- **When a CPU stops ticking**: going idle with nothing queued and nothing of its own waiting for a grace period, it
  arms its timer only for its own timers (ports' and waits' deadlines), or for nothing. Not the boot CPU, whose ticks
  keep the kernel's own time: when it stops, its tests, polling for DMA faults, and the root task's grace period.
- **Quiescence**: such a CPU holds no object, so it counts as past every quiescent point (`IDLE_EPOCH`, which the
  oldest epoch's minimum passes over) until an interrupt wakes it. Every interrupt from idle goes through the
  kernel's entry, which records the epoch first, with a full fence, before anything else runs (`leave_idle`), and
  ticks again from then.
- **Waking**: a thread made ready on an idle CPU already sends it an IPI. A thread queued behind what a CPU is running
  now also wakes an idle CPU that isn't ticking, which would otherwise not look to steal it until something woke it.
- **Tests**: `test_tickless`, four CPUs and nothing to run: over 50 of the boot CPU's ticks the other three take no
  timer interrupts, where they took about 50 each before; the full suite and the Perf baselines as before.

## Alternatives considered
- **The boot CPU tickless too**, with its housekeeping moved to timers: the tests' and the stop's timing all count its
  ticks, for no saving on an idle machine of one CPU's 100 interrupts a second.
- **Ticking while anything's queued anywhere**: simpler, but a busy CPU would keep every idle one awake.

## Consequences
- An idle machine wakes only its boot CPU, 100 times a second; a CPU running a budget still ticks to share it.
- The benchmarks that aren't held to their baselines have grown since `0112` took them, on AArch64 a program's start from
  about 41 to 102 million instructions and boot to healthy from 16 to 23 billion: libraries bound at every start and
  more grants (9e, 9f), not ticks. Worth a look, and new baselines, with Perf's next stages.
