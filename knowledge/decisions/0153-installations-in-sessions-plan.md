# 0153: The Plan for 10c4, Installations in Sessions and Memory Pressure

Status: accepted
Date: 2026-11-02
Related: `0149` (10c's plan), `0150` to `0152` (login, sessions, locale), `0113` and `0117` (installations), `0097`
(the session manager asking idle installations to stop), `../design/lessons.md` §9.2

## Context
`0149`'s 10c4: idle installations asked to save and stop under memory pressure, by the session manager. Installations
run in the supervisor now, for the whole system, so the session manager has none to ask.

## Decision
Chosen with the owner as 10c4 started:
- **Installations move into sessions.** A session runs the system's installations: the session manager starts them when
  the session starts, on its budget, each with its data in the session's user's home volume (`apps/<name>`), or the
  system volume's for a session with no user, and its settings in the config store under `user:<user>:<name>`
  (`user:-:<name>` for none). The supervisor keeps running only system services. Updating and uninstalling an
  installation are the session manager's: stopped, then started from its new bundle; or stopped, its data and settings
  removed.
- **Installations keep running** until they're asked to stop; the counter counts once at its start, then waits.
- **Idle** is any program of a session that isn't the one shown, the least recently shown session's first; a session's
  first program (echo, the shell later) is never stopped.
- **The policy**: the session manager's budget raises its pressure signal at 80% of its limit; it then asks one idle
  installation at a time to save and stop, over its lifecycle channel, each given its grace period, until use is under
  70%.

In two parts:
- **10c4a** installations in sessions: the session manager's connections to the bundle store and the system volume's
  `apps`, the system's list of installations from the supervisor, each session's installations started, and the
  installation test (an update refused, one taken that keeps the data, an uninstall, a reinstall) run by the session
  manager in a session of its own.
- **10c4b** the pressure policy: the terminal service telling the session manager which session is shown, the
  threshold, and idle installations stopped until use is back under it.

## Alternatives considered
- **The policy for the supervisor's installations**: the session manager is where the design puts it, and
  installations are a user's.
- **The policy first, installations moved later**: the policy would have nothing of a user's to act on.

## Consequences
- A boot from a disk runs no installations until someone logs in.
- What installs and removes installations for a user (a shell, a store) comes later; until then each session runs the
  system's list.
