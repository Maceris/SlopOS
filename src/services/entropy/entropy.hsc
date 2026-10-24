/*
 * The early entropy source (decisions/0012, 0058, 0067, 0071): random bytes for the services that need more
 * than their own seed before there's a hardware RNG driver (7c), from a ChaCha20 stream seeded with the seed
 * in its startup block, which the root task draws from the boot's. Connections arrive on clients, its listener,
 * and each Fill gets as many bytes as it asks for, up to MAX_BYTES.
 */
package entropy

import os from "std"
import slop_os from "std/os"
import log_line from "../../log_line"
import entropy as protocol from "../../protocols/entropy"
import random_stream from "../../random_stream"
import service_kit from "../../service_kit"

main :: fn(log: slop_os.DebugLog?, clients: os.Listener[protocol.Entropy]) -> int {
    block :: slop_os.startup_block()
    to :: log or_else cast[slop_os.DebugLog](slop_os.NO_HANDLE)
    seeded := false
    for byte in block.seed {
        seeded = seeded || byte != 0
    }
    if !seeded {
        log_line.write(to, "entropy: no seed")
        return 1
    }
    stream := random_stream.make(block.seed)
    port :: slop_os.port_create(block.budget) or_return 2
    // The listener is a client like any, which sends only Connects
    connected := service_kit.Clients.{}
    if !service_kit.add_client(&connected, port, clients.end) {
        return 3
    }
    log_line.write(to, "entropy: serving")
    into := os.Incoming.{}
    loop {
        // A client added while serving is served in the same pass
        with {
            i : usize = 0
        }
        loop {
            serve(&connected, i, port, &stream, &into)
            i += 1
        }
        while i < connected.count
        packets : slop_os.Packet[8]
        _ = slop_os.port_wait(port, packets, slop_os.NO_DEADLINE)
    }
}

// Every request client index has sent, until there are none left, or it's gone.
serve :: fn(connected: ptr[mut service_kit.Clients], index: usize, port: slop_os.Port, stream: ptr[mut random_stream.Stream],
    into: ptr[mut os.Incoming]) {
    if index >= connected.ends.count {
        return void
    }
    end :: connected.ends[index]
    if cast[slop_os.Handle](end) == slop_os.NO_HANDLE {
        return void
    }
    loop {
        match protocol.receive_request(end, port, into, false) {
            case Received => {}
            case Empty => return void
            case Unsupported => {
                _ = protocol.answer_unsupported(end, port)
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
                random_stream.fill(stream, filled)
                out := os.Outgoing.{}
                response :: os.begin[protocol.Response](&out)
                response^ = .Filled(os.append(&out, filled))
                _ = protocol.send_response(end, port, &out)
            }
            case Connect(connection) => {
                if !service_kit.add_client(connected, port, connection.end) {
                    _ = slop_os.handle_close(cast[slop_os.Handle](connection.end))
                }
            }
        }
    }
}
