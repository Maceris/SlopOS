/*
 * GUID partition tables (roadmap 8a, decisions/0086): reading a disk's, through a function that reads its blocks, and
 * writing one, for the image builder and the tests. A table is a protective MBR in block 0, a header in block 1 and
 * the partition entries after it, with a copy of both at the disk's end, each header checked by its CRC32 and naming
 * its entries' CRC32. Reading takes the primary header, or the backup where the primary doesn't check out.
 *
 * It's a portable package: the partition server reads a disk with it, and its tests run hosted over a buffer.
 */
/**
 * Read and write GUID partition tables.
 *
 * SPEC: UEFI Specification 2.10, §5.2.3 (protective MBR), §5.3 (GPT disk layout, header, partition entries).
 */
package gpt

/** The size of a disk block, in bytes: GPT's logical block, the only size this package reads or writes. */
BLOCK_BYTES : u64 : 512
/** The 8 ASCII bytes a header starts with, not terminated. */
SIGNATURE :: "EFI PART"
/** The header revision read and written, 1.0; a header of any other revision is taken as no header. */
REVISION : u32 : 0x00010000
/** The bytes of a header that its CRC32 covers when written, and the least header_size a read header may say. */
HEADER_BYTES : u32 : 92
/** The size of one partition entry, in bytes; a header naming another entry size is taken as no header. */
ENTRY_BYTES : u32 : 128
/**
 * The number of partition entries written, and the most a read header may name: 128, the least the specification
 * lets a table have, so entries take ENTRY_BLOCKS blocks.
 */
ENTRY_COUNT : u32 : 128
/** The blocks the partition entries take on disk: ENTRY_COUNT entries of ENTRY_BYTES each, 16 KiB. */
ENTRY_BLOCKS : u64 : 32
/**
 * The most partitions a read table holds: the first this many entries in use, in entry order; any after them are
 * left out of the Table without an error.
 */
MAX_PARTITIONS :: 16
/** The UTF-16 code units in an entry's name field, zero-padded when the name is shorter. */
NAME_UNITS :: 36
/** The most bytes a name takes as UTF-8: NAME_UNITS code units of at most 3 bytes each. */
NAME_BYTES :: 108

/** A GUID, as its 16 bytes are on disk (mixed-endian as the specification lays them out, never reordered here). */
Guid :: u8[16]

/** A table's header, as it is in its block: little-endian, HEADER_BYTES long, the rest of its block zero. */
Header :: struct #packed {
    /** SIGNATURE's 8 bytes. */
    signature : u8[8],
    /** The header's revision; REVISION for every header read or written here. */
    revision : u32le,
    /** The header's size in bytes, which its CRC32 covers: at least HEADER_BYTES and at most BLOCK_BYTES. */
    header_size : u32le,
    /** The CRC32 of the header's header_size bytes, computed with this field zero. */
    header_crc : u32le,
    /** Reserved; zero. */
    reserved : u32le,
    /** The block this header is in: 1 for the primary, the disk's last block for the backup. */
    my_block : u64le,
    /** The block the other copy of the header is in. */
    alternate_block : u64le,
    /** The first block a partition may use. */
    first_usable : u64le,
    /** The last block a partition may use, inclusive. */
    last_usable : u64le,
    /** The disk's GUID. */
    disk_guid : Guid,
    /** The first block of this copy's partition entries: 2 for the primary, before the backup header for the backup. */
    entries_block : u64le,
    /** The number of partition entries, used or not: 1 to ENTRY_COUNT for a header read here. */
    entry_count : u32le,
    /** The size of each partition entry in bytes; ENTRY_BYTES for a header read here. */
    entry_size : u32le,
    /** The CRC32 of the entry_count * entry_size bytes of partition entries. */
    entries_crc : u32le,
}

#assert size_of(Header) == 92

/** A partition entry, as it is in the entries' blocks: little-endian, ENTRY_BYTES long; all zero when unused. */
Entry :: struct #packed {
    /** The partition's type; all zero means the entry is unused. */
    type_guid : Guid,
    /** The partition's own GUID, unique to it. */
    unique_guid : Guid,
    /** The partition's first block, an LBA from the disk's start. */
    first_block : u64le,
    /** The partition's last block, inclusive, an LBA from the disk's start. */
    last_block : u64le,
    /** The partition's attribute bits, as the specification defines them; kept, not interpreted, here. */
    attributes : u64le,
    /** The partition's name, UTF-16LE, ending at the first zero unit or after NAME_UNITS units. */
    name : u16le[NAME_UNITS],
}

#assert size_of(Entry) == 128

/** A partition as read from an entry in use: its blocks, its type and its own GUID, and its name as UTF-8. */
Partition :: struct {
    /** The partition's first block, an LBA in BLOCK_BYTES blocks; within the table's usable blocks. */
    first : u64,
    /** How many blocks the partition takes, at least 1. */
    count : u64,
    /** The partition's type GUID, never all zero. */
    type_guid : Guid,
    /** The partition's own GUID. */
    unique_guid : Guid,
    /** The entry's attribute bits, uninterpreted. */
    attributes : u64,
    /** The name as UTF-8, its first name_length bytes used; unpaired surrogates in the entry became '?'. */
    name : u8[NAME_BYTES],
    /** How many bytes of name are used, 0 to NAME_BYTES. */
    name_length : u32,
}

/** A table, as read: what its header says of the disk, and the partitions in use. */
Table :: struct {
    /** The disk's GUID, from the header read. */
    disk_guid : Guid,
    /** The first block a partition may use, from the header read. */
    first_usable : u64,
    /** The last block a partition may use, inclusive, from the header read. */
    last_usable : u64,
    /** The partitions of the entries in use, in entry order; the first count are filled. */
    partitions : Partition[MAX_PARTITIONS],
    /** How many of partitions are filled, 0 to MAX_PARTITIONS. */
    count : u32,
    /** Whether the primary header or its entries were bad or unreadable, so the backup's were read instead. */
    from_backup : bool,
}

/** A disk to read a table from: its size, and a function that reads its blocks. */
Disk :: struct #scoped {
    /** What read is given back as its context, the caller's own; never read here. */
    context : rawptr,
    /** The disk's size in BLOCK_BYTES blocks; the backup header is in its last block. */
    block_count : u64,
    /**
     * Read count blocks, from block first, into into, which holds at least count * BLOCK_BYTES bytes; true if they
     * were read, false if the disk couldn't be read there.
     */
    read : fn(context: rawptr, first: u64, count: u64, into: mut u8[]) -> bool,
}

/** Why a disk's table couldn't be read. */
ReadError :: enum {
    /** Neither header checks out, the disk is too small for a table, or the buffer is too small for its entries. */
    NoTable,
    /** A header checks out, but its entries' CRC32 doesn't match, or an entry's blocks are outside the usable ones. */
    BadEntries,
    /** The disk couldn't be read where a header or its entries are. */
    Unreadable,
}

/**
 * Read the disk's partition table: its primary header and entries, or, where either doesn't check out or can't be
 * read, its backup's.
 *
 * Nothing is written to the disk: a bad primary isn't repaired from the backup, only reported by from_backup.
 *
 * @param disk The disk, read through its read function; it has to have at least 2 * (ENTRY_BLOCKS + 2) blocks.
 * @param buffer Where the entries are read to, the caller's, overwritten; at least ENTRY_BLOCKS * BLOCK_BYTES bytes.
 *     Nothing in the Table points into it, so it may be reused once this returns.
 * @return The table, with from_backup set if the backup's header and entries were the ones read.
 * @error NoTable The disk or the buffer is too small, or the primary's header doesn't check out and the backup's
 *     doesn't either.
 * @error BadEntries The primary's header checks out but its entries don't, and the backup didn't give a table.
 * @error Unreadable The primary's header or entries couldn't be read, and the backup didn't give a table.
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

/**
 * Read the table whose header is at one block, if it and its entries check out.
 *
 * @param disk The disk, read through its read function.
 * @param at The header's block: 1 for the primary, block_count - 1 for the backup. The header has to say it's there.
 * @param buffer Where the entries are read to, the caller's, overwritten; it has to hold the header's entries.
 * @return The table, from_backup false; the first MAX_PARTITIONS entries in use, any others left out.
 * @error NoTable The header doesn't check out (see header_checks_out).
 * @error BadEntries The entries' CRC32 isn't the header's, or an entry in use is outside the usable blocks or ends
 *     before it starts.
 * @error Unreadable The header's block or its entries couldn't be read, or buffer can't hold the entries.
 */
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

/**
 * Tell whether a header read from a block is a GPT header this package reads.
 *
 * It checks the signature, the revision (REVISION), the size (HEADER_BYTES to BLOCK_BYTES), the entry size
 * (ENTRY_BYTES) and count (1 to ENTRY_COUNT), that it says it's at the block it was read from, its CRC32 over its size
 * with its own CRC field zero, and that its usable blocks and its ENTRY_BLOCKS of entries are on the disk.
 *
 * @param header The header, a view of block's start.
 * @param block The block's bytes as read, BLOCK_BYTES of them; not changed (the CRC is computed over a copy).
 * @param at The block it was read from, which the header's my_block has to name.
 * @param block_count The disk's size in blocks.
 * @return True if every check passes; false if any fails.
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

/**
 * Convert an entry's UTF-16LE name to UTF-8, up to its first zero unit or its NAME_UNITS units.
 *
 * @param name The entry's name field.
 * @param into Where the UTF-8 goes, from its start; bytes past the returned length are left as they were.
 * @return The UTF-8 length in bytes, 0 to NAME_BYTES. An unpaired surrogate becomes '?'.
 */
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

/**
 * Put a code point as UTF-8 into a name buffer, if all its bytes fit.
 *
 * @param into Where the UTF-8 goes, a name buffer of NAME_BYTES.
 * @param at The byte offset to put it at, 0 to NAME_BYTES.
 * @param code The code point, at most 0x10ffff; surrogates aren't checked for.
 * @return Where the next code point goes: at plus its 1 to 4 bytes, or at unchanged if they didn't fit, so nothing
 *     was written.
 */
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

/**
 * Get a partition's name as text.
 *
 * @param partition The partition, as read_table filled it.
 * @return Its name, UTF-8, possibly empty: a view into partition's name, good as long as the partition is.
 */
name_of :: fn(partition: ptr[Partition]) -> string {
    return string_of(&partition.name[0], cast[usize](partition.name_length))
}

/**
 * Tell whether a GUID is all zero, as an unused entry's type is.
 *
 * @param guid The GUID, as its 16 bytes are on disk.
 * @return True if all 16 bytes are zero.
 */
is_zero :: fn(guid: Guid) -> bool {
    for byte in guid {
        if byte != 0 {
            return false
        }
    }
    return true
}

/**
 * Compute the CRC-32 that Ethernet, zlib and GPT use: reflected, polynomial 0xedb88320, starting and ending inverted.
 *
 * @param bytes The bytes, possibly none.
 * @return The CRC; 0 for no bytes.
 */
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

/** A partition to write: its blocks, its type, its GUID and its name. */
NewPartition :: struct {
    /** The partition's first block, an LBA; at least ENTRY_BLOCKS + 2. */
    first : u64,
    /** How many blocks it takes, at least 1, ending at most at block_count - ENTRY_BLOCKS - 2. */
    count : u64,
    /** The partition's type GUID; it should not be all zero, which marks an entry unused. */
    type_guid : Guid,
    /** The partition's own GUID. */
    unique_guid : Guid,
    /**
     * The name, ASCII: each byte becomes one UTF-16 unit, so other UTF-8 is mangled. Bytes past NAME_UNITS are
     * dropped.
     */
    name : string,
}

/**
 * Write a partition table into a disk image: the protective MBR, the primary header and entries, and the backup
 * entries and header at the disk's end.
 *
 * Only the bytes of the table are written: the MBR's partition record and boot signature, the headers'
 * HEADER_BYTES and the entries' blocks. The rest of the image, including the rest of block 0 and of the headers'
 * blocks, is left as it was, so the image should start out zero. On false, nothing has been written. The entries are
 * written in the order given, with attributes zero, and the rest of the ENTRY_COUNT entries unused.
 *
 * @param image The disk's bytes, at least block_count * BLOCK_BYTES of them.
 * @param block_count The disk's size in blocks, at least 2 * (ENTRY_BLOCKS + 2).
 * @param disk_guid The disk's GUID, put in both headers.
 * @param partitions The partitions, at most ENTRY_COUNT; each within the usable blocks, from ENTRY_BLOCKS + 2 to
 *     block_count - ENTRY_BLOCKS - 2. Overlaps aren't checked for.
 * @return True if the table was written; false if the image or disk is too small, there are too many partitions,
 *     or one is empty or outside the usable blocks.
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

/**
 * Write a header, its CRC32 computed, into a disk image.
 *
 * Only its HEADER_BYTES are written; the rest of its block is left as it was.
 *
 * @param image The disk's bytes; bytes that would fall past its end are dropped.
 * @param at The block the header goes in, which it names as its own.
 * @param alternate The block of the other copy of the header.
 * @param entries_block The first block of this copy's entries.
 * @param first_usable The first block a partition may use.
 * @param last_usable The last block a partition may use, inclusive.
 * @param disk_guid The disk's GUID.
 * @param entries_crc The CRC32 of the ENTRY_COUNT entries' bytes.
 */
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

/**
 * Put a byte into an image, if it's within it.
 *
 * @param image The disk's bytes; nothing past their end is written.
 * @param at The byte offset; past the image's end, nothing is written.
 * @param value The byte, any value.
 */
put_u8 :: fn(image: mut u8[], at: usize, value: u8) {
    if at < image.count {
        image[at] = value
    }
}

/**
 * Put a little-endian u32 into an image, each of its bytes only if it's within the image.
 *
 * @param image The disk's bytes; nothing past their end is written.
 * @param at The byte offset of its first byte.
 * @param value The value, any u32, written low byte first.
 */
put_u32 :: fn(image: mut u8[], at: usize, value: u32) {
    for i in 0..<cast[usize](4) {
        put_u8(image, at + i, cast[u8]((value >> (8 * cast[u32](i))) & 0xff))
    }
}
