/**
 * Typed libraries' interface records read from their files (roadmap 9e3, decisions/0119, 0122), as Hemera's
 * --check-interface reads them, for a substitution's check: whether one build of a library can stand in for another,
 * every export of the old there in the new with the same type, for the same calling convention and Context. Plain
 * Hemera on bytes, which builds anywhere.
 *
 * A record is at the library's entry (base's runtime.LibraryInterface): its magic, convention and Context's hash,
 * then its exports, a count and a pointer; each export a name, a count and a pointer, then its type's hash. The file
 * holds its pointers as zeros, each the addend of a relative relocation, found through the dynamic segment.
 */
package library_interface

/** An interface record's first 8 bytes: "HEMERAI2" in ASCII, read as a little-endian u64. */
LIBRARY_MAGIC : u64 : 0x32494152454d4548
/** ELF program header type: a loadable segment, whose file bytes addresses are read through. */
PT_LOAD : u32 : 1
/** ELF program header type: the dynamic section, where the relocations are found. */
PT_DYNAMIC : u32 : 2
/** ELF dynamic tag: the dynamic section's end. */
DT_NULL : u64 : 0
/** ELF dynamic tag: the RELA relocation table's address. */
DT_RELA : u64 : 7
/** ELF dynamic tag: the RELA relocation table's size, in bytes. */
DT_RELASZ : u64 : 8
/** An ELF64 RELA entry's size, in bytes: its offset, its info, then its addend, each 8 bytes. */
RELA_SIZE : u64 : 24
/** The relocation type R_X86_64_RELATIVE, in a RELA entry's info's low 32 bits: base plus addend. */
X86_64_RELATIVE : u32 : 8
/** The relocation type R_AARCH64_RELATIVE, in a RELA entry's info's low 32 bits: base plus addend. */
AARCH64_RELATIVE : u32 : 1027
/* Where the record's fields are (runtime.LibraryInterface, LibraryExport). */
/** The record's calling convention, a u64, in bytes from the record's start. */
INTERFACE_CONVENTION : u64 : 8
/** The record's Context's 32-byte hash, in bytes from the record's start. */
INTERFACE_CONTEXT_HASH : u64 : 16
/** The record's export count, a u64, then the pointer to its exports, in bytes from the record's start. */
INTERFACE_EXPORTS : u64 : 48
/** An export's type's 32-byte hash, in bytes from the export's start, after its name's count and pointer. */
EXPORT_TYPE_HASH : u64 : 16
/** An export's size in bytes, the distance from one export to the next. */
EXPORT_SIZE : u64 : 56
/* The most exports, and the longest name, a record is read with. */
/** The most exports a record may have; one with more isn't read. */
MAX_EXPORTS : u64 : 4096
/** The longest export name read, in bytes; a record with a longer one can't be read. */
MAX_NAME : u64 : 4096

/** A library's file, with what's found in it to read it by the addresses it was linked at. */
Image :: struct #scoped {
    /** The whole file; only read, and borrowed: the image is good only as long as the file's bytes are. */
    file : u8[],
    /** Where its program headers start, in bytes from the file's start; each is 56 bytes. */
    headers : u64,
    /** How many program headers there are; all of them are within the file. */
    count : u64,
    /** Where its RELA relocations start, in bytes from the file's start; 0 if it has none. */
    relocations : u64,
    /** How many bytes of relocations there are at relocations, within the file; 0 if it has none. */
    relocation_bytes : u64,
}

/** An interface record's start, as read: its convention, and where its Context's hash and its exports are. */
Record :: struct {
    /** The calling convention the library was built for, as the record gives it. */
    convention : u64,
    /** The address of the record's Context's 32-byte hash, as the library was linked; not the hash itself. */
    context_hash : u64,
    /** The address of the record's first export, as the library was linked; each EXPORT_SIZE bytes after the last. */
    exports : u64,
    /** How many exports there are, at most MAX_EXPORTS. */
    count : u64,
}

/**
 * Check whether one build of a library can stand in for another.
 *
 * New can when both are ELF libraries with interface records, built for the same calling convention and Context, and
 * every export of the old is in the new, by name, with the same type's hash; the new may have exports the old
 * hasn't, in any order. An export's name found more than once in the new is compared with its first.
 *
 * @param old The old library's whole file; only read.
 * @param new The new library's whole file; only read.
 * @return Null if new can stand in for old, or why not: a constant sentence fragment, such as "an export's type
 *     changed".
 */
check :: fn(old: u8[], new: u8[]) -> string? {
    before_image :: image_of(old) or_return "the old library isn't an ELF library"
    after_image :: image_of(new) or_return "the new library isn't an ELF library"
    before := record_of(&before_image) or_return "the old library has no interface record"
    after := record_of(&after_image) or_return "the new library has no interface record"
    if before.convention != after.convention || !same_bytes(&before_image, before.context_hash, &after_image, after.context_hash, 32) {
        return "it's built for another calling convention or Context"
    }
    for i in cast[u64](0)..<before.count {
        entry :: before.exports + i * EXPORT_SIZE
        name :: string_at(&before_image, entry) or_return "the old library's record can't be read"
        found := false
        for j in cast[u64](0)..<after.count {
            other :: after.exports + j * EXPORT_SIZE
            other_name :: string_at(&after_image, other) or_return "the new library's record can't be read"
            if other_name != name {
                continue
            }
            if !same_bytes(&before_image, entry + EXPORT_TYPE_HASH, &after_image, other + EXPORT_TYPE_HASH, 32) {
                return "an export's type changed"
            }
            found = true
            break
        }
        if !found {
            return "an export isn't there any more"
        }
    }
    return null
}

/**
 * Find a library's program headers and relocations in its file.
 *
 * @param file The library's whole file; the image borrows it.
 * @return The image, or null if file isn't a 64-bit little-endian ELF shared object (ET_DYN) with 56-byte program
 *     headers all within it, or its dynamic section or relocations can't be read within its segments' file bytes.
 */
image_of :: fn(file: u8[]) -> Image? {
    if file.count < 64 || file[0] != 0x7f || file[1] != 0x45 || file[2] != 0x4c || file[3] != 0x46 || file[4] != 2 || file[5] != 1
        || word_of(file, 16, 2) != 3 || word_of(file, 54, 2) != 56 {
        return null
    }
    image := Image.{file = file, headers = word_of(file, 32, 8), count = word_of(file, 56, 2)}
    if image.headers > cast[u64](file.count) || image.count * 56 > cast[u64](file.count) - image.headers {
        return null
    }
    for i in cast[u64](0)..<image.count {
        header :: image.headers + i * 56
        if word_of(file, header, 4) != cast[u64](PT_DYNAMIC) {
            continue
        }
        // Its entries, read where they were linked to be
        at := word_of(file, header + 16, 8)
        loop {
            tag :: word(&image, at) or_return null
            value :: word(&image, at + 8) or_return null
            if tag == DT_NULL {
                break
            }
            if tag == DT_RELA {
                image.relocations = offset_of_address(&image, value) or_return null
            }
            else if tag == DT_RELASZ {
                image.relocation_bytes = value
            }
            at += 16
        }
    }
    if image.relocations > cast[u64](file.count) || image.relocation_bytes > cast[u64](file.count) - image.relocations {
        return null
    }
    return image
}

/**
 * Read the interface record at the library's entry point.
 *
 * @param image The library's image, from image_of.
 * @return The record's start, or null if the entry's 8 bytes aren't LIBRARY_MAGIC, its fields can't be read from
 *     the file, or it has more than MAX_EXPORTS exports.
 */
record_of :: fn(image: ptr[Image]) -> Record? {
    at :: word_of(image.file, 24, 8)
    if (word(image, at) or_return null) != LIBRARY_MAGIC {
        return null
    }
    record :: Record.{convention = word(image, at + INTERFACE_CONVENTION) or_return null, context_hash = at + INTERFACE_CONTEXT_HASH,
        count = word(image, at + INTERFACE_EXPORTS) or_return null, exports = pointer(image, at + INTERFACE_EXPORTS + 8) or_return null}
    if record.count > MAX_EXPORTS {
        return null
    }
    return record
}

/**
 * Read a string from the library as it was linked: its byte count, then a pointer to its bytes.
 *
 * @param image The library's image, as image_of made it; only read, its loadable segments and relocations used to find
 *     the count and bytes.
 * @param address The string's address, as the library was linked.
 * @return The string, a view of the image's file, good as long as the file is; empty for a count of 0, or null if
 *     its count is more than MAX_NAME or its pointer or bytes can't be read (bytes_at).
 */
string_at :: fn(image: ptr[Image], address: u64) -> string? {
    count :: word(image, address) or_return null
    if count > MAX_NAME {
        return null
    }
    if count == 0 {
        return ""
    }
    data :: pointer(image, address + 8) or_return null
    bytes :: bytes_at(image, data, count) or_return null
    return bit_cast[string](bytes)
}

/**
 * Compare bytes in two libraries, each at an address as it was linked.
 *
 * @param image_a The first library's image.
 * @param a The address of the first library's bytes.
 * @param image_b The second library's image.
 * @param b The address of the second library's bytes.
 * @param count How many bytes are compared; 0 compares as false, as bytes_at reads no bytes.
 * @return True if both ranges are each in one segment's file bytes and are the same, false otherwise.
 */
same_bytes :: fn(image_a: ptr[Image], a: u64, image_b: ptr[Image], b: u64, count: u64) -> bool {
    first :: bytes_at(image_a, a, count) or_return false
    second :: bytes_at(image_b, b, count) or_return false
    for byte, i in first {
        if i >= second.count || byte != second[i] {
            return false
        }
    }
    return true
}

/**
 * Read a pointer from the library as it will be once it's relocated at base 0.
 *
 * @param image The library's image, as image_of made it; only read, its relocations searched for one at address.
 * @param address The pointer's address, as the library was linked.
 * @return The addend of the relative relocation at address, if there's one, since the file holds such a pointer as
 *     zeros; otherwise the 8 bytes at address; null if there's no relocation there and the bytes can't be read.
 */
pointer :: fn(image: ptr[Image], address: u64) -> u64? {
    for i in cast[u64](0)..<image.relocation_bytes / RELA_SIZE {
        entry :: image.relocations + i * RELA_SIZE
        kind :: cast[u32](word_of(image.file, entry + 8, 4))
        if word_of(image.file, entry, 8) == address && (kind == X86_64_RELATIVE || kind == AARCH64_RELATIVE) {
            return word_of(image.file, entry + 16, 8)
        }
    }
    return word(image, address)
}

/**
 * Read a little-endian u64 from the library as it was linked.
 *
 * @param image The library's image, as image_of made it; only read, its loadable segments used to find address in the
 *     file.
 * @param address The u64's address, as the library was linked.
 * @return The u64, or null if address isn't in a loadable segment's file bytes or the 8 bytes run past the file's
 *     end. The bytes may run past the segment's own file bytes, into what follows it in the file.
 */
word :: fn(image: ptr[Image], address: u64) -> u64? {
    offset :: offset_of_address(image, address) or_return null
    if offset > cast[u64](image.file.count) || 8 > cast[u64](image.file.count) - offset {
        return null
    }
    return word_of(image.file, offset, 8)
}

/**
 * View bytes of the library as it was linked, taken from the file.
 *
 * Only the first and last bytes are looked up: they have to be in loadable segments' file bytes, count - 1 bytes
 * apart in the file as in memory, which holds when the range is in one segment.
 *
 * @param image The library's image, as image_of made it; only read. The view returned borrows its file.
 * @param address The bytes' address, as the library was linked.
 * @param count How many bytes; at least 1.
 * @return The bytes, a view of the image's file, good as long as the file is; null for a count of 0, if the first
 *     or last byte isn't in a segment's file bytes or they aren't count - 1 bytes apart in the file, or if the bytes
 *     run past the file's end.
 */
bytes_at :: fn(image: ptr[Image], address: u64, count: u64) -> u8[]? {
    offset :: offset_of_address(image, address) or_return null
    if count == 0 || offset_of_address(image, address + count - 1) != offset + count - 1 {
        return null
    }
    end :: offset + count
    if end > cast[u64](image.file.count) || offset > end {
        return null
    }
    return image.file[cast[usize](offset)..<cast[usize](end)]
}

/**
 * Find where in the file the byte at an address, as the library was linked, is.
 *
 * @param image The library's image, whose program headers are read; image_of calls this before the relocations are
 *     found, which it doesn't use.
 * @param address The byte's virtual address, as the library was linked; it's found in a PT_LOAD segment's file bytes,
 *     from its p_vaddr for p_filesz bytes, never in the zero-filled rest of its memory.
 * @return Its offset in the file, from the first loadable segment whose file bytes hold it, or null if none does;
 *     the offset isn't checked against the file's size.
 */
offset_of_address :: fn(image: ptr[Image], address: u64) -> u64? {
    for i in cast[u64](0)..<image.count {
        header :: image.headers + i * 56
        if word_of(image.file, header, 4) != cast[u64](PT_LOAD) {
            continue
        }
        start :: word_of(image.file, header + 16, 8)
        size :: word_of(image.file, header + 32, 8)
        if address >= start && address - start < size {
            return word_of(image.file, header + 8, 8) + (address - start)
        }
    }
    return null
}

/**
 * Read a little-endian unsigned number from bytes.
 *
 * @param bytes The bytes to read from.
 * @param offset Where the number starts, in bytes.
 * @param size How many bytes the number takes, 0 to 8; 0 reads 0.
 * @return The number, or 0 if any of its bytes is past bytes' end, which can't be told from a number that's 0.
 */
word_of :: fn(bytes: u8[], offset: u64, size: u64) -> u64 {
    value : u64 = 0
    for i in cast[u64](0)..<size {
        at :: offset + i
        if at < offset || at >= cast[u64](bytes.count) {
            return 0
        }
        value |= cast[u64](bytes[cast[usize](at)]) << (8 * i)
    }
    return value
}

/**
 * Work out how long a library's file is, from its ELF headers.
 *
 * Memory holding a file can be longer, a page's multiple, so this tells how much of it is the file.
 *
 * @param file Memory holding the file from its start; only read.
 * @return The file's length in bytes: where its section headers end, or its program headers or a segment's bytes,
 *     whichever is last; 0 if it isn't an ELF file, or that end is past the memory's.
 */
file_size :: fn(file: u8[]) -> u64 {
    if file.count < 64 || file[0] != 0x7f || file[1] != 0x45 || file[2] != 0x4c || file[3] != 0x46 {
        return 0
    }
    end := word_of(file, 40, 8) + word_of(file, 60, 2) * word_of(file, 58, 2)
    headers :: word_of(file, 32, 8)
    count :: word_of(file, 56, 2)
    end = if headers + count * 56 > end { headers + count * 56 } else { end }
    for i in cast[u64](0)..<count {
        header :: headers + i * 56
        last :: word_of(file, header + 8, 8) + word_of(file, header + 32, 8)
        end = if last > end { last } else { end }
    }
    return if end <= cast[u64](file.count) { end } else { 0 }
}
