# 0194: Faster Boot Tests, Planned

Status: accepted in part (2026-11-21): T1 to T3 now, then T4 and T5 with the owner; T6 waits on what they measure
Date: 2026-11-21
Related: `0144` (the parallel runner), `0146` (boot tests steady under load, `test_settle`), `0192` (15g: the builds
made faster, the suite from 22.8 to 13.8 minutes), `0193` (M16's suites), `0186` (the KVM path)

## Context
The boot suite takes 14 to 19 minutes: 292 boots, about 85 minutes of test time added up, 8 at once. Each is a cold
boot in QEMU without hardware acceleration (TCG; WHPX stays off for the Linux VM's KVM, `0186`), UEFI, the kernel,
every service, and often first-boot setup and a login, before the test's own few seconds. The host's 24 logical
processors are about 80% busy throughout, nearly all of it QEMU, so the suite is bound by what it emulates: it gets
faster by emulating less, not by running more at once.

## What was measured (2026-11-21)
Times from M16's second suite run, and single boots timed line by line from their serial output:

| Group | Tests | Test time | Each |
|---|---|---|---|
| Boot disk, first-boot setup typed (x86-64, AArch64) | 76 | 1990 s | 26 s |
| Boot disk, no setup | 46 | 1096 s | 24 s |
| The kernel and its modules (test programs, `test_program=`) | 86 | 761 s | 9 s |
| The kernel alone | 45 | 224 s | 5 s |
| Reboots, network, GUI, and the rest | 35 | 1093 s | 31 s |

A typical boot-disk test on x86-64, 10.8 s: QEMU and boot.py starting 1.4 s; UEFI 1.1 s; the bootloader and the
kernel 0.3 s; the root task until "the system is healthy" 6.4 s; the test and the shutdown 1.7 s. With first-boot
setup and a login, about 3 s more each on x86-64 and 1.3 s each on AArch64.
- **AArch64's firmware waits 5 s for a boot menu** (edk2's default timeout on the virt machine) in every boot:
  `-boot menu=on,splash-time=0` takes an AArch64 boot from 6.4 s to 1.3 s, and every AArch64 test about 5 s faster.
  x86-64's OVMF doesn't wait.
- **Starting the services**, 5 to 6.4 s: the container's mount 1.8 to 2.3 s, though it reads a few blocks; each
  program the supervisor loads from the bundle store 0.3 to 0.9 s; a session's programs after a login about 2 s. Not
  profiled yet.
- **Argon2id's 64 MiB**, once to make an account and again for each login, elevation or SSH password: most of the
  3 s each on x86-64.
- **`test_settle`**: a `test_services` boot that isn't shut down when it's done stays up for its settle time (`0146`)
  after what it checks is seen; the console's tests, the snapshots' (45 s), the network's and TLS's.
- No difference: AArch64's pointer authentication (`pauth-impdef=on`), x86-64's IOMMU (`--no-iommu`), typing (it waits
  on what's shown, polled every 50 ms).

## Proposal
In stages, each measured by a suite run, and kept only if the suite stays steady (`0146`):
- **T1, the firmware's wait**: `-boot menu=on,splash-time=0` for AArch64 (~730 s of test time, ~14%).
- **T2, ending when done**: a test whose checks are all lines it expects ends once they're all seen, its machine shut
  down as a user would (the power button, so the root task's leak checks and exit code still count), rather than when
  `test_settle` runs out. Tests whose length is what's tested (a watchdog kept from resetting the machine, the chaos
  test) keep theirs. ~250 s.
- **T3, profiling the boot**: the kernel's clock in the boot log's lines, a test run's phases timed from them, and the
  container's mount, the bundle store's loads and a session's start profiled and made faster. Every boot-disk test
  waits ~6 s on these, and a real machine would too, if 20 times less. Unknown until profiled; perhaps 300 to 700 s.
- **T4, disks made once**: the disk each test needs made once a run (per architecture and kind), and each test given a
  copy-on-write overlay (qcow2) rather than its own 133 MB copy. Tests that don't test first-boot setup start from a
  disk where it's been done, so they don't type it or pay its Argon2id. The setup's own tests keep doing it. ~300 s.
- **T5, Argon2id's cost in tests**: a test build's accounts hashed with small parameters, a record keeping them as it
  does now, so checking needs nothing else; one test keeps the real ones. Never a command-line word or anything a
  release image can take. ~300 to 500 s, partly what T4 saves.
- **T6, snapshots** (the largest and most invasive): each group's machine booted once to where its tests start (the
  system healthy, or logged in), saved (`savevm`), and each test started from it (`-loadvm`). That needs a group's
  tests to share the kernel's command line and devices, so what a test does moves from the command line to what it's
  given after (typed, or a file on the disk); and every test of a group starts with the same randomness, keys and
  addresses. A prototype on one group first. Up to 1500 to 2000 s on top of the rest.
- **Not proposed**: more boots at once (the host's busy); several test programs in one boot (`test_program=a,b`),
  ~130 s, and a failure would take the others with it.

T1, T2, T4 and T5 together are about a third of the test time: the suite in about 9 to 10 minutes; T3 and T6 may take
it under 5.

## Chosen with the owner (2026-11-21)
- T1 to T3 first, then T4 and T5 checked with the owner before they're built.
- T5 as proposed: smaller Argon2id parameters in test builds only, one test keeping the real ones.
- T6 waits until T1 to T5 are measured.

## Open questions
- Groups that don't need the network or SSH could start without them (less to load), but the system under test would
  then differ by group. Wanted, or only after T3 shows what loading costs?

## As Built: T1 to T3
- **T1**: AArch64's QEMU boots with `-boot menu=on,splash-time=0`; edk2 no longer waits 5 s in every boot.
- **T2**: `boot.py --end-when-done` presses the power button once the supervisor's started all its services, every
  expected line but a run's end's is in, the console's typed its lines and shown what it's to show. The root task
  shuts down as for the console's shutdown, ending with 0, its leak checks run as before. Eleven tests take it: the
  console's, the snapshots' (55 to 63 s became 36 s), the recovery generation's. The network's tests keep their
  settle: their peers' checks on this machine don't say when they're done.
- **T3, the profiler**: `profile_boot` on the kernel's command line samples each tick of each CPU, user code with its
  frame pointers' chain or idle, with its time and CPU, into a ring of 16384, written to the serial line once the root
  task's ended. Kernel code runs with interrupts off, so its time shows at the system call it returns to. The root task
  and the process manager, given the command line now, log where each image went (`profile: name at base`).
  `tools/profile_boot.py` boots tests with it, names the samples by function through the programs' ELF symbols, and
  with `--timeline` says each quarter second. A boot test checks the samples and the images' lines.
- **T3, what it found**: the container's mount read 3011 blocks, 25 of them distinct, as every walk of a tree starts
  from its root and slopfs kept no node it had read; each read 16 KiB and checked its BLAKE3. The mount took 2 s of a
  9 s boot, nearly all of it waiting on the disk. Reading a file a page at a time read and checked its 64 KiB chunk
  for each page, and its 3 nodes too: the bundle store's pages, so every program's loading.
- **T3, what's done**: slopfs keeps the last 16 nodes a Nodes read and checked (`NODE_CACHE`) and the last 2 chunks a
  volume read and checked (`CHUNK_CACHE`), each found again only by the same pointer: address, birth, seal, the tree
  and its owner, and whether it's encrypted. What's at an address so sealed never changes, as a changed node or chunk is
  written elsewhere and sealed anew, so a kept copy is what reading again would give, checked once. About 390 KiB, in
  the container service's 4 MiB and the volume server's 6 MiB. A typical boot-disk test's boot went from 9.4 s to
  4.6 s, the system healthy at 1.75 s rather than 6.5 s.
- **What's left**: a test with first-boot setup and a login spends ~5.5 s of its 9 in Argon2id, the account service's
  and the volume server's, at the account's making and the login (T5). The FAT server's free count, seen at first, was
  its reads waiting behind the mount's.
- **The suite, 2026-11-21**: 294 of 294 passed in 9.8 minutes (14 to 19 before), 62 minutes of test time added up (85
  before). One flaky: the SSH client's test hung once among the others after its command had run and the server had
  closed, and passed alone; the client's end, left to look into.

## As Built: T5
- **`test_kdf`**, a build setting, off by default and never a release's: with it on, a password goes through Argon2id
  with 256 KiB and 1 pass rather than 64 MiB and 3 (`account_records.PASSWORD_ARGON2`, 4 lanes still), and a volume
  made at run time wraps its key with 64 KiB and 1 pass rather than 4 MiB and 3 (`slopfs.MADE_PASSPHRASE`). What's made
  keeps its parameters, as everything Argon2id wraps does, so nothing reads them as the build's. `DEFAULT_PASSPHRASE`,
  for volumes made on the host, is as it was.
- **The boot tests build with it**, and `tools/profile_boot.py` too. The account test boots x86-64's programs built
  without it (`WITH_REAL_KDF`), for the account service's budget holding Argon2id's whole 64 MiB, as a release's must.
- A test with first-boot setup and a login: its boot from 11.4 s to 5.9 s.
- **The suite, 2026-11-21**: 294 of 294 passed in 8.5 minutes, 54.8 minutes of test time added up. Two flaky:
  - The trace test's timeline missed the services started last, on a busy host, as they hadn't run yet when it was
    read, and the run ended, its settle out, before its ping was traced. The supervisor reads the trace again until
    every running service has run, up to 5 s, and the test ends when its lines are in (`--end-when-done`, a settle of
    60 s).
  - The editor's test: once edit had quit and the shell had said its result, the shell's prompt didn't come back, as
    in the SSH client's test; the shell's end of a job, likely, left with the SSH client's for that work.
- **T4 not built yet**: with T5, a first-boot setup costs a typed form and one quick Argon2id, about 1 s; what's
  left of T4 is the disk made for each test, ~1 s each, for the owner to weigh.

## Chosen with the owner, after T5 (2026-11-21)
T4 dropped: measured after T5, a first-boot setup took 0.2 s and a disk 1.0 s, under 5% of the test time, and a disk
depends on its test's command line. The explicit waits cleared next, then T6.

## As Built: the explicit waits
- **Every test_services test ends when it's done** (`boot_tests.boot_arguments` gives it `--end-when-done`), unless it
  ends another way (`OWN_ENDINGS`: the console's shutdown or restart, the power button, reboots, the disk checked after,
  the display's tests) or its length is what's tested (`KEEPS_SETTLE`: the watchdog kept from resetting the machine,
  and the watchdog left to reset it).
- **The network peers say when they're done**: each check against the machine (port 7's echo, TLS's, OpenSSH's) is
  noted once it's ended, and `--end-when-done` waits for every one whose lines the serial output has.
- **boot.py's fixed sleeps** wait on what they stood for: the power button is pressed once the supervisor's started its
  services, not a second after its line; a new keyboard's next line is typed once the status line stops asking for
  its code; the console's and the display's screens are taken until what's to be drawn is; the GUI's typing test
  types once test_gui says its window has the keyboard's focus; the display test's click follows its move on the
  tablet's queue.
- **The suite, 2026-11-21**: 294 of 294 passed in 6.4 minutes, 41.3 minutes of test time added up (54.8 after T5), none
  flaky.
