/*
 * The substitution policy as a generation's boot-set file, and libraries checked against it (roadmap 9f2,
 * decisions/0119, 0123, 0125). The policy, bundle.Substitutions, is substitutions.records: its schema's hash, then its
 * bytes, fixed-size plain data. Each entry replaces the library whose file has the hash from by the one whose file has
 * the hash to, if to's interface record passes library_interface.check against from's. The root task applies it to
 * what it launches, from the libraries the kernel gave it, which the generation has; the supervisor checks a change
 * before the update service stages it.
 */
package substitution

import runtime from "base"
import schema from "std"
import strings from "std"
import slop_os from "std/os"
import bundle from "../bundle"
import library_interface from "../library_interface"

// The policy's file in a generation's boot set
POLICY_FILE :: "substitutions.records"
POLICY_SCHEMA :: #run schema.hash(type_info_of(bundle.Substitutions))
POLICY_BYTES :: 32 + size_of(bundle.Substitutions)
LIBRARY_PREFIX :: "library:"

// A library a process was given: its file's name, and its memory.
Library :: struct {
    name : string,
    memory : slop_os.Memory,
}

// Bytes mapped read-only, and where.
Mapped :: struct {
    bytes : u8[],
    address : u64,
}

// The policy's file: its schema's hash, then its bytes.
policy_record :: fn(policy: bundle.Substitutions) -> u8[POLICY_BYTES] {
    record : u8[POLICY_BYTES]
    for byte, i in POLICY_SCHEMA {
        if i < record.count {
            record[i] = byte
        }
    }
    bytes :: view_of(cast[ptr[u8]](&policy), size_of(bundle.Substitutions))
    for byte, i in bytes {
        if 32 + i < record.count {
            record[32 + i] = byte
        }
    }
    return record
}

// The policy in a file's bytes, if they're one: its schema's hash, then a count within its entries.
policy_of :: fn(bytes: u8[]) -> bundle.Substitutions? {
    if bytes.count < POLICY_BYTES {
        return null
    }
    for byte, i in POLICY_SCHEMA {
        if i >= bytes.count || bytes[i] != byte {
            return null
        }
    }
    policy := bundle.Substitutions.{}
    into :: view_of(cast[ptr[mut u8]](&policy), size_of(bundle.Substitutions))
    for i in 0..<into.count {
        if 32 + i < bytes.count {
            into[i] = bytes[32 + i]
        }
    }
    if policy.count > cast[u64](bundle.MAX_SUBSTITUTIONS) {
        return null
    }
    return policy
}

// size bytes of memory mapped read-only, or null.
mapped :: fn(block: ptr[slop_os.StartupBlock], memory: slop_os.Handle) -> Mapped? {
    size :: slop_os.memory_size(cast[slop_os.Memory](memory)) or_return null
    address :: runtime.reserve_addresses(cast[usize](size)) or_return null
    if slop_os.memory_map(cast[slop_os.Memory](memory), block.space, address, 0, size, slop_os.PROTECTION_READ) is_error {
        return null
    }
    return Mapped.{bytes = view_of(cast[ptr[u8]](address), cast[usize](size)), address = address}
}

unmap :: fn(block: ptr[slop_os.StartupBlock], what: Mapped) {
    _ = slop_os.memory_unmap(block.space, what.address)
}

/*
 * A library's file in memory, mapped read-only: its bytes, as long as its ELF headers say it is, which a boot module's
 * memory, a page's multiple, can be longer than.
 */
library_mapped :: fn(block: ptr[slop_os.StartupBlock], memory: slop_os.Handle) -> Mapped? {
    whole :: mapped(block, memory) or_return null
    length :: cast[usize](library_interface.file_size(whole.bytes))
    if length == 0 || length > whole.bytes.count {
        unmap(block, whole)
        return null
    }
    return Mapped.{bytes = whole.bytes[0..<length], address = whole.address}
}

// The hash of the library's file in memory, or null.
library_hash :: fn(block: ptr[slop_os.StartupBlock], memory: slop_os.Handle) -> bundle.Hash? {
    file :: library_mapped(block, memory) or_return null
    hash :: bundle.hash_of(file.bytes)
    unmap(block, file)
    return hash
}

// The process's own library, a grant library:<name>, whose file has hash, or null.
own_library :: fn(block: ptr[slop_os.StartupBlock], hash: bundle.Hash) -> Library? {
    for &grant in slop_os.grants_of(block) {
        label :: slop_os.label_of(grant)
        if grant.kind != .Memory || !strings.starts_with(label, LIBRARY_PREFIX) || LIBRARY_PREFIX.count > label.count {
            continue
        }
        start :: LIBRARY_PREFIX.count
        name :: if start <= label.count { label[start..<label.count] } else { label }
        match library_hash(block, grant.handle) {
            case Some(found) => if bundle.same(found, hash) {
                return Library.{name = name, memory = cast[slop_os.Memory](grant.handle)}
            }
            case None => {}
        }
    }
    return null
}

// Whether the library in new can stand in for the one in old (library_interface.check), or why not.
check :: fn(block: ptr[slop_os.StartupBlock], old: slop_os.Handle, new: slop_os.Handle) -> string? {
    before :: library_mapped(block, old) or_return "the library can't be read"
    defer unmap(block, before)
    after :: library_mapped(block, new) or_return "its substitute can't be read"
    defer unmap(block, after)
    return library_interface.check(before.bytes, after.bytes)
}
