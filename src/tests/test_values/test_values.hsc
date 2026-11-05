/**
 * test_values (decisions/0162): an entry's parameters that aren't handles are values, written by whoever launches
 * the program in its grant "arguments" and read by its runtime before main. Launched by the root task with none, it
 * launches a copy of itself with a number, a string, a list of strings, an enum's member and a record, as std/os's
 * launch writes them, and waits for it: the copy runs the same test, which as the copy checks each value, reporting
 * as "test_values copy", and ends with 0 if every one is what was given.
 */
package test_values

import compiler from "base"
import os from "std"
import testing from "std"
import slop_os from "std/os"
import process_manager from "std/os/slop_os"
import test_kit from "../../test_kit"

/** The test's name, which starts each line it logs. */
NAME :: "test_values"
/** The copy's name, which starts each line the copy logs. */
COPY_NAME :: "test_values copy"
/** The copy's memory budget, in bytes: 4 MiB. */
COPY_BUDGET : u64 : 4 << 20
/** The key the copy's watch queues its end under. */
WATCH_KEY : u64 : 1

/** An enum passed as a value, by its member. */
Speed :: enum {
    /** Slow; what the copy takes speed as without one. */
    Slow,
    /** Fast; what the copy is given. */
    Fast,
}

/** A record passed as a value, with a signed number, a large one, and a string. */
Limits :: struct {
    /** A negative number, -7 as given, so its sign has to survive. */
    low : i32,
    /** A number past 32 bits, 9,000,000,000 as given. */
    high : u64,
    /** A string inside the record, "bounds" as given. */
    name : string,
}

/** What the copy is given: its log, and the values. */
CopyGrants :: struct {
    /** A copy of the test's debug log, writable. */
    log : slop_os.DebugLog,
    /** Not given. */
    manager : os.Channel[process_manager.ProcessManager]?,
    /** Not given. */
    program : slop_os.Memory?,
    /** A number, 3, whose presence makes main run as the copy. */
    count : u64?,
    /** A string, "three". */
    label : string?,
    /** A list of strings, "a" and "bc". */
    tags : string[]?,
    /** An enum's member, Fast. */
    speed : Speed?,
    /** A record. */
    limits : Limits?,
}

/**
 * What the copy read of the values it was given, as test_kit.run can hold it: what has no pointers is kept, and each
 * string is kept as whether it was what the program launching the copy gave, as what main is given can't hold a
 * pointer (test_kit.run copies it to the heap).
 */
ValuesRead :: struct {
    /** The number given, 3 in the copy; 0 if there was none. */
    count : u64,
    /** Whether the string given was there, and "three". */
    label_is_three : bool,
    /** How many strings the list given had, 2 in the copy; 0 if there was none. */
    tag_count : usize,
    /** Whether the list's strings were "a" then "bc"; false if it had other than 2. */
    tags_are_a_and_bc : bool,
    /** The member given, Fast in the copy; Slow if there was none. */
    speed : Speed,
    /** Whether a record was given. */
    has_limits : bool,
    /** The record's negative number, -7 in the copy; 0 if there was no record. */
    low : i32,
    /** The record's number past 32 bits, 9,000,000,000 in the copy; 0 if there was no record. */
    high : u64,
    /** Whether the record was there, and its string "bounds". */
    name_is_bounds : bool,
}

/** What main was given that the tests use: the program's grants, and in the copy, what it read of its values. */
Given :: struct {
    /** The debug log. */
    log : slop_os.DebugLog,
    /** The process manager, which launches the copy; none in the copy. */
    manager : os.Channel[process_manager.ProcessManager]?,
    /** The test's own module, which the copy is launched from; none in the copy. */
    program : slop_os.Memory?,
    /** What the copy read of its values; none in the program the root task ran, which says it isn't the copy. */
    copy : ValuesRead?,
}

/**
 * Check that values given in a launch reach the program launched: run by the root task, launch a copy with some and
 * see it end with 0, its own run of this test having passed, and its budget come back to nothing; run as the copy,
 * check each value is what was given.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if, run by the root task, it wasn't given the process manager or its module, or a
 *     port, the log's copy or the launch couldn't be made.
 */
values_given_in_a_launch_reach_the_program #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    given :: test_kit.given(t, Given)?
    match given.copy {
        case Some(read) => {
            check_copy(t, read)
            return .Ok
        }
        case None => {}
    }
    block :: slop_os.startup_block()
    executable :: testing.require_some(t, given.program, "the root task grants the program's own module")?
    loader :: testing.require_some(t, given.manager, "the root task grants the process manager")?
    manager_port :: testing.require_some(t, os.port_for(block.budget, loader.end), "a port for the process manager's replies")?
    port :: testing.require_ok(t, slop_os.port_create(block.budget), "a port for the copy's watch")?
    rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_DEBUG_LOG_WRITE) | cast[u32](slop_os.RIGHT_TRANSFER))
    copy_log :: testing.require_ok(t, slop_os.handle_duplicate(cast[slop_os.Handle](given.log), rights), "the debug log can be copied for the copy")?
    grants := CopyGrants.{log = cast[slop_os.DebugLog](copy_log), count = 3, label = "three", tags = string.["a", "bc"], speed = .Fast,
        limits = Limits.{low = -7, high = 9_000_000_000, name = "bounds"}}
    launch :: os.launch(loader, manager_port, "test_values copy", executable, COPY_BUDGET, main, grants,
        os.LaunchOptions.{watch = os.LaunchWatch.{port = port, key = WATCH_KEY}})
    launched :: testing.require_ok(t, launch, "the process manager launches the copy with its values")?
    testing.expect_eq(t, ended_with(port), 0, "the copy read every value as it was given, so its test passed")
    _ = slop_os.handle_close(cast[slop_os.Handle](launched.process))
    testing.expect(t, test_kit.wait_for_budget(launched.budget, 0, 1_000_000_000), "the copy's budget is back to nothing once it has ended")
    _ = slop_os.handle_close(cast[slop_os.Handle](launched.budget))
    _ = slop_os.handle_close(cast[slop_os.Handle](port))
    return .Ok
}

/**
 * Check, as the copy, each value it read against what the program launching it gave.
 *
 * @param t The test's state, which each value that isn't what was given is recorded in.
 * @param read What the copy read of its values.
 */
check_copy :: fn(t: ptr[mut testing.T], read: ValuesRead) {
    testing.expect_eq(t, read.count, 3, "a number given reads back as itself")
    testing.expect(t, read.label_is_three, "a string given reads back as itself, \"three\"")
    testing.expect_eq(t, read.tag_count, 2, "a list of strings given reads back with as many strings")
    testing.expect(t, read.tags_are_a_and_bc, "each string of a list given reads back as itself, in its place: \"a\" then \"bc\"")
    testing.expect_eq(t, read.speed, Speed.Fast, "an enum's member given reads back as that member")
    testing.expect(t, read.has_limits, "a record given reads back")
    testing.expect_eq(t, read.low, -7, "a record's negative number keeps its sign")
    testing.expect_eq(t, read.high, 9_000_000_000, "a record's number past 32 bits keeps its high bits")
    testing.expect(t, read.name_is_bounds, "a record's string reads back as itself, \"bounds\"")
}

/**
 * ValuesRead the values the copy was given, as its test can be given them.
 *
 * @param count The number given.
 * @param label The string given; None reads as not "three".
 * @param tags The list given; None reads as no strings.
 * @param speed The member given; None reads as Slow.
 * @param limits The record given; None reads as no record, its numbers 0.
 * @return What was read, each string as whether it's what the program launching the copy gave.
 */
read_values :: fn(count: u64, label: string?, tags: string[]?, speed: Speed?, limits: Limits?) -> ValuesRead {
    given_tags :: tags or_else string.[]
    expected_tags :: string.["a", "bc"]
    tags_match := given_tags.count == expected_tags.count
    for tag, i in given_tags {
        if i < expected_tags.count && tag != expected_tags[i] {
            tags_match = false
        }
    }
    bounds :: limits or_else Limits.{}
    return ValuesRead.{count = count, label_is_three = (label or_else "") == "three", tag_count = given_tags.count,
        tags_are_a_and_bc = tags_match, speed = speed or_else Speed.Slow, has_limits = limits is_some, low = bounds.low,
        high = bounds.high, name_is_bounds = (limits is_some) && bounds.name == "bounds"}
}

/**
 * Run the tests, reporting to the debug log: as the program the root task ran, or, given count, as the copy, its
 * lines started with COPY_NAME.
 *
 * @param log The debug log, writable, where each test is reported.
 * @param manager The process manager, which launches the copy; without it the test fails.
 * @param program The test's own module, which the copy is launched from; without it the test fails.
 * @param count Given only to the copy, 3. With it, this runs as the copy.
 * @param label Given only to the copy, "three".
 * @param tags Given only to the copy, "a" and "bc".
 * @param speed Given only to the copy, Fast.
 * @param limits Given only to the copy: -7, 9,000,000,000 and "bounds".
 * @return How many tests failed: 0 when every one passed.
 */
main :: fn(log: slop_os.DebugLog, manager: os.Channel[process_manager.ProcessManager]?, program: slop_os.Memory?, count: u64?,
    label: string?, tags: string[]?, speed: Speed?, limits: Limits?) -> int {
    given := Given.{log = log, manager = manager, program = program}
    name := NAME
    match count {
        case Some(number) => {
            given.copy = read_values(number, label, tags, speed, limits)
            name = COPY_NAME
        }
        case None => {}
    }
    return test_kit.run(log, name, #insert testing.tests_of(compiler.load_package(".")), given)
}

/**
 * Wait for a watched process to end, and tell how.
 *
 * @param port The port its watch, for SIGNAL_TERMINATED, queues on; nothing else may be bound to it.
 * @return The process's exit code, or 0xffff if the wait failed.
 */
ended_with :: fn(port: slop_os.Port) -> u64 {
    packets : slop_os.Packet[1]
    taken :: slop_os.port_wait(port, packets, slop_os.NO_DEADLINE) or_else 0
    return if taken == 1 { packets[0].data[1] } else { cast[u64](0xffff) }
}
