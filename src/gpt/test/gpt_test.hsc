/*
 * The GPT package's tests, as a hosted program (tools/unit_tests.py): main returns 0 if everything worked, or the
 * number of the first check that failed. A table written into a buffer standing in for a disk reads back as written;
 * with its primary header broken it's read from its backup; with both sets of entries broken it isn't read at all.
 */
package gpt_test

import runtime from "base"
import gpt from ".."

BLOCKS : u64 : 256

Image :: struct {
    bytes : mut u8[],
}

main :: fn() -> int {
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

// One byte of the image changed, where it's there.
flip :: fn(bytes: mut u8[], at: usize) {
    if at < bytes.count {
        bytes[at] ~= 0xff
    }
}

// A GUID of one repeated byte.
guid :: fn(byte: u8) -> gpt.Guid {
    made : gpt.Guid
    for &each in made {
        each^ = byte
    }
    return made
}

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
