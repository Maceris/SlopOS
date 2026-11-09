/**
 * test_memory (decisions/0069, from the kernel's test of 0054): memory budgets and memory objects, used by
 * the program's first thread, A, and a writer, B, a copy of the test A launches:
 * - A splits a child budget off its test budget, which can't pay for memory bigger than its limit, nor make
 *   memory of a size that isn't whole pages;
 * - A makes memory with the child, and maps it read/write; mapping it over itself, past its end, or
 *   writable and executable is refused;
 * - A touches each page, which reads as zeros, then holds what A wrote; mapped again read-only elsewhere,
 *   the same frames show what A wrote;
 * - B maps the memory read-only and writes to it, and is stopped: its process ends, killed, and the memory still
 *   holds what A wrote (decisions/0181's F6: a thread's unresolved fault ends its process);
 * - A unmaps the second mapping (and can't again), then closes the child budget: the parent takes over
 *   what the child paid for and gets back the rest of its limit, and the memory is still there;
 * - once the memory is closed, the test budget is back to nothing.
 */
package test_memory

import compiler from "base"
import intrinsics from "base"
import runtime from "base"
import os from "std"
import testing from "std"
import slop_os from "std/os"
import process_manager from "std/os/slop_os"
import log_line from "../../log_line"
import test_kit from "../../test_kit"

/** The test's name, which starts each line it logs. */
NAME :: "test_memory"
/** A page, in bytes. */
PAGE : u64 : 4096
/** The size of the memory A makes with the child budget, in bytes: 8 pages. */
MEMORY_SIZE : u64 : 32768
/** How many pages that memory has. */
MEMORY_PAGES :: 8
/** The limit of the budget A splits off its own for the test, in bytes: 1 MiB. */
TEST_LIMIT : u64 : 1 << 20
/** The limit of the child budget A splits off that, in bytes: 64 KiB. */
CHILD_LIMIT : u64 : 65536
/** A large page, in bytes: 2 MiB (decisions/0129). */
LARGE : u64 : 2 * 1024 * 1024
/** The size of each object whose page tables are measured: two large pages. */
LARGE_MEMORY : u64 : 2 * LARGE
/** How long A waits for B's process to end, in nanoseconds: 2 seconds. */
WRITER_DEADLINE : u64 : 2_000_000_000
/** The key A's watch for B's end queues under. */
WRITER_WATCH_KEY : u64 : 31
/** What B writes where it may only read. */
WRITTEN : u64 : 7

/**
 * Run as B: take the memory A sends on the peer channel, map it read-only, and write to its second page, which stops
 * B and ends its process.
 *
 * @param peer B's end of its peer channel to A, on which the memory comes, with only RIGHT_MEMORY_READ.
 * @return Never, as the write ends B's process; 1 if no port could be made for peer, 2 if the memory didn't come, 3
 *     if no addresses were left to map it at, 4 if it couldn't be mapped, and 0 if the write went on, which A sees.
 */
run_writer :: fn(peer: slop_os.Channel) -> int {
    block :: slop_os.startup_block()
    port :: os.port_for(block.budget, peer) or_return 1
    nothing : u64 = 0
    handles : slop_os.Handle[1]
    _ = os.receive(peer, port, os.mut_bytes_of(&nothing), handles) or_return 2
    at :: runtime.reserve_addresses(cast[usize](MEMORY_SIZE)) or_return 3
    slop_os.memory_map(cast[slop_os.Memory](handles[0]), block.space, at, 0, MEMORY_SIZE, slop_os.PROTECTION_READ) or_return 4
    intrinsics.volatile_store_u64(cast[ptr[mut u64]](at + PAGE), WRITTEN)
    return 0
}

/** What B is given (main): its log, and its peer channel to A. */
WriterGrants :: struct {
    /** A copy of A's debug log, writable. */
    log : slop_os.DebugLog,
    /** Not given. */
    platform : slop_os.Platform?,
    /** Not given. */
    test_device : slop_os.Memory?,
    /** Not given. */
    firmware : slop_os.Memory?,
    /** Not given. */
    manager : os.Channel[process_manager.ProcessManager]?,
    /** Not given. */
    program : slop_os.Memory?,
    /** B's end of its peer channel to A, which makes main run as B. */
    peer : slop_os.Channel?,
    /** Not given. */
    cpu_budget : slop_os.CpuBudget?,
}

/** What main was given that the tests use. */
Given :: struct {
    /** The debug log, which what large pages cost is logged to if they don't save page tables, duplicated for B. */
    log : slop_os.DebugLog,
    /** The process manager, which launches B; none if main wasn't given it. */
    manager : os.Channel[process_manager.ProcessManager]?,
    /** The test's own module, which B is launched from; none if main wasn't given it. */
    program : slop_os.Memory?,
}

/**
 * Check that a budget split off another has the limit asked for, nothing charged, and can't pay for memory bigger than
 * its limit, nor make memory of a size that isn't whole pages; and that its parent is back to nothing once it's closed.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if the test budget or its child couldn't be made.
 */
a_child_budget_pays_only_within_its_limit #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    block :: slop_os.startup_block()
    budget :: testing.require_ok(t, slop_os.memory_budget_create(block.budget, TEST_LIMIT), "a test budget split off the process's")?
    given_info :: slop_os.memory_budget_info(budget)
    testing.expect_ok(t, given_info, "a budget can be read")
    testing.expect_eq(t, (given_info or_else slop_os.BudgetInfo.{}).limit, TEST_LIMIT, "a budget has the limit it was made with")
    child :: testing.require_ok(t, slop_os.memory_budget_create(budget, CHILD_LIMIT), "a child budget split off the test budget")?
    fresh :: slop_os.memory_budget_info(child) or_else slop_os.BudgetInfo.{}
    testing.expect_eq(t, fresh.limit, CHILD_LIMIT, "a child has the limit it was made with")
    testing.expect_eq(t, fresh.used, 0, "a new budget has nothing charged")
    too_big :: slop_os.memory_create(child, 2 * CHILD_LIMIT)
    testing.expect_error(t, too_big, slop_os.MemoryError.BudgetExceeded, "a budget can't pay for memory bigger than its limit")
    not_pages :: slop_os.memory_create(child, 1000)
    testing.expect_error(t, not_pages, slop_os.MemoryError.InvalidSize, "memory is made in whole pages")
    _ = slop_os.handle_close(cast[slop_os.Handle](child))
    testing.expect(t, test_kit.wait_for_budget(budget, 0, 1_000_000_000), "the test budget is back to nothing once its child is closed")
    return .Ok
}

/**
 * Check memory objects, A being this thread and B a writer: memory maps read/write, but not over itself, past its end,
 * or writable and executable; each page reads as zeros, then holds what A wrote; mapped again read-only, the same
 * frames show it; the second mapping
 * unmaps once; closing the child that paid for the memory gives the parent the memory to pay for and the rest of the
 * child's limit back, the memory still there; and once the memory is closed, the test budget is back to nothing.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if the addresses, the test budget, its child or the memory couldn't be made, or the
 *     memory mapped.
 */
memory_fills_as_touched_and_shares_its_frames #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    block :: slop_os.startup_block()
    space :: block.space
    at :: testing.require_some(t, runtime.reserve_addresses(cast[usize](MEMORY_SIZE)), "addresses to map the memory at")?
    again :: testing.require_some(t, runtime.reserve_addresses(cast[usize](MEMORY_SIZE)), "addresses to map it at again")?
    budget :: testing.require_ok(t, slop_os.memory_budget_create(block.budget, TEST_LIMIT), "a test budget split off the process's")?
    child :: testing.require_ok(t, slop_os.memory_budget_create(budget, CHILD_LIMIT), "a child budget split off the test budget")?
    read :: slop_os.PROTECTION_READ
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    write_execute :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_WRITE) | cast[u32](slop_os.PROTECTION_EXECUTE))
    memory :: testing.require_ok(t, slop_os.memory_create(child, MEMORY_SIZE), "memory within the child's limit is made")?
    // Mapped, then over itself, past its end, and writable and executable
    mapped :: slop_os.memory_map(memory, space, at, 0, MEMORY_SIZE, read_write)
    testing.require_ok(t, mapped, "memory maps read/write")?
    over :: slop_os.memory_map(memory, space, at + PAGE, 0, PAGE, read)
    testing.expect_error(t, over, slop_os.MemoryError.BadAddress, "a mapping can't go over another")
    past :: slop_os.memory_map(memory, space, again, PAGE, MEMORY_SIZE, read)
    testing.expect_error(t, past, slop_os.MemoryError.InvalidSize, "a mapping can't run past its memory's end")
    writable_executable :: slop_os.memory_map(memory, space, again, 0, PAGE, write_execute)
    testing.expect_error(t, writable_executable, slop_os.MemoryError.BadProtection, "memory is never mapped writable and executable at once")
    // Each page, untouched, reads as zeros, then holds what's written
    zeros := cast[u64](0)
    for i in 0..<MEMORY_PAGES {
        page :: at + cast[u64](i) * PAGE
        if intrinsics.volatile_load_u64(cast[ptr[u64]](page + 8)) == 0 {
            zeros += 1
        }
        intrinsics.volatile_store_u64(cast[ptr[mut u64]](page), 1000 + cast[u64](i))
    }
    testing.expect_eq(t, zeros, MEMORY_PAGES, "each page of new memory reads as zeros when first touched")
    // The second page again, read-only, shows the same frame
    shared_mapping :: slop_os.memory_map(memory, space, again, PAGE, PAGE, read)
    testing.expect_ok(t, shared_mapping, "memory maps again, read-only, elsewhere")
    if shared_mapping is_ok {
        testing.expect_eq(t, intrinsics.volatile_load_u64(cast[ptr[u64]](again)), 1001, "a second mapping shows the same frames, with what was written through the first")
    }
    unmapped :: slop_os.memory_unmap(space, again)
    testing.expect_ok(t, unmapped, "the second mapping unmaps")
    unmapped_again :: slop_os.memory_unmap(space, again)
    testing.expect_error(t, unmapped_again, slop_os.MemoryError.NotMapped, "an unmapped mapping is gone, so it can't be unmapped again")
    // Closing the child: the parent pays for the memory, and gets back the rest of the limit
    child_used :: test_kit.used(child)
    with_child :: test_kit.used(budget)
    closed_child :: slop_os.handle_close(cast[slop_os.Handle](child))
    after :: test_kit.used(budget)
    still_there :: intrinsics.volatile_load_u64(cast[ptr[u64]](at + 3 * PAGE))
    closed_memory :: slop_os.handle_close(cast[slop_os.Handle](memory))
    testing.expect(t, child_used >= MEMORY_SIZE && child_used <= CHILD_LIMIT, "the child paid for all of the memory, within its limit")
    testing.expect_ok(t, closed_child, "the child budget closes with memory it paid for still there")
    /*
     * Closing the child gave the parent back the limit less what the child paid for the memory, and the child's own
     * slot too if its grace period is over already
     */
    testing.expect_ge(t, with_child - after, CHILD_LIMIT - child_used, "closing a child gives its parent back the rest of its limit")
    testing.expect_ge(t, after, child_used, "closing a child leaves its parent paying for the memory the child paid for")
    testing.expect_eq(t, still_there, 1003, "memory outlives the budget that paid for it, with what was written")
    testing.expect_ok(t, closed_memory, "the memory closes")
    _ = test_kit.wait_for_budget(budget, 0, 1_000_000_000)
    testing.expect_eq(t, test_kit.used(budget), 0, "the test budget is back to nothing once the memory and B are gone")
    return .Ok
}

/** The key a memory object's SIGNAL_UNHELD is bound under, on the tests' ports. */
UNHELD_KEY : u64 : 7

/**
 * Wait for a memory object's watcher to hear SIGNAL_UNHELD, up to a second.
 *
 * @param port The port the memory is bound to under UNHELD_KEY.
 * @return True if the packet came; false if the second ran out first, or the wait failed.
 */
heard_unheld :: fn(port: slop_os.Port) -> bool {
    deadline :: (slop_os.clock_monotonic() or_else 0) + 1_000_000_000
    loop {
        packets : slop_os.Packet[4]
        taken :: slop_os.port_wait(port, packets, deadline) or_return false
        if taken == 0 {
            return false
        }
        for packet, i in packets {
            if i < cast[usize](taken) && packet.key == UNHELD_KEY && packet.kind == .Signal {
                return true
            }
        }
    }
}

/**
 * A memory object counts who holds it besides its owner (decisions/0178): a duplicate, a mapping and a window each
 * hold it until they go; a handle moved over a channel holds it on its way and in the taker's table; only the owning
 * handle asks, or watches; and its watcher hears SIGNAL_UNHELD once no one holds it.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if the memory, the port, the channel or the addresses couldn't be made.
 */
memory_counts_who_holds_it #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    block :: slop_os.startup_block()
    memory :: testing.require_ok(t, slop_os.memory_create(block.budget, PAGE), "memory is made")?
    defer slop_os.handle_close(cast[slop_os.Handle](memory))
    port :: testing.require_ok(t, slop_os.port_create(block.budget), "a port is made")?
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    testing.require_ok(t, slop_os.port_bind(port, cast[slop_os.Handle](memory), slop_os.SIGNAL_UNHELD, UNHELD_KEY, .Persistent),
        "its owner watches it")?
    testing.expect_eq(t, slop_os.memory_holders(memory) or_else 99, 0, "no one holds new memory but its owner")
    rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_READ) | cast[u32](slop_os.RIGHT_TRANSFER) | cast[u32](slop_os.RIGHT_DUPLICATE))
    copy :: cast[slop_os.Memory](testing.require_ok(t, slop_os.handle_duplicate(cast[slop_os.Handle](memory), rights), "it's duplicated")?)
    testing.expect_eq(t, slop_os.memory_holders(memory) or_else 99, 1, "a duplicate holds it")
    testing.expect_error(t, slop_os.memory_holders(copy), slop_os.MemoryError.MissingRight, "only the owning handle asks")
    testing.expect_error(t, slop_os.port_bind(port, cast[slop_os.Handle](copy), slop_os.SIGNAL_UNHELD, UNHELD_KEY + 1, .Persistent),
        slop_os.PortError.MissingRight, "only the owning handle watches")
    // A mapping, and a window
    at :: testing.require_some(t, runtime.reserve_addresses(cast[usize](PAGE)), "addresses to map it at")?
    testing.require_ok(t, slop_os.memory_map(memory, block.space, at, 0, PAGE, slop_os.PROTECTION_READ), "it's mapped")?
    testing.expect_eq(t, slop_os.memory_holders(memory) or_else 99, 2, "a mapping holds it")
    _ = slop_os.memory_unmap(block.space, at)
    testing.expect_eq(t, slop_os.memory_holders(memory) or_else 99, 1, "an unmapped mapping doesn't")
    window :: testing.require_ok(t, slop_os.memory_create_window(memory, block.budget, 0, PAGE), "a window onto it is made")?
    testing.expect_eq(t, slop_os.memory_holders(memory) or_else 99, 2, "a window holds it")
    _ = slop_os.handle_close(cast[slop_os.Handle](window))
    testing.expect_eq(t, slop_os.memory_holders(memory) or_else 99, 1, "a closed window doesn't")
    // The duplicate moved over a channel: held on its way, and once it's taken
    pair :: testing.require_ok(t, slop_os.channel_create(block.budget, 0, 0), "a channel is made")?
    defer slop_os.handle_close(cast[slop_os.Handle](pair.a))
    defer slop_os.handle_close(cast[slop_os.Handle](pair.b))
    sender_port :: testing.require_some(t, os.port_for(block.budget, pair.a), "a port for its sending end")?
    defer slop_os.handle_close(cast[slop_os.Handle](sender_port))
    moving :: slop_os.Handle.[cast[slop_os.Handle](copy)]
    byte : u8[1]
    testing.require(t, os.send(pair.a, sender_port, view_of(&byte[0], 1), moving[0..<1]) is_none, "the duplicate's sent")?
    testing.expect_eq(t, slop_os.memory_holders(memory) or_else 99, 1, "a handle on its way holds it")
    buffer : u8[8]
    taken : slop_os.Handle[1]
    testing.require_ok(t, os.try_receive(pair.b, buffer[0..<8], taken[0..<1]), "it's received")?
    testing.expect_eq(t, slop_os.memory_holders(memory) or_else 99, 1, "the taker's handle holds it")
    testing.expect(t, !heard_unheld_now(port), "nothing's heard while it's held")
    _ = slop_os.handle_close(taken[0])
    testing.expect_eq(t, slop_os.memory_holders(memory) or_else 99, 0, "no one holds it once the taker closes it")
    testing.expect(t, heard_unheld(port), "its owner hears it")
    return .Ok
}

/**
 * Tell whether a memory object's watcher has heard SIGNAL_UNHELD already, without waiting.
 *
 * @param port The port the memory is bound to under UNHELD_KEY; a packet taken is gone.
 * @return True if the packet's there.
 */
heard_unheld_now :: fn(port: slop_os.Port) -> bool {
    packets : slop_os.Packet[4]
    taken :: slop_os.port_wait(port, packets, 0) or_else 0
    for packet, i in packets {
        if i < cast[usize](taken) && packet.key == UNHELD_KEY && packet.kind == .Signal {
            return true
        }
    }
    return false
}

/**
 * A handle given to a process holds memory until the process is gone (decisions/0178): its table's let go of with it.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if the memory, the port or the process couldn't be made, or the handle given.
 */
memory_held_by_a_process_is_let_go_with_it #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    block :: slop_os.startup_block()
    memory :: testing.require_ok(t, slop_os.memory_create(block.budget, PAGE), "memory is made")?
    defer slop_os.handle_close(cast[slop_os.Handle](memory))
    port :: testing.require_ok(t, slop_os.port_create(block.budget), "a port is made")?
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    testing.require_ok(t, slop_os.port_bind(port, cast[slop_os.Handle](memory), slop_os.SIGNAL_UNHELD, UNHELD_KEY, .Persistent),
        "its owner watches it")?
    rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_READ) | cast[u32](slop_os.RIGHT_TRANSFER))
    copy :: testing.require_ok(t, slop_os.handle_duplicate(cast[slop_os.Handle](memory), rights), "it's duplicated")?
    budget :: testing.require_ok(t, slop_os.memory_budget_create(block.budget, 1 << 20), "a budget for the process")?
    defer slop_os.handle_close(cast[slop_os.Handle](budget))
    process :: testing.require_ok(t, slop_os.process_create(budget), "a process is made")?
    moving :: slop_os.Handle.[copy]
    given : slop_os.Handle[1]
    testing.require_ok(t, slop_os.process_give_handles(process, moving[0..<1], given[0..<1]), "the duplicate's given to it")?
    testing.expect_eq(t, slop_os.memory_holders(memory) or_else 99, 1, "the process's handle holds it")
    _ = slop_os.handle_close(cast[slop_os.Handle](process))
    testing.expect(t, heard_unheld(port), "its owner hears no one holds it, once the process is gone")
    testing.expect_eq(t, slop_os.memory_holders(memory) or_else 99, 0, "and no one does")
    return .Ok
}

/**
 * Check that 4 MiB mapped on a 2 MiB boundary is mapped with large pages, so touching it takes at least two pages less
 * in page tables than mapped a page off one. What each took is logged if it didn't.
 *
 * What touching takes is read from the budget, which memory let go of earlier, as by the process the test before ends,
 * can lower while it's read, after its grace period: a cost can read low, never high. So it's measured up to
 * TABLE_ATTEMPTS times, and fails only if large pages never save anything.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if the memory couldn't be made or mapped.
 */
memory_on_a_large_page_boundary_maps_with_large_pages #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    given :: test_kit.given(t, Given)?
    block :: slop_os.startup_block()
    // 4 MiB mapped 2 MiB-aligned takes two large pages, so none of the tables of 4 KiB pages it takes mapped a page off
    costs := TableCosts.{}
    for attempt in 0..<TABLE_ATTEMPTS {
        costs = testing.require_some(t, page_tables_touching(block), "two objects of 4 MiB are made and mapped")?
        if costs.aligned + 2 * PAGE <= costs.unaligned {
            break
        }
    }
    saved :: testing.expect_le(t, costs.aligned + 2 * PAGE, costs.unaligned, "4 MiB mapped 2 MiB-aligned takes large pages, not the tables of 4 KiB pages it takes mapped a page off")
    if !saved {
        log_line.write(given.log, "%: 4 MiB took % bytes of page tables mapped 2 MiB-aligned, and % mapped a page off", NAME, costs.aligned,
            costs.unaligned)
    }
    return .Ok
}

/** How many times memory_on_a_large_page_boundary_maps_with_large_pages measures, at most. */
TABLE_ATTEMPTS :: 3

/**
 * Check that a write where only reading is mapped stops the thread making it and ends its process, killed, the memory
 * as it was: B, a copy of the test launched with memory A wrote, maps it read-only and writes to it (decisions/0181's
 * F6). Last, so what B's process gives back as it's destroyed isn't measured by another test.
 *
 * @param t The test's state.
 * @return Ok once B has ended, or the deadline passed; Error if the memory couldn't be made or mapped, or B launched,
 *     sent the memory or watched.
 */
a_write_where_only_reading_is_mapped_ends_the_process #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    given :: test_kit.given(t, Given)?
    block :: slop_os.startup_block()
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    memory :: testing.require_ok(t, slop_os.memory_create(block.budget, MEMORY_SIZE), "memory for B to write to")?
    defer slop_os.handle_close(cast[slop_os.Handle](memory))
    at :: testing.require_some(t, runtime.reserve_addresses(cast[usize](MEMORY_SIZE)), "addresses to map the memory at")?
    testing.require_ok(t, slop_os.memory_map(memory, block.space, at, 0, MEMORY_SIZE, read_write), "the memory maps read/write")?
    defer slop_os.memory_unmap(block.space, at)
    intrinsics.volatile_store_u64(cast[ptr[mut u64]](at + PAGE), 1001)
    manager :: testing.require_some(t, given.manager, "the root task grants the process manager")?
    program :: testing.require_some(t, given.program, "the root task grants the program's own module")?
    manager_port :: testing.require_some(t, os.port_for(block.budget, manager.end), "a port for the process manager's replies")?
    pair :: testing.require_ok(t, slop_os.channel_create(block.budget, 0, 0), "a peer channel for B")?
    log_rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_DEBUG_LOG_WRITE) | cast[u32](slop_os.RIGHT_DUPLICATE) | cast[u32](slop_os.RIGHT_TRANSFER))
    log_copy :: testing.require_ok(t, slop_os.handle_duplicate(cast[slop_os.Handle](given.log), log_rights), "the log duplicated for B")?
    launched :: testing.require_ok(t, os.launch(manager, manager_port, "test_memory B", program, 4 << 20, main,
        WriterGrants.{log = cast[slop_os.DebugLog](log_copy), peer = pair.b}), "B is launched")?
    // Watched before it's sent the memory, so its end can't come first
    exit_port :: testing.require_ok(t, slop_os.port_create(block.budget), "a port for B's end")?
    defer slop_os.handle_close(cast[slop_os.Handle](exit_port))
    watched :: slop_os.port_bind(exit_port, cast[slop_os.Handle](launched.process), slop_os.SIGNAL_TERMINATED, WRITER_WATCH_KEY, .Once)
    testing.require_ok(t, watched, "A watches for B's end")?
    read_only :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_READ) | cast[u32](slop_os.RIGHT_TRANSFER))
    readable :: testing.require_ok(t, slop_os.handle_duplicate(cast[slop_os.Handle](memory), read_only), "the memory duplicated for B, read-only")?
    peer_port :: testing.require_some(t, os.port_for(block.budget, pair.a), "a port for A's end of the peer channel")?
    nothing : u64 = 0
    sent :: os.send(pair.a, peer_port, os.bytes_of(&nothing), slop_os.Handle.[readable])
    testing.require(t, sent == null, "B is sent the memory")?
    packets : slop_os.Packet[1]
    deadline :: (slop_os.clock_monotonic() or_else 0) + WRITER_DEADLINE
    ended :: slop_os.port_wait(exit_port, packets, deadline) or_else 0
    testing.expect(t, ended == 1 && packets[0].key == WRITER_WATCH_KEY, "B's process ends")
    testing.expect_eq(t, packets[0].data[1], slop_os.EXIT_KILLED, "a write to a read-only mapping stops the thread making it, and its process ends, killed")
    // What B's process held given back before the tests after this measure what theirs takes
    _ = test_kit.wait_for_budget(launched.budget, 0, WRITER_DEADLINE)
    testing.expect_eq(t, test_kit.used(launched.budget), 0, "B's budget is back to nothing once its process has ended")
    _ = slop_os.handle_close(cast[slop_os.Handle](pair.a))
    _ = slop_os.handle_close(cast[slop_os.Handle](launched.process))
    _ = slop_os.handle_close(cast[slop_os.Handle](launched.budget))
    testing.expect_eq(t, intrinsics.volatile_load_u64(cast[ptr[u64]](at + PAGE)), 1001, "a write to a read-only mapping doesn't reach the memory")
    return .Ok
}

/**
 * Run the tests, reporting to the debug log.
 *
 * @param log The debug log, writable, where each test is reported.
 * @param platform Not used.
 * @param test_device Not used.
 * @param firmware Not used.
 * @param manager The process manager, which launches B; without it the read-only write test fails.
 * @param program The test's own module, which B is launched from; without it that test fails.
 * @param peer Given only to B, by A: the channel the memory comes on. With it, this runs as B.
 * @param cpu_budget Not used.
 * @return How many tests failed, 0 when every one passed; as B, what run_writer gives.
 */
main :: fn(log: slop_os.DebugLog, platform: slop_os.Platform?, test_device: slop_os.Memory?, firmware: slop_os.Memory?,
    manager: os.Channel[process_manager.ProcessManager]?, program: slop_os.Memory?, peer: slop_os.Channel?, cpu_budget: slop_os.CpuBudget?) -> int {
    match peer {
        case Some(end) => return run_writer(end)
        case None => {}
    }
    given :: Given.{log = log, manager = manager, program = program}
    return test_kit.run(log, NAME, #insert testing.tests_of(compiler.load_package(".")), given)
}

/** What touching 4 MiB cost in page tables, mapped on a 2 MiB boundary and a page past one. */
TableCosts :: struct {
    /** The bytes the process's budget was charged touching the object mapped on a 2 MiB boundary. */
    aligned : u64,
    /** The bytes charged touching the object mapped a page past one. */
    unaligned : u64,
}

/**
 * Measure what the page tables cost the process's budget as two objects of 4 MiB are touched, a page at a time: one
 * mapped on a 2 MiB boundary, the other a page past one.
 *
 * Both are made and mapped first, and closed after, so nothing else is charged or given back meanwhile.
 *
 * @param block The process's startup block, whose budget pays and whose address space they're mapped in.
 * @return What each cost, 0 for one whose touching charged nothing; or null if they can't be made or mapped, in
 *     which case what was made is left behind.
 */
page_tables_touching :: fn(block: ptr[slop_os.StartupBlock]) -> TableCosts? {
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    places : u64[2]
    memories : slop_os.Memory[2]
    for i in 0..<2 {
        reserved :: runtime.reserve_addresses(cast[usize](LARGE_MEMORY + 2 * LARGE)) or_return null
        boundary :: (reserved + LARGE - 1) & ~(LARGE - 1)
        places[i] = if i == 0 { boundary } else { boundary + PAGE }
        memories[i] = slop_os.memory_create(block.budget, LARGE_MEMORY) or_return null
        if slop_os.memory_map(memories[i], block.space, places[i], 0, LARGE_MEMORY, read_write) is_error {
            return null
        }
    }
    costs : u64[2]
    for at, i in places {
        before :: test_kit.used(block.budget)
        for page in cast[u64](0)..<LARGE_MEMORY / PAGE {
            intrinsics.volatile_store_u64(cast[ptr[mut u64]](at + page * PAGE), page)
        }
        after :: test_kit.used(block.budget)
        costs[i] = if after > before { after - before } else { 0 }
    }
    for i in 0..<2 {
        _ = slop_os.memory_unmap(block.space, places[i])
        _ = slop_os.handle_close(cast[slop_os.Handle](memories[i]))
    }
    return TableCosts.{aligned = costs[0], unaligned = costs[1]}
}
