/*
 * The boot adapter for SlopOS's own boot protocol (L0, roadmap B2, decisions/0131, 0133, src/boot_protocol): the kernel's
 * entry point when the Hemera bootloader (src/uefi/bootloader) boots it. It sets up a carrier block and the boot context,
 * turns the bootloader's handoff into a BootInfo, and calls the portable kernel entry, as src/boot/limine does for
 * Limine. BootInfo's arrays and strings point into the handoff, which is in boot-reclaimable memory, through the direct
 * map, so it needs no memory of its own.
 */
package slopos_boot

import intrinsics from "base"
import runtime from "base"
import text_buffer from "std"
import boot_info from "../../boot_info"
import boot_protocol from "../../boot_protocol"
import kernel from "../../kernel"

#if TARGET_ARCH == .x86_64 {
    import arch from "../../arch/x86_64"
}
#else_if TARGET_ARCH == .arm64 {
    import arch from "../../arch/aarch64"
}

// A logger for the boot context, writing straight to the architecture's early console, as Limine's adapter's does.
EARLY_LOGGER :: runtime.Logger.{
    data = null,
    trace = early_log,
    debug = early_log,
    info = early_log,
    warn = early_log,
    error = early_log,
    fatal = early_log,
    name = "early",
}

early_log : runtime.LogFunction : fn(format_string: string, params: any..., location := #caller_location) {
    storage : u8[256]
    line := text_buffer.make(storage)
    text_buffer.append(&line, "[boot] ")
    text_buffer.append_format(&line, format_string, params)
    if line.truncated {
        text_buffer.append(&line, "...")
    }
    text_buffer.append(&line, "\n")
    arch.early_console_write(text_buffer.as_string(&line))
}

// The stack the bootloader gave the boot CPU is boot_protocol.BOOT_STACK_SIZE bytes, and this runs at most this far below its top
BOOT_STACK_SLACK :: 4096

/*
 * Where the bootloader enters the kernel, on the boot CPU's boot stack, with interrupts disabled, given the handoff's
 * address in the direct map, with the C convention, and without a carrier block or a context.
 */
kernel_entry #calling_convention(.c) #no_context :: fn(handoff_address: u64) #never_returns {
    carrier : runtime.CarrierBlock
    stack :: cast[u64](intrinsics.stack_pointer())
    carrier.stack_limit = cast[rawptr](stack - boot_protocol.BOOT_STACK_SIZE + BOOT_STACK_SLACK + runtime.STACK_GUARD)
    carrier.native_stack_limit = carrier.stack_limit
    intrinsics.set_carrier(&carrier)
    push_context boot from runtime.MINIMAL_CONTEXT {
        push_context early (logger = &EARLY_LOGGER, log_level = .INFO) {
            handoff :: cast[ptr[mut boot_protocol.Handoff]](handoff_address)
            if !boot_protocol.is_handoff(handoff) {
                kernel.boot_failed("", "the bootloader's handoff isn't one, or isn't this kernel's version")
            }
            tables :: firmware_tables(handoff)
            arch.early_console_init(handoff.direct_map_offset, &tables)
            info : boot_info.BootInfo
            build_boot_info(handoff_address, &info)
            kernel.boot(&info)
        }
    }
}

/*
 * BootInfo from the handoff at handoff_address, in the direct map, its arrays in the handoff's room for them
 * (boot_protocol.Handoff): by its address, so what points into it points into the direct map, never this stack.
 */
build_boot_info :: fn(handoff_address: u64, info: ptr[mut boot_info.BootInfo]) {
    handoff :: cast[ptr[mut boot_protocol.Handoff]](handoff_address)
    info.command_line = text_of(handoff.command_line[0..<handoff.command_line.count])
    info.bootloader = "SlopOS's bootloader"
    info.firmware = .Uefi
    info.direct_map_offset = handoff.direct_map_offset
    region_count :: cast[usize](handoff.region_count)
    if region_count > handoff.regions.count {
        kernel.boot_failed(info.command_line, "the bootloader's memory map has more regions than the handoff holds")
    }
    info.memory_map = handoff.regions[0..<region_count]
    // The kernel image, and its segments
    info.kernel_image.physical = handoff.kernel_physical
    info.kernel_image.virtual_base = cast[boot_info.VirtualAddress](handoff.kernel_virtual_base)
    segment_count := cast[usize](0)
    for segment, i in handoff.segments {
        if cast[u64](i) >= handoff.segment_count || i >= handoff.image_segments.count {
            break
        }
        handoff.image_segments[i] = boot_info.ImageSegment.{virtual_base = cast[boot_info.VirtualAddress](segment.virtual_base),
            size = segment.size, writable = segment.writable != 0, executable = segment.executable != 0}
        segment_count = i + 1
    }
    if segment_count <= handoff.image_segments.count {
        info.kernel_image.segments = handoff.image_segments[0..<segment_count]
    }
    // CPUs: the boot CPU only, until the bootloader starts the others
    if handoff.cpu_count > 0 && handoff.boot_cpus.count > 0 && handoff.cpus.count > 0 {
        handoff.boot_cpus[0] = boot_info.BootCpu.{hardware_id = handoff.cpus[0].hardware_id, boot_handle = 0}
        info.cpus = handoff.boot_cpus[0..<1]
    }
    info.start_cpu = null
    // Modules, named by their names in the handoff
    module_count := cast[usize](0)
    for &module, i in handoff.modules {
        if cast[u64](i) >= handoff.module_count || i >= handoff.boot_modules.count {
            break
        }
        handoff.boot_modules[i] = boot_info.BootModule.{name = text_of(module.name[0..<module.name.count]), command_line = "",
            contents = module.contents}
        module_count = i + 1
    }
    if module_count <= handoff.boot_modules.count {
        info.modules = handoff.boot_modules[0..<module_count]
    }
    // The framebuffer, if there's one
    if handoff.has_framebuffer != 0 && handoff.framebuffers.count > 0 {
        frame :: handoff.framebuffer
        handoff.framebuffers[0] = boot_info.Framebuffer.{
            memory = boot_info.PhysicalRange.{cast[boot_info.PhysicalAddress](frame.base), frame.size},
            width = frame.width, height = frame.height, pitch = frame.pitch, bits_per_pixel = frame.bits_per_pixel,
            red = boot_info.ColorChannel.{frame.red_size, frame.red_shift},
            green = boot_info.ColorChannel.{frame.green_size, frame.green_shift},
            blue = boot_info.ColorChannel.{frame.blue_size, frame.blue_shift},
        }
        info.framebuffers = handoff.framebuffers[0..<1]
    }
    info.firmware_tables = firmware_tables(handoff)
    info.bootloader_entropy = if handoff.has_entropy != 0 { handoff.entropy } else { null }
    info.counter_frequency_hint = null
    info.boot_wall_time = null
}

// The firmware tables the handoff names, by their physical addresses.
firmware_tables :: fn(handoff: ptr[boot_protocol.Handoff]) -> boot_info.FirmwareTables {
    tables : boot_info.FirmwareTables
    tables.acpi_rsdp = address_or_none(handoff.acpi_rsdp)
    tables.devicetree = address_or_none(handoff.devicetree)
    tables.smbios = address_or_none(handoff.smbios)
    tables.efi_system_table = address_or_none(handoff.efi_system_table)
    return tables
}

address_or_none :: fn(address: u64) -> boot_info.PhysicalAddress? {
    if address == 0 {
        return null
    }
    return cast[boot_info.PhysicalAddress](address)
}

// The text of bytes up to their first zero, in the handoff, where it stays.
text_of :: fn(bytes #escaping : u8[]) -> string {
    count := cast[usize](0)
    for byte in bytes {
        if byte == 0 {
            break
        }
        count += 1
    }
    return if count <= bytes.count { bit_cast[string](bytes[0..<count]) } else { "" }
}
