/**
 * The protocols' validators, as a hosted program (tools/unit_tests.py; decisions/0186, He): each protocol's
 * validate_request and validate_response, which os.protocol_code generates, judge any bytes without reading outside
 * them, and judge the same bytes the same way. hemera --fuzz guides it by coverage (tools/fuzz.py). The network's
 * protocols, std's (network, tcp_stream, tcp_listener, datagrams) and net, are among them (decisions/0188, 13h).
 *
 * And a message's handles are each named by exactly one of its fields (13h): a handle no field names would be left
 * in the receiver's table, which a sender could fill so.
 */
package protocols_test

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import testing from "std"
import network from "std/os/slop_os"
import tcp_stream from "std/os/slop_os"
import tcp_listener from "std/os/slop_os"
import datagrams from "std/os/slop_os"
import accounts from "../accounts"
import block from "../block"
import bundle_store from "../bundle_store"
import clock_setting from "../clock_setting"
import config from "../config"
import connector from "../connector"
import display from "../display"
import container from "../container"
import entropy from "../entropy"
import events from "../events"
import input from "../input"
import links from "../links"
import net from "../net"
import partitions from "../partitions"
import platform from "../platform"
import power from "../power"
import powerbox from "../powerbox"
import programs from "../programs"
import prompt from "../prompt"
import rng from "../rng"
import scheduler from "../scheduler"
import seat from "../seat"
import serial from "../serial"
import session from "../session"
import storage from "../storage"
import supervision from "../supervision"
import trace from "../trace"
import update from "../update"
import volume from "../volume"
import watchdog from "../watchdog"

/** A protocol's validators, by its name. */
Judged :: struct {
    /** The protocol's package's name. */
    name : string,
    /** Its validate_request. */
    request : (fn(message: u8[], size: u32, handle_count: u32) -> os.Validity),
    /** Its validate_response. */
    response : (fn(message: u8[], size: u32, handle_count: u32) -> os.Validity),
}

/** How many protocols there are. */
PROTOCOL_COUNT :: 34
/** The most bytes a case's message has: a case reads at most testing.MAX_CASE_BYTES, its other draws among them. */
MOST_MESSAGE_BYTES :: 1000

/**
 * Give every protocol's validators.
 *
 * @return Each protocol's, by its package's name.
 */
protocols :: fn() -> Judged[PROTOCOL_COUNT] {
    return Judged.[
        Judged.{name = "accounts", request = accounts.validate_request, response = accounts.validate_response},
        Judged.{name = "block", request = block.validate_request, response = block.validate_response},
        Judged.{name = "bundle_store", request = bundle_store.validate_request, response = bundle_store.validate_response},
        Judged.{name = "clock_setting", request = clock_setting.validate_request, response = clock_setting.validate_response},
        Judged.{name = "config", request = config.validate_request, response = config.validate_response},
        Judged.{name = "connector", request = connector.validate_request, response = connector.validate_response},
        Judged.{name = "display", request = display.validate_request, response = display.validate_response},
        Judged.{name = "container", request = container.validate_request, response = container.validate_response},
        Judged.{name = "entropy", request = entropy.validate_request, response = entropy.validate_response},
        Judged.{name = "events", request = events.validate_request, response = events.validate_response},
        Judged.{name = "input", request = input.validate_request, response = input.validate_response},
        Judged.{name = "links", request = links.validate_request, response = links.validate_response},
        Judged.{name = "partitions", request = partitions.validate_request, response = partitions.validate_response},
        Judged.{name = "platform", request = platform.validate_request, response = platform.validate_response},
        Judged.{name = "power", request = power.validate_request, response = power.validate_response},
        Judged.{name = "powerbox", request = powerbox.validate_request, response = powerbox.validate_response},
        Judged.{name = "programs", request = programs.validate_request, response = programs.validate_response},
        Judged.{name = "prompt", request = prompt.validate_request, response = prompt.validate_response},
        Judged.{name = "rng", request = rng.validate_request, response = rng.validate_response},
        Judged.{name = "scheduler", request = scheduler.validate_request, response = scheduler.validate_response},
        Judged.{name = "seat", request = seat.validate_request, response = seat.validate_response},
        Judged.{name = "serial", request = serial.validate_request, response = serial.validate_response},
        Judged.{name = "session", request = session.validate_request, response = session.validate_response},
        Judged.{name = "storage", request = storage.validate_request, response = storage.validate_response},
        Judged.{name = "supervision", request = supervision.validate_request, response = supervision.validate_response},
        Judged.{name = "trace", request = trace.validate_request, response = trace.validate_response},
        Judged.{name = "update", request = update.validate_request, response = update.validate_response},
        Judged.{name = "volume", request = volume.validate_request, response = volume.validate_response},
        Judged.{name = "watchdog", request = watchdog.validate_request, response = watchdog.validate_response},
        Judged.{name = "net", request = net.validate_request, response = net.validate_response},
        Judged.{name = "network", request = network.validate_request, response = network.validate_response},
        Judged.{name = "tcp_stream", request = tcp_stream.validate_request, response = tcp_stream.validate_response},
        Judged.{name = "tcp_listener", request = tcp_listener.validate_request, response = tcp_listener.validate_response},
        Judged.{name = "datagrams", request = datagrams.validate_request, response = datagrams.validate_response},
    ]
}

/**
 * Check that any bytes, as a message of any protocol's requests or responses, with any number of handles, are judged
 * without reading outside them, and judged the same way again. The message is in a buffer of words, as os.Incoming
 * keeps one, aligned for any field, and given as exactly its bytes, so a read past them is outside the slice.
 *
 * @param t The test's state.
 * @param source The case's source: the protocol, the side, the handle count and the bytes.
 * @return Ok.
 */
any_bytes_are_judged_without_reading_outside_them #test :: fn(t: ptr[mut testing.T], source: ptr[mut testing.Source]) -> testing.Outcome {
    all :: protocols()
    index :: cast[usize](testing.draw_below(source, PROTOCOL_COUNT))
    if index >= all.count {
        return .Ok
    }
    judged :: all[index]
    response :: testing.draw_bool(source)
    handle_count :: cast[u32](testing.draw_below(source, cast[u64](slop_os.MAX_HANDLES_PER_BATCH) + 1))
    drawn :: testing.draw_bytes(source, MOST_MESSAGE_BYTES)
    words : u64[(MOST_MESSAGE_BYTES + 7) / 8]
    storage :: bit_cast[mut u8[]](usize.[words.count * 8, cast[usize](cast[uintptr](&words[0]))])
    for byte, i in drawn {
        if i < storage.count {
            storage[i] = byte
        }
    }
    if drawn.count > storage.count {
        return .Ok
    }
    message :: storage[0..<drawn.count]
    validate :: if response { judged.response } else { judged.request }
    first :: validate(message, cast[u32](message.count), handle_count)
    second :: validate(message, cast[u32](message.count), handle_count)
    testing.expect(t, first == second, "the same bytes are judged the same way again")
    return .Ok
}

/** Each handle a message carries is named by one of its fields, once: none left over, none named twice. */
handles_are_each_named_once #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    // Dialed names one handle, by its index in the batch, 0; Unavailable names none
    dialed := os.Outgoing.{}
    answer :: os.begin[connector.Response](&dialed)
    answer^ = .Dialed(cast[slop_os.Channel](0))
    message :: bytes_of(&dialed)
    testing.expect(t, connector.validate_response(message, cast[u32](message.count), 1) == .Valid, "one handle, named")
    testing.expect(t, connector.validate_response(message, cast[u32](message.count), 2) == .Invalid, "a second, named by nothing")
    testing.expect(t, connector.validate_response(message, cast[u32](message.count), 0) == .Invalid, "a handle named that didn't come")
    unavailable := os.Outgoing.{}
    none :: os.begin[connector.Response](&unavailable)
    none^ = .Unavailable
    empty :: bytes_of(&unavailable)
    testing.expect(t, connector.validate_response(empty, cast[u32](empty.count), 0) == .Valid, "no handles, none named")
    testing.expect(t, connector.validate_response(empty, cast[u32](empty.count), 1) == .Invalid, "a handle with a message naming none")
    return .Ok
}

/** A message being built, as the bytes it'd be sent as. */
bytes_of :: fn(out: ptr[os.Outgoing]) -> u8[] {
    return bit_cast[u8[]](usize.[cast[usize](out.used), cast[usize](cast[uintptr](&out.words[0]))])
}
