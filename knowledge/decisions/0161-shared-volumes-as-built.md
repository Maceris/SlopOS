# 0161: 10d4, Shared Volumes, as Built

Status: accepted
Date: 2026-11-02
Related: `0158` (the choices), `0042` (sharing), `0090` (key generations), `0091` and `0159` (stored links),
`0141` (account records), `../design/security.md` §8, `../design/console-and-sessions.md` §5

## Context
`0158`'s 10d4: volumes an owner shares with other users, their key sealed to each member's public key, shared from the
secure attention key's screen, with members taken out again and the volume moved to a new key generation.

## Decision
- **Key pairs**: an account record (version 2, 272 bytes) has an X25519 public key and its secret key sealed by the home
  volume's secret, as the password's and the recovery code's keys seal that secret, so either opens it. New accounts
  get one when they're made; a version 1 record is read as before and gets its pair at its account's next login.
- **Sealing a share**: the share's random 32-byte secret is sealed to a member's public key with an ephemeral X25519
  key: the agreement, with both public keys, through BLAKE3, is the key for ChaCha20-Poly1305 over the secret, bound to
  the share's name. Only the member's secret key opens it, so they needn't be logged in.
- **Records**: `<name>.share` on the accounts volume names the share and up to 8 members, the owner first, each with
  the secret sealed to them. The volume is `shared-<name>` in the system container, sealed by the secret.
- **Accounts protocol**: `Share` and `Unshare`, with the owner's name, the share's and a member's, asked by the trusted
  path for the session's user; each answers `Shared` with a grant of the volume's root, to write, for the owner's link,
  or `NoSuchAccount` for a member with no account or no key pair yet, `AlreadyExists`, `NameRefused` or `Refused` (not
  the owner's, or not opened since the service started).
- **Making and joining**: the first `Share` of a name makes the volume and its record; each adds a member. Opening a
  home opens its account's shares too: the secret key unsealed, each share's secret with it and kept in memory, its
  volume opened, and `shared/<name>` linked in the home unless the link there opens.
- **Taking a member out**: `Unshare` drops their sealed secret, revokes every link the volume has issued, and starts its
  next key generation (`Rotate`); the owner's link is made again by the trusted path, the other members' at their next
  login.
- **The trusted path** (`src/services/terminal_service/share_form.hsc`): H on the secure attention key's screen opens
  the share form for the session's user: the volume's name, then a member's, Enter shares it with them, Delete takes
  them out, Escape goes back; the grant answered is linked as `shared/<name>` in the owner's home, through the
  connection the grants view uses.
- **Tests**: the boot test has bob's account made, shares `team` with bob, which links it in the owner's home; bob,
  logged in to another session, joins it, his home showing two entries; back in the owner's session, bob's taken out,
  both links revoked and the volume's next key generation started.

## Limits found
- **A new key generation protects less than `0042` meant against a member who's left**: a generation's key is wrapped by
  the volume key, which the share's secret unwraps, and that doesn't change; someone who kept the secret, and gets the
  disk, unwraps the new generation's key too. Against them, what protects new data is the revoked link and their sealed
  secret being gone, while the system runs. Giving a volume a new volume key, wrapped by a new secret sealed to the
  remaining members, is what would close it; it's left for later, recorded in `../open-questions.md`.
- A member taken out keeps their dangling link in their home until it's removed; it opens nothing.
- A share's secret is kept from when it's first opened until the service ends, so the owner can manage it only once
  they've logged in since.

## Alternatives considered
- **Joining a share at once, while the member is logged in**: the account service doesn't hold their home; they join at
  their next login.

## Consequences
- M10 is done: the console, accounts, sessions, the powerbox, kept grants, elevation and shared volumes.
