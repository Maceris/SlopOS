package kernel

import intrinsics from "base"
import runtime from "base"
import arch_interface from "../arch_interface"
import slop_os from "std/os"
import frames from "frames"

/*
 * test_memory: two threads in user mode, A and B, use memory budgets and memory objects, keeping what
 * each call gave in their page:
 * - A splits a child budget off the one it's given, which can't pay for memory bigger than its limit,
 *   nor make memory of a size that isn't whole pages;
 * - A makes memory with the child, and maps it read/write; mapping it over itself, past its end, or
 *   writable and executable is refused;
 * - A touches each page, which reads as zeros, then holds what A wrote; mapped again read-only
 *   elsewhere, the same frames show what A wrote;
 * - B writes to the read-only mapping, and is stopped: its handle in A's table reaches nothing;
 * - A unmaps the second mapping (and can't again), then closes the child budget: the parent takes over
 *   what the child paid for and gets back the rest of its limit, and the memory is still there.
 * Then the kernel destroys the process: every memory object, mapping and budget it had goes, and the
 * root budget is back to what it had before.
 */

MEMORY_TEST_TICKS : u64 : 60
MEMORY_TEST_DESTROY_TICK : u64 : 50
MEMORY_SLOT_SPACE :: 0
MEMORY_SLOT_ENTRY :: 1
MEMORY_SLOT_STACK :: 2
MEMORY_SLOT_B_STARTED :: 3
MEMORY_SLOT_B_AFTER :: 4
MEMORY_SLOT_DONE :: 5
MEMORY_RESULTS :: 8
// Where A maps the memory, and maps its second page again.
MEMORY_AT : u64 : 0x1000000
MEMORY_AGAIN : u64 : 0x2000000
MEMORY_SIZE : u64 : 32768
MEMORY_PAGES :: 8
CHILD_LIMIT : u64 : 65536
// How long A gives B to be stopped.
STOP_NANOSECONDS : u64 : 20_000_000

MemoryTest :: struct {
    process : u64,
    page : u64,
    // What the root budget had charged before the test's budget was split from it.
    root_used : u64,
}

user_memory #calling_convention(.c) #no_context :: fn(page: ptr[mut u64[64]]) #never_returns {
    base :: cast[u64](page)
    space :: page^[MEMORY_SLOT_SPACE]
    budget :: page^[TEST_SLOT_BUDGET]
    read :: cast[u64](cast[u32](slop_os.PROTECTION_READ))
    read_write :: cast[u64](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    write_execute :: cast[u64](cast[u32](slop_os.PROTECTION_WRITE) | cast[u32](slop_os.PROTECTION_EXECUTE))
    given :: call(.MemoryBudgetInfo, budget)
    page^[8] = given.rax
    page^[9] = given.rdx
    // A child budget, too small for some memory, and memory of no whole number of pages
    child :: call(.MemoryBudgetCreate, budget, CHILD_LIMIT)
    page^[10] = child.rax
    fresh :: call(.MemoryBudgetInfo, child.rdx)
    page^[11] = fresh.rdx
    page^[12] = fresh.r8
    page^[13] = call(.MemoryCreate, child.rdx, 2 * CHILD_LIMIT).rax
    page^[14] = call(.MemoryCreate, child.rdx, 1000).rax
    memory :: call(.MemoryCreate, child.rdx, MEMORY_SIZE)
    page^[15] = memory.rax
    // Mapped, then over itself, past its end, and writable and executable
    page^[16] = call(.MemoryMap, memory.rdx, space, MEMORY_AT, 0, MEMORY_SIZE, read_write).rax
    page^[17] = call(.MemoryMap, memory.rdx, space, MEMORY_AT + frames.FRAME_SIZE, 0, frames.FRAME_SIZE, read).rax
    page^[18] = call(.MemoryMap, memory.rdx, space, MEMORY_AGAIN, frames.FRAME_SIZE, MEMORY_SIZE, read).rax
    page^[19] = call(.MemoryMap, memory.rdx, space, MEMORY_AGAIN, 0, frames.FRAME_SIZE, write_execute).rax
    // Each page, untouched, reads as zeros, then holds what's written
    zeros := cast[u64](0)
    for i in 0..<MEMORY_PAGES {
        at :: MEMORY_AT + cast[u64](i) * frames.FRAME_SIZE
        if intrinsics.volatile_load_u64(cast[ptr[u64]](at + 8)) == 0 {
            zeros += 1
        }
        intrinsics.volatile_store_u64(cast[ptr[mut u64]](at), 1000 + cast[u64](i))
    }
    page^[20] = zeros
    // The second page again, read-only, shows the same frame
    page^[21] = call(.MemoryMap, memory.rdx, space, MEMORY_AGAIN, frames.FRAME_SIZE, frames.FRAME_SIZE, read).rax
    page^[22] = intrinsics.volatile_load_u64(cast[ptr[u64]](MEMORY_AGAIN))
    // B writes to it, and is stopped
    writer :: call(.ThreadCreate, budget, space, page^[MEMORY_SLOT_ENTRY], page^[MEMORY_SLOT_STACK], base)
    page^[23] = writer.rax
    loop {
        intrinsics.spin_hint()
    }
    while intrinsics.volatile_load_u64(&page^[MEMORY_SLOT_B_STARTED]) == 0
    started :: call(.ClockMonotonic).rdx
    loop {
        intrinsics.spin_hint()
    }
    while call(.ClockMonotonic).rdx - started < STOP_NANOSECONDS
    page^[24] = intrinsics.volatile_load_u64(&page^[MEMORY_SLOT_B_AFTER])
    page^[25] = call(.HandleInfo, writer.rdx).rax
    page^[26] = call(.MemoryUnmap, space, MEMORY_AGAIN).rax
    page^[27] = call(.MemoryUnmap, space, MEMORY_AGAIN).rax
    // Closing the child: the parent pays for the memory, and gets back the rest of the limit
    page^[28] = call(.MemoryBudgetInfo, child.rdx).r8
    page^[29] = call(.MemoryBudgetInfo, budget).r8
    page^[30] = call(.HandleClose, child.rdx).rax
    page^[31] = call(.MemoryBudgetInfo, budget).r8
    page^[32] = intrinsics.volatile_load_u64(cast[ptr[u64]](MEMORY_AT + 3 * frames.FRAME_SIZE))
    page^[33] = call(.HandleClose, memory.rdx).rax
    intrinsics.volatile_store_u64(&page^[MEMORY_SLOT_DONE], 1)
    _ = call(.ThreadExit)
    loop {
        intrinsics.spin_hint()
    }
}

user_memory_writer #calling_convention(.c) #no_context :: fn(page: ptr[mut u64[64]]) #never_returns {
    intrinsics.volatile_store_u64(&page^[MEMORY_SLOT_B_STARTED], 1)
    intrinsics.volatile_store_u64(cast[ptr[mut u64]](MEMORY_AGAIN), 7)
    intrinsics.volatile_store_u64(&page^[MEMORY_SLOT_B_AFTER], 1)
    _ = call(.ThreadExit)
    loop {
        intrinsics.spin_hint()
    }
}

test_memory :: fn(kernel: ptr[mut Kernel]) {
    test :: allocate_object[MemoryTest](&kernel.frames) or_else out_of_memory(&kernel.options, "test_memory: no memory")
    process := cast[ptr[mut Process]](0)
    match create_process(kernel, 0, 0) {
        case Ok(made) => process = made
        case Error(error) => {
            runtime.log_error("test_memory: no process: %", error)
            return void
        }
    }
    test.process = cast[u64](process)
    space := cast[ptr[mut AddressSpace]](0)
    match create_address_space(kernel, cast[u64](process), 0) {
        case Ok(made) => space = made
        case Error(error) => {
            runtime.log_error("test_memory: no address space: %", error)
            return void
        }
    }
    // Both functions, call, and the code between them
    first :: min_u64(min_u64(cast[u64](user_memory), cast[u64](user_memory_writer)), cast[u64](call)) & ~(frames.FRAME_SIZE - 1)
    last :: frames.round_up(max_u64(max_u64(cast[u64](user_memory), cast[u64](user_memory_writer)), cast[u64](call)) + 4 * frames.FRAME_SIZE,
        frames.FRAME_SIZE)
    if !mapped_for_test(kernel, space, TEST_CODE, kernel.image_physical + (first - kernel.image_base), last - first, USER_CODE) {
        return void
    }
    page :: frames.allocate_zeroed(&kernel.frames, 0) or_else out_of_memory(&kernel.options, "test_memory: no memory")
    stacks :: frames.allocate_zeroed(&kernel.frames, 1) or_else out_of_memory(&kernel.options, "test_memory: no memory")
    if !mapped_for_test(kernel, space, TEST_COUNTERS, cast[u64](page), frames.FRAME_SIZE, USER_DATA)
        || !mapped_for_test(kernel, space, TEST_STACKS, cast[u64](stacks), 2 * frames.FRAME_SIZE, USER_DATA) {
        return void
    }
    test.page = frames.virtual_of(&kernel.frames, page)
    slots :: cast[ptr[mut u64[64]]](test.page)
    match install(kernel, &process.table, cast[u64](space), space.header.generation, .AddressSpace, slop_os.RIGHTS_ALL, false) {
        case Ok(handle) => slots^[MEMORY_SLOT_SPACE] = cast[u64](cast[u32](handle))
        case Error(error) => {
            runtime.log_error("test_memory: no handle: %", error)
            return void
        }
    }
    _, root_used :: budget_info(cast[ptr[mut MemoryBudget]](kernel.root_budget))
    test.root_used = root_used
    if !give_test_budget(kernel, process, test.page) {
        return void
    }
    slots^[MEMORY_SLOT_ENTRY] = TEST_CODE + (cast[u64](user_memory_writer) - first)
    slots^[MEMORY_SLOT_STACK] = TEST_STACKS + 2 * frames.FRAME_SIZE - 8
    start :: arch_interface.UserStart.{
        instruction_pointer = cast[arch_interface.VirtualAddress](TEST_CODE + (cast[u64](user_memory) - first)),
        stack_pointer = cast[arch_interface.VirtualAddress](TEST_STACKS + frames.FRAME_SIZE - 8),
        argument = TEST_COUNTERS,
    }
    match create_thread(kernel, cast[u64](process), space, &start, arch_interface.VectorConfig.{extended = false}, 0, 0) {
        case Ok(thread) => start_thread(kernel, thread)
        case Error(error) => {
            runtime.log_error("test_memory: no thread: %", error)
            return void
        }
    }
    kernel.stop_after_ticks = MEMORY_TEST_TICKS
    intrinsics.atomic_store_u64_release(&kernel.memory_test, cast[u64](test))
}

memory_test_tick :: fn(kernel: ptr[mut Kernel], tick: u64) {
    address :: intrinsics.atomic_load_u64_acquire(&kernel.memory_test)
    if address == 0 {
        return void
    }
    test :: cast[ptr[mut MemoryTest]](address)
    if tick == MEMORY_TEST_DESTROY_TICK {
        check_memory_results(test)
        _ = destroy_object(kernel, test.process)
        return void
    }
    if tick != MEMORY_TEST_TICKS {
        return void
    }
    pools :: &kernel.pools
    _, root_used :: budget_info(cast[ptr[mut MemoryBudget]](kernel.root_budget))
    // The root budget is the one left
    if pools.memories.allocated != 0 || pools.mappings.allocated != 0 || pools.budgets.allocated != 1 || root_used != test.root_used {
        runtime.log_error("test_memory: left after the process was destroyed: % memory objects, % mappings, % budgets; the root has % charged, not %",
            pools.memories.allocated, pools.mappings.allocated, pools.budgets.allocated, root_used, test.root_used)
        return void
    }
    runtime.log_info("test_memory: destroying the process freed its memory, its mappings and its budgets, and gave the root budget back what it paid for")
}

// An error's tag, as a call gives it.
tag :: fn(error: slop_os.MemoryError) -> u64 {
    return cast[u64](cast[u32](error))
}

check_memory_results :: fn(test: ptr[MemoryTest]) {
    slots :: cast[ptr[u64[64]]](test.page)
    if slots^[MEMORY_SLOT_DONE] != 1 {
        runtime.log_error("test_memory: A didn't finish")
        return void
    }
    expected :: u64.[
        0, TEST_BUDGET_LIMIT,
        0, CHILD_LIMIT, 0,
        tag(.BudgetExceeded), tag(.InvalidSize), 0,
        0, tag(.BadAddress), tag(.InvalidSize), tag(.BadProtection),
        MEMORY_PAGES, 0, 1001,
        0, 0, cast[u64](cast[u32](slop_os.HandleError.ObjectGone)), 0, tag(.NotMapped),
    ]
    for value, i in expected {
        if slots^[MEMORY_RESULTS + i] != value {
            runtime.log_error("test_memory: result % is %, not %", i, slots^[MEMORY_RESULTS + i], value)
            return void
        }
    }
    // The child paid for the memory, and at least all of it
    child_used :: slots^[28]
    if child_used < MEMORY_SIZE + page_array_bytes(MEMORY_SIZE) || child_used > CHILD_LIMIT {
        runtime.log_error("test_memory: the child budget has % charged for % bytes of memory", child_used, MEMORY_SIZE)
        return void
    }
    // Closing it gave the parent back the limit, less what the child had used
    with_child :: slots^[29]
    after :: slots^[31]
    if slots^[30] != 0 || with_child - after != CHILD_LIMIT - child_used || slots^[32] != 1003 || slots^[33] != 0 {
        runtime.log_error("test_memory: closing the child took the parent from % to %, having used %; the memory read % after",
            with_child, after, child_used, slots^[32])
        return void
    }
    runtime.log_info("test_memory: budgets split and closed, memory filled as it was touched and shared between mappings, and a write it didn't allow stopped the thread")
}
