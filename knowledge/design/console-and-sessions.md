# The Console, Accounts and Sessions

Status: **proposed** 2026-10-24, for roadmap M10. Builds on `../decisions/0016` (users, the administrator, per-user
encryption), `0018` (the powerbox), `0042` (unlocking, the account database), `0043` (the trusted path) and
`services.md`. The choices still to make are at the end and in `../open-questions.md`, *Console and sessions*.

## 1. What Goes Wrong Elsewhere

| Problem | Where | SlopOS answer |
|---|---|---|
| Control sequences travel in the same byte stream as text, so printing a file or a log line can retitle the terminal, move the cursor or, through report sequences, type into the shell; programs guess what the terminal supports (terminfo) | VT100 descendants, every Unix terminal | A typed terminal protocol: text and operations are different messages, and text is never interpreted (§2) |
| The Escape key and escape sequences share bytes, so editors wait to tell them apart; paste is indistinguishable from typing (bracketed paste is a later patch) | Same | Input is typed key events; paste is its own event (§2) |
| A line discipline, job control, `SIGHUP`, `SIGWINCH`, process groups and controlling terminals in the kernel | Unix TTYs | A user-space terminal service; resizes, hangups and interrupts are messages (§2) |
| A program can draw a fake login or password prompt | Every console; Windows answered with Ctrl+Alt+Del | The secure attention key and the reserved status line (`0043`, §3) |
| Elevation through setuid programs that parse the whole environment as root (`sudo`'s Baron Samedit, CVE-2021-3156; `pkexec`'s PwnKit, CVE-2021-4034) | Unix | No setuid and no superuser: re-authentication on the trusted path grants one capability to one program (§5) |
| Authentication stacks loaded into every login program (PAM modules) | Linux | One account service; front ends hold only a connection to it (§4) |
| A permission prompt answers for the whole app, forever | Android, macOS | The powerbox grants one capability; persistent grants are stored links the user can list and revoke (§5) |

## 2. The Terminal Service

- **Terminals** are objects in the terminal service: each has a size, a scrollback and an owner (the session it
  belongs to). A program writes to one through a `Terminal` connection it was given; the shell gives each job its
  own, or the same one.
- **Output** is messages: `Text(runs)`, each run a UTF-8 string and a `Style` (colours from a palette or 24-bit,
  bold, italic, underline, a link target), and operations: `MoveCursor`, `Clear(region)`, `Scroll(region)`,
  `SetRegion` (a part of the screen the program redraws, for full-screen programs), `Bell`. Text is never parsed for
  control characters: a newline is a line break and anything else non-printable is shown as a visible substitute.
- **Input** is messages: `Key(code, modifiers, text)`, `Paste(text)`, `Resize(size)`, `Focus(bool)`, `Interrupt`
  (Ctrl-C, sent to the terminal's owner, §6 of `shell.md`), `HangUp`.
- **`Features`** says what the terminal can show (colours, styles, widths), in place of terminfo.
- **Widths** follow Unicode's East Asian Width and UAX #29 grapheme clusters, computed in the terminal service and in
  `std`'s client library from the same tables, so both agree on where the cursor is.
- **Line editing** is a `std` library in the program (history, completion, the shell's editor), not the service.
- **The VT adapter** turns the protocol into ECMA-48 bytes and back, for a byte-stream device: the serial line, the
  VT console of a remote SSH client (M14). It's the only place escape sequences exist, and it strips them from text.
- **Back ends:** the framebuffer (a text renderer with a PSF2 font, as the kernel's early console has) with the
  keyboard from the input service, and the serial line through the VT adapter.

## 3. The Trusted Path

As `0043` decided, made concrete:
- **The status line** is the screen's top row, drawn only by the terminal service: the session's user, the
  terminal's name, and the powerbox's prompts when one is pending. Programs' output can't reach it.
- **The secure attention key** is a key combination (proposed: Ctrl+Alt+Delete on a keyboard, a BREAK on a serial
  line) that **the input service** recognizes before anything else sees it. It always reaches the terminal service,
  which shows the pending powerbox prompt, or the lock and login screen when nothing is pending.
- **While a prompt is up**, keystrokes go to the powerbox only (`0018`).
- **No password is typed into a program's terminal.** Login and re-authentication happen on a screen the terminal
  service draws itself, reached through the secure attention key.

## 4. Accounts and Login

- **The account service** keeps the account database on its own unencrypted volume (`0042`), given to it by the
  system configuration. A record is an account's name, its Argon2id password hash, its public keys and FIDO2
  credentials, and its volume keys, wrapped once per credential.
- **Passwords:** Argon2id, with RFC 9106's second recommended parameters (64 MiB, 3 passes, 4 lanes) unless the
  configuration says otherwise, inside the account service's memory budget, so a flood of attempts can't exhaust
  memory. Attempts are rate-limited per account and per front end.
- **Key wrapping:** a key-encryption key is derived from the password (or a FIDO2 `hmac-secret`, `0042`) and wraps
  the volume key with the AEAD of `storage.md` §5.
- **First boot:** with no accounts, the console shows a setup screen that creates the administrator's account and
  volume, and nothing else is reachable until it's done.
- **Front ends** (console login now, SSH in M14) hold a connection to the account service and the terminal they
  serve, and nothing else.

## 5. Sessions and the Powerbox

- **The session manager**, on a successful login, creates the session's node in the ownership tree with its memory
  and CPU budgets (from the scheduler service and the configuration), asks the storage manager to unlock the home
  volume with the key the account service unwrapped (`0042`), and starts the session's first program (the shell)
  with the session's starting capabilities: the home `Dir`, the user's app list and configuration, a terminal, and a
  powerbox connection.
- **Several sessions** run at once (`0016`), switched between with the secure attention key's menu.
- **One powerbox per session**, holding only that session's grantable authority: a bug in it reaches one user's
  data, and it needs nothing from other sessions.
- **Runtime requests** (`0018`): `RequestFile(kind, purpose, suggested name)`, `RequestDirectory`,
  `RequestService(protocol)`, each answered by the user on the trusted path, through a chooser the terminal service
  draws over the session's `Dir`s, or refused.
- **Persistent grants** are stored links (`storage.md` §6): "this editor may reopen this file" is a link in the
  installation's data (`software.md` §6). The user's grants view lists every link they've issued, and deleting one
  revokes it.
- **Elevation:** a program that needs an administrator's capability asks the powerbox; the powerbox asks for the
  administrator's credentials on the trusted path and grants that one capability to that program, for as long as it
  holds it. There is no command that runs another command with everything.
- **Sharing between users** is a shared volume, a link in each member's namespace and a wrapped key for each
  (`0042`), set up through the storage manager by the volume's owner.

## 6. Open Questions

- The secure attention key's combination on each kind of console.
- Whether the shell or the terminal service owns the decision to send a job `Interrupt` (`shell.md` §6 assumes the
  terminal sends it to its owner, the shell).
- How a session ends (logout, a lost remote connection) and what its programs are told: `Stop` over each program's
  lifecycle channel (`shell.md` §6), then killing the session node after a grace period, as for jobs.
