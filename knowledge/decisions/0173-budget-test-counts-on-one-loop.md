# 0173: The Budget Test Counts on One Loop

Status: accepted
Date: 2026-11-03
Related: `0050` (CPU budgets in the scheduler), `0093` (`relevel`), `0099` (`test_budgets` as a program)

## Context
`test_budgets` (`0099`) failed every time on AArch64 only, with "the pair counted 27 percent of the counts, the first 91
percent of theirs" (35 to 65 allowed). It started with a change to Hemera's `std` that only gathered `os.launch`'s grants
in a heap array, and passed again once they were gathered in a fixed array on the stack. Since only the launcher's
timing seemed to change, it looked like a fairness bug in the scheduler: round robin within a budget, refills, or
`relevel`.

It wasn't. A trace of every scheduling decision on one CPU, with the failing build and the passing one, gave the same
schedule in both: the pair's two threads ran 22 and 20 ticks of a second, the rival 59 (21, 20 and 59 passing). The
scheduler split the CPU as it should. The counts didn't, because the two threads didn't count at the same speed:
- The copy's own thread called `counter`, and the compiler inlined it into `main`. The thread it started ran `counter`
  itself, the out-of-line copy, at the address `thread_create` was given. So the two counted with different copies of
  the loop.
- `counter`'s loop is four instructions. The `std` change moved code by a few hundred bytes, putting the out-of-line loop
  at `0x24ff8`–`0x25007`, across a 4 KiB page boundary; with the stack array it's at `0x24cf4`, inside one page. Under
  QEMU's TCG the loop that straddles a page counted at about a tenth of the speed of the other. TCG ends a translation
  block at a guest page boundary and doesn't chain direct jumps between pages, so each pass looks up its next block.
  That's how TCG works; we measured the slowdown, not the mechanism.

So `std` didn't change the launcher's timing in a way that mattered. It changed the copies' code, since the copies are the
same program as the launcher. x86-64 passed only because its layout put no loop across a page.

## Decision
- **Every counter in `test_budgets` is a thread started at `counter`**: the pair's two, and the rival's one. Each copy's
  own thread then sleeps for good on a port, so it takes none of its budget. All three count with the same instructions
  at the same address, so however fast an emulator runs that loop, they run it at the same rate, and the counts are
  proportional to the CPU time each was given.
- **The scheduler is unchanged.** No kernel fix: the trace showed nothing to fix.

## Alternatives considered
- **Fixing the scheduler**, as first suspected. There was no fault to fix: the same ticks went to the same threads in
  the passing and failing builds.
- **Measuring CPU time instead of counts**, through the kernel's per-thread `run_time`. That would be the most direct
  measure, but there's no system call that gives it yet, and adding one to the ABI for a test isn't worth it now. It
  would also stop the test from checking that a counting thread really ran.
- **Keeping `counter` out of a page boundary**, by aligning it. That only fixes this one way a loop's speed depends on
  where it is, under one emulator. Hemera has no directive for a function's alignment, or for not inlining one, either.
- **Wider bounds.** The first thread's 91% isn't noise; no bound that still tests fairness would allow it.

## Consequences
- The test checks what it says it checks, wherever the linker puts `counter`.
- A benchmark-like test under QEMU's TCG should count only with one loop at one address. How fast code runs there
  depends on where it is, so counts from different copies of a loop, or from different loops, aren't comparable.
- The trace that showed this (a log line per scheduling of a thread on a limited budget, in `schedule`) was taken out
  again. It's quick to add back if a budget's split looks wrong again: it shows each tick's thread, level, and the
  budget's time left, debt and refills.
