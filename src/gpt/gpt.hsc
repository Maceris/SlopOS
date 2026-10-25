/*
 * GUID partition tables (roadmap 8a, decisions/0086): reading a disk's, through a function that reads its blocks, and
 * writing one, for the image builder and the tests. A table is a protective MBR in block 0, a header in block 1 and
 * the partition entries after it, with a copy of both at the disk's end, each header checked by its CRC32 and naming
 * its entries' CRC32. Reading takes the primary header, or the backup where the primary doesn't check out.
 *
 * It's a portable package: the partition server reads a disk with it, and its tests run hosted over a buffer.
 */
//SPEC: UEFI Specification 2.10, §5.2.3 (protective MBR), §5.3 (GPT disk layout, header, partition entries)
package gpt

BLOCK_BYTES : u64 : 512
SIGNATURE :: "EFI PART"
REVISION : u32 : 0x00010000
HEADER_BYTES : u32 : 92
ENTRY_BYTES : u32 : 128
// Entries are kept in this many blocks: 128 entries of 128 bytes, as every table has at least
ENTRY_COUNT : u32 : 128
ENTRY_BLOCKS : u64 : 32
// The partitions a table is read with, at most: the first so many entries in use
MAX_PARTITIONS :: 16
// A name's UTF-16 code units, and the most bytes it takes as UTF-8
NAME_UNITS :: 36
NAME_BYTES :: 108

Guid :: u8[16]

// A table's header, as it is in its block.
Header :: struct #packed {
    signature : u8[8],
    revision : u32le,
    header_size : u32le,
    header_crc : u32le,
    reserved : u32le,
    my_block : u64le,
    alternate_block : u64le,
    first_usable : u64le,
    last_usable : u64le,
    disk_guid : Guid,
    entries_block : u64le,
    entry_count : u32le,
    entry_size : u32le,
    entries_crc : u32le,
}

#assert size_of(Header) == 92

// A partition entry, as it is in the entries' blocks.
Entry :: struct #packed {
    type_guid : Guid,
    unique_guid : Guid,
    first_block : u64le,
    last_block : u64le,
    attributes : u64le,
    name : u16le[NAME_UNITS],
}

#assert size_of(Entry) == 128

// A partition: its blocks, from first, count of them; its type and its own GUID, and its name as UTF-8.
Partition :: struct {
    first : u64,
    count : u64,
    type_guid : Guid,
    unique_guid : Guid,
    attributes : u64,
    name : u8[NAME_BYTES],
    name_length : u32,
}

// A table, as read.
Table :: struct {
    disk_guid : Guid,
    first_usable : u64,
    last_usable : u64,
    partitions : Partition[MAX_PARTITIONS],
    count : u32,
    // Whether the primary header was bad, so the backup was read
    from_backup : bool,
}

// A disk to read: block_count blocks, read through read, count blocks from first into into, true if it could.
Disk :: struct #scoped {
    context : rawptr,
    block_count : u64,
    read : fn(context: rawptr, first: u64, count: u64, into: mut u8[]) -> bool,
}

ReadError :: enum {
    // Neither header checks out
    NoTable,
    // A header checks out, but its entries don't
    BadEntries,
    // The disk couldn't be read
    Unreadable,
}

/*
 * The disk's table: its primary header and entries, or, where either doesn't check out, its backup's. buffer holds
 * the entries as they're read, at least ENTRY_BLOCKS blocks.
 */
read_table :: fn(disk: ptr[Disk], buffer: mut u8[]) -> Result[Table, ReadError] {
    if disk.block_count < 2 * (ENTRY_BLOCKS + 2) || cast[u64](buffer.count) < ENTRY_BLOCKS * BLOCK_BYTES {
        return .Error(.NoTable)
    }
    failure := ReadError.NoTable
    match read_at(disk, 1, buffer) {
        case Ok(table) => return .Ok(table)
        case Error(error) => failure = error
    }
    match read_at(disk, disk.block_count - 1, buffer) {
        case Ok(table) => {
            found := table
            found.from_backup = true
            return .Ok(found)
        }
        case Error(error) => return .Error(failure)
    }
}

// The table whose header is at block at, if it and its entries check out.
read_at :: fn(disk: ptr[Disk], at: u64, buffer: mut u8[]) -> Result[Table, ReadError] {
    header_block : u8[512]
    if !disk.read(disk.context, at, 1, header_block) {
        return .Error(.Unreadable)
    }
    header :: cast[ptr[Header]](&header_block[0])
    if !header_checks_out(header, header_block, at, disk.block_count) {
        return .Error(.NoTable)
    }
    entries_bytes :: cast[u64](cast[u32](header.entry_count)) * cast[u64](cast[u32](header.entry_size))
    blocks :: (entries_bytes + BLOCK_BYTES - 1) / BLOCK_BYTES
    if blocks > ENTRY_BLOCKS || buffer.count == 0 || entries_bytes > cast[u64](buffer.count)
        || !disk.read(disk.context, cast[u64](header.entries_block), blocks, buffer) {
        return .Error(.Unreadable)
    }
    if crc32(view_of(&buffer[0], cast[usize](entries_bytes))) != cast[u32](header.entries_crc) {
        return .Error(.BadEntries)
    }
    table := Table.{disk_guid = header.disk_guid, first_usable = cast[u64](header.first_usable), last_usable = cast[u64](header.last_usable)}
    for index in 0..<cast[u64](cast[u32](header.entry_count)) {
        if cast[usize](table.count) >= table.partitions.count {
            break
        }
        offset :: cast[usize](index * cast[u64](cast[u32](header.entry_size)))
        if offset >= buffer.count || offset + size_of(Entry) > buffer.count {
            break
        }
        entry :: cast[ptr[Entry]](&buffer[offset])
        if is_zero(entry.type_guid) {
            continue
        }
        first :: cast[u64](entry.first_block)
        last :: cast[u64](entry.last_block)
        // A partition outside the usable blocks, or ending before it starts, is a broken table's
        if first < table.first_usable || last > table.last_usable || last < first {
            return .Error(.BadEntries)
        }
        partition := Partition.{first = first, count = last - first + 1, type_guid = entry.type_guid, unique_guid = entry.unique_guid,
            attributes = cast[u64](entry.attributes)}
        partition.name_length = utf8_of_name(&entry.name, &partition.name)
        table.partitions[cast[usize](table.count)] = partition
        table.count += 1
    }
    return .Ok(table)
}

/*
 * Whether a header read at block at, of a disk of block_count blocks, is one: its signature, revision and size, its
 * CRC32 over its size with its own field zero, where it says it is, and its usable blocks and entries on the disk.
 */
header_checks_out :: fn(header: ptr[Header], block: u8[], at: u64, block_count: u64) -> bool {
    for character, i in SIGNATURE {
        if i >= header.signature.count || header.signature[i] != cast[u8](character) {
            return false
        }
    }
    size :: cast[u32](header.header_size)
    if cast[u32](header.revision) != REVISION || size < HEADER_BYTES || cast[u64](size) > BLOCK_BYTES
        || cast[u64](header.my_block) != at || cast[u32](header.entry_size) != ENTRY_BYTES
        || cast[u32](header.entry_count) == 0 || cast[u32](header.entry_count) > ENTRY_COUNT {
        return false
    }
    copy : u8[512]
    for byte, i in block {
        if i < copy.count {
            copy[i] = byte
        }
    }
    // The CRC is of the header with its own field zero
    for i in 16..<20 {
        copy[i] = 0
    }
    if crc32(view_of(&copy[0], cast[usize](size))) != cast[u32](header.header_crc) {
        return false
    }
    first :: cast[u64](header.first_usable)
    last :: cast[u64](header.last_usable)
    entries :: cast[u64](header.entries_block)
    return first <= last && last < block_count && entries < block_count && entries + ENTRY_BLOCKS <= block_count
}

// A GPT name's UTF-16LE code units as UTF-8, up to its first zero: its length. Unpaired surrogates become '?'.
utf8_of_name :: fn(name: ptr[u16le[NAME_UNITS]], into: ptr[mut u8[NAME_BYTES]]) -> u32 {
    length : usize = 0
    i : usize = 0
    loop {
        if i >= NAME_UNITS {
            break
        }
        unit :: cast[u32](cast[u16](name^[i]))
        if unit == 0 {
            break
        }
        i += 1
        code := unit
        if unit >= 0xd800 && unit < 0xdc00 && i < NAME_UNITS {
            low :: cast[u32](cast[u16](name^[i]))
            if low >= 0xdc00 && low < 0xe000 {
                code = 0x10000 + ((unit - 0xd800) << 10) + (low - 0xdc00)
                i += 1
            }
            else {
                code = cast[u32]('?')
            }
        }
        else if unit >= 0xd800 && unit < 0xe000 {
            code = cast[u32]('?')
        }
        length = put_utf8(into, length, code)
    }
    return cast[u32](length)
}

// code as UTF-8 at at in into, if it fits: where the next goes.
put_utf8 :: fn(into: ptr[mut u8[NAME_BYTES]], at: usize, code: u32) -> usize {
    bytes : u8[4]
    count : usize = 0
    if code < 0x80 {
        bytes[0] = cast[u8](code)
        count = 1
    }
    else if code < 0x800 {
        bytes[0] = cast[u8](0xc0 | (code >> 6))
        bytes[1] = cast[u8](0x80 | (code & 0x3f))
        count = 2
    }
    else if code < 0x10000 {
        bytes[0] = cast[u8](0xe0 | (code >> 12))
        bytes[1] = cast[u8](0x80 | ((code >> 6) & 0x3f))
        bytes[2] = cast[u8](0x80 | (code & 0x3f))
        count = 3
    }
    else {
        bytes[0] = cast[u8](0xf0 | (code >> 18))
        bytes[1] = cast[u8](0x80 | ((code >> 12) & 0x3f))
        bytes[2] = cast[u8](0x80 | ((code >> 6) & 0x3f))
        bytes[3] = cast[u8](0x80 | (code & 0x3f))
        count = 4
    }
    if at + count > NAME_BYTES {
        return at
    }
    for byte, j in bytes {
        k :: at + j
        if j < count && k < into^.count {
            into^[k] = byte
        }
    }
    return at + count
}

// A partition's name, as text.
name_of :: fn(partition: ptr[Partition]) -> string {
    return string_of(&partition.name[0], cast[usize](partition.name_length))
}

is_zero :: fn(guid: Guid) -> bool {
    for byte in guid {
        if byte != 0 {
            return false
        }
    }
    return true
}

// CRC-32 as Ethernet, zlib and GPT have it: reflected, polynomial 0xedb88320, starting and ending inverted.
crc32 :: fn(bytes: u8[]) -> u32 {
    crc := cast[u32](0xffffffff)
    for byte in bytes {
        crc ~= cast[u32](byte)
        for bit in 0..<8 {
            crc = if crc & 1 != 0 { (crc >> 1) ~ 0xedb88320 } else { crc >> 1 }
        }
    }
    return ~crc
}

// Writing a table

// A partition to write: its blocks, its type, its GUID and its name, ASCII.
NewPartition :: struct {
    first : u64,
    count : u64,
    type_guid : Guid,
    unique_guid : Guid,
    name : string,
}

/*
 * A table for a disk of block_count blocks, written into image, the disk's bytes: the protective MBR, the primary
 * header and entries, and the backup entries and header at the end. The partitions must be in the usable blocks,
 * from ENTRY_BLOCKS + 2 to block_count - ENTRY_BLOCKS - 2; false if one isn't, or there are too many.
 */
write_table :: fn(image: mut u8[], block_count: u64, disk_guid: Guid, partitions: NewPartition[]) -> bool {
    if cast[u64](image.count) < block_count * BLOCK_BYTES || block_count < 2 * (ENTRY_BLOCKS + 2) || partitions.count > cast[usize](ENTRY_COUNT) {
        return false
    }
    first_usable :: ENTRY_BLOCKS + 2
    last_usable :: block_count - ENTRY_BLOCKS - 2
    entries : u8[16384]
    for partition, index in partitions {
        if partition.count == 0 || partition.first < first_usable || partition.first + partition.count - 1 > last_usable {
            return false
        }
        at :: index * cast[usize](ENTRY_BYTES)
        if at >= entries.count {
            return false
        }
        entry :: cast[ptr[mut Entry]](&entries[at])
        entry.type_guid = partition.type_guid
        entry.unique_guid = partition.unique_guid
        entry.first_block = cast[u64le](partition.first)
        entry.last_block = cast[u64le](partition.first + partition.count - 1)
        for character, i in partition.name {
            if i < entry.name.count {
                entry.name[i] = cast[u16le](cast[u16](character))
            }
        }
    }
    entries_crc :: crc32(entries)
    // The protective MBR: one partition of type 0xee over the whole disk, from block 1, and the boot signature
    mbr :: cast[usize](446)
    put_u8(image, mbr + 2, 2)
    put_u8(image, mbr + 4, 0xee)
    put_u8(image, mbr + 5, 0xff)
    put_u8(image, mbr + 6, 0xff)
    put_u8(image, mbr + 7, 0xff)
    put_u32(image, mbr + 8, 1)
    put_u32(image, mbr + 12, if block_count - 1 > 0xffffffff { 0xffffffff } else { cast[u32](block_count - 1) })
    put_u8(image, 510, 0x55)
    put_u8(image, 511, 0xaa)
    primary :: cast[usize](2 * BLOCK_BYTES)
    backup :: cast[usize]((block_count - ENTRY_BLOCKS - 1) * BLOCK_BYTES)
    for byte, i in entries {
        put_u8(image, primary + i, byte)
        put_u8(image, backup + i, byte)
    }
    put_header(image, 1, block_count - 1, 2, first_usable, last_usable, disk_guid, entries_crc)
    put_header(image, block_count - 1, 1, block_count - ENTRY_BLOCKS - 1, first_usable, last_usable, disk_guid, entries_crc)
    return true
}

put_header :: fn(image: mut u8[], at: u64, alternate: u64, entries_block: u64, first_usable: u64, last_usable: u64, disk_guid: Guid,
    entries_crc: u32) {
    header := Header.{revision = cast[u32le](REVISION), header_size = cast[u32le](HEADER_BYTES), my_block = cast[u64le](at),
        alternate_block = cast[u64le](alternate), first_usable = cast[u64le](first_usable), last_usable = cast[u64le](last_usable),
        disk_guid = disk_guid, entries_block = cast[u64le](entries_block), entry_count = cast[u32le](ENTRY_COUNT),
        entry_size = cast[u32le](ENTRY_BYTES), entries_crc = cast[u32le](entries_crc)}
    for character, i in SIGNATURE {
        if i < header.signature.count {
            header.signature[i] = cast[u8](character)
        }
    }
    header.header_crc = cast[u32le](crc32(view_of(cast[ptr[u8]](&header), cast[usize](HEADER_BYTES))))
    start :: cast[usize](at * BLOCK_BYTES)
    for byte, i in view_of(cast[ptr[u8]](&header), cast[usize](HEADER_BYTES)) {
        put_u8(image, start + i, byte)
    }
}

// A byte, little-endian u32, into image, where it fits.
put_u8 :: fn(image: mut u8[], at: usize, value: u8) {
    if at < image.count {
        image[at] = value
    }
}

put_u32 :: fn(image: mut u8[], at: usize, value: u32) {
    for i in 0..<cast[usize](4) {
        put_u8(image, at + i, cast[u8]((value >> (8 * cast[u32](i))) & 0xff))
    }
}
