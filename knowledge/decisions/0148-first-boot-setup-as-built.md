# 0148: 10b4, First-Boot Setup, as Built

Status: accepted
Date: 2026-11-02
Related: `0141` (10b's plan), `0143` (the account service), `0137` and `0138` (the terminal service, the secure attention
key's screen), `0147` (the input line), `../design/console-and-sessions.md` §3

## Context
`0141`'s 10b4: with no accounts, the terminal service's own screen asks for the administrator's name and password,
twice, has the account service make the account and its home volume, and shows the recovery code once. On the trusted
path, so nothing a program does can read what's typed there or draw over it.

## Decision
- **The supervisor** starts the account service before the terminal service, outside the recovery generation, and gives
  the terminal service a connector to it (`accounts_service`).
- **The terminal service** asks the account service how many accounts there are once it's dialed it, and with none,
  brings up setup: its own screen, as the secure attention key's is, which every key goes to and over which nothing a
  program writes is shown (the screen model keeps it, drawn again once setup's done). The secure attention key brings up
  nothing over it.
- **Its steps**: the name, checked as an account's name must be (`account_records.valid_name`); the password, checked
  against the rules and the common list (`account_records.password_problem`), each refusal said on the screen; the
  password again, which has to match; then `Create` sent, the password wiped from the terminal service's memory and the
  message that carried it, and "making the account" shown while Argon2id runs. The account service's own refusals come
  back as the same messages. The password shows as a dot per character.
- **The recovery code** is shown, in bold, until Enter, then wiped, and the program's screen drawn again. Setup logs each
  step, never what's typed.
- **Typing** draws only the fields' rows and the message's again, not the whole screen, so the serial line's queue keeps
  up; and what's typed on the serial line is decoded a slice at a time, each slice's keys taken before the next, so
  typing faster than events are held loses none of what the trusted path's screens take.
- **Test**: on a fresh disk, a name that can't be an account's and a common password refused, the administrator made,
  the recovery code shown, and Enter ending setup; the password never shown. `boot.py`'s `--console-input-after` can be
  given more than once, each `\w` waiting for the next, and it escapes what its output's encoding can't show.

## Alternatives considered
- **A program of its own for setup**: it would be one more thing on the trusted path to trust, where the terminal
  service already is.
- **Showing nothing as the password's typed**: dots say each key was taken, and only how many there were.

## Consequences
- 10b is done. 10c's login asks for a name and password on the same kind of screen, and opens the home volume with
  `OpenHome`.
- Every boot from a fresh disk stops at setup until someone makes the administrator; programs run meanwhile, and their
  output is shown once it's done.
