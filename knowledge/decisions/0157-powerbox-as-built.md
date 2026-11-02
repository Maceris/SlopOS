# 0157: 10d1, the Powerbox, as Built

Status: accepted
Date: 2026-11-02
Related: `0156` (10d's plan), `0018` (granting authority), `0043` (the trusted path), `0150` and `0151` (sessions),
`../design/console-and-sessions.md` §3 and §5

## Context
`0156`'s first part: a powerbox per session, `RequestFile` and `RequestDirectory` answered through a chooser on the
trusted path, and echo asking for things as the shell will.

## Decision
- **Two protocols**: `powerbox`, a program's to its session's powerbox (`RequestFile` with a purpose, a suggested name
  and whether it would write; `RequestDirectory` with a purpose and whether it would write; and `Serve`, the session
  manager's own, to serve another program under its name), answered with a connection (`GrantedFile`,
  `GrantedReadOnlyFile`, `GrantedDirectory`, `GrantedReadOnlyDirectory`), `Refused` or `Busy`; and `prompt`, the
  powerbox's to the trusted path, one `Ask` with the requester's name, the purpose, the suggestion, the kind, whether
  it would write, and the home read only, answered `Chosen` (a path beneath the home, and whether it's a new file) or
  `Refused`.
- **The powerbox** (`src/services/powerbox_service`) runs in each session with a user: the session manager loads it
  from the bundle store, its manifest checked, before echo, with another connection to the home, the prompt connection
  the terminal service made for the session (in `SessionStart`), and a connection of the session manager's own. Each
  program started after is given a connection the powerbox serves under the program's name, so the user is told which
  program asks; a program can't name itself, since only the session manager's connection may `Serve`. It holds one
  request at a time, opens what's chosen on the home (read only unless writing was asked for; a new file only for one
  to write), and answers the program. The session manager's budget is 48 MiB, the supervisor's 320 MiB.
- **The trusted path** (`src/services/terminal_service/chooser.hsc`): each session's view keeps its prompt connection
  and the request waiting on it. The status line names the program and what it asks for; the secure attention key opens
  the chooser instead of its menu. The chooser lists the directory it's in from the home given, read only: Up and Down
  move, Enter opens a directory or chooses, typing narrows the list to names with what's typed in them, a file to write
  is offered as a new file of the typed name when nothing has it, the suggested name is typed to begin with, and Escape
  refuses. A directory is chosen with "this directory" at the top of its list. The answer goes back on the prompt
  connection, and logging out drops what's waiting.
- **echo** asks with "open" (a file to read, whose first line it shows), "save" and text (a file to write, notes.txt
  suggested) and "list" (a directory to read, whose entries it names).
- **The system configuration** records that the session manager serves `Powerbox` connections, as the supervisor and
  the storage manager serve theirs, so echo's entry passes the check that every channel it takes has a server.
- **Tests**: the boot test logs in, saves a line in a new notes.txt, opens it narrowed by typing, lists the home, and
  has a request refused.

## Fixed along the way
- **Input in larger bursts**: the terminal service sent every event waiting in one `Input`, which a burst of about 30
  key events made too big for the client's connection's ring (`TooBig`), so the burst was never delivered. It now sends
  as many as fit, halving until they do, and keeps the rest for the next `Read`.
- **A message built in one statement**: `os.begin[T](&out)^ = .Variant(os.append(&out, ...))` appends before `begin`
  lays the message out, which makes it invalid; `begin`'s pointer is taken first, as the rest of the code does.

## Alternatives considered
- **The chooser listing through the powerbox**: the terminal service would ask the powerbox for each listing; giving it
  the home read only for the request's length is simpler, and it's the trusted path's anyway.
- **A powerbox for the session with no user**: it has no home to choose from.

## Consequences
- `RequestService` waits for services a session's programs may be granted.
- Installations aren't given a powerbox connection yet: their entry takes only their data and settings.
- 10d2 keeps what's granted as stored links, which a request will ask for.
