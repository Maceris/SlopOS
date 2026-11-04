/**
 * The GPT package's tests, as a hosted program (tools/unit_tests.py): main returns 0 if everything worked, or the
 * number of the first check that failed. A table written into a buffer standing in for a disk reads back as written;
 * with its primary header broken it's read from its backup; with both sets of entries broken it isn't read at all.
 */
package gpt_test

import runtime from "base"
import gpt from ".."
import hosted_faults from "../../robustness/hosted"

/** The size of the stand-in disk, in gpt.BLOCK_BYTES blocks: 128 KiB, room for the table and two partitions. */
BLOCKS : u64 : 256

/** The stand-in disk read_blocks reads: a buffer of BLOCKS blocks. */
Image :: struct {
    /** The disk's bytes, the test's own, BLOCKS * gpt.BLOCK_BYTES of them. */
    bytes : mut u8[],
}

/**
 * Run the checks in order, stopping at the first that fails.
 *
 * They check crc32 against the standard check value; that write_table writes the protective MBR and a table that
 * read_table reads back with both partitions as written; that a broken primary header is read from the backup; that
 * with both copies of the entries broken no table is read; and that write_table refuses a partition outside the usable
 * blocks.
 *
 * @return 0 if every check passed, or the number of the first that failed, 1 to 13.
 */
checks :: fn() -> int {
    // The CRC everyone checks against
    check :: "123456789"
    if gpt.crc32(string_bytes(check)) != 0xcbf43926 {
        return 1
    }
    bytes, error :: runtime.new_array(u8, cast[usize](BLOCKS * gpt.BLOCK_BYTES))
    if error != null {
        return 2
    }
    defer runtime.free_array(bytes)
    image := Image.{bytes = bytes}
    system :: gpt.NewPartition.{first = 34, count = 100, type_guid = guid(1), unique_guid = guid(2), name = "SlopOS check"}
    spare :: gpt.NewPartition.{first = 134, count = 50, type_guid = guid(3), unique_guid = guid(4), name = "spare"}
    if !gpt.write_table(bytes, BLOCKS, guid(9), gpt.NewPartition.[system, spare]) {
        return 3
    }
    if bytes.count < 512 || bytes[510] != 0x55 || bytes[511] != 0xaa || bytes[446 + 4] != 0xee {
        return 4
    }
    disk := gpt.Disk.{context = cast[rawptr](&image), block_count = BLOCKS, read = read_blocks}
    entries, entries_error :: runtime.new_array(u8, cast[usize](gpt.ENTRY_BLOCKS * gpt.BLOCK_BYTES))
    if entries_error != null {
        return 5
    }
    defer runtime.free_array(entries)

    // As written
    table := gpt.read_table(&disk, entries) or_return 6
    if table.count != 2 || table.from_backup || table.first_usable != 34 || table.last_usable != BLOCKS - 34 {
        return 7
    }
    if table.partitions[0].first != 34 || table.partitions[0].count != 100 || gpt.name_of(&table.partitions[0]) != "SlopOS check"
        || table.partitions[0].type_guid != guid(1) || table.partitions[0].unique_guid != guid(2) {
        return 8
    }
    if table.partitions[1].first != 134 || table.partitions[1].count != 50 || gpt.name_of(&table.partitions[1]) != "spare" {
        return 9
    }

    // Its primary header broken: from the backup
    flip(bytes, cast[usize](gpt.BLOCK_BYTES) + 40)
    from_backup := gpt.read_table(&disk, entries) or_return 10
    if !from_backup.from_backup || from_backup.count != 2 {
        return 11
    }

    // Both sets of entries broken: none
    flip(bytes, cast[usize](2 * gpt.BLOCK_BYTES))
    flip(bytes, cast[usize]((BLOCKS - gpt.ENTRY_BLOCKS - 1) * gpt.BLOCK_BYTES))
    if gpt.read_table(&disk, entries) is_ok {
        return 12
    }

    // A partition outside the usable blocks isn't written
    if gpt.write_table(bytes, BLOCKS, guid(9), gpt.NewPartition.[gpt.NewPartition.{first = 2, count = 10, type_guid = guid(1)}]) {
        return 13
    }
    return 0
}

/**
 * Invert one byte of the image, as a broken disk would have it.
 *
 * @param bytes The image's bytes, changed in place.
 * @param at The byte's offset; past the image's end, nothing changes.
 */
flip :: fn(bytes: mut u8[], at: usize) {
    if at < bytes.count {
        bytes[at] ~= 0xff
    }
}

/**
 * Make a GUID of one repeated byte, distinct for each byte.
 *
 * @param byte The byte; 0 makes the all-zero GUID of an unused entry.
 * @return The GUID, its 16 bytes all the given byte.
 */
guid :: fn(byte: u8) -> gpt.Guid {
    made : gpt.Guid
    for &each in made {
        each^ = byte
    }
    return made
}

/**
 * Read blocks from the stand-in disk, as a gpt.Disk's read does.
 *
 * @param context The Image, as a rawptr.
 * @param first The first block to read.
 * @param count How many blocks to read.
 * @param into Where they go; at least count * gpt.BLOCK_BYTES bytes.
 * @return True if they were read; false if they run past the image's end or into is too small, with nothing read.
 */
read_blocks :: fn(context: rawptr, first: u64, count: u64, into: mut u8[]) -> bool {
    image :: cast[ptr[Image]](context)
    start :: first * gpt.BLOCK_BYTES
    bytes :: count * gpt.BLOCK_BYTES
    if start + bytes > cast[u64](image.bytes.count) || bytes > cast[u64](into.count) {
        return false
    }
    for &byte, i in into {
        at :: cast[usize](start) + i
        if cast[u64](i) < bytes && at < image.bytes.count {
            byte^ = image.bytes[at]
        }
    }
    return true
}

/**
 * Run the checks, with fault injection as SLOPOS_FAIL asks (robustness/hosted, tools/unit_tests.py --robustness).
 *
 * @return 0 if every check passed, or the number of the first that failed.
 */
main :: fn() -> int {
    return hosted_faults.run(checks)
}
