# 0180: Shutting Down When Asked, and Boot Tests That End When They're Done

Status: accepted, chosen with the project's owner
Date: 2026-11-06
Related: `0067` (the supervisor), `0068` (the root task), `0115` (healthy boots), `0179` (11e), `../design/lessons.md`
§5 (P, power), `../roadmap.md` M11

## Context
Nothing could shut SlopOS down: the root task never ended but in a boot test, after `test_settle` seconds. About 30 boot
tests (the shell's, the sessions', the multi-user and powerbox ones, the file tools') type into the console and then
wait out that timer, set long enough for their slowest run; together they were some 55 of a run's 80 test-minutes,
mostly spent waiting after the work was done.

## Decision
- **The secure attention key's screen shuts the system down**: P, shown on it with the other keys, asks the supervisor
  on a `power` connection the terminal service is given; the supervisor has the volumes committed, then passes it to
  the root task as the supervision report `ShutDown`; the root task ends with 0, which ends everything, as a boot test's end always has. Whoever is at
  the console may, logged in or not: they can cut the power too.
- **The settle wait is the root task's main loop's deadline**, not a loop of its own, so a shutdown asked for during it
  ends it, and services that end meanwhile are started again as at any other time.
- **Boot tests end when they're done**: `boot.py --shut-down-when-done` types Ctrl+Alt+Delete and P once every expected
  console line has been shown and all the input typed. The settle-bound tests use it, keeping their expectations of a
  clean end (the root task ends with 0, only the kernel's objects are left), with `test_settle` as the most they wait.

## Alternatives
- **Stopping QEMU once the expected lines are seen**: no change to the system, but those tests would stop checking that
  it ends cleanly.
- **Shorter settle times**: the runs vary too much, on AArch64 above all, for a time that's both short and safe.
- **The interactive tests on x86-64 alone**: halves their cost, but they're cheaper now anyway, and keep both.

## Consequences
- Before it tells the root task, the supervisor has the storage manager commit every writable volume it serves
  (`storage`'s `CommitAll`, each volume server's `Commit`), so nothing done before the shutdown is lost. The services
  themselves end as abruptly as they always have at a test's end; a graceful shutdown, each asked to stop in reverse
  dependency order with a deadline (`../design/lessons.md` §5), is P's.

## As Built (2026-11-06)
- **The system**: the `power` protocol (`src/protocols/power`); the supervision report `ShutDown`; the storage
  protocol's `CommitAll`, each writable volume served told to `Commit`; the supervisor's `power_connection` and
  `serve_power`, done once; the terminal service's `power` grant, P and `shut_down`, and the line "P shuts the system
  down." on the secure attention key's screen; the system configuration has the supervisor serve `power`. The root
  task's settle is its main loop's deadline.
- **`boot.py --shut-down-when-done`**: waits for the first input line to be typed, every expected console line to be
  shown, and every expected serial line but those of a run's end (`RUN_END_LINES`) to be written, then types the secure
  attention key and P. 17 tests use it; those settling 4 to 8 seconds, several of which test the secure attention key's
  screen itself, and the automatic snapshots' test, which waits on time, don't.
- **Found on the way**: 11e2's six new programs made 64 boot modules, and the root task, given one grant a module,
  had room for 64 grants, so the test programs, last, weren't given: 80 tests failed. `MAX_ROOT_GRANTS` and the boot
  protocol's `MAX_MODULES` are 128 now.
- **The result**: a full run took 7.6 minutes, from about 14, its tests 48 test-minutes from 78; the slow multi-user
  tests from 160 to 200 seconds to under 40. A test whose powerbox request is up when the keys come goes on to its
  settle, as the key opens the chooser then.
