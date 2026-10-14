# 0042: Unlocking Volumes, Sharing, and the Account Database

Status: accepted
Date: 2026-10-13
Related: `0013` (threat model), `0016` (users and encryption), `0018` (granting authority),
`0043` (remote login)

## Context
`0016` gives each user a volume encrypted with a key that only their credentials unwrap. That left
three questions: how key-based remote logins and background work unlock a volume when no password
is typed, what happens when a member leaves a shared volume, and what protects the account service's
own volume, which must be readable before anyone logs in.

The threat model (`0013`) settles much of it: physical theft of the disk is in scope for
confidentiality; reading keys from a running machine's memory (cold boot), encrypting metadata, and
an administrator replacing system software are not.

## Decision
- **A user's volume is unlocked from their first login until shutdown**, as iOS and Android do
  after first unlock. The storage service keeps the volume key in memory until the machine shuts
  down. Key-based remote logins and background work use the unlocked volume.
- **Before the first login after boot:**
  - The volume key is also wrapped for each of the user's public keys. Remote login over the native
    protocol (`0043`) sends the wrapped key to the client, which unwraps it and sends it back over
    the encrypted connection: the same exposure as typing a password.
  - FIDO2 security keys with `hmac-secret` derive a secret that unwraps the volume key directly.
  - An SSH key login can't unwrap anything. Its session starts with the volume locked, until the
    user enters their password once.
- **Background work with no session** runs only while the volume is unlocked. A per-user, opt-in key
  held by the machine may come later, documented as weaker against disk theft.
- **Persistent grants and sharing** are `../design/security.md` §8 as written: stored links in the
  recipient's namespace, and shared volumes whose key is wrapped for each member.
- **Removing a member from a shared volume** deletes their link and wrapped key, and rotates the
  volume to a new key generation for everything written afterwards. Existing data isn't
  re-encrypted by default, since the member could have copied it while they had access. Full
  re-encryption stays available as an explicit action.
- **The account database is not encrypted.** It holds only password hashes from a slow function
  (Argon2id), public keys, and volume keys that are themselves wrapped. Offline guessing against it
  is the same attack as against a wrapped volume key, so encryption adds nothing against disk
  theft. Account names are visible, which is metadata (`0013`).

## Alternatives considered
- **Locking volumes when the last session ends:** stronger against an attacker with the running
  machine, which the threat model leaves out, and it breaks key-based logins and background work.
- **Re-encrypting a shared volume on every removal:** expensive, and protects nothing the removed
  member couldn't have copied.
- **A machine key for the account database:** the machine would need to read it unattended at boot,
  so the key would be on the same disk, or need a TPM and measured boot, which `0013` doesn't plan.

## Consequences
- The storage service holds every logged-in-since-boot user's volume key in memory. Its memory is
  part of the trusted computing base.
- Volumes record key generations, and readers try the generation each extent was written with.
- Hemera's `std` needs cryptography (`0043`, `../hemera-feedback.md`).
