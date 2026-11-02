# 0159: 10d2, Kept Grants, as Built

Status: accepted
Date: 2026-11-02
Related: `0158` (the choices), `0157` (the powerbox), `0091` (stored links), `../design/security.md` §8,
`../design/console-and-sessions.md` §5

## Context
`0158`'s 10d2: grants a program may keep for next time, as stored links, ticked by the user, listed and revoked from
the trusted path.

## Decision
- **Links into their own volume**: the storage manager no longer refuses a grant claimed by the volume it's from, or a
  link that leads back into the volume holding it; the volume server answers its own `IssueTo` and `OpenIssued` while
  it waits on the storage manager, as it answers any other volume's. disk_check links a system-volume file into the
  system volume and opens it through the link.
- **Asking to keep**: `RequestFile` and `RequestDirectory` carry a key, empty to not ask; `prompt.Ask` says whether
  keeping was asked for, and `prompt.Choice` whether the user ticked "keep for next time", which the chooser shows for
  such a request, off until Tab ticks it.
- **Keeping**: the powerbox grants what was chosen again on the home (read only unless writing was asked for), and links
  the grant at `grants/<program>/<key>` in the home, in place of one there before. `Reopen(key, kind, write)` opens that
  link as asked, without the user; a revoked or missing one is `Refused`. A key is letters, digits, `-` and `_`.
- **The grants view**: G on the secure attention key's screen lists the links the session's home has issued, what each
  reaches and whether it may write; Delete revokes the one chosen; Escape goes back. The terminal service reads the
  home through a connection of its own, made with the session (another connection to the root it gives the session
  manager), closed at logout.
- **echo**'s "save" asks to keep its file as "notes", and "reopen" reopens it.
- **Tests**: the boot test saves a line with "keep" ticked, reopens it without the chooser, revokes it in the grants
  view, and reopen then gets nothing.

## Alternatives considered
- **The grants view listing `grants/` beneath the home**: that's where the powerbox keeps its links, but what the home
  issued is the whole list, including links other volumes hold, as shared volumes will.

## Consequences
- The grants view shows what a link reaches, not which program holds it: the issued record names the volume that holds
  the link, not where in it.
- A revoked link stays in `grants/<program>/` until the program keeps another under its key.
