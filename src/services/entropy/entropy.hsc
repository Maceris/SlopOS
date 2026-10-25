/*
 * The entropy service (decisions/0012, 0058, 0067, 0071, 0074): random bytes for the services that need more than their
 * own seed, from a ChaCha20 stream seeded with the seed in its startup block, which the root task draws from the
 * boot's. Connections arrive on clients, its listener, and each Fill gets as many bytes as it asks for, up to
 * MAX_BYTES.
 *
 * Hardware RNGs' drivers offer themselves with AddSource. A source is read when it's added, and again each time
 * RESEED_BYTES more have been handed out; what it gives is mixed in, the stream reseeded with its own next 32 bytes
 * XORed with the source's, so a source can add to the stream's unpredictability but never take from it.
 */
package entropy

import os from "std"
import slop_os from "std/os"
import log_line from "../../log_line"
import entropy as protocol from "../../protocols/entropy"
import rng from "../../protocols/rng"
import random_stream from "../../random_stream"
import service_kit from "../../service_kit"

MAX_SOURCES :: 4
// Sources are bound to the port from here on, clients below
SOURCE_KEY : u64 : 1000
SEED_BYTES : u32 : 32
RESEED_BYTES : u64 : 64 * 1024

Entropy :: struct {
    log : slop_os.DebugLog,
    stream : random_stream.Stream,
    port : slop_os.Port,
    sources : slop_os.Channel[MAX_SOURCES],
    source_count : usize,
    // Bytes handed out since the sources were last read
    handed_out : u64,
}

main :: fn(log: slop_os.DebugLog?, clients: os.Listener[protocol.Entropy]) -> int {
    block :: slop_os.startup_block()
    service := Entropy.{log = log or_else cast[slop_os.DebugLog](slop_os.NO_HANDLE)}
    seeded := false
    for byte in block.seed {
        seeded = seeded || byte != 0
    }
    if !seeded {
        log_line.write(service.log, "entropy: no seed")
        return 1
    }
    service.stream = random_stream.make(block.seed)
    service.port = slop_os.port_create(block.budget) or_return 2
    // The listener is a client like any, which sends only Connects
    connected := service_kit.Clients.{}
    if !service_kit.add_client(&connected, service.port, clients.end) {
        return 3
    }
    log_line.write(service.log, "entropy: serving")
    into := os.Incoming.{}
    loop {
        // A client added while serving is served in the same pass
        with {
            i : usize = 0
        }
        loop {
            serve(&service, &connected, i, &into)
            i += 1
        }
        while i < connected.count
        for source in 0..<service.source_count {
            take_bytes(&service, source, &into)
        }
        packets : slop_os.Packet[8]
        _ = slop_os.port_wait(service.port, packets, slop_os.NO_DEADLINE)
    }
}

// Every request client index has sent, until there are none left, or it's gone.
serve :: fn(service: ptr[mut Entropy], connected: ptr[mut service_kit.Clients], index: usize, into: ptr[mut os.Incoming]) {
    if index >= connected.ends.count {
        return void
    }
    end :: connected.ends[index]
    if cast[slop_os.Handle](end) == slop_os.NO_HANDLE {
        return void
    }
    loop {
        match protocol.receive_request(end, service.port, into, false) {
            case Received => {}
            case Empty => return void
            case Unsupported => {
                _ = protocol.answer_unsupported(end, service.port)
                continue
            }
            case Invalid => continue
            case WrongProtocol => continue
            case Failed(error) => {
                service_kit.drop_client(connected, index)
                return void
            }
        }
        match os.message_of[protocol.Request](into)^ {
            case Fill(count) => {
                bytes : u8[protocol.MAX_BYTES]
                filled :: view_of(&bytes[0], cast[usize](if count < protocol.MAX_BYTES { count } else { protocol.MAX_BYTES }))
                random_stream.fill(&service.stream, filled)
                out := os.Outgoing.{}
                response :: os.begin[protocol.Response](&out)
                response^ = .Filled(os.append(&out, filled))
                _ = protocol.send_response(end, service.port, &out)
                service.handed_out += cast[u64](filled.count)
                if service.handed_out >= RESEED_BYTES {
                    service.handed_out = 0
                    for source in 0..<service.source_count {
                        ask(service, source)
                    }
                }
            }
            case Connect(connection) => {
                if !service_kit.add_client(connected, service.port, connection.end) {
                    _ = slop_os.handle_close(cast[slop_os.Handle](connection.end))
                }
            }
            case AddSource(source) => add_source(service, source.end)
        }
    }
}

// A hardware RNG's driver's channel, bound to the port, read at once.
add_source :: fn(service: ptr[mut Entropy], end: slop_os.Channel) {
    index :: service.source_count
    signals :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    if index >= service.sources.count {
        _ = slop_os.handle_close(cast[slop_os.Handle](end))
        return void
    }
    match slop_os.port_bind(service.port, cast[slop_os.Handle](end), signals, SOURCE_KEY + cast[u64](index), .Persistent) {
        case Ok => {}
        case Error(error) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](end))
            return void
        }
    }
    service.sources[index] = end
    service.source_count = index + 1
    ask(service, index)
}

// A Read of SEED_BYTES from a source, answered later.
ask :: fn(service: ptr[mut Entropy], index: usize) {
    if index >= service.sources.count || cast[slop_os.Handle](service.sources[index]) == slop_os.NO_HANDLE {
        return void
    }
    out := os.Outgoing.{}
    request :: os.begin[rng.Request](&out)
    request^ = .Read(SEED_BYTES)
    _ = rng.send_request(service.sources[index], service.port, &out)
}

// What a source has answered, mixed into the stream; a source that's gone, closed.
take_bytes :: fn(service: ptr[mut Entropy], index: usize, into: ptr[mut os.Incoming]) {
    if index >= service.sources.count {
        return void
    }
    end :: service.sources[index]
    if cast[slop_os.Handle](end) == slop_os.NO_HANDLE {
        return void
    }
    loop {
        match rng.receive_response(end, service.port, into, false) {
            case Received => {}
            case Empty => return void
            case Failed(error) => {
                _ = slop_os.handle_close(cast[slop_os.Handle](end))
                service.sources[index] = cast[slop_os.Channel](slop_os.NO_HANDLE)
                return void
            }
            case _ => continue
        }
        match os.message_of[rng.Response](into)^ {
            case Bytes(given) => {
                bytes :: os.items(into, given)
                seed : u8[32]
                random_stream.fill(&service.stream, seed)
                for byte, i in bytes {
                    if i < seed.count {
                        seed[i] ~= byte
                    }
                }
                service.stream = random_stream.make(seed)
                log_line.write(service.log, "entropy: reseeded from a hardware source, % bytes", bytes.count)
            }
            case Unsupported => {}
        }
    }
}
