package kernel

import intrinsics from "base"
import runtime from "base"
import arch_interface from "../arch_interface"
import boot_info from "../boot_info"
import concurrency from "std"
import frames from "frames"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}

/*
 * Address spaces (roadmap M4, knowledge/design/kernel.md §2): page tables for user mode, sharing the
 * kernel's half (decisions/0048), each with its own address-space tag where the CPU has them, so
 * switching between them keeps the TLB.
 */
//TODO(claude): destroying one, and its tag's reuse after flush_tlb_tag on every CPU (M5, with AddressSpace objects)

// Tags: 0 is the kernel's own table's (address_space.hsc).
MAX_TAGS :: 4096

AddressSpace :: struct {
    // Held while its table changes (docs/specs/arch_interface.md, Rules for L2).
    lock : concurrency.SpinLock,
    table : arch.PageTable,
}

SpaceError :: enum {
    OutOfMemory,
    // Every address-space tag is in use.
    OutOfTags,
    // Not user addresses, or not aligned.
    InvalidAddress,
    AlreadyMapped,
}

// The tags in use, one bit each.
TagSet :: struct {
    lock : concurrency.SpinLock,
    used : u64[MAX_TAGS / 64],
}

create_address_space :: fn(kernel: ptr[mut Kernel]) -> (made #unrestricted : Result[ptr[mut AddressSpace], SpaceError]) {
    tag :: allocate_tag(kernel) or_return .Error(.OutOfTags)
    root :: frames.take_frame(&per_cpu().frame_cache, &kernel.frames) or_return .Error(.OutOfMemory)
    intrinsics.mem_zero(cast[rawptr](frames.virtual_of(&kernel.frames, root)), cast[usize](frames.FRAME_SIZE))
    space, error :: runtime.new_aligned(AddressSpace, align_of(AddressSpace))
    if error != null {
        frames.give_frame(&per_cpu().frame_cache, &kernel.frames, root)
        return .Error(.OutOfMemory)
    }
    space^ = AddressSpace.{}
    arch.init_page_table(&space.table, root, tag, &kernel.page_table)
    return .Ok(space)
}

/*
 * A free tag, or with only one tag (no PCIDs), that one: every switch flushes the TLB then anyway.
 */
allocate_tag :: fn(kernel: ptr[mut Kernel]) -> arch_interface.AddressSpaceTag? {
    count :: cast[usize](arch.address_space_tag_count())
    if count <= 1 {
        return cast[arch_interface.AddressSpaceTag](0)
    }
    tags :: &kernel.tags
    concurrency.lock(&tags.lock)
    defer concurrency.unlock(&tags.lock)
    for tag in 1..<count {
        word :: tag / 64 % (MAX_TAGS / 64)
        bit :: cast[u64](1) << cast[u64](tag % 64)
        if tags.used[word] & bit == 0 {
            tags.used[word] |= bit
            return cast[arch_interface.AddressSpaceTag](cast[u16](tag))
        }
    }
    return null
}

/*
 * Map size bytes from physical on at address in a user address space, 4 KiB pages, with mapping, which
 * is a user mapping.
 */
map_user :: fn(kernel: ptr[mut Kernel], space: ptr[mut AddressSpace], address: u64, physical: u64, size: u64,
    mapping: arch_interface.Mapping) -> Result[void, SpaceError] {
    tables : arch_interface.TableFrames
    concurrency.lock(&space.lock)
    defer {
        concurrency.unlock(&space.lock)
        give_back_tables(kernel, &tables)
    }
    for page in 0..<size / frames.FRAME_SIZE {
        offset :: page * frames.FRAME_SIZE
        loop {
            result :: arch.map(&space.table, cast[arch_interface.VirtualAddress](address + offset),
                cast[arch_interface.PhysicalAddress](physical + offset), .Size4K, mapping, &tables)
            match result {
                case Ok => break
                case Error(error) => {
                    if error == .AlreadyMapped {
                        return .Error(.AlreadyMapped)
                    }
                    if error != .NeedTableFrames {
                        return .Error(.InvalidAddress)
                    }
                    if !refill_user_tables(kernel, &tables) {
                        return .Error(.OutOfMemory)
                    }
                }
            }
        }
    }
    return .Ok
}

// Zeroed frames for new tables from this CPU's frame cache, false if there are none.
refill_user_tables :: fn(kernel: ptr[mut Kernel], tables: ptr[mut arch_interface.TableFrames]) -> bool {
    cache :: &per_cpu().frame_cache
    for i in cast[usize](tables.count)..<4 {
        match frames.take_frame(cache, &kernel.frames) {
            case Ok(frame) => {
                intrinsics.mem_zero(cast[rawptr](frames.virtual_of(&kernel.frames, frame)), cast[usize](frames.FRAME_SIZE))
                tables.frames[i] = frame
                tables.count += 1
            }
            case Error(error) => return false
        }
    }
    return true
}
