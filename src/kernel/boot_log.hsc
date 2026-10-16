package kernel

import runtime from "base"
import boot_info from "../boot_info"
import text_buffer from "std"

// What the kernel was given, for the boot log.
log_boot_info :: fn(info: ptr[boot_info.BootInfo]) {
    storage : u8[200]
    line := text_buffer.make(storage)

    text_buffer.append(&line, "SlopOS, booted by ")
    text_buffer.append(&line, if info.bootloader.count > 0 { info.bootloader } else { "an unknown bootloader" })
    text_buffer.append(&line, " (")
    text_buffer.append(&line, firmware_name(info.firmware))
    text_buffer.append(&line, ")")
    runtime.log_info(text_buffer.as_string(&line))

    usable : u64 = 0
    for region in info.memory_map {
        if region.kind == .Usable {
            usable += region.range.size
        }
    }
    text_buffer.clear(&line)
    text_buffer.append(&line, "memory map: ")
    text_buffer.append_unsigned(&line, cast[u64](info.memory_map.count))
    text_buffer.append(&line, " regions, ")
    text_buffer.append_unsigned(&line, usable / 1024)
    text_buffer.append(&line, " KiB usable")
    runtime.log_info(text_buffer.as_string(&line))

    text_buffer.clear(&line)
    text_buffer.append(&line, "kernel image at ")
    text_buffer.append_address(&line, cast[u64](info.kernel_image.virtual_base))
    text_buffer.append(&line, ", physical ")
    text_buffer.append_address(&line, cast[u64](info.kernel_image.physical.base))
    text_buffer.append(&line, ", ")
    text_buffer.append_unsigned(&line, cast[u64](info.kernel_image.segments.count))
    text_buffer.append(&line, " segments")
    runtime.log_info(text_buffer.as_string(&line))

    text_buffer.clear(&line)
    text_buffer.append_unsigned(&line, cast[u64](info.cpus.count))
    text_buffer.append(&line, " CPUs, ")
    text_buffer.append_unsigned(&line, cast[u64](info.modules.count))
    text_buffer.append(&line, " modules, ")
    text_buffer.append_unsigned(&line, cast[u64](info.framebuffers.count))
    text_buffer.append(&line, " framebuffers")
    runtime.log_info(text_buffer.as_string(&line))
}

firmware_name :: fn(firmware: boot_info.Firmware) -> string {
    return match firmware {
        case .Bios => "BIOS"
        case .Uefi => "UEFI"
        case .Uefi32 => "32-bit UEFI"
        case .Sbi => "SBI"
    }
}
