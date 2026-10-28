# 0091: Stored Links, as Built

Status: accepted
Date: 2026-10-27
Related: `0085` (the plan for M8), `0090` (encryption and snapshots), `0089` (the native filesystem as services), `0042`
(persistent grants and sharing), `0014` (server authorization), `../design/security.md` §8, `../design/storage.md` §6,
`../roadmap.md` M8

## Context
M8's last stage (8f, `0085`): links in a recipient's namespace to an object in another volume, listed and revoked by
the granter, which M10's persistent grants and shared volumes are made of (`0042`). Chosen with the project's owner:
- **Made from a connection**: whoever holds a `dir` connection to an object grants it, with no more than its own
  rights, and hands the grant to a directory in the recipient's volume, which keeps it as a link. Any program can share
  what it holds, as M10's powerbox needs; the storage manager doesn't take names for it.
- **Followed anywhere in a path**: `shared/docs/a.txt` opens through the link `shared`; `Remove` and `Rename` act on
  the link itself, and `List` shows it as a link.
- **Listed and revoked through a `dir` over the object**: the links issued for anything beneath it.
- **No re-sharing**: what's opened through a link can't be granted again, so every link is issued by someone holding
  the object directly, and the list a granter sees is complete.

## Decision
- **Records** (`src/slopfs/links.hsc`, format version 3): a link is an object of kind `Link` in the recipient's
  volume, named like any other, with a `Link` record naming the volume it leads into, by its container and ID, and the
  number that volume issued it under. The volume it leads into keeps an `Issued` record per number: the object, whether
  it may be written, when, and which volume holds the link; the next number is at 0. A link is only as good as its
  issued record, so deleting that revokes it; the issuing volume's ID is in each, so a clone's copies of its origin's
  records issue nothing. `walk` resolves a path to its end or to its first link and the rest; everything that doesn't
  follow links sees one as neither a file nor a directory (`IsALink`). Removing a link removes its record.
- **The protocols** (Hemera's `std/os/slop_os`): `dir` gains `Grant(path, write)`, giving a connection speaking the
  new `grant` protocol; `Link(path, grant)`; `Links(cursor)`, answering `Issued(number, path, write, created)`; and
  `Revoke(number)`. `files` gains `Kind.Link` and the errors `Revoked`, `Unavailable` (the volume a link leads into
  isn't open) and `IsALink` (a link where it isn't followed). `grant` has one request, `Claim`, answering the volume
  it's from and a ticket.
- **Making one**: the recipient's volume server claims the grant from its server, which makes a random ticket, and
  takes the claim to the storage manager on its own `links` connection (`src/protocols/links`). The storage manager,
  which knows which volume asks, has the granting volume's server issue a link to that volume (`IssueTo`, on the volume
  protocol) for the ticket's grant, durable before it answers, and the recipient's server makes the link with the
  number. Each grant makes one link.
- **Following one**: a request whose path reaches a link (`OpenFile`, `OpenReadOnlyFile`, `OpenDirectory`, and the
  `read_only_dir` opens) asks the storage manager to `Resolve` it, with the rest of the path and how it's opened; the
  storage manager has the volume it leads into open it (`OpenIssued`), which checks its issued record against the
  volume the storage manager vouches for and opens the object and the path beneath it, read only if that's all it was
  issued for (`ReadOnly` otherwise, so a read-only link to a directory is opened through a narrowed `dir`). The
  connection comes back to the client. A link leads only into a volume being served, unlocked, and never into its
  own; following one doesn't start or unlock a volume.
- **No waiting on the storage manager**: a volume server sends what it asks and goes on serving, its client's
  connection left unread until the answer comes back (answers come in the order asked); a grant's claim is read the
  same way. The storage manager waits on volume servers, as it did for `Unlock`; since none waits on it, two volumes
  linking to each other can't deadlock.
- **Linked connections**: what's opened through a link, and everything opened from it, is linked: it can't `Grant`,
  `Link`, or list or revoke links (`ReadOnly`), and a link beneath it isn't followed (`IsALink`), since that link is
  the volume owner's authority, not the holder's.
- **Listing and revoking**: `Links` on a `dir` that isn't linked lists what was issued for anything beneath it, with
  the path from it; `Revoke` deletes one. A link revoked opens nothing from its next open; connections opened through
  it before stay open.
- **Tests**: hosted (`src/slopfs/test/links_test.hsc`), links to a directory and a file in another volume, walked up to
  and no further, refused as files and directories to what doesn't follow them, listed as links; what was issued
  listed, revoked, kept across a mount, and a clone's copies issuing nothing; a link's record gone with it. Booted, the
  encrypted volume grants a directory to write and a file to read, which the system volume keeps as links, one in a
  directory of its own; through the system volume a file is written through the first link and read by the encrypted
  volume, both are read through their links, the file's link refuses writing and lists as a link; a directory opened
  through a link grants nothing and lists no links; the encrypted volume lists both, revokes the file's link, which
  then opens nothing (`Revoked`); a grant kept in its own volume is refused; and removing a link leaves its object.

## Alternatives considered
- **Links made by name through the storage manager**, as snapshots are: only whoever holds the storage manager could
  share, not a program sharing what it was given.
- **Following links only as a path's last name**: simpler for the volume server, but every client would walk paths
  itself.
- **Re-sharing, revoked together**: a chain of grants the granter couldn't see whole.
- **The grant as a bearer ticket from the start**: a ticket in the granter's hands is a secret to keep; a `grant`
  connection is a handle, and the ticket exists only between two servers and the storage manager, once.
- **The storage manager speaking on the grant itself**: any program can make a channel tagged `grant`, and the storage
  manager would wait on it; the recipient's volume server reads it without waiting.
- **Revoking open connections too**: the volume would have to find every connection opened through a link; a link is
  authority to open, as a `dir` handed over is.

## Consequences
- M8 is done. M10's grants view lists a user's issued links through their home volume's root, and its sharing is a
  shared volume, a link in each member's namespace, and a wrapped key.
- A volume must be open for its links to lead anywhere: M10's session manager unlocks the shared volumes a session
  needs.
- Issued records of objects that are gone stay until they're revoked; listing skips them.
