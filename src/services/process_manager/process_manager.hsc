/**
 * The process manager (decisions/0012, 0058, 0067, 0071): loads programs into processes their requesters
 * made, which stay theirs and are paid for by them, and keeps nothing of what it builds, so a program
 * outlives it. Its protocol is std's (std/os/slop_os/process_manager). It serves clients, the listener the
 * root task connects through, and each connection a client sends it in a Connect; each Load gets a Response.
 * The entropy service gives each program its seed, and the randomness that places its parts; it's reached through a
 * connector the root task serves, and dialed again if it's started again (decisions/0140).
 */
package process_manager

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import process_manager as protocol from "std/os/slop_os"
import log_line from "../../log_line"
import process_builder from "../../process_builder"
import entropy from "../../protocols/entropy"
import connector from "../../protocols/connector"
import random_stream from "../../random_stream"
import service_kit from "../../libraries/service_kit"

/** The manager's state, all of it main's, kept for its life. */
Manager :: struct {
    /** The process's startup block, for its budget and address space, which the manager's own work is paid from. */
    block : ptr[slop_os.StartupBlock],
    /** Where its lines go, or NO_HANDLE when it wasn't given a log, so lines go nowhere. */
    log : slop_os.DebugLog,
    /** The port every client is bound to, waited on between passes. */
    port : slop_os.Port,
    /** The clients: the listener, and each connection a Connect brought. */
    clients : service_kit.Clients,
    /** The connection to the entropy service, the manager's own, or NO_HANDLE before the first dial. */
    entropy : slop_os.Channel,
    /** A port bound to entropy alone, waited on for its answers; replaced with entropy on each dial. */
    entropy_port : slop_os.Port,
    /** The connector the entropy service is dialed through, served by the root task; the manager's own. */
    entropy_connector : slop_os.Channel,
    /** A port bound to entropy_connector alone, waited on for the connector's answers. */
    connector_port : slop_os.Port,
    /** Where the builder stages each program it loads, kept so loading one after another doesn't use up its addresses. */
    staging : process_builder.Staging,
}

/**
 * Load programs into processes other programs make, for the root task, the supervisor and whoever else is given it.
 *
 * The program runs until the system stops. A requester makes the process, its address space and its budget, and
 * hands them over with the executable and the program's grants in a Load; the manager builds the program in, starts
 * its first thread, and keeps none of it, so the program is the requester's and outlives the manager.
 *
 * @param log The debug log it writes its lines to: that it's serving, and each program started or not. Without one,
 *     it writes nothing.
 * @param entropy The connector the entropy service is reached through, from the root task; each program's seed is
 *     drawn from it. It's dialed once at start, and again whenever the service has gone.
 * @param clients The listener new clients' connections arrive on, from the root task; it's served as a client, its
 *     Connects each adding a client, up to service_kit's MAX_CLIENTS at once.
 * @return 1 when the entropy service can't be reached at start, 2 when no port could be made, 3 when the listener
 *     couldn't be bound to it; it doesn't return otherwise.
 */
main :: fn(log: slop_os.DebugLog?, entropy: os.Channel[connector.Connector], clients: os.Listener[protocol.ProcessManager]) -> int {
    block :: slop_os.startup_block()
    manager := Manager.{block = block, entropy_connector = entropy.end, entropy = cast[slop_os.Channel](slop_os.NO_HANDLE)}
    manager.log = log or_else cast[slop_os.DebugLog](slop_os.NO_HANDLE)
    manager.connector_port = os.port_for(block.budget, manager.entropy_connector) or_return 1
    if !dial_entropy(&manager) {
        return 1
    }
    manager.port = slop_os.port_create(block.budget) or_return 2
    // The listener is a client like any, whose requests are connections or loads
    if !service_kit.add_client(&manager.clients, manager.port, clients.end) {
        return 3
    }
    log_line.write(manager.log, "process manager: serving")
    into := os.Incoming.{}
    loop {
        // A client added while serving is served in the same pass
        with {
            i : usize = 0
        }
        loop {
            serve(&manager, i, &into)
            i += 1
        }
        while i < manager.clients.count
        packets : slop_os.Packet[8]
        _ = slop_os.port_wait(manager.port, packets, slop_os.NO_DEADLINE)
    }
}

/**
 * Answer every request one client has sent, until none is left or the client's gone.
 *
 * Each Load is answered with load's Response, the client waiting while the entropy service is asked. A Connect adds
 * its channel as a client, closing it when the table's full. An unknown request is answered Unsupported; an invalid one
 * is skipped.
 *
 * @param manager The manager; a client whose channel failed is dropped, its channel closed and its place freed.
 * @param index Which client, an index in manager.clients; one past its end, or a freed place, is nothing to serve.
 * @param into Where each request is received, reused for each and left holding the last.
 */
serve :: fn(manager: ptr[mut Manager], index: usize, into: ptr[mut os.Incoming]) {
    if index >= manager.clients.ends.count {
        return void
    }
    end :: manager.clients.ends[index]
    if cast[slop_os.Handle](end) == slop_os.NO_HANDLE {
        return void
    }
    loop {
        match protocol.receive_request(end, manager.port, into, false) {
            case Received => {}
            case Empty => return void
            case Unsupported => {
                _ = protocol.answer_unsupported(end, manager.port)
                continue
            }
            case _ => {
                service_kit.drop_client(&manager.clients, index)
                return void
            }
        }
        match os.message_of[protocol.Request](into)^ {
            case Load(request) => {
                loading := request
                out := os.Outgoing.{}
                response :: os.begin[protocol.Response](&out)
                response^ = load(manager, &loading)
                _ = protocol.send_response(end, manager.port, &out)
            }
            case Connect(connection) => {
                if !service_kit.add_client(&manager.clients, manager.port, connection.end) {
                    _ = slop_os.handle_close(cast[slop_os.Handle](connection.end))
                }
            }
        }
    }
}

/** The largest executable the manager copies to build from, in bytes: 4 MiB, half its budget. */
MAX_EXECUTABLE : u64 : 4 << 20

/**
 * Build a Load's program into the requester's process and start its first thread.
 *
 * 64 bytes are drawn from the entropy service: the first 32 the program's seed, for its startup block, the rest the
 * seed of the stream that places its parts. The executable is copied to the manager's heap, through memory_read, to
 * be built from, and freed after; only the new process maps it. Whatever happens, the request's handles leave this process: to the program, or closed; when it fails, the
 * process, space and budget are the requester's to destroy.
 *
 * @param manager The manager, whose entropy connection may be dialed again.
 * @param request The Load, whose handles are all gone from this process when it returns.
 * @return Loaded with the first thread's ID and the image's address; or NotLoaded with BadRequest for more than MAX_GRANTS grants or an
 *     executable that's empty, larger than MAX_EXECUTABLE, or can't be read (its memory gone), NoRandom when the
 *     entropy service doesn't answer even when dialed again, NoMemory when the heap can't hold its copy or the build
 *     ran out, NotAProgram when it isn't an
 *     executable the loader takes, and Failed for any other failure building it.
 */
load :: fn(manager: ptr[mut Manager], request: ptr[protocol.Load]) -> protocol.Response {
    defer close_all(request)
    grant_count :: cast[usize](request.grant_count)
    if grant_count > protocol.MAX_GRANTS {
        return .NotLoaded(.BadRequest)
    }
    name :: service_kit.text_of_label(&request.name)
    // The program's own seed, and one for where its parts go
    seeds : u8[64]
    if !draw(manager, seeds) {
        log_line.write(manager.log, "process manager: no randomness for %", name)
        return .NotLoaded(.NoRandom)
    }
    seed : u8[32]
    layout_seed : u8[32]
    for byte, i in seeds {
        if i < 32 {
            seed[i] = byte
        }
        else if i - 32 < layout_seed.count {
            layout_seed[i - 32] = byte
        }
    }
    stream := random_stream.make(layout_seed)
    /*
     * The executable, copied for the manager to read (decisions/0098, 0181's F6): it's the requester's, or the bundle
     * store's paged memory, either of which may end meanwhile, which a copy makes BadRequest, not the manager's fault
     */
    size :: slop_os.memory_size(request.executable) or_return .NotLoaded(.BadRequest)
    if size == 0 || size > MAX_EXECUTABLE {
        return .NotLoaded(.BadRequest)
    }
    file, made :: runtime.new_array(u8, cast[usize](size))
    if made != null {
        return .NotLoaded(.NoMemory)
    }
    defer runtime.free_array(file)
    if !service_kit.read_pages(request.executable, 0, file) {
        return .NotLoaded(.BadRequest)
    }
    grants : process_builder.Grant[protocol.MAX_GRANTS]
    for i in 0..<grant_count {
        if i < grants.count && i < request.labels.count && i < request.grants.count {
            grants[i] = process_builder.Grant.{label = request.labels[i], handle = request.grants[i]}
        }
    }
    target :: process_builder.Target.{process = request.process, space = request.space, budget = request.budget}
    match process_builder.build(target, file, view_of(&grants[0], grant_count), seed, &stream, request.executable, slop_os.ABI_VERSION,
        &manager.staging) {
        case Ok(built) => {
            log_line.write(manager.log, "process manager: started %", name)
            return .Loaded(protocol.Started.{thread = built.thread, image = built.image})
        }
        case Error(error) => {
            log_line.write(manager.log, "process manager: % didn't start: %", name, error)
            return .NotLoaded(if error == .NotAProgram { protocol.LoadStatus.NotAProgram } else if error == .NoMemory {
                protocol.LoadStatus.NoMemory } else { protocol.LoadStatus.Failed })
        }
    }
}

/**
 * Dial the entropy service through its connector, in place of the connection there was, which is closed.
 *
 * connector.dial tries again while the service is restarting, so this may wait some seconds.
 *
 * @param manager The manager, whose entropy and entropy_port are replaced.
 * @return Whether there's a connection now: false when the connector didn't give one that speaks the entropy
 *     protocol, or no port could be made for it.
 */
dial_entropy :: fn(manager: ptr[mut Manager]) -> bool {
    if cast[slop_os.Handle](manager.entropy) != slop_os.NO_HANDLE {
        _ = slop_os.handle_close(cast[slop_os.Handle](manager.entropy))
        _ = slop_os.handle_close(cast[slop_os.Handle](manager.entropy_port))
        manager.entropy = cast[slop_os.Channel](slop_os.NO_HANDLE)
    }
    connection :: connector.dial[entropy.Entropy](manager.entropy_connector, manager.connector_port) or_return false
    manager.entropy = connection.end
    manager.entropy_port = os.port_for(manager.block.budget, manager.entropy) or_return false
    return true
}

/**
 * Fill bytes from the entropy service, dialing it again once if the first try fails.
 *
 * @param manager The manager, whose entropy connection may be replaced.
 * @param bytes Where the bytes go, all of it; at most the entropy protocol's MAX_BYTES (256), since the service gives
 *     no more and fewer fails.
 * @return Whether bytes were all filled; false when the service didn't answer with enough even after a new dial,
 *     bytes then unchanged.
 */
draw :: fn(manager: ptr[mut Manager], bytes: mut u8[]) -> bool {
    if draw_once(manager, bytes) {
        return true
    }
    return dial_entropy(manager) && draw_once(manager, bytes)
}

/**
 * Ask the entropy service for bytes once, and wait for its answer.
 *
 * @param manager The manager, whose entropy connection is used as it is.
 * @param bytes Where the bytes go, all of it.
 * @return Whether the service answered with at least bytes' count; false when sending or receiving failed, or the
 *     answer was another or too short, bytes then unchanged.
 */
draw_once :: fn(manager: ptr[mut Manager], bytes: mut u8[]) -> bool {
    out := os.Outgoing.{}
    request :: os.begin[entropy.Request](&out)
    request^ = .Fill(cast[u32](bytes.count))
    if entropy.send_request(manager.entropy, manager.entropy_port, &out) is_some {
        return false
    }
    into := os.Incoming.{}
    match entropy.receive_response(manager.entropy, manager.entropy_port, &into, true) {
        case Received => {}
        case _ => return false
    }
    match os.message_of[entropy.Response](&into)^ {
        case Filled(data) => {
            given :: os.items(&into, data)
            if given.count < bytes.count {
                return false
            }
            for &byte, i in bytes {
                if i < given.count {
                    byte^ = given[i]
                }
            }
            return true
        }
        case _ => return false
    }
}

/**
 * Close the request's handles still in this process's table: its process, space, budget, executable and grants.
 *
 * One that went to the program is gone from the table already, so closing it fails, harmlessly.
 *
 * @param request The Load, whose handle fields are left as they were, naming nothing of this process's now.
 */
close_all :: fn(request: ptr[protocol.Load]) {
    _ = slop_os.handle_close(cast[slop_os.Handle](request.process))
    _ = slop_os.handle_close(cast[slop_os.Handle](request.space))
    _ = slop_os.handle_close(cast[slop_os.Handle](request.budget))
    _ = slop_os.handle_close(cast[slop_os.Handle](request.executable))
    for handle in request.grants {
        _ = slop_os.handle_close(handle)
    }
}
