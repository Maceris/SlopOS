# 0069: The User-Mode Tests as Programs, as Built

Status: accepted
Date: 2026-10-24
Related: `0058` (the plan for M6), `0068` (typed entry points, which split this stage off), `0067` (the root task
and the process manager), `../../docs/specs/programs.md`, `../roadmap.md` M6

## Context
M6's fifth stage (6e). The kernel's user-mode tests (threads, system calls, ports, channels, memory, devices and
process control) ran code from the kernel's image, mapped into user address spaces, and checked from inside
the kernel that every object was back in its pool. `0058` planned to move them into programs once `std/os` could
write them, which it can since `0068`. A program can't see the kernel's pools, though, and the devices test
needed the kernel to start the test device.

## Decision
Chosen with the project's owner:
- **Leaks are checked through budgets, and by the kernel at the end**: each test charges what it makes to a
  child budget and checks it's back to nothing; the root task checks each test's whole budget is, once the test
  has ended; and once the root task ends, the kernel logs what's left in its pools, which must be only its own.
- **All seven move, with a little help from the kernel**: a `test_device` option for the devices test, and the
  threads test checks its own vector registers. The budgets test stays in the kernel: CPU budgets aren't objects
  a program can make yet.
- **One program per test**, in `src/tests/<name>`, which the root task runs with `test_program=<name>` on the
  kernel's command line.
- **The kernel's versions go**, and with them the tests' mapping of the kernel's code into user mode.

As built:
- **The tests** (`src/tests/test_syscalls`, `test_ports`, `test_memory`, `test_channels`, `test_control`,
  `test_threads`, `test_devices`) keep the kernel tests' checks, in the same order, with what each call gave
  compared with what it should have (`test_kit.check`); each says what worked in its debug log and ends with 0,
  or the number of the first check that failed. They share `src/test_kit`: threads of their own on stacks of
  their own (there's no thread support in the runtime yet), waits, and budgets.
- **Every test's entry is the same**, `(log, platform?, test_device?, manager?, program?, peer?)`, so the root task
  launches each with one `TestGrants` through the manager, and `system_config` checks they're the same.
  `manager` and `program`, a connection to the manager and the test's own module, let a test launch copies of
  itself where it needs other processes: `test_channels`' B, and `test_control`'s target and exiting process, each
  told its part, and reporting where its things are, through `peer`, a channel to the test. A copy is at its own
  random base, so it says where its functions and pages are rather than the test knowing.
- **The root task**: with `test_program=<name>` it starts the entropy service and the manager, then the test in
  place of the supervisor, waits for it to end, waits up to 2 s for its budget to be back to nothing, and ends with
  0 if both hold.
- **The kernel**: once the root task ends, it destroys the root task's subtree, waits 20 ticks for the grace period
  (`ROOT_END_TICKS`), then logs "objects left: only the kernel's own" if the pools hold only the root budget and
  the platform capability, or what's left, and stops. `test_device` grants the root task a `test_device` page
  (`src/test_device`: the controller's kind and registers, the line and its flags, as the firmware tables would
  say, and RAM the kernel owns), and runs the device while an IRQ for its line exists. `test_budgets` is
  `budgets_test.hsc`, mapping only its counter's pages; nothing maps the kernel's whole code any more.
- **Found on the way, fixed**: Limine reports the kernel and the modules loaded beside it as one entry, which
  the boot adapter made all `KernelImage`, read-only in the direct map. Nothing freed a module's frames until the
  root task's end started destroying what it owned, when freeing one beside the kernel faulted, on AArch64 where
  Limine put modules there. The adapter now splits the entry: the kernel's own pages, from its ELF's segments, are
  its image, and the rest `BootModule`.
- **Tightened on the way**: `test_memory` no longer expects the child budget's own slot to be charged when it's
  closed, which the kernel test only got by timing; it checks the parent got back at least the rest of the limit.

## Alternatives considered
- **Budgets only**: simpler, but a leak of something nothing is charged for would go unseen.
- **A test-only system call for the pools**: closest to the kernel tests, but a hole in the table for tests.
- **Only the tests that need no kernel help**: the devices and threads tests would have stayed in the kernel.
- **One program running every test**: fewer modules, but one failure could stop the rest, and each test couldn't
  get only its own grants.
- **Keeping the kernel versions for a while**: a cross-check, at the cost of two copies of every test.

## Consequences
- M6 is done: programs build and load, the root task starts the first services, a program's entry is its
  manifest, and the kernel's user-mode tests are programs like any.
- The tests are boot modules, so every boot with programs carries them, and the root task's grants count them.
- A new user-mode test is a program in `src/tests` with the shared entry, and a `program_test` in
  `tools/boot_tests.py`.
- `test_budgets` moves to a program once CPU budgets are objects.
