# 0141: The Plan for 10b, Accounts

Status: accepted
Date: 2026-11-01
Related: `0136` (M10's plan), `0042` (unlocking, the account database), `0016` (users, the administrator), `0123`
(`Secret[T]` left to 10b), `0089` and `0090` (the container service and volume servers, sealed volumes),
`../design/console-and-sessions.md` §4

## Context
`0136`'s 10b: the account service on its own unencrypted volume, records with Argon2id hashes (RFC 9106's second
parameters, inside its budget, attempts rate-limited) and wrapped volume keys, NIST SP 800-63B's password rules,
`Secret[T]` with Hemera's `#secret` extended (`0123`), first-boot setup creating the administrator, and a recovery code.
SlopOS can't create a volume at run time yet: the image builder makes the system volume, and the container service
mustn't hold what opens a sealed one (`0089`).

## Decision
Chosen with the owner as 10b started:
- **`#secret`, extended in Hemera** rather than a `Secret[T]`: nothing holding a secret can become an `any` (a secret,
  a struct with a secret field, an array of them, or a pointer to one), which is what formatting and logging take, so
  passing one there is a compile error; a `#secret` struct's type information says so, and the formatter writes
  `<secret>` for one that reaches it anyway. Wiping on free was there already.
- **Common passwords**: SecLists' 10,000 most common (MIT), embedded and searched as a sorted table.
- **The accounts volume** is made at first boot, unencrypted, in the system container, when the account service asks
  the storage manager for it.
- **Volumes made at run time**: the storage manager gains `CreateVolume`. A plain volume is made by the container
  service; a sealed one by a volume server started for it, which makes the volume's key, wraps it, and gives the
  container service only the sealed record, as `0089` keeps it.

Decided here, in four parts:
- **10b1** Hemera's `#secret` rules above.
- **10b2** volumes made at run time, plain and sealed.
- **10b3** the account service: its volume, a record per account (its name, an Argon2id hash with RFC 9106's second
  parameters, 64 MiB, 3 passes, 4 lanes, in a budget sized for one at a time, and its home volume's secret wrapped by a
  key from the password and again by one from the recovery code), the password rules (at least 8 characters, no
  composition rules, none of the common list, not the account's name), attempts rate-limited per account and per
  client, and the `accounts` protocol.
- **10b4** first-boot setup on the trusted path: with no accounts, the terminal service's own screen asks for the
  administrator's name and password, twice, has the account service make the account and its home volume, and shows
  the recovery code once.

## Alternatives considered
- **A `Secret[T]` wrapper in `std`**: a second way to say what `#secret` says.
- **Runtime-only `<secret>`**: a secret reaching a log would be caught only by what it prints.
- **The image builder making the accounts volume**: every way of making a disk would need it.
- **The home volume made at first login (10c)**: setup would make an account with nothing to unlock.
- **The container service making sealed volumes**: it would hold what opens one, for a moment.

## Consequences
- `../roadmap.md`'s 10b gains its parts; 10c unlocks the home volume this makes, with the key the account service
  unwraps.
