# 0154: 10c4a, Installations in Sessions, as Built

Status: accepted
Date: 2026-11-02
Related: `0153` (10c4's plan), `0150` and `0151` (the session manager), `0152` (users' values in the config store),
`0113` and `0117` (installations), `../design/software.md` §6

## Context
`0153`'s first part: the system's installations run in each session, by the session manager, instead of once for the
whole system by the supervisor.

## Decision
- **The supervisor** keeps only the system's list: at the session manager's start it writes the build's list to the
  config store's value "installations" of owner "system" if none is there yet, and gives the session manager a
  connection of its own to that value, one to the bundle store, the system volume's `apps` directory, and the boot's
  command line. It no longer starts, updates or uninstalls installations.
- **The session manager**, at each session's start, opens the session's apps directory (its home's `apps`, made if it
  isn't there, or another connection to the system volume's for a session without a home) before echo is given the
  home, then starts each installation on the list after echo: its bundle from the store (the one it names, or the boot
  root's of its program's name), refused unless its manifest is the installations' entry; its data directory
  `apps/<name>` in the session's apps directory; its settings, the config store's value "settings" of owner
  `user:<user>:<name>` (`user:-:<name>` for no user); and its budget split off the session manager's, with a
  lifecycle channel, the session's locale and a log ring, as echo is. Updating is stopping it and starting it from the
  list's new entry; uninstalling stops it, takes it off the list, deletes its data directory in that session's apps
  directory and forgets its settings.
- **The counter** keeps running after it counts, until it's asked to stop, as an installation does.
- **The config store**: an owner may be a user's, `user:` and an account's name (letters, digits, `-` and `_`, or `-`),
  with `:` and an installation's name after it, up to 72 bytes; the session manager's connection may `Forget` users'
  owners, as it does when an installation is removed.
- **Budgets**: the session manager's is 40 MiB (4 sessions of echo, 2 MiB, and the counter, 4), the supervisor's
  304 MiB.
- **Tests**: `test_installations` is the session manager's, in the first session with a user: once the counter has
  counted 1 (read from its data directory, since its runtime answers pings before `main` does anything), an update to
  hello's bundle is refused, it's updated to counter_next's, which counts 2, uninstalled, and installed again, counting
  1. The boot test logs in first; a boot from a disk runs no installation until someone logs in.

## Fixed along the way
- **Users' values never reached the store**: its names were letters, digits and `_`, so `user:admin` was refused, and
  `0152`'s locale setting fell back to the layout's suggestion at every login; its test passed because both logins
  used the same layout.
- **A program's place used again** was refused its end's watch, `KeyInUse`: a `.Once` binding keeps its key once it's
  fired, so the session manager unbinds it first, as the supervisor does. Its process, budget and lifecycle handles
  are closed when it ends.
- **echo's greeting** counts the home's `apps` directory: "Your home directory has 1 entry."

## Alternatives considered
- **The list as a grant, a copy at the session manager's start**: an update or uninstall it makes would be lost at its
  restart.
- **Pinging the counter to learn it has counted**: the runtime answers on a thread of its own from before `main`.

## Consequences
- Each session runs its own copy of every installation, each counting in its user's home; two sessions of one user
  share its data directory.
- An installation's list is still the system's; a user's own list comes with what installs apps for them.
- `os.launch` leaks the child budget when a step after making it fails (Hemera's std), which a launch refused for its
  key made visible.
