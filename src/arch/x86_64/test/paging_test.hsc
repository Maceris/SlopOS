/*
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

MEMORY_BASE : u64 : 0x100000
FRAME_COUNT : u64 : 300
FRAME_SIZE : u64 : 4096

// Kernel and user addresses the tests map.
KERNEL_PAGE : u64 : 0xffff800000100000
KERNEL_LARGE_PAGE : u64 : 0xffff800000200000
USER_PAGE : u64 : 0x400000

KERNEL_DATA :: arch_interface.Mapping.{protection = .ReadWrite, cache = .WriteBack, user = false, global = true}
KERNEL_CODE :: arch_interface.Mapping.{protection = .ReadExecute, cache = .WriteBack, user = false, global = true}
KERNEL_READ_ONLY :: arch_interface.Mapping.{protection = .Read, cache = .WriteBack, user = false, global = true}
FRAMEBUFFER :: arch_interface.Mapping.{protection = .ReadWrite, cache = .WriteCombining, user = false, global = true}
DEVICE :: arch_interface.Mapping.{protection = .ReadWrite, cache = .Device, user = false, global = false}
USER_DATA :: arch_interface.Mapping.{protection = .ReadWrite, cache = .WriteBack, user = true, global = false}

// The memory standing in for physical memory, handed out a frame at a time.
Memory :: struct {
    direct_map_offset : u64,
    next_frame : u64,
}

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

next_frame :: fn(memory: ptr[mut Memory]) -> arch_interface.PhysicalAddress {
    runtime.assert(memory.next_frame < FRAME_COUNT, "the tests fit in FRAME_COUNT frames")
    frame :: MEMORY_BASE + memory.next_frame * FRAME_SIZE
    memory.next_frame += 1
    return cast[arch_interface.PhysicalAddress](frame)
}

refill :: fn(tables: ptr[mut arch_interface.TableFrames], memory: ptr[mut Memory]) {
    for i in cast[usize](tables.count)..<4 {
        tables.frames[i] = next_frame(memory)
    }
    tables.count = 4
}

address :: fn(value: u64) -> arch_interface.VirtualAddress {
    return cast[arch_interface.VirtualAddress](value)
}

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

// Whether map fails with expected.
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

// The physical address unmap gives, or 1 if it fails.
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

// Whether unmap fails with expected.
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

translates :: fn(table: ptr[arch.PageTable], virtual_address: u64) -> bool {
    return arch.translate(table, address(virtual_address)) != null
}

translates_to :: fn(table: ptr[arch.PageTable], virtual_address: u64, physical: u64, mapping: arch_interface.Mapping) -> bool {
    found :: arch.translate(table, address(virtual_address)) or_return false
    return cast[u64](found.physical_address) == physical
        && found.mapping.protection == mapping.protection
        && found.mapping.cache == mapping.cache
        && found.mapping.user == mapping.user
        && found.mapping.global == mapping.global
}
