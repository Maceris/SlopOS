# Threads

Status: **decided** (`../decisions/0023-cheap-threads.md`); remaining questions at the end.

Requirement: threads should be cheap. Creating one should take little memory and little
time, so programs can use them freely instead of reaching for thread pools by reflex.

## Where Thread Cost Comes From (in a typical OS)

Using Linux as the reference point (rough, order-of-magnitude figures):

| Cost | Typical Linux | Why it exists |
|---|---|---|
| Kernel stack per thread | 16 KiB | Kernel code can block anywhere, so every thread needs its own kernel stack |
| Kernel thread object | several KiB (`task_struct`) | Decades of accumulated fields |
| User stack | 8 MiB *reserved* by default, committed on touch | One size for everyone |
| FPU/SIMD save area | ~1 KiB (AVX) up to ~2.5 KiB+ (AVX-512) | Must save vector registers on context switch |
| Thread-local storage | Copy TLS image per thread | Thread-local globals (`errno`, etc.) |
| Creation path | `mmap` stack + guard, `clone` with many flags, TLS setup, signal mask | Generality and POSIX semantics |

## How SlopOS Makes Each One Cheap

### 1. No per-thread kernel stack — **[decided]**
Use **one kernel stack per CPU** (seL4's model). The kernel never blocks in the middle
of a system call; an operation either completes, or the thread's state records what it's
waiting for and the kernel returns to the scheduler. Microkernel operations are short and
bounded, so this is natural. **Saves ~16 KiB per thread**, the single biggest item.

Cost: kernel code must be written in "run to completion or record a continuation" style,
and long kernel operations need explicit preemption points. A good stress test of
Hemera's control flow (`defer`, tagged unions for continuation states).

### 2. Small thread control block — **[decided]**
Target **≤ 1 KiB** of kernel memory for the TCB excluding vector state: saved general
registers, scheduling fields, IPC state, capability to its address space and its context.
Allocated from a slab, so creation is a free-list pop.

### 3. Vector state sized to what we enable — **[decided]**
With x86-64-v3, user space gets AVX2. The XSAVE area for x87 + SSE + AVX is roughly
1 KiB. AVX-512 (not part of v3) would more than double it per thread. **Proposal: only
enable the state components in `XCR0` that v3 guarantees**, at least initially, keeping
the save area ~1 KiB. AVX-512 (and later AMX) is a per-process opt-in (`0023`).

Eager save/restore (not lazy switching — lazy FPU switching was the LazyFP
vulnerability, CVE-2018-3665). Use `XSAVEOPT`/`XSAVEC` so unused components cost little.

### 4. User space owns user stacks — **[decided]**
The kernel doesn't allocate user stacks. Thread creation takes a stack pointer the caller
already set up, so the runtime picks the size: a few KiB for a small worker, megabytes
for deep recursion. The standard runtime reserves address space and commits pages on
demand with a guard page below.

### 5. No thread-local storage needed — **[decided]**, Hemera synergy
Hemera has no mutable globals, so there are no thread-local globals (no `errno`, no TLS
image to copy). Per-thread state is the **context**, which is passed in a register on
every call. Starting a thread = setting the instruction pointer, stack pointer, and the
context register. **TLS setup cost disappears.**

### 6. One simple creation call — **[decided]**
```
thread_create :: fn(
    space: AddressSpaceCap,
    entry: rawptr,
    stack: rawptr,
    context: rawptr,
    memory: MemoryBudget,     // kernel memory for the TCB comes from the caller's budget
    cpu: CpuBudget?,          // proposed: null = inherit the creator's binding
) -> Result[Thread, ThreadError]
```
No `clone` flag matrix, no signal masks (no signals). The TCB memory is charged to
the caller's memory capability (seL4 retype / Genode model), so creation is both cheap
and accounted for (see `../problems-and-directions.md` §11).

### 7. Even cheaper: fibers on top — **[explore]**
Hemera's `std/fiber` copies stack frames out on yield and back on resume, so a
suspended fiber costs only the stack it actually used. Combined with async completion
queues (submit I/O, yield, completion resumes the fiber), most "many concurrent tasks"
workloads need only one kernel thread per core.

## Target Numbers (aspirational)

| | Target |
|---|---|
| Kernel memory per thread | ≤ ~2 KiB (TCB + vector state) |
| Minimum user stack | 4 KiB (one page), runtime's choice |
| Creation | a single syscall, no page-table changes, no memory zeroing beyond the TCB |

These are goals to measure against once something runs, not claims.

## Open Questions
- Long kernel operations (destroying a large subtree, large unmaps): proposed split in
  `kernel.md` §2, "Long operations".
- Scheduler policy: proposed in `scheduling.md`.
- Does the kernel need to know a thread's stack bounds at all (for diagnostics), or only user space?
