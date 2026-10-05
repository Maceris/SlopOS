# 0023: Cheap Threads: One Kernel Stack per CPU, Small TCBs, User-Owned Stacks, No TLS

Status: accepted
Date: 2026-10-04
Amended by: `0026` (carrier register and stack-limit checks at thread start; items 5 and 6, and the stack-probe consequence)

## Context
`../design/threads.md` set the requirement that threads be cheap in memory and creation
time, and listed six leanings. They interact with other decisions: TCB memory is charged to
a memory budget (`0011`), and a blocked thread can't hold kernel object pointers across a
quiescent point (`0008`).

## Decision
1. **One kernel stack per CPU, not per thread.** The kernel never blocks in the middle of an
   operation. An operation either completes, or the thread's state records what it waits for
   (a continuation, as a tagged union) and the CPU returns to the scheduler. Long operations
   have explicit preemption points.
2. **Small thread control block:** target ≤ 1 KiB excluding vector state, allocated from the
   thread pool and charged to the creator's memory budget (`0011`).
3. **Vector state sized to what's enabled.** `XCR0` enables only the v3 state components
   (x87, SSE, AVX) by default. Save and restore are eager, never lazy (LazyFP,
   CVE-2018-3665), using `XSAVEC`/`XSAVEOPT`.
4. **AVX-512 (and later AMX) is a per-process opt-in**, requested at process creation and
   available only if `CpuFeatures` reports it (`0019`). Opted-in threads get the larger save
   area, charged to their budget. The kernel switches `XCR0` at context switch only when it
   moves between an opted-in and a non-opted-in thread. AMX can use `XFD` instead.
5. **User space owns user stacks.** Thread creation takes a stack pointer the caller set up.
   The kernel doesn't allocate, size or track user stacks.
6. **No thread-local storage.** Per-thread state is Hemera's `context`, passed in a register.
   Starting a thread sets the instruction pointer, stack pointer and context register.
7. **One simple creation call:**
   ```
   thread_create :: fn(
       space: AddressSpace,
       entry: rawptr,
       stack: rawptr,
       context: rawptr,
       memory: MemoryBudget,     // TCB (and vector state) charged here (0011)
       cpu: CpuBudget?,          // proposed: null = inherit the creator's current binding
   ) -> Result[Thread, ThreadError]
   ```
   No flag matrix and no signal masks (there are no signals). Whether `cpu` is a parameter is
   decided with scheduling (`../design/scheduling.md`).

## Alternatives considered
- **Per-thread kernel stacks:** easier kernel code (block anywhere), at about 16 KiB per
  thread, and kernel code that can block anywhere is harder to bound.
- **AVX-512 always enabled when present:** more than doubles every thread's save area for a
  feature few programs use, and on some CPUs AVX-512 use lowers clock speeds.
- **AVX-512 never:** gives up real performance for the programs that want it.

## Consequences
- Kernel code is written in run-to-completion style. Preemption points, and long operations
  such as destroying a large subtree, are designed in `../design/kernel.md`.
- Since a kernel entry never leaves its CPU, the CPU's per-CPU block can be bound into the
  kernel's `context` at entry (`../design/kernel.md`, "Per-CPU state").
- Syscall interception stops only at syscall entry and exit, where the thread's whole
  state is its saved user registers (`../design/kernel.md`).
- `std`'s runtime decides stack sizes and guard pages. Large frames need stack probes so a
  guard page can't be jumped over (`../design/system-abi.md`).
- A future thread-local feature in Hemera would add a cost to every SlopOS thread
  (`../hemera-feedback.md`).
