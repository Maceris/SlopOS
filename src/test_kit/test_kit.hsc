/**
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

/** The size of a test thread's stack, in bytes, as start_thread maps it: 64 KiB. */
THREAD_STACK : u64 : 64 * 1024

/**
 * Give a call's result as the word a test keeps in its results: its error's tag, or 0 for success.
 *
 * @tparam T What the call gives on success, which is dropped.
 * @tparam E The call's error type, an enum backed by a u32 whose tags start at 1, as slop_os's errors are, so a tag
 *     can't be confused with success.
 * @param result The result of the call checked, Ok or an Error; only its variant and error are read, and an Ok's
 *     value is dropped.
 * @return 0 if result is Ok, or the error's u32 tag, widened, if it's an Error.
 */
tag_of :: fn[T, E](result: Result[T, E]) -> u64 #no_context {
    return match result {
        case Error(error) => cast[u64](cast[u32](error))
        case _ => 0
    }
}

/**
 * Give an error as the word a call's result would be kept as: its tag, which a check's expected values are written in.
 *
 * @tparam E The error type, an enum backed by a u32, as slop_os's errors are.
 * @param error The error a check expects, any of E's variants; only its tag is used.
 * @return The error's u32 tag, widened, the same word tag_of gives for a result with that error.
 */
tag :: fn[E](error: E) -> u64 #no_context {
    return cast[u64](cast[u32](error))
}

/**
 * Compare what a test's calls gave with what they should have, and give the test's exit code.
 *
 * Only the first expected.count results are compared, in order; a result past results' end compares as all ones,
 * which no expected value should be, so it fails. The first that differs is logged as a line naming the test, the
 * result's index from 0, and both values, and comparing stops there.
 *
 * @param log The debug log the failure is written to, which needs RIGHT_DEBUG_LOG_WRITE; nothing is logged when
 *     every result matches.
 * @param name The test's name, which starts the logged line.
 * @param results What the test's calls gave, as tag_of, tag or other words keep them; extra results after
 *     expected.count are ignored.
 * @param expected What each result should be, in the same order; empty passes without comparing anything.
 * @return 0 if every expected value matched, otherwise the index of the first result that didn't, counted from 1,
 *     so a test's exit code says which check failed.
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

/**
 * Start a thread of the process's own, on a stack of its own, for a test that needs more than one thread.
 *
 * The stack is a memory object of THREAD_STACK bytes, charged to the process's own budget (the startup block's, not
 * budget), mapped read/write at addresses reserved from the startup block's free range. Neither the stack nor its
 * addresses are given back, even when the thread ends or a later step fails, so a test starts few of them.
 *
 * @param budget The memory budget the thread itself is charged to.
 * @param entry The address of the function the thread runs: a #calling_convention(.c) #no_context function, as the
 *     runtime has no thread support yet, which never returns but ends with thread_exit.
 * @param argument A word handed to entry as its first argument, often the address of something the threads share.
 * @return An owning handle to the thread, running by the time this returns.
 * @error OutOfMemory The stack couldn't be made, its addresses reserved or it mapped, whatever the reason; or the
 *     kernel had no memory for the thread.
 * @error ObjectGone The process or its address space was destroyed.
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

/**
 * Read the monotonic clock.
 *
 * @return The time in nanoseconds since an arbitrary start, which never goes back; 0 if the clock couldn't be read,
 *     which it always can.
 */
clock_now :: fn() -> u64 #no_context {
    return slop_os.clock_monotonic() or_else 0
}

/**
 * Wait by spinning, without sleeping or yielding the CPU, so it's safe on a thread without a context.
 *
 * @param nanoseconds How long to wait at least; it may be longer, by however long the thread isn't run. 0 still reads
 *     the clock once more before returning.
 */
wait_nanoseconds :: fn(nanoseconds: u64) #no_context {
    started :: clock_now()
    loop {
        intrinsics.spin_hint()
    }
    while clock_now() - started < nanoseconds
}

/**
 * Wait, spinning, for a word another thread sets, with a timeout.
 *
 * @param address The word, read with volatile loads each time round, so a store from another thread or CPU is seen;
 *     it has to stay mapped and readable while this waits.
 * @param nanoseconds How long to wait at most, on the monotonic clock; 0 checks only once or twice.
 * @return True if the word wasn't 0 by the time the wait ended, false if it still was after nanoseconds.
 */
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

/**
 * Tell how much a memory budget has charged.
 *
 * @param budget The budget; no right is needed.
 * @return The bytes charged to it, or all ones (0xffffffffffffffff) if memory_budget_info failed, as for a handle
 *     that isn't a budget, which no check of a real amount will match.
 */
used :: fn(budget: slop_os.MemoryBudget) -> u64 #no_context {
    info :: slop_os.memory_budget_info(budget) or_else slop_os.BudgetInfo.{used = 0xffffffffffffffff}
    return info.used
}

/**
 * Wait, spinning, for what a budget has charged to come back down, as what was charged to it is freed only after a
 * grace period.
 *
 * @param budget The budget to watch; no right is needed. If it can't be read, its charge counts as all ones, so the
 *     wait runs out.
 * @param at_most The most it may have charged, in bytes, for the wait to end early: usually what it had before what
 *     was freed was made.
 * @param nanoseconds How long to wait at most, on the monotonic clock.
 * @return True if the budget's charge was at most at_most by the time the wait ended, false if it still wasn't.
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

/**
 * View memory as packets, for a port_wait to fill, from a #no_context thread that can't make a slice another way.
 *
 * @param address Where the packets are, which has to be mapped writable for count packets and outlast the view;
 *     nothing is checked.
 * @param count How many packets the view has, not bytes.
 * @return A slice of count packets at address, which doesn't own them.
 */
packets_at :: fn(address: u64, count: usize) -> mut slop_os.Packet[] #no_context {
    return bit_cast[mut slop_os.Packet[]](usize.[count, cast[usize](address)])
}

/**
 * View memory as bytes, for a call that takes a slice, from a #no_context thread that can't make one another way.
 *
 * @param address Where the bytes are, which has to be mapped for count bytes and outlast the view; nothing is
 *     checked.
 * @param count How many bytes the view has.
 * @return A slice of count bytes at address, which doesn't own them.
 */
bytes_at :: fn(address: u64, count: usize) -> mut u8[] #no_context {
    return bit_cast[mut u8[]](usize.[count, cast[usize](address)])
}

/**
 * Take a handle back from the word a test kept it in, as a page of results shared between threads keeps handles.
 *
 * @tparam H The kind of handle, a distinct alias of slop_os.Handle.
 * @param word The word, whose low 32 bits are the handle; the rest are ignored.
 * @return The handle, which is borrowed: the word doesn't own it, and it's still the one handle, not a copy.
 */
handle_at :: fn[H](word: u64) -> H #no_context {
    return cast[H](cast[slop_os.Handle](cast[u32](word)))
}
