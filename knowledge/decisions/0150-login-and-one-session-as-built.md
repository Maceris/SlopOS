# 0150: 10c1, Console Login and One Session, as Built

Status: accepted
Date: 2026-11-02
Related: `0149` (10c's plan), `0148` (first-boot setup), `0143` (the account service), `0139` (the lifecycle channel,
the session protocol), `0138` (the input service, keymaps), `../design/console-and-sessions.md` §3 to §5

## Context
`0149`'s 10c1: the login screen on the trusted path, with the keyboard layout on the status line and switchable there;
the session manager making a session with its home volume's root and starting echo in it; echo no longer started by the
supervisor. Chosen with the owner as it started: a boot with no account service (no disk) has a session with no user,
running echo, as the console did before; the layouts are US and UK; F2 cycles them.

## Decision
- **The session manager** (`src/services/session_manager`, `sessions`, 24 MiB) serves the session protocol, which
  the supervisor no longer does: `Start` (the user's name, the home's root, and a terminal connection) and
  `StartWithoutUser` (a terminal connection) make the session and start echo in it, its budget split off the session
  manager's, with a lifecycle channel and a ring for its log records from the events service, which it gives back once
  echo's ended; `List` and `End` are the supervisor's were, for the session's programs. One session until 10c2.
- **The terminal service's login screen**, after first-boot setup or when there are accounts: the name, then the password
  as dots; the account service's `OpenHome` with them, the password wiped once sent. The status line shows the keyboard
  layout and "F2: layout"; F2 moves to the next, which the input service types through from then (`seat`'s
  `SetLayout`). A wrong name or password says so, without saying which, and asks for both again; a rate limit says how
  long to wait. Once the home's opened, the terminal service makes a terminal connection for the session, a client of
  its own, and asks the session manager to start the session with it; the status line then shows the user. With no
  account service it asks for the session with no user at once.
- **echo** is given its session's terminal connection and, once someone's logged in, the home's root, whose entries it
  counts and says; it ends when its terminal does.
- **The keymaps** hold UTF-8 per key, for the UK layout's £ and ¬, and type the ISO keyboard's extra backslash key.
- **Room**: the process manager's `Load` takes up to 48 grants (from 32; its protocol's major version 3), as the
  supervisor's are 33 with the session manager's program; the supervisor's budget is 272 MiB.
- **Test**: on a fresh disk, setup, then the login screen: F2 changes the layout, a wrong password is refused, the right
  one makes the session, whose echo counts the home's entries and answers a line; no password is ever shown.

## Alternatives considered
- **The session manager dialing the terminal service for each session**: the terminal service would need to know which
  connection is whose; handing it the connection it made says so.
- **The terminal service serving a connector to the session's programs**: one more thing to serve, for one program.

## Consequences
- 10c2 makes that terminal connection one of a session's own screen, and the session protocol several sessions'.
- echo doesn't outlive its terminal service: started again, the terminal service has no sessions, and its login screen
  comes back.
