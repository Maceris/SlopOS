package kernel

import runtime from "base"
import boot_info from "../boot_info"

// What the kernel was given, for the boot log.
log_boot_info :: fn(info: ptr[boot_info.BootInfo]) {
    bootloader :: if info.bootloader.count > 0 { info.bootloader } else { "an unknown bootloader" }
    runtime.log_info("SlopOS, booted by % (%)", bootloader, firmware_name(info.firmware))

    usable : u64 = 0
    for region in info.memory_map {
        if region.kind == .Usable {
            usable += region.range.size
        }
    }
    runtime.log_info("memory map: % regions, % KiB usable", info.memory_map.count, usable / 1024)
    // As pointers, so they're written in hexadecimal
    runtime.log_info("kernel image at %, physical %, % segments", cast[rawptr](info.kernel_image.virtual_base),
        cast[rawptr](info.kernel_image.physical.base), info.kernel_image.segments.count)
    runtime.log_info("% CPUs, % modules, % framebuffers", info.cpus.count, info.modules.count, info.framebuffers.count)
}

firmware_name :: fn(firmware: boot_info.Firmware) -> string {
    return match firmware {
        case .Bios => "BIOS"
        case .Uefi => "UEFI"
        case .Uefi32 => "32-bit UEFI"
        case .Sbi => "SBI"
    }
}
