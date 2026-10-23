package kernel

import intrinsics from "base"
import arch_interface from "../arch_interface"
import concurrency from "std"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}

/*
 * Reaching user memory (docs/specs/arch_interface.md, Rules for L2): never through a user address, but
 * by translating it in the address space's table and using the direct map. So a kernel access never
 * faults on user memory, and user-access protection stays on.
 */

/*
 * Copy size bytes from source to address in space, which has to be mapped for user mode and writable
 * all the way: whether it was. With the space's lock, so nothing is unmapped meanwhile.
 */
copy_to_user :: fn(kernel: ptr[Kernel], space: ptr[mut AddressSpace], address: u64, source: u64, size: u64) -> bool {
    return copy_user(kernel, space, address, source, size, true)
}

// Copy size bytes from address in space, which has to be mapped for user mode all the way, to destination.
copy_from_user :: fn(kernel: ptr[Kernel], space: ptr[mut AddressSpace], address: u64, destination: u64, size: u64) -> bool {
    return copy_user(kernel, space, address, destination, size, false)
}

copy_user :: fn(kernel: ptr[Kernel], space: ptr[mut AddressSpace], address: u64, other: u64, size: u64, to_user: bool) -> bool {
    if size == 0 {
        return true
    }
    low, high :: arch.user_address_range()
    if address < cast[u64](low) || address >= cast[u64](high) || size > cast[u64](high) - address {
        return false
    }
    concurrency.lock(&space.lock)
    defer concurrency.unlock(&space.lock)
    copied : u64 = 0
    loop {
        at :: address + copied
        found :: arch.translate(&space.table, cast[arch_interface.VirtualAddress](at)) or_return false
        if !found.mapping.user || (to_user && found.mapping.protection != .ReadWrite) {
            return false
        }
        // As far as this page goes
        in_page :: 4096 - (at & 4095)
        piece :: if size - copied < in_page { size - copied } else { in_page }
        user :: kernel.frames.direct_map_offset + cast[u64](found.physical_address)
        if to_user {
            intrinsics.mem_copy(cast[rawptr](user), cast[rawptr](other + copied), cast[usize](piece))
        }
        else {
            intrinsics.mem_copy(cast[rawptr](other + copied), cast[rawptr](user), cast[usize](piece))
        }
        copied += piece
    }
    while copied < size
    return true
}
