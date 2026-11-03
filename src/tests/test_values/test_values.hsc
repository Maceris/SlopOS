/*
 * test_values (decisions/0162): an entry's parameters that aren't handles are values, written by whoever launches the
 * program in its grant "arguments" and read by its runtime before main. Launched by the root task with none, it
 * launches a copy of itself with a number, a string, a list of strings, an enum's member and a record, as std/os's
 * launch writes them, and waits for it: the copy checks each, and ends with 0 if every one is what was given.
 */
package test_values

import os from "std"
import slop_os from "std/os"
import process_manager from "std/os/slop_os"
import log_line from "../../log_line"
import test_kit from "../../test_kit"

NAME :: "test_values"
COPY_BUDGET : u64 : 4 << 20
WATCH_KEY : u64 : 1

Speed :: enum {
    Slow,
    Fast,
}

Limits :: struct {
    low : i32,
    high : u64,
    name : string,
}

// What the copy is given: its log, and the values.
CopyGrants :: struct {
    log : slop_os.DebugLog,
    manager : os.Channel[process_manager.ProcessManager]?,
    program : slop_os.Memory?,
    count : u64?,
    label : string?,
    tags : string[]?,
    speed : Speed?,
    limits : Limits?,
}

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

// In the copy: each value checked, 0 if all are what the test gave, or which wasn't.
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

// How the process watched on port ended: its code, once it has.
ended_with :: fn(port: slop_os.Port) -> u64 {
    packets : slop_os.Packet[1]
    taken :: slop_os.port_wait(port, packets, slop_os.NO_DEADLINE) or_else 0
    return if taken == 1 { packets[0].data[1] } else { cast[u64](0xffff) }
}
