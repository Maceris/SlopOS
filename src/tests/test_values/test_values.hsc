/**
 * test_values (decisions/0162): an entry's parameters that aren't handles are values, written by whoever launches
 * the program in its grant "arguments" and read by its runtime before main. Launched by the root task with none, it
 * launches a copy of itself with a number, a string, a list of strings, an enum's member and a record, as std/os's
 * launch writes them, and waits for it: the copy checks each, and ends with 0 if every one is what was given.
 */
package test_values

import os from "std"
import slop_os from "std/os"
import process_manager from "std/os/slop_os"
import log_line from "../../log_line"
import test_kit from "../../test_kit"

/** The test's name, which starts each line it logs. */
NAME :: "test_values"
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
 * Check values passed to an entry: launch a copy with some, and see it end with 0; or, run as the copy, check them.
 *
 * @param log The debug log, writable, where the test says what it found and which check failed.
 * @param manager The process manager, which launches the copy; without it the test ends with 101.
 * @param program The test's own module, which the copy is launched from; without it the test ends with 100.
 * @param count Given only to the copy, 3. With it, this runs as the copy.
 * @param label Given only to the copy, "three".
 * @param tags Given only to the copy, "a" and "bc".
 * @param speed Given only to the copy, Fast.
 * @param limits Given only to the copy: -7, 9,000,000,000 and "bounds".
 * @return 0 if both checks passed; 1 if the copy didn't end with 0, 2 if its budget didn't come back to nothing.
 *     102 to 105 if setting up failed: 102 and 103 the ports, 104 the log's copy, 105 launching the copy. As the
 *     copy, what check_copy gives.
 */
main :: fn(log: slop_os.DebugLog, manager: os.Channel[process_manager.ProcessManager]?, program: slop_os.Memory?, count: u64?,
    label: string?, tags: string[]?, speed: Speed?, limits: Limits?) -> int {
    match count {
        case Some(given) => return check_copy(given, label, tags, speed, limits)
        case None => {}
    }
    block :: slop_os.startup_block()
    executable :: program or_return 100
    loader :: manager or_return 101
    manager_port :: os.port_for(block.budget, loader.end) or_return 102
    port :: slop_os.port_create(block.budget) or_return 103
    rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_DEBUG_LOG_WRITE) | cast[u32](slop_os.RIGHT_TRANSFER))
    copy_log :: cast[slop_os.DebugLog](slop_os.handle_duplicate(cast[slop_os.Handle](log), rights) or_return 104)
    grants := CopyGrants.{log = copy_log, count = 3, label = "three", tags = string.["a", "bc"], speed = .Fast,
        limits = Limits.{low = -7, high = 9_000_000_000, name = "bounds"}}
    launched :: os.launch(loader, manager_port, "test_values copy", executable, COPY_BUDGET, main, grants,
        os.LaunchOptions.{watch = os.LaunchWatch.{port = port, key = WATCH_KEY}}) or_return 105
    results : u64[2]
    results[0] = ended_with(port)
    _ = slop_os.handle_close(cast[slop_os.Handle](launched.process))
    results[1] = if test_kit.wait_for_budget(launched.budget, 0, 1_000_000_000) { cast[u64](1) } else { cast[u64](0) }
    _ = slop_os.handle_close(cast[slop_os.Handle](launched.budget))
    failed :: test_kit.check(log, NAME, results, u64.[0, 1])
    if failed == 0 {
        log_line.write(log, "%: a copy was given a number, a string, a list, an enum's member and a record, and read each", NAME)
    }
    return failed
}

/**
 * Check each value the copy was given against what the test gave.
 *
 * @param count The number given, which should be 3.
 * @param label The string given, which should be "three"; None fails.
 * @param tags The list given, which should be "a" and "bc"; None fails.
 * @param speed The member given, which should be Fast; None fails.
 * @param limits The record given, which should be -7, 9,000,000,000 and "bounds"; None fails.
 * @return 0 if every value is what was given; otherwise which wasn't: 1 count, 2 label, 3 tags, 4 speed, 5 limits.
 */
check_copy :: fn(count: u64, label: string?, tags: string[]?, speed: Speed?, limits: Limits?) -> int {
    if count != 3 {
        return 1
    }
    if (label or_else "") != "three" {
        return 2
    }
    given_tags :: tags or_return 3
    if given_tags.count != 2 || given_tags[0 % given_tags.count] != "a" || given_tags[1 % given_tags.count] != "bc" {
        return 3
    }
    if (speed or_else Speed.Slow) != .Fast {
        return 4
    }
    bounds :: limits or_return 5
    if bounds.low != -7 || bounds.high != 9_000_000_000 || bounds.name != "bounds" {
        return 5
    }
    return 0
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
