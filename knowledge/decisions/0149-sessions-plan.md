# 0149: The Plan for 10c, Login and Sessions

Status: accepted
Date: 2026-11-02
Related: `0136` (M10's plan), `0016` (users, several sessions), `0042` (unlocking), `0043` (the trusted path), `0139`
(the lifecycle channel, the session protocol), `0143` (the account service), `0148` (first-boot setup),
`../design/console-and-sessions.md` §3 to §5

## Context
`0136`'s 10c: console login on the trusted path with the layout on the status line, the session manager (the session's
node and budgets, the home volume unlocked, the first program started with its starting capabilities), several sessions
switched through the secure attention key's menu, ending a session, `Locale`, and idle installations asked to save and
stop under memory pressure. There's no shell yet (M11), and the supervisor serves the session protocol for the console's
programs (`0139`).

## Decision
Chosen with the owner as 10c started:
- **A session's first program** is echo, standing in for the shell: started by the session manager with the session's
  terminal, its home directory and its starting capabilities. The console runs no program before anyone logs in. The
  shell, when it comes, takes echo's place as the configured first program.
- **A session manager**, a new service the supervisor starts, makes and ends sessions, and serves the session protocol
  the supervisor serves now, so the secure attention key's screen asks it.
- **The secure attention key's screen**, once someone's logged in, offers: switching to another session, logging in
  another, locking the console (the session goes on; its user's password brings it back), and logging out (`Stop` over
  each of the session's programs' lifecycle channels, then its node killed after a grace period).
- **A screen per session in the terminal service**: a screen model and clients for each session, the active one shown,
  the others' output kept for when they're switched back to; a session's programs get a terminal connection for their
  own session only.

Decided here, in four parts:
- **10c1** console login and one session: the login screen, on the trusted path as setup's is, with the keyboard layout
  on the status line and switchable there; the account service's `OpenHome`; the session manager making the session
  (its memory and CPU budgets, its home volume's root) and starting echo in it with a terminal connection and its home
  directory; echo no longer started by the supervisor.
- **10c2** several sessions: the terminal service's screens per session; the secure attention key's menu with switch,
  log in another, lock and log out; a session ended.
- **10c3** `Locale`: a context value from the user's configuration, read only by human-facing formatters.
- **10c4** idle installations asked to save and stop under memory pressure.

## Alternatives considered
- **A new small session shell**: much of it thrown away when the shell comes.
- **The supervisor running sessions**: it would grow further and hold every session's authority.
- **A terminal service per session**: stronger isolation between sessions, but the trusted path split across processes.

## Consequences
- `../roadmap.md`'s 10c gains its parts; 10d's powerbox is per session, made by the session manager.
