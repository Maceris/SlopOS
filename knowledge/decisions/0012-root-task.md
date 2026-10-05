# 0012: A Minimal Root Task, Separate From the Process Manager

Status: accepted
Date: 2026-10-02

## Context
With no ambient authority, every capability must come from somewhere. At boot the kernel
holds everything: all physical memory, IRQs, I/O ports, device memory, the boot modules.
Something in user space has to receive that and build the system from it. Under `0008`,
whatever owns the root of the ownership tree takes everything down with it if it dies.

## Decision
**The kernel starts exactly one user process, the root task, and gives it everything:**
the root memory budget (all free memory), the root CPU budget, all IRQ and I/O-port
capabilities, memory objects for device memory, the boot modules, and the boot entropy seed.

**The root task is tiny and policy-free.** Its whole job:
1. Read the typed boot configuration (compiled into the boot image, `../problems-and-directions.md` §6).
2. Split budgets and device capabilities and start the first services from boot modules:
   process manager, supervisor, platform service, and an early entropy source seeded from
   the boot seed.
3. Stay alive as the top of the ownership tree. It is never restarted.

**The process manager is a separate, ordinary, restartable service.** It loads programs
and builds processes *on behalf of* a requester. It never owns what it builds: a new process
is owned by the requester's node (job or session) and charged to the budget the requester
supplied (`0011`). If the process manager crashes, the supervisor restarts it and every
running process is unaffected.

This split is standard practice:
- **seL4:** the kernel hands all Untyped memory and initial capabilities to one root task.
- **Genode:** `core` owns all physical resources and has no policy; `init`, its first
  child, starts everything else from configuration.
- **Fuchsia:** the kernel starts `userboot`, which starts `component_manager`.
- **L4 (Pistachio/Fiasco):** `sigma0` owns physical memory; a separate root task builds the system.

## Alternatives considered
- **Root task = process manager:** fewer processes, but the root then holds program
  loading, executable parsing and spawn logic, so any bug there kills the whole system and
  it can never be restarted.
- **Kernel starts several services directly:** puts boot policy (which services, with which
  capabilities) into the kernel.

## Consequences
- "Who owns a process" and "who built it" are different. The process manager is a deputy
  that only acts with the budget and ownership node it is handed, which matches principle 1
  and avoids the confused-deputy problem by construction.
- The root task needs a minimal, non-relocating program loader of its own for the first
  few boot modules (or the boot modules are prelinked). Decide when the program format is designed.
- Users and sessions (`../open-questions.md`) become nodes the root task or a session
  manager creates under itself. The kernel has no notion of a user.
