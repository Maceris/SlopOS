package hello

import runtime from "base"
import os from "std"
import random from "std"
import text_buffer from "std"
import time from "std"
import slop_os from "std/os"
import process_manager from "std/os/slop_os"
import connector from "../../protocols/connector"
import console_log from "../../protocols/console_log"

/*
 * The first SlopOS program (roadmap M6): it fills memory from its heap, draws random numbers, and says
 * whether both worked through base's logger, to the events service, and on the console, if it's given a connection to the
 * console service, through a connector to it (decisions/0075, 0077). Given a connection to the process manager,
 * it then waits for the manager to be gone and says it's still running, which shows a program outlives the
 * manager that loaded it (decisions/0067). It says the date the wall clock gives too, which it reads from the clock
 * page it's given (decisions/0093). It ends with 0 if its heap worked.
 */
main :: fn(manager: os.Channel[process_manager.ProcessManager]?, console: os.Channel[connector.Connector]?)
    -> int {
    code :: fill_heap()
    // Two draws of 64 bits alike would be one chance in 2^64
    random_works :: random.next_u64() != random.next_u64()
    runtime.log_info("heap %, random numbers %", if code == 0 { "working" } else { "broken" },
        if random_works { "working" } else { "broken" })
    match time.now() {
        case Ok(now) => {
            today :: time.utc(now)
            storage : u8[16]
            date := text_buffer.make(storage)
            text_buffer.append_format(&date, "%-", today.year)
            append_two_digits(&date, today.month)
            text_buffer.append_format(&date, "-")
            append_two_digits(&date, today.day)
            runtime.log_info("the wall clock says it's %", text_buffer.as_string(&date))
        }
        case Error(error) => runtime.log_info("no wall clock (%)", error)
    }
    match console {
        case Some(dialing) => {
            dial_port :: os.port_for(slop_os.startup_block().budget, dialing.end) or_return 6
            connection :: connector.dial[console_log.ConsoleLog](dialing.end, dial_port) or_return 6
            port :: os.port_for(slop_os.startup_block().budget, connection.end) or_return 6
            _ = console_log.write(connection.end, port, if code == 0 && random_works { "hello: heap and random numbers working" }
                else { "hello: something's broken" })
        }
        case None => {}
    }
    match manager {
        case Some(connection) => {
            port :: slop_os.port_create(slop_os.startup_block().budget) or_return 3
            slop_os.port_bind(port, cast[slop_os.Handle](connection.end), slop_os.SIGNAL_PEER_CLOSED, 0, .Once) or_return 4
            packets : slop_os.Packet[1]
            _ = slop_os.port_wait(port, packets, slop_os.NO_DEADLINE) or_return 5
            runtime.log_info("still running after the process manager ended")
        }
        case None => {}
    }
    return code
}

// A field of a date, with a 0 in front of it below 10.
append_two_digits :: fn(line: ptr[mut text_buffer.TextBuffer], value: int) {
    if value < 10 {
        text_buffer.append_format(line, "0")
    }
    text_buffer.append_format(line, "%", value)
}

// 0 if memory from the heap holds what's written to it.
fill_heap :: fn() -> int {
    values, error :: runtime.new_array(u64, 1000)
    if error != null {
        return 1
    }
    defer runtime.free_array(values)
    for &value, i in values {
        value^ = cast[u64](i) * 3
    }
    total : u64 = 0
    for value in values {
        total += value
    }
    // 3 × (0 + 1 + ... + 999)
    return if total == 1498500 { 0 } else { 2 }
}
