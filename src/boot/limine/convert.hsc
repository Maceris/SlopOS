package limine_boot

import raw from "std"
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

// The i-th pointer in an array of pointers, as Limine's responses give their lists.
pointer_at :: fn(array: rawptr, i: u64) -> rawptr {
    return cast[ptr[rawptr]](cast[u64](array) + i * cast[u64](size_of(rawptr)))^
}

// Space for size bytes in carve, aligned for any of BootInfo's arrays.
take :: fn(carve: ptr[mut Carve], size: usize) -> rawptr {
    start :: carve.used
    carve.used = (start + cast[u64](size) + ARRAY_ALIGNMENT - 1) & ~(ARRAY_ALIGNMENT - 1)
    return cast[rawptr](carve.virtual_base + start)
}

/*
 * The response to a required request, or a report of which one is missing and a stop
 * (docs/specs/boot_info.md, Requests).
 */
required :: fn(header: ptr[RequestHeader], command_line: string, name: string) -> rawptr {
    response :: header.response
    if response == null {
        kernel.boot_failed(command_line, name)
    }
    return response
}

build_boot_info :: fn(info: ptr[mut boot_info.BootInfo]) {
    info.command_line = command_line()
    if !base_revision_supported() {
        kernel.boot_failed(info.command_line, "the bootloader doesn't support Limine base revision 6")
    }
    memory_map :: cast[ptr[MemoryMapResponse]](required(&MEMORY_MAP_REQUEST.header, info.command_line,
        "no memory map from the bootloader"))
    hhdm :: cast[ptr[HhdmResponse]](required(&HHDM_REQUEST.header, info.command_line,
        "no direct map from the bootloader"))
    address :: cast[ptr[ExecutableAddressResponse]](required(&EXECUTABLE_ADDRESS_REQUEST.header, info.command_line,
        "no kernel address from the bootloader"))
    file_response :: cast[ptr[ExecutableFileResponse]](required(&EXECUTABLE_FILE_REQUEST.header, info.command_line,
        "no kernel file from the bootloader"))
    mp :: cast[ptr[MpResponse]](required(&MP_REQUEST.header, info.command_line,
        "no CPU list from the bootloader"))
    paging :: cast[ptr[PagingModeResponse]](required(&PAGING_MODE_REQUEST.header, info.command_line,
        "the bootloader didn't answer the paging mode request"))
    if STACK_SIZE_REQUEST.header.response == null {
        kernel.boot_failed(info.command_line, "the bootloader didn't set up 64 KiB boot stacks")
    }
    if paging.mode != PAGING_MODE_X86_64_4_LEVEL {
        kernel.boot_failed(info.command_line, "the bootloader didn't set up 4-level paging")
    }
    executable :: cast[ptr[File]](file_response.executable_file)
    elf :: cast[ptr[ElfHeader]](executable.address)
    if !is_kernel_elf(elf) {
        kernel.boot_failed(info.command_line, "the kernel file isn't a 64-bit little-endian ELF")
    }
    framebuffer_count :: rgb_framebuffer_count()
    bootloader_name, bootloader_version :: bootloader_names()

    // Sizes of the arrays, to find room for all of them at once
    memory_map_count :: memory_map_capacity(cast[usize](memory_map.entry_count))
    segment_count :: load_segment_count(elf)
    cpu_count :: cast[usize](mp.cpu_count)
    // Limine answers the module request only when there are modules
    modules :: cast[ptr[ModuleResponse]](MODULE_REQUEST.header.response)
    module_count :: if modules != null { cast[usize](modules.module_count) } else { 0 }
    sizes :: usize.[
        memory_map_count * size_of(boot_info.MemoryRegion),
        segment_count * size_of(boot_info.ImageSegment),
        cpu_count * size_of(boot_info.BootCpu),
        module_count * size_of(boot_info.BootModule),
        framebuffer_count * size_of(boot_info.Framebuffer),
        bootloader_name.count + 1 + bootloader_version.count,
    ]
    needed : u64 = 0
    for size in sizes {
        needed += (cast[u64](size) + ARRAY_ALIGNMENT - 1) & ~(ARRAY_ALIGNMENT - 1)
    }
    carved := boot_info.PhysicalRange.{}
    match find_carve(memory_map, align_up(needed)) {
        case Some(found) => carved = found
        case None => kernel.boot_failed(info.command_line, "no usable memory for the boot information")
    }
    carve := Carve.{carved, cast[u64](carved.base) + hhdm.offset, 0}

    info.direct_map_offset = hhdm.offset
    regions :: raw.view_of(cast[ptr[boot_info.MemoryRegion]](take(&carve, sizes[0])), memory_map_count)
    info.memory_map = regions[0..<build_memory_map(memory_map, address.physical_base, carved, regions)]
    info.kernel_image = kernel_image(address, info.memory_map, elf,
        raw.view_of(cast[ptr[boot_info.ImageSegment]](take(&carve, sizes[1])), segment_count))
    info.cpus = cpus(mp, raw.view_of(cast[ptr[boot_info.BootCpu]](take(&carve, sizes[2])), cpu_count))
    //TODO(claude): start_cpu, which needs an entry for the other CPUs that Limine can call without a
    //carrier or a context, like kernel_entry (M3)
    info.start_cpu = null
    info.modules = boot_modules(modules, hhdm.offset,
        raw.view_of(cast[ptr[boot_info.BootModule]](take(&carve, sizes[3])), module_count))
    info.framebuffers = framebuffers(hhdm.offset,
        raw.view_of(cast[ptr[boot_info.Framebuffer]](take(&carve, sizes[4])), framebuffer_count))
    info.bootloader = join_names(bootloader_name, bootloader_version,
        raw.view_of(cast[ptr[u8]](take(&carve, sizes[5])), sizes[5]))
    info.firmware = firmware()
    info.firmware_tables = firmware_tables(hhdm.offset)
    info.bootloader_entropy = bootloader_entropy()
    info.counter_frequency_hint = counter_frequency_hint()
    info.boot_wall_time = boot_wall_time()
}

command_line :: fn() -> string {
    response :: EXECUTABLE_COMMAND_LINE_REQUEST.header.response
    if response == null {
        return ""
    }
    return raw.string_of_c_string(cast[ptr[ExecutableCommandLineResponse]](response).command_line)
}

// The bootloader's name and version, empty if it didn't say.
bootloader_names :: fn() -> (string, string) {
    response :: BOOTLOADER_INFO_REQUEST.header.response
    if response == null {
        return "", ""
    }
    names :: cast[ptr[BootloaderInfoResponse]](response)
    return raw.string_of_c_string(names.name), raw.string_of_c_string(names.version)
}

// "name version", in bytes.
join_names :: fn(name, version: string, bytes: u8[]) -> string {
    if name.count == 0 {
        return ""
    }
    count : usize = 0
    for character in name {
        bytes[count] = cast[u8](character)
        count += 1
    }
    if version.count > 0 {
        bytes[count] = cast[u8](' ')
        count += 1
        for character in version {
            bytes[count] = cast[u8](character)
            count += 1
        }
    }
    return raw.string_of(&bytes[0], count)
}

/*
 * Where the kernel is: physically, the memory map region at its physical base; virtually, the base
 * Limine loaded it at, with each loaded segment moved by the same amount from its link address.
 */
kernel_image :: fn(
    address: ptr[ExecutableAddressResponse],
    memory_map: boot_info.MemoryRegion[],
    elf: ptr[ElfHeader],
    segments: boot_info.ImageSegment[],
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
        segments[count] = boot_info.ImageSegment.{
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

// Every CPU, the boot CPU first. boot_handle is its MpInfo, for starting it.
cpus :: fn(mp: ptr[MpResponse], cpus: boot_info.BootCpu[]) -> boot_info.BootCpu[] {
    count : usize = 1
    for i in 0..<mp.cpu_count {
        cpu :: cast[ptr[MpInfo]](pointer_at(mp.cpus, i))
        entry :: boot_info.BootCpu.{cast[u64](cpu.lapic_id), cast[rawptr](cpu)}
        if cpu.lapic_id == mp.bsp_lapic_id {
            cpus[0] = entry
            continue
        }
        cpus[count] = entry
        count += 1
    }
    return cpus
}

boot_modules :: fn(response: ptr[ModuleResponse], hhdm_offset: u64, modules: boot_info.BootModule[]) -> boot_info.BootModule[] {
    for i in 0..<modules.count {
        file :: cast[ptr[File]](pointer_at(response.modules, cast[u64](i)))
        modules[i] = boot_info.BootModule.{
            name = file_name(raw.string_of_c_string(file.path)),
            command_line = raw.string_of_c_string(file.string),
            contents = boot_info.PhysicalRange.{cast[boot_info.PhysicalAddress](cast[u64](file.address) - hhdm_offset), file.size},
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
    //HEMERA(gap): slicing a string gives char[], not a string
    return bit_cast[string](path[start..<path.count])
}

framebuffer_at :: fn(response: ptr[FramebufferResponse], i: u64) -> ptr[LimineFramebuffer] {
    return cast[ptr[LimineFramebuffer]](pointer_at(response.framebuffers, i))
}

// How many framebuffers are linear RGB, the only kind BootInfo lists.
rgb_framebuffer_count :: fn() -> usize {
    response :: FRAMEBUFFER_REQUEST.header.response
    if response == null {
        return 0
    }
    framebuffers :: cast[ptr[FramebufferResponse]](response)
    count : usize = 0
    for i in 0..<framebuffers.framebuffer_count {
        if framebuffer_at(framebuffers, i).memory_model == FRAMEBUFFER_RGB {
            count += 1
        }
    }
    return count
}

framebuffers :: fn(hhdm_offset: u64, framebuffers: boot_info.Framebuffer[]) -> boot_info.Framebuffer[] {
    response :: FRAMEBUFFER_REQUEST.header.response
    if response == null {
        return framebuffers
    }
    list :: cast[ptr[FramebufferResponse]](response)
    count : usize = 0
    for i in 0..<list.framebuffer_count {
        framebuffer :: framebuffer_at(list, i)
        if framebuffer.memory_model != FRAMEBUFFER_RGB {
            continue
        }
        edid : u8[] = u8.[]
        if framebuffer.edid != null && framebuffer.edid_size > 0 {
            edid = raw.view_of(cast[ptr[u8]](framebuffer.edid), cast[usize](framebuffer.edid_size))
        }
        framebuffers[count] = boot_info.Framebuffer.{
            memory = boot_info.PhysicalRange.{
                cast[boot_info.PhysicalAddress](cast[u64](framebuffer.address) - hhdm_offset),
                framebuffer.pitch * framebuffer.height,
            },
            width = cast[u32](framebuffer.width),
            height = cast[u32](framebuffer.height),
            pitch = cast[u32](framebuffer.pitch),
            bits_per_pixel = framebuffer.bits_per_pixel,
            red = boot_info.ColorChannel.{framebuffer.red_mask_size, framebuffer.red_mask_shift},
            green = boot_info.ColorChannel.{framebuffer.green_mask_size, framebuffer.green_mask_shift},
            blue = boot_info.ColorChannel.{framebuffer.blue_mask_size, framebuffer.blue_mask_shift},
            edid = edid,
        }
        count += 1
    }
    return framebuffers
}

// UEFI when the bootloader doesn't say.
firmware :: fn() -> boot_info.Firmware {
    response :: FIRMWARE_TYPE_REQUEST.header.response
    if response == null {
        return .Uefi
    }
    kind :: cast[ptr[FirmwareTypeResponse]](response).firmware_type
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

// A table's physical address, from a response holding its address in the direct map.
table_address :: fn(address: rawptr, hhdm_offset: u64) -> boot_info.PhysicalAddress? {
    if address == null {
        return null
    }
    return cast[boot_info.PhysicalAddress](cast[u64](address) - hhdm_offset)
}

address_response :: fn(header: ptr[RequestHeader]) -> rawptr {
    if header.response == null {
        return null
    }
    return cast[ptr[AddressResponse]](header.response).address
}

firmware_tables :: fn(hhdm_offset: u64) -> boot_info.FirmwareTables {
    tables : boot_info.FirmwareTables
    tables.acpi_rsdp = table_address(address_response(&RSDP_REQUEST.header), hhdm_offset)
    tables.devicetree = table_address(address_response(&DEVICE_TREE_REQUEST.header), hhdm_offset)
    tables.efi_system_table = table_address(address_response(&EFI_SYSTEM_TABLE_REQUEST.header), hhdm_offset)
    tables.smbios = null
    if SMBIOS_REQUEST.header.response != null {
        smbios :: cast[ptr[SmbiosResponse]](SMBIOS_REQUEST.header.response)
        entry :: if smbios.entry_64 != null { smbios.entry_64 } else { smbios.entry_32 }
        tables.smbios = table_address(entry, hhdm_offset)
    }
    return tables
}

// The bootloader's four entropy values as bytes, lowest first, if it gave all four.
bootloader_entropy :: fn() -> u8[32]? {
    response :: ENTROPY_REQUEST.header.response
    if response == null {
        return null
    }
    entropy :: cast[ptr[EntropyResponse]](response)
    if entropy.value_count < ENTROPY_VALUES {
        return null
    }
    values :: raw.view_of(cast[ptr[u64]](entropy.values), ENTROPY_VALUES)
    bytes : u8[32]
    for value, i in values {
        for j in 0..<cast[usize](8) {
            bytes[i * 8 + j] = cast[u8]((value >> cast[u64](j * 8)) & 0xff)
        }
    }
    return bytes
}

counter_frequency_hint :: fn() -> u64? {
    response :: TSC_FREQUENCY_REQUEST.header.response
    if response == null {
        return null
    }
    frequency :: cast[ptr[TscFrequencyResponse]](response).frequency
    if frequency == 0 {
        return null
    }
    return frequency
}

boot_wall_time :: fn() -> i64? {
    response :: DATE_AT_BOOT_REQUEST.header.response
    if response == null {
        return null
    }
    return cast[ptr[DateAtBootResponse]](response).timestamp
}
