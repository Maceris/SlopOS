# 0146: Boot Tests Steady Under Load

Status: accepted
Date: 2026-11-02
Related: `0145` (the tests seen to fail under load), `0144` (the parallel runner), `0109` (CPU budgets lent to servers)

## Context
Booted 8 or 10 at once, four tests failed now and then, and passed alone: the console's echo, the console's echo
after a driver restart, `test_lending`'s priority, and `test_pool`'s spread over CPUs. Each assumed a QEMU's CPUs keep
pace with one another and with the host, which a busy host doesn't promise.

## Decision
- **The console tests** wait longer before the root task ends (`test_settle=4`), and the echo test types once the
  console shows hello's line (`boot.py --console-input-after`): typed at the banner, its echo and hello's line could
  land on one line.
- **`test_pool`'s CPUs start their pools together**, and a fiber that's taken its turns goes on yielding, uncounted,
  until its pool has run on all its CPUs and moved a fiber, for up to 4 seconds: one CPU could otherwise do all its
  pool's work before a stalled one joined.
- **`test_lending`** counts only the backlog answered once both requests lent the high budget are waiting, and while it
  hasn't yet seen both answered; and it makes up to 3 attempts, passing if one shows them served first. Answers on
  separate connections can't be ordered when the host stalls the supervisor's CPU for long, but a server that took
  connections in turn, or served each queue whole, would answer six or more first in every attempt.
- `test_pager` counts before it supplies (`0145`).

## Alternatives considered
- **Longer waits everywhere**: they slow every run and only move the line.
- **Booting fewer tests at once**: the runs would be steadier, and slower, and the timing they depend on no less wrong.

## Consequences
- Under stress (200 to 240 runs each, 10 at a time) the four didn't fail again.
- The terminal service writes a program's output where the cursor is, so output that comes while a line is being typed
  shares its line, as a terminal in cooked mode does.
