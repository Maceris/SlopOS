/**
 * x86-64 paging's tests, a test program (tools/unit_tests.py, decisions/0175).
 *
 * In each test a buffer stands in for physical memory from MEMORY_BASE on, reached through a direct map whose offset
 * makes those addresses land in it. Its frames are handed out in order, zeroed: the kernel table's root first, then its
 * kernel half's 256 tables, then the rest as tests need them.
 */
package x86_64_test

import intrinsics from "base"
import runtime from "base"
import testing from "std"
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

/** A kernel table in a buffer standing in for physical memory, as kernel_space makes it. */
Space :: struct {
    /** The buffer, FRAME_COUNT frames, from the context's allocator, which free_space gives back. */
    bytes : mut u8[],
    /** The buffer's frames, handed out from after the kernel table's. */
    memory : Memory,
    /** The kernel's own table, its root and its kernel half's tables the buffer's first frames. */
    kernel : arch.PageTable,
}

/**
 * Make a kernel table with nothing mapped, in a zeroed buffer standing in for physical memory: its root the first frame,
 * its kernel half's tables the next.
 *
 * @param t The test's state, which a failure is recorded in.
 * @return The table and its memory, which the caller frees with free_space; Error if the buffer couldn't be allocated,
 *     the failure recorded.
 */
kernel_space :: fn(t: ptr[mut testing.T]) -> Result[Space, testing.Stopped] {
    bytes, error :: runtime.new_array(u8, cast[usize](FRAME_COUNT * FRAME_SIZE))
    testing.require(t, error == null, "the buffer standing in for physical memory is allocated")?
    intrinsics.mem_zero(cast[mut rawptr](bytes.data), bytes.count)
    made := Space.{bytes = bytes, memory = Memory.{direct_map_offset = cast[u64](bytes.data) - MEMORY_BASE, next_frame = 0}}
    root :: next_frame(&made.memory)
    half :: next_frame(&made.memory)
    for i in 1..<arch.kernel_half_frames() {
        _ = next_frame(&made.memory)
    }
    arch.init_kernel_page_table(&made.kernel, root, half, cast[arch_interface.AddressSpaceTag](0), made.memory.direct_map_offset)
    return .Ok(made)
}

/**
 * Give back a space kernel_space made.
 *
 * @param space The space, whose tables aren't used after.
 */
free_space :: fn(space: Space) {
    runtime.free_array(space.bytes)
}

/**
 * Map what kernel_pages_map_and_translate maps, for the tests that go on from there: KERNEL_DATA's page at
 * KERNEL_PAGE, KERNEL_CODE's 2 MiB page at KERNEL_LARGE_PAGE, and write-combining and device pages beside them.
 *
 * @param t The test's state, which a failure is recorded in.
 * @param space A kernel table with nothing mapped; its memory gives the tables needed.
 * @param tables Frames for new tables, refilled to 4 first.
 * @return Ok once all five are mapped; Error at the first that isn't, the failure recorded.
 */
map_kernel_pages :: fn(t: ptr[mut testing.T], space: ptr[mut Space], tables: ptr[mut arch_interface.TableFrames]) -> testing.Outcome {
    refill(tables, &space.memory)
    expect_mapped(t, &space.kernel, KERNEL_PAGE, 0x5000, .Size4K, KERNEL_DATA, tables, "a 4 KiB kernel page")?
    expect_mapped(t, &space.kernel, KERNEL_LARGE_PAGE, 0x400000, .Size2M, KERNEL_CODE, tables, "a 2 MiB kernel page")?
    expect_mapped(t, &space.kernel, KERNEL_PAGE + FRAME_SIZE, 0x7000, .Size4K, FRAMEBUFFER, tables, "a 4 KiB write-combining page")?
    expect_mapped(t, &space.kernel, KERNEL_LARGE_PAGE + 0x200000, 0x600000, .Size2M, FRAMEBUFFER, tables,
        "a 2 MiB write-combining page")?
    expect_mapped(t, &space.kernel, KERNEL_PAGE + 2 * FRAME_SIZE, 0x8000, .Size4K, DEVICE, tables, "a device page")?
    return .Ok
}

kernel_pages_map_and_translate #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    space := kernel_space(t)?
    defer free_space(space)
    kernel :: &space.kernel
    tables : arch_interface.TableFrames
    // A 4 KiB page needs a page directory and a page table below the kernel half's table
    expect_map_fails(t, kernel, KERNEL_PAGE, 0x5000, .Size4K, KERNEL_DATA, &tables, .NeedTableFrames,
        "a 4 KiB page needs a page directory and a page table, and there are no frames for them")
    refill(&tables, &space.memory)
    expect_mapped(t, kernel, KERNEL_PAGE, 0x5000, .Size4K, KERNEL_DATA, &tables, "with frames for its tables, it's mapped")?
    testing.expect_eq(t, tables.count, 2, "two of the four frames became its page directory and page table")
    expect_translates_to(t, kernel, KERNEL_PAGE + 0x123, 0x5123, KERNEL_DATA, "an address in the page, its offset kept")
    testing.expect(t, !translates(kernel, KERNEL_PAGE + FRAME_SIZE), "the next page isn't mapped")
    expect_map_fails(t, kernel, KERNEL_PAGE, 0x6000, .Size4K, KERNEL_DATA, &tables, .AlreadyMapped, "the page is mapped already")
    expect_map_fails(t, kernel, KERNEL_PAGE + 8, 0x6000, .Size4K, KERNEL_DATA, &tables, .InvalidAddress,
        "an address that isn't page-aligned")
    expect_map_fails(t, kernel, USER_PAGE, 0x6000, .Size4K, USER_DATA, &tables, .InvalidAddress,
        "the kernel's table maps only the kernel half")
    expect_map_fails(t, kernel, USER_PAGE, 0x6000, .Size4K, KERNEL_DATA, &tables, .InvalidAddress,
        "nor a user address as a kernel page")
    // A 2 MiB page beside it, in the same page directory, and write-combining in both sizes
    expect_mapped(t, kernel, KERNEL_LARGE_PAGE, 0x400000, .Size2M, KERNEL_CODE, &tables, "a 2 MiB page beside the 4 KiB one")?
    testing.expect_eq(t, tables.count, 2, "it's in the page directory there is, so no new table is taken")
    expect_translates_to(t, kernel, KERNEL_LARGE_PAGE + 0x12345, 0x412345, KERNEL_CODE, "an address in the 2 MiB page")
    expect_mapped(t, kernel, KERNEL_PAGE + FRAME_SIZE, 0x7000, .Size4K, FRAMEBUFFER, &tables, "a 4 KiB write-combining page")
    expect_translates_to(t, kernel, KERNEL_PAGE + FRAME_SIZE, 0x7000, FRAMEBUFFER, "write-combining, in a 4 KiB page's PAT bit")
    expect_mapped(t, kernel, KERNEL_LARGE_PAGE + 0x200000, 0x600000, .Size2M, FRAMEBUFFER, &tables, "a 2 MiB write-combining page")
    expect_translates_to(t, kernel, KERNEL_LARGE_PAGE + 0x200000, 0x600000, FRAMEBUFFER, "write-combining, in a 2 MiB page's PAT bit")
    expect_mapped(t, kernel, KERNEL_PAGE + 2 * FRAME_SIZE, 0x8000, .Size4K, DEVICE, &tables, "a device page")
    expect_translates_to(t, kernel, KERNEL_PAGE + 2 * FRAME_SIZE, 0x8000, DEVICE, "uncached, and not global")
    return .Ok
}

protecting_a_page_changes_it_and_flushes_it #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    space := kernel_space(t)?
    defer free_space(space)
    kernel :: &space.kernel
    tables : arch_interface.TableFrames
    flush : arch_interface.TlbBatch
    map_kernel_pages(t, &space, &tables)?
    protected :: arch.protect(kernel, address(KERNEL_PAGE), .Size4K, KERNEL_READ_ONLY, &flush)
    testing.outcome_of(testing.expect_ok(t, protected, "a mapped page can be made read-only"))?
    expect_translates_to(t, kernel, KERNEL_PAGE, 0x5000, KERNEL_READ_ONLY, "it's read-only, at the same physical address")
    testing.require_eq(t, flush.count, 1, "the page's old entry is in the batch to flush")?
    testing.expect_eq(t, cast[u64](flush.addresses[0]), KERNEL_PAGE, "at the page's address")
    return .Ok
}

unmapping_frees_tables_once_they_are_empty #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    space := kernel_space(t)?
    defer free_space(space)
    kernel :: &space.kernel
    tables : arch_interface.TableFrames
    freed : arch_interface.FreedTables
    flush : arch_interface.TlbBatch
    map_kernel_pages(t, &space, &tables)?
    protected :: arch.protect(kernel, address(KERNEL_PAGE), .Size4K, KERNEL_READ_ONLY, &flush)
    testing.outcome_of(testing.expect_ok(t, protected, "a mapped page can be made read-only"))?
    // Unmapping one of three pages in the page table frees nothing
    expect_unmapped(t, kernel, KERNEL_PAGE, .Size4K, &freed, &flush, 0x5000, "a 4 KiB page unmaps, giving its frame")
    testing.expect_eq(t, freed.count, 0, "two pages are left in its page table, so no table is freed")
    testing.expect(t, !translates(kernel, KERNEL_PAGE), "it's unmapped")
    expect_unmap_fails(t, kernel, KERNEL_PAGE, .Size4K, &freed, &flush, .NotMapped, "it can't be unmapped twice")
    expect_unmap_fails(t, kernel, KERNEL_LARGE_PAGE + FRAME_SIZE, .Size4K, &freed, &flush, .PartOfLargerPage,
        "4 KiB of a 2 MiB page can't be unmapped alone")
    expect_unmap_fails(t, kernel, KERNEL_PAGE, .Size2M, &freed, &flush, .NotMapped, "a 2 MiB page where only a page table is")
    // The last two free the page table, but not the page directory, which holds the 2 MiB pages
    expect_unmapped(t, kernel, KERNEL_PAGE + FRAME_SIZE, .Size4K, &freed, &flush, 0x7000, "the second 4 KiB page unmaps")
    testing.expect_eq(t, freed.count, 0, "one page is left in the page table")
    expect_unmapped(t, kernel, KERNEL_PAGE + 2 * FRAME_SIZE, .Size4K, &freed, &flush, 0x8000, "the last 4 KiB page unmaps")
    testing.expect_eq(t, freed.count, 1, "the page table, empty, is freed; the page directory holds the 2 MiB pages")
    // With no room to record a freed table, nothing changes
    freed.count = 4
    expect_unmapped(t, kernel, KERNEL_LARGE_PAGE + 0x200000, .Size2M, &freed, &flush, 0x600000,
        "a 2 MiB page beside another frees no table")
    expect_unmap_fails(t, kernel, KERNEL_LARGE_PAGE, .Size2M, &freed, &flush, .NeedFreedSpace,
        "the last page in the page directory would free it, and freed is full")
    testing.expect(t, translates(kernel, KERNEL_LARGE_PAGE), "so the page is still mapped")
    // Then the page directory goes, but the kernel half's table above it stays
    freed.count = 1
    expect_unmapped(t, kernel, KERNEL_LARGE_PAGE, .Size2M, &freed, &flush, 0x400000, "with room, the last 2 MiB page unmaps")
    testing.expect_eq(t, freed.count, 2, "freeing the page directory, but not the kernel half's table above it")
    // A full batch covers everything
    testing.expect(t, !flush.all, "six addresses fit in a batch")
    testing.expect_eq(t, flush.count, 6, "the protected page and five unmapped, the failed unmaps adding none")
    refill(&tables, &space.memory)
    expect_mapped(t, kernel, KERNEL_PAGE, 0x5000, .Size4K, KERNEL_DATA, &tables, "the page maps again, with new tables")?
    for i in 0..<11 {
        _ = arch.protect(kernel, address(KERNEL_PAGE), .Size4K, KERNEL_DATA, &flush)
    }
    testing.expect(t, flush.all, "17 addresses don't fit in a batch of 16, so it flushes everything")
    freed.count = 0
    expect_unmapped(t, kernel, KERNEL_PAGE, .Size4K, &freed, &flush, 0x5000, "with the batch full, unmapping still works")
    testing.expect_eq(t, freed.count, 2, "freeing its page table and page directory")
    return .Ok
}

/** A user address space sharing a kernel table's half, as user_space makes it. */
UserSpace :: struct {
    /** The kernel table and its memory, which free_space gives back. */
    space : Space,
    /** The user address space, its root the next frame, of tag 5. */
    user : arch.PageTable,
}

/**
 * Make a user address space of tag 5, sharing a new kernel table's half.
 *
 * @param t The test's state, which a failure is recorded in.
 * @return The address space and the kernel table, which the caller frees with free_space(made.space); Error if
 *     kernel_space failed, the failure recorded.
 */
user_space :: fn(t: ptr[mut testing.T]) -> Result[UserSpace, testing.Stopped] {
    made := UserSpace.{space = kernel_space(t)?}
    arch.init_page_table(&made.user, next_frame(&made.space.memory), cast[arch_interface.AddressSpaceTag](5), &made.space.kernel)
    return .Ok(made)
}

the_kernel_half_is_shared_with_user_address_spaces #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made := user_space(t)?
    defer free_space(made.space)
    kernel :: &made.space.kernel
    tables : arch_interface.TableFrames
    freed : arch_interface.FreedTables
    flush : arch_interface.TlbBatch
    refill(&tables, &made.space.memory)
    expect_mapped(t, kernel, KERNEL_PAGE, 0x9000, .Size4K, KERNEL_DATA, &tables, "a kernel page, after the address space was made")?
    expect_translates_to(t, &made.user, KERNEL_PAGE, 0x9000, KERNEL_DATA, "the user table sees it, its kernel half shared")
    // Nor unmapped through a user table: the kernel's page stays
    expect_map_fails(t, &made.user, KERNEL_PAGE + FRAME_SIZE, 0x9000, .Size4K, KERNEL_DATA, &tables, .InvalidAddress,
        "a user table can't map in the kernel half")
    expect_unmap_fails(t, &made.user, KERNEL_PAGE, .Size4K, &freed, &flush, .NotMapped, "nor unmap from it")
    expect_translates_to(t, kernel, KERNEL_PAGE, 0x9000, KERNEL_DATA, "the kernel's page stays")
    return .Ok
}

a_user_page_takes_three_tables_which_go_when_it_is_unmapped #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made := user_space(t)?
    defer free_space(made.space)
    kernel :: &made.space.kernel
    tables : arch_interface.TableFrames
    freed : arch_interface.FreedTables
    flush : arch_interface.TlbBatch
    refill(&tables, &made.space.memory)
    expect_mapped(t, &made.user, USER_PAGE, 0xa000, .Size4K, USER_DATA, &tables, "a user page in a user address space")?
    testing.expect_eq(t, tables.count, 1, "it took three tables below the root: a PDPT, a page directory and a page table")
    expect_translates_to(t, &made.user, USER_PAGE + 0x10, 0xa010, USER_DATA, "an address in it, its offset kept")
    testing.expect(t, !translates(kernel, USER_PAGE), "the kernel's table doesn't see user pages")
    expect_map_fails(t, &made.user, 0, 0xa000, .Size4K, USER_DATA, &tables, .InvalidAddress, "page 0 is never mapped")
    expect_map_fails(t, &made.user, 0x00007ffffffff000, 0xa000, .Size4K, USER_DATA, &tables, .InvalidAddress,
        "nor the page below the canonical boundary")
    expect_unmapped(t, &made.user, USER_PAGE, .Size4K, &freed, &flush, 0xa000, "the user page unmaps, giving its frame")
    testing.expect_eq(t, freed.count, 3, "its three tables are empty, and all freed")
    testing.expect_eq(t, cast[u16](flush.tag), 5, "the flush is for the address space's tag")
    testing.expect(t, !translates(&made.user, USER_PAGE), "it's unmapped")
    return .Ok
}

a_user_address_spaces_tables_are_released_a_few_at_a_time #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made := user_space(t)?
    defer free_space(made.space)
    tables : arch_interface.TableFrames
    freed : arch_interface.FreedTables
    refill(&tables, &made.space.memory)
    expect_mapped(t, &made.space.kernel, KERNEL_PAGE, 0x9000, .Size4K, KERNEL_DATA, &tables, "a kernel page")?
    // Three pages under two page directories: six tables below the root
    refill(&tables, &made.space.memory)
    _ = mapped(&made.user, USER_PAGE, 0xa000, .Size4K, USER_DATA, &tables)
    refill(&tables, &made.space.memory)
    _ = mapped(&made.user, USER_PAGE + 0x200000, 0xb000, .Size4K, USER_DATA, &tables)
    refill(&tables, &made.space.memory)
    _ = mapped(&made.user, 0x80000000, 0xc000, .Size4K, USER_DATA, &tables)
    testing.expect(t, translates(&made.user, 0x80000000), "a page under another PDPT entry is mapped")
    testing.expect(t, translates(&made.user, USER_PAGE + 0x200000), "a page under another page directory entry is mapped")
    released : u32 = 0
    calls : u32 = 0
    loop {
        freed.count = 0
        done :: arch.release_user_tables(&made.user, &freed)
        released += freed.count
        calls += 1
        if done {
            break
        }
    }
    while calls < 10
    testing.expect_eq(t, released, 6, "a PDPT, two page directories and three page tables")
    testing.expect_eq(t, calls, 2, "freed holds four, so six take two calls")
    testing.expect(t, !translates(&made.user, USER_PAGE), "the user pages are gone")
    testing.expect(t, !translates(&made.user, 0x80000000), "all of them")
    expect_translates_to(t, &made.user, KERNEL_PAGE, 0x9000, KERNEL_DATA, "the kernel half is still there")
    return .Ok
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
 * Check that a page maps, as arch.map does, reporting the error if it doesn't.
 *
 * @param t The test's state, which a failure is recorded in.
 * @param table The kernel's table or a user address space, its tables in the buffer standing in for physical
 *     memory; changed if the page is mapped.
 * @param virtual_address Where to map it.
 * @param physical The page's pretend physical address.
 * @param size The page's size, which virtual_address must be aligned to for the call to succeed.
 * @param mapping The protection, cache mode, user flag and global bit to map it with, passed to arch.map as is.
 * @param tables Zeroed frames arch.map takes new tables from, the last first; refill puts it back to 4.
 * @param message Why it should map, for whoever reads a failure.
 * @param location Where the check is; the caller's own.
 * @return Ok if it was mapped; Error(Failed), the failure recorded, if not, for a test that can't go on without it.
 */
expect_mapped :: fn(
    t: ptr[mut testing.T],
    table: ptr[mut arch.PageTable],
    virtual_address: u64,
    physical: u64,
    size: arch_interface.PageSize,
    mapping: arch_interface.Mapping,
    tables: ptr[mut arch_interface.TableFrames],
    message: string,
    location := #caller_location,
) -> testing.Outcome {
    result :: arch.map(table, address(virtual_address), cast[arch_interface.PhysicalAddress](physical), size, mapping, tables)
    return testing.outcome_of(testing.expect_ok(t, result, message, location))
}

/**
 * Check that a map fails as it ought to, reporting what happened if it doesn't.
 *
 * @param t The test's state, which a failure is recorded in.
 * @param table The kernel's table or a user address space, its tables in the buffer standing in for physical
 *     memory; left as it was if the map fails, changed if it wrongly succeeds.
 * @param virtual_address Where to map it.
 * @param physical The page's pretend physical address.
 * @param size The page's size, which virtual_address must be aligned to for the call to succeed.
 * @param mapping The protection, cache mode, user flag and global bit to map it with, passed to arch.map as is.
 * @param tables Zeroed frames arch.map takes new tables from, the last first; refill puts it back to 4.
 * @param expected The error it ought to fail with.
 * @param message Why it should fail so, for whoever reads a failure.
 * @param location Where the check is; the caller's own.
 */
expect_map_fails :: fn(
    t: ptr[mut testing.T],
    table: ptr[mut arch.PageTable],
    virtual_address: u64,
    physical: u64,
    size: arch_interface.PageSize,
    mapping: arch_interface.Mapping,
    tables: ptr[mut arch_interface.TableFrames],
    expected: arch_interface.MapError,
    message: string,
    location := #caller_location,
) {
    result :: arch.map(table, address(virtual_address), cast[arch_interface.PhysicalAddress](physical), size, mapping, tables)
    _ = testing.expect_error(t, result, expected, message, location)
}

/**
 * Check that a page unmaps, as arch.unmap does, giving the physical address it mapped.
 *
 * @param t The test's state, which a failure is recorded in.
 * @param table The kernel's table or a user address space, its tables in the buffer standing in for physical
 *     memory; changed if the page is unmapped.
 * @param virtual_address The page's address, kernel or user, as a plain number; it's passed to arch.unmap unchecked.
 * @param size The size the page was mapped with; a page of another size there makes the unmap fail.
 * @param freed Where emptied tables go.
 * @param flush The TLB batch the page is added to.
 * @param physical The physical address it ought to have mapped.
 * @param message Why it should unmap so, for whoever reads a failure.
 * @param location Where the check is; the caller's own.
 */
expect_unmapped :: fn(
    t: ptr[mut testing.T],
    table: ptr[mut arch.PageTable],
    virtual_address: u64,
    size: arch_interface.PageSize,
    freed: ptr[mut arch_interface.FreedTables],
    flush: ptr[mut arch_interface.TlbBatch],
    physical: u64,
    message: string,
    location := #caller_location,
) {
    result :: arch.unmap(table, address(virtual_address), size, freed, flush)
    match result {
        case Ok(found) => {
            _ = testing.expect_eq(t, cast[u64](found), physical, message, location)
        }
        case Error => {
            _ = testing.expect_ok(t, result, message, location)
        }
    }
}

/**
 * Check that an unmap fails as it ought to, reporting what happened if it doesn't.
 *
 * @param t The test's state, which a failure is recorded in.
 * @param table The kernel's table or a user address space, its tables in the buffer standing in for physical
 *     memory; left as it was if the unmap fails, changed if it wrongly succeeds.
 * @param virtual_address The address to unmap at, as a plain number, passed to arch.unmap unchecked: aligned or not, in
 *     table's half or not, as the case being tested needs.
 * @param size The size the page was mapped with; a page of another size there makes the unmap fail.
 * @param freed Where emptied tables would go.
 * @param flush The TLB batch the page would be added to.
 * @param expected The error it ought to fail with.
 * @param message Why it should fail so, for whoever reads a failure.
 * @param location Where the check is; the caller's own.
 */
expect_unmap_fails :: fn(
    t: ptr[mut testing.T],
    table: ptr[mut arch.PageTable],
    virtual_address: u64,
    size: arch_interface.PageSize,
    freed: ptr[mut arch_interface.FreedTables],
    flush: ptr[mut arch_interface.TlbBatch],
    expected: arch_interface.UnmapError,
    message: string,
    location := #caller_location,
) {
    result :: arch.unmap(table, address(virtual_address), size, freed, flush)
    _ = testing.expect_error(t, result, expected, message, location)
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
 * Check that an address is mapped to a physical address with a mapping, reporting what differs if it isn't.
 *
 * @param t The test's state, which a failure is recorded in.
 * @param table The kernel's table or a user address space, its tables in the buffer standing in for physical
 *     memory; only read.
 * @param virtual_address Any address, kernel or user, anywhere in a page of any size.
 * @param physical The physical address it ought to map to, its offset in the page included.
 * @param mapping The mapping it ought to have, every field compared.
 * @param message Why it should map so, for whoever reads a failure.
 * @param location Where the check is; the caller's own.
 */
expect_translates_to :: fn(t: ptr[mut testing.T], table: ptr[arch.PageTable], virtual_address: u64, physical: u64,
        mapping: arch_interface.Mapping, message: string, location := #caller_location) {
    match arch.translate(table, address(virtual_address)) {
        case Some(found) => {
            _ = testing.expect_eq(t, cast[u64](found.physical_address), physical, message, location)
            _ = testing.expect_eq(t, found.mapping.protection, mapping.protection, message, location)
            _ = testing.expect_eq(t, found.mapping.cache, mapping.cache, message, location)
            _ = testing.expect_eq(t, found.mapping.user, mapping.user, message, location)
            _ = testing.expect_eq(t, found.mapping.global, mapping.global, message, location)
        }
        case None => testing.record(t, message, "nothing is mapped there", location)
    }
}
