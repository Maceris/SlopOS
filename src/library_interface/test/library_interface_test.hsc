/**
 * library_interface's tests, as a hosted program (tools/unit_tests.py): main returns 0 if everything worked, or the
 * number of the first check that failed. Libraries are made here, the least ELF that has a record: its header, one
 * loadable segment of the whole file at address 0, and the record at its entry, its pointers written in place.
 */
package library_interface_test

import runtime from "base"
import library_interface from ".."

// Where the made library's parts are
/** The interface record's address, and its offset in the file, which are the same: the library's entry. */
RECORD : u64 : 128
/** The exports' address and offset, each EXPORT_SIZE bytes after the last; room for 13 of them. */
EXPORTS : u64 : 256
/** Where the exports' names' bytes go, one after another. */
NAMES : u64 : 1024
/** The made library's memory, in bytes; its file, as file_size reads it, is 64 bytes shorter. */
SIZE : u64 : 2048

/** An export of a made library: its name, and the byte its type's hash is made of. */
Made :: struct {
    /** The export's name, copied into the library. */
    name : string,
    /** The byte each of the type's hash's 32 bytes is, so exports of the same byte have the same type. */
    type : u8,
}

/**
 * Run the checks: libraries that can and can't stand in for one, bytes that aren't a library, and a file's length.
 *
 * @return 0 if every check passed, or the number of the first that failed, 1 to 7.
 */
main :: fn() -> int {
    old : u8[SIZE]
    new : u8[SIZE]
    make(&old, 1, Made.[Made.{name = "add", type = 1}, Made.{name = "has_word", type = 2}])
    // The same, and one export more, stand in
    make(&new, 1, Made.[Made.{name = "add", type = 1}, Made.{name = "has_word", type = 2}])
    if library_interface.check(old, new) is_some {
        return 1
    }
    make(&new, 1, Made.[Made.{name = "has_word", type = 2}, Made.{name = "build_name", type = 3}, Made.{name = "add", type = 1}])
    if library_interface.check(old, new) is_some {
        return 2
    }
    // One export fewer, or of another type, or another convention, doesn't
    make(&new, 1, Made.[Made.{name = "add", type = 1}])
    if (library_interface.check(old, new) or_else "") != "an export isn't there any more" {
        return 3
    }
    make(&new, 1, Made.[Made.{name = "add", type = 9}, Made.{name = "has_word", type = 2}])
    if (library_interface.check(old, new) or_else "") != "an export's type changed" {
        return 4
    }
    make(&new, 2, Made.[Made.{name = "add", type = 1}, Made.{name = "has_word", type = 2}])
    if (library_interface.check(old, new) or_else "") != "it's built for another calling convention or Context" {
        return 5
    }
    // Bytes that aren't a library aren't read
    garbage : u8[SIZE]
    if (library_interface.check(old, garbage) is_none) || library_interface.file_size(garbage) != 0 {
        return 6
    }
    // A file's length from its headers, in memory longer than it
    if library_interface.file_size(old) != SIZE - 64 {
        return 7
    }
    return 0
}

/**
 * Make a library in bytes: its header, one loadable segment of the file at address 0, and its record at its entry.
 *
 * Its pointers are written in place, with no relocations, which library_interface reads as the file's bytes.
 *
 * @param bytes Where the library is made, all overwritten.
 * @param convention The record's calling convention; any value.
 * @param exports The record's exports, in order: at most 13, their names together at most 896 bytes, for them to
 *     fit where they're put, in the segment's 1920 bytes.
 */
make :: fn(bytes: ptr[mut u8[SIZE]], convention: u64, exports: Made[]) {
    for i in 0..<bytes.count {
        bytes^[i] = 0
    }
    for byte, i in u8.[0x7f, 0x45, 0x4c, 0x46, 2, 1] {
        put(bytes, cast[u64](i), 1, cast[u64](byte))
    }
    put(bytes, 16, 2, 3)
    put(bytes, 24, 8, RECORD)
    put(bytes, 32, 8, 64)
    // Section headers, none, said to end 64 bytes before the end
    put(bytes, 40, 8, SIZE - 64)
    put(bytes, 54, 2, 56)
    put(bytes, 56, 2, 1)
    put(bytes, 64, 4, cast[u64](library_interface.PT_LOAD))
    put(bytes, 64 + 32, 8, SIZE - 128)
    put(bytes, RECORD, 8, library_interface.LIBRARY_MAGIC)
    put(bytes, RECORD + 8, 8, convention)
    put(bytes, RECORD + 48, 8, cast[u64](exports.count))
    put(bytes, RECORD + 56, 8, EXPORTS)
    names := NAMES
    for export, i in exports {
        at :: EXPORTS + cast[u64](i) * library_interface.EXPORT_SIZE
        put(bytes, at, 8, cast[u64](export.name.count))
        put(bytes, at + 8, 8, names)
        for byte in string_bytes(export.name) {
            put(bytes, names, 1, cast[u64](byte))
            names += 1
        }
        for j in cast[u64](0)..<32 {
            put(bytes, at + library_interface.EXPORT_TYPE_HASH + j, 1, cast[u64](export.type))
        }
    }
}

/**
 * Write a number into the made library, little-endian.
 *
 * @param bytes The library's bytes; those past its end aren't written.
 * @param offset Where the number goes, in bytes.
 * @param size How many bytes it takes, 0 to 8.
 * @param value The number; its low size bytes are written.
 */
put :: fn(bytes: ptr[mut u8[SIZE]], offset: u64, size: u64, value: u64) {
    for i in cast[u64](0)..<size {
        at :: cast[usize](offset + i)
        if at < bytes.count {
            bytes^[at] = cast[u8]((value >> (8 * i)) & 0xff)
        }
    }
}
