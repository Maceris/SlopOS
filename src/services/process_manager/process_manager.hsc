/*
 * The process manager (decisions/0012, 0058, 0067, 0071): loads programs into processes their requesters
 * made, which stay theirs and are paid for by them, and keeps nothing of what it builds, so a program
 * outlives it. Its protocol is std's (std/os/slop_os/process_manager). It serves clients, the listener the
 * root task connects through, and each connection a client sends it in a Connect; each Load gets a Response.
 * The entropy service gives each program its seed, and the randomness that places its parts.
 */
package process_manager

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import process_manager as protocol from "std/os/slop_os"
import log_line from "../../log_line"
import process_builder from "../../process_builder"
import entropy from "../../protocols/entropy"
import random_stream from "../../random_stream"
import service_kit from "../../service_kit"

Manager :: struct {
    block : ptr[slop_os.StartupBlock],
    log : slop_os.DebugLog,
    port : slop_os.Port,
    clients : service_kit.Clients,
    entropy : slop_os.Channel,
    entropy_port : slop_os.Port,
}

main :: fn(log: slop_os.DebugLog?, entropy: os.Channel[entropy.Entropy], clients: os.Listener[protocol.ProcessManager]) -> int {
    block :: slop_os.startup_block()
    manager := Manager.{block = block, entropy = entropy.end}
    manager.log = log or_else cast[slop_os.DebugLog](slop_os.NO_HANDLE)
    manager.entropy_port = os.port_for(block.budget, manager.entropy) or_return 1
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

// Every request client index has sent, until there are none left, or it's gone.
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
            case Invalid => continue
            case WrongProtocol => continue
            case Failed(error) => {
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

/*
 * One Load's answer: the program built into the requester's process, and its first thread's ID. Whatever happens,
 * the request's handles leave this process: to the program, or closed.
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
    // The executable, mapped where the manager can read it
    size :: slop_os.memory_size(request.executable) or_return .NotLoaded(.BadRequest)
    address :: runtime.reserve_addresses(cast[usize](size)) or_return .NotLoaded(.NoMemory)
    match slop_os.memory_map(request.executable, manager.block.space, address, 0, size, slop_os.PROTECTION_READ) {
        case Ok => {}
        case Error(error) => return .NotLoaded(.BadRequest)
    }
    defer _ = slop_os.memory_unmap(manager.block.space, address)
    file :: view_of(cast[ptr[u8]](address), cast[usize](size))
    grants : process_builder.Grant[protocol.MAX_GRANTS]
    for i in 0..<grant_count {
        if i < grants.count && i < request.labels.count && i < request.grants.count {
            grants[i] = process_builder.Grant.{label = request.labels[i], handle = request.grants[i]}
        }
    }
    target :: process_builder.Target.{process = request.process, space = request.space, budget = request.budget}
    match process_builder.build(target, file, view_of(&grants[0], grant_count), seed, &stream) {
        case Ok(thread) => {
            log_line.write(manager.log, "process manager: started %", name)
            return .Loaded(thread)
        }
        case Error(error) => {
            log_line.write(manager.log, "process manager: % didn't start: %", name, error)
            return .NotLoaded(if error == .NotAProgram { protocol.LoadStatus.NotAProgram } else if error == .NoMemory {
                protocol.LoadStatus.NoMemory } else { protocol.LoadStatus.Failed })
        }
    }
}

// bytes, filled from the entropy service: false if it didn't answer.
draw :: fn(manager: ptr[mut Manager], bytes: mut u8[]) -> bool {
    out := os.Outgoing.{}
    request :: os.begin[entropy.Request](&out)
    request^ = .Fill(cast[u32](bytes.count))
    match entropy.send_request(manager.entropy, manager.entropy_port, &out) {
        case Some(error) => return false
        case None => {}
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

// The request's handles still in this process's table, closed: one that went to a program is gone already.
close_all :: fn(request: ptr[protocol.Load]) {
    _ = slop_os.handle_close(cast[slop_os.Handle](request.process))
    _ = slop_os.handle_close(cast[slop_os.Handle](request.space))
    _ = slop_os.handle_close(cast[slop_os.Handle](request.budget))
    _ = slop_os.handle_close(cast[slop_os.Handle](request.executable))
    for handle in request.grants {
        _ = slop_os.handle_close(handle)
    }
}
