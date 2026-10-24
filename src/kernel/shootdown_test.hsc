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
SHOOTDOWN_TEST_CPUS :: 64
OLD_PAGE_VALUE : u64 : 0x1111111111111111
NEW_PAGE_VALUE : u64 : 0x2222222222222222
SHOOTDOWN_TEST_TIMEOUT_MS :: 1000

TEST_PAGE_MAPPING :: arch_interface.Mapping.{protection = .ReadWrite, cache = .WriteBack, user = false, global = true}

ShootdownTest :: struct {
    // The page in the kernel window.
    address : u64,
    // What each CPU read, by index, and how many have.
    seen : u64[SHOOTDOWN_TEST_CPUS],
    answered : u32,
}

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
    concurrency.lock(&kernel.page_table_lock)
    _ = arch.unmap(&kernel.page_table, cast[arch_interface.VirtualAddress](test.address), .Size4K, &freed, &flush)
    concurrency.unlock(&kernel.page_table_lock)
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

// Ask every other online CPU to read the page, and check they all read value.
every_cpu_reads :: fn(kernel: ptr[Kernel], test: ptr[mut ShootdownTest], value: u64) -> bool {
    intrinsics.atomic_store_u32_release(&test.answered, 0)
    cpus :: kernel.cpus
    others :: kernel.online_cpus - 1
    for cpu, index in cpus {
        if index > 0 && index < cast[usize](kernel.online_cpus) {
            arch.send_ipi(cpu.hardware_id, .Reschedule)
        }
    }
    deadline :: arch.counter() + kernel.counter_frequency / 1000 * SHOOTDOWN_TEST_TIMEOUT_MS
    loop {
        arch.spin_hint()
    }
    while intrinsics.atomic_load_u32_acquire(&test.answered) < others && arch.counter() < deadline
    if intrinsics.atomic_load_u32_acquire(&test.answered) < others {
        runtime.log_error("test_shootdown: only % of % CPUs read the page", test.answered, others)
        return false
    }
    for index in 1..<cast[usize](kernel.online_cpus) {
        if index < SHOOTDOWN_TEST_CPUS && test.seen[index] != value {
            runtime.log_error("test_shootdown: CPU % read %{x}, not %{x}", index, test.seen[index], value)
            return false
        }
    }
    return true
}

// On a reschedule IPI: read test_shootdown's page, if it's running.
read_for_shootdown_test :: fn() {
    cpu :: per_cpu()
    address :: intrinsics.atomic_load_u64_acquire(&cpu.kernel.shootdown_test)
    if address == 0 {
        return void
    }
    test :: cast[ptr[mut ShootdownTest]](address)
    index :: cast[usize](cpu.index)
    if index < SHOOTDOWN_TEST_CPUS {
        test.seen[index] = intrinsics.volatile_load_u64(cast[ptr[u64]](test.address))
    }
    intrinsics.interlocked_increment_u32_release(&test.answered)
}
