/*
 * The early entropy source (decisions/0012, 0058, 0067): random bytes for the services that need them
 * before there's a hardware RNG driver (M7), from a ChaCha20 stream seeded with the seed in its startup
 * block, which the root task draws from the boot's. It serves each channel it was granted as
 * "client:<name>", answering each EntropyRequest with as many bytes, up to MAX_ENTROPY_BYTES.
 */
package entropy

import slop_os from "std/os"
import log_line from "../../log_line"
import protocols from "../../protocols"
import random_stream from "../../random_stream"

main :: fn() -> int {
    block :: slop_os.startup_block()
    log :: cast[slop_os.DebugLog](slop_os.find_grant(block, "debug_log", .DebugLog) or_else slop_os.NO_HANDLE)
    seeded := false
    for byte in block.seed {
        seeded = seeded || byte != 0
    }
    if !seeded {
        log_line.write(log, "entropy: no seed")
        return 1
    }
    stream := random_stream.make(block.seed)
    port :: slop_os.port_create(block.budget) or_return 2
    clients := protocols.Clients.{}
    protocols.add_granted_clients(&clients, port, block)
    log_line.write(log, "entropy: serving % clients", clients.count)
    loop {
        for end, i in clients.ends {
            if i >= clients.count {
                break
            }
            if cast[slop_os.Handle](end) == slop_os.NO_HANDLE {
                continue
            }
            loop {
                request := protocols.EntropyRequest.{}
                handles : slop_os.Handle[1]
                match protocols.try_receive(end, protocols.mut_bytes_of(&request), handles) {
                    case Ok(received) => answer(end, port, &stream, &request, received)
                    case Error(error) => {
                        if error != .Empty {
                            protocols.drop_client(&clients, i)
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
    received: protocols.Received) {
    reply := protocols.EntropyReply.{tag = protocols.ENTROPY_FILL}
    if request.tag == protocols.ENTROPY_FILL && received.size == cast[u32](size_of(protocols.EntropyRequest)) {
        reply.count = if request.count < protocols.MAX_ENTROPY_BYTES { request.count } else { protocols.MAX_ENTROPY_BYTES }
        random_stream.fill(stream, view_of(&reply.bytes[0], cast[usize](reply.count)))
    }
    none : slop_os.Handle[1]
    _ = protocols.send(end, port, protocols.bytes_of(&reply), view_of(&none[0], 0))
}
