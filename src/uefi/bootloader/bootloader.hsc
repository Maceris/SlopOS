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

// The key that boots the recovery generation, held or pressed as the machine starts
RECOVERY_KEY :: 'r'
// How long the bootloader looks for it: 100 ms, in steps
KEY_WINDOW_STEPS :: 10
KEY_WINDOW_STEP_MICROSECONDS : usize : 10000
/*
 * The seed file (decisions/0131): random bytes kept on the ESP, mixed into the entropy the kernel's pool starts from,
 * and replaced every boot, so a machine whose firmware has no RNG still boots differently each time
 */
SEED_PATH :: "EFI/SlopOS/SEED"

// Memory kinds of the bootloader's, past UEFI's own, so the memory map says what each page holds
LOADER_DATA : u32 : 2
KERNEL_MEMORY : u32 : 0x80000001
MODULE_MEMORY : u32 : 0x80000002
PANIC_MEMORY : u32 : 0x80000003

/*
 * Where the panic record's page is kept (boot_info.PanicRecord), the same every boot so the next finds it: low in
 * RAM, which the firmware, allocating from the top, leaves alone
 */
#if TARGET_ARCH == .x86_64 {
    PANIC_RECORD_AT : u64 : 0x400000
}
#else {
    PANIC_RECORD_AT : u64 : 0x40400000
}
// Where the ESP keeps the last panic record's text
LAST_PANIC_PATH :: "EFI/SlopOS/LAST_PANIC"

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

// The bootloader stopped, saying why; the firmware tries the next boot option.
fail :: fn(why: string) -> int {
    runtime.log_error("bootloader: %", why)
    return 1
}

/*
 * The generation to boot (roadmap B3, decisions/0131): the recovery generation if a key asks for it; otherwise the
 * newest whose record checks out but the recovery generation, a tentative one only with tries left, one taken from it
 * and its record written back before it boots, so one that never comes up healthy runs out and the one before it boots
 * instead; the recovery generation once none is left. Null if there's not even that.
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

// The generation numbered number, its record checked, or null.
read_generation :: fn(root: ptr[uefi.File], number: u64) -> generations.Generation? {
    path_storage : u8[128]
    pages :: read_file(root, generations.record_path(number, &path_storage), LOADER_DATA) or_return null
    return generations.generation_of(view_of(cast[ptr[u8]](cast[rawptr](pages.address)), cast[usize](pages.size)))
}

// RECOVERY_KEY, or its capital, typed on the console as the bootloader starts, every key waiting taken.
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

/*
 * The panic record's page, at PANIC_RECORD_AT if the firmware leaves it there, for the kernel: what it holds, if it's
 * a sealed record from the boot before, kept as LAST_PANIC_PATH on the ESP, the text's bytes then zeros, and handed
 * to the kernel as the module boot_info.LAST_PANIC_MODULE; then it's emptied for this boot.
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

/*
 * Random bytes for the kernel's pool: the firmware's RNG's, the seed file's and the CPU's counter, hashed together. The
 * kernel's bytes and the next seed are each hashed from that apart, so one doesn't tell the other; the next seed is
 * written before the kernel boots, so no two boots start from the same seed.
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
        runtime.log_error("bootloader: the next seed can't be written")
    }
    else if seeded {
        runtime.log_info("bootloader: the seed file mixed in, and replaced")
    }
    else {
        runtime.log_info("bootloader: a seed file written, for the next boot")
    }
}

// The CPU's cycle or virtual counter.
cpu_counter :: fn() -> u64 {
    #if TARGET_ARCH == .x86_64 {
        return x86_64.rdtsc()
    }
    #else {
        return aarch64.read_system_register(.CNTVCT_EL0)
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
