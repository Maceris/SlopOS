/**
 * x86-64 paging's tests, as a hosted program (tools/unit_tests.py): main returns 0 if everything
 * worked, or the number of the first check that failed.
 *
 * A buffer stands in for physical memory from MEMORY_BASE on, reached through a direct map whose
 * offset makes those addresses land in it. Its frames are handed out in order, zeroed: the kernel
 * table's root first, then its kernel half's 256 tables, then the rest as tests need them.
 */
package x86_64_test

import intrinsics from "base"
import runtime from "base"
import arch from ".."
import arch_interface from "../../../arch_interface"

/** The pretend physical address of the buffer's first frame, 1 MiB. */
MEMORY_BASE : u64 : 0x100000
/** How many frames the buffer has, enough for the kernel half's 256 tables and every test's. */
FRAME_COUNT : u64 : 300
/** The bytes of a frame, a 4 KiB page. */
FRAME_SIZE : u64 : 4096

// Kernel and user addresses the tests map.
/** A 4 KiB-aligned kernel address the tests map 4 KiB pages at, in the kernel half's first table. */
KERNEL_PAGE : u64 : 0xffff800000100000
/** A 2 MiB-aligned kernel address beside KERNEL_PAGE, in the same page directory, for 2 MiB pages. */
KERNEL_LARGE_PAGE : u64 : 0xffff800000200000
/** A user address the tests map 4 KiB pages at, 4 MiB. */
USER_PAGE : u64 : 0x400000

/** A kernel data mapping: read-write, write-back, global. */
KERNEL_DATA :: arch_interface.Mapping.{protection = .ReadWrite, cache = .WriteBack, user = false, global = true}
/** A kernel code mapping: read-execute, write-back, global. */
KERNEL_CODE :: arch_interface.Mapping.{protection = .ReadExecute, cache = .WriteBack, user = false, global = true}
/** A kernel read-only mapping: read, write-back, global. */
KERNEL_READ_ONLY :: arch_interface.Mapping.{protection = .Read, cache = .WriteBack, user = false, global = true}
/** A framebuffer-like mapping: read-write, write-combining, global. */
FRAMEBUFFER :: arch_interface.Mapping.{protection = .ReadWrite, cache = .WriteCombining, user = false, global = true}
/** A device-register mapping: read-write, uncached device memory, not global. */
DEVICE :: arch_interface.Mapping.{protection = .ReadWrite, cache = .Device, user = false, global = false}
/** A user data mapping: read-write, write-back, user. */
USER_DATA :: arch_interface.Mapping.{protection = .ReadWrite, cache = .WriteBack, user = true, global = false}

/** The memory standing in for physical memory, handed out a frame at a time. */
Memory :: struct {
    /** The offset that puts pretend physical address MEMORY_BASE at the buffer's start. */
    direct_map_offset : u64,
    /** The index of the next frame to hand out, from 0 to FRAME_COUNT. */
    next_frame : u64,
}

/**
 * Run every test: a kernel table, then a user address space sharing its kernel half.
 *
 * @return 0 if everything worked, 1 if the buffer couldn't be had, or the number of the first check that failed.
 */
main :: fn() -> int {
    bytes, error :: runtime.new_array(u8, cast[usize](FRAME_COUNT * FRAME_SIZE))
    if error != null {
        return 1
    }
    intrinsics.mem_zero(cast[mut rawptr](bytes.data), bytes.count)
    memory := Memory.{direct_map_offset = cast[u64](bytes.data) - MEMORY_BASE, next_frame = 0}

    kernel : arch.PageTable
    root :: next_frame(&memory)
    half :: next_frame(&memory)
    for i in 1..<arch.kernel_half_frames() {
        _ = next_frame(&memory)
    }
    arch.init_kernel_page_table(&kernel, root, half, cast[arch_interface.AddressSpaceTag](0), memory.direct_map_offset)

    failed :: test_kernel_pages(&kernel, &memory)
    if failed != 0 {
        return failed
    }
    return test_user_pages(&kernel, &memory)
}

/**
 * Test mapping, translating, protecting and unmapping kernel pages of 4 KiB and 2 MiB, and the errors and TLB batches.
 *
 * @param kernel The kernel's own table, set up, with nothing mapped yet.
 * @param memory Where new tables come from.
 * @return 0 if every check passed, or the first failed check's number, 10 to 28.
 */
test_kernel_pages :: fn(kernel: ptr[mut arch.PageTable], memory: ptr[mut Memory]) -> int {
    tables : arch_interface.TableFrames
    freed : arch_interface.FreedTables
    flush : arch_interface.TlbBatch

    // A 4 KiB page needs a page directory and a page table below the kernel half's table
    if !map_fails(kernel, KERNEL_PAGE, 0x5000, .Size4K, KERNEL_DATA, &tables, .NeedTableFrames) {
        return 10
    }
    refill(&tables, memory)
    if !mapped(kernel, KERNEL_PAGE, 0x5000, .Size4K, KERNEL_DATA, &tables) || tables.count != 2 {
        return 11
    }
    if !translates_to(kernel, KERNEL_PAGE + 0x123, 0x5123, KERNEL_DATA) || translates(kernel, KERNEL_PAGE + FRAME_SIZE) {
        return 12
    }
    if !map_fails(kernel, KERNEL_PAGE, 0x6000, .Size4K, KERNEL_DATA, &tables, .AlreadyMapped) {
        return 13
    }
    if !map_fails(kernel, KERNEL_PAGE + 8, 0x6000, .Size4K, KERNEL_DATA, &tables, .InvalidAddress)
        || !map_fails(kernel, USER_PAGE, 0x6000, .Size4K, USER_DATA, &tables, .InvalidAddress)
        || !map_fails(kernel, USER_PAGE, 0x6000, .Size4K, KERNEL_DATA, &tables, .InvalidAddress) {
        return 14
    }

    // A 2 MiB page beside it, in the same page directory, and write-combining in both sizes
    if !mapped(kernel, KERNEL_LARGE_PAGE, 0x400000, .Size2M, KERNEL_CODE, &tables) || tables.count != 2 {
        return 15
    }
    if !translates_to(kernel, KERNEL_LARGE_PAGE + 0x12345, 0x412345, KERNEL_CODE) {
        return 16
    }
    if !mapped(kernel, KERNEL_PAGE + FRAME_SIZE, 0x7000, .Size4K, FRAMEBUFFER, &tables)
        || !translates_to(kernel, KERNEL_PAGE + FRAME_SIZE, 0x7000, FRAMEBUFFER)
        || !mapped(kernel, KERNEL_LARGE_PAGE + 0x200000, 0x600000, .Size2M, FRAMEBUFFER, &tables)
        || !translates_to(kernel, KERNEL_LARGE_PAGE + 0x200000, 0x600000, FRAMEBUFFER)
        || !mapped(kernel, KERNEL_PAGE + 2 * FRAME_SIZE, 0x8000, .Size4K, DEVICE, &tables)
        || !translates_to(kernel, KERNEL_PAGE + 2 * FRAME_SIZE, 0x8000, DEVICE) {
        return 17
    }

    // Protection changes, and the flush covers the page
    if arch.protect(kernel, address(KERNEL_PAGE), .Size4K, KERNEL_READ_ONLY, &flush) is_error {
        return 18
    }
    if !translates_to(kernel, KERNEL_PAGE, 0x5000, KERNEL_READ_ONLY) || flush.count != 1 || cast[u64](flush.addresses[0]) != KERNEL_PAGE {
        return 19
    }

    // Unmapping one of three pages in the page table frees nothing
    if unmapped(kernel, KERNEL_PAGE, .Size4K, &freed, &flush) != 0x5000 || freed.count != 0 || translates(kernel, KERNEL_PAGE) {
        return 20
    }
    if !unmap_fails(kernel, KERNEL_PAGE, .Size4K, &freed, &flush, .NotMapped)
        || !unmap_fails(kernel, KERNEL_LARGE_PAGE + FRAME_SIZE, .Size4K, &freed, &flush, .PartOfLargerPage)
        || !unmap_fails(kernel, KERNEL_PAGE, .Size2M, &freed, &flush, .NotMapped) {
        return 21
    }
    // The last two free the page table, but not the page directory, which holds the 2 MiB pages
    if unmapped(kernel, KERNEL_PAGE + FRAME_SIZE, .Size4K, &freed, &flush) != 0x7000 || freed.count != 0 {
        return 22
    }
    if unmapped(kernel, KERNEL_PAGE + 2 * FRAME_SIZE, .Size4K, &freed, &flush) != 0x8000 || freed.count != 1 {
        return 23
    }
    // With no room to record a freed table, nothing changes
    freed.count = 4
    _ = unmapped(kernel, KERNEL_LARGE_PAGE + 0x200000, .Size2M, &freed, &flush)
    if !unmap_fails(kernel, KERNEL_LARGE_PAGE, .Size2M, &freed, &flush, .NeedFreedSpace) || !translates(kernel, KERNEL_LARGE_PAGE) {
        return 24
    }
    // Then the page directory goes, but the kernel half's table above it stays
    freed.count = 1
    if unmapped(kernel, KERNEL_LARGE_PAGE, .Size2M, &freed, &flush) != 0x400000 || freed.count != 2 {
        return 25
    }

    // A full batch covers everything
    if flush.all || flush.count != 6 {
        return 26
    }
    refill(&tables, memory)
    if !mapped(kernel, KERNEL_PAGE, 0x5000, .Size4K, KERNEL_DATA, &tables) {
        return 27
    }
    for i in 0..<11 {
        _ = arch.protect(kernel, address(KERNEL_PAGE), .Size4K, KERNEL_DATA, &flush)
    }
    freed.count = 0
    if !flush.all || unmapped(kernel, KERNEL_PAGE, .Size4K, &freed, &flush) != 0x5000 || freed.count != 2 {
        return 28
    }
    return 0
}

/**
 * Test a user address space: the shared kernel half, user mappings, their errors, and releasing its tables.
 *
 * @param kernel The kernel's own table, which test_kernel_pages left with nothing mapped.
 * @param memory Where new tables come from.
 * @return 0 if every check passed, or the first failed check's number, 30 to 39.
 */
test_user_pages :: fn(kernel: ptr[mut arch.PageTable], memory: ptr[mut Memory]) -> int {
    tables : arch_interface.TableFrames
    freed : arch_interface.FreedTables
    flush : arch_interface.TlbBatch
    user : arch.PageTable
    arch.init_page_table(&user, next_frame(memory), cast[arch_interface.AddressSpaceTag](5), kernel)

    // The kernel half is shared, including what the kernel maps after the address space was made
    refill(&tables, memory)
    if !mapped(kernel, KERNEL_PAGE, 0x9000, .Size4K, KERNEL_DATA, &tables) || !translates_to(&user, KERNEL_PAGE, 0x9000, KERNEL_DATA) {
        return 30
    }
    if !map_fails(&user, KERNEL_PAGE + FRAME_SIZE, 0x9000, .Size4K, KERNEL_DATA, &tables, .InvalidAddress) {
        return 31
    }

    // A user page needs three tables, which all go when it's unmapped
    refill(&tables, memory)
    if !mapped(&user, USER_PAGE, 0xa000, .Size4K, USER_DATA, &tables) || tables.count != 1 {
        return 32
    }
    if !translates_to(&user, USER_PAGE + 0x10, 0xa010, USER_DATA) || translates(kernel, USER_PAGE) {
        return 33
    }
    if !map_fails(&user, 0, 0xa000, .Size4K, USER_DATA, &tables, .InvalidAddress)
        || !map_fails(&user, 0x00007ffffffff000, 0xa000, .Size4K, USER_DATA, &tables, .InvalidAddress) {
        return 34
    }
    if unmapped(&user, USER_PAGE, .Size4K, &freed, &flush) != 0xa000 || freed.count != 3 || cast[u16](flush.tag) != 5 {
        return 35
    }
    if translates(&user, USER_PAGE) {
        return 36
    }

    // Three pages under two page directories: six tables below the root, all released, a few at a time
    refill(&tables, memory)
    _ = mapped(&user, USER_PAGE, 0xa000, .Size4K, USER_DATA, &tables)
    refill(&tables, memory)
    _ = mapped(&user, USER_PAGE + 0x200000, 0xb000, .Size4K, USER_DATA, &tables)
    refill(&tables, memory)
    _ = mapped(&user, 0x80000000, 0xc000, .Size4K, USER_DATA, &tables)
    if !translates(&user, 0x80000000) || !translates(&user, USER_PAGE + 0x200000) {
        return 37
    }
    released : u32 = 0
    calls : u32 = 0
    loop {
        freed.count = 0
        done :: arch.release_user_tables(&user, &freed)
        released += freed.count
        calls += 1
        if done {
            break
        }
    }
    while calls < 10
    if released != 6 || calls != 2 || translates(&user, USER_PAGE) || translates(&user, 0x80000000) {
        return 38
    }
    // The kernel half is still there
    if !translates_to(&user, KERNEL_PAGE, 0x9000, KERNEL_DATA) {
        return 39
    }
    return 0
}

/**
 * Hand out the buffer's next frame, zeroed since the buffer was.
 *
 * @param memory The buffer, with a frame left (asserted).
 * @return The frame's pretend physical address.
 */
next_frame :: fn(memory: ptr[mut Memory]) -> arch_interface.PhysicalAddress {
    runtime.assert(memory.next_frame < FRAME_COUNT, "the tests fit in FRAME_COUNT frames")
    frame :: MEMORY_BASE + memory.next_frame * FRAME_SIZE
    memory.next_frame += 1
    return cast[arch_interface.PhysicalAddress](frame)
}

/**
 * Fill tables up to 4 frames with new ones, keeping those it has.
 *
 * @param tables The frames, count set to 4.
 * @param memory Where the new frames come from.
 */
refill :: fn(tables: ptr[mut arch_interface.TableFrames], memory: ptr[mut Memory]) {
    for i in cast[usize](tables.count)..<4 {
        tables.frames[i] = next_frame(memory)
    }
    tables.count = 4
}

/**
 * Make a virtual address of a number.
 *
 * @param value Any number, kernel or user, canonical or not; it isn't checked.
 * @return The same bits, as a VirtualAddress.
 */
address :: fn(value: u64) -> arch_interface.VirtualAddress {
    return cast[arch_interface.VirtualAddress](value)
}

/**
 * Map a page, as arch.map does.
 *
 * @param table The kernel's table or a user address space, its tables in the buffer standing in for physical
 *     memory; changed if the page is mapped.
 * @param virtual_address Where to map it.
 * @param physical The page's pretend physical address.
 * @param size The page's size, which virtual_address must be aligned to for the call to succeed.
 * @param mapping The protection, cache mode, user flag and global bit to map it with, passed to arch.map as is.
 * @param tables Zeroed frames arch.map takes new tables from, the last first; refill puts it back to 4.
 * @return Whether it was mapped.
 */
mapped :: fn(
    table: ptr[mut arch.PageTable],
    virtual_address: u64,
    physical: u64,
    size: arch_interface.PageSize,
    mapping: arch_interface.Mapping,
    tables: ptr[mut arch_interface.TableFrames],
) -> bool {
    return arch.map(table, address(virtual_address), cast[arch_interface.PhysicalAddress](physical), size, mapping, tables) is_ok
}

/**
 * Try a map that ought to fail.
 *
 * @param table The kernel's table or a user address space, its tables in the buffer standing in for physical
 *     memory; left as it was if the map fails, changed if it wrongly succeeds.
 * @param virtual_address Where to map it.
 * @param physical The page's pretend physical address.
 * @param size The page's size, which virtual_address must be aligned to for the call to succeed.
 * @param mapping The protection, cache mode, user flag and global bit to map it with, passed to arch.map as is.
 * @param tables Zeroed frames arch.map takes new tables from, the last first; refill puts it back to 4.
 * @param expected The error it ought to fail with.
 * @return Whether it failed with expected; false if it mapped, or failed otherwise.
 */
map_fails :: fn(
    table: ptr[mut arch.PageTable],
    virtual_address: u64,
    physical: u64,
    size: arch_interface.PageSize,
    mapping: arch_interface.Mapping,
    tables: ptr[mut arch_interface.TableFrames],
    expected: arch_interface.MapError,
) -> bool {
    return match arch.map(table, address(virtual_address), cast[arch_interface.PhysicalAddress](physical), size, mapping, tables) {
        case Ok => false
        case Error(error) => error == expected
    }
}

/**
 * Unmap a page, as arch.unmap does.
 *
 * @param table The kernel's table or a user address space, its tables in the buffer standing in for physical
 *     memory; changed if the page is unmapped.
 * @param virtual_address The page's address.
 * @param size The size the page was mapped with; a page of another size there makes the unmap fail.
 * @param freed Where emptied tables go.
 * @param flush The TLB batch the page is added to.
 * @return The physical address it mapped, or 1, which no page is at, if unmapping failed.
 */
unmapped :: fn(
    table: ptr[mut arch.PageTable],
    virtual_address: u64,
    size: arch_interface.PageSize,
    freed: ptr[mut arch_interface.FreedTables],
    flush: ptr[mut arch_interface.TlbBatch],
) -> u64 {
    return match arch.unmap(table, address(virtual_address), size, freed, flush) {
        case Ok(physical) => cast[u64](physical)
        case Error(error) => 1
    }
}

/**
 * Try an unmap that ought to fail.
 *
 * @param table The kernel's table or a user address space, its tables in the buffer standing in for physical
 *     memory; left as it was if the unmap fails, changed if it wrongly succeeds.
 * @param virtual_address The page's address.
 * @param size The size the page was mapped with; a page of another size there makes the unmap fail.
 * @param freed Where emptied tables would go.
 * @param flush The TLB batch the page would be added to.
 * @param expected The error it ought to fail with.
 * @return Whether it failed with expected; false if it unmapped, or failed otherwise.
 */
unmap_fails :: fn(
    table: ptr[mut arch.PageTable],
    virtual_address: u64,
    size: arch_interface.PageSize,
    freed: ptr[mut arch_interface.FreedTables],
    flush: ptr[mut arch_interface.TlbBatch],
    expected: arch_interface.UnmapError,
) -> bool {
    return match arch.unmap(table, address(virtual_address), size, freed, flush) {
        case Ok(physical) => false
        case Error(error) => error == expected
    }
}

/**
 * Tell whether anything is mapped at an address.
 *
 * @param table The kernel's table or a user address space, its tables in the buffer standing in for physical
 *     memory; only read.
 * @param virtual_address Any address, kernel or user, anywhere in a page; a page of any size counts.
 * @return Whether arch.translate finds a mapping.
 */
translates :: fn(table: ptr[arch.PageTable], virtual_address: u64) -> bool {
    return arch.translate(table, address(virtual_address)) != null
}

/**
 * Tell whether an address is mapped to a physical address with a mapping.
 *
 * @param table The kernel's table or a user address space, its tables in the buffer standing in for physical
 *     memory; only read.
 * @param virtual_address Any address, kernel or user, anywhere in a page of any size.
 * @param physical The physical address it ought to map to, its offset in the page included.
 * @param mapping The mapping it ought to have, every field compared.
 * @return Whether both match; false if nothing is mapped there.
 */
translates_to :: fn(table: ptr[arch.PageTable], virtual_address: u64, physical: u64, mapping: arch_interface.Mapping) -> bool {
    found :: arch.translate(table, address(virtual_address)) or_return false
    return cast[u64](found.physical_address) == physical
        && found.mapping.protection == mapping.protection
        && found.mapping.cache == mapping.cache
        && found.mapping.user == mapping.user
        && found.mapping.global == mapping.global
}
