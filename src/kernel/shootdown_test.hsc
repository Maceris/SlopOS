package kernel

import intrinsics from "base"
import runtime from "base"
import arch_interface from "../arch_interface"
import concurrency from "std"
import frames from "frames"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}
#else_if TARGET_ARCH == .arm64 {
    import arch from "../arch/aarch64"
}

/*
 * test_shootdown: a page in the kernel window every CPU reads, so each has it in its TLB, then pointed
 * at another frame, with a shootdown. Asked again, every CPU has to read the new frame: without the
 * shootdown, the others would still read the old one through their TLBs. The other CPUs read when a
 * reschedule IPI takes them from idle (read_for_shootdown_test).
 */
/** The most CPUs the test can check: ShootdownTest.seen's size. With more online, it fails without running. */
SHOOTDOWN_TEST_CPUS :: 64
/** What the page's first frame holds, which every CPU reads before the shootdown. */
OLD_PAGE_VALUE : u64 : 0x1111111111111111
/** What the page's second frame holds, which every CPU has to read after it. */
NEW_PAGE_VALUE : u64 : 0x2222222222222222
/** How long the boot CPU waits for every other CPU to read the page, in milliseconds, each time it asks. */
SHOOTDOWN_TEST_TIMEOUT_MS :: 1000

/** How the test's page is mapped: read-write, write-back, kernel only, and global, kept across space switches. */
TEST_PAGE_MAPPING :: arch_interface.Mapping.{protection = .ReadWrite, cache = .WriteBack, user = false, global = true}

/** test_shootdown's state, which the other CPUs reach through kernel.shootdown_test while it runs. */
ShootdownTest :: struct {
    /** The page's kernel virtual address in the kernel window. */
    address : u64,
    /** What each CPU read from the page, by its index, 0 until it has; written and read volatile. */
    seen : u64[SHOOTDOWN_TEST_CPUS],
    /** How many reads were answered in all, incremented atomically; a CPU woken twice counts twice. */
    answered : u32,
}

/**
 * Test TLB shootdown: every other CPU reads a page in the kernel window, the page is pointed at another frame with a
 * shootdown, and every CPU then has to read the new frame.
 *
 * Runs on the boot CPU at boot, with 2 to SHOOTDOWN_TEST_CPUS CPUs online, and logs whether it passed. Running out of
 * memory for the test stops the kernel. On a failure, what it allocated and mapped is left as it is, and once the page
 * is mapped, kernel.shootdown_test stays set; only a pass gives the frames and mapping back. Its ShootdownTest is
 * never freed.
 *
 * @param kernel The kernel, whose frames, window and page table it uses.
 */
test_shootdown :: fn(kernel: ptr[mut Kernel]) {
    if kernel.online_cpus < 2 || cast[usize](kernel.online_cpus) > SHOOTDOWN_TEST_CPUS {
        runtime.log_error("test_shootdown: needs 2 to % CPUs online, not %", SHOOTDOWN_TEST_CPUS, kernel.online_cpus)
        return void
    }
    test :: allocate_object[ShootdownTest](&kernel.frames) or_else out_of_memory(&kernel.options, "test_shootdown: no memory")
    old :: frames.allocate(&kernel.frames, 0) or_else out_of_memory(&kernel.options, "test_shootdown: no memory")
    new :: frames.allocate(&kernel.frames, 0) or_else out_of_memory(&kernel.options, "test_shootdown: no memory")
    cast[ptr[mut u64]](frames.virtual_of(&kernel.frames, old))^ = OLD_PAGE_VALUE
    cast[ptr[mut u64]](frames.virtual_of(&kernel.frames, new))^ = NEW_PAGE_VALUE
    match map_in_window(kernel, cast[u64](old), frames.FRAME_SIZE, TEST_PAGE_MAPPING) {
        case Ok(address) => test.address = address
        case Error(error) => {
            runtime.log_error("test_shootdown: the kernel window couldn't map a page")
            return void
        }
    }
    intrinsics.atomic_store_u64_release(&kernel.shootdown_test, cast[u64](test))
    if !every_cpu_reads(kernel, test, OLD_PAGE_VALUE) {
        return void
    }

    // The same address, another frame
    flush : arch_interface.TlbBatch
    freed : arch_interface.FreedTables
    lock_at(&kernel.page_table_lock, .PageTable)
    _ = arch.unmap(&kernel.page_table, cast[arch_interface.VirtualAddress](test.address), .Size4K, &freed, &flush)
    unlock_at(&kernel.page_table_lock, .PageTable)
    shootdown(kernel, &flush)
    free_tables(kernel, &freed)
    mapper : Mapper
    map_page(kernel, test.address, cast[u64](new), .Size4K, TEST_PAGE_MAPPING, &mapper)
    give_back_tables(kernel, &mapper.tables)
    if !every_cpu_reads(kernel, test, NEW_PAGE_VALUE) {
        return void
    }

    intrinsics.atomic_store_u64_release(&kernel.shootdown_test, 0)
    unmap_from_window(kernel, test.address, frames.FRAME_SIZE)
    frames.free(&kernel.frames, old, 0)
    frames.free(&kernel.frames, new, 0)
    runtime.log_info("test_shootdown: every CPU read the new page after the shootdown")
}

/**
 * Ask every other online CPU to read the test's page, with a Reschedule IPI each, and check they all read a value.
 *
 * Each CPU's own reading is waited for, up to SHOOTDOWN_TEST_TIMEOUT_MS, not a count of answers: a CPU another
 * reschedule IPI wakes reads twice, which a count would take for two CPUs.
 *
 * @param kernel The kernel, whose online CPUs are asked.
 * @param test The test's state, whose seen is cleared first.
 * @param value What every CPU should read.
 * @return True if every other online CPU read value in time; false, with an error logged for the first that didn't,
 *     otherwise.
 */
every_cpu_reads :: fn(kernel: ptr[Kernel], test: ptr[mut ShootdownTest], value: u64) -> bool {
    for index in 0..<SHOOTDOWN_TEST_CPUS {
        intrinsics.volatile_store_u64(&test.seen[index], 0)
    }
    intrinsics.atomic_store_u32_release(&test.answered, 0)
    cpus :: kernel.cpus
    for cpu, index in cpus {
        if index > 0 && index < cast[usize](kernel.online_cpus) {
            arch.send_ipi(cpu.hardware_id, .Reschedule)
        }
    }
    deadline :: arch.counter() + kernel.counter_frequency / 1000 * SHOOTDOWN_TEST_TIMEOUT_MS
    loop {
        arch.spin_hint()
    }
    while !all_read(kernel, test, value) && arch.counter() < deadline
    for index in 1..<cast[usize](kernel.online_cpus) {
        if index < SHOOTDOWN_TEST_CPUS {
            seen :: intrinsics.volatile_load_u64(&test.seen[index])
            if seen != value {
                runtime.log_error("test_shootdown: CPU % read %{x}, not %{x}", index, seen, value)
                return false
            }
        }
    }
    return true
}

/**
 * Tell whether every other online CPU has read a value from the test's page.
 *
 * @param kernel The kernel, whose online_cpus says which CPUs count.
 * @param test The test's state, whose seen slots the other CPUs write; only read here, each with a volatile load.
 * @param value The value each should have read.
 * @return True if each online CPU but the boot CPU, up to SHOOTDOWN_TEST_CPUS, has value in seen.
 */
all_read :: fn(kernel: ptr[Kernel], test: ptr[ShootdownTest], value: u64) -> bool {
    for index in 1..<cast[usize](kernel.online_cpus) {
        if index < SHOOTDOWN_TEST_CPUS && intrinsics.volatile_load_u64(&test.seen[index]) != value {
            return false
        }
    }
    return true
}

/**
 * Read test_shootdown's page into this CPU's place in seen, if the test is running; called at a Reschedule IPI.
 *
 * Does nothing if kernel.shootdown_test is 0. A CPU at an index of SHOOTDOWN_TEST_CPUS or above only counts its answer.
 */
read_for_shootdown_test :: fn() {
    cpu :: per_cpu()
    address :: intrinsics.atomic_load_u64_acquire(&cpu.kernel.shootdown_test)
    if address == 0 {
        return void
    }
    test :: cast[ptr[mut ShootdownTest]](address)
    index :: cast[usize](cpu.index)
    if index < SHOOTDOWN_TEST_CPUS {
        intrinsics.volatile_store_u64(&test.seen[index], intrinsics.volatile_load_u64(cast[ptr[u64]](test.address)))
    }
    intrinsics.interlocked_increment_u32_release(&test.answered)
}
