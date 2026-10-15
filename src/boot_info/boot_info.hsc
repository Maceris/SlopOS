/*
 * BootInfo: what the boot adapter (L0) hands the kernel core (L2). The only boot data L2 reads.
 * Specified in docs/specs/boot_info.md, which explains every rule these types follow.
 */
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

/*
 * Starts cpu, which then loads carrier, pushes the constant boot context and calls entry
 * (docs/specs/boot_info.md, CPUs).
 */
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
