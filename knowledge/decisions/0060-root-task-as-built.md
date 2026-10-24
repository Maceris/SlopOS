# 0060: The Root Task as Built

Status: accepted
Date: 2026-10-23
Related: `0012` (the root task), `0058` (the plan for M6), `0059` (user programs), `0039` (the platform
capability), `0011` (budgets), `../../docs/specs/programs.md`, `../roadmap.md` M6

## Context
M6's second stage (6b): the kernel starts the root task. `0012` says the root task gets everything the
kernel holds, and `0058` chose a shared loader and a debug-log capability, but left open how the startup
block carries grants, what happens when the root task ends, how the root task reads boot modules, and the
root CPU budget, which isn't a kernel object yet.

## Decision
Chosen with the project's owner:
- **Grants in a labeled table** after the startup block's fixed fields, found through an offset from the
  block's start: each a label of up to 32 bytes ("platform", "debug_log", "module:hello.elf"), its handle's
  kind and the handle. 6d's typed entry parameters become grants named after their parameters.
- **The root task's end stops the kernel**, with a stop reason of its own (`RootTaskEnded`) and a log line
  saying how it ended: a working system's root task never ends, so its end is the machine's.
- **Boot modules as physical memory objects**: read-only, over the frames Limine loaded each one into, with
  no copy. Their frames go to the frame allocator once the object is destroyed, so the allocator keeps state
  for boot modules' memory too.
- **CPU budgets later**: the root task's threads run with the kernel's default until CPU budgets become
  objects with handles, when something splits them.

As built:
- **The kernel loads the root task** (`src/kernel/root_task.hsc`) from the first boot module with the shared
  loader: its image in a memory object, each segment mapped with its protection and the RELRO pages
  read-only; a 256 KiB stack, with the startup block a guard page above it, mapped read-only; and a 1 TiB free
  range. Each is at a random page in a quarter of user addresses of its own (the free range in the upper
  half), the same every boot with `no_kaslr`. The first thread starts at the entry with the startup block's
  address. `no_root_task` on the command line leaves it out.
- **Its handles**: itself, its address space (owning) and the root budget; grants for the platform, a debug
  log, and each other boot module. The startup block also has the first thread's stack, which the runtime
  takes its stack limit from (`runtime.os_prepare_carrier`), and the boot's random seed: the bootloader's
  entropy mixed with the CPU's.
- **The debug log**: `DebugLog` objects (kind 14), and `debug_log` (call 46), which writes `[user] ` and up to
  200 bytes of a program's text as one line of the kernel's log, anything not printable as `?`.
- **The root task** (`src/services/root_task`), for now: it checks its startup block and grants, maps
  `hello.elf`'s module, uses its heap, reports through its debug log, and ends with 0, or the number of the
  first check that failed. It becomes long-lived with 6c.
- **`runtime.reserve_addresses(size)`**, part of the free range for a program to map something itself.
- **Boot tests**: the root task starts, reports and ends with 0; `no_root_task` leaves it out. Only tests that
  need programs carry them, since the root task's end stops the kernel.
- **Found in Hemera on the way, fixed (`0047`):** a `#no_context` function calling a generic function that
  needs a context checked, then crashed the compiler; the checker now refuses it, as it does for other calls.

## Alternatives considered
- **Fixed fields for each grant**: simpler to read, but the layout would change with every kind of grant, and
  6d needs a general scheme anyway.
- **A panic when the root task ends**: tests couldn't run a root task to completion.
- **Copying modules into new memory**: a copy, and twice the memory for a while.
- **CPU budgets as objects now**: kernel work before anything uses it.

## Consequences
- 6c's process manager needs what the kernel did here as calls: loading into another process's space is
  `memory_map` on its space, but starting its first thread isn't, since `thread_create` makes one in the
  caller's process. A call for that comes with 6c.
- A module's frames stay the root task's until it closes the module's handle, which gives them back.
- The root task is in the TCB with everything it holds; the debug log is a handle like any, so it's given on
  only on purpose.
