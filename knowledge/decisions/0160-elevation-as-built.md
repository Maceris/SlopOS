# 0160: 10d3, Elevation, as Built

Status: accepted
Date: 2026-11-02
Related: `0158` (the choices), `0157` and `0159` (the powerbox), `0141` to `0148` (accounts),
`../design/console-and-sessions.md` §4 and §5

## Context
`0158`'s 10d3: a program asks for an administrator's capability, the administrator's password is asked for on the
trusted path, always, and that one capability is granted; making another account is the first.

## Decision
- **The account service** serves `CreateBy`, the administrator's name and password with the new account: it checks
  them as a login's are, counted against the name and the client when they're wrong, and when the account isn't the
  administrator's (`WrongCredentials` either way, so which isn't said); then makes the account as it made the first,
  not an administrator, with its home volume and recovery code. `Create` still makes only the first.
- **The powerbox** takes `RequestAccount` with a purpose, sends an `Ask` of the new kind `Account`, and answers the
  program with `AccountMade` and the account's name once the trusted path answers `AccountMade`; or `Refused`.
- **The trusted path** (`src/services/terminal_service/elevation.hsc`): for such a request, the secure attention key
  opens the elevation screen, which runs on first-boot setup's steps with two before them: the administrator's name
  and password, then the new account's name and password, twice. Enter after the last sends `CreateBy`; a wrong
  administrator's name or password, or a name that's taken, starts again from the administrator's name; the recovery
  code is shown once, and Enter after it answers the powerbox. Escape refuses until the account's asked for. The
  passwords are wiped once sent, and nothing typed there reaches the program; the status line says an account is being
  made.
- **echo**'s "adduser" asks for an account and says its name.
- **Tests**: the boot test asks for an account, has a wrong administrator's password refused, makes bob's account with
  the right one, logs out, and logs bob in; no password shows on the console.

## Alternatives considered
- **The program given a connection that may `Create`**: it would type, or see, the new account's password.

## Consequences
- An administrator's capability is one act on the trusted path, not a connection the program keeps; more such acts
  (removing an account, changing the system's configuration) take the same path.
- The new account's recovery code is shown to whoever is at the console, for its owner.
