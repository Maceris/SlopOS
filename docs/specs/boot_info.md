# BootInfo

`BootInfo` is what the boot adapter (L0) hands the kernel core (L2): the memory map, the kernel
image's location, the CPUs and how to start them, the boot modules, framebuffers, firmware
tables, and a few optional values the bootloader may know. It is the only boot data the kernel
core reads; no bootloader structure reaches L2 (`../architecture/layers.md`, L0).

Status: **draft**, implemented in `src/boot_info` and `src/boot/limine` (roadmap M1), apart from
`start_cpu`. Choices and alternatives are in
`../../knowledge/decisions/0031-boot-info.md` (proposed). Four-digit numbers like `0020` refer to
decision records in `../../knowledge/decisions/`.

`BootInfo` is internal to the kernel image: L0 and L2 are compiled together, so this
specification changes together with both, and the struct carries no version number.

## Handoff

L0's entry point calls the kernel core's portable entry with a read-only pointer:

```
boot #never_returns :: fn(boot_info: ptr[BootInfo])
```

At that point:
- **Interrupts are disabled** on the boot CPU, and the other CPUs aren't running kernel code.
- **The carrier register** points at a carrier block on the boot stack, with `stack_limit` set
  for that stack. To switch to its own per-CPU carrier block, the kernel copies the current
  `intrinsics.carrier().stack_limit` into it before calling `intrinsics.set_carrier`.
- **The context** is the constant boot context: `runtime.MINIMAL_CONTEXT`, pushed with
  `push_context ... from`, with an early serial logger in place of its discarding one.
- **Paging is on**, with the bootloader's page tables. The kernel image is mapped at
  `kernel_image.virtual_base`, and all memory in the memory map except `Reserved` and
  `Defective` regions is mapped at `direct_map_offset` plus its physical address.

## Types

All of these are in the `boot_info` package, which L0 and L2 both import.

```
package boot_info

import runtime from "base"

PhysicalAddress :: distinct alias u64
VirtualAddress :: distinct alias u64

// A range of physical memory. size is in bytes.
PhysicalRange :: struct {
    base : PhysicalAddress,
    size : u64,
}

BootInfo :: struct {
    // Bootloader name and version, for the boot log.
    bootloader : string,
    firmware : Firmware,
    // The kernel's command line. Empty when there is none.
    command_line : string,
    // Every range of physical memory the firmware reported, sorted and non-overlapping.
    memory_map : MemoryRegion[],
    // Virtual address of physical address 0 in the bootloader's direct map.
    direct_map_offset : u64,
    kernel_image : KernelImage,
    // Every CPU, the boot CPU first. A CPU's index here is its kernel CPU index.
    cpus : BootCpu[],
    // Starts one of cpus. Null when there is only one CPU.
    start_cpu : StartCpu?,
    // The boot modules, the root task first.
    modules : BootModule[],
    // Linear RGB framebuffers. Empty when there are none.
    framebuffers : Framebuffer[],
    firmware_tables : FirmwareTables,
    // Random bytes from the bootloader, if it has any. Best effort, never the only source.
    bootloader_entropy : u8[32]?,
    // Frequency of the architecture's counter in Hz, if the bootloader measured it.
    counter_frequency_hint : u64?,
    // Wall-clock time at boot, in seconds since the Unix epoch, if the bootloader read one.
    boot_wall_time : i64?,
}

StartCpu :: alias fn(cpu: ptr[BootCpu], carrier: ptr[mut runtime.CarrierBlock], entry: CpuEntry)

// Where a started CPU begins in the kernel.
CpuEntry :: alias fn() #never_returns

Firmware :: enum #backed_by(u8) {
    Bios,
    Uefi,
    // 32-bit UEFI on a 64-bit CPU. Its runtime services can't be called from 64-bit code.
    Uefi32,
    // RISC-V Supervisor Binary Interface.
    Sbi,
}

MemoryRegion :: struct {
    range : PhysicalRange,
    kind : MemoryKind,
}

MemoryKind :: enum #backed_by(u8) {
    // Free RAM.
    Usable,
    /*
     * RAM holding the bootloader's data, its page tables, the CPUs' boot stacks, and BootInfo
     * with everything it points to. Free once the kernel is done with all of them.
     */
    BootReclaimable,
    // The kernel image.
    KernelImage,
    // The contents of boot modules.
    BootModule,
    // A framebuffer's memory.
    Framebuffer,
    // Firmware tables (ACPI) that can be freed once they've been read.
    FirmwareTables,
    // Memory the firmware keeps using (ACPI NVS, UEFI runtime). Never used or freed.
    FirmwareReserved,
    // Reserved for any other reason. Never used or freed.
    Reserved,
    // RAM reported as faulty.
    Defective,
}

KernelImage :: struct {
    physical : PhysicalRange,
    virtual_base : VirtualAddress,
    // The image's loaded segments, so the kernel can map each with the right protection.
    segments : ImageSegment[],
}

// One loaded segment of the kernel image, from its ELF program headers.
ImageSegment :: struct {
    virtual_base : VirtualAddress,
    // In bytes, in memory.
    size : u64,
    writable : bool,
    executable : bool,
}

BootCpu :: struct {
    /*
     * The CPU's hardware identifier: the local APIC ID on x86-64, the MPIDR affinity fields
     * on AArch64, the hart ID on RISC-V.
     */
    hardware_id : u64,
    // L0's own data for starting this CPU. Never read outside L0.
    boot_handle : rawptr,
}

BootModule :: struct {
    // The module's file name, without the directory.
    name : string,
    // The module's command line, from the boot configuration. Empty when there is none.
    command_line : string,
    // The module's contents. base is 4 KiB aligned; size is the exact size in bytes.
    contents : PhysicalRange,
}

Framebuffer :: struct {
    memory : PhysicalRange,
    width : u32,
    height : u32,
    // Bytes from the start of one row to the start of the next.
    pitch : u32,
    bits_per_pixel : u16,
    red : ColorChannel,
    green : ColorChannel,
    blue : ColorChannel,
    // The display's EDID, empty when unknown.
    edid : u8[],
}

// Where one color's bits are in a pixel.
ColorChannel :: struct {
    size : u8,
    shift : u8,
}

// Physical addresses of firmware tables, each null when the firmware has none.
FirmwareTables :: struct {
    acpi_rsdp : PhysicalAddress?,
    devicetree : PhysicalAddress?,
    smbios : PhysicalAddress?,
    efi_system_table : PhysicalAddress?,
}
```

## Rules

### Addresses
- **Physical addresses** are `PhysicalAddress` and `PhysicalRange` values: memory regions, the
  kernel image, module contents, framebuffers and firmware tables. They stay valid for the
  life of the system, since the kernel hands most of them on as memory objects.
- **Everything else is a virtual address** in the bootloader's mapping: `BootInfo` itself, its
  arrays and strings, and `edid`. These are valid only while the bootloader's direct map is
  mapped. The kernel finishes reading them before it activates page tables without that
  mapping at the same `direct_map_offset`.

### Memory Map
- Regions are **sorted by base, don't overlap, and start and end on 4 KiB boundaries.**
  `Usable` regions are shrunk to page boundaries; other regions are grown to them, and where
  growing makes two regions overlap, the one that isn't `Usable` keeps the page.
- Adjacent regions of the same kind are merged.
- **Physical page 0 is never `Usable`,** so a physical address of 0 is never a valid frame.
- `BootInfo` and its arrays are in `BootReclaimable` memory. So are the bootloader's
  responses that its strings point into.
- Ranges missing from the map aren't RAM. They may be device memory, which the platform
  service finds from the firmware tables.

### Reclaiming Boot Memory
`BootReclaimable` regions become usable only after all of these:
1. The kernel has copied everything it keeps from `BootInfo`.
2. Every CPU has left its boot stack.
3. The kernel's own page tables are active, since the bootloader's are in `BootReclaimable`
   memory.

`FirmwareTables` regions are handed to the root task as memory objects and freed when it lets
them go. `KernelImage`, `BootModule`, `Framebuffer`, `FirmwareReserved`, `Reserved` and
`Defective` are never added to the frame allocator.

### CPUs
- `cpus[0]` is the boot CPU.
- `start_cpu(cpu, carrier, entry)` starts `cpu` once. On that CPU, L0:
  1. sets `carrier.stack_limit` for the boot stack the bootloader gave that CPU;
  2. loads `carrier` with `intrinsics.set_carrier`;
  3. pushes the constant boot context;
  4. calls `entry`.

  `entry` finds its CPU's `PerCpu` through `intrinsics.carrier().program_data`, which the
  kernel sets before calling `start_cpu`. Each CPU's boot stack is in `BootReclaimable` memory.
- `start_cpu` doesn't wait for the CPU to start or report failure. The kernel waits for each
  CPU's `entry` to report in, with a timeout.

### Modules
- `modules[0]` is the root task (`0012`). The kernel stops if there isn't one when it starts the
  root task (roadmap M6); until then there may be none.
- Module contents are passed on to the root task as memory objects, except the root task's own
  module, which the kernel loads.

### Entropy
`bootloader_entropy` is mixed into the kernel's entropy pool together with the architecture's
own source (`RDSEED` on x86-64, `RNDR` on AArch64, Zkr `seed` on RISC-V). The kernel never relies
on it alone.

## Limine (`boot/limine`)

The `boot/limine` package implements L0 for the Limine boot protocol, base revision 6, on every
supported architecture (`0020`, `0022`).

### Requests

| Limine request | Required | Used for |
|---|---|---|
| Base revision 6 | yes | Every pointer below is virtual, in the direct map |
| Memory map | yes | `memory_map` |
| HHDM | yes | `direct_map_offset` |
| Executable address | yes | `kernel_image` |
| Executable file | yes | `kernel_image.segments` |
| MP (x86-64: x2APIC flag set) | yes | `cpus`, `start_cpu` |
| Module | no: Limine answers it only when there are modules | `modules` |
| Paging mode: 4-level (Sv48 on RISC-V) | yes | The bootloader's page tables |
| Stack size: 64 KiB | yes | Boot stacks of every CPU |
| Bootloader info | no | `bootloader` |
| Firmware type | no | `firmware` (defaults to `Uefi`) |
| Executable command line | no | `command_line` |
| Framebuffer | no | `framebuffers` |
| RSDP, device tree blob, SMBIOS, EFI system table | no | `firmware_tables` |
| Entropy (4 values) | no | `bootloader_entropy` |
| TSC frequency (x86-64) | no | `counter_frequency_hint` |
| Date at boot | no | `boot_wall_time` |

If the bootloader doesn't acknowledge base revision 6, or a required response is missing, L0
reports which one through the early logger and halts.

### Conversion

| `BootInfo` | From Limine |
|---|---|
| `memory_map` | Memory map entries. `USABLE` → `Usable`; `BOOTLOADER_RECLAIMABLE` → `BootReclaimable`; `EXECUTABLE_AND_MODULES` → `KernelImage` for the range containing the executable's physical base, `BootModule` for the rest; `FRAMEBUFFER` → `Framebuffer`; `ACPI_RECLAIMABLE` → `FirmwareTables`; `ACPI_NVS` → `FirmwareReserved`; `BAD_MEMORY` → `Defective`; `RESERVED`, `RESERVED_MAPPED` and unknown types → `Reserved`. Then the arrays L0 builds are carved out of a `Usable` region and listed as `BootReclaimable`. |
| `kernel_image` | Executable address response, with the size of the memory map entry at the physical base. `segments` are the `PT_LOAD` program headers of the executable file response's ELF image, offset by the difference between `virtual_base` and the image's link address |
| `cpus` | MP response, with the boot CPU moved first. `hardware_id` is `lapic_id`, `mpidr` or `hartid`; `boot_handle` points at the CPU's `limine_mp_info` |
| `start_cpu` | Writes `extra_argument`, then `goto_address` (atomically) in the CPU's `limine_mp_info`, pointing at L0's secondary entry |
| `modules` | Module response, in the order the boot configuration lists them. `name` is the last component of `path`; `command_line` is `string` |
| `framebuffers` | Framebuffers with memory model 1 (RGB). Others are left out. `memory` is `address` minus the HHDM offset, with size `pitch × height` |
| `firmware_tables` | Each response's address minus the HHDM offset. SMBIOS uses `entry_64`, or `entry_32` when that's null |
| `bootloader_entropy` | The 4 entropy values, as bytes in little-endian order |
| `firmware` | `X86_BIOS` → `Bios`, `EFI64` → `Uefi`, `EFI32` → `Uefi32`, `SBI` → `Sbi` |

L0 needs no allocator. Strings point into the bootloader's responses. The arrays (memory
map, segments, CPUs, modules, framebuffers) are sized from the response counts and placed in memory carved
from the first `Usable` region big enough.

### Request Blocks

Limine finds requests by scanning the kernel image, and writes each response pointer into the
request before the kernel starts. Each request, and the start and end markers, is a constant
marked `#externally_initialized`, in its own section (Hemera `docs/directives.md`, *Constants*):

| Constants | Section |
|---|---|
| The start marker | `.limine_requests_start` |
| The base revision tag and every request | `.limine_requests` |
| The end marker | `.limine_requests_end` |

The kernel's linker script places the three sections in that order, in a loaded segment.

## Not Covered

- Starting CPUs without the bootloader's help (INIT-SIPI on x86-64, PSCI on AArch64, SBI HSM on
  RISC-V), for a future L0 that doesn't start CPUs itself.
- UEFI runtime services: whether anything calls them, and how.
- How the root task's module is laid out and loaded (`0012`, decided with the program format).
