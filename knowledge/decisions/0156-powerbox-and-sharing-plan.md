# 0156: The Plan for 10d, the Powerbox and Sharing

Status: accepted
Date: 2026-11-02
Related: `0136` (M10's plan), `0018` (granting authority), `0042` (persistent grants and sharing), `0043` (the trusted
path), `0091` (stored links), `0149` to `0155` (10c), `../design/console-and-sessions.md` §3 and §5

## Context
`0136`'s 10d: a powerbox per session, `RequestFile`, `RequestDirectory` and `RequestService` answered on the trusted
path through a chooser, persistent grants as stored links the user lists and revokes, elevation by re-authentication,
and shared volumes between users.

## Decision
Chosen with the owner as 10d started:
- **Four parts**, each with an as-built record, on both architectures:
  - **10d1** the powerbox, one per session, started by the session manager, each of the session's programs given a
    connection of its own to it, labeled with the program's name; `RequestFile` and `RequestDirectory` answered
    through a chooser on the trusted path.
  - **10d2** persistent grants: a request may ask to keep what it's given, a stored link in the installation's data;
    the user's grants view on the trusted path lists the links they've issued, and revokes them.
  - **10d3** elevation: a program asks the powerbox for an administrator's capability, the administrator's credentials
    are asked for on the trusted path, and that one capability is granted to that program; making another account is
    the first such capability, which 10d4 needs.
  - **10d4** shared volumes: a volume its owner shares with another user, a link in each member's namespace and a
    wrapped key for each (`0042`), set up through the storage manager.
- **echo gains commands** that ask the powerbox for things, as the stand-in for the shell (`0136`).
- **The chooser** lists the directory it's in, arrows moving and Enter opening a directory or choosing a file, and
  typing filters the list, or names a new file; Escape refuses.
- **A pending request** is shown on the status line, which programs can't draw on, naming the program that asks and
  what for; the secure attention key opens the chooser, so a program can't put up a look-alike one.

## Alternatives considered
- **Shared volumes later**: the design has them in M10, and 10d3's second account makes them testable.
- **A new requester app**: echo already stands where the shell goes.
- **The chooser opening at once**: quicker, but a program could draw a copy of it before the real one.

## Consequences
- `RequestService` waits for services a session's programs may be granted; 10d1's protocol has room for it.
- The terminal service grows a chooser and, in 10d3, a re-authentication screen; both are the trusted path's.
