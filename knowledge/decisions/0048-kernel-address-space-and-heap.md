# 0048: The Kernel's Address Space and Heap

Status: accepted, amended 2026-10-22 (heap blocks by size and alignment; the direct map randomized; see the end)
Date: 2026-10-22
Related: `0004` (position-independent code), `0021` (KASLR), `0023` (cheap threads), `0026` (stack
checks, not guard pages), `0032` (arch interface), `../roadmap.md` M2

## Context
Until M2 the kernel ran on the bootloader's page tables, which map the kernel image and a direct map
of RAM, and allocated everything in whole frames. M2 adds paging behind the arch interface, the
kernel's own address space, and a heap for objects smaller than a frame. Several choices shape
everything that maps or allocates later.

## Decision
- **The kernel's address space** maps two things, both global and never user-accessible:
  - **The direct map**: every region of the memory map except `Reserved` and `Defective`, at
    `direct_map_offset` plus its physical address, never executable. Neighboring regions mapped alike
    are mapped as one, in the largest pages that fit (1 GiB where the CPU has them). Framebuffers are
    write-combining; the kernel image's own frames are read-only there, so no frame is both writable
    through one mapping and executable through another. Ranges outside the memory map aren't mapped:
    they may be device memory, which isn't to be cached.
  - **The kernel image**, at the address the bootloader loaded it, each loaded segment with its own
    protection: code read-execute, read-only data read-only, data read-write. A segment both writable
    and executable stops the boot.
- **The direct map stays at the bootloader's offset.** Everything the kernel allocates before its
  tables exist (its state, the frame allocator's) is addressed there, so moving it would mean
  building the tables before anything else. Randomizing it, and laying out regions of the kernel's
  own (`0021`), is left for when there's something to put in them; per-CPU state and stacks are in
  the direct map, as overflow is caught by stack checks rather than guard pages (`0026`).
- **Every address space shares the kernel half.** The kernel's table gets every table of its half up
  front (`arch_interface.kernel_half_frames`, 256 on x86-64, 1 MiB), and new address spaces copy its
  top-level entries, so a kernel mapping made later is in every address space without touching them.
  The kernel's table maps kernel addresses only, and other tables user addresses only.
- **Boot memory is reclaimed once every CPU is done with it**: every CPU on the kernel's tables, off
  its boot stack, and what the kernel keeps of `BootInfo` (the CPUs, where boot memory is) copied.
  A CPU leaves its boot stack for good at its first interrupt from idle; the boot CPU's timer does
  that for it, and the others get a reschedule IPI. If a CPU didn't start, the bootloader may still
  have it waiting in boot memory, which then stays as it is.
- **The heap is slab caches behind per-CPU magazines**, after Bonwick: power-of-two size classes
  from 16 bytes to 2 KiB, each a slab cache, with a magazine of free objects per CPU in front of it
  that takes no lock; larger sizes are blocks of frames. It's the `Allocator` in every CPU's context.
  Kernel objects get caches of their own from the same slab allocator as they arrive.
- **A heap block's class depends on its size alone**, since Hemera's `free` passes no alignment. A
  block is aligned to its class, and asking for more than that is an error.

## Alternatives considered
- **Mapping the direct map with whole 1 GiB pages regardless of the memory map**: fewer tables, but
  it maps device memory and holes as cacheable RAM, which some machines punish with machine checks.
- **Creating the kernel half's tables on demand and updating every address space**: saves up to
  1 MiB, at the cost of a walk over every address space whenever the kernel half grows.
- **One global heap lock, no magazines**: simpler, but every allocation on every CPU would contend
  for it.

## Consequences
- An address space costs its root and what its user half needs; the kernel half is free.
- The kernel image can't be written through any mapping, which the `keeps the kernel's code
  read-only` boot test checks.
- Code that needs device memory maps it itself, with `Device` caching, once the kernel has a place
  for such mappings (M3, the I/O APIC).
- Freeing a heap block with a different size than it was allocated with is caught, where whole-frame
  allocation used to hide it (it found `fiber_destroy` freeing a fiber's block by its struct's size).

## Amendment (2026-10-22)
Hemera's allocators now pass a block's alignment when freeing and resizing, as they pass its size
(Hemera's `docs/memory.md`, *Allocators*). So a heap block's class depends on its size and alignment
together, the smallest class or frame block that holds the size and is aligned enough, and asking for
more alignment than the size is no longer an error.

## Amendment (2026-10-22): The Direct Map Randomized
The direct map still stays at the bootloader's offset, but that offset is random: Limine puts it at a
random 1 GiB-aligned address when asked (`randomise_hhdm_base`, `0021`'s amendment). So the kernel never
has to move what it allocated before its tables existed, and its regions, which all live in the direct
map, are randomized with it. Single frames also go through a per-CPU cache in front of the frame
allocator, which page tables and the heap's one-frame blocks use.
