# 0112: 9c5, the Perf Baselines and Storage Faults, as Built

Status: accepted
Date: 2026-10-30
Related: `0107` (9c's plan), `0097` (Perf), `0096` (R4), `0104` (the robustness sweeps), `0085` and `0088` (the crash
states), `../design/lessons.md` §9.1

## Context
`0097` made Perf a track of numbers kept: benchmarks as boot tests with recorded baselines, failing on a regression
beyond a margin, with QEMU's `-icount` where it can give instruction counts. `0096`'s R4 asked for a faulty block
connection. Under it, slopfs and the FAT server must report a failed write to every `Sync` after it, never only the
first (fsyncgate). They must never return data a failed write should have changed. The crash-state tester gains failed
writes beside torn ones.

## Decision
- **Instructions gate, time is recorded** (with the project's owner): `tools/perf_tests.py` boots each architecture's
  benchmarks under `-icount shift=0,sleep=off`, where a guest nanosecond is an instruction and an idle guest's clock
  runs ahead, so a guest's clock readings are counts.
  - A count more than 10% above its baseline in `tools/perf_baselines.json` fails the run, for the kernel's four
    benchmarks, whose counts repeat within 2%. The disk boot's three wait on the disk, whose requests finish in the
    host's time even under `-icount`, and moved by 27% to 71% between two runs. So they're recorded and reported,
    but not held to a baseline.
  - Each boot is made again as usual, and its wall times are reported beside the counts, never failing anything.
  - `--update` records the counts as the baselines.
  - On x86-64, QEMU (11.1, the build this was made with) stops the guest under `-icount` with "Bad icount read",
    without the TSC deadline or the IOMMU too, so x86-64's numbers are only wall time for now, reported each run. The
    gate is AArch64's until x86-64 can be counted.
- **The benchmarks**, each a line `perf: <name> <nanoseconds>`:
  - `test_perf` measures the kernel's: an IPC round trip to a thread of its own through a channel's kernel path, each
    side woken through a port; a first touch of a page of anonymous memory; a thread made, ended and seen to end; and
    a copy of the program launched through the process manager and seen to end.
  - A boot from the image builder's disk gives the rest: a file made and synced on the system volume (the disk check),
    hello's start from the bundle store (the supervisor, from the launch to its process loaded), and boot to everything
    started (the supervisor, by the monotonic clock).
- **Failed writes are remembered** (R4):
  - slopfs already failed every commit after a failed data write. Now the volume also remembers the chunks failed
    writes were for, up to 32 and then every chunk, and refuses to read them (`DeviceError`), since the tree still
    points at what was there before. A later write of a chunk that succeeds makes it whole again, and `forget` clears
    them with what it forgets.
  - The FAT library goes through two helpers for its sectors. A failed write marks the volume failed, which every
    `Sync` after it reports in the FAT server, and remembers its sectors, which reads refuse until a whole write of
    them succeeds; a write of part of one needs what's there, and is refused too.
- **The faulty block connection**: the partition server, built with `robustness=on`, reads `faulty_block=<read|write|tear>:<n>`
  from the kernel's command line, which the storage manager now passes it (and the supervisor lets it). The nth read
  or write through its narrowed connections fails with `DeviceError` without reaching the disk; a torn one has its
  first half written and its answer turned into a failure. Without `robustness=on`, none of it is compiled in.
- **Tests**:
  - The FAT tests fail a write and check the file's sectors are refused, other files read, a partial rewrite is
    refused and a whole one reads, and the volume stays failed.
  - The crash-state tester fails a write, on a plain and a sealed volume, and checks that the chunk is refused, the
    other file reads, two commits after it fail, and the disk holds the last acknowledged commit once mounted again.
  - `boot_tests.py --robustness` builds its programs with `robustness=on` and sweeps `faulty_block` on both
    architectures: the first twelve writes, then some to the 96th, the first six reads and tears, then some to the
    48th. Every run must end as a failed allocation's may: the root task ending with nothing of anyone else's left,
    or the kernel halting, never a fault or a hang.

## Alternatives considered
- **Wall time with a loose margin**: catches only regressions large enough to stand out of a shared host's noise.
- **A per-file error state in slopfs**: a failed volume already fails every commit, so per-file states would only
  narrow the error, at the cost of keeping them across renames and links.

## Consequences
- 9c is done; 9d, generations and updates, is next.
- A change meant to move a benchmark's count records the new baseline with `--update` in the same commit.
