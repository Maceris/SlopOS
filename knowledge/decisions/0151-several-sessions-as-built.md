# 0151: 10c2, Several Sessions, as Built

Status: accepted
Date: 2026-11-02
Related: `0149` (10c's plan), `0150` (console login and one session), `0138` (the secure attention key's screen),
`0147` (the input line), `../design/console-and-sessions.md` §5

## Context
`0149`'s 10c2: several sessions, a screen each in the terminal service, the secure attention key's menu with switching,
logging in another, locking and logging out, and a session ended.

## Decision
- **Views**: the terminal service keeps a view per session, up to 4: its screen model, its input's owner and the line
  that owner's editing, and whose session it is. One is shown, the active one. Each client is a session's, the one
  whose terminal connection it is, and what it writes goes to its session's view, sent to the serial line and drawn on
  the framebuffer only if that's the one shown; a client in none, as hello's is, writes to the active one. Input goes to
  the active view's owner. The view in use is an index into the views, reached through `view(service)`, so nothing
  stores a pointer into the service.
- **The secure attention key's screen** says whose session it is, and, once someone's logged in and there's an account
  service, offers: **S** switches to the next session; **N** logs in another, on a new view's login screen, where Esc
  goes back to the session it was started from; **L** locks the console, its screen asking for the session's user's
  password, which the account service checks by opening the home volume, closed again at once, with the same rate
  limits; **O** logs out, the session manager ending the session's programs, the session's connections closed and its
  view let go, then the next session shown, or the login screen if there's none.
- **The session manager** keeps up to 4 sessions, and up to 16 programs among them: `Start` and `StartWithoutUser`
  answer with the session's number, `List` takes one, and `EndSession` asks every program of a session to stop, ends
  those that don't, and lets the session go.
- **Room**: the terminal service's budget goes to 4 MiB, for its views; at 2 MiB its log records were dropped, which
  the events service reported as its ring filling.
- **Test**: the administrator logged in, a second session of theirs logged in from the secure attention key's screen,
  the first switched back to, the console locked and unlocked, and the first logged out, the second shown; each
  session's echo answering what's typed in it. `boot.py`'s waits look at what the console showed after the last wait,
  so the same line can be waited for again.

## Alternatives considered
- **A pointer to the view in use**, stored in the service: every function on the way would need its parameter marked
  `#escaping`.
- **A list of sessions to choose from with Up and Down**: the screen's Up and Down choose a program already; S going
  round is enough for a few sessions.

## Consequences
- Locking is the console's: while it's locked nothing else is reachable, and the secure attention key brings up nothing
  over the lock screen.
- The runtime counts any record it couldn't write as one its ring had no room for, a failed allocation among them.
