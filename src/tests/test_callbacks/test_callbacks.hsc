/**
 * test_callbacks (decisions/0201, 20k): C calling back into Hemera. Its C, sorting.c, built by a stock clang into
 * test_callbacks_c's library (tools/c_libraries.py), sorts by calling a Hemera comparison, a .c function with a
 * context, for each pair, with the carrier register spoiled before each call; the comparison's shim finds the thread's
 * carrier block through its thread pointer, runs with the caller's context, and allocates through it.
 */
package test_callbacks

import compiler from "base:compiler"
import runtime from "base:runtime"
import os from "std:os"
import slop_os from "std:os/slop_os"
import process_manager from "std:os/slop_os/process_manager"
import testing from "std:testing"
import test_kit from "../../test_kit"

/** The test's name, which starts each line it logs. */
NAME :: "test_callbacks"

/** The C library, test_callbacks_c's, which tools/c_libraries.py builds from c/ beside this. */
SORTING :: #library("test_callbacks_c")

/**
 * Sort items in place, calling compare for each comparison with data (sorting.c).
 *
 * @param items The items, count of them.
 * @param count How many.
 * @param compare The comparison: below 0, 0 or above for less, equal or more.
 * @param data What compare is given, as it is.
 * @return How many comparisons it made.
 */
sort_items #foreign(SORTING) : fn(items : ptr[mut i64], count : usize, compare : CompareItems, data : ptr[mut Tally]) -> usize : ---

/** A comparison sort_items calls: a .c function with a context, so C reaches it through its shim. */
CompareItems :: alias fn(a : ptr[i64], b : ptr[i64], data : ptr[mut Tally]) -> i32 #calling_convention(.c)

/** What a comparison counts, through the data it's given. */
Tally :: struct {
    /** How many times it was called. */
    calls : u64,
    /** How many of those found a heap allocation worked, through the context the callback ran with. */
    allocated : u64,
}

/**
 * Compare two items, as sort_items calls it: called from C, through its shim, with the caller's context.
 *
 * @param a One item.
 * @param b The other.
 * @param data The Tally, counted in.
 * @return -1, 0 or 1 for a below, equal to or above b.
 */
compare_items #calling_convention(.c) :: fn(a : ptr[i64], b : ptr[i64], data : ptr[mut Tally]) -> i32 {
    tally :: data
    tally.calls += 1
    // An allocation through the context, which only works if the carrier and context were found
    made, error :: runtime.new_aligned(u64, 8)
    if error == null {
        made^ = 1
        tally.allocated += made^
        runtime.free(made)
    }
    return if a^ < b^ { -1 } else if a^ > b^ { 1 } else { 0 }
}

/** What main was given that the tests use. */
Given :: struct {
    /** The debug log. */
    log : slop_os.DebugLog,
}

/**
 * Check that C calling back into Hemera works: sort_items sorts by compare_items, each call reaching it with its
 * carrier block and context though the carrier register was spoiled.
 *
 * @param t The test's state.
 * @return Ok once it's run.
 */
c_calls_back_into_hemera_with_its_carrier_and_context #test :: fn(t : ptr[mut testing.T]) -> testing.Outcome {
    items := i64.[5, -3, 12, 0, 7, 7, -40, 1]
    tally := Tally.{}
    comparisons :: sort_items(&items[0], items.count, compare_items, &tally)
    testing.expect(t, comparisons > 0, "sort_items compared")
    testing.expect_eq(t, tally.calls, cast[u64](comparisons), "every comparison called back into Hemera")
    testing.expect_eq(t, tally.allocated, tally.calls, "each callback allocated through its context")
    sorted := true
    for i in 1..<items.count {
        if items[i - 1] > items[i] {
            sorted = false
        }
    }
    testing.expect(t, sorted, "the items are sorted, as the comparison said")
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
main :: fn(
    log : slop_os.DebugLog,
    platform : slop_os.Platform?,
    test_device : slop_os.Memory?,
    firmware : slop_os.Memory?,
    manager : os.Channel[process_manager.ProcessManager]?,
    program : slop_os.Memory?,
    peer : slop_os.Channel?,
    cpu_budget : slop_os.CpuBudget?
) -> int {
    given :: Given.{log = log}
    return test_kit.run(log, NAME, #insert testing.tests_of(compiler.load_package(".")), given)
}
