package kernel

import runtime from "base"
import boot_info from "../boot_info"

/**
 * Log what the kernel was given at boot: the bootloader and firmware, the memory map's usable total, the image, the
 * CPUs, modules and framebuffers, and which firmware tables were found.
 *
 * @param info The boot information the boot adapter built; only read.
 */
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
    runtime.log_info("kernel image at %{#018x}, physical %{#018x}, % segments", info.kernel_image.virtual_base,
        info.kernel_image.physical.base, info.kernel_image.segments.count)
    runtime.log_info("% CPUs, % modules, % framebuffers", info.cpus.count, info.modules.count, info.framebuffers.count)
    for module in info.modules {
        runtime.log_info("module %", module.name)
    }
    tables :: &info.firmware_tables
    runtime.log_info("firmware tables: ACPI %, device tree %, SMBIOS %, EFI system table %", tables.acpi_rsdp is_some,
        tables.devicetree is_some, tables.smbios is_some, tables.efi_system_table is_some)
}

/**
 * Name a kind of firmware, for the log.
 *
 * @param firmware The firmware the machine booted through.
 * @return A constant name: "BIOS", "UEFI", "32-bit UEFI" or "SBI".
 */
firmware_name :: fn(firmware: boot_info.Firmware) -> string {
    return match firmware {
        case .Bios => "BIOS"
        case .Uefi => "UEFI"
        case .Uefi32 => "32-bit UEFI"
        case .Sbi => "SBI"
    }
}
