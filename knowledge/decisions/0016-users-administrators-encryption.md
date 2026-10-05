# 0016: Multiple Users, a Limited Administrator, and Per-User Encryption

Status: accepted
Date: 2026-10-02

## Context
SlopOS supports several users on one machine (`0013`: users attacking each other is in
scope). Someone has to manage the system and the accounts, but in a capability system that
doesn't need to mean "can do anything". This also has to work with simultaneous sessions
and remote login.

## Decision
**Users and sessions:**
- The kernel has no notion of a user. A user's running work is a **session**: a node in
  the ownership tree (`0008`, `0012`) holding that user's starting capabilities.
- **Simultaneous sessions** (several users, or one user several times) and **remote login**
  are designed in from the start.
- **Authentication** supports passwords and key- or token-based credentials. Remote login
  in particular should work with keys.

**The administrator is a role defined by which capabilities it holds, with limits:**
- *Can:* change the system configuration, create and delete accounts, delete a user's data
  along with the account, and move a user's data (to another disk, say).
- *Cannot:* read another user's data.
- An administrator is an ordinary account whose session is given capabilities to the
  config store, account management and storage volume management. There is no superuser
  bypass anywhere.

**Per-user encryption at rest:**
- Each user's storage is a separate volume encrypted with its own random volume key. The
  key is stored only *wrapped* (encrypted) by keys derived from that user's credentials,
  so it can be unwrapped only by logging in as that user.
- Volume management (delete, move, resize, quotas) works on the encrypted volume as an
  opaque unit. That's how the administrator can delete or migrate a user's data without
  being able to read it.
- **Raw block access is rarely granted.** Only the storage service holds the `block`
  capabilities for disks. Anything else needing raw blocks (a disk-imaging or recovery
  tool) gets them only by explicit system configuration.

## Alternatives considered
- **A superuser who can do anything (Unix `root`):** what the whole design is avoiding.
- **Whole-disk encryption only:** protects a stolen disk but not users from each other or
  from the administrator.
- **No encryption, access control in the storage service only:** protects users from each
  other while the system is running, but anyone with the disk, or a raw-block capability,
  reads everything.

## Consequences
- **Key-based login can't unlock an encrypted volume by itself.** A password can be turned
  into a key that unwraps the volume key; verifying a signature (SSH-style public-key login)
  produces no secret. Logging in remotely with a key therefore needs one of: the volume
  already unlocked by another session, a credential that can decrypt (the client unwraps the
  key), or the user typing a password once. Open question.
- The same issue affects a user's background work (scheduled tasks, a mail fetcher) while
  they aren't logged in. Open question.
- Sharing between users needs a shared volume whose key is wrapped for each member, plus a
  way for a grant to survive reboots. Proposed in `../design/security.md` and still open.
- Protection from the administrator is against reading data, not against replacing system
  software (`0013`).
- The storage service sees plaintext while a volume is unlocked, so it is in the trusted
  computing base.
- Which services hold the account database, verify credentials and create sessions is
  proposed in `../design/services.md`.
