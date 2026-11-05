package kernel

import intrinsics from "base"
import arch_interface from "../arch_interface"
import concurrency from "std"
import frames from "frames"
import testing from "std"
import text_buffer from "std"

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
 * Run test_shootdown on the boot CPU at boot, reporting it to the kernel's log.
 *
 * @param kernel Not used: the test finds the kernel through per_cpu.
 */
test_shootdown :: fn(kernel: ptr[mut Kernel]) {
    _ = run_tests("test_shootdown", testing.Test.[.{name = "every_cpu_reads_the_new_page_after_a_shootdown",
        run = every_cpu_reads_the_new_page_after_a_shootdown}])
}

/**
 * Check TLB shootdown: every other CPU reads a page in the kernel window, the page is pointed at another frame with a
 * shootdown, and every CPU then has to read the new frame.
 *
 * Runs on the boot CPU, with 2 to SHOOTDOWN_TEST_CPUS CPUs online. On a failure, what it allocated and mapped is left
 * as it is, and once the page is mapped, kernel.shootdown_test stays set; only a pass gives the frames and mapping
 * back. Its ShootdownTest is never freed.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if the CPUs online are too few or too many, there was no memory or window for the
 *     page, or a CPU didn't read the old frame before the shootdown.
 */
every_cpu_reads_the_new_page_after_a_shootdown #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    kernel :: per_cpu().kernel
    require_within(t, cast[i64](kernel.online_cpus), 2, SHOOTDOWN_TEST_CPUS,
        "the test is booted with other CPUs to read the page, and no more than ShootdownTest.seen keeps")?
    made :: allocate_object[ShootdownTest](&kernel.frames)
    test :: testing.require_ok(t, made, "a boot's free frames hold the test's state")?
    old_frame :: frames.allocate(&kernel.frames, 0)
    old :: testing.require_ok(t, old_frame, "a boot's free frames hold the page's first frame")?
    new_frame :: frames.allocate(&kernel.frames, 0)
    new :: testing.require_ok(t, new_frame, "a boot's free frames hold the page's second frame")?
    cast[ptr[mut u64]](frames.virtual_of(&kernel.frames, old))^ = OLD_PAGE_VALUE
    cast[ptr[mut u64]](frames.virtual_of(&kernel.frames, new))^ = NEW_PAGE_VALUE
    mapped :: map_in_window(kernel, cast[u64](old), frames.FRAME_SIZE, TEST_PAGE_MAPPING)
    test.address = testing.require_ok(t, mapped, "the kernel window has room for a page at boot")?
    intrinsics.atomic_store_u64_release(&kernel.shootdown_test, cast[u64](test))
    every_cpu_reads(t, kernel, test, OLD_PAGE_VALUE)?

    // The same address, another frame
    flush : arch_interface.TlbBatch
    freed : arch_interface.FreedTables
    lock_at(&kernel.page_table_lock, .PageTable)
    unmapped :: arch.unmap(&kernel.page_table, cast[arch_interface.VirtualAddress](test.address), .Size4K, &freed, &flush)
    unlock_at(&kernel.page_table_lock, .PageTable)
    testing.require_ok(t, unmapped, "the page the test mapped is there to unmap")?
    shootdown(kernel, &flush)
    free_tables(kernel, &freed)
    mapper : Mapper
    map_page(kernel, test.address, cast[u64](new), .Size4K, TEST_PAGE_MAPPING, &mapper)
    give_back_tables(kernel, &mapper.tables)
    every_cpu_reads(t, kernel, test, NEW_PAGE_VALUE)?

    intrinsics.atomic_store_u64_release(&kernel.shootdown_test, 0)
    unmap_from_window(kernel, test.address, frames.FRAME_SIZE)
    frames.free(&kernel.frames, old, 0)
    frames.free(&kernel.frames, new, 0)
    return .Ok
}

/**
 * Ask every other online CPU to read the test's page, with a Reschedule IPI each, and check they all read a value.
 *
 * Each CPU's own reading is waited for, up to SHOOTDOWN_TEST_TIMEOUT_MS, not a count of answers: a CPU another
 * reschedule IPI wakes reads twice, which a count would take for two CPUs.
 *
 * @param t The test's state, which a failure is recorded in for each CPU that didn't read value, naming it.
 * @param kernel The kernel, whose online CPUs are asked.
 * @param test The test's state, whose seen is cleared first.
 * @param value What every CPU should read.
 * @param location Where the test asked, which a failure is recorded at: the caller's own.
 * @return Ok if every other online CPU read value in time; Error, each that didn't recorded, otherwise.
 */
every_cpu_reads :: fn(t: ptr[mut testing.T], kernel: ptr[Kernel], test: ptr[mut ShootdownTest], value: u64, location := #caller_location) -> testing.Outcome {
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
    all := true
    for index in 1..<cast[usize](kernel.online_cpus) {
        if index < SHOOTDOWN_TEST_CPUS {
            seen :: intrinsics.volatile_load_u64(&test.seen[index])
            storage : u8[testing.TEXT_BYTES]
            message := text_buffer.make(storage)
            text_buffer.append_format(&message, "CPU % reads the page's current frame when asked, its TLB entry for the old one shot down", index)
            said :: text_buffer.as_string(&message)
            all = testing.expect_eq(t, seen, value, said, location) && all
        }
    }
    return testing.outcome_of(all)
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
