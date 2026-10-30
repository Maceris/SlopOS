/*
 * Bundles and roots (roadmap 9b, decisions/0094, design/software.md §2): the records the bundle store keeps beside
 * programs, libraries and schemas, each an object named by its BLAKE3-256 hash. A record is its type's schema hash
 * (std's schema.hash), then its value as schema.write_value writes it, what it points to after it at distances from
 * the value's start; the store reads one back only if its schema hash is the one its type has here.
 *
 * A bundle names one build of a program: its hash, its manifest's (the schema of its entry's type, decisions/0044),
 * and its libraries' and resources'. A root keeps bundles alive, each under a name: the boot root, which the image
 * builder writes until generations do (9d), and what a developer pins.
 */
package bundle

import runtime from "base"
import crypto from "std"
import schema from "std"

Hash :: struct {
    bytes : u8[32],
}

Bundle :: struct {
    program : Hash,
    manifest : Hash,
    libraries : Hash[],
    resources : Hash[],
}

RootEntry :: struct {
    name : string,
    bundle : Hash,
}

Root :: struct {
    entries : RootEntry[],
}

BUNDLE_SCHEMA :: #run schema.hash(type_info_of(Bundle))
ROOT_SCHEMA :: #run schema.hash(type_info_of(Root))

// The hash that names bytes.
hash_of :: fn(bytes: u8[]) -> Hash {
    made := Hash.{}
    crypto.blake3(bytes, made.bytes)
    return made
}

same :: fn(a: Hash, b: Hash) -> bool {
    for byte, i in a.bytes {
        if byte != b.bytes[i] {
            return false
        }
    }
    return true
}

// A record of value written to the end of into: its type's schema hash, then the value.
write :: fn[T](value: T, into: ptr[mut u8[..]]) {
    for byte in schema.hash(type_info_of(T)) {
        runtime.array_add(into, byte)
    }
    schema.write_value(value, into)
}

// Hex text of a hash, 64 characters, into storage.
hex :: fn(hash: Hash, storage: ptr[mut u8[64]]) -> string {
    digits :: "0123456789abcdef"
    for byte, i in hash.bytes {
        storage^[(2 * i) % 64] = cast[u8](digits[cast[usize](byte >> 4)])
        storage^[(2 * i + 1) % 64] = cast[u8](digits[cast[usize](byte & 15)])
    }
    return string_of(&storage^[0], 64)
}

// A hash from 64 hex characters, or null.
from_hex :: fn(text: string) -> Hash? {
    if text.count < 64 {
        return null
    }
    made := Hash.{}
    for i in cast[usize](0)..<32 {
        high :: digit(text[2 * i]) or_return null
        low :: digit(text[2 * i + 1]) or_return null
        made.bytes[i] = high << 4 | low
    }
    return made
}

digit :: fn(character: char) -> u8? {
    if character >= '0' && character <= '9' {
        return cast[u8](character) - cast[u8]('0')
    }
    if character >= 'a' && character <= 'f' {
        return cast[u8](character) - cast[u8]('a') + 10
    }
    return null
}

// A record's value, if its schema hash is expected.
value_of :: fn(record: u8[], expected: u8[32]) -> u8[]? {
    if record.count < 32 {
        return null
    }
    for byte, i in expected {
        if record[i] != byte {
            return null
        }
    }
    return record[32..<record.count]
}

/*
 * Each hash a bundle refers to: its program's, its manifest's, its libraries' and its resources'; false if the bytes
 * aren't a bundle.
 */
bundle_refers :: fn(record: u8[], each: ptr[mut Hash[..]]) -> bool {
    value :: value_of(record, BUNDLE_SCHEMA) or_return false
    if value.count < size_of(Bundle) {
        return false
    }
    runtime.array_add(each, hash_at(value, 0))
    runtime.array_add(each, hash_at(value, 32))
    for list in usize.[offset_of(Bundle, libraries), offset_of(Bundle, resources)] {
        count :: cast[usize](word(value, list))
        at :: cast[usize](word(value, list + 8))
        if count > 0 && (at >= value.count || count > (value.count - at) / 32) {
            return false
        }
        for i in cast[usize](0)..<count {
            runtime.array_add(each, hash_at(value, at + i * 32))
        }
    }
    return true
}

// A root's entries, each name and bundle; false if the bytes aren't a root.
root_entries :: fn(record #escaping : u8[], names: ptr[mut string[..]], bundles: ptr[mut Hash[..]]) -> bool {
    value :: value_of(record, ROOT_SCHEMA) or_return false
    if value.count < size_of(Root) {
        return false
    }
    count :: cast[usize](word(value, 0))
    at :: cast[usize](word(value, 8))
    entry_size :: size_of(RootEntry)
    if count > 0 && (at >= value.count || count > (value.count - at) / entry_size) {
        return false
    }
    for i in cast[usize](0)..<count {
        entry :: at + i * entry_size
        name_count :: cast[usize](word(value, entry + offset_of(RootEntry, name)))
        name_at :: cast[usize](word(value, entry + offset_of(RootEntry, name) + 8))
        if name_count > 0 && (name_at >= value.count || name_count > value.count - name_at) {
            return false
        }
        name :: if name_count > 0 && name_at < value.count { string_of(&value[name_at], name_count) } else { "" }
        runtime.array_add(names, name)
        runtime.array_add(bundles, hash_at(value, entry + offset_of(RootEntry, bundle)))
    }
    return true
}

hash_at :: fn(bytes: u8[], at: usize) -> Hash {
    made := Hash.{}
    for i in cast[usize](0)..<32 {
        if at + i < bytes.count {
            made.bytes[i] = bytes[at + i]
        }
    }
    return made
}

word :: fn(bytes: u8[], at: usize) -> u64 {
    result : u64 = 0
    for i in cast[usize](0)..<8 {
        if at + i < bytes.count {
            result |= cast[u64](bytes[at + i]) << (8 * cast[u64](i))
        }
    }
    return result
}
