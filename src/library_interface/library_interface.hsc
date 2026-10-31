/*
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

LIBRARY_MAGIC : u64 : 0x32494152454d4548
PT_LOAD : u32 : 1
PT_DYNAMIC : u32 : 2
DT_NULL : u64 : 0
DT_RELA : u64 : 7
DT_RELASZ : u64 : 8
RELA_SIZE : u64 : 24
X86_64_RELATIVE : u32 : 8
AARCH64_RELATIVE : u32 : 1027
// Where the record's fields are (runtime.LibraryInterface, LibraryExport)
INTERFACE_CONVENTION : u64 : 8
INTERFACE_CONTEXT_HASH : u64 : 16
INTERFACE_EXPORTS : u64 : 48
EXPORT_TYPE_HASH : u64 : 16
EXPORT_SIZE : u64 : 56
// The most exports, and the longest name, a record is read with
MAX_EXPORTS : u64 : 4096
MAX_NAME : u64 : 4096

// A library's file, read by the addresses it was linked at.
Image :: struct #scoped {
    file : u8[],
    // Its program headers' place and count
    headers : u64,
    count : u64,
    // Its relative relocations' place in the file, and their bytes
    relocations : u64,
    relocation_bytes : u64,
}

// An interface record's start, as read: where its exports are and how many.
Record :: struct {
    convention : u64,
    context_hash : u64,
    exports : u64,
    count : u64,
}

// Whether new can stand in for old, or why not.
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

// A library's file's headers and relocations found, or null if it isn't a 64-bit little-endian ELF library.
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

// The record at the library's entry, checked to be one.
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

// The string at address: its count, then a pointer to its bytes.
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

// Whether count bytes at a in one image are those at b in another.
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

// The address a pointer at address holds once the library's relocated: its relocation's addend, or what's there.
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

// The 8 bytes at address.
word :: fn(image: ptr[Image], address: u64) -> u64? {
    offset :: offset_of_address(image, address) or_return null
    if offset > cast[u64](image.file.count) || 8 > cast[u64](image.file.count) - offset {
        return null
    }
    return word_of(image.file, offset, 8)
}

// count bytes at address, all in one segment's bytes from the file.
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

// Where in the file the byte at address is: in a loadable segment's bytes from the file, or null.
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

// A little-endian number of size bytes at offset, or 0 past the end.
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

/*
 * How long a library's file is, from its ELF headers: where its section headers end, or its program headers or a
 * segment's bytes, whichever is last; 0 if it isn't an ELF file. Memory holding it can be longer, a page's multiple.
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
