# 0026: Carrier Register and Stack-Limit Checks at Thread Start (Amends 0023)

Status: accepted
Date: 2026-10-05
Amends: `0023` (items 5 and 6, and its consequence about stack probes)

## Context
Hemera's fiber and calling-convention redesign (Hemera commit "Redesign fibers and calling
convention, re-introduce pointers to the stack with some restrictions", 2026-10-04) changed
three things `0023` relied on:

- **A carrier register.** Every OS thread running Hemera code has a runtime-owned
  `CarrierBlock` (`base/runtime/carrier.hsc`), and a pointer to it is kept in a register that
  nothing else uses (`r14` on x86-64, `x28` on AArch64). It holds the current stack limit,
  the current fiber and scheduler hooks, `foreign_depth`, `no_yield_depth` and the carrier's
  index. Fiber switches never save or restore it.
- **A stack-limit check in every prologue.** Every function (except small leaves) compares
  the stack pointer, or where its frame will end, against `carrier.stack_limit` before
  building its frame, and calls `morestack` when there isn't room. On fibers, `morestack`
  runs the function on a new segment. On plain threads, running out is a deterministic
  error, not a fault on a guard page.
- **Fibers no longer copy frames.** A fiber is one allocation of about 1.4 KiB (struct, root
  context, first 1 KiB stack segment) plus 1 KiB segments as needed. Frames never move, and
  resuming re-enters frames with real calls, so fibers work under CET shadow stacks, GCS,
  PAC and IBT/BTI.

`0023` said starting a thread sets only the instruction pointer, stack pointer and context
register, and that `std` protects user stacks with guard pages, which needs stack probes in
large frames.

## Decision
1. **The kernel knows nothing about carrier blocks.** A thread's first instruction is an
   entry stub in its own program's `std`, which runs before any Hemera function (it must not
   use the prologue check). It sets up the thread's `CarrierBlock` (in memory `std`
   prepared), sets `stack_limit` from the thread's stack, loads the carrier register, builds
   or loads the context, and calls the Hemera entry function. This is the same sequence
   Hemera's own `thread_start` describes for other operating systems.
   - The carrier block's layout stays private to each program's `std` (programs are
     content-addressed and may embed different `std` versions), so it is never part of the
     system ABI and is never written by another process.
   - `0023`'s `thread_create` keeps its shape. Its `context: rawptr` argument becomes an opaque
     `start: rawptr` handed to the entry stub, which points at whatever that program's `std`
     needs (context, carrier block, stack bounds). The kernel only puts it in the first
     argument register.
   - The kernel zeroes every other general register when a thread starts, so it never leaks a
     kernel pointer (such as the kernel's own carrier pointer, a KASLR leak, `0021`) through
     the carrier register.
2. **Stack overflow in user space is caught by Hemera's prologue check, not by guard pages.**
   The system ABI does not require stack probes for Hemera code. The stack-limit check is part
   of the Hemera calling convention, and so of the pinned convention version
   (`../design/system-abi.md` §7). Guard pages remain useful only for foreign code running on
   a thread's own stack.
3. **"No thread-local storage" stands for Hemera code.** Per-call-chain state is the context;
   per-thread execution state is the carrier block, reached through the carrier register, not
   through TLS. Whether SlopOS adds one kernel-saved per-thread pointer, only so callbacks
   from foreign code can find the carrier, is left open (`../open-questions.md`, *Kernel*).
4. **The kernel preserves the carrier register across syscalls and interrupts**, like every
   other non-result register (`../design/system-abi.md` §4), and never trusts its user-mode
   value: kernel entry loads the kernel's own carrier pointer from per-CPU data.

## Alternatives considered
- **The kernel sets the carrier register as part of `thread_create`:** the kernel would have
  to know about a runtime structure whose layout changes with `std`, or take one more raw
  register value. An entry stub is needed anyway, to set `stack_limit` before the first
  prologue check runs.
- **The process manager writes the new process's carrier block:** puts the parent's `std`
  layout into the child, which breaks when they were built with different `std` versions.
- **Keep guard pages and probes as the primary mechanism:** redundant with the prologue
  check, and guard pages need page-aligned stacks, which fibers' 1 KiB segments aren't.

## Consequences
- `0023`'s cost model holds: thread creation is still one syscall. The carrier block adds
  about one cache line or two of user memory per thread, paid by `std`.
- The kernel itself is Hemera code, so it needs a carrier block per CPU and an entry path that
  loads the carrier register. That, interrupt stacks, and what the check does in freestanding
  builds (no `morestack`) are open (`../design/kernel.md` §3, `../hemera-feedback.md`).
- Since fibers no longer move frames, pointers into a fiber's stack stay valid across yields,
  which Hemera now allows with compile-time checks (`#escaping`, `#scoped`).
- The startup block (`../design/system-abi.md` §6) no longer needs to carry anything for the
  carrier: the child's own entry stub sets it up.
