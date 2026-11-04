/**
 * SlopOS's bootloader (roadmap B, decisions/0131, 0133, 0134, 0135): a UEFI application, BOOTX64.EFI or BOOTAA64.EFI on
 * the ESP of a disk or an ISO's El Torito image. It reads the ESP's generations (src/generations), boots the newest,
 * each of its files checked against its hash, and hands the kernel SlopOS's own boot protocol (src/boot_protocol): the
 * kernel loaded and relocated at a random place, every module in its own pages, a direct map at a random offset, the
 * memory map, the firmware's tables and the framebuffer, then the firmware's boot services left and the kernel
 * entered. Nothing is parsed but the generation records, which generations.check checks, and the kernel's ELF; FAT is
 * the firmware's.
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

/** The key that boots the recovery generation, held or pressed as the machine starts; its capital does too. */
RECOVERY_KEY :: 'r'
// How long the bootloader looks for it: 100 ms, in steps
/** How many steps the bootloader looks for RECOVERY_KEY in, ended early by the first key it sees. */
KEY_WINDOW_STEPS :: 10
/** How long each step of looking for RECOVERY_KEY waits, in microseconds: 10 ms. */
KEY_WINDOW_STEP_MICROSECONDS : usize : 10000
/**
 * The seed file (decisions/0131): random bytes kept on the ESP, mixed into the entropy the kernel's pool starts from,
 * and replaced every boot, so a machine whose firmware has no RNG still boots differently each time.
 *
 * The path is from the ESP's root; the file is 32 bytes, and one of another size is ignored and replaced.
 */
SEED_PATH :: "EFI/SlopOS/SEED"

// Memory kinds of the bootloader's, past UEFI's own, so the memory map says what each page holds
/**
 * UEFI's EfiLoaderData memory type: the bootloader's own allocations, which the kernel gets as boot-reclaimable
 * memory.
 */
LOADER_DATA : u32 : 2
/** The memory type of the kernel image's pages, in the OS-defined range; the kernel gets them as KernelImage. */
KERNEL_MEMORY : u32 : 0x80000001
/** The memory type of the boot modules' pages, in the OS-defined range; the kernel gets them as BootModule. */
MODULE_MEMORY : u32 : 0x80000002
/**
 * The memory type of the panic record's page, in the OS-defined range; the kernel gets it as FirmwareReserved, so
 * nothing allocates it.
 */
PANIC_MEMORY : u32 : 0x80000003

/*
 * Where the panic record's page is kept (boot_info.PanicRecord), the same every boot so the next finds it: low in
 * RAM, which the firmware, allocating from the top, leaves alone
 */
#if TARGET_ARCH == .x86_64 {
    /** The panic record page's physical address on x86-64: 4 MiB, 4096-aligned. */
    PANIC_RECORD_AT : u64 : 0x400000
}
#else {
    /** The panic record page's physical address on AArch64: 4 MiB above 0x40000000, where RAM starts on QEMU's virt. */
    PANIC_RECORD_AT : u64 : 0x40400000
}
/**
 * Where the ESP keeps the last panic record's text, from its root: the record's whole text field, the text then zeros,
 * written over each time the boot before left a sealed record.
 */
LAST_PANIC_PATH :: "EFI/SlopOS/LAST_PANIC"

/**
 * Boot SlopOS: choose a generation, load its boot set and kernel, build the handoff and page tables, leave the
 * firmware's boot services, start the other CPUs and enter the kernel.
 *
 * Runs as a UEFI application on the boot CPU, with boot services, until it leaves them; from then nothing of the
 * firmware's is called and interrupts are masked. Pages allocated before a failure aren't freed.
 *
 * @return 1, after logging why, when booting failed before the boot services were left, so the firmware tries its
 *     next boot option. Once the kernel is entered it doesn't return.
 */
main :: fn() -> int {
    runtime.log_info("bootloader: SlopOS's bootloader")
    services :: uefi.boot_services() or_return fail("no boot services")
    // The firmware's watchdog off, which would reset the machine after five minutes in the bootloader
    _ = services.set_watchdog_timer(0, 0, 0, null)
    root :: esp_root() or_return fail("the ESP can't be opened")
    generation := choose_generation(root) or_return fail("there's no generation on the ESP to boot")
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
    keep_panic_record(root, handoff)
    kernel_file :: read_object(root, generation.kernel, LOADER_DATA) or_return fail("the kernel is missing, or isn't what its hash says")
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
    entropy(handoff, root)
    _ = root.close(root)
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

/**
 * Log why the bootloader stopped, as an error on the firmware's console.
 *
 * @param why What went wrong, a phrase that follows "bootloader: ".
 * @return 1, main's result for a failure, so the firmware tries the next boot option.
 */
fail :: fn(why: string) -> int {
    runtime.log_error("bootloader: %", why)
    return 1
}

/**
 * Choose the generation to boot (roadmap B3, decisions/0131).
 *
 * The recovery generation if a key asks for it; otherwise the newest whose record checks out but the recovery
 * generation, a tentative one only with tries left, one taken from it and its record written back before it boots, so
 * one that never comes up healthy runs out and the one before it boots instead; the recovery generation once none is
 * left. A tentative generation whose record can't be written back is skipped, so a read-only ESP boots only the
 * others. Records whose names aren't decimal numbers, or that don't check out, are skipped.
 *
 * @param root The ESP's root folder, open, which has to be writable for a tentative generation to boot.
 * @return The generation, its record checked and, for a tentative one, its try already counted on the ESP; null if
 *     the records folder can't be listed and no key asked for recovery, or the recovery generation is needed but
 *     missing or doesn't check out.
 */
choose_generation :: fn(root: ptr[uefi.File]) -> generations.Generation? {
    if recovery_asked() {
        runtime.log_info("bootloader: the recovery generation, as a key asks")
        return read_generation(root, generations.RECOVERY_NUMBER)
    }
    names := folder_names(root, generations.RECORDS) or_return null
    defer runtime.array_free(&names)
    // Newest first, each time the newest below the one tried last
    below := generations.RECOVERY_NUMBER
    loop {
        newest := cast[u64](0)
        for name in names {
            number :: number_of(name) or_continue
            if number < below && number > newest {
                newest = number
            }
        }
        if newest == 0 {
            break
        }
        below = newest
        found := read_generation(root, newest) or_continue
        if found.state != generations.STATE_TENTATIVE {
            return found
        }
        if found.tries_left == 0 {
            runtime.log_info("bootloader: generation % never came up healthy in its tries, so the one before it boots", found.number)
            continue
        }
        found.tries_left -= 1
        path_storage : u8[128]
        if !write_file(root, generations.record_path(found.number, &path_storage), generations.bytes_of(&found)) {
            runtime.log_error("bootloader: generation %'s try can't be counted, so it isn't booted", found.number)
            continue
        }
        runtime.log_info("bootloader: generation % is tentative, % tries left after this one", found.number, found.tries_left)
        return found
    }
    runtime.log_info("bootloader: no generation is left to boot but the recovery generation")
    return read_generation(root, generations.RECOVERY_NUMBER)
}

/**
 * Read a generation's record from the ESP and check it.
 *
 * The record's pages, boot-reclaimable, aren't freed; the generation returned is a copy.
 *
 * @param root The ESP's root folder, open.
 * @param number The generation's number, which names its record's file (generations.record_path);
 *     generations.RECOVERY_NUMBER for the recovery generation.
 * @return The generation; null if its record isn't there, can't be read, or generations.generation_of rejects it.
 */
read_generation :: fn(root: ptr[uefi.File], number: u64) -> generations.Generation? {
    path_storage : u8[128]
    pages :: read_file(root, generations.record_path(number, &path_storage), LOADER_DATA) or_return null
    return generations.generation_of(view_of(cast[ptr[u8]](cast[rawptr](pages.address)), cast[usize](pages.size)))
}

/**
 * Tell whether RECOVERY_KEY, or its capital, is typed on the console as the bootloader starts.
 *
 * Looks for up to KEY_WINDOW_STEPS steps of KEY_WINDOW_STEP_MICROSECONDS; the first step that finds any key ends the
 * look, and takes up to 64 keys waiting, so they don't reach the kernel.
 *
 * @return True if a key seen in that step was RECOVERY_KEY or its capital; false if none was, no key came within the
 *     window, or boot services are gone.
 */
recovery_asked :: fn() -> bool {
    services :: uefi.boot_services() or_return false
    // A firmware's console may take what's typed a moment to see, so a short window, ended by the first key
    for wait in 0..<KEY_WINDOW_STEPS {
        found := false
        asked := false
        for i in 0..<64 {
            match uefi.key_waiting() {
                case Some(key) => {
                    found = true
                    if key.unicode == cast[u16](RECOVERY_KEY) || key.unicode == cast[u16](RECOVERY_KEY) - 32 {
                        asked = true
                    }
                }
                case None => break
            }
        }
        if found {
            return asked
        }
        _ = services.stall(KEY_WINDOW_STEP_MICROSECONDS)
    }
    return false
}

/**
 * Claim the panic record's page for the kernel, keeping what the boot before left in it.
 *
 * The page is at PANIC_RECORD_AT if the firmware leaves it there. If it holds a sealed record from the boot before,
 * its whole text field, the text's bytes then zeros, is written as LAST_PANIC_PATH on the ESP, and the text is handed
 * to the kernel as the module boot_info.LAST_PANIC_MODULE when the handoff has room for a module; then the page is
 * zeroed for this boot. If PANIC_RECORD_AT can't be had, a page anywhere is used, which the next boot won't look at,
 * or none if no page can be had. Failing to write the ESP is logged, not fatal.
 *
 * @param root The ESP's root folder, open; written to only when there's a record.
 * @param handoff The handoff, whose panic_record gets the page's physical address, or 0 without one, and which may get
 *     a module.
 */
keep_panic_record :: fn(root: ptr[uefi.File], handoff: ptr[mut boot_protocol.Handoff]) {
    services :: uefi.boot_services() or_return void
    address := PANIC_RECORD_AT
    if services.allocate_pages(cast[u32](uefi.AllocateKind.Address), PANIC_MEMORY, 1, &address) != uefi.SUCCESS {
        // Somewhere else, which the next boot won't look at, but this one's panic still shows on the console
        handoff.panic_record = allocate_pages(PANIC_MEMORY, 4096) or_else 0
        return void
    }
    record :: cast[ptr[mut boot_info.PanicRecord]](cast[rawptr](address))
    match boot_info.panic_record_text(record) {
        case Some(text) => {
            if !write_file(root, LAST_PANIC_PATH, record.text[0..<record.text.count]) {
                runtime.log_error("bootloader: the last panic record can't be kept on the ESP")
            }
            if handoff.module_count < cast[u64](handoff.modules.count) && text.count > 0 {
                match allocate_pages(MODULE_MEMORY, cast[u64](text.count)) {
                    case Some(pages) => {
                        for character, i in text {
                            cast[ptr[mut u8]](cast[rawptr](pages + cast[u64](i)))^ = cast[u8](character)
                        }
                        at :: cast[usize](handoff.module_count)
                        if at < handoff.modules.count {
                            module :: &handoff.modules[at]
                            for character, i in boot_info.LAST_PANIC_MODULE {
                                if i < module.name.count {
                                    module.name[i] = cast[u8](character)
                                }
                            }
                            module.contents = boot_info.PhysicalRange.{cast[boot_info.PhysicalAddress](pages), cast[u64](text.count)}
                            handoff.module_count += 1
                        }
                    }
                    case None => {}
                }
            }
            runtime.log_info("bootloader: the boot before stopped for a fault, its panic record kept as %", LAST_PANIC_PATH)
        }
        case None => {}
    }
    zero(address, 4096)
    handoff.panic_record = address
}

/**
 * Read an object of the ESP's, boot/objects/<hex>, and check its bytes against its hash.
 *
 * @param root The ESP's root folder, open.
 * @param hash The object's hash, which names its file and which its bytes have to have.
 * @param memory_kind The UEFI memory type of the pages it's read into, which says what the kernel gets them as.
 * @return The object's pages and size; null if it's missing, can't be read, or its bytes don't have its hash, in which
 *     case pages already read aren't freed.
 */
read_object :: fn(root: ptr[uefi.File], hash: bundle.Hash, memory_kind: u32) -> Pages? {
    path_storage : u8[128]
    pages :: read_file(root, generations.object_path(hash, &path_storage), memory_kind) or_return null
    if !bundle.same(bundle.hash_of(view_of(cast[ptr[u8]](cast[rawptr](pages.address)), cast[usize](pages.size))), hash) {
        return null
    }
    return pages
}

/**
 * Write the kernel's command line into the handoff.
 *
 * It's the generation's command line, then " generation=" and its number in decimal, " recovery" for the recovery
 * generation, and " store_root=" and the store's root hash in hex when it has one. What doesn't fit in
 * handoff.command_line with a zero after it is cut off.
 *
 * @param handoff The handoff, its command_line zeroed beforehand; the bytes after the line are left zero.
 * @param generation The generation being booted.
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

/**
 * Append text's bytes to a growing line.
 *
 * @param line The line, grown with context's allocator.
 * @param text The text, its bytes appended as they are.
 */
append :: fn(line: ptr[mut u8[..]], text: string) {
    for byte in string_bytes(text) {
        runtime.array_add(line, byte)
    }
}

/**
 * Parse a decimal number, as a generation's record's file name is.
 *
 * @param text The text: ASCII digits only, without a sign or spaces.
 * @return Its value, which wraps past the largest u64 without being checked; null if text is empty or has anything but
 *     digits.
 */
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

/**
 * Find the firmware's tables in its configuration tables, by their GUIDs, and put their addresses in the handoff.
 *
 * ACPI's RSDP is the 2.0 one if there is one, else the 1.0 one; SMBIOS's entry point the 3.0 one, else the older one.
 * Each address is physical, and 0 when the firmware has no such table.
 *
 * @param handoff The handoff, whose acpi_rsdp, devicetree, smbios and efi_system_table are written.
 */
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

/**
 * Describe the firmware's framebuffer in the handoff, if it has a linear one of 32-bit pixels.
 *
 * Only Graphics Output's red-green-blue and blue-green-red formats, 8 bits a channel, are taken; one described by bit
 * masks, one that's only blitted to, or none at all leaves has_framebuffer 0.
 *
 * @param handoff The handoff, whose framebuffer, its base a physical address, and has_framebuffer are written.
 */
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

/**
 * Gather random bytes for the kernel's pool, and write the next boot's seed.
 *
 * The firmware's RNG's 32 bytes, the seed file's 32 and the CPU's counter are hashed together. The kernel's bytes and
 * the next seed are each hashed from that apart, so one doesn't tell the other; the next seed is written before the
 * kernel boots, so no two boots start from the same seed. An ESP that can't be written, as an ISO's, is logged, not
 * fatal.
 *
 * @param handoff The handoff, whose entropy is written, and has_entropy set to 1 if the RNG or the seed file
 *     contributed, 0 if only the counter did.
 * @param root The ESP's root folder, open, which SEED_PATH is read from and written to.
 */
entropy :: fn(handoff: ptr[mut boot_protocol.Handoff], root: ptr[uefi.File]) {
    // The firmware's bytes, the seed's and the counter, then a byte saying which of the two hashes
    mixed : u8[73]
    sources := 0
    seeded := false
    match uefi.locate[uefi.Rng](uefi.RNG_GUID) {
        case Some(rng) => {
            if rng.get_rng(rng, null, 32, &mixed[0]) == uefi.SUCCESS {
                sources += 1
            }
        }
        case None => {}
    }
    match read_file(root, SEED_PATH, LOADER_DATA) {
        case Some(seed) => {
            if seed.size == 32 {
                for i in cast[usize](0)..<32 {
                    mixed[32 + i] = cast[ptr[u8]](cast[rawptr](seed.address + cast[u64](i)))^
                }
                sources += 1
                seeded = true
            }
        }
        case None => {}
    }
    counter :: cpu_counter()
    for i in cast[usize](0)..<8 {
        mixed[64 + i] = cast[u8](counter >> cast[u64](i * 8))
    }
    mixed[72] = 1
    handoff.entropy = bundle.hash_of(mixed[0..<mixed.count]).bytes
    handoff.has_entropy = if sources > 0 { 1 } else { 0 }
    mixed[72] = 2
    next :: bundle.hash_of(mixed[0..<mixed.count])
    if !write_file(root, SEED_PATH, next.bytes[0..<next.bytes.count]) {
        // As an ISO's can't be
        runtime.log_info("bootloader: the ESP can't be written, so there's no next seed")
    }
    else if seeded {
        runtime.log_info("bootloader: the seed file mixed in, and replaced")
    }
    else {
        runtime.log_info("bootloader: a seed file written, for the next boot")
    }
}

/**
 * Read the CPU's counter, a little entropy and a fallback for randomness.
 *
 * @return The time-stamp counter on x86-64, the virtual counter, CNTVCT_EL0, on AArch64: ticks since an unspecified
 *     start, at a rate the CPU sets.
 */
cpu_counter :: fn() -> u64 {
    #if TARGET_ARCH == .x86_64 {
        return x86_64.rdtsc()
    }
    #else {
        return aarch64.read_system_register(.CNTVCT_EL0)
    }
}

/**
 * Read the boot CPU's hardware identifier, as boot_protocol.Cpu's hardware_id holds it.
 *
 * @return On x86-64 its initial local APIC ID from CPUID leaf 1, 0 to 255; on AArch64 its MPIDR_EL1's affinity fields,
 *     Aff3 and Aff2 to Aff0 with the other bits cleared, as PSCI's CPU_ON and the device tree's cpu nodes name it.
 */
boot_cpu_id :: fn() -> u64 {
    #if TARGET_ARCH == .x86_64 {
        return cast[u64](x86_64.cpuid(1).ebx >> 24)
    }
    #else {
        return aarch64.read_system_register(.MPIDR_EL1) & 0xff00ffffff
    }
}

/**
 * Random numbers for where the kernel and the direct map go, when the generation asks for KASLR: the firmware's RNG,
 * or with none, the CPU's. Without KASLR, always 0.
 */
Random :: struct {
    /** Whether the generation asks for KASLR; false makes every number 0, so the kernel and direct map don't move. */
    kaslr : bool,
}

/**
 * Draw a random number for placing the kernel or the direct map.
 *
 * Boot services have to be running. It's the firmware's RNG's if it has one that answers; otherwise RDRAND or RNDR
 * where the CPU has it, else the CPU's counter, which is hardly random.
 *
 * @param random Whether KASLR is on.
 * @return Any u64 when KASLR is on; 0 when it's off.
 */
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
        // RDRAND only where CPUID says there is one (leaf 1, ECX bit 30): the bootloader runs on any x86-64, so the
        // kernel can be the one to refuse a CPU below its baseline
        if x86_64.cpuid(1).ecx & (1 << 30) != 0 {
            return x86_64.rdrand() or_else x86_64.rdtsc()
        }
        return x86_64.rdtsc()
    }
    #else {
        // RNDR only where ID_AA64ISAR0_EL1 has FEAT_RNG (bits 63:60), as on x86-64 for RDRAND
        if aarch64.read_system_register(.ID_AA64ISAR0_EL1) >> 60 != 0 {
            return aarch64.rndr() or_else aarch64.read_system_register(.CNTVCT_EL0)
        }
        return aarch64.read_system_register(.CNTVCT_EL0)
    }
}

/**
 * Choose the direct map's offset: the bottom of the higher half, a random number of GiB up, within its first 32 TiB.
 *
 * @param random Whether KASLR is on; without it the offset is HIGHER_HALF itself.
 * @return The virtual address physical address 0 is mapped at, 1 GiB-aligned, from HIGHER_HALF up to HIGHER_HALF plus
 *     32 TiB less 1 GiB.
 */
direct_map_offset :: fn(random: ptr[Random]) -> u64 {
    return HIGHER_HALF + (random_u64(random) % 32768) * GIGABYTE
}
