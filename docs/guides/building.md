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

That builds the kernel, SlopOS's programs, every test program and the hosted tools. Settings choose what and where,
as `--setting=name=value,name=value`:

| Setting | Values |
|---|---|
| `targets` | `all` (the default), `kernel`, `programs`, `tests`, or `tools` |
| `kernel_output` | The kernel's ELF; `kernel.elf` by default. A relative path is relative to `src/build` |
| `programs_output` | The folder for SlopOS's programs, each `<name>.elf`; the current folder by default |
| `tests_output` | The folder for test programs; the current folder by default |
| `tools_output` | The folder for the hosted tools in `src/tools`, like the image builder; the current folder by default |
| `arch` | `x86_64` (the default) or `aarch64`, for the kernel and the programs |
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
| `--console-input LINE` | Add a virtio console linked to a TCP socket on the loopback, and type this line into it when the console service's banner shows; may be repeated, the i-th line typed at the i-th banner, as when the console has dialed its serial line again |
| `--keyboard-input LINE` | Add a virtio keyboard and the virtio console, and type this line on the keyboard, a key at a time with Enter at the end, through QEMU's machine protocol (QMP) on a loopback socket, once the console's banner shows; may be repeated |
| `--expect-console-line LINE` | With `--expect`: the virtio console must show this exact line; may be repeated |
| `--arch ARCH` | `x86_64` (the default), or `aarch64` on QEMU's virt machine through UEFI |
| `--disk MARK` | Add a virtio block device: a 38 MiB GPT disk whose `SlopOS check` partition has `MARK` at the start of its block 0 and `block N` at the start of its blocks 2 to 9, and an EFI system partition holding the disk check's files, its FAT32 written by `boot.py` itself |
| `--boot-disk` | Boot from a disk the image builder makes instead of the ISO: the disk check's partitions, marked with `--disk`'s `MARK`, a BIOS boot partition with Limine's second stage, an EFI system partition with Limine, the kernel and the programs, of which Limine loads only the boot set, and a SlopOS container whose `system` volume holds the programs, the rest read from there |
| `--image-builder PATH` | With `--boot-disk`: the image builder to run, instead of building one |
| `--expect-disk-block N=TEXT` | With `--expect`: block `N` of the image must start with `TEXT` once the kernel has stopped; may be repeated |
| `--expect-disk-text TEXT` | With `--expect`: the image must hold `TEXT` somewhere once the kernel has stopped; may be repeated |
| `-- ARGUMENTS` | Anything after `--` goes to QEMU, like `-smp 4` |

## The Image Builder

`src/tools/image_builder` (`decisions/0088`) makes a GPT disk image with the packages SlopOS reads it with:

```
image_builder <output> <sectors> <kind,name,sectors[,folder]>...
```

Each partition starts at a MiB, in order from sector 2048: `bios` (a BIOS boot partition, for `limine bios-install`),
`esp` and `data` (FAT32, holding the folder's tree), `test` (zeros, SlopOS's test partition type) or `slopfs` (a
SlopOS container with a `system` volume holding the folder's tree, checked whole once it's made). It prints each
partition as `partition <index> <first> <count> <name>`.

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
| `test_budgets` | Run a thread with a CPU budget against one without, on 1 CPU |
| `test_device` | Grant the root task what the firmware tables say of the emulator's test device, and run the device while an IRQ for its line exists, for `test_devices` |
| `test_fibers` | Run two fibers taking turns |
| `test_segments` | Grow a fiber's stack onto more segments (a kernel built with `stack_check=morestack`) |
| `test_pool` | Share two fiber pools between CPUs 1 to 5 (6 CPUs) |

The root task reads the command line too (`docs/specs/programs.md`):

| Word | What it does |
|---|---|
| `test_services` | End once the supervisor has started its services |
| `test_outlive_manager` | Kill the process manager once `hello` has started, and end once `hello` has |
| `test_program=<name>` | Run the test program `src/tests/<name>` in place of the supervisor, and end once it has: `test_syscalls`, `test_ports`, `test_channels`, `test_memory`, `test_control`, `test_threads`, or `test_devices` (with `test_device`) |

## Testing

```
python tools/boot_tests.py
python tools/unit_tests.py
python tools/perf_tests.py
python tools/boot_tests.py --robustness
```

- **Boot tests** build the kernel, plus one with `stack_check=morestack`, and boot them in every way
  they're tested: BIOS and UEFI, a CPU below the baseline, 1 to 6 CPUs, each `test_` option above, and
  twice each with and without KASLR to compare addresses. Each test checks the code the kernel stops with,
  and some, lines of its output.
- **Unit tests** build each `test/` package under `src/` as a hosted program and run it: the frame
  allocator, the slab allocator and x86-64 paging, over buffers standing in for physical memory. A test
  program returns 0, or the number of the check that failed.
- **Perf tests** boot `test_perf` and a boot from the image builder's disk on each architecture, under QEMU's
  `-icount`, where a guest nanosecond is an instruction, and again as usual: the instruction counts are held to
  `tools/perf_baselines.json`, failing more than 10% above one, and the wall times are only reported. x86-64 is wall
  time only for now, as QEMU stops it under `-icount`. `--update`
  records the counts as the baselines, after a change that's meant to move them (`knowledge/decisions/0112`).
- **Robustness sweeps** boot kernels built with `robustness=on`, failing each chosen pass through the kernel's
  failure points (`fail=`), and boots from the image builder's disk with a faulty block connection
  (`faulty_block=`); every run must end without a fault, a hang, or anything left behind (`0096`, `0104`, `0112`).

Under heavy load on the host, the fiber pool test can fail when QEMU starves one of its CPUs, since it
needs every CPU to take part.

## Debugging

- The kernel logs its image's base, its direct map's offset and its kernel window's address at boot.
  Stack traces give addresses relative to the image base (`kernel+0x...`), so they can be found in the
  ELF whatever KASLR chose: `llvm-nm -n kernel.elf` lists its functions in order, from the link base
  `0xffffffff80000000`.
- `--no-kaslr` makes every address the same on every boot.
- `--serial PATH` keeps the whole log, including what a framebuffer console shows.
