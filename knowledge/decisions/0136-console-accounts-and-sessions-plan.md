# 0136: The Plan for M10, the Console, Accounts and Sessions

Status: accepted
Date: 2026-11-01
Related: `0016` (users), `0018` (the powerbox), `0042` (unlocking), `0043` (the trusted path), `0097` (10a's and 10c's
items), `0101` (the catch-up's), `0123` (`Secret[T]` in 10b), `../design/console-and-sessions.md`, `../design/shell.md`,
`../roadmap.md` M10

## Context
M10 turns the console service of `0075`/`0077` into the terminal service, and adds the input service, accounts, login,
sessions and the powerbox (`console-and-sessions.md`). Its open questions (`../open-questions.md`, *Console and
sessions*) and the items `lessons.md` §3 proposed for it are decided here. `0097` placed the trusted path's budgets,
the secure attention key's menu, the lifecycle channel with `Ping` and showing the last panic record in 10a, and asking
idle installations to stop under memory pressure in 10c; `0101` placed the root task's services restarted and logging
to the events service, and interrupt controllers unregistered when the platform service restarts, in 10a.

## Decision
Chosen with the project's owner:
- **A typed terminal protocol**: text and operations are separate messages and text is never interpreted, as
  `console-and-sessions.md` §2 has it. Escape sequences exist only in the VT adapter, for the serial line now and SSH
  in M14.
- **The secure attention key** is Ctrl+Alt+Delete on a keyboard and a BREAK on a serial line, recognized by the input
  service (and, for the serial line, the VT adapter) before anything else sees it. Tests send BREAK as telnet's
  `IAC BRK` through QEMU's serial.
- **Ctrl-C** is an `Interrupt` the terminal service sends to the terminal's owner, the shell, which sends the job `Stop`
  over its lifecycle channel and kills it after a grace period (`shell.md` §6).
- **Every item `lessons.md` §3 proposed** is built: a recovery code at setup (each volume key wrapped once more under a
  random code shown once); new keyboards read only by the trusted path until a code shown on screen is typed on them;
  password rules after NIST SP 800-63B (a minimum length, no rotation, common passwords refused); bidirectional and
  invisible characters shown as visible substitutes in all terminal text; the keyboard layout shown on the status line
  at login and switchable there; and `Locale` a context value from the user's configuration.

Decided here, as `console-and-sessions.md` proposed:
- **One powerbox per session**, and **elevation without `sudo`**: re-authentication on the trusted path granting one
  capability to one program.
- **A session ends** by `Stop` over each of its programs' lifecycle channels, then its node killed after a grace period,
  whether by logout or a lost remote connection.
- **Until M11's shell**, a session's first program is a small one of SlopOS's own that shows what it was given and
  exercises the powerbox, standing where the shell goes.

In four stages, each with an as-built record, on both architectures; 10a in parts, as 9c's were:
- **10a, the terminal and input services and the trusted path:**
  - **10a1** the terminal protocol in `std` (styled runs, cursor and region operations, key, paste, resize and
    interrupt events, `Features`), the terminal service replacing the console service, the VT adapter on the serial
    line, Unicode widths (East Asian Width, UAX #29) from tables shared with `std`'s client, and visible substitutes
    for control, bidirectional and invisible characters.
  - **10a2** the input service owning keyboards and the seat, keymaps, new keyboards accepted by a code, the secure
    attention key on both kinds of console, the status line, and the framebuffer back end (a PSF2 text renderer).
  - **10a3** the lifecycle channel in `std` with `Stop` and `Ping`, answered on its own fiber; the secure attention key's
    menu listing the session's programs with their use, not responding ones marked, and ending them; the trusted path's
    services on a reserved budget at the highest user priority; the last boot's panic record shown.
  - **10a4** the catch-up's: the root task's services (entropy, the process manager, the scheduler, the platform service)
    started again when they end and logging to the events service; interrupt controllers unregistered when the platform
    service starts again.
- **10b, accounts:** the account service on its own unencrypted volume, records with Argon2id hashes (RFC 9106's second
  parameters, inside its budget, attempts rate-limited) and wrapped volume keys, the password rules, `Secret[T]` with
  Hemera's `#secret` extended (`0123`), first-boot setup creating the administrator, and the recovery code.
- **10c, login and sessions:** console login on the trusted path with the layout on the status line, the session
  manager (the session's node and budgets, the home volume unlocked, the first program started with its starting
  capabilities), several sessions switched through the secure attention key's menu, ending a session, `Locale`, and
  idle installations asked to save and stop under memory pressure.
- **10d, the powerbox and sharing:** a powerbox per session, `RequestFile`, `RequestDirectory` and `RequestService`
  answered on the trusted path through a chooser, persistent grants as stored links with the user's view to list and
  revoke them, elevation by re-authentication, and shared volumes between users.

R5 (chaos, `0096`) can start once 10a is done.

## Alternatives considered
- **A VT100-compatible stream**: easier ports, but it keeps the escape-sequence and terminfo problems §1 lists.
- **SysRq or Ctrl+Alt+End as the secure attention key**: avoids hosts that intercept Ctrl+Alt+Delete, but less familiar;
  a configuration value can add another later.
- **The terminal service ending the foreground job itself**: the terminal would have to track jobs, which are the
  shell's.
- **Deferring `lessons.md` §3's items to H**: each is cheaper designed into the service that owns it now.

## Consequences
- The console service leaves the tree in 10a1; `hello` and the other clients of `console_log` write through the
  terminal protocol.
- `../roadmap.md`'s M10 gains its stages, and `../open-questions.md`'s *Console and sessions* is answered.
- The recovery generation's console (`0118`) becomes the terminal service; its account service and shell follow in 10b
  and M11.
