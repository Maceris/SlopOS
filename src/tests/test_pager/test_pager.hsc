/*
 * test_pager (roadmap 9b, decisions/0094): paged memory, whose pages a pager supplies. A thread of the program's own
 * is the pager: woken on its port's wake binding, it asks which pages are wanted and supplies each from memory of its
 * own, which holds a pattern per page. The program maps the paged memory read-only at two addresses, and:
 * - reads pages 0 and 2 through the first, each waiting for its page to be supplied, and finds each page's pattern;
 * - reads page 0 through the second, which was supplied already, so the pager supplies 2 pages in all;
 * - is refused mapping the memory to write, asking what's wanted through a handle that can't write it, and making
 *   paged memory on a key with no wake binding;
 * - pressure and eviction (decisions/0111): the paged memory is paid for by a budget of its own, which is charged a
 *   page for each page supplied; page 0 was touched, and isn't once that's been asked; with a threshold a page above
 *   what the budget has, touching page 1 raises SIGNAL_PRESSURE; page 0 given back is uncharged and can't be given back
 *   again, and read again is supplied again; and a page never supplied can't be given back.
 */
package test_pager

import intrinsics from "base"
import runtime from "base"
import os from "std"
import slop_os from "std/os"
import process_manager from "std/os/slop_os"
import log_line from "../../log_line"
import test_kit from "../../test_kit"

NAME :: "test_pager"
PAGE : u64 : 4096
PAGES : u64 : 4
PAGER_KEY : u64 : 1
STOP_KEY : u64 : 2
PRESSURE_KEY : u64 : 3
// How long it waits for pressure to be raised
PRESSURE_WAIT : u64 : 2_000_000_000

// What the program and its pager share: the paged memory, its source, the port, how many pages it supplied, and stop.
Shared :: struct {
    paged : slop_os.Memory,
    source : slop_os.Memory,
    port : slop_os.Port,
    supplied : u64,
    stop : u64,
}

// The pager: woken for each wanted page, which it supplies from the same page of its source, until it's told to stop.
pager #calling_convention(.c) #no_context :: fn(shared: ptr[mut Shared]) #never_returns {
    loop {
        packets : slop_os.Packet[4]
        _ = slop_os.port_wait(shared.port, packets, slop_os.NO_DEADLINE)
        loop {
            match slop_os.memory_page_wanted(shared.paged) {
                case Ok(offset) => {
                    if slop_os.memory_supply(shared.paged, offset, shared.source, offset) is_ok {
                        intrinsics.atomic_store_u64(&shared.supplied, intrinsics.atomic_load_u64(&shared.supplied) + 1)
                    }
                }
                case Error(error) => break
            }
        }
        if intrinsics.atomic_load_u64(&shared.stop) != 0 {
            slop_os.thread_exit()
        }
    }
}

main :: fn(log: slop_os.DebugLog, platform: slop_os.Platform?, test_device: slop_os.Memory?, firmware: slop_os.Memory?,
    manager: os.Channel[process_manager.ProcessManager]?, program: slop_os.Memory?, peer: slop_os.Channel?, cpu_budget: slop_os.CpuBudget?) -> int {
    block :: slop_os.startup_block()
    budget :: slop_os.memory_budget_create(block.budget, 1 << 20) or_return 100
    shared :: runtime.new(Shared)
    shared.port = slop_os.port_create(block.budget) or_return 101
    slop_os.port_bind_wake(shared.port, PAGER_KEY) or_return 102
    slop_os.port_bind_wake(shared.port, STOP_KEY) or_return 103
    // Its own budget pays for the paged memory, a page at a time
    paying :: slop_os.memory_budget_create(block.budget, 1 << 20) or_return 100
    shared.paged = slop_os.memory_create_paged(paying, shared.port, PAGER_KEY, PAGES * PAGE) or_return 104
    unsupplied :: (slop_os.memory_budget_info(paying) or_return 111).used
    // The pages it's supplied from: page i full of i + 1 times 0x11
    shared.source = slop_os.memory_create(block.budget, PAGES * PAGE) or_return 105
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    source_at :: runtime.reserve_addresses(cast[usize](PAGES * PAGE)) or_return 106
    slop_os.memory_map(shared.source, block.space, source_at, 0, PAGES * PAGE, read_write) or_return 106
    for i in cast[u64](0)..<PAGES * PAGE {
        intrinsics.volatile_store_u8(cast[ptr[mut u8]](source_at + i), cast[u8]((i / PAGE + 1) * 0x11))
    }
    first :: runtime.reserve_addresses(cast[usize](PAGES * PAGE)) or_return 107
    second :: runtime.reserve_addresses(cast[usize](PAGES * PAGE)) or_return 107
    slop_os.memory_map(shared.paged, block.space, first, 0, PAGES * PAGE, slop_os.PROTECTION_READ) or_return 108
    slop_os.memory_map(shared.paged, block.space, second, 0, PAGES * PAGE, slop_os.PROTECTION_READ) or_return 108
    thread :: test_kit.start_thread(budget, cast[u64](pager), cast[u64](shared)) or_return 109

    results : u64[16]
    results[0] = cast[u64](intrinsics.volatile_load_u8(cast[ptr[u8]](first)))
    results[1] = cast[u64](intrinsics.volatile_load_u8(cast[ptr[u8]](first + 2 * PAGE + 8)))
    results[2] = cast[u64](intrinsics.volatile_load_u8(cast[ptr[u8]](second + 100)))
    results[3] = intrinsics.atomic_load_u64(&shared.supplied)
    // Writing it is refused, as is asking what it's waited for without the right to write it, and a pager with no binding
    results[4] = test_kit.tag_of(slop_os.memory_map(shared.paged, block.space, runtime.reserve_addresses(cast[usize](PAGE)) or_else 0, 0, PAGE,
        read_write))
    read_rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_READ))
    reader :: cast[slop_os.Memory](slop_os.handle_duplicate(cast[slop_os.Handle](shared.paged), read_rights) or_return 110)
    results[5] = test_kit.tag_of(slop_os.memory_page_wanted(reader))
    results[6] = test_kit.tag_of(slop_os.memory_create_paged(block.budget, shared.port, 99, PAGE))
    results[7] = test_kit.tag_of(slop_os.memory_page_wanted(shared.source))
    // Two pages supplied, two pages charged
    results[8] = ((slop_os.memory_budget_info(paying) or_return 111).used - unsupplied) / PAGE
    // Page 0 was touched, and isn't once that's been asked
    results[9] = slop_os.memory_page_accessed(shared.paged, 0) or_else 99
    results[10] = slop_os.memory_page_accessed(shared.paged, 0) or_else 99
    // A threshold a page above what the budget has: touching page 1 reaches it, raising pressure on another port
    watch :: slop_os.port_create(block.budget) or_return 112
    slop_os.port_bind(watch, cast[slop_os.Handle](paying), slop_os.SIGNAL_PRESSURE, PRESSURE_KEY, .Once) or_return 113
    slop_os.memory_budget_set_threshold(paying, (slop_os.memory_budget_info(paying) or_return 111).used + PAGE) or_return 114
    results[11] = cast[u64](intrinsics.volatile_load_u8(cast[ptr[u8]](first + PAGE)))
    packets : slop_os.Packet[1]
    waited :: slop_os.port_wait(watch, packets, (slop_os.clock_monotonic() or_else 0) + PRESSURE_WAIT) or_else 0
    results[12] = if waited == 1 && packets[0].key == PRESSURE_KEY { cast[u64](1) } else { cast[u64](0) }
    // Page 0 given back: uncharged, not there to give back again, and read again, supplied again
    results[13] = test_kit.tag_of(slop_os.memory_evict(shared.paged, 0))
    results[14] = test_kit.tag_of(slop_os.memory_evict(shared.paged, 0)) * 100 + test_kit.tag_of(slop_os.memory_evict(shared.paged, 3 * PAGE))
    results[15] = ((slop_os.memory_budget_info(paying) or_return 111).used - unsupplied) / PAGE * 1000
        + cast[u64](intrinsics.volatile_load_u8(cast[ptr[u8]](second + 50)))
    intrinsics.atomic_store_u64(&shared.stop, 1)
    _ = slop_os.port_wake(shared.port, STOP_KEY, 1)
    _ = slop_os.handle_close(cast[slop_os.Handle](thread))
    not_supplied :: test_kit.tag(slop_os.MemoryError.NotSupplied)
    expected :: u64.[0x11, 0x33, 0x11, 2, test_kit.tag(slop_os.MemoryError.MissingRight), test_kit.tag(slop_os.MemoryError.MissingRight),
        test_kit.tag(slop_os.MemoryError.NoPager), test_kit.tag(slop_os.MemoryError.NotPaged), 2, 1, 0, 0x22, 1, 0,
        not_supplied * 100 + not_supplied, 2 * 1000 + 0x11]
    failed :: test_kit.check(log, NAME, results, expected)
    if failed == 0 {
        log_line.write(log, "%: 2 pages supplied as they were touched, read at two addresses, and writing them refused", NAME)
        log_line.write(log, "%: pages charged as they're supplied, touches reported, pressure raised at the threshold, and a page given back read again", NAME)
    }
    return failed
}
