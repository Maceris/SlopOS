# Programs

What a SlopOS program is, and how it starts: the executable its build makes, what its loader does with it,
and what it's given when it starts.

Status: **implemented in part** (roadmap M6, stage 6a): programs build and their loader is unit-tested, but
nothing loads one into a process yet (6b, the root task). Choices and alternatives are in
`../../knowledge/decisions/0058-user-space-plan.md` and `0059-user-programs-as-built.md`. Four-digit
numbers like `0004` refer to decision records in `../../knowledge/decisions/`.

## Executables

A program is a package in `src/apps/`, `src/services/` or `src/drivers/`, built by the build package
(`src/build`, `targets=programs`) as `<name>.elf` for `os = .SlopOS` and x86-64-v3 (`0003`): a
position-independent ELF executable (`ET_DYN`, `0004`) linked statically, with no interpreter, no shared
libraries and no thread-local storage, whose only relocations are `R_X86_64_RELATIVE`. Its entry is the
compiler's startup code, which calls the package's `main`.

The boot image carries every program as a Limine module, in the order of their names, under
`/boot/modules/`.

## Loading

`src/elf_loader` checks an executable and loads it into memory the loader provides, allocating nothing:

1. `read(file)` checks the file and gives its `Executable`: the entry and each loadable segment, from the
   image's base; the image's size, a whole number of pages; its relocations; and what's read-only once
   it's relocated (`PT_GNU_RELRO`). It refuses anything else: another kind of file or machine, a
   segment that's writable and executable or shares a page with another, an entry outside an executable
   segment, a relocation of another kind or into a segment that isn't writable, and an executable stack.
2. `load(executable, file, image)` copies each segment's bytes into `image`, zeroed and at least the
   image's size.
3. `relocate(executable, file, image, base)` writes each relocation for the image to run at `base`.

The image is then mapped at `base`, a random, page-aligned address (ASLR), each segment's pages with its
own protection, and the RELRO pages without write.

## Starting

The process's first thread starts at the entry, with the stack pointer 8 below a multiple of 16 (as a call
leaves it) and the **startup block**'s address in its first argument register; every other register is
zero (`0026`). The startup code keeps the address, sets up the thread's carrier block and its `Context`,
calls `main`, and ends the process with `process_exit` and `main`'s result as its code, or 0 for a `main`
without one.

`slop_os.StartupBlock`, written by the loader in memory it maps into the process for the process's life:

| Field | |
|---|---|
| `abi_version: u32` | `slop_os.ABI_VERSION` of the kernel that started it |
| `size: u32` | `size_of(StartupBlock)` as its writer knew it |
| `process: Process` | The process itself |
| `space: AddressSpace` | Its address space, with `RIGHT_SPACE_MAP` |
| `budget: MemoryBudget` | Its memory budget, with `RIGHT_BUDGET_CHARGE` |
| `reserved: u32` | |
| `free_base: u64`, `free_size: u64` | A free range of the address space, page-aligned, at a random place, where the program's runtime maps its own memory: its heap, and later its threads' stacks. Nothing else in the space uses it |
| `cpu_features: CpuFeatures` | The CPU's features (`0019`) |

The rest of the startup grants, and the entry point's typed arguments (`0044`), come with 6d.

## The Runtime

Hemera's `base` runtime for `os = .SlopOS` (`base/runtime/slop_os.hsc`) makes these calls itself, with its
own copies of their numbers and of the startup block's first fields, which the ABI package checks against
its own when it's compiled:
- **memory:** its heap is Hemera's page heap, whose pages are memory objects of their own from `budget`,
  each mapped read-write in the free range, with its handle in a page in front of it;
- **the clock:** `clock_monotonic`; there's no wall clock yet;
- **ending:** `process_exit`, also for a failed assertion.

There's no output yet (the debug-log capability comes with 6b), no random numbers (the entropy source comes
with 6c), and no threads.
