# 0195: M18, Launch Identity, Planned

Status: accepted (2026-11-23), planned with the project's owner as a milestone of its own; started 2026-11-23
Date: 2026-11-22
Related: `0193` (M16; 16b, the simpler fix this replaces), `0181` (the powerbox's names), `0183` (12a, the shell's
crash reports through intercepts; 12d, profiling), `0185` (debugging and elevation)

## Context
The powerbox tells the user which program asks, by the name its connection is served under. M16 (`0193`, 16b) made
only shells name those connections, so a program can't get one under another's name, and trusts shells, which control
what they start. Anything else that starts a program with powerbox access needs the name to come from what the child
runs, and working that through (2026-11-21) found three things it rests on:
- **What a process runs.** The process manager loads it, so it can say which executable it loaded where; the kernel's
  `handle_same` (16b) lets another server check that against an executable it handed out.
- **Who holds the connection.** A name settled after the load needs proof the child holds the connection, and only
  the child: a launcher that copied the handle first could get the copy named for a genuine child and keep using it.
- **Who controls the child.** `os.launch` leaves the launcher the child's process with every right: it can attach an
  intercept at any time and stop the child's threads and change their registers, as the shell's crash reports,
  `profile` and the debugger do. Named by what it runs, a child its launcher steers still speaks for the launcher.

## Proposal
- **18a, the process manager makes launched processes.** `Load` makes the child's process and address space itself;
  the launcher gets a handle that watches the child's end and ends it, without the rights to intercept it, make
  threads in it or touch its memory. `os.launch` (Hemera's std) and every launcher change with it.
- **18b, intercepts on the user's say.** A launcher's crash reports and `profile` ask for an intercept of the child
  from the process manager, which gives one that reports faults or samples but can't change the child; a debugger's,
  which can, comes through the session's powerbox, the user allowing it, as attaching does now (`0185`).
- **18c, handles that only move.** A system call that drops a handle's rights in place, owning or not, so a channel's
  end without `RIGHT_DUPLICATE` can be moved and never copied.
- **18d, names from the launch.** A launcher asks the session manager for a pending powerbox connection, its end
  move-only, which the powerbox doesn't read until it's named; it gives it to the child as its powerbox grant. The
  process manager keeps, for each process it loads, the executable and the grant labelled `powerbox`, and answers who
  asks with the process's handle. The session manager matches the executable against those it handed out (`Find`) and
  the grant against its pending connections, by `handle_same`, and has the powerbox serve the connection under the
  program's name. Shells name only themselves and their scripts by hand.
- **18e, the rate limit and the band by identity, and a review.** The powerbox's limits keyed by the name a launch
  proved; the identity band for programs anything starts; a security review and the full suites.

## Settled with the owner (2026-11-22)
- **A shell's own children go through 18d**, as every launch does. A shell runs scripts, and through the SSH service a
  remote login's commands, so a bug or a hostile script in it shouldn't be able to misname a program; one path is
  simpler to trust and to test; and with 18b its crash reports and `profile` take intercepts that only report, so its
  children are unsteered and named by launch like anyone's. A shell names by hand only itself and its scripts, which
  run in it, the powerbox showing a script's name as a script's ("backup.sh, a script"), the shell vouching for it.
- **Recording and replay are steering** (`0183`, 12c): trapping the counter and feeding recorded results back are
  what a debugger's intercept does, so they take one on the user's say (18b), not a launcher's right of their own. The
  process manager makes a replay's process with the recording's seeds and layout, as `Load` takes seeds now. The
  session manager names a connection by launch only for a process the process manager says has no steering
  intercept, the one rule covering debuggers, recordings and replays. A replay gets no powerbox connection, as what it
  was given while recorded can't be replayed anyway: one that asks is refused, as a program without one is (settled
  2026-11-23).
