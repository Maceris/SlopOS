# Building, Running and Testing

How to build SlopOS, boot it in QEMU, and run its tests. Everything here runs on Windows and Linux.

## What You Need

| Tool | Found through | Notes |
|---|---|---|
| Hemera's compiler, `hemera` | the `PATH`, or `HEMERA` for the unit tests | Built from the Hemera repository; it finds Hemera's `std` next to itself, or in `HEMERA_INSTALL` |
| QEMU, `qemu-system-x86_64` | `QEMU` (the program or its folder), then the `PATH`, then `C:\Program Files\qemu` | Its own UEFI firmware is used for `--uefi`, or `OVMF` |
| Limine's binary release | `LIMINE` (its folder), then the `PATH` | `limine-bios.sys`, `limine-bios-cd.bin`, `limine-uefi-cd.bin`, `BOOTX64.EFI` and the `limine` tool |
| xorriso | `XORRISO`, then the `PATH` | Makes the boot ISO |
| Python 3 | the `PATH` | Runs the tools in `tools/` |

## Building

SlopOS is built by its build package, a Hemera program (`src/build`, decision `0028`), which also runs
the house-rule checks on every target (`0029`):

```
hemera src/build
```

That builds the kernel and every test program. Settings choose what and where, as
`--setting=name=value,name=value`:

| Setting | Values |
|---|---|
| `targets` | `all` (the default), `kernel`, or `tests` |
| `kernel_output` | The kernel's ELF; `kernel.elf` by default. A relative path is relative to `src/build` |
| `tests_output` | The folder for test programs; the current folder by default |
| `stack_check` | What the kernel's prologue checks do without room: `trap` (the default), or `morestack` |

```
hemera --setting=targets=kernel,kernel_output=D:/build/kernel.elf src/build
```

If a build fails, the boot tests keep everything the compiler wrote in `build/failed_kernel_build.log`.

## Running

`tools/boot.py` builds the kernel (unless given one), puts it in a Limine ISO, and boots it in QEMU with
the serial port on standard output:

```
python tools/boot.py --expect 0
```

| Option | What it does |
|---|---|
| `--kernel PATH` | Boot this ELF instead of building one |
| `--command-line TEXT` | The kernel's command line; `test_exit` by default |
| `--expect CODE` | Exit 0 if the kernel stops with this code (`src/kernel/stop.hsc`), 1 otherwise |
| `--expect-line LINE` | With `--expect`: the serial output must also have this exact line; may be repeated |
| `--uefi` | Boot with UEFI firmware instead of BIOS |
| `--cpu MODEL` | QEMU's CPU model; `max` by default, since SlopOS needs x86-64-v3 |
| `--no-kaslr` | The same addresses on every boot: no random image base, direct map or kernel window (`0021`) |
| `--timeout SECONDS` | Give up after this long; 30 by default |
| `--serial PATH` | Also keep the serial output in a file |
| `-- ARGUMENTS` | Anything after `--` goes to QEMU, like `-smp 4` |

The kernel stops with a code QEMU's debug-exit device reports when `test_exit` is on its command line:

| Code | Why |
|---|---|
| 0 | It booted, ran, and halted after its last tick |
| 1 | A fault in the kernel |
| 2 | The CPU isn't x86-64-v3 |
| 3 | A failed assertion |
| 4 | A double fault or machine check |
| 5 | The boot adapter couldn't build `BootInfo` |
| 6 | Too little memory to boot |

## The Kernel's Command Line

Words separated by spaces; unknown words are ignored.

| Word | What it does |
|---|---|
| `test_exit` | When the kernel stops, ask the emulator to exit with the reason's code |
| `no_kaslr` | Lay out the kernel's own regions at fixed addresses (`boot.py --no-kaslr` adds it) |
| `test_fault` | Run an invalid instruction, to check kernel faults are reported |
| `test_assert` | Fail an assertion |
| `test_nmi` | Raise an NMI, and check the kernel resumes |
| `test_write_code` | Write to the kernel's code, which has to fault (W^X) |
| `test_heap` | Allocate, resize and free blocks of many sizes and alignments from the kernel heap |
| `test_clock` | Check the monotonic clock against the counter |
| `test_shootdown` | Change a mapping every CPU has used, and check they all see the change (2 CPUs or more) |
| `test_ioapic` | Route the emulator's PIT through its I/O APIC, and count its interrupts |
| `test_threads` | Run 4 threads in user mode, preempted by the timer, each keeping its own vector state |
| `test_budgets` | Run a thread with a CPU budget against one without, on 1 CPU |
| `test_fibers` | Run two fibers taking turns |
| `test_segments` | Grow a fiber's stack onto more segments (a kernel built with `stack_check=morestack`) |
| `test_pool` | Share two fiber pools between CPUs 1 to 5 (6 CPUs) |

## Testing

```
python tools/boot_tests.py
python tools/unit_tests.py
```

- **Boot tests** build the kernel, plus one with `stack_check=morestack`, and boot them in every way
  they're tested: BIOS and UEFI, a CPU below the baseline, 1 to 6 CPUs, each `test_` option above, and
  twice each with and without KASLR to compare addresses. Each test checks the code the kernel stops with,
  and some, lines of its output.
- **Unit tests** build each `test/` package under `src/` as a hosted program and run it: the frame
  allocator, the slab allocator and x86-64 paging, over buffers standing in for physical memory. A test
  program returns 0, or the number of the check that failed.

Under heavy load on the host, the fiber pool test can fail when QEMU starves one of its CPUs, since it
needs every CPU to take part.

## Debugging

- The kernel logs its image's base, its direct map's offset and its kernel window's address at boot.
  Stack traces give addresses relative to the image base (`kernel+0x...`), so they can be found in the
  ELF whatever KASLR chose: `llvm-nm -n kernel.elf` lists its functions in order, from the link base
  `0xffffffff80000000`.
- `--no-kaslr` makes every address the same on every boot.
- `--serial PATH` keeps the whole log, including what a framebuffer console shows.
