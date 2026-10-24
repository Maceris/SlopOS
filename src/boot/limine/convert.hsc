package limine_boot

import c_string from "std"
import runtime from "base"
import boot_info from "../../boot_info"
import kernel from "../../kernel"

/*
 * BootInfo from Limine's responses (docs/specs/boot_info.md, Conversion). Strings point into the
 * responses; the arrays go in memory carved from the first usable region with room, through the
 * direct map, so no allocator is needed.
 */

// Bump allocation in the carved memory.
Carve :: struct {
    physical : boot_info.PhysicalRange,
    // Where physical is in the direct map.
    virtual_base : u64,
    used : u64,
}

ARRAY_ALIGNMENT : u64 : 64

/*
 * A carve that keeps itself at the start of the memory it carves: what it gives out then comes from
 * an address in the direct map, not from a Carve on this stack (Hemera's docs/memory.md, Returning).
 */
start_carve :: fn(physical: boot_info.PhysicalRange, virtual_base: u64) -> ptr[mut Carve] {
    carve :: cast[ptr[mut Carve]](virtual_base)
    carve^ = Carve.{physical, virtual_base, carved_size(1, size_of(Carve))}
    return carve
}

// Room for count Ts in carve, aligned for any of BootInfo's arrays.
take :: fn[T](carve: ptr[mut Carve], count: usize) -> mut T[] {
    start :: carve.used
    carve.used = (start + cast[u64](count * size_of(T)) + ARRAY_ALIGNMENT - 1) & ~(ARRAY_ALIGNMENT - 1)
    return view_of(cast[ptr[mut T]](carve.virtual_base + start), count)
}

// What carve takes for count Ts.
carved_size :: fn(count: usize, element_size: usize) -> u64 {
    return (cast[u64](count * element_size) + ARRAY_ALIGNMENT - 1) & ~(ARRAY_ALIGNMENT - 1)
}

// A C string's text, empty when there's none.
text :: fn(value: cstring?) -> string {
    return c_string.to_string(value or_return "")
}

build_boot_info :: fn(info: ptr[mut boot_info.BootInfo]) {
    info.command_line = command_line()
    if !base_revision_supported() {
        kernel.boot_failed(info.command_line, "the bootloader doesn't support Limine base revision 6")
    }
    // The required responses (docs/specs/boot_info.md, Requests)
    memory_map :: MEMORY_MAP_REQUEST.response or_else kernel.boot_failed(info.command_line, "no memory map from the bootloader")
    hhdm :: HHDM_REQUEST.response or_else kernel.boot_failed(info.command_line, "no direct map from the bootloader")
    address :: EXECUTABLE_ADDRESS_REQUEST.response
        or_else kernel.boot_failed(info.command_line, "no kernel address from the bootloader")
    file_response :: EXECUTABLE_FILE_REQUEST.response
        or_else kernel.boot_failed(info.command_line, "no kernel file from the bootloader")
    mp :: MP_REQUEST.response or_else kernel.boot_failed(info.command_line, "no CPU list from the bootloader")
    paging :: PAGING_MODE_REQUEST.response
        or_else kernel.boot_failed(info.command_line, "the bootloader didn't answer the paging mode request")
    if STACK_SIZE_REQUEST.response is_none {
        kernel.boot_failed(info.command_line, "the bootloader didn't set up 64 KiB boot stacks")
    }
    if paging.mode != PAGING_MODE_4_LEVEL {
        kernel.boot_failed(info.command_line, "the bootloader didn't set up 4-level paging")
    }
    elf :: cast[ptr[ElfHeader]](file_response.executable_file.address)
    if !is_kernel_elf(elf) {
        kernel.boot_failed(info.command_line, "the kernel file isn't a 64-bit little-endian ELF")
    }
    framebuffer_count :: rgb_framebuffer_count()
    bootloader_name, bootloader_version :: bootloader_names()
    // Limine answers the module request only when there are modules
    modules :: module_files()

    // Sizes of the arrays, to find room for all of them at once
    memory_map_count :: memory_map_capacity(cast[usize](memory_map.entry_count))
    segment_count :: load_segment_count(elf)
    cpu_count :: cast[usize](mp.cpu_count)
    name_length :: bootloader_name.count + 1 + bootloader_version.count
    needed :: carved_size(1, size_of(Carve))
        + carved_size(memory_map_count, size_of(boot_info.MemoryRegion))
        + carved_size(segment_count, size_of(boot_info.ImageSegment))
        + carved_size(cpu_count, size_of(boot_info.BootCpu))
        + carved_size(cpu_count, size_of(StartingCpu))
        + carved_size(modules.count, size_of(boot_info.BootModule))
        + carved_size(framebuffer_count, size_of(boot_info.Framebuffer))
        + carved_size(name_length, 1)
    carved :: find_carve(memory_map, align_up(needed))
        or_else kernel.boot_failed(info.command_line, "no usable memory for the boot information")
    carve :: start_carve(carved, cast[u64](carved.base) + hhdm.offset)

    info.direct_map_offset = hhdm.offset
    regions :: take[boot_info.MemoryRegion](carve, memory_map_count)
    region_count :: build_memory_map(memory_map, address.physical_base, carved, regions)
    runtime.assert(region_count <= regions.count, "build_memory_map gave more regions than it has room for")
    info.memory_map = regions[0..<region_count]
    info.kernel_image = kernel_image(address, info.memory_map, elf, take[boot_info.ImageSegment](carve, segment_count))
    info.cpus = cpus(mp, take[boot_info.BootCpu](carve, cpu_count), take[StartingCpu](carve, cpu_count))
    info.start_cpu = null
    if cpu_count > 1 {
        info.start_cpu = start_cpu
    }
    info.modules = boot_modules(modules, hhdm.offset, take[boot_info.BootModule](carve, modules.count))
    info.framebuffers = framebuffers(hhdm.offset, take[boot_info.Framebuffer](carve, framebuffer_count))
    info.bootloader = join_names(bootloader_name, bootloader_version, take[u8](carve, name_length))
    info.firmware = firmware()
    info.firmware_tables = firmware_tables(hhdm.offset)
    info.bootloader_entropy = bootloader_entropy()
    info.counter_frequency_hint = counter_frequency_hint()
    info.boot_wall_time = boot_wall_time()
}

command_line :: fn() -> string {
    response :: EXECUTABLE_COMMAND_LINE_REQUEST.response or_return ""
    return text(response.command_line)
}

// The bootloader's name and version, empty if it didn't say.
bootloader_names :: fn() -> (string, string) {
    match BOOTLOADER_INFO_REQUEST.response {
        case Some(names) => return text(names.name), text(names.version)
        case None => return "", ""
    }
}

// "name version", in bytes.
join_names :: fn(name, version: string, bytes: mut u8[]) -> string {
    if name.count == 0 || bytes.count == 0 {
        return ""
    }
    runtime.assert(name.count + 1 + version.count <= bytes.count, "join_names needs room for both names")
    count : usize = 0
    for character in name {
        if count < bytes.count {
            bytes[count] = cast[u8](character)
            count += 1
        }
    }
    if version.count > 0 && count < bytes.count {
        bytes[count] = cast[u8](' ')
        count += 1
        for character in version {
            if count < bytes.count {
                bytes[count] = cast[u8](character)
                count += 1
            }
        }
    }
    return string_of(&bytes[0], count)
}

/*
 * Where the kernel is: physically, the memory map region at its physical base; virtually, the base
 * Limine loaded it at, with each loaded segment moved by the same amount from its link address.
 */
kernel_image :: fn(
    address: ptr[ExecutableAddressResponse],
    memory_map: boot_info.MemoryRegion[],
    elf: ptr[ElfHeader],
    segments: mut boot_info.ImageSegment[],
) -> boot_info.KernelImage {
    image : boot_info.KernelImage
    image.virtual_base = cast[boot_info.VirtualAddress](address.virtual_base)
    image.physical = boot_info.PhysicalRange.{cast[boot_info.PhysicalAddress](address.physical_base), 0}
    for region in memory_map {
        start :: cast[u64](region.range.base)
        if region.kind == .KernelImage && address.physical_base >= start && address.physical_base - start < region.range.size {
            image.physical.size = start + region.range.size - address.physical_base
        }
    }
    slide :: address.virtual_base - link_base(elf)
    count : usize = 0
    for i in 0..<cast[u64](elf.program_header_count) {
        header :: program_header(elf, i)
        if cast[u32](header.kind) != PT_LOAD {
            continue
        }
        runtime.assert(count < segments.count, "load_segment_count counts every loadable segment")
        segments[count] = .{
            virtual_base = cast[boot_info.VirtualAddress](cast[u64](header.virtual_address) + slide),
            size = cast[u64](header.memory_size),
            writable = (cast[u32](header.flags) & PF_W) != 0,
            executable = (cast[u32](header.flags) & PF_X) != 0,
        }
        count += 1
    }
    image.segments = segments[0..<count]
    return image
}

// The module files, none when Limine didn't answer the module request.
module_files :: fn() -> ptr[File][] {
    empty : ptr[File][]
    response :: MODULE_REQUEST.response or_return empty
    return pointers(response.modules, response.module_count)
}

boot_modules :: fn(files: ptr[File][], hhdm_offset: u64, modules: mut boot_info.BootModule[]) -> boot_info.BootModule[] {
    runtime.assert(files.count <= modules.count, "boot_modules needs room for every module")
    for file, i in files {
        modules[i] = .{
            name = file_name(text(file.path)),
            command_line = text(file.string),
            contents = .{cast[boot_info.PhysicalAddress](cast[u64](file.address) - hhdm_offset), file.size},
        }
    }
    return modules
}

// The last part of a path.
file_name :: fn(path: string) -> string {
    start : usize = 0
    for character, i in path {
        if character == '/' {
            start = i + 1
        }
    }
    return path[start..<path.count]
}

// Limine's framebuffers, none when it didn't answer the request.
limine_framebuffers :: fn() -> ptr[LimineFramebuffer][] {
    empty : ptr[LimineFramebuffer][]
    response :: FRAMEBUFFER_REQUEST.response or_return empty
    return pointers(response.framebuffers, response.framebuffer_count)
}

// How many framebuffers are linear RGB, the only kind BootInfo lists.
rgb_framebuffer_count :: fn() -> usize {
    count : usize = 0
    for framebuffer in limine_framebuffers() {
        if framebuffer.memory_model == FRAMEBUFFER_RGB {
            count += 1
        }
    }
    return count
}

framebuffers :: fn(hhdm_offset: u64, framebuffers: mut boot_info.Framebuffer[]) -> boot_info.Framebuffer[] {
    count : usize = 0
    for framebuffer in limine_framebuffers() {
        if framebuffer.memory_model != FRAMEBUFFER_RGB {
            continue
        }
        edid : u8[]
        match framebuffer.edid {
            case Some(data) => edid = view_of(data, cast[usize](framebuffer.edid_size))
            case None => {}
        }
        runtime.assert(count < framebuffers.count, "rgb_framebuffer_count counts every RGB framebuffer")
        framebuffers[count] = .{
            memory = .{cast[boot_info.PhysicalAddress](framebuffer.address - hhdm_offset), framebuffer.pitch * framebuffer.height},
            width = cast[u32](framebuffer.width),
            height = cast[u32](framebuffer.height),
            pitch = cast[u32](framebuffer.pitch),
            bits_per_pixel = framebuffer.bits_per_pixel,
            red = .{framebuffer.red_mask_size, framebuffer.red_mask_shift},
            green = .{framebuffer.green_mask_size, framebuffer.green_mask_shift},
            blue = .{framebuffer.blue_mask_size, framebuffer.blue_mask_shift},
            edid = edid,
        }
        count += 1
    }
    return framebuffers
}

// UEFI when the bootloader doesn't say.
firmware :: fn() -> boot_info.Firmware {
    response :: FIRMWARE_TYPE_REQUEST.response or_return .Uefi
    kind :: response.firmware_type
    if kind == FIRMWARE_X86_BIOS {
        return .Bios
    }
    if kind == FIRMWARE_EFI32 {
        return .Uefi32
    }
    if kind == FIRMWARE_SBI {
        return .Sbi
    }
    return .Uefi
}

// A table's physical address, from its address in the direct map, which is null when there's none.
table_address :: fn(address: rawptr, hhdm_offset: u64) -> boot_info.PhysicalAddress? {
    if address == null {
        return null
    }
    return cast[boot_info.PhysicalAddress](cast[u64](address) - hhdm_offset)
}

// A table's address, from a request answered with one.
address_of_table :: fn(response: ptr[AddressResponse]?) -> rawptr {
    answered :: response or_return null
    return answered.address
}

firmware_tables :: fn(hhdm_offset: u64) -> boot_info.FirmwareTables {
    tables : boot_info.FirmwareTables
    tables.acpi_rsdp = table_address(address_of_table(RSDP_REQUEST.response), hhdm_offset)
    tables.devicetree = table_address(address_of_table(DEVICE_TREE_REQUEST.response), hhdm_offset)
    tables.efi_system_table = table_address(address_of_table(EFI_SYSTEM_TABLE_REQUEST.response), hhdm_offset)
    tables.smbios = null
    match SMBIOS_REQUEST.response {
        case Some(smbios) => tables.smbios = table_address(if smbios.entry_64 != null { smbios.entry_64 } else { smbios.entry_32 }, hhdm_offset)
        case None => {}
    }
    return tables
}

// The bootloader's four entropy values as bytes, lowest first, if it gave all four.
bootloader_entropy :: fn() -> u8[32]? {
    entropy :: ENTROPY_REQUEST.response or_return null
    data :: entropy.values or_return null
    if entropy.value_count < ENTROPY_VALUES {
        return null
    }
    bytes : u8[32]
    for value, i in view_of(data, ENTROPY_VALUES) {
        for j in 0..<cast[usize](8) {
            bytes[i * 8 + j] = cast[u8]((value >> cast[u64](j * 8)) & 0xff)
        }
    }
    return bytes
}

counter_frequency_hint :: fn() -> u64? {
    response :: TSC_FREQUENCY_REQUEST.response or_return null
    if response.frequency == 0 {
        return null
    }
    return response.frequency
}

boot_wall_time :: fn() -> i64? {
    response :: DATE_AT_BOOT_REQUEST.response or_return null
    return response.timestamp
}
