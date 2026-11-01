/*
 * SlopOS's bootloader (roadmap B2, decisions/0131, 0133): a UEFI application, BOOTX64.EFI or BOOTAA64.EFI on the ESP,
 * in place of Limine. It reads the ESP's generations (src/generations), boots the newest, each of its files checked
 * against its hash, and hands the kernel SlopOS's own boot protocol (src/boot_protocol): the kernel loaded and relocated
 * at a random place, every module in its own pages, a direct map at a random offset, the memory map, the firmware's
 * tables and the framebuffer, then the firmware's boot services left and the kernel entered. Nothing is parsed but the
 * generation records, which generations.check checks, and the kernel's ELF; FAT is the firmware's.
 */
package bootloader

import runtime from "base"
import intrinsics from "base"
import uefi from "std/os"
import bundle from "../../bundle"
import generations from "../../generations"
import boot_info from "../../boot_info"
import boot_protocol from "../../boot_protocol"

#if TARGET_ARCH == .x86_64 {
    import x86_64 from "base/intrinsics"
}
#else {
    import aarch64 from "base/intrinsics"
}

// Memory kinds of the bootloader's, past UEFI's own, so the memory map says what each page holds
LOADER_DATA : u32 : 2
KERNEL_MEMORY : u32 : 0x80000001
MODULE_MEMORY : u32 : 0x80000002

main :: fn() -> int {
    runtime.log_info("bootloader: SlopOS's bootloader")
    services :: uefi.boot_services() or_return fail("no boot services")
    // The firmware's watchdog off, which would reset the machine after five minutes in the bootloader
    _ = services.set_watchdog_timer(0, 0, 0, null)
    root :: esp_root() or_return fail("the ESP can't be opened")
    generation := newest_generation(root) or_return fail("there's no generation on the ESP to boot")
    runtime.log_info("bootloader: booting generation %", generation.number)
    handoff_address :: allocate_pages(LOADER_DATA, cast[u64](size_of(boot_protocol.Handoff))) or_return fail("no memory for the handoff")
    handoff :: cast[ptr[mut boot_protocol.Handoff]](cast[rawptr](handoff_address))
    handoff.magic = boot_protocol.MAGIC
    handoff.size = cast[u64](size_of(boot_protocol.Handoff))
    write_command_line(handoff, &generation)
    // The boot set, each file in its own pages, checked against its hash
    for i in cast[usize](0)..<generation.files.count {
        if i >= cast[usize](generation.file_count) {
            break
        }
        file :: &generation.files[i]
        pages :: read_object(root, file.hash, MODULE_MEMORY) or_return fail("a boot-set file is missing, or isn't what its hash says")
        if handoff.module_count >= cast[u64](handoff.modules.count) {
            return fail("more boot-set files than the handoff holds")
        }
        module :: &handoff.modules[cast[usize](handoff.module_count)]
        module.name = file.name
        module.contents = boot_info.PhysicalRange.{cast[boot_info.PhysicalAddress](pages.address), pages.size}
        handoff.module_count += 1
    }
    kernel_file :: read_object(root, generation.kernel, LOADER_DATA) or_return fail("the kernel is missing, or isn't what its hash says")
    _ = root.close(root)
    random :: Random.{kaslr = generation.kaslr == 1}
    image := load_kernel(kernel_file, &random) or_return fail("the kernel isn't an ELF kernel this bootloader loads")
    handoff.kernel_physical = boot_info.PhysicalRange.{cast[boot_info.PhysicalAddress](image.physical), image.size}
    handoff.kernel_virtual_base = image.virtual_base
    for segment, i in image.segments {
        if i >= image.segment_count || i >= handoff.segments.count {
            break
        }
        handoff.segments[i] = segment
        handoff.segment_count = cast[u64](i + 1)
    }
    firmware_tables(handoff)
    framebuffer(handoff)
    entropy(handoff, &random)
    stack :: allocate_pages(LOADER_DATA, boot_protocol.BOOT_STACK_SIZE) or_return fail("no memory for the kernel's stack")
    handoff.direct_map_offset = direct_map_offset(&random)
    tables := new_tables() or_return fail("no memory for page tables")
    starting :: prepare_cpus(handoff, &tables, handoff.direct_map_offset) or_return fail("no room for the other CPUs' trampoline")
    // The memory map now, for the page tables, and again after them, just before the boot services are left
    if !map_memory(&tables, handoff.direct_map_offset) || !map(&tables, image.virtual_base, image.physical, image.size) {
        return fail("no memory for page tables")
    }
    leave_boot_services(handoff) or_return fail("the boot services couldn't be left")
    // No firmware from here: interrupts off, the other CPUs parked, then the kernel's tables and stack, and the kernel
    #if TARGET_ARCH == .x86_64 {
        x86_64.cli()
        start_cpus(handoff, starting)
        x86_64.enter(tables.root, handoff.direct_map_offset + stack + boot_protocol.BOOT_STACK_SIZE,
            image.virtual_base + image.entry, handoff.direct_map_offset + handoff_address)
    }
    #else {
        // The kernel's code, written through the data cache, where instruction fetches see it
        line := image.physical & ~cast[u64](63)
        loop {
            if line >= image.physical + image.size {
                break
            }
            aarch64.dc_cvau(cast[rawptr](line))
            line += 64
        }
        aarch64.dsb(.ISH)
        aarch64.ic_iallu()
        aarch64.dsb(.ISH)
        aarch64.isb()
        aarch64.daif_set(aarch64.DAIF_IRQ | aarch64.DAIF_FIQ | aarch64.DAIF_SERROR)
        start_cpus(handoff, starting)
        aarch64.enter(MAIR_VALUE, tcr_value(), tables.low_root, tables.root, handoff.direct_map_offset + stack + boot_protocol.BOOT_STACK_SIZE,
            image.virtual_base + image.entry, handoff.direct_map_offset + handoff_address)
    }
}

// The bootloader stopped, saying why; the firmware tries the next boot option.
fail :: fn(why: string) -> int {
    runtime.log_error("bootloader: %", why)
    return 1
}

// The newest generation on the ESP, but the recovery generation, its record checked; null if there's none.
newest_generation :: fn(root: ptr[uefi.File]) -> generations.Generation? {
    names := folder_names(root, generations.RECORDS) or_return null
    defer runtime.array_free(&names)
    newest := cast[u64](0)
    for name in names {
        number :: number_of(name) or_continue
        if number != generations.RECOVERY_NUMBER && number > newest {
            newest = number
        }
    }
    if newest == 0 {
        return null
    }
    path_storage : u8[128]
    pages :: read_file(root, generations.record_path(newest, &path_storage), LOADER_DATA) or_return null
    return generations.generation_of(view_of(cast[ptr[u8]](cast[rawptr](pages.address)), cast[usize](pages.size)))
}

// An object of the ESP's, boot/objects/<hex>, in pages of memory_kind, if its bytes have its hash.
read_object :: fn(root: ptr[uefi.File], hash: bundle.Hash, memory_kind: u32) -> Pages? {
    path_storage : u8[128]
    pages :: read_file(root, generations.object_path(hash, &path_storage), memory_kind) or_return null
    if !bundle.same(bundle.hash_of(view_of(cast[ptr[u8]](cast[rawptr](pages.address)), cast[usize](pages.size))), hash) {
        return null
    }
    return pages
}

/*
 * The kernel's command line, as Limine's entry for the generation gives it (generations.limine_conf): the generation's,
 * then its number, recovery for the recovery generation, and the store's root.
 */
write_command_line :: fn(handoff: ptr[mut boot_protocol.Handoff], generation: ptr[generations.Generation]) {
    line : u8[..]
    defer runtime.array_free(&line)
    append(&line, generations.line_of(&generation.command_line))
    digits : u8[20]
    append(&line, " generation=")
    append(&line, generations.decimal(generation.number, &digits))
    if generation.state == generations.STATE_RECOVERY {
        append(&line, " recovery")
    }
    if !bundle.same(generation.store_root, bundle.Hash.{}) {
        hex_storage : u8[64]
        append(&line, " store_root=")
        append(&line, bundle.hex(generation.store_root, &hex_storage))
    }
    for byte, i in line {
        if i < handoff.command_line.count && i + 1 < handoff.command_line.count {
            handoff.command_line[i] = byte
        }
    }
}

append :: fn(line: ptr[mut u8[..]], text: string) {
    for byte in string_bytes(text) {
        runtime.array_add(line, byte)
    }
}

// A decimal number, or null.
number_of :: fn(text: string) -> u64? {
    if text.count == 0 {
        return null
    }
    value := cast[u64](0)
    for character in text {
        if character < '0' || character > '9' {
            return null
        }
        value = value * 10 + cast[u64](character) - cast[u64]('0')
    }
    return value
}

// The firmware's tables, by their configuration tables' GUIDs.
firmware_tables :: fn(handoff: ptr[mut boot_protocol.Handoff]) {
    acpi := uefi.configuration_table(uefi.ACPI_20_GUID)
    if acpi is_none {
        acpi = uefi.configuration_table(uefi.ACPI_10_GUID)
    }
    handoff.acpi_rsdp = cast[u64](acpi or_else null)
    handoff.devicetree = cast[u64](uefi.configuration_table(uefi.DEVICE_TREE_GUID) or_else null)
    smbios := uefi.configuration_table(uefi.SMBIOS3_GUID)
    if smbios is_none {
        smbios = uefi.configuration_table(uefi.SMBIOS_GUID)
    }
    handoff.smbios = cast[u64](smbios or_else null)
    match uefi.system_table() {
        case Some(table) => handoff.efi_system_table = cast[u64](cast[rawptr](table))
        case None => {}
    }
}

// The firmware's framebuffer, if it has a linear one of 32-bit pixels.
framebuffer :: fn(handoff: ptr[mut boot_protocol.Handoff]) {
    output :: uefi.locate[uefi.GraphicsOutput](uefi.GRAPHICS_OUTPUT_GUID) or_return void
    mode :: output.mode
    info :: mode.info
    // Red, green and blue bytes, either way round; not one by masks, or none
    if info.pixel_format > 1 || mode.frame_buffer_base == 0 {
        return void
    }
    red_shift :: if info.pixel_format == 0 { cast[u8](0) } else { cast[u8](16) }
    blue_shift :: if info.pixel_format == 0 { cast[u8](16) } else { cast[u8](0) }
    handoff.framebuffer = boot_protocol.Framebuffer.{base = mode.frame_buffer_base, size = cast[u64](mode.frame_buffer_size),
        width = info.width, height = info.height, pitch = info.pixels_per_scan_line * 4, bits_per_pixel = 32,
        red_size = 8, red_shift = red_shift, green_size = 8, green_shift = 8, blue_size = 8, blue_shift = blue_shift}
    handoff.has_framebuffer = 1
}

// Random bytes for the kernel's pool, if the firmware has any to give.
entropy :: fn(handoff: ptr[mut boot_protocol.Handoff], random: ptr[Random]) {
    rng :: uefi.locate[uefi.Rng](uefi.RNG_GUID) or_return void
    if rng.get_rng(rng, null, handoff.entropy.count, &handoff.entropy[0]) == uefi.SUCCESS {
        handoff.has_entropy = 1
    }
}

// The boot CPU's hardware identifier: its initial local APIC ID.
boot_cpu_id :: fn() -> u64 {
    #if TARGET_ARCH == .x86_64 {
        return cast[u64](x86_64.cpuid(1).ebx >> 24)
    }
    #else {
        return aarch64.read_system_register(.MPIDR_EL1) & 0xff00ffffff
    }
}

/*
 * Random numbers for where the kernel and the direct map go, when the generation asks for KASLR: the firmware's RNG,
 * or with none, the CPU's. Without KASLR, always 0.
 */
Random :: struct {
    kaslr : bool,
}

random_u64 :: fn(random: ptr[Random]) -> u64 {
    if !random.kaslr {
        return 0
    }
    value : u64 = 0
    match uefi.locate[uefi.Rng](uefi.RNG_GUID) {
        case Some(rng) => {
            bytes : u8[8]
            if rng.get_rng(rng, null, 8, &bytes[0]) == uefi.SUCCESS {
                for byte, i in bytes {
                    value |= cast[u64](byte) << cast[u64](i * 8)
                }
                return value
            }
        }
        case None => {}
    }
    #if TARGET_ARCH == .x86_64 {
        return x86_64.rdrand() or_else x86_64.rdtsc()
    }
    #else {
        return aarch64.rndr() or_else aarch64.read_system_register(.CNTVCT_EL0)
    }
}

// The direct map's offset: the bottom of the higher half, a random number of GiB up, within its first 32 TiB.
direct_map_offset :: fn(random: ptr[Random]) -> u64 {
    return HIGHER_HALF + (random_u64(random) % 32768) * GIGABYTE
}
