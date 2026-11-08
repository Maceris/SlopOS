# 0184: A Port Wait With No Room for a Packet Is Refused

Status: accepted
Date: 2026-11-08
Related: `0035` (async shared-ring IPC with ports), `0052` (port bindings and waits), `0183` (M12, whose 12c found
this), `../../docs/specs/system_calls.md`

## Context
`port_wait(port, packets, deadline)` with empty `packets` returned 0 at once, without looking at the port or its
deadline, as the kernel's `port_wait_begin`, `std`'s doc and the spec all said. That makes an empty wait look like a
pause: it reads as "wait until the deadline, taking nothing", and it compiles, but it doesn't wait at all.

Building 12c, `test_control`'s `a_recorder_traps_counter_reads` paused that way for 50 ms, on the test's intercept
port, to let a newly set trap take effect before telling the traced process to read the counter. The test then stalled
until the boot test's 60 s timeout, on x86-64 and AArch64. It looked like `port_wait` never returned. Reproduced in
`test_ports`, the empty wait returned within 0.3 ms on x86-64 and 50 µs on AArch64, and putting the empty pause back
in `test_control` stalls it again. So `port_wait` returned. The pause didn't pause, the process read the counter before
the trap was in effect, no stop came, and the test's `next_stop`, waiting with `NO_DEADLINE`, waited forever.
(`a_debugger_breaks_steps_and_watches` had the same empty pause, which happened to be harmless there.)

## Decision
A wait with no room for a packet is refused: `port_wait` gives `PortError.BufferTooSmall` (tag 16, new to
`PortError`, the tag and meaning `ChannelError` already has), at once, whatever the deadline and whatever is queued.
Queued packets stay for the next wait. `channel_notify_and_wait` refuses an empty `packets` the same way, with
`ChannelError.BufferTooSmall`, before it raises anything on the other end. A non-empty buffer is unchanged.

A pause until a deadline is a wait with room for a packet on a port nothing is bound to, as `test_control`'s
`pause_for` does, or a timer binding.

## Alternatives considered
- **Return 0 at once (as before).** Silent: a mistake reads as a pause and becomes a busy loop or a race, as here.
- **Wait until the deadline and give 0.** That makes an empty wait a sleep, but its semantics aren't clear. A packet
  that comes before the deadline can't be taken: does the wait end early, leaving it queued, or ignore it? Ending early
  makes it an unreliable sleep on a busy port, and ignoring it makes a port wait that doesn't wait for the port. It
  would also block a thread that holds a port's wait right for nothing. Sleeping has better forms, which say what they
  mean.
- **`BadBuffer`.** It already means the packets are memory the caller can't write, which is a different mistake, and
  sharing it would make the two harder to tell apart.

## Consequences
- A caller passing an empty buffer finds out at once, from an error, rather than from a race later.
- `PortError` gains a member. The system ABI isn't frozen (`0025`, `0027`), and no caller in SlopOS or `std` passed
  an empty buffer.
- Covered by `test_ports`' `an_empty_wait_is_refused_at_once`.
