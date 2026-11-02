# 0155: 10c4b, Idle Installations Stopped Under Memory Pressure, as Built

Status: accepted
Date: 2026-11-02
Related: `0153` (10c4's plan), `0154` (installations in sessions), `0151` (several sessions), `0111` (budget
thresholds), `0097`, `../design/lessons.md` §9.2

## Context
`0153`'s second part: under memory pressure the session manager asks idle installations to stop, those of sessions the
console doesn't show.

## Decision
- **Which session is shown**: the session protocol's `Shown(number)`, answered `Noted`, `NO_SESSION` for none. The
  terminal service sends it whenever the shown view changes: a session started, a switch, a login for another session
  begun (none), and a logout that leaves the login screen (none). The session manager counts the times it's told, and
  keeps each session's count from when it was last shown.
- **The threshold**: the session manager's budget, which its programs' budgets are split off and charged to, has its
  threshold at 80% of its limit, its `SIGNAL_PRESSURE` bound to its port.
- **Relief**: on the signal, until the budget's use is under 70% of its limit, the session manager picks the
  installation of a session not shown whose session was shown least recently, asks it to stop on its lifecycle channel
  and ends it after the grace period, as `End` does; when none is left it says so and stops looking. A session's first
  program (echo) is never picked, nor any program of the shown session.
- **Stopped is stopped**: an installation stopped this way isn't started again when its session is shown; that waits for
  what starts apps for a user (a shell).
- **Tests**: `test_pressure`, once two sessions are in use and one is shown, splits a budget off the session manager's
  up to its threshold, which raises the signal; the idle session's counter is stopped, the shown session's left
  running, and the charge given back. The boot test makes the administrator, logs in, then logs in another session
  from the secure attention key's screen.

## Alternatives considered
- **Idle as unanswered pings**: the runtime answers pings on a thread of its own, so a program busy or waiting answers
  alike; being shown is what the user sees.
- **Asking every idle installation at once**: one at a time stops only as many as the pressure needs.

## Consequences
- The terminal service waits on the session manager's answer to `Shown`, which can take a stop's grace period while
  pressure's being relieved.
- Installations run again only in a new session until a shell starts them.
