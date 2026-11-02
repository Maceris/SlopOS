# 0158: The Rest of 10d, Chosen

Status: accepted
Date: 2026-11-02
Related: `0156` (10d's plan), `0157` (the powerbox), `0091` (stored links), `0042` (sharing),
`../design/security.md` §8, `../design/console-and-sessions.md` §5

## Context
`0156` split 10d into four parts. Before 10d2 to 10d4, the owner chose how each goes, since stored links can't lead
into their own volume (`0091`), while a kept grant is usually a file in the same home as the program that keeps it, and
a shared volume's key has to be wrapped for a member who isn't logged in.

## Decision
- **10d2, kept grants**: stored links, with the volume server allowing a link into its own volume; the grants view is
  the home's list of the links it issued, and revoking deletes the issued record. A request may ask to be kept; the
  chooser offers "keep for next time", off until the user ticks it (Tab), and only what's ticked is kept.
- **10d3, elevation**: the first capability is making another account. A program asks the powerbox; the trusted path
  asks for the administrator's password, always, even in the administrator's own session, then the new account's name
  and password, so no password is typed into the program.
- **10d4, shared volumes**: each account has a Curve25519 key pair, its private key wrapped as the volume key is (under
  the password's key and the recovery code's); a shared volume's key is sealed to each member's public key, so a member
  needn't be logged in. The owner shares from the secure attention key's screen: a new shared volume and a member, each
  given a link `shared/<name>` in their home. Removing a member deletes their link and wrapped key, and the volume
  writes under a new key generation from then on (`0042`).
- **Progress**: a full suite and a commit per part, both repositories pushed once M10 is done.

## Alternatives considered
- **Kept grants as the powerbox's own records**: a second mechanism beside stored links, and a grants view that sees
  only the powerbox's.
- **Kept by default**: a program would decide what persists.
- **A share accepted at the member's next login, or only while both are logged in**: weaker, or of little use.
- **Sharing through a program**: the trusted path is where the owner's intent is shown and confirmed.

## Consequences
- A same-volume link is resolved by the volume itself, without the storage manager.
- Accounts made before 10d4 get their key pair at their next login, when their password unwraps what it needs.
