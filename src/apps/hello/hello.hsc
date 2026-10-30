package hello

import runtime from "base"
import os from "std"
import random from "std"
import text_buffer from "std"
import time from "std"
import slop_os from "std/os"
import process_manager from "std/os/slop_os"
import config from "../../protocols/config"
import connector from "../../protocols/connector"
import console_log from "../../protocols/console_log"
import entropy from "../../protocols/entropy"

/*
 * The first SlopOS program (roadmap M6): it fills memory from its heap, draws random numbers, and says
 * whether both worked through base's logger, to the events service, and on the console, if it's given a connection to the
 * console service, through a connector to it (decisions/0075, 0077). Given a connection to the process manager,
 * it then waits for the manager to be gone and says it's still running, which shows a program outlives the
 * manager that loaded it (decisions/0067). It says the date the wall clock gives too, which it reads from the clock
 * page it's given (decisions/0093). Given a connection to the entropy service, it asks it for random bytes too
 * (decisions/0067, 0101). Given its settings in the config store (decisions/0109), it declares them, writes an override,
 * reads them back merged, and rolls the override back. It ends with 0 if its heap worked.
 */
main :: fn(manager: os.Channel[process_manager.ProcessManager]?, console: os.Channel[connector.Connector]?,
    entropy_service: os.Channel[entropy.Entropy]?, settings: config.Config[HelloSettings]?) -> int {
    code :: fill_heap()
    // Two draws of 64 bits alike would be one chance in 2^64
    random_works :: random.next_u64() != random.next_u64()
    runtime.log_info("heap %, random numbers %", if code == 0 { "working" } else { "broken" },
        if random_works { "working" } else { "broken" })
    match entropy_service {
        case Some(connection) => runtime.log_info("the entropy service gave % random bytes", entropy_bytes(connection.end))
        case None => {}
    }
    match settings {
        case Some(value) => check_settings(value)
        case None => {}
    }
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

// hello's settings, in the config store: only what it's been asked to show.
HelloSettings :: struct {
    greeting : slop_os.Relative[u8],
    repeats : u32 = 1,
    loud : bool,
}

/*
 * Its settings declared, an override of greeting and repeats written and read back over the default, which loud keeps,
 * Next answered at once for a version already past, and the override rolled back to the declared version's.
 */
check_settings :: fn(settings: config.Config[HelloSettings]) {
    port :: os.port_for(slop_os.startup_block().budget, settings.end) or_return void
    declared :: match config.declare(settings, port) {
        case Ok(version) => version
        case Error(error) => {
            runtime.log_info("config: declaring its settings failed (%)", error)
            return void
        }
    }
    value := os.Outgoing.{}
    first :: if config.read(settings, port, &value) is_ok { os.typed_value[HelloSettings](os.value_bytes(&value)).repeats } else { 0 }
    override := os.Outgoing.{}
    written :: os.begin[HelloSettings](&override)
    written.repeats = 3
    written.loud = true
    written.greeting = os.append(&override, string_bytes("hi"))
    fields :: config.field_bit[HelloSettings]("greeting") | config.field_bit[HelloSettings]("repeats")
    wrote :: config.write(settings, port, os.value_bytes(&override), fields) is_ok
    // Next for the declared version, which the write is past
    merged := "not read"
    if config.next(settings, port, declared, &value) is_ok {
        bytes :: os.value_bytes(&value)
        read :: os.typed_value[HelloSettings](bytes)
        greeting :: os.items_of(bytes, read.greeting)
        merged = if read.repeats == 3 && !read.loud && greeting.count == 2 && string_of(&greeting[0], 2) == "hi" { "merged" } else { "not merged" }
    }
    author_storage : u8[..]
    defer runtime.array_free(&author_storage)
    author :: match config.history(settings, port, 0, &author_storage) {
        case Some(kept) => if author_storage.count > 0 { string_of(&author_storage[0], author_storage.count) } else { "nobody" }
        case None => "nobody"
    }
    rolled :: config.roll_back(settings, port, declared) is_ok
    after :: if config.read(settings, port, &value) is_ok { os.typed_value[HelloSettings](os.value_bytes(&value)).repeats } else { 0 }
    runtime.log_info("config: declared repeats %, wrote an override %, read it back %, by %; rolled back %, repeats %", first,
        if wrote { "kept" } else { "refused" }, merged, author, if rolled { "kept" } else { "refused" }, after)
}

// How many random bytes the entropy service gives, through end, for 32 asked for: 0 if it gives none.
entropy_bytes :: fn(end: slop_os.Channel) -> usize {
    port :: os.port_for(slop_os.startup_block().budget, end) or_return 0
    out := os.Outgoing.{}
    request :: os.begin[entropy.Request](&out)
    request^ = .Fill(32)
    if entropy.send_request(end, port, &out) is_some {
        return 0
    }
    into := os.Incoming.{}
    loop {
        match entropy.receive_response(end, port, &into, true) {
            case Received => break
            case Failed(error) => return 0
            case _ => continue
        }
    }
    return match os.message_of[entropy.Response](&into)^ {
        case Filled(bytes) => os.items(&into, bytes).count
        case _ => 0
    }
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
