# 0100: The House-Rule Checks, as Built (Catch-up Part 3)

Status: accepted
Date: 2026-10-30
Related: `0007` (checks, not conventions), `0021` (KASLR: no kernel addresses to user space), `0029` (checks in the
build, and the rules waiting to be written), `0099` (catch-up part 2), `../roadmap.md` *Catch-up*

## Context
`0029` listed the rules waiting for Hemera's reflection: layout asserts for hardware structs, no floating point in the
kernel, interrupt handlers that don't allocate, `rawptr` only where allowed, no ignored errors in the kernel, programs
that don't import programs, and (`0021`) no pointers in system call results. All but ignored errors could be written
with what reflection gave; for that one Hemera's `FunctionInfo` now gives `discards`, each value a body throws away
with `_ =`, with its type. Chosen with the project's owner: a `#packed` struct in a hardware package is hardware, and
its package asserts its size; the kernel's discarded `Result`s are refused outside an allow-list.

## Decision
Each rule is a function in `src/checks`, called from `check_program`, so it runs on every target the build makes.
"The project's own packages" means neither `base`'s nor `std`'s; "the kernel" means a target built for no operating
system.
- **No floating point in the kernel** (`check_kernel_floats`): no float, complex or quaternion type, or vector of them,
  in what a kernel function takes, gives or uses.
- **No pointers in system call results** (`check_syscall_results`): what each `sys_` function of the `kernel` package
  gives has no pointer in it, through aliases, arrays, struct members and union variants.
- **Interrupt handlers don't allocate** (`check_interrupt_allocation`): nothing that `kernel_entry.interrupt` reaches,
  through calls to named functions in the project's packages and `base`, calls one of `base`'s allocators (`new`,
  `new_aligned`, `new_array`, `new_array_aligned`, `array_reserve`) or the kernel's (`allocate_block`, `new_object`).
  A generic function's instance is matched by its name without its arguments. Calls through function values aren't
  followed. `INTERRUPT_ALLOCATIONS` lists the exceptions, as `package.function`. There's one: `kernel.grow_heap`,
  which a woken thread's wait reaches when it's armed again as the thread resumes. Without memory, that wait goes on
  without its deadline, as designed.
- **Programs don't share code** (`check_program_imports`): a program is a package in `src/apps`, `src/services`,
  `src/drivers` or `src/tests` that declares `main`. A program may import another to launch it, for its entry's type
  and its constants, but calls nothing of it. `0029` said "never import", which launching with typed entries (`0068`)
  needs to.
- **`rawptr` only where allowed** (`check_raw_pointers`): a function of one of the project's packages uses `rawptr`
  only if `RAW_POINTERS` names its package. The list is the 38 packages that used it when the rule came in: the
  kernel, the architectures, the file systems, the services that read rings and buffers, and the tests and tools
  that do the same. A new package joins only for such a reason.
- **Hardware structs have their layouts asserted** (`check_hardware_layouts`): a `#packed` struct in a package under
  `src/arch`, `src/drivers`, `src/iommu`, `src/virtio`, `src/pci`, `src/gpt`, `src/fat` or `src/slopfs` has a line in
  one of its package's files with `#assert` and `size_of(Name)`. The files are read, since reflection doesn't give
  asserts.
- **The kernel's errors aren't ignored** (`check_kernel_discards`): no kernel function discards a `Result` with `_ =`,
  unless `DISCARDED_RESULTS` names it. Three do: `arch_aarch64.init_kernel_page_table`, which maps a block another's
  tables may cover already; `kernel.sys_channel_create`'s cleanup after a failure, whose own error is the one given;
  and `kernel.test_shootdown`.
- **Found by the rules**: virtio's `Descriptor` and `UsedElement`, virtio-blk's `RequestHeader` and virtio-input's
  `DeviceEvent` had no size asserts, and have them now. Nothing else broke a rule.
- **Each rule was shown to fire** by putting a breach of it in, once: a float in the kernel, a `sys_` function giving a
  pointer, an allocation in `handle_timer`, an unasserted `#packed` struct in `gpt`, and one test program calling
  another's function.
- Package paths are Windows paths on Windows, so folders are matched whichever separator a path uses.

## Alternatives considered
- **A `LAYOUT_CHECKED` constant per package**, which `0029` suggested: easy to read by reflection, but it says nothing
  about which structs are checked.
- **An empty `rawptr` list, with each use moved behind a typed pointer**: the end state, but hundreds of edits across
  the kernel and file systems, for another time.
- **Following calls through function values from interrupt handlers**: they're the logger's and the allocator's own.
  Reflection doesn't say which function a value holds.

## Consequences
- Part 4 of the catch-up is next.
- The interrupt rule's roots are what `kernel_entry.interrupt` calls. A new entry for interrupts needs to be one of them.
