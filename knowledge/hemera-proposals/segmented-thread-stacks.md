# Proposal: Segmented Stacks for Plain Threads

Status: **proposed** 2026-10-13. Raised with Hemera's fiber redesign (2026-10-04), from SlopOS's
open question *Should plain threads grow their stacks with segments too?*

## Problem

Hemera's fibers run on segmented stacks: a 1 KiB first segment, more added by `morestack` as
needed, and none of the cost of guard pages or memory mappings (Hemera `docs/multitasking.md`,
*Stacks*). Plain threads don't: a thread has one fixed stack, and "running out of stack is a
deterministic error rather than a fault on a guard page".

So the same code has different limits depending on where it runs:
- deep recursion that works on a fiber fails on a thread, or the thread is created with a large
  stack "just in case";
- on SlopOS, where user space owns stacks and threads should be cheap (`../decisions/0023`), every
  thread costs at least a 4 KiB page of stack, while an idle fiber costs about 1.4 KiB in total.

## Proposal

**A plain thread runs its Hemera code on a segmented stack, the way a fiber does.**
- A new thread starts on a small first segment (1 KiB, like a fiber's), allocated with the thread.
- `morestack` adds segments from the per-carrier cache, with the same spare-segment rule as fibers.
- `stack_limit` follows the current segment, as it does on a fiber. Running out is no longer an
  error on threads, only on stacks that can't grow.

**The thread's native stack** is a separate, contiguous stack, used only where Hemera code isn't
running:
- **foreign calls**, which the foreign-call shim already switches to "the carrier thread's own
  stack" (`docs/calling_convention.md`, *Calls to Foreign Code*);
- **signal delivery** on systems with signals (*Signals*);
- **fiber schedulers'** own work, if the thread runs one.

Where it comes from depends on the system:
- **Linux, Windows, macOS** require one for every OS thread, so it's the stack the OS thread was
  created with, as today. The gain there is growth rather than memory: no fixed limit for Hemera
  code, and the same behaviour as fibers.
- **SlopOS** (and any system where a thread starts with only the stack pointer it's given) doesn't
  require one: it's allocated on the thread's first foreign call, with a size chosen when the thread
  is created, and never allocated by threads that don't call foreign code.

**Unchanged:**
- **Freestanding programs and kernels** keep their fixed stacks. `stack_check_failure` stays `.Trap`
  or `.AssertionHandler` there, since there's no allocator for `morestack`.
- **The main thread on hosted systems** starts on the stack the OS gave it, and switches to segments
  in Hemera's startup code, like other threads.
- **Threads that want a fixed stack** can still ask for one when they're created (for example, code
  that must never allocate after it starts).

## Where It Would Change

| Where | Change |
|---|---|
| Hemera `docs/multitasking.md`, *Stacks* | Threads use segments too; the native stack and when it's used |
| Hemera `docs/calling_convention.md` | `morestack` on threads; the foreign-call shim's native stack may be allocated on first use |
| Hemera `base/runtime/thread.hsc` | Thread creation options: first segment size, native stack size, or a fixed stack |
| SlopOS `std` thread entry stub (`../decisions/0026`) | Sets up the first segment instead of a page-sized stack |

## Alternatives Considered

- **Keep fixed thread stacks:** simplest, but threads stay expensive on SlopOS, and code behaves
  differently on threads and fibers.
- **Guard pages and growth by faulting** (Linux's main-thread stack): needs page-aligned stacks and
  probes for large frames, which `../decisions/0026` already moved away from.

## Open Questions

- **Cost:** threads pay `morestack` at segment boundaries where a fixed stack wouldn't. Measure
  against the spare-segment cache before making it the default everywhere.
- **Native stack size on SlopOS** when a thread does call foreign code: a fixed default (64 KiB?), or
  required at creation?
