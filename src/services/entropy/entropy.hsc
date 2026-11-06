/**
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
import service_kit from "../../libraries/service_kit"

/**
 * The most hardware sources the service takes in its life; an AddSource past this many has its channel closed. A
 * source that goes away keeps its place, so it isn't given to another.
 */
MAX_SOURCES :: 4
/**
 * The port key of the first source, the source at index i bound with SOURCE_KEY + i; clients are bound with keys
 * below it, their indices in service_kit's table.
 */
SOURCE_KEY : u64 : 1000
/** How many bytes each Read asks a source for, and the most of its answer that's mixed in: a ChaCha20 key's 32. */
SEED_BYTES : u32 : 32
/** How many bytes are handed out to clients, 64 KiB, before every source is read again to reseed the stream. */
RESEED_BYTES : u64 : 64 * 1024

/** The service's state, all of it main's, kept for its life. */
Entropy :: struct {
    /** Where its lines go, or NO_HANDLE when it wasn't given a log, so lines go nowhere. */
    log : slop_os.DebugLog,
    /** The ChaCha20 stream every Fill draws from, seeded from the startup block and reseeded from sources. */
    stream : random_stream.Stream,
    /** The one port every client and source is bound to, waited on between passes. */
    port : slop_os.Port,
    /**
     * The sources' channels, the service's own, in the order they were added; one gone is NO_HANDLE, its place not
     * reused.
     */
    sources : slop_os.Channel[MAX_SOURCES],
    /** How many of sources have been used, from the first: 0 to MAX_SOURCES. */
    source_count : usize,
    /** Bytes handed out since the sources were last read, reset to 0 when it reaches RESEED_BYTES. */
    handed_out : u64,
}

/**
 * Serve random bytes to the system's services, from a stream seeded with the boot's seed.
 *
 * The program runs until the system stops, answering each client's Fill and reseeding from any hardware source a
 * driver adds. It exits at once if its startup block's seed is all zeros, since a stream from that would be
 * predictable.
 *
 * @param log The debug log it writes its lines to: that it's serving, each reseed, and why it stopped. Without one,
 *     it writes nothing.
 * @param clients The listener new clients' connections arrive on, from the root task; it's served as a client, its
 *     Connects each adding a client, up to service_kit's MAX_CLIENTS at once.
 * @return 1 when the startup block's seed is all zeros, 2 when no port could be made, 3 when the listener couldn't
 *     be bound to it; it doesn't return otherwise.
 */
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

/**
 * Answer every request one client has sent, until none is left or the client's gone.
 *
 * A Fill is answered at once with min(count, protocol.MAX_BYTES) bytes from the stream; when that brings the bytes
 * handed out to RESEED_BYTES, every source is asked for more. A Connect adds its channel as a client, closing it when
 * the table's full. An AddSource adds its channel as a source. An unknown request is answered Unsupported; an invalid
 * one is skipped.
 *
 * @param service The service, whose stream and sources change.
 * @param connected The clients; a client whose channel failed is dropped, its channel closed and its place freed.
 * @param index Which client, an index in connected; one past its end, or a freed place, is nothing to serve.
 * @param into Where each request is received, reused for each and left holding the last.
 */
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
            case _ => {
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

/**
 * Take a hardware RNG's driver's channel as a source: bind it to the port and ask it for SEED_BYTES at once.
 *
 * @param service The service, which keeps the channel in sources when it's taken: in the slot of a source that's
 *     gone, or else the next one.
 * @param end The driver's channel, which moves to the service: kept as a source, or closed when MAX_SOURCES are
 *     already taken or it can't be bound.
 */
add_source :: fn(service: ptr[mut Entropy], end: slop_os.Channel) {
    index := service.source_count
    for i in 0..<service.source_count {
        if i < service.sources.count && cast[slop_os.Handle](service.sources[i]) == slop_os.NO_HANDLE {
            index = i
            break
        }
    }
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
    if index == service.source_count {
        service.source_count = index + 1
    }
    ask(service, index)
}

/**
 * Ask a source for SEED_BYTES with a Read, without waiting; its answer is taken by take_bytes.
 *
 * @param service The service, whose port the answer will wake.
 * @param index Which source; one out of range, or one gone, is skipped. A send that fails is ignored, the source's
 *     loss found when it's next read.
 */
ask :: fn(service: ptr[mut Entropy], index: usize) {
    if index >= service.sources.count || cast[slop_os.Handle](service.sources[index]) == slop_os.NO_HANDLE {
        return void
    }
    out := os.Outgoing.{}
    request :: os.begin[rng.Request](&out)
    request^ = .Read(SEED_BYTES)
    _ = rng.send_request(service.sources[index], service.port, &out)
}

/**
 * Mix every answer a source has sent into the stream, until none is left; close a source that's gone.
 *
 * Each Bytes answer reseeds the stream with its own next 32 bytes XORed with the answer's first 32, so the stream is
 * never less unpredictable than it was; bytes past 32 are ignored, and fewer leave the rest of the key the stream's.
 * An Unsupported answer is ignored.
 *
 * @param service The service, whose stream is reseeded and whose source is cleared to NO_HANDLE when gone.
 * @param index Which source; one out of range, or one gone, is skipped.
 * @param into Where each answer is received, reused for each.
 */
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
            case _ => {
                // Its slot and key free for the next source added
                _ = slop_os.port_unbind(service.port, SOURCE_KEY + cast[u64](index))
                _ = slop_os.handle_close(cast[slop_os.Handle](end))
                service.sources[index] = cast[slop_os.Channel](slop_os.NO_HANDLE)
                return void
            }
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
