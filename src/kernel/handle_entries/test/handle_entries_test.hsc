/**
 * The handle entry's tests (tools/unit_tests.py, decisions/0175, 0187): its reads under the model checker, racing a
 * close and the entry's reuse, which the build package's tests target builds model-checked.
 */
package handle_entries_test

import runtime from "base"
import concurrency from "std"
import testing from "std"
import handle_entries from ".."

/** The first handle the entry holds, at generation 0. */
FIRST :: handle_entries.Held.{object = 0x1000, generation = 1, kind = 1, rights = 0x11, owning = true}
/** What it holds once that's closed, at generation 1. */
SECOND :: handle_entries.Held.{object = 0x2000, generation = 2, kind = 2, rights = 0x22, owning = false}

/** An entry, its table's lock, and what the reader found. */
Table :: struct {
    lock : concurrency.SpinLock,
    entry : handle_entries.HandleEntry,
    /** The test's state, by its address, where a read of something other than one whole handle fails it. */
    t : u64,
    /** How many executions' reads found the first handle, and the second, so the races are seen to happen. */
    found_first : u32,
    found_second : u32,
}

/**
 * Give the test's state from its address.
 *
 * @param address The address, as a number, which isn't a pointer into anyone's stack for the escape checks: the test's
 *     state outlives check_model, and so every thread.
 * @return The test's state.
 */
test_at :: fn(address: u64) -> ptr[mut testing.T] {
    return cast[ptr[mut testing.T]](cast[rawptr](cast[uintptr](address)))
}

/**
 * Give the test's state's address, as a number.
 *
 * @param t The test's state.
 * @return Its address.
 */
address_of_test :: fn(t: ptr[mut testing.T]) -> u64 {
    return cast[u64](cast[uintptr](cast[rawptr](t)))
}

table_of :: fn(data: any) -> ptr[mut Table] {
    return cast[ptr[ptr[mut Table]]](data.data)^
}

/**
 * Say whether two handles are the same.
 *
 * @param a One.
 * @param b The other.
 * @return True if every field is.
 */
same :: fn(a: handle_entries.Held, b: handle_entries.Held) -> bool {
    return a.object == b.object && a.generation == b.generation && a.kind == b.kind && a.rights == b.rights
        && a.owning == b.owning
}

/** Read the entry as the first handle, then as the second: each found has to be that one, whole. */
reader : runtime.ThreadFunction : fn(data #escaping : any) {
    table :: table_of(data)
    match handle_entries.read(&table.entry, 0) {
        case Some(held) => {
            testing.expect(test_at(table.t), same(held, FIRST), "a read of the first handle finds it whole")
            table.found_first += 1
        }
        case None => {}
    }
    match handle_entries.read(&table.entry, 1) {
        case Some(held) => {
            testing.expect(test_at(table.t), same(held, SECOND), "a read of the second handle finds it whole")
            table.found_second += 1
        }
        case None => {}
    }
}

/** Close the first handle, then reuse the entry for the second, each under the lock. */
closer : runtime.ThreadFunction : fn(data #escaping : any) {
    table :: table_of(data)
    concurrency.lock(&table.lock)
    next : u64 = 0
    emptied :: handle_entries.empty(&table.entry, 0, &next)
    testing.expect(test_at(table.t), (emptied is_some) && next == 1, "the first handle is closed, to generation 1")
    concurrency.unlock(&table.lock)
    concurrency.lock(&table.lock)
    testing.expect_eq(test_at(table.t), handle_entries.fill(&table.entry, SECOND), 1, "the second handle is at generation 1")
    concurrency.unlock(&table.lock)
}

race_body : runtime.ThreadFunction : fn(data #escaping : any) {
    table :: table_of(data)
    table.lock = concurrency.SpinLock.{}
    table.entry = handle_entries.HandleEntry.{}
    handle_entries.start(&table.entry, 0)
    handle_entries.fill(&table.entry, FIRST)
    first :: testing.spawn(reader, data) or_return void
    second :: testing.spawn(closer, data) or_return void
    testing.join(first)
    testing.join(second)
}

reads_racing_a_close_and_reuse_see_one_whole_handle #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    table :: runtime.new(Table)
    defer runtime.free(table)
    table.t = address_of_test(t)
    outcome :: testing.check_model(t, race_body, table)
    testing.expect(t, outcome is_ok, "in every schedule, a read finds one whole handle, or none")
    testing.expect(t, table.found_first > 0 && table.found_second > 0, "some schedules read each handle")
    return .Ok
}

/** An entry emptied gives back what it held, and its handle fails; one whose generation wraps says so. */
emptying_advances_the_generation #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    entry := handle_entries.HandleEntry.{}
    handle_entries.start(&entry, 0xffff)
    testing.expect_eq(t, handle_entries.fill(&entry, FIRST), 0xffff, "filled at its generation")
    testing.expect(t, handle_entries.read(&entry, 0xfffe) is_none, "another generation's handle fails")
    next : u64 = 5
    match handle_entries.empty(&entry, 0xffff, &next) {
        case Some(emptied) => testing.expect(t, same(emptied, FIRST), "emptying gives what it held")
        case None => testing.fail(t, "the handle is closed")
    }
    testing.expect_eq(t, next, 0, "the generation wrapped")
    testing.expect(t, handle_entries.read(&entry, 0xffff) is_none, "the closed handle fails")
    testing.expect(t, handle_entries.peek(&entry) is_none, "the entry is empty")
    return .Ok
}
