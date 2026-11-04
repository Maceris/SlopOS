/**
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

/** The policy's file's name in a generation's boot set. */
POLICY_FILE :: "substitutions.records"
/** The policy's schema hash, bundle.Substitutions', which its file starts with: 32 bytes. */
POLICY_SCHEMA :: #run schema.hash(type_info_of(bundle.Substitutions))
/** The bytes of the policy's file: the schema's hash, then the policy as it's laid out in memory. */
POLICY_BYTES :: 32 + size_of(bundle.Substitutions)
/** What a library grant's label starts with, before the library's file name. */
LIBRARY_PREFIX :: "library:"

/** A library a process was given: its file's name, and its memory. */
Library :: struct {
    /** The library's file name, its grant's label after LIBRARY_PREFIX; a view of the startup block's bytes. */
    name : string,
    /** The memory object holding the library's file, the grant's handle, which the process still owns. */
    memory : slop_os.Memory,
}

/** Bytes mapped read-only, and where. */
Mapped :: struct {
    /** The mapped bytes, a view good until they're unmapped. */
    bytes : u8[],
    /** The address the mapping starts at, which unmap takes. */
    address : u64,
}

/**
 * Make the policy's file from a policy.
 *
 * @param policy The policy; its bytes are copied as they're laid out in memory, unused entries included.
 * @return The file's bytes: POLICY_SCHEMA, then the policy's bytes.
 */
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

/**
 * Read the policy from its file's bytes.
 *
 * @param bytes The file's bytes; bytes past POLICY_BYTES are ignored.
 * @return The policy, or null if bytes are too few, don't start with POLICY_SCHEMA, or say a count of more than
 *     bundle.MAX_SUBSTITUTIONS entries.
 */
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

/**
 * Map a memory object read-only, whole, in the process's own address space.
 *
 * The addresses are reserved from the startup block's free range, and aren't given back, even when unmapped.
 *
 * @param block The process's startup block, whose address space it's mapped in; not null.
 * @param memory A handle to the memory object, which stays the caller's.
 * @return The mapped bytes and their address, which the caller unmaps with unmap; or null if the object's size
 *     couldn't be read, the free range hasn't room, or the mapping failed.
 */
mapped :: fn(block: ptr[slop_os.StartupBlock], memory: slop_os.Handle) -> Mapped? {
    size :: slop_os.memory_size(cast[slop_os.Memory](memory)) or_return null
    address :: runtime.reserve_addresses(cast[usize](size)) or_return null
    if slop_os.memory_map(cast[slop_os.Memory](memory), block.space, address, 0, size, slop_os.PROTECTION_READ) is_error {
        return null
    }
    return Mapped.{bytes = view_of(cast[ptr[u8]](address), cast[usize](size)), address = address}
}

/**
 * Unmap what mapped or library_mapped mapped; failing to is ignored.
 *
 * @param block The process's startup block, whose address space it's mapped in; not null.
 * @param what The mapping, whose bytes aren't to be used after.
 */
unmap :: fn(block: ptr[slop_os.StartupBlock], what: Mapped) {
    _ = slop_os.memory_unmap(block.space, what.address)
}

/**
 * Map a library's file read-only, as long as its ELF headers say it is, which a boot module's memory, a page's
 * multiple, can be longer than.
 *
 * @param block The process's startup block, whose address space it's mapped in; not null.
 * @param memory A handle to the memory object holding the file, which stays the caller's.
 * @return The file's bytes and the mapping's address, which the caller unmaps with unmap; or null if it couldn't be
 *     mapped, or isn't an ELF file whose headers fit in the memory, in which case nothing is left mapped.
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

/**
 * Hash a library's file, as bundle names files.
 *
 * @param block The process's startup block; not null.
 * @param memory A handle to the memory object holding the file, which stays the caller's; it's mapped only while it's
 *     hashed.
 * @return The hash of the file's bytes, as long as its ELF headers say it is; or null if it couldn't be mapped or
 *     isn't an ELF file.
 */
library_hash :: fn(block: ptr[slop_os.StartupBlock], memory: slop_os.Handle) -> bundle.Hash? {
    file :: library_mapped(block, memory) or_return null
    hash :: bundle.hash_of(file.bytes)
    unmap(block, file)
    return hash
}

/**
 * Find the library the process was given whose file has a hash, among its grants named library:<name>.
 *
 * Every library grant before it is mapped and hashed, so this takes as long as hashing them.
 *
 * @param block The process's startup block; not null.
 * @param hash The hash of the library's file.
 * @return The first such library, its name and memory, or null if no memory grant labeled library: has that hash.
 */
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

/**
 * Check that one library can stand in for another (library_interface.check).
 *
 * @param block The process's startup block, whose address space both are mapped in while they're checked; not null.
 * @param old A handle to the memory holding the library replaced, which stays the caller's.
 * @param new A handle to the memory holding its substitute, which stays the caller's.
 * @return Null if new's interface record passes the check against old's; otherwise why not, a static string: that
 *     either can't be read, or what library_interface.check says.
 */
check :: fn(block: ptr[slop_os.StartupBlock], old: slop_os.Handle, new: slop_os.Handle) -> string? {
    before :: library_mapped(block, old) or_return "the library can't be read"
    defer unmap(block, before)
    after :: library_mapped(block, new) or_return "its substitute can't be read"
    defer unmap(block, after)
    return library_interface.check(before.bytes, after.bytes)
}
