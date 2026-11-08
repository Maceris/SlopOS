package hello

import compiler from "base"
import runtime from "base"
import os from "std"
import random from "std"
import text_buffer from "std"
import time from "std"
import slop_os from "std/os"
import service_kit from "../../libraries/service_kit"
import terminal from "std/os/slop_os"
import process_manager from "std/os/slop_os"
import config from "../../protocols/config"
import connector from "../../protocols/connector"
import entropy from "../../protocols/entropy"

/**
 * Whether this is the next build, hello_next.elf, built with the build's setting hello_build=next: it says it's the
 * next build first, a changed bundle for the test of generations applied live (decisions/0126).
 */
NEXT :: #run compiler.target_setting("hello_build", default = "") == "next"

/**
 * Check that a program's heap and random numbers work, and say so.
 *
 * The first SlopOS program (roadmap M6): it fills memory from its heap, draws random numbers, and says whether both
 * worked through base's logger, to the events service, and on the console (decisions/0075, 0077, 0136). It says the
 * date the wall clock gives too, which it reads from the clock page it's given (decisions/0093), or that there's no
 * wall clock. The next build (NEXT) says so first.
 *
 * @param manager A connection to the process manager. Given one, hello waits at the end for the manager to be gone,
 *     then says it's still running, which shows a program outlives the manager that loaded it (decisions/0067).
 *     Without it, hello ends as soon as it has said everything else.
 * @param console A connection to the terminal service's connector, dialed for a terminal on which hello writes one
 *     line saying whether its heap and random numbers worked. Without it, nothing's written on the console.
 * @param entropy_service A connection to the entropy service, asked for 32 random bytes; hello logs how many it gave
 *     (decisions/0067, 0101). Without it, hello doesn't ask.
 * @param settings hello's settings in the config store (decisions/0109): hello declares them, writes an override,
 *     reads them back merged, and rolls the override back, logging how each step went. Without them, it skips this.
 * @return 0 if its heap worked; 1 if the heap couldn't give it memory, 2 if the memory didn't hold what was written;
 *     3, 4 or 5 if it couldn't wait for the process manager to be gone; 6 if it couldn't reach the terminal.
 */
main :: fn(manager: os.Channel[process_manager.ProcessManager]?, console: os.Channel[connector.Connector]?,
    entropy_service: os.Channel[entropy.Entropy]?, settings: config.Config[HelloSettings]?) -> int {
    #if NEXT {
        runtime.log_info("the next build")
    }
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
            connection :: connector.dial[terminal.Terminal](dialing.end, dial_port) or_return 6
            port :: os.port_for(slop_os.startup_block().budget, connection.end) or_return 6
            _ = terminal.write_line(connection.end, port, if code == 0 && random_works { "hello: heap and random numbers working" }
                else { "hello: something's broken" })
        }
        case None => {}
    }
    match manager {
        case Some(connection) => {
            port :: slop_os.port_create(slop_os.startup_block().budget) or_return 3
            slop_os.port_bind(port, cast[slop_os.Handle](connection.end), slop_os.SIGNAL_PEER_CLOSED, 0, .Once) or_return 4
            // Or until it's asked to stop, as the system shuts down (decisions/0182)
            _ = service_kit.watch_stop(port)
            packets : slop_os.Packet[1]
            _ = slop_os.port_wait(port, packets, slop_os.NO_DEADLINE) or_return 5
            if service_kit.stopping() {
                return code
            }
            runtime.log_info("still running after the process manager ended")
        }
        case None => {}
    }
    return code
}

/** hello's settings, in the config store: only what it's been asked to show, as a test of the store. */
HelloSettings :: struct {
    /** A greeting, as bytes of text in the value; empty unless an override writes one. */
    greeting : slop_os.Relative[u8],
    /** How many times to repeat the greeting, 1 by default; only written and read back, never acted on. */
    repeats : u32 = 1,
    /** Whether to say it loudly, false by default; only read back, to check a write of other fields keeps it. */
    loud : bool,
}

/**
 * Exercise the config store with hello's settings, logging what each step did.
 *
 * It declares the settings, writes an override of greeting and repeats (loud is written too, but not among the fields,
 * so the default is kept), checks that Next is answered at once for the declared version, which the write is past, with
 * the override merged over the default, reads who wrote the first version in the history, and rolls the override back
 * to the declared version's. Nothing is returned: a step that fails is logged as refused or not read.
 *
 * @param settings The connection to the config store for hello's settings, which stays the caller's; a port for it is
 *     made from the process's budget and not closed.
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

/**
 * Ask the entropy service for 32 random bytes and count how many it gives.
 *
 * It sends Fill(32) and waits for the answer; the bytes themselves are only counted.
 *
 * @param end The channel to the entropy service, which stays the caller's; a port for it is made from the process's
 *     budget and not closed.
 * @return How many bytes the service gave, at most 32; 0 if the port couldn't be made, the request couldn't be sent,
 *     the answer failed, or it wasn't Filled.
 */
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
            case _ => return 0
        }
    }
    return match os.message_of[entropy.Response](&into)^ {
        case Filled(bytes) => os.items(&into, bytes).count
        case _ => 0
    }
}

/**
 * Append a field of a date in decimal, with a 0 in front of it below 10, so it's at least two digits.
 *
 * @param line The text to append to; what doesn't fit its storage is dropped, as text_buffer drops it.
 * @param value The field: a month (1 to 12) or a day (1 to 31). A negative value isn't padded right.
 */
append_two_digits :: fn(line: ptr[mut text_buffer.TextBuffer], value: int) {
    if value < 10 {
        text_buffer.append_format(line, "0")
    }
    text_buffer.append_format(line, "%", value)
}

/**
 * Check that memory from the heap holds what's written to it: 1000 numbers written and summed, then freed.
 *
 * @return 0 if the sum is right; 1 if the heap couldn't give the memory; 2 if the sum is wrong.
 */
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
