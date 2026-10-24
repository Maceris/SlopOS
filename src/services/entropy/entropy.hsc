/*
 * The early entropy source (decisions/0012, 0058, 0067, 0068): random bytes for the services that need more
 * than their own seed before there's a hardware RNG driver (M7), from a ChaCha20 stream seeded with the seed
 * in its startup block, which the root task draws from the boot's. Connections arrive on clients, and each
 * EntropyRequest gets as many bytes as it asks for, up to MAX_ENTROPY_BYTES.
 */
package entropy

import os from "std"
import slop_os from "std/os"
import log_line from "../../log_line"
import protocols from "../../protocols"
import random_stream from "../../random_stream"

// The port's key for clients, a connection's index; and for the listener, after them.
LISTENER_KEY : u64 : 1000

main :: fn(log: slop_os.DebugLog?, clients: os.Listener[protocols.Entropy]) -> int {
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
    signals :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    slop_os.port_bind(port, cast[slop_os.Handle](clients.end), signals, LISTENER_KEY, .Persistent) or_return 3
    connected := protocols.Clients.{}
    log_line.write(to, "entropy: serving")
    loop {
        // New connections, each a message with its end
        loop {
            request := protocols.ConnectRequest.{}
            handles : slop_os.Handle[1]
            received :: os.try_receive(clients.end, os.mut_bytes_of(&request), handles) or_break
            if received.handle_count == 1 && !protocols.add_client(&connected, port, cast[slop_os.Channel](handles[0])) {
                _ = slop_os.handle_close(handles[0])
            }
        }
        for end, i in connected.ends {
            if i >= connected.count {
                break
            }
            if cast[slop_os.Handle](end) == slop_os.NO_HANDLE {
                continue
            }
            loop {
                request := protocols.EntropyRequest.{}
                handles : slop_os.Handle[1]
                match os.try_receive(end, os.mut_bytes_of(&request), handles) {
                    case Ok(received) => answer(end, port, &stream, &request, received)
                    case Error(error) => {
                        if error != .Empty {
                            protocols.drop_client(&connected, i)
                        }
                        break
                    }
                }
            }
        }
        packets : slop_os.Packet[8]
        _ = slop_os.port_wait(port, packets, slop_os.NO_DEADLINE)
    }
}

// The reply to one request: its bytes, or none for a request that isn't one.
answer :: fn(end: slop_os.Channel, port: slop_os.Port, stream: ptr[mut random_stream.Stream], request: ptr[protocols.EntropyRequest],
    received: os.Received) {
    reply := protocols.EntropyReply.{tag = protocols.ENTROPY_FILL}
    if request.tag == protocols.ENTROPY_FILL && received.size == cast[u32](size_of(protocols.EntropyRequest)) {
        reply.count = if request.count < protocols.MAX_ENTROPY_BYTES { request.count } else { protocols.MAX_ENTROPY_BYTES }
        random_stream.fill(stream, view_of(&reply.bytes[0], cast[usize](reply.count)))
    }
    none : slop_os.Handle[1]
    _ = os.send(end, port, os.bytes_of(&reply), view_of(&none[0], 0))
}
