/**
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

/** An object's name in the bundle store: the BLAKE3-256 hash of its bytes. */
Hash :: struct {
    /** The hash's 32 bytes, as BLAKE3 gives them. */
    bytes : u8[32],
}

/** One build of a program, as the store keeps it: what it's made of, each by its hash. */
Bundle :: struct {
    /** The program's executable, its ELF image. */
    program : Hash,
    /** Its manifest: the schema of its entry's type (decisions/0044). */
    manifest : Hash,
    /** The typed libraries it's linked against. */
    libraries : Hash[],
    /** Its resources, other objects it's given. */
    resources : Hash[],
}

/** One of a root's entries: a bundle kept alive under a name. */
RootEntry :: struct {
    /** The name it's kept under, as a program's name is. */
    name : string,
    /** The bundle's hash. */
    bundle : Hash,
}

/** A root, which keeps bundles, and what they refer to, from the store's collection. */
Root :: struct {
    /** Its entries, each a bundle under a name. */
    entries : RootEntry[],
}

/**
 * The substitution policy (roadmap 9e3, decisions/0119, 0122), the config store's value "substitutions" of owner
 * "system": each library by its hash, from, replaced by another, to, where to's interface record passes the check
 * against from's. The supervisor applies it to what it launches after it reads it.
 */
Substitution :: struct {
    /** The hash of the library replaced. */
    from : Hash,
    /** The hash of the library that replaces it, whose interface has to pass the check against from's. */
    to : Hash,
}

/** The most substitutions a policy holds: 8. */
MAX_SUBSTITUTIONS :: 8

/** A substitution policy: its substitutions, in the first count of entries. */
Substitutions :: struct {
    /** How many of entries are the policy's, 0 to MAX_SUBSTITUTIONS. */
    count : u64,
    /** The substitutions, the first count of them. */
    entries : Substitution[MAX_SUBSTITUTIONS],
}

/** Bundle's schema hash, which a bundle's record starts with. */
BUNDLE_SCHEMA :: #run schema.hash(type_info_of(Bundle))
/** Root's schema hash, which a root's record starts with. */
ROOT_SCHEMA :: #run schema.hash(type_info_of(Root))

/**
 * Hash bytes, as the store names an object.
 *
 * @param bytes The object's bytes.
 * @return Their BLAKE3-256 hash.
 */
hash_of :: fn(bytes: u8[]) -> Hash {
    made := Hash.{}
    crypto.blake3(bytes, made.bytes)
    return made
}

/**
 * Tell whether two hashes are the same.
 *
 * @param a One hash.
 * @param b The other hash, compared byte for byte with a.
 * @return True if every byte is the same.
 */
same :: fn(a: Hash, b: Hash) -> bool {
    for byte, i in a.bytes {
        if byte != b.bytes[i] {
            return false
        }
    }
    return true
}

/**
 * Write a record of a value to the end of a byte array: its type's schema hash, then the value, as schema.write_value
 * writes it.
 *
 * @tparam T The value's type, whose schema hash names the record's kind.
 * @param value The value, written as schema.write_value writes it, what it points to after it; it isn't changed.
 * @param into The bytes, which grow by the record, with context's allocator.
 */
write :: fn[T](value: T, into: ptr[mut u8[..]]) {
    for byte in schema.hash(type_info_of(T)) {
        runtime.array_add(into, byte)
    }
    schema.write_value(value, into)
}

/**
 * Write a hash as hex text.
 *
 * @param hash The hash, all 32 bytes of it written.
 * @param storage Where the text is written.
 * @return The 64 lowercase hex characters, two a byte, high digit first: a view into storage, good while it is.
 */
hex :: fn(hash: Hash, storage: ptr[mut u8[64]]) -> string {
    digits :: "0123456789abcdef"
    for byte, i in hash.bytes {
        storage^[(2 * i) % 64] = cast[u8](digits[cast[usize](byte >> 4)])
        storage^[(2 * i + 1) % 64] = cast[u8](digits[cast[usize](byte & 15)])
    }
    return string_of(&storage^[0], 64)
}

/**
 * Read a hash from hex text, as hex writes it.
 *
 * @param text The text, whose first 64 characters are read; any after them are ignored.
 * @return The hash; null if text has fewer than 64 characters, or one of the first 64 isn't a lowercase hex digit.
 */
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

/**
 * Read a lowercase hex digit.
 *
 * @param character A character of hex text; uppercase digits aren't taken.
 * @return Its value, 0 to 15; null for anything but 0 to 9 and a to f.
 */
digit :: fn(character: char) -> u8? {
    if character >= '0' && character <= '9' {
        return cast[u8](character) - cast[u8]('0')
    }
    if character >= 'a' && character <= 'f' {
        return cast[u8](character) - cast[u8]('a') + 10
    }
    return null
}

/**
 * Give a record's value, if it's of the type expected.
 *
 * @param record The record's bytes: a schema hash, then the value.
 * @param expected The schema hash its type has to have.
 * @return The value's bytes, after the hash, a view into record; null if record is shorter than a hash, or its hash
 *     isn't expected.
 */
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

/**
 * List each hash a bundle refers to: its program's, its manifest's, its libraries' and its resources', in that order.
 *
 * @param record The bundle's record, as the store keeps it.
 * @param each Where the hashes are added, after what it holds, with context's allocator; on false or an error it may
 *     hold some of them.
 * @return True once they're listed; false if the bytes aren't a bundle's record, or its lists run past its end.
 * @error OutOfMemory There wasn't the memory to list them (decisions/0104).
 */
bundle_refers :: fn(record: u8[], each: ptr[mut Hash[..]]) -> Result[bool, runtime.AllocatorError] {
    value :: value_of(record, BUNDLE_SCHEMA) or_return .Ok(false)
    if value.count < size_of(Bundle) {
        return .Ok(false)
    }
    for first in usize.[0, 32] {
        if runtime.array_try_add(each, hash_at(value, first)) != null {
            return .Error(.OutOfMemory)
        }
    }
    for list in usize.[offset_of(Bundle, libraries), offset_of(Bundle, resources)] {
        count :: cast[usize](word(value, list))
        at :: cast[usize](word(value, list + 8))
        if count > 0 && (at >= value.count || count > (value.count - at) / 32) {
            return .Ok(false)
        }
        for i in cast[usize](0)..<count {
            if runtime.array_try_add(each, hash_at(value, at + i * 32)) != null {
                return .Error(.OutOfMemory)
            }
        }
    }
    return .Ok(true)
}

/**
 * List a root's entries, each name and bundle.
 *
 * Room for every entry is made first, so on an error neither list has any of them.
 *
 * @param record The root's record, as the store keeps it, which the names view, so it has to outlive them.
 * @param names Where the entries' names are added, after what it holds, with context's allocator: views into record.
 * @param bundles Where the entries' bundles' hashes are added, in the same order.
 * @return True once they're listed; false if the bytes aren't a root's record, or an entry or its name runs past its
 *     end, in which case the entries before it are listed.
 * @error OutOfMemory There wasn't the memory for the lists (decisions/0104).
 */
root_entries :: fn(record #escaping : u8[], names: ptr[mut string[..]], bundles: ptr[mut Hash[..]]) -> Result[bool, runtime.AllocatorError] {
    value :: value_of(record, ROOT_SCHEMA) or_return .Ok(false)
    if value.count < size_of(Root) {
        return .Ok(false)
    }
    count :: cast[usize](word(value, 0))
    at :: cast[usize](word(value, 8))
    entry_size :: size_of(RootEntry)
    if count > 0 && (at >= value.count || count > (value.count - at) / entry_size) {
        return .Ok(false)
    }
    // Room for every entry, so the lists stay whole
    if runtime.array_try_reserve(names, names.count + count) != null || runtime.array_try_reserve(bundles, bundles.count + count) != null {
        return .Error(.OutOfMemory)
    }
    for i in cast[usize](0)..<count {
        entry :: at + i * entry_size
        name_count :: cast[usize](word(value, entry + offset_of(RootEntry, name)))
        name_at :: cast[usize](word(value, entry + offset_of(RootEntry, name) + 8))
        if name_count > 0 && (name_at >= value.count || name_count > value.count - name_at) {
            return .Ok(false)
        }
        name :: if name_count > 0 && name_at < value.count { string_of(&value[name_at], name_count) } else { "" }
        runtime.array_add(names, name)
        runtime.array_add(bundles, hash_at(value, entry + offset_of(RootEntry, bundle)))
    }
    return .Ok(true)
}

/**
 * Read a hash from bytes at an offset.
 *
 * @param bytes A record's value, which the hash is read from; not changed.
 * @param at Where the hash starts, in bytes.
 * @return The 32 bytes from at; those past bytes' end are 0.
 */
hash_at :: fn(bytes: u8[], at: usize) -> Hash {
    made := Hash.{}
    for i in cast[usize](0)..<32 {
        if at + i < bytes.count {
            made.bytes[i] = bytes[at + i]
        }
    }
    return made
}

/**
 * Read a little-endian 64-bit word from bytes at an offset, as schema.write_value writes a count or a distance.
 *
 * @param bytes A record's value, which the word is read from; not changed.
 * @param at Where the word starts, in bytes.
 * @return The word; bytes past bytes' end count as 0.
 */
word :: fn(bytes: u8[], at: usize) -> u64 {
    result : u64 = 0
    for i in cast[usize](0)..<8 {
        if at + i < bytes.count {
            result |= cast[u64](bytes[at + i]) << (8 * cast[u64](i))
        }
    }
    return result
}
