package kernel

import intrinsics from "base"
import arch_interface from "../arch_interface"
import concurrency from "std"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}
#else_if TARGET_ARCH == .arm64 {
    import arch from "../arch/aarch64"
}

/*
 * Reaching user memory (docs/specs/arch_interface.md, Rules for L2): never through a user address, but
 * by translating it in the address space's table and using the direct map. So a kernel access never
 * faults on user memory, and user-access protection stays on.
 */

/**
 * Copy bytes from the kernel to user memory in an address space.
 *
 * The user range is reached through the space's table and the direct map, a page at a time, never through the user
 * address itself, so this can't fault. The space's lock is held throughout, so no page is unmapped meanwhile. Pages
 * are checked as they're copied: a check that fails partway leaves the pages before it written.
 *
 * @param kernel The kernel, for the direct map's offset.
 * @param space The address space the user range is in; its lock (level Space) is taken, so the caller holds none at
 *     that level or above.
 * @param address The user virtual address to copy to, any alignment. The whole range has to be in the user half and
 *     mapped, for user mode and writable, at the time of the copy; nothing is faulted in.
 * @param source The kernel virtual address of the bytes to copy, readable for size bytes.
 * @param size How many bytes to copy; 0 copies nothing and succeeds.
 * @return True if every byte was copied; false if the range leaves the user half, or a page of it isn't mapped,
 *     isn't user memory or isn't writable, in which case the pages before it may have been written.
 */
copy_to_user :: fn(kernel: ptr[Kernel], space: ptr[mut AddressSpace], address: u64, source: u64, size: u64) -> bool {
    return copy_user(kernel, space, address, source, size, true)
}

/**
 * Copy bytes from user memory in an address space to the kernel.
 *
 * As copy_to_user, the other way: through the space's table and the direct map, with the space's lock held.
 *
 * @param kernel The kernel, for the direct map's offset.
 * @param space The address space the user range is in; its lock (level Space) is taken.
 * @param address The user virtual address to copy from, any alignment. The whole range has to be in the user half and
 *     mapped for user mode, readable at least; nothing is faulted in.
 * @param destination The kernel virtual address the bytes go to, writable for size bytes.
 * @param size How many bytes to copy; 0 copies nothing and succeeds.
 * @return True if every byte was copied; false if the range leaves the user half or a page of it isn't mapped for user
 *     mode, in which case the bytes of the pages before it have been copied.
 */
copy_from_user :: fn(kernel: ptr[Kernel], space: ptr[mut AddressSpace], address: u64, destination: u64, size: u64) -> bool {
    return copy_user(kernel, space, address, destination, size, false)
}

/**
 * Copy bytes between the kernel and user memory, either way: copy_to_user and copy_from_user's work.
 *
 * @param kernel The kernel, for the direct map's offset.
 * @param space The address space the user range is in; its lock (level Space) is taken for the whole copy.
 * @param address The user virtual address, any alignment, whose range has to be in the user half.
 * @param other The kernel virtual address on the other side, valid for size bytes.
 * @param size How many bytes to copy; 0 succeeds at once.
 * @param to_user True to copy from other to the user range, which then has to be writable; false to copy from it.
 * A page mapped but not yet touched is brought in first, as a fault on it would (present_user_page).
 *
 * @return True if every byte was copied; false at the first page that's outside the user half, not mapped, not user
 *     memory, device memory or a framebuffer (which the direct map doesn't reach), or, copying to user, not writable,
 *     with the pages before it copied.
 */
copy_user :: fn(kernel: ptr[Kernel], space: ptr[mut AddressSpace], address: u64, other: u64, size: u64, to_user: bool) -> bool {
    if size == 0 {
        return true
    }
    low, high :: arch.user_address_range()
    if address < cast[u64](low) || address >= cast[u64](high) || size > cast[u64](high) - address {
        return false
    }
    lock_at(&space.lock, .Space)
    defer unlock_at(&space.lock, .Space)
    copied : u64 = 0
    loop {
        at :: address + copied
        found :: present_user_page(kernel, space, at, to_user) or_return false
        if !found.mapping.user || (to_user && found.mapping.protection != .ReadWrite) {
            return false
        }
        // Device registers and framebuffers aren't in the direct map, so they're refused, not reached through it
        if !reachable_in_direct_map(kernel, cast[u64](found.physical_address), found.mapping.cache) {
            return false
        }
        // As far as this page goes
        in_page :: 4096 - (at & 4095)
        piece :: if size - copied < in_page { size - copied } else { in_page }
        user :: kernel.frames.direct_map_offset + cast[u64](found.physical_address)
        if to_user {
            intrinsics.mem_copy(cast[mut rawptr](user), cast[rawptr](other + copied), cast[usize](piece))
        }
        else {
            intrinsics.mem_copy(cast[mut rawptr](other + copied), cast[rawptr](user), cast[usize](piece))
        }
        copied += piece
    }
    while copied < size
    return true
}

/**
 * Find a user page's translation, bringing it in first if it's mapped but not yet touched, as a fault on it would.
 *
 * The kernel's copies to and from user memory can't take a fault themselves, so they ask here: a page of anonymous
 * memory gets its zeroed frame, a window's or device memory's its frame, as resolve_fault gives them. Paged memory its
 * pager hasn't supplied yet isn't waited for, and fails.
 *
 * @param kernel The kernel, whose frames a new page comes from.
 * @param space The address space, its lock (level Space) held by the caller.
 * @param address The user address, any alignment.
 * @param write Whether the page will be written, which the mapping has to allow.
 * @return The page's translation; null if it isn't mapped, the mapping doesn't allow the access, or it can't be had.
 */
present_user_page :: fn(kernel: ptr[Kernel], space: ptr[mut AddressSpace], address: u64, write: bool) -> arch_interface.Translation? {
    match arch.translate(&space.table, cast[arch_interface.VirtualAddress](address)) {
        case Some(found) => return found
        case None => {}
    }
    fault :: arch_interface.PageFault.{address = cast[arch_interface.VirtualAddress](address), access = if write { arch_interface.Access.Write }
        else { arch_interface.Access.Read }, present = false}
    if resolve_fault_locked(cast[ptr[mut Kernel]](kernel), null, space, fault) != .Mapped {
        return null
    }
    return arch.translate(&space.table, cast[arch_interface.VirtualAddress](address))
}
