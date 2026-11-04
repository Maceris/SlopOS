/**
 * The counter (roadmap 9d4, decisions/0117): an app for testing installations, in two versions, counter and
 * counter_next, with the same entry. Each run counts itself in its data directory's file count, and says which run it
 * is and which version counted it, so an update that keeps the data counts on, and an uninstall starts again from 1.
 * It declares its settings, so its configuration is something an uninstall removes. Then it keeps running, as an
 * installation does, until it's asked to stop on its lifecycle channel (decisions/0153).
 */
package counter_app

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import lifecycle from "std/os/slop_os"
import config from "../protocols/config"
import installations from "../installations"

/** What it's configured with: how much a run counts. */
CounterSettings :: struct {
    /** How much each run adds to the count, 1 unless configured; 0 makes runs leave it as it was. */
    step : u32 = 1,
}

/** The key the lifecycle's stop request is bound to on a run's port. */
STOP_KEY : u64 : 1

/**
 * Run the counter once: count the run in the data directory, say so in the log, then wait until asked to stop.
 *
 * The count is read from the file count in data, as decimal digits, 0 if there's no such file or it doesn't start
 * with a digit; step is added, and the new count written back before it's logged as "run <count>, version
 * <version>".
 *
 * @param data The installation's data directory, whose end the run takes over: it's closed when the run ends, or
 *     when the directory can't be opened.
 * @param settings The run's configuration connection, whose settings are declared, then read for the step; None, or
 *     settings that can't be read, count by 1.
 * @param version Which version of the app is running, as the entry says, which is only logged.
 * @return 0 once the run was asked to stop; 1 if no port could be made for the configuration connection; 2 if the
 *     data directory couldn't be opened; 3 if the count couldn't be written; 4 if the port for the stop request
 *     couldn't be made or bound.
 */
run :: fn(data: installations.AppData, settings: config.Config[CounterSettings]?, version: int) -> int {
    step := cast[u64](1)
    match settings {
        case Some(connection) => {
            port :: os.port_for(slop_os.startup_block().budget, connection.end) or_return 1
            _ = config.declare(connection, port)
            value := os.Outgoing.{}
            if config.read(connection, port, &value) is_ok {
                step = cast[u64](os.typed_value[CounterSettings](os.value_bytes(&value)).step)
            }
        }
        case None => {}
    }
    directory, error :: os.directory_on(data.end)
    if error != null {
        return 2
    }
    defer os.close_directory(directory)
    count := cast[u64](0)
    match os.read_entire_file_in(directory, "count") {
        case Ok(text) => count = number_of(text)
        case Error(failure) => {}
    }
    count += step
    digits : u8[20]
    if os.write_entire_file_in(directory, "count", decimal(count, &digits)) != null {
        return 3
    }
    runtime.log_info("run %, version %", count, version)
    port :: slop_os.port_create(slop_os.startup_block().budget) or_return 4
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    if !lifecycle.on_stop(port, STOP_KEY) {
        return 4
    }
    loop {
        if lifecycle.stop_requested() {
            return 0
        }
        packets : slop_os.Packet[1]
        _ = slop_os.port_wait(port, packets, slop_os.NO_DEADLINE)
    }
}

/**
 * Read a count written in decimal.
 *
 * @param text The text, whose leading digits are read up to the first byte that isn't one; a sign or space isn't.
 * @return The number its leading digits make, 0 if it doesn't start with a digit; one too big for a u64 wraps.
 */
number_of :: fn(text: string) -> u64 {
    value := cast[u64](0)
    for character in text {
        if character < '0' || character > '9' {
            break
        }
        value = value * 10 + cast[u64](character) - cast[u64]('0')
    }
    return value
}

/**
 * Write a number in decimal, for the count file.
 *
 * @param value The number; 0 is written as "0".
 * @param digits Where the digits go, 20 bytes, enough for any u64; what was there is overwritten.
 * @return The digits, without a sign or leading zeros, as a view into digits, good as long as it is.
 */
decimal :: fn(value: u64, digits: ptr[mut u8[20]]) -> string {
    reversed : u8[20]
    count := cast[usize](0)
    left := value
    loop {
        if count < reversed.count {
            reversed[count] = cast[u8](48 + left % 10)
            count += 1
        }
        left /= 10
    }
    while left != 0
    for i in cast[usize](0)..<count {
        at :: count - 1 - i
        if i < digits.count && at < reversed.count {
            digits^[i] = reversed[at]
        }
    }
    return string_of(&digits^[0], count)
}
