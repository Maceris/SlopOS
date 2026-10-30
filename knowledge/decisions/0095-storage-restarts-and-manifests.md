# 0095: Storage Servers Restarted, and Manifests Built

Status: accepted
Date: 2026-10-29
Related: `0086` and `0087` (the storage manager's servers), `0077` (restarts), `0044` (manifests), `0094` (the bundle
store)

## Context
Two things planned earlier and not built, found reading the decisions back: `0086` left restarting a partition server
that crashes to 8d, and `0087` a FAT server's, but the storage manager never watched what it started; and `0044` gave
the build a step extracting each program's manifest, which `0094`'s bundles were to carry, but nothing wrote one, so
bundles held a manifest of zeros.

## Decision
- **The storage manager watches every server it starts** from its launch, under a key per kind (partition servers by
  disk, FAT servers and container services by partition, volume servers by their place in `served`), and keeps each
  one's process and budget until it ends; then the budget's handle is closed, so what it had comes back, which it
  never did before.
  - **A partition server that ends** is started again at once, with its disk dialed again through the connector the
    storage manager now keeps, up to three times a minute (`0077`'s policy). What's served from its disk's partitions
    held connections it narrowed, so the FAT servers, container services and volume servers there are killed first.
    Its partitions keep their numbers.
  - **A FAT server, a container service or a volume server that ends** is let go: its ends are closed and its slot
    freed, and the next request for it starts another, as the first request did, also at most three times a minute. A
    container service takes its volume servers with it. A volume server's place in `served` is reused; an encrypted
    volume served again is locked until its passphrase is given again.
  - Clients of a server that ended find their connections closed and ask the storage manager again; nothing reconnects
    them for them.
- **The build writes each SlopOS program's manifest** (`src/build`'s `write_manifest`, a check that runs on every
  program target): the schema of its `main`'s type, `std`'s `schema.write`, beside the program as `<name>.manifest`.
  Hemera's `compiler.FunctionInfo` gained `type`, the function's own type, to give it. The store builder puts each
  manifest in the store as an object, which its bundle names, and which collection keeps with it.
- **Tests**: "starts a disk's partition server again when it's killed, and serves its volumes through the new one", on
  both architectures, from the disk: the storage manager is given the kernel's command line, and with
  `test_storage_restart` kills the first disk's partition server once it's listed its partitions, waits for it to be
  started again, and everything the disk boot checks then works through the new one. `test_store` checks that hello's
  bundle's manifest is the schema hash of `hello.main`'s type as the supervisor works it out at run time.

## Alternatives considered
- **Restarting FAT servers, container services and volume servers at once**, like partition servers: their clients
  would still have to reconnect, and an encrypted volume couldn't be served again without its passphrase.
- **Manifests embedded in each program**, as a section its startup code fills: no file beside it, but every program
  would carry it, and the loader would have to find it.

## Consequences
- A crash in the storage stack no longer stays down; a FAT, container or volume server's clients reconnect through the
  storage manager. Killing those servers' dependents when a partition server ends isn't tested yet, as the test kills
  it before any exist.
- The supervisor's own connection to the system volume, and the events service's and the bundle store's directories,
  aren't reconnected when the system volume's server ends; they need connectors of their own, or the supervisor
  watching for it.
- Manifests exist for the shell (M11) and the config store (9c) to read.
