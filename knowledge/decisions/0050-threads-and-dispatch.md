# 0050: Threads, Vector State and the Dispatcher

Status: accepted
Date: 2026-10-22
Related: `0023` (cheap threads), `0026` (carrier register), `0037` (scheduling), `../design/threads.md`,
`../design/scheduling.md`, `../roadmap.md` M4

## Context
M4 builds what `0023` and `0037` decided: threads with no kernel stack of their own, run by a fixed
dispatcher with CPU budgets. Building it settled several choices the designs left open.

## Decision
- **A thread** is a slab object under 1 KiB: its saved `RegisterFrame`, its address space, its budget,
  and its place on a run queue. Its vector state is a separate heap block, about 1 KiB. Every entry from
  user mode copies the frame into the CPU's current thread, and every return goes through
  `return_to_user` from a thread's frame.
- **Vector state is saved and restored eagerly**, at each switch between threads and at no other time,
  since the kernel never uses vector registers: XSAVE's standard format after a 64-byte header naming
  its state components, with XSAVEOPT where the CPU has it. XCR0 changes only when a thread with other
  components (AVX-512, opt-in) is restored.
- **No FSGSBASE.** With it, user code could set its own `fs` and `gs` bases, which every switch would
  have to save. Hemera code has no thread-local storage (its carrier is `r14`), and the kernel reads its
  `gs` base through the MSR, so the bases stay as the kernel sets them.
- **Entries clear `RFLAGS.AC`.** An interrupt gate leaves it as user code set it, which with SMAP lets
  the kernel reach user memory; Hemera's entry stubs now clear it with the flags (`clac` faults without
  SMAP). `SYSCALL` already clears it through `FMASK`.
- **Each CPU has its own run queue**: a list per level, the background band at 0 and priority `p` at
  `p + 1`, with a bit per non-empty level. A CPU with nothing to run takes the highest-level thread from
  another CPU's queue. A thread made ready above what its CPU runs gets a reschedule IPI there.
- **Accounting is at ticks** (100 Hz on every CPU) and switches, as `../design/scheduling.md` §2 allows:
  a budget can overrun by up to a tick. Refills follow the sporadic-server rule, up to 8 per budget, the
  latest one taking any more.
- **A thread's level is worked out when it's queued.** A thread whose budget comes back while it waits
  in the background band moves up once it next runs, within a tick, since the band is round robin.
- **Address-space tags** are PCIDs, handed out from a bitmap, 0 kept for the kernel's own table. Without
  PCIDs every space has tag 0, and every switch flushes.

## Alternatives considered
- **Lazy vector-state switching:** the LazyFP attack (CVE-2018-3665), and the kernel doesn't use the
  registers anyway, so eager costs nothing extra.
- **Saving `fs` and `gs` bases per thread:** costs every switch, for nothing Hemera code uses.
- **One global run queue:** simpler, but every switch on every CPU would take its lock.
- **Tickless accounting with exact deadlines:** precise budgets, at the cost of reprogramming the timer at
  every switch; the design accepts a tick's overrun.

## Consequences
- Blocking, exiting and destroying threads, `thread_create` as a system call, and continuations for
  long operations come with system calls (M5).
- Before programs can be loaded (M6), tests run kernel code that needs nothing else (`user_counter`)
  in user mode, mapped from the kernel image's frames into a user address space.
- Idle CPUs keep ticking; a tickless idle is left for when power matters.
