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
 * free for devices (decisions/0074); and, with a framebuffer, its own "FB  " table, the first framebuffer's
 * slop_os.FramebufferLayout at the framebuffer's physical address, for the terminal service to draw on
 * (decisions/0138).
 */
//SPEC: ACPI Specification 6.5, §5.2.5 (RSDP), §5.2.6 (system description table header), §5.2.7-8 (RSDT, XSDT)
//SPEC: ACPI Specification 6.5, §5.2.9 (FADT), §5.2.10 (FACS)
//SPEC: Devicetree Specification 0.4, §5.2 (the header)

/** The most firmware tables copied; any past them are left out, with a warning. */
MAX_FIRMWARE_TABLES :: 64
// The most bytes a table may have, and all of them: QEMU's are a few KiB, a large server's a few hundred.
/** The most bytes one ACPI table may have; a longer one isn't copied. */
MAX_TABLE_BYTES : u64 : 4 << 20
/** The most bytes the whole copy may have, headers and the kernel's own tables included; past it, nothing's copied. */
MAX_FIRMWARE_BYTES : u64 : 16 << 20
/** The bytes of an ACPI system description table's header, before an RSDT's or XSDT's entries. */
SDT_HEADER_SIZE : u64 : 36
/** A device tree blob's magic, its first four bytes, big-endian. */
DEVICE_TREE_MAGIC : u32 : 0xd00dfeed

/** A firmware table found, to be copied. */
FoundTable :: struct {
    /** Its signature, four characters, as in the copy's entry. */
    signature : u8[4],
    /** The physical address of its first byte. */
    physical : u64,
    /** Its size in bytes, as its header says. */
    size : u64,
}

/** The firmware tables found, in the order they're copied. */
FoundTables :: struct {
    /** Whether they're ACPI's or a device tree. */
    kind : slop_os.FirmwareKind,
    /** How many of tables are used. */
    count : usize,
    /** The tables, each at a physical address of its own. */
    tables : FoundTable[MAX_FIRMWARE_TABLES],
}

/**
 * Copy the firmware tables, if the boot has any, for the root task: kernel.firmware, a read-only Memory.
 *
 * Called once at boot, while the bootloader's memory is still there. Failures leave kernel.firmware as it was and are
 * logged: no tables found, a copy over MAX_FIRMWARE_BYTES, or no memory for it.
 *
 * @param kernel The kernel, whose ram ranges become the "RAM " table, and whose firmware it sets.
 * @param tables Where the bootloader found the firmware's tables: ACPI's RSDP on x86-64, the device tree on AArch64.
 * @param framebuffers The boot's framebuffers; the first, if there is one, becomes the "FB  " table.
 * @param direct_map_offset What's added to a physical address to reach it through the direct map, where the device
 *     tree is read.
 */
copy_firmware_tables :: fn(kernel: ptr[mut Kernel], tables: ptr[boot_info.FirmwareTables], framebuffers: boot_info.Framebuffer[],
    direct_map_offset: u64) {
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
    // The kernel's own tables after the firmware's: RAM, and the framebuffer if there is one
    own :: if framebuffers.count > 0 { cast[usize](2) } else { cast[usize](1) }
    header_bytes :: cast[u64](size_of(slop_os.FirmwareTables)) + cast[u64](found.count + own) * cast[u64](size_of(slop_os.FirmwareTable))
    total := header_bytes
    for table, i in found.tables {
        if i < found.count {
            total = frames.round_up(total, 8) + table.size
        }
    }
    total = frames.round_up(total, 8) + ram_bytes
    if own == 2 {
        total = frames.round_up(total, 8) + cast[u64](size_of(slop_os.FramebufferLayout))
    }
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
    header.count = cast[u32](found.count + own)
    entries :: view_of(cast[ptr[mut slop_os.FirmwareTable]](base + cast[u64](size_of(slop_os.FirmwareTables))), found.count + own)
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
    // The first framebuffer, whose pixels the platform service gives the terminal service
    next :: last + 1
    if own == 2 && next < entries.count && framebuffers.count > 0 {
        offset = frames.round_up(offset + ram_bytes, 8)
        shown :: &framebuffers[0]
        entries[next] = slop_os.FirmwareTable.{signature = signature_of("FB  "), size = cast[u32](size_of(slop_os.FramebufferLayout)),
            offset = offset, physical = cast[u64](shown.memory.base)}
        cast[ptr[mut slop_os.FramebufferLayout]](base + offset)^ = slop_os.FramebufferLayout.{width = shown.width, height = shown.height,
            pitch = shown.pitch, bits_per_pixel = shown.bits_per_pixel, red_size = shown.red.size, red_shift = shown.red.shift,
            green_size = shown.green.size, green_shift = shown.green.shift, blue_size = shown.blue.size, blue_shift = shown.blue.shift}
    }
    kernel.firmware = cast[u64](memory)
    runtime.log_info("firmware tables: % copied for the root task, and % RAM ranges, % bytes", found.count, kernel.ram.count, total)
}

/**
 * Find the ACPI tables an RSDP leads to, and the RSDP: every table its XSDT (or before ACPI 2, its RSDT) lists, and
 * the FADT's DSDT and FACS. Each is read through the kernel window.
 *
 * @param kernel The kernel, whose window maps them for a moment.
 * @param rsdp The RSDP's physical address; one with the wrong signature is logged, and nothing is found.
 * @param found Where they're added; its kind is set to Acpi.
 */
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

/**
 * Add an ACPI table, by its header's signature and length, unless it's found already.
 *
 * @param kernel The kernel, whose window maps its header for a moment.
 * @param found Where it's added.
 * @param physical The table's physical address.
 * @return Its length in bytes, even when it was found already or there's no room for it; 0 if the length is under 8
 *     or over MAX_TABLE_BYTES, which is logged and not added.
 */
add_sdt :: fn(kernel: ptr[mut Kernel], found: ptr[mut FoundTables], physical: u64) -> u64 {
    header : u8[8]
    read_physical(kernel, physical, 8, cast[u64](&header))
    size :: cast[u64](u32_at(cast[u64](&header), 4))
    if size < 8 || size > MAX_TABLE_BYTES {
        runtime.log_warn("a firmware table at %{#018x} has a length of %, and isn't copied", physical, size)
        return 0
    }
    signature : u8[4]
    intrinsics.mem_copy_non_overlapping(cast[mut rawptr](&signature), cast[rawptr](&header), 4)
    add_table(found, signature, physical, size)
    return size
}

/**
 * Add a table to those found, unless one at its address is there already; with no room left, it's logged and left
 * out.
 *
 * @param found Where it's added.
 * @param signature The table's four-byte signature as its header holds it, or a made-up one ("RSDP", "DTB ") for those
 *     without; kept as is, not checked.
 * @param physical Its physical address.
 * @param size Its size in bytes.
 */
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

/**
 * Make a table's signature from its text.
 *
 * @param text Its four characters, ASCII; any past four are left out, and fewer leave zeros.
 * @return Its four bytes, in the text's order, as the copy's entries hold them.
 */
signature_of :: fn(text: string) -> u8[4] {
    signature : u8[4]
    for byte, i in text {
        if i < signature.count {
            signature[i] = cast[u8](byte)
        }
    }
    return signature
}

/**
 * Find the device tree's blob, by its header's magic and total size.
 *
 * @param address Where it is through the direct map, readable for its whole size.
 * @param physical Its physical address.
 * @param found Where it's added as "DTB "; its kind is set to DeviceTree. A wrong magic or a size over
 *     MAX_FIRMWARE_BYTES is logged, and nothing is added.
 */
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

/**
 * Copy physical memory through the kernel window, mapping it uncached for the copy and unmapping it after, since
 * firmware may keep its tables in reserved memory the direct map leaves out.
 *
 * @param kernel The kernel, whose window maps it.
 * @param physical The physical address of the first byte, aligned or not.
 * @param size How many bytes.
 * @param into The kernel virtual address they go to, writable for size bytes; zeroed if they can't be mapped.
 */
read_physical :: fn(kernel: ptr[mut Kernel], physical: u64, size: u64, into: u64) {
    match map_device(kernel, cast[boot_info.PhysicalAddress](physical), size) {
        case Ok(address) => {
            intrinsics.mem_copy_non_overlapping(cast[mut rawptr](into), cast[rawptr](address), cast[usize](size))
            unmap_device(kernel, address, size)
        }
        case Error(error) => intrinsics.mem_zero(cast[mut rawptr](into), cast[usize](size))
    }
}

/**
 * Read a little-endian u32 at any alignment.
 *
 * @param base A kernel virtual address.
 * @param offset The value's offset from base, in bytes.
 * @return The four bytes at base + offset, read as a little-endian u32.
 */
u32_at :: fn(base: u64, offset: u64) -> u32 {
    value : u32 = 0
    intrinsics.mem_copy_non_overlapping(cast[mut rawptr](&value), cast[rawptr](base + offset), 4)
    return value
}

/**
 * Read a little-endian u64 at any alignment.
 *
 * @param base A kernel virtual address.
 * @param offset The value's offset from base, in bytes.
 * @return The eight bytes at base + offset, read as a little-endian u64.
 */
u64_at :: fn(base: u64, offset: u64) -> u64 {
    value : u64 = 0
    intrinsics.mem_copy_non_overlapping(cast[mut rawptr](&value), cast[rawptr](base + offset), 8)
    return value
}

/**
 * Tell whether the bytes at an address are a text's.
 *
 * @param address A kernel virtual address, readable for the text's length.
 * @param text The text, as ASCII.
 * @return True if the bytes there match it, each one.
 */
bytes_are :: fn(address: u64, text: string) -> bool {
    bytes :: view_of(cast[ptr[u8]](address), text.count)
    for byte, i in text {
        if i < bytes.count && bytes[i] != cast[u8](byte) {
            return false
        }
    }
    return true
}

/**
 * Read a big-endian u32, as a device tree's are, at any alignment.
 *
 * @param address A kernel virtual address, readable for 4 bytes.
 * @return The four bytes at address, most significant first.
 */
big_endian_u32 :: fn(address: u64) -> u32 {
    bytes :: view_of(cast[ptr[u8]](address), 4)
    if bytes.count < 4 {
        return 0
    }
    return cast[u32](bytes[0]) << 24 | cast[u32](bytes[1]) << 16 | cast[u32](bytes[2]) << 8 | cast[u32](bytes[3])
}
