# 0126: 9f3, Generations That Change Only Services, Applied Live, as Built

Status: accepted
Date: 2026-10-31
Related: `0123` (9f's plan), `0116` (the update service), `0093` (restarts), `0077` (connectors),
`../design/lessons.md` §2.3

## Context
`0123`: a generation that changes only services applies live, the supervisor restarting each service whose bundle
changed from its new bundle; one that changes the kernel or the boot set waits for the next boot, and nothing reboots
without the user.

## Decision
- **Which generations are live**: one the update service installs whose kernel, boot set (each file's name and hash),
  command line and KASLR are the booted generation's, so it differs only in its store root, that is in services'
  bundles. Installing it, after a healthy boot, the update service answers the supervisor's `Booted` with `Live`, its
  number and store root (`update.LiveOf`). Any other waits for the next boot, as before.
- **The supervisor applies it**: the new store root is its own from then on; each running service started from the
  store whose bundle under the new root names another program than under the old is started again, its cached program
  dropped first, through the restarts 9a built, so its clients redial through their connectors. Then it tells the
  update service the new generation booted, healthy if every service it restarted came back: made permanent, or rolled
  back for the next boot. Drivers and the boot set aren't restarted; a generation changing them isn't live.
- **The test's second bundle**: hello built again with the build's setting `hello_build=next` as `hello_next.elf`, which
  says "the next build" first; `boot.py --stage-next-hello` stages generation 2 with a store root whose hello is it.
  `boot.py` leaves `hello_next.elf` out of everything else.
- **Tests**: a disk booted once with that generation staged: installed, applied live, hello started again from its new
  bundle and saying so, and made permanent, without a reboot. The test of a staged generation booted next has its
  command line one word longer, so it isn't one that's applied live.

## Alternatives considered
- **Asking the user before restarting**: nothing a restart loses that a crash wouldn't; asking waits for M11's shell.

## Consequences
- An update of services from elsewhere (M13) applies without a reboot; one of the kernel or the boot set, or of a
  substitution (`0125`), takes the next boot.
- With 9f, M9 and its follow-ups are done; B and Perf's stages are next, before M10.
