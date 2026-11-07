/**
 * test_pager (roadmap 9b, decisions/0094): paged memory, whose pages a pager supplies. A thread of the program's own
 * is the pager: woken on its port's wake binding, it asks which pages are wanted and supplies each from memory of its
 * own, which holds a pattern per page. Each test maps paged memory of its own read-only at two addresses, with a pager
 * of its own, and:
 * - reads pages 0 and 2 through the first, each waiting for its page to be supplied, and finds each page's pattern;
 * - reads page 0 through the second, which was supplied already, so the pager supplies 2 pages in all;
 * - is refused mapping the memory to write, asking what's wanted through a handle that can't write it, and making
 *   paged memory on a key with no wake binding;
 * - pressure and eviction (decisions/0111): the paged memory is paid for by a budget of its own, which is charged a
 *   page for each page supplied; page 0 was touched, and isn't once that's been asked; with a threshold a page above
 *   what the budget has, touching page 1 raises SIGNAL_PRESSURE; page 0 given back is uncharged and can't be given
 *   back again, and read again is supplied again; and a page never supplied can't be given back;
 * - memory_read (decisions/0181's F6): bytes across two pages not supplied yet are read without a mapping, the call
 *   waiting for the pager to supply each; writing paged memory that way is refused; and once the pager's port is gone,
 *   a page not supplied reads as ObjectGone, not a fault.
 */
package test_pager

import compiler from "base"
import intrinsics from "base"
import runtime from "base"
import os from "std"
import testing from "std"
import slop_os from "std/os"
import process_manager from "std/os/slop_os"
import test_kit from "../../test_kit"

/** The test's name, which starts each line it logs. */
NAME :: "test_pager"
/** A page, in bytes. */
PAGE : u64 : 4096
/** How many pages the paged memory has. */
PAGES : u64 : 4
/** The key of the wake binding the paged memory wakes its pager with. */
PAGER_KEY : u64 : 1
/** The key of the wake binding the program wakes the pager with to stop it. */
STOP_KEY : u64 : 2
/** The key the paying budget's pressure binding queues under. */
PRESSURE_KEY : u64 : 3
/** How long the program waits for pressure to be raised, in nanoseconds: 2 s. */
PRESSURE_WAIT : u64 : 2_000_000_000

/** What main was given that the tests use. */
Given :: struct {
    /** The debug log. */
    log : slop_os.DebugLog,
}

/**
 * What the program and its pager share: the paged memory, its source, the port, how many pages it supplied, and stop.
 */
Shared :: struct {
    /** The paged memory, whose pages the pager supplies. */
    paged : slop_os.Memory,
    /** The memory the pages are supplied from, page i holding (i + 1) * 0x11 in every byte. */
    source : slop_os.Memory,
    /** The pager's port, with wake bindings for PAGER_KEY and STOP_KEY. */
    port : slop_os.Port,
    /** How many pages the pager has supplied, counted before each is, so the program never reads fewer. */
    supplied : u64,
    /** Set to 1 by the program to tell the pager to end, once it's woken. */
    stop : u64,
}

/** Paged memory a test has made, mapped twice, with a pager running for it, as set_up makes it. */
Paged :: struct {
    /** What the test and its pager share, on the heap, which outlives the pager and isn't freed. */
    shared : ptr[mut Shared],
    /** The budget that pays for the paged memory, a page at a time. */
    paying : slop_os.MemoryBudget,
    /** What paying had charged before any page was supplied, in bytes. */
    unsupplied : u64,
    /** Where the paged memory is first mapped, read-only, all PAGES pages. */
    first : u64,
    /** Where it's mapped a second time, read-only, all PAGES pages. */
    second : u64,
    /** The pager. */
    thread : slop_os.Thread,
}

/**
 * Supply each wanted page from the same page of the source, woken on the port, until told to stop.
 *
 * @param shared What the program and the pager share, which outlives the pager.
 */
pager #calling_convention(.c) #no_context :: fn(shared: ptr[mut Shared]) #never_returns {
    loop {
        packets : slop_os.Packet[4]
        _ = slop_os.port_wait(shared.port, packets, slop_os.NO_DEADLINE)
        loop {
            match slop_os.memory_page_wanted(shared.paged) {
                case Ok(offset) => {
                    // Counted first: the supply wakes the program, which may read the count before this thread goes on
                    counted :: intrinsics.atomic_load_u64(&shared.supplied)
                    intrinsics.atomic_store_u64(&shared.supplied, counted + 1)
                    if slop_os.memory_supply(shared.paged, offset, shared.source, offset) is_error {
                        intrinsics.atomic_store_u64(&shared.supplied, counted)
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

/**
 * Make paged memory of PAGES pages, paid for by a budget of its own, with a source holding each page's pattern, map
 * it read-only twice, and start a pager for it.
 *
 * @param t The test's state, which a step that failed is recorded in.
 * @return The paged memory, its pager running; Error(Failed), recorded, if any of it couldn't be made.
 */
set_up :: fn(t: ptr[mut testing.T]) -> Result[Paged, testing.Stopped] {
    block :: slop_os.startup_block()
    budget :: testing.require_ok(t, slop_os.memory_budget_create(block.budget, 1 << 20), "a budget for the pager")?
    shared :: runtime.new(Shared)
    shared.port = testing.require_ok(t, slop_os.port_create(block.budget), "a port for the pager")?
    testing.require_ok(t, slop_os.port_bind_wake(shared.port, PAGER_KEY), "the paged memory's wake binding is made")?
    testing.require_ok(t, slop_os.port_bind_wake(shared.port, STOP_KEY), "the stopping wake binding is made")?
    // Its own budget pays for the paged memory, a page at a time
    paying :: testing.require_ok(t, slop_os.memory_budget_create(block.budget, 1 << 20), "a budget to pay for the paged memory")?
    shared.paged = testing.require_ok(t, slop_os.memory_create_paged(paying, shared.port, PAGER_KEY, PAGES * PAGE), "paged memory on a key with a wake binding is made")?
    unsupplied :: testing.require_ok(t, slop_os.memory_budget_info(paying), "the paying budget can be read")?
    // The pages it's supplied from: page i full of i + 1 times 0x11
    shared.source = testing.require_ok(t, slop_os.memory_create(block.budget, PAGES * PAGE), "the memory pages are supplied from is made")?
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    source_at :: testing.require_some(t, runtime.reserve_addresses(cast[usize](PAGES * PAGE)), "addresses to map the source at")?
    testing.require_ok(t, slop_os.memory_map(shared.source, block.space, source_at, 0, PAGES * PAGE, read_write), "the source is mapped to write")?
    for i in cast[u64](0)..<PAGES * PAGE {
        intrinsics.volatile_store_u8(cast[ptr[mut u8]](source_at + i), cast[u8]((i / PAGE + 1) * 0x11))
    }
    first :: testing.require_some(t, runtime.reserve_addresses(cast[usize](PAGES * PAGE)), "addresses to map the paged memory at")?
    second :: testing.require_some(t, runtime.reserve_addresses(cast[usize](PAGES * PAGE)), "addresses to map the paged memory at again")?
    testing.require_ok(t, slop_os.memory_map(shared.paged, block.space, first, 0, PAGES * PAGE, slop_os.PROTECTION_READ), "paged memory maps read-only")?
    testing.require_ok(t, slop_os.memory_map(shared.paged, block.space, second, 0, PAGES * PAGE, slop_os.PROTECTION_READ), "paged memory maps read-only twice")?
    thread :: testing.require_ok(t, test_kit.start_thread(budget, cast[u64](pager), cast[u64](shared)), "the pager starts")?
    return .Ok(Paged.{shared = shared, paying = paying, unsupplied = unsupplied.used, first = first, second = second, thread = thread})
}

/**
 * Stop a pager set_up started, and close it.
 *
 * @param paged What set_up made; its pager ends, and its thread's handle is closed.
 */
stop_pager :: fn(paged: Paged) {
    intrinsics.atomic_store_u64(&paged.shared.stop, 1)
    _ = slop_os.port_wake(paged.shared.port, STOP_KEY, 1)
    _ = slop_os.handle_close(cast[slop_os.Handle](paged.thread))
}

/**
 * Check that pages of paged memory are supplied as they're touched, each with its page of the source, once each
 * whichever mapping touches them; and that writing it, asking what's wanted without the right to write it, paged memory
 * on a key with no wake binding, and asking what's wanted of memory that isn't paged are refused.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if the paged memory, its pager or the read-only handle couldn't be made.
 */
pages_are_supplied_as_they_are_touched #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    block :: slop_os.startup_block()
    paged :: set_up(t)?
    shared :: paged.shared
    testing.expect_eq(t, intrinsics.volatile_load_u8(cast[ptr[u8]](paged.first)), 0x11, "page 0, touched, is supplied from the source's page 0")
    testing.expect_eq(t, intrinsics.volatile_load_u8(cast[ptr[u8]](paged.first + 2 * PAGE + 8)), 0x33, "page 2, touched, is supplied from the source's page 2")
    testing.expect_eq(t, intrinsics.volatile_load_u8(cast[ptr[u8]](paged.second + 100)), 0x11, "page 0 through the second mapping is the page already supplied")
    testing.expect_eq(t, intrinsics.atomic_load_u64(&shared.supplied), 2, "a page is supplied once, whichever mapping touches it")
    // Writing it is refused, as is asking what it's waited for without the right to write it, and a pager with no binding
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    writable :: slop_os.memory_map(shared.paged, block.space, runtime.reserve_addresses(cast[usize](PAGE)) or_else 0, 0, PAGE, read_write)
    testing.expect_error(t, writable, slop_os.MemoryError.MissingRight, "paged memory can't be mapped to write, only its pager supplies it")
    read_rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_READ))
    reader :: testing.require_ok(t, slop_os.handle_duplicate(cast[slop_os.Handle](shared.paged), read_rights), "the paged memory's handle is copied with only the right to read")?
    wanted :: slop_os.memory_page_wanted(cast[slop_os.Memory](reader))
    testing.expect_error(t, wanted, slop_os.MemoryError.MissingRight, "only a handle that can write paged memory can ask what's wanted of it")
    no_binding :: slop_os.memory_create_paged(block.budget, shared.port, 99, PAGE)
    testing.expect_error(t, no_binding, slop_os.MemoryError.NoPager, "paged memory needs a wake binding for its key, to wake its pager")
    not_paged :: slop_os.memory_page_wanted(shared.source)
    testing.expect_error(t, not_paged, slop_os.MemoryError.NotPaged, "only paged memory has pages wanted")
    stop_pager(paged)
    return .Ok
}

/**
 * Check that paged memory's budget is charged a page for each page supplied; that a touched page is reported once,
 * then not until touched again; that touching a page at the budget's threshold raises pressure; and that a page given
 * back is uncharged, can't be given back again, and read again is supplied again, while a page never supplied can't
 * be given back.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if the paged memory, its pager, or the pressure watch or threshold couldn't be made,
 *     or the paying budget couldn't be read.
 */
pages_are_charged_and_given_back_under_pressure #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    block :: slop_os.startup_block()
    paged :: set_up(t)?
    shared :: paged.shared
    // Two pages touched, so supplied, and charged
    _ = intrinsics.volatile_load_u8(cast[ptr[u8]](paged.first))
    _ = intrinsics.volatile_load_u8(cast[ptr[u8]](paged.first + 2 * PAGE + 8))
    two :: testing.require_ok(t, slop_os.memory_budget_info(paged.paying), "the paying budget can be read")?
    testing.expect_eq(t, (two.used - paged.unsupplied) / PAGE, 2, "the paying budget is charged a page for each page supplied")
    // Page 0 was touched, and isn't once that's been asked
    testing.expect_eq(t, slop_os.memory_page_accessed(shared.paged, 0) or_else 99, 1, "a page read since it was supplied is reported touched")
    testing.expect_eq(t, slop_os.memory_page_accessed(shared.paged, 0) or_else 99, 0, "asking clears a page's touch, so it isn't reported again until touched again")
    // A threshold a page above what the budget has: touching page 1 reaches it, raising pressure on another port
    watch :: testing.require_ok(t, slop_os.port_create(block.budget), "a port to watch for pressure")?
    testing.require_ok(t, slop_os.port_bind(watch, cast[slop_os.Handle](paged.paying), slop_os.SIGNAL_PRESSURE, PRESSURE_KEY, .Once), "the paying budget's pressure is watched")?
    now :: testing.require_ok(t, slop_os.memory_budget_info(paged.paying), "the paying budget can be read")?
    testing.require_ok(t, slop_os.memory_budget_set_threshold(paged.paying, now.used + PAGE), "a threshold a page above what's charged is set")?
    testing.expect_eq(t, intrinsics.volatile_load_u8(cast[ptr[u8]](paged.first + PAGE)), 0x22, "page 1, touched, is supplied from the source's page 1")
    packets : slop_os.Packet[1]
    waited :: slop_os.port_wait(watch, packets, (slop_os.clock_monotonic() or_else 0) + PRESSURE_WAIT) or_else 0
    testing.expect(t, waited == 1 && packets[0].key == PRESSURE_KEY, "a page charged up to the budget's threshold raises SIGNAL_PRESSURE")
    // Page 0 given back: uncharged, not there to give back again, and read again, supplied again
    evicted :: slop_os.memory_evict(shared.paged, 0)
    testing.expect_ok(t, evicted, "a supplied page can be given back")
    evicted_again :: slop_os.memory_evict(shared.paged, 0)
    testing.expect_error(t, evicted_again, slop_os.MemoryError.NotSupplied, "a page given back isn't there to give back again")
    never :: slop_os.memory_evict(shared.paged, 3 * PAGE)
    testing.expect_error(t, never, slop_os.MemoryError.NotSupplied, "a page never supplied can't be given back")
    after :: testing.require_ok(t, slop_os.memory_budget_info(paged.paying), "the paying budget can be read")?
    testing.expect_eq(t, (after.used - paged.unsupplied) / PAGE, 2, "a page given back is uncharged: of pages 0, 1 and 2, only 1 and 2 are charged")
    testing.expect_eq(t, intrinsics.volatile_load_u8(cast[ptr[u8]](paged.second + 50)), 0x11, "page 0, read again once given back, is supplied again")
    _ = slop_os.handle_close(cast[slop_os.Handle](watch))
    stop_pager(paged)
    return .Ok
}

/**
 * Run the tests, reporting to the debug log.
 *
 * @param log The debug log, writable, where each test is reported.
 * @param platform Not used.
 * @param test_device Not used.
 * @param firmware Not used.
 * @param manager Not used.
 * @param program Not used.
 * @param peer Not used.
 * @param cpu_budget Not used.
 * @return How many tests failed: 0 when every one passed.
 */
main :: fn(log: slop_os.DebugLog, platform: slop_os.Platform?, test_device: slop_os.Memory?, firmware: slop_os.Memory?,
    manager: os.Channel[process_manager.ProcessManager]?, program: slop_os.Memory?, peer: slop_os.Channel?, cpu_budget: slop_os.CpuBudget?) -> int {
    given :: Given.{log = log}
    return test_kit.run(log, NAME, #insert testing.tests_of(compiler.load_package(".")), given)
}

/**
 * Check that paged memory is read through memory_read, with no mapping, the call waiting for its pager to supply each
 * page it reads; that it can't be written that way; and that a page not supplied, once its pager's port is gone, is
 * ObjectGone.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if the paged memory or its pager couldn't be made.
 */
paged_memory_is_read_without_a_mapping #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    paged :: set_up(t)?
    shared :: paged.shared
    // The last byte of page 1 and the first of page 2, neither supplied yet
    across : u8[2]
    read :: slop_os.memory_read(shared.paged, 2 * PAGE - 1, across)
    testing.expect_ok(t, read, "paged memory reads through memory_read, waiting for its pager")
    testing.expect_eq(t, across[0], 0x22, "the read's first byte is page 1's, supplied for it")
    testing.expect_eq(t, across[1], 0x33, "the read's second byte is page 2's, supplied for it")
    testing.expect_eq(t, intrinsics.atomic_load_u64(&shared.supplied), 2, "each page the read crossed was supplied once")
    written :: slop_os.memory_write(shared.paged, 0, across)
    testing.expect_error(t, written, slop_os.MemoryError.WrongKind, "paged memory isn't written through memory_write, only its pager supplies it")
    // Its pager gone, a page it never supplied reads as gone
    stop_pager(paged)
    _ = slop_os.handle_close(cast[slop_os.Handle](shared.port))
    last : u8[1]
    gone :: slop_os.memory_read(shared.paged, 3 * PAGE, last)
    testing.expect_error(t, gone, slop_os.MemoryError.ObjectGone, "a page its gone pager never supplied reads as ObjectGone, not a fault")
    return .Ok
}
