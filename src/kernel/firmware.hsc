package kernel

import intrinsics from "base"
import runtime from "base"
import boot_info from "../boot_info"
import slop_os from "std/os"
import frames from "frames"

/*
 * The firmware tables' copy (roadmap M7, decisions/0070, 0073): while the bootloader's memory is still there, the
 * kernel copies the firmware tables into one block of frames, in the layout of slop_os.FirmwareTables, which becomes
 * the root task's "firmware" grant, for the platform service. The kernel only finds them; reading what they say is
 * the platform service's.
 *
 * On x86-64 they're ACPI's: the RSDP, every table its XSDT (or, before ACPI 2, its RSDT) lists, and the FADT's DSDT
 * and FACS, read through the kernel window, since firmware may keep them in reserved memory the direct map leaves out.
 * On AArch64, the device tree's blob, which the bootloader's memory holds, through the direct map. Last, on both, the
 * kernel's own "RAM " table: the RAM it owns, a slop_os.PhysicalRange each, so the platform service knows what isn't
 * free for devices (decisions/0074).
 */
//SPEC: ACPI Specification 6.5, §5.2.5 (RSDP), §5.2.6 (system description table header), §5.2.7-8 (RSDT, XSDT), §5.2.9 (FADT), §5.2.10 (FACS)
//SPEC: Devicetree Specification 0.4, §5.2 (the header)

MAX_FIRMWARE_TABLES :: 64
// The most bytes a table may have, and all of them: QEMU's are a few KiB, a large server's a few hundred.
MAX_TABLE_BYTES : u64 : 4 << 20
MAX_FIRMWARE_BYTES : u64 : 16 << 20
SDT_HEADER_SIZE : u64 : 36
DEVICE_TREE_MAGIC : u32 : 0xd00dfeed

FoundTable :: struct {
    signature : u8[4],
    physical : u64,
    size : u64,
}

FoundTables :: struct {
    kind : slop_os.FirmwareKind,
    count : usize,
    tables : FoundTable[MAX_FIRMWARE_TABLES],
}

// Copy the firmware tables, if the boot has any, for the root task: kernel.firmware, a read-only Memory.
copy_firmware_tables :: fn(kernel: ptr[mut Kernel], tables: ptr[boot_info.FirmwareTables], direct_map_offset: u64) {
    found : FoundTables
    #if TARGET_ARCH == .x86_64 {
        match tables.acpi_rsdp {
            case Some(rsdp) => find_acpi_tables(kernel, cast[u64](rsdp), &found)
            case None => {}
        }
    }
    #else {
        match tables.devicetree {
            case Some(tree) => find_device_tree(direct_map_offset + cast[u64](tree), cast[u64](tree), &found)
            case None => {}
        }
    }
    if found.count == 0 {
        runtime.log_warn("no firmware tables to copy for the root task")
        return void
    }
    ram_bytes :: cast[u64](kernel.ram.count) * cast[u64](size_of(slop_os.PhysicalRange))
    header_bytes :: cast[u64](size_of(slop_os.FirmwareTables)) + cast[u64](found.count + 1) * cast[u64](size_of(slop_os.FirmwareTable))
    total := header_bytes
    for table, i in found.tables {
        if i < found.count {
            total = frames.round_up(total, 8) + table.size
        }
    }
    total = frames.round_up(total, 8) + ram_bytes
    if total > MAX_FIRMWARE_BYTES {
        runtime.log_error("the firmware tables are too big to copy: % bytes", total)
        return void
    }
    memory := cast[ptr[mut Memory]](0)
    match create_contiguous_memory(kernel, 0, 0, frames.round_up(total, frames.FRAME_SIZE), 0, cast[u32](slop_os.PROTECTION_READ)) {
        case Ok(made) => memory = made
        case Error(error) => {
            runtime.log_error("no memory for the firmware tables' copy")
            return void
        }
    }
    base :: frames.virtual_of(&kernel.frames, cast[boot_info.PhysicalAddress](memory.physical))
    header :: cast[ptr[mut slop_os.FirmwareTables]](base)
    header.magic = slop_os.FIRMWARE_MAGIC
    header.kind = found.kind
    header.count = cast[u32](found.count + 1)
    entries :: view_of(cast[ptr[mut slop_os.FirmwareTable]](base + cast[u64](size_of(slop_os.FirmwareTables))), found.count + 1)
    offset := header_bytes
    for &table, i in found.tables {
        if i >= found.count || i >= entries.count {
            break
        }
        offset = frames.round_up(offset, 8)
        entries[i] = slop_os.FirmwareTable.{signature = table.signature, size = cast[u32](table.size), offset = offset, physical = table.physical}
        #if TARGET_ARCH == .x86_64 {
            read_physical(kernel, table.physical, table.size, base + offset)
        }
        #else {
            intrinsics.mem_copy_non_overlapping(cast[mut rawptr](base + offset), cast[rawptr](direct_map_offset + table.physical), cast[usize](table.size))
        }
        offset += table.size
    }
    // The RAM the kernel owns, which wasn't anywhere before, so at physical address 0
    offset = frames.round_up(offset, 8)
    last :: found.count
    if last < entries.count {
        entries[last] = slop_os.FirmwareTable.{signature = signature_of("RAM "), size = cast[u32](ram_bytes), offset = offset, physical = 0}
    }
    ranges :: view_of(cast[ptr[mut slop_os.PhysicalRange]](base + offset), kernel.ram.count)
    for range, i in kernel.ram {
        if i < ranges.count {
            ranges[i] = slop_os.PhysicalRange.{base = cast[u64](range.base), size = range.size}
        }
    }
    kernel.firmware = cast[u64](memory)
    runtime.log_info("firmware tables: % copied for the root task, and % RAM ranges, % bytes", found.count, kernel.ram.count, total)
}

// The tables an RSDP leads to, and the RSDP.
find_acpi_tables :: fn(kernel: ptr[mut Kernel], rsdp: u64, found: ptr[mut FoundTables]) {
    found.kind = .Acpi
    bytes : u8[36]
    read_physical(kernel, rsdp, 36, cast[u64](&bytes))
    if !bytes_are(cast[u64](&bytes), "RSD PTR ") {
        runtime.log_warn("the RSDP's signature is wrong")
        return void
    }
    revision :: bytes[15]
    add_table(found, signature_of("RSDP"), rsdp, if revision >= 2 { cast[u64](36) } else { cast[u64](20) })
    xsdt :: if revision >= 2 { u64_at(cast[u64](&bytes), 24) } else { cast[u64](0) }
    root :: if xsdt != 0 { xsdt } else { cast[u64](u32_at(cast[u64](&bytes), 16)) }
    entry_size :: if xsdt != 0 { cast[u64](8) } else { cast[u64](4) }
    root_size :: add_sdt(kernel, found, root)
    if root_size < SDT_HEADER_SIZE {
        return void
    }
    for index in 0..<(root_size - SDT_HEADER_SIZE) / entry_size {
        entry : u64 = 0
        read_physical(kernel, root + SDT_HEADER_SIZE + index * entry_size, entry_size, cast[u64](&entry))
        if entry == 0 {
            continue
        }
        signature : u8[4]
        read_physical(kernel, entry, 4, cast[u64](&signature))
        size :: add_sdt(kernel, found, entry)
        // The FADT points at two more: the DSDT, and the FACS, which has a length but no checksum or the rest
        if bytes_are(cast[u64](&signature), "FACP") && size >= 44 {
            fadt : u8[148]
            read_physical(kernel, entry, if size >= 148 { cast[u64](148) } else { size }, cast[u64](&fadt))
            dsdt :: if size >= 148 && u64_at(cast[u64](&fadt), 140) != 0 { u64_at(cast[u64](&fadt), 140) } else { cast[u64](u32_at(cast[u64](&fadt), 40)) }
            facs :: if size >= 140 && u64_at(cast[u64](&fadt), 132) != 0 { u64_at(cast[u64](&fadt), 132) } else { cast[u64](u32_at(cast[u64](&fadt), 36)) }
            if dsdt != 0 {
                _ = add_sdt(kernel, found, dsdt)
            }
            if facs != 0 {
                _ = add_sdt(kernel, found, facs)
            }
        }
    }
}

// The table at physical, by its header's signature and length, unless it's there already or too long: its length.
add_sdt :: fn(kernel: ptr[mut Kernel], found: ptr[mut FoundTables], physical: u64) -> u64 {
    header : u8[8]
    read_physical(kernel, physical, 8, cast[u64](&header))
    size :: cast[u64](u32_at(cast[u64](&header), 4))
    if size < 8 || size > MAX_TABLE_BYTES {
        runtime.log_warn("a firmware table at % has a length of %, and isn't copied", cast[rawptr](physical), size)
        return 0
    }
    signature : u8[4]
    intrinsics.mem_copy_non_overlapping(cast[mut rawptr](&signature), cast[rawptr](&header), 4)
    add_table(found, signature, physical, size)
    return size
}

add_table :: fn(found: ptr[mut FoundTables], signature: u8[4], physical: u64, size: u64) {
    for table, i in found.tables {
        if i < found.count && table.physical == physical {
            return void
        }
    }
    index :: found.count
    if index >= found.tables.count {
        runtime.log_warn("more than % firmware tables: the rest aren't copied", MAX_FIRMWARE_TABLES)
        return void
    }
    found.tables[index] = FoundTable.{signature = signature, physical = physical, size = size}
    found.count += 1
}

// A signature of four characters, as its bytes.
signature_of :: fn(text: string) -> u8[4] {
    signature : u8[4]
    for byte, i in text {
        if i < signature.count {
            signature[i] = cast[u8](byte)
        }
    }
    return signature
}

// The device tree's blob, at address through the direct map and at physical.
find_device_tree :: fn(address: u64, physical: u64, found: ptr[mut FoundTables]) {
    found.kind = .DeviceTree
    if big_endian_u32(address) != DEVICE_TREE_MAGIC {
        runtime.log_warn("the device tree's magic is wrong")
        return void
    }
    size :: cast[u64](big_endian_u32(address + 4))
    if size > MAX_FIRMWARE_BYTES {
        runtime.log_warn("the device tree is too big to copy: % bytes", size)
        return void
    }
    add_table(found, signature_of("DTB "), physical, size)
}

// size bytes from physical, through the kernel window, copied to into; zeros if they can't be mapped.
read_physical :: fn(kernel: ptr[mut Kernel], physical: u64, size: u64, into: u64) {
    match map_device(kernel, cast[boot_info.PhysicalAddress](physical), size) {
        case Ok(address) => {
            intrinsics.mem_copy_non_overlapping(cast[mut rawptr](into), cast[rawptr](address), cast[usize](size))
            unmap_device(kernel, address, size)
        }
        case Error(error) => intrinsics.mem_zero(cast[mut rawptr](into), cast[usize](size))
    }
}

u32_at :: fn(base: u64, offset: u64) -> u32 {
    value : u32 = 0
    intrinsics.mem_copy_non_overlapping(cast[mut rawptr](&value), cast[rawptr](base + offset), 4)
    return value
}

u64_at :: fn(base: u64, offset: u64) -> u64 {
    value : u64 = 0
    intrinsics.mem_copy_non_overlapping(cast[mut rawptr](&value), cast[rawptr](base + offset), 8)
    return value
}

// Whether the bytes at address are text's.
bytes_are :: fn(address: u64, text: string) -> bool {
    bytes :: view_of(cast[ptr[u8]](address), text.count)
    for byte, i in text {
        if i < bytes.count && bytes[i] != cast[u8](byte) {
            return false
        }
    }
    return true
}

big_endian_u32 :: fn(address: u64) -> u32 {
    bytes :: view_of(cast[ptr[u8]](address), 4)
    if bytes.count < 4 {
        return 0
    }
    return cast[u32](bytes[0]) << 24 | cast[u32](bytes[1]) << 16 | cast[u32](bytes[2]) << 8 | cast[u32](bytes[3])
}
