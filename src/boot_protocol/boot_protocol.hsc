/*
 * SlopOS's own boot protocol (roadmap B2, decisions/0131, 0133): what the Hemera bootloader (src/uefi/bootloader) hands
 * the kernel's boot adapter (src/boot/slopos), which turns it into the kernel's BootInfo as src/boot/limine turns
 * Limine's responses. The bootloader is a program of its own, so this is fixed-size plain data and physical addresses,
 * read through the direct map, never a Hemera value with pointers in it; the adapter checks the magic and the size
 * first.
 *
 * At the kernel's entry, the boot CPU runs with interrupts off, on a stack of BOOT_STACK_SIZE bytes, with the
 * bootloader's page tables: the kernel image at its virtual base, every region of the memory map but reserved and
 * defective ones at direct_map_offset plus its physical address, and the same regions where they are, identity
 * mapped, for the bootloader's last instructions. The entry is called with the C convention, given the handoff's
 * address in the direct map.
 */
package boot_protocol

import boot_info from "../boot_info"

// "SLOPBOOT", little-endian
MAGIC : u64 : 0x544f4f42504f4c53
// The boot CPU's stack, and each other CPU's, when they're started (B2)
BOOT_STACK_SIZE : u64 : 64 * 1024
// The most of each the handoff carries
MAX_REGIONS :: 512
MAX_SEGMENTS :: 8
MAX_MODULES :: 32
MAX_CPUS :: 64
NAME_BYTES :: 32
COMMAND_LINE_BYTES :: 1024

// A loadable segment of the kernel, where it's mapped, already relocated.
Segment :: struct {
    virtual_base : u64,
    size : u64,
    writable : u8,
    executable : u8,
    padding : u8[6],
}

// A boot module: its file's name, as the generation names it, and where its bytes are.
Module :: struct {
    name : u8[NAME_BYTES],
    contents : boot_info.PhysicalRange,
}

// A CPU: its hardware identifier, the local APIC ID or MPIDR's affinity fields.
Cpu :: struct {
    hardware_id : u64,
}

// The framebuffer the firmware set up, if it has one: linear, 32 bits a pixel, its channels by their masks' positions.
Framebuffer :: struct {
    base : u64,
    size : u64,
    width : u32,
    height : u32,
    pitch : u32,
    bits_per_pixel : u16,
    red_size : u8,
    red_shift : u8,
    green_size : u8,
    green_shift : u8,
    blue_size : u8,
    blue_shift : u8,
}

Handoff :: struct {
    magic : u64,
    size : u64,
    // The kernel's command line, its bytes then zeros
    command_line : u8[COMMAND_LINE_BYTES],
    // Sorted, not overlapping, page-aligned and merged, as BootInfo's rules say (docs/specs/boot_info.md)
    regions : boot_info.MemoryRegion[MAX_REGIONS],
    region_count : u64,
    direct_map_offset : u64,
    // The kernel image: its physical pages, where it's mapped, its segments there
    kernel_physical : boot_info.PhysicalRange,
    kernel_virtual_base : u64,
    segments : Segment[MAX_SEGMENTS],
    segment_count : u64,
    modules : Module[MAX_MODULES],
    module_count : u64,
    // Every CPU, the boot CPU first
    cpus : Cpu[MAX_CPUS],
    cpu_count : u64,
    framebuffer : Framebuffer,
    has_framebuffer : u8,
    has_entropy : u8,
    padding : u8[6],
    entropy : u8[32],
    // The firmware tables' physical addresses, 0 for none
    acpi_rsdp : u64,
    devicetree : u64,
    smbios : u64,
    efi_system_table : u64,
    /*
     * Room the kernel's boot adapter fills with BootInfo's arrays, which point at the handoff's own fields, so it
     * needs no memory of its own; the bootloader leaves it zeroed
     */
    image_segments : boot_info.ImageSegment[MAX_SEGMENTS],
    boot_modules : boot_info.BootModule[MAX_MODULES],
    boot_cpus : boot_info.BootCpu[MAX_CPUS],
    framebuffers : boot_info.Framebuffer[1],
}

// Whether bytes, at least a handoff's size, are one: its magic and size.
is_handoff :: fn(handoff: ptr[Handoff]) -> bool {
    return handoff.magic == MAGIC && handoff.size == cast[u64](size_of(Handoff))
}
