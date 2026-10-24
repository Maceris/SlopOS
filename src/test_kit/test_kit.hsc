/*
 * What SlopOS's test programs share (src/tests, decisions/0069): each is a program the root task runs with
 * test_program=<name> on the kernel's command line, with a TestGrants' worth of handles, and ends with 0 if
 * everything worked, or the number of the first check that failed, saying which in its debug log. Each keeps
 * what calls gave in results, and compares them with what they should have given:
 *
 *     results : u64[16]
 *     results[0] = test_kit.tag_of(slop_os.handle_close(handle))
 *     return test_kit.check(log, "test_syscalls", results, u64.[0])
 *
 * Threads of their own run #no_context functions on stacks of their own (start_thread), as there's no thread
 * support in the runtime yet.
 */
package test_kit

import intrinsics from "base"
import runtime from "base"
import slop_os from "std/os"
import log_line from "../log_line"

// A test thread's stack.
THREAD_STACK : u64 : 64 * 1024

// A result's error tag, 0 for success.
tag_of :: fn[T, E](result: Result[T, E]) -> u64 #no_context {
    return match result {
        case Error(error) => cast[u64](cast[u32](error))
        case _ => 0
    }
}

// An error's tag, as a call gives it.
tag :: fn[E](error: E) -> u64 #no_context {
    return cast[u64](cast[u32](error))
}

/*
 * 0 if each of results' first expected.count values is what expected says, otherwise the first that isn't,
 * counted from 1, after saying so.
 */
check :: fn(log: slop_os.DebugLog, name: string, results: u64[], expected: u64[]) -> int {
    for value, i in expected {
        found :: if i < results.count { results[i] } else { cast[u64](0xffffffffffffffff) }
        if found != value {
            log_line.write(log, "%: result % is %, not %", name, i, found, value)
            return cast[int](i) + 1
        }
    }
    return 0
}

/*
 * A thread of the process's own, charged to budget, at entry, a #calling_convention(.c) #no_context function,
 * given argument, on a stack of THREAD_STACK bytes mapped in the free range, charged to the process's: its
 * handle.
 */
start_thread :: fn(budget: slop_os.MemoryBudget, entry: u64, argument: u64) -> Result[slop_os.Thread, slop_os.HandleError] {
    block :: slop_os.startup_block()
    stack :: slop_os.memory_create(block.budget, THREAD_STACK) or_return .Error(.OutOfMemory)
    address :: runtime.reserve_addresses(cast[usize](THREAD_STACK)) or_return .Error(.OutOfMemory)
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    slop_os.memory_map(stack, block.space, address, 0, THREAD_STACK, read_write) or_return .Error(.OutOfMemory)
    // As a call leaves it: 8 below a multiple of 16
    return slop_os.thread_create(budget, block.space, entry, address + THREAD_STACK - 8, argument)
}

// The monotonic clock, in nanoseconds.
clock_now :: fn() -> u64 #no_context {
    return slop_os.clock_monotonic() or_else 0
}

wait_nanoseconds :: fn(nanoseconds: u64) #no_context {
    started :: clock_now()
    loop {
        intrinsics.spin_hint()
    }
    while clock_now() - started < nanoseconds
}

// Waits until value at address isn't 0, or nanoseconds have passed: whether it isn't.
wait_for :: fn(address: ptr[u64], nanoseconds: u64) -> bool #no_context {
    started :: clock_now()
    loop {
        if intrinsics.volatile_load_u64(address) != 0 {
            return true
        }
        intrinsics.spin_hint()
    }
    while clock_now() - started < nanoseconds
    return intrinsics.volatile_load_u64(address) != 0
}

// What a budget has charged, in bytes, or all ones if it can't be told.
used :: fn(budget: slop_os.MemoryBudget) -> u64 #no_context {
    info :: slop_os.memory_budget_info(budget) or_else slop_os.BudgetInfo.{used = 0xffffffffffffffff}
    return info.used
}

/*
 * Waits for what a budget has charged to come back to at most used, as what was charged to it is freed after
 * a grace period, for up to nanoseconds: whether it did.
 */
wait_for_budget :: fn(budget: slop_os.MemoryBudget, at_most: u64, nanoseconds: u64) -> bool #no_context {
    started :: clock_now()
    loop {
        if used(budget) <= at_most {
            return true
        }
        intrinsics.spin_hint()
    }
    while clock_now() - started < nanoseconds
    return used(budget) <= at_most
}

// count packets at address, for a port_wait.
packets_at :: fn(address: u64, count: usize) -> mut slop_os.Packet[] #no_context {
    return bit_cast[mut slop_os.Packet[]](usize.[count, cast[usize](address)])
}

// count bytes at address, as a slice for a call.
bytes_at :: fn(address: u64, count: usize) -> mut u8[] #no_context {
    return bit_cast[mut u8[]](usize.[count, cast[usize](address)])
}

// A handle from a word, as a page of results keeps it.
handle_at :: fn[H](word: u64) -> H #no_context {
    return cast[H](cast[slop_os.Handle](cast[u32](word)))
}
