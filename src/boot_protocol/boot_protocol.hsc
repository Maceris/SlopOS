/**
 * SlopOS's own boot protocol (roadmap B2, decisions/0131, 0133): what the Hemera bootloader (src/uefi/bootloader)
 * hands the kernel's boot adapter (src/boot/slopos), which turns it into the kernel's BootInfo. The bootloader is a
 * program of its own, so this is fixed-size plain data and physical addresses, read through the direct map, never a
 * Hemera value with pointers in it; the adapter checks the magic and the size first.
 *
 * At the kernel's entry, the boot CPU runs with interrupts off, on a stack of BOOT_STACK_SIZE bytes, with the
 * bootloader's page tables: the kernel image at its virtual base, every region of the memory map but reserved and
 * defective ones at direct_map_offset plus its physical address, and the same regions where they are, identity
 * mapped, for the bootloader's last instructions. The entry is called with the C convention, given the handoff's
 * address in the direct map.
 */
package boot_protocol

import boot_info from "../boot_info"

/** The handoff's first word, "SLOPBOOT" read as a little-endian u64, which says it is one. */
MAGIC : u64 : 0x544f4f42504f4c53
/** The size in bytes of the boot CPU's stack, and of each other CPU's when they're started (B2): 64 KiB. */
BOOT_STACK_SIZE : u64 : 64 * 1024
/** The most memory map regions the handoff carries, after merging. */
MAX_REGIONS :: 512
/** The most loadable segments of the kernel image the handoff carries. */
MAX_SEGMENTS :: 8
/**
 * The most boot modules the handoff carries: a generation's boot set, as many as an ISO carries, and the
 * bootloader's own, last_panic.
 */
MAX_MODULES :: 128
/** The most CPUs the handoff carries, the boot CPU included; the bootloader starts no more than this many. */
MAX_CPUS :: 64
/** The bytes of a module's name, which is cut off at this length; a shorter one is followed by zeros. */
NAME_BYTES :: 32
/** The bytes of the kernel's command line, which is cut off to leave room for a zero after it. */
COMMAND_LINE_BYTES :: 1024

/** A loadable segment of the kernel, where it's mapped, already relocated. */
Segment :: struct {
    /** The virtual address the segment is mapped at. */
    virtual_base : u64,
    /** The segment's size in memory, in bytes. */
    size : u64,
    /** 1 if the segment is mapped writable, 0 if read-only. */
    writable : u8,
    /** 1 if the segment is mapped executable, 0 if not. */
    executable : u8,
    /** Unused, so the struct's size is a multiple of 8. */
    padding : u8[6],
}

/** A boot module: its file's name, as the generation names it, and where its bytes are. */
Module :: struct {
    /** The module's file name, its bytes then zeros; a name of NAME_BYTES bytes has no zero after it. */
    name : u8[NAME_BYTES],
    /** The physical pages the bootloader loaded the file's bytes into, and how many bytes the file has. */
    contents : boot_info.PhysicalRange,
}

/**
 * A CPU: its hardware identifier, the local APIC ID or MPIDR's affinity fields; and, but for the boot CPU, its mailbox.
 *
 * The bootloader starts every other CPU before it enters the kernel and parks it, on its own stack of BOOT_STACK_SIZE
 * bytes, with interrupts off and the bootloader's page tables, until goto_address isn't 0: then it jumps there, with
 * argument as its first argument in the C convention. The kernel writes argument, then goto_address, with release
 * order. Its fields' places are the trampoline's, so they don't move.
 */
Cpu :: struct {
    /**
     * Where a parked CPU jumps, a virtual address, which the kernel writes last, with release order; 0 until then,
     * and never used for the boot CPU, which isn't parked.
     */
    goto_address : u64,
    /** The top of the CPU's stack, a virtual address in the direct map; 0 for the boot CPU, which runs the entry's. */
    stack_top : u64,
    /** The word the CPU is given as its first argument when it jumps to goto_address, written by the kernel. */
    argument : u64,
    /** The CPU's hardware identifier: its local APIC ID on x86-64, or its MPIDR's affinity fields on AArch64. */
    hardware_id : u64,
}

/**
 * The framebuffer the firmware set up, if it has one: linear, 32 bits a pixel, its channels by their masks' positions.
 */
Framebuffer :: struct {
    /** The physical address of the framebuffer's memory. */
    base : u64,
    /** The framebuffer's memory, in bytes. */
    size : u64,
    /** The visible width, in pixels. */
    width : u32,
    /** The visible height, in pixels. */
    height : u32,
    /** Bytes from the start of one row to the start of the next. */
    pitch : u32,
    /** The bits one pixel takes, 32. */
    bits_per_pixel : u16,
    /** How many bits red has in a pixel. */
    red_size : u8,
    /** The bit position of red's lowest bit within a pixel. */
    red_shift : u8,
    /** How many bits green has in a pixel. */
    green_size : u8,
    /** The bit position of green's lowest bit within a pixel. */
    green_shift : u8,
    /** How many bits blue has in a pixel. */
    blue_size : u8,
    /** The bit position of blue's lowest bit within a pixel. */
    blue_shift : u8,
}

/**
 * What the bootloader hands the kernel's entry, in memory it allocated, given by its address in the direct map.
 *
 * The bootloader fills everything up to panic_record; the rest is room the kernel's boot adapter fills itself.
 */
Handoff :: struct {
    /** MAGIC, which says this is a handoff. */
    magic : u64,
    /** The handoff's size in bytes, size_of(Handoff), so a handoff of another layout is refused. */
    size : u64,
    /** The kernel's command line, its bytes then zeros. */
    command_line : u8[COMMAND_LINE_BYTES],
    /**
     * The memory map, its first region_count used: sorted, not overlapping, page-aligned and merged, as BootInfo's
     * rules say (docs/specs/boot_info.md).
     */
    regions : boot_info.MemoryRegion[MAX_REGIONS],
    /** How many of regions are used, at most MAX_REGIONS. */
    region_count : u64,
    /** What's added to a physical address to give its virtual address in the direct map. */
    direct_map_offset : u64,
    /** The kernel image's physical pages. */
    kernel_physical : boot_info.PhysicalRange,
    /** The virtual address the kernel image is mapped at. */
    kernel_virtual_base : u64,
    /** The kernel image's loadable segments, where they're mapped, their first segment_count used. */
    segments : Segment[MAX_SEGMENTS],
    /** How many of segments are used, at most MAX_SEGMENTS. */
    segment_count : u64,
    /** The boot modules, their first module_count used. */
    modules : Module[MAX_MODULES],
    /** How many of modules are used, at most MAX_MODULES. */
    module_count : u64,
    /** Every CPU, the boot CPU first, their first cpu_count used. */
    cpus : Cpu[MAX_CPUS],
    /** How many of cpus are used, at least 1 (the boot CPU) and at most MAX_CPUS. */
    cpu_count : u64,
    /** The framebuffer, which means something only when has_framebuffer is 1. */
    framebuffer : Framebuffer,
    /** 1 if the firmware set up a framebuffer, which framebuffer describes; 0 if not. */
    has_framebuffer : u8,
    /** 1 if entropy holds random bytes from the firmware's RNG or the seed file, 0 if there were none. */
    has_entropy : u8,
    /** Unused, so entropy is 8-byte aligned. */
    padding : u8[6],
    /** Random bytes for the kernel's entropy pool to start from, when has_entropy is 1. */
    entropy : u8[32],
    /** The ACPI RSDP's physical address, 0 for none. */
    acpi_rsdp : u64,
    /** The devicetree's physical address, 0 for none. */
    devicetree : u64,
    /** The SMBIOS entry point's physical address, 0 for none. */
    smbios : u64,
    /** The EFI system table's physical address, 0 for none. */
    efi_system_table : u64,
    /** The panic record's page (boot_info.PanicRecord), 0 for none. */
    panic_record : u64,
    /*
     * Room the kernel's boot adapter fills with BootInfo's arrays, which point at the handoff's own fields, so it
     * needs no memory of its own; the bootloader leaves it zeroed.
     */
    /** Room for BootInfo's kernel image segments, which the adapter makes from segments. */
    image_segments : boot_info.ImageSegment[MAX_SEGMENTS],
    /** Room for BootInfo's boot modules, which the adapter makes from modules. */
    boot_modules : boot_info.BootModule[MAX_MODULES],
    /** Room for BootInfo's CPUs, which the adapter makes from cpus. */
    boot_cpus : boot_info.BootCpu[MAX_CPUS],
    /** What the adapter keeps for each CPU it starts, of its own type, in words: 4 words a CPU. */
    starting : u64[MAX_CPUS * 4],
    /** Room for BootInfo's framebuffer, which the adapter makes from framebuffer when there's one. */
    framebuffers : boot_info.Framebuffer[1],
}

/**
 * Tell whether memory holds a handoff of this layout, by its magic and size, before anything else of it is read.
 *
 * @param handoff The handoff's address, which has to be readable for at least size_of(Handoff) bytes.
 * @return True if its magic is MAGIC and its size is this Handoff's, false if either isn't, as for one from another
 *     version of this protocol.
 */
is_handoff :: fn(handoff: ptr[Handoff]) -> bool {
    return handoff.magic == MAGIC && handoff.size == cast[u64](size_of(Handoff))
}
