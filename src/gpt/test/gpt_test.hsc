/**
 * The GPT package's tests, as a hosted program (tools/unit_tests.py, decisions/0175): main runs them and returns how
 * many failed. A table written into a buffer standing in for a disk reads back as written; with its primary header
 * broken it's read from its backup; with both sets of entries broken it isn't read at all.
 */
package gpt_test

import compiler from "base"
import runtime from "base"
import testing from "std"
import gpt from ".."
import hosted_faults from "../../robustness/hosted"

/** The size of the stand-in disk, in gpt.BLOCK_BYTES blocks: 128 KiB, room for the table and two partitions. */
BLOCKS : u64 : 256

/** The stand-in disk read_blocks reads: a buffer of BLOCKS blocks. */
Image :: struct {
    /** The disk's bytes, the test's own, BLOCKS * gpt.BLOCK_BYTES of them. */
    bytes : mut u8[],
}

/** The partitions every test's table has: one for SlopOS's check, and a spare. */
PARTITIONS :: gpt.NewPartition.[
    gpt.NewPartition.{first = 34, count = 100, type_guid = guid(1), unique_guid = guid(2), name = "SlopOS check"},
    gpt.NewPartition.{first = 134, count = 50, type_guid = guid(3), unique_guid = guid(4), name = "spare"},
]

/** A stand-in disk with PARTITIONS' table written on it, and room for read_table's entries. */
Written :: struct {
    /** The disk's bytes, from the context's allocator, which free_written gives back. */
    bytes : mut u8[],
    /** Where read_table puts the entries it reads, ENTRY_BLOCKS blocks of it, freed with bytes. */
    entries : mut u8[],
}

/**
 * Make a stand-in disk and write PARTITIONS' table on it, for a test that reads it.
 *
 * @param t The test's state, which a failure is recorded in.
 * @return The disk, which the caller frees with free_written; Error if it couldn't be allocated or written, the
 *     failure recorded.
 */
written :: fn(t: ptr[mut testing.T]) -> Result[Written, testing.Stopped] {
    bytes, error :: runtime.new_array(u8, cast[usize](BLOCKS * gpt.BLOCK_BYTES))
    testing.require(t, error == null, "the stand-in disk is allocated")?
    entries, entries_error :: runtime.new_array(u8, cast[usize](gpt.ENTRY_BLOCKS * gpt.BLOCK_BYTES))
    if entries_error != null {
        runtime.free_array(bytes)
        testing.fail(t, "room for the entries read is allocated")
        return .Error(.Failed)
    }
    made :: Written.{bytes = bytes, entries = entries}
    if !testing.expect(t, gpt.write_table(bytes, BLOCKS, guid(9), PARTITIONS), "a table of two partitions is written") {
        free_written(made)
        return .Error(.Failed)
    }
    return .Ok(made)
}

/**
 * Give back a stand-in disk written made.
 *
 * @param disk The disk, whose bytes and entries aren't used after.
 */
free_written :: fn(disk: Written) {
    runtime.free_array(disk.bytes)
    runtime.free_array(disk.entries)
}

checks_the_standard_crc #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    testing.expect_eq(t, gpt.crc32(string_bytes("123456789")), 0xcbf43926, "the CRC everyone checks against")
    return .Ok
}

writes_a_protective_mbr #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    disk :: written(t)?
    defer free_written(disk)
    if disk.bytes.count < 512 {
        testing.fail(t, "the disk has a first block")
        return .Ok
    }
    testing.expect_eq(t, disk.bytes[510], 0x55, "the MBR's signature, first byte")
    testing.expect_eq(t, disk.bytes[511], 0xaa, "the MBR's signature, second byte")
    testing.expect_eq(t, disk.bytes[446 + 4], 0xee, "the one MBR partition is GPT's protective one")
    return .Ok
}

reads_the_table_as_written #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    disk :: written(t)?
    defer free_written(disk)
    image := Image.{bytes = disk.bytes}
    reading := gpt.Disk.{context = cast[rawptr](&image), block_count = BLOCKS, read = read_blocks}
    read :: gpt.read_table(&reading, disk.entries)
    table := testing.require_ok(t, read, "the table written reads back")?
    testing.require_eq(t, table.count, 2, "both partitions")?
    testing.expect(t, !table.from_backup, "from the primary copy")
    testing.expect_eq(t, table.first_usable, 34, "the first usable block, after the primary table")
    testing.expect_eq(t, table.last_usable, BLOCKS - 34, "the last usable block, before the backup table")
    testing.expect_eq(t, table.partitions[0].first, 34, "the first partition's first block")
    testing.expect_eq(t, table.partitions[0].count, 100, "the first partition's size")
    testing.expect_eq(t, gpt.name_of(&table.partitions[0]), "SlopOS check", "the first partition's name")
    testing.expect_eq(t, table.partitions[0].type_guid, guid(1), "the first partition's type")
    testing.expect_eq(t, table.partitions[0].unique_guid, guid(2), "the first partition's own GUID")
    testing.expect_eq(t, table.partitions[1].first, 134, "the second partition's first block")
    testing.expect_eq(t, table.partitions[1].count, 50, "the second partition's size")
    testing.expect_eq(t, gpt.name_of(&table.partitions[1]), "spare", "the second partition's name")
    return .Ok
}

reads_the_backup_when_the_primary_header_is_broken #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    disk :: written(t)?
    defer free_written(disk)
    flip(disk.bytes, cast[usize](gpt.BLOCK_BYTES) + 40)
    image := Image.{bytes = disk.bytes}
    reading := gpt.Disk.{context = cast[rawptr](&image), block_count = BLOCKS, read = read_blocks}
    read :: gpt.read_table(&reading, disk.entries)
    table :: testing.require_ok(t, read, "the backup reads")?
    testing.expect(t, table.from_backup, "read from the backup")
    testing.expect_eq(t, table.count, 2, "both partitions")
    return .Ok
}

reads_nothing_when_both_sets_of_entries_are_broken #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    disk :: written(t)?
    defer free_written(disk)
    flip(disk.bytes, cast[usize](2 * gpt.BLOCK_BYTES))
    flip(disk.bytes, cast[usize]((BLOCKS - gpt.ENTRY_BLOCKS - 1) * gpt.BLOCK_BYTES))
    image := Image.{bytes = disk.bytes}
    reading := gpt.Disk.{context = cast[rawptr](&image), block_count = BLOCKS, read = read_blocks}
    read :: gpt.read_table(&reading, disk.entries)
    testing.expect(t, read is_error, "neither copy of the entries checks out")
    return .Ok
}

refuses_a_partition_outside_the_usable_blocks #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    bytes, error :: runtime.new_array(u8, cast[usize](BLOCKS * gpt.BLOCK_BYTES))
    testing.require(t, error == null, "the stand-in disk is allocated")?
    defer runtime.free_array(bytes)
    outside :: gpt.NewPartition.[gpt.NewPartition.{first = 2, count = 10, type_guid = guid(1)}]
    testing.expect(t, !gpt.write_table(bytes, BLOCKS, guid(9), outside), "block 2 is the primary table's")
    return .Ok
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
 * Run the tests, reporting to standard output.
 *
 * @return How many failed: 0 when every one passed.
 */
run_tests :: fn() -> int {
    return cast[int](testing.run(#insert testing.tests_of(compiler.load_package(".")), testing.STANDARD_OUTPUT))
}

/**
 * Run the tests, with fault injection as SLOPOS_FAIL asks (robustness/hosted, tools/unit_tests.py --robustness).
 *
 * @return How many tests failed: 0 when every one passed.
 */
main :: fn() -> int {
    return hosted_faults.run(run_tests)
}
