# 0143: 10b3, the Account Service, as Built

Status: accepted
Date: 2026-11-01
Related: `0141` (10b's plan), `0142` (volumes made at run time; its supervisor budget raised again here), `0042`
(unlocking), `0016` (users, the administrator), `../../docs/specs/programs.md`, `../../third_party/seclists`

## Context
`0141`'s 10b3: the account service, its volume, a record per account with an Argon2id hash at RFC 9106's second
parameters and the home volume's secret wrapped by the password and by the recovery code, NIST SP 800-63B's password
rules, rate limits, and the `accounts` protocol. Chosen with the owner as it started: the boot tests' machines get 512
MiB, so Argon2id keeps its 64 MiB there too; and the recovery code is Crockford base32 in groups.

## Decision
- **`account_records`** (`src/account_records`, unit-tested), what the service keeps and checks:
  - names: 1 to 32 bytes, a lowercase ASCII letter, then letters, digits, `-` or `_`;
  - passwords: at least 8 characters, counted as code points, at most 256 bytes, no composition rules, refused if
    they're among SecLists' 10,000 most common (the 2,087 of 8 characters or more, lowercased, sorted, searched by
    binary search; `third_party/seclists`) compared lowercased, or are the account's name ignoring ASCII case;
  - a record (192 bytes): the name, whether it's the administrator, when it was made, Argon2id's parameters (64 MiB,
    3 passes, 4 lanes) and salt, and the home volume's 256-bit secret sealed (ChaCha20-Poly1305, bound to the name) by
    the key Argon2id derives from the password, and again by a key BLAKE3 derives from the recovery code and a salt of
    its own. A wrong password is known by its seal not opening; nothing else of the password is kept;
  - the recovery code: 125 random bits, shown as 25 Crockford base32 characters in five groups of five, read back in
    any case, hyphens and spaces ignored, I and L as 1, O as 0.
- **The account service** (`src/services/account_service`, started by the supervisor when there's a disk, 72 MiB):
  - its records are files `<name>.account` on the `accounts` volume, a plain volume of the first SlopOS container,
    which it has the storage manager make (`CreateVolume`) the first time; each written to `<name>.new`, moved over
    the last, and synced;
  - each account's home volume is `home-<name>`, sealed with AES-256-GCM, its passphrase the record's secret, which
    goes nowhere but the storage manager and the volume server; `OpenHome` answers with the volume's root;
  - `Create` makes the first account only, the administrator, until 10c gives the administrator's session authority;
    it answers with the recovery code; `ChangePassword` takes the old password, `Recover` the recovery code;
  - a name that isn't an account's is checked against a record that opens nothing, so it takes as long as a wrong
    password, and both are answered `WrongCredentials`;
  - wrong attempts: from the third in a row for an account, or the fifth for a client, the next is heard only after a
    wait that doubles from a second, up to five minutes (`RateLimited`, with how long); a right one starts both counts
    again. They're counted in memory, for the 32 names most recently tried;
  - requests are served one at a time, so its budget holds one Argon2id's memory; each request's message is zeroed
    once it's handled, and so is the one carrying a home volume's secret to the storage manager.
- **Room**: the supervisor's budget goes to 240 MiB (from `0142`'s 160), for the account service's 72; the boot tests
  run QEMU with 512 MiB.
- **Test**: `test_accounts` on the kernel's command line has the supervisor, once everything has started, refuse a
  common password and a capitalized name, make the administrator, be refused a second account, be rate-limited after
  three wrong passwords, open the home volume and write a file there, replace the password with the recovery code
  typed in lowercase, be refused the old password and open the home volume with the new one, the file still there. It
  waits for each answer while handling what else arrives, since the account service reaches the storage manager
  through a connector the supervisor serves.

## Alternatives considered
- **Keeping a hash of the password beside the sealed secret**: a second thing to check, which the seal already is.
- **Argon2id for the recovery code too**: it's 125 random bits, which no guessing reaches; BLAKE3 is enough.
- **Counting wrong attempts on the volume**: a restart forgets them now; worth it once there's more than the trusted
  path to ask.
- **Unicode normalization of passwords** (NFKC, as SP 800-63B suggests): `std/unicode` has no normalization yet, so a
  password is compared byte for byte; typing it the same way on the same keymap gives the same bytes.

## Consequences
- 10b4's first-boot setup calls `Create` from the terminal service's own screen and shows the recovery code; 10c's
  login calls `OpenHome`.
- A disk boot starts one more service, and a fresh disk gets the accounts volume at its first boot.
