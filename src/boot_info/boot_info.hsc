/**
 * BootInfo: what the boot adapter (L0) hands the kernel core (L2). The only boot data L2 reads.
 * Specified in docs/specs/boot_info.md, which explains every rule these types follow.
 */
package boot_info

import runtime from "base"

/**
 * A physical address: of memory regions, the kernel image, module contents, framebuffers and firmware tables. These
 * stay valid for the life of the system.
 */
PhysicalAddress :: distinct alias u64
/** A virtual address in the bootloader's mapping, valid only while the bootloader's direct map is mapped. */
VirtualAddress :: distinct alias u64

/** A range of physical memory. */
PhysicalRange :: struct {
    /** The range's first byte. In the memory map, 4 KiB aligned. */
    base : PhysicalAddress,
    /** The range's length in bytes. In the memory map, a multiple of 4 KiB. */
    size : u64,
}

/**
 * Everything the boot adapter (L0) tells the kernel core about the machine: the only boot data the core reads.
 *
 * It, its arrays and its strings are in BootReclaimable memory, reached through the bootloader's direct map, so the
 * kernel copies what it keeps before it activates page tables without that map (docs/specs/boot_info.md, Addresses).
 */
BootInfo :: struct {
    /** The bootloader's name and version, for the boot log. */
    bootloader : string,
    /** The firmware the machine booted from. */
    firmware : Firmware,
    /** The kernel's command line. Empty when there is none. */
    command_line : string,
    /**
     * Every range of physical memory the firmware reported: sorted by base, non-overlapping, on 4 KiB boundaries, and
     * with adjacent regions of one kind merged. Physical page 0 is never Usable; ranges missing from it aren't RAM.
     */
    memory_map : MemoryRegion[],
    /**
     * The virtual address of physical address 0 in the bootloader's direct map: all memory in memory_map except
     * Reserved and Defective regions is mapped at this plus its physical address.
     */
    direct_map_offset : u64,
    /** Where the kernel image is, physically and virtually, and its segments. */
    kernel_image : KernelImage,
    /** Every CPU, the boot CPU first. A CPU's index here is its kernel CPU index. */
    cpus : BootCpu[],
    /** Starts one of cpus. Null when there is only one CPU. */
    start_cpu : StartCpu?,
    /** The boot modules, the root task first. May be empty until the kernel starts the root task. */
    modules : BootModule[],
    /** Linear RGB framebuffers. Empty when there are none. */
    framebuffers : Framebuffer[],
    /** The physical addresses of the firmware's tables. */
    firmware_tables : FirmwareTables,
    /** Random bytes from the bootloader, if it has any. Best effort: mixed into the pool, never its only source. */
    bootloader_entropy : u8[32]?,
    /** Frequency of the architecture's counter in Hz, if the bootloader measured it. */
    counter_frequency_hint : u64?,
    /** Wall-clock time at boot, in seconds since the Unix epoch, if the bootloader read one. */
    boot_wall_time : i64?,
    /**
     * A page for the kernel's panic record (PanicRecord), at the same physical address every boot and listed as
     * FirmwareReserved, so the next boot finds it; null when the bootloader kept none.
     */
    panic_record : PhysicalRange?,
}

/**
 * Start a CPU in the kernel, once (docs/specs/boot_info.md, CPUs).
 *
 * On that CPU, L0 sets carrier's stack_limit for the CPU's boot stack, loads carrier, pushes the constant boot context
 * and calls entry. It doesn't wait for the CPU to start or report failure: the kernel waits for entry to report in.
 *
 * @param cpu The CPU to start: one of BootInfo.cpus other than the boot CPU, not started before.
 * @param carrier The carrier block the CPU loads; the kernel sets its program_data first, for entry to find. It has to
 *     stay valid until entry loads a carrier block of its own.
 * @param entry Where the CPU begins in the kernel, on its boot stack.
 */
StartCpu :: alias fn(cpu: ptr[BootCpu], carrier #escaping : ptr[mut runtime.CarrierBlock], entry: CpuEntry)

/** Where a started CPU begins in the kernel. */
CpuEntry :: alias fn() #never_returns

/** The kind of firmware the machine booted from. */
Firmware :: enum #backed_by(u8) {
    /** A PC BIOS. */
    Bios,
    /** 64-bit UEFI; SlopOS's own bootloader always reports this. */
    Uefi,
    /** 32-bit UEFI on a 64-bit CPU. Its runtime services can't be called from 64-bit code. */
    Uefi32,
    /** RISC-V Supervisor Binary Interface. */
    Sbi,
}

/** One region of the memory map. */
MemoryRegion :: struct {
    /** The region's physical memory, 4 KiB aligned and a whole number of 4 KiB pages. */
    range : PhysicalRange,
    /** What the memory holds, and so whether and when the kernel may use it. */
    kind : MemoryKind,
}

/** What a region of physical memory holds, which says whether the kernel may use it, and when. */
MemoryKind :: enum #backed_by(u8) {
    /** Free RAM. */
    Usable,
    /**
     * RAM holding the bootloader's data, its page tables, the CPUs' boot stacks, and BootInfo
     * with everything it points to. Free once the kernel is done with all of them.
     */
    BootReclaimable,
    /** The kernel image. Never added to the frame allocator. */
    KernelImage,
    /** The contents of boot modules. Never added to the frame allocator; handed on as memory objects. */
    BootModule,
    /** A framebuffer's memory. Never added to the frame allocator. */
    Framebuffer,
    /**
     * Firmware tables (ACPI) that can be freed once they've been read: handed to the root task as memory objects, and
     * freed when it lets them go.
     */
    FirmwareTables,
    /** Memory the firmware keeps using (ACPI NVS, UEFI runtime). Never used or freed. */
    FirmwareReserved,
    /** Reserved for any other reason. Never used or freed, and not in the direct map. */
    Reserved,
    /** RAM reported as faulty. Never used or freed, and not in the direct map. */
    Defective,
}

/** Where the kernel image is loaded. */
KernelImage :: struct {
    /** The physical memory the image is loaded in, a KernelImage region of the memory map. */
    physical : PhysicalRange,
    /** The virtual address the bootloader's page tables map the image at. */
    virtual_base : VirtualAddress,
    /** The image's loaded segments, so the kernel can map each with the right protection. */
    segments : ImageSegment[],
}

/** One loaded segment of the kernel image, from its ELF program headers. */
ImageSegment :: struct {
    /** The segment's first virtual address. */
    virtual_base : VirtualAddress,
    /** The segment's size in memory, in bytes. */
    size : u64,
    /** Whether the segment's pages are to be writable. */
    writable : bool,
    /** Whether the segment's pages are to be executable. */
    executable : bool,
}

/** One CPU, as the bootloader found it. */
BootCpu :: struct {
    /**
     * The CPU's hardware identifier: the local APIC ID on x86-64, the MPIDR affinity fields
     * on AArch64, the hart ID on RISC-V.
     */
    hardware_id : u64,
    /** The address of L0's own data for starting this CPU, whose type only L0 knows. Never read outside L0. */
    boot_handle : uintptr,
}

/** A file the bootloader loaded for the kernel to pass on: the root task, and what it needs. */
BootModule :: struct {
    /** The module's file name, without the directory. */
    name : string,
    /** The module's command line, from the boot configuration. Empty when there is none. */
    command_line : string,
    /** The module's contents. base is 4 KiB aligned; size is the exact size in bytes. */
    contents : PhysicalRange,
}

/** A linear RGB framebuffer the firmware set up. */
Framebuffer :: struct {
    /** The framebuffer's physical memory, a Framebuffer region of the memory map. */
    memory : PhysicalRange,
    /** The visible width, in pixels. */
    width : u32,
    /** The visible height, in pixels. */
    height : u32,
    /** Bytes from the start of one row to the start of the next. */
    pitch : u32,
    /** The bits one pixel takes. */
    bits_per_pixel : u16,
    /** Where red's bits are in a pixel. */
    red : ColorChannel,
    /** Where green's bits are in a pixel. */
    green : ColorChannel,
    /** Where blue's bits are in a pixel. */
    blue : ColorChannel,
    /** The display's EDID, empty when unknown; in the bootloader's mapping, like BootInfo's other arrays. */
    edid : u8[],
}

/** Where one color's bits are in a pixel. */
ColorChannel :: struct {
    /** How many bits the color has. */
    size : u8,
    /** The bit position of the color's lowest bit within the pixel. */
    shift : u8,
}

/** Physical addresses of firmware tables, each null when the firmware has none. */
FirmwareTables :: struct {
    /** The ACPI Root System Description Pointer. */
    acpi_rsdp : PhysicalAddress?,
    /** The flattened devicetree blob. */
    devicetree : PhysicalAddress?,
    /** The SMBIOS entry point. */
    smbios : PhysicalAddress?,
    /** The UEFI system table. */
    efi_system_table : PhysicalAddress?,
}
