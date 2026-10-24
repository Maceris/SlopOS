/*
 * The process manager (decisions/0012, 0058, 0067): loads programs into processes their requesters made,
 * which stay theirs and are paid for by them, and keeps nothing of what it builds, so a program outlives
 * it. It serves each channel it was granted as "client:<name>", and each end a client sends it in a
 * PM_CONNECT; each PM_LOAD gets a LoadReply. ASLR's randomness comes from the entropy service, a fresh
 * seed for each program.
 */
package process_manager

import runtime from "base"
import slop_os from "std/os"
import log_line from "../../log_line"
import process_builder from "../../process_builder"
import protocols from "../../protocols"
import random_stream from "../../random_stream"

Manager :: struct {
    block : ptr[slop_os.StartupBlock],
    log : slop_os.DebugLog,
    port : slop_os.Port,
    clients : protocols.Clients,
    entropy : slop_os.Channel,
    entropy_port : slop_os.Port,
}

main :: fn() -> int {
    block :: slop_os.startup_block()
    manager := Manager.{block = block}
    manager.log = cast[slop_os.DebugLog](slop_os.find_grant(block, "debug_log", .DebugLog) or_else slop_os.NO_HANDLE)
    manager.entropy = cast[slop_os.Channel](slop_os.find_grant(block, "entropy", .Channel) or_return 1)
    manager.entropy_port = protocols.port_for(block.budget, manager.entropy) or_return 2
    manager.port = slop_os.port_create(block.budget) or_return 3
    protocols.add_granted_clients(&manager.clients, manager.port, block)
    log_line.write(manager.log, "process manager: serving % clients", manager.clients.count)
    loop {
        // A client added while serving is served in the same pass
        with {
            i : usize = 0
        }
        loop {
            serve(&manager, i)
            i += 1
        }
        while i < manager.clients.count
        packets : slop_os.Packet[8]
        _ = slop_os.port_wait(manager.port, packets, slop_os.NO_DEADLINE)
    }
}

// Every request client index has sent, until there are none left, or it's gone.
serve :: fn(manager: ptr[mut Manager], index: usize) {
    if index >= manager.clients.ends.count {
        return void
    }
    end :: manager.clients.ends[index]
    if cast[slop_os.Handle](end) == slop_os.NO_HANDLE {
        return void
    }
    loop {
        request := protocols.LoadRequest.{}
        handles : slop_os.Handle[slop_os.MAX_HANDLES_PER_BATCH]
        match protocols.try_receive(end, protocols.mut_bytes_of(&request), handles) {
            case Ok(received) => {
                taken :: view_of(&handles[0], cast[usize](received.handle_count))
                if request.tag == protocols.PM_CONNECT && taken.count == 1 {
                    if !protocols.add_client(&manager.clients, manager.port, cast[slop_os.Channel](taken[0])) {
                        close_all(taken)
                    }
                }
                else if request.tag == protocols.PM_LOAD {
                    reply := load(manager, &request, received, taken)
                    none : slop_os.Handle[1]
                    _ = protocols.send(end, manager.port, protocols.bytes_of(&reply), view_of(&none[0], 0))
                }
                else {
                    close_all(taken)
                }
            }
            case Error(error) => {
                if error != .Empty {
                    protocols.drop_client(&manager.clients, index)
                }
                return void
            }
        }
    }
}

/*
 * One PM_LOAD's reply: the program built into the requester's process, and its first thread's ID. Whatever
 * happens, the request's handles leave this process: to the program, or closed.
 */
load :: fn(manager: ptr[mut Manager], request: ptr[protocols.LoadRequest], received: protocols.Received, handles: slop_os.Handle[])
    -> protocols.LoadReply {
    defer close_all(handles)
    grant_count :: cast[usize](request.grant_count)
    if received.size != cast[u32](size_of(protocols.LoadRequest)) || grant_count > protocols.MAX_LOAD_GRANTS
        || handles.count != protocols.LOAD_HANDLES + grant_count {
        return failed(.BadRequest)
    }
    name :: protocols.text_of_label(&request.name)
    seed : u8[32]
    if !draw(manager, seed) {
        log_line.write(manager.log, "process manager: no randomness for %", name)
        return failed(.NoRandom)
    }
    stream := random_stream.make(seed)
    // The executable, mapped where the manager can read it
    executable :: cast[slop_os.Memory](handles[3])
    size :: slop_os.memory_size(executable) or_return failed(.BadRequest)
    address :: runtime.reserve_addresses(cast[usize](size)) or_return failed(.NoMemory)
    match slop_os.memory_map(executable, manager.block.space, address, 0, size, slop_os.PROTECTION_READ) {
        case Ok => {}
        case Error(error) => return failed(.BadRequest)
    }
    defer _ = slop_os.memory_unmap(manager.block.space, address)
    file :: view_of(cast[ptr[u8]](address), cast[usize](size))
    grants : process_builder.Grant[protocols.MAX_LOAD_GRANTS]
    for i in 0..<grant_count {
        if i < grants.count && i < request.labels.count && protocols.LOAD_HANDLES + i < handles.count {
            grants[i] = process_builder.Grant.{label = request.labels[i], handle = handles[protocols.LOAD_HANDLES + i]}
        }
    }
    target :: process_builder.Target.{
        process = cast[slop_os.Process](handles[0]),
        space = cast[slop_os.AddressSpace](handles[1]),
        budget = cast[slop_os.MemoryBudget](handles[2]),
    }
    zeros : u8[32]
    match process_builder.build(target, file, view_of(&grants[0], grant_count), zeros, &stream) {
        case Ok(thread) => {
            log_line.write(manager.log, "process manager: started %", name)
            return protocols.LoadReply.{tag = protocols.PM_LOAD, status = .Loaded, thread = thread}
        }
        case Error(error) => {
            log_line.write(manager.log, "process manager: % didn't start: %", name, error)
            return failed(if error == .NotAProgram { protocols.LoadStatus.NotAProgram } else if error == .NoMemory { protocols.LoadStatus.NoMemory }
                else { protocols.LoadStatus.Failed })
        }
    }
}

failed :: fn(status: protocols.LoadStatus) -> protocols.LoadReply {
    return protocols.LoadReply.{tag = protocols.PM_LOAD, status = status}
}

// bytes, filled from the entropy service: false if it didn't answer.
draw :: fn(manager: ptr[mut Manager], bytes: mut u8[]) -> bool {
    request := protocols.EntropyRequest.{tag = protocols.ENTROPY_FILL, count = cast[u32](bytes.count)}
    reply := protocols.EntropyReply.{}
    none : slop_os.Handle[1]
    match protocols.call(manager.entropy, manager.entropy_port, protocols.bytes_of(&request), view_of(&none[0], 0), protocols.mut_bytes_of(&reply)) {
        case Ok(received) => {
            if reply.tag != protocols.ENTROPY_FILL || cast[usize](reply.count) < bytes.count {
                return false
            }
            for &byte, i in bytes {
                if i < reply.bytes.count {
                    byte^ = reply.bytes[i]
                }
            }
            return true
        }
        case Error(error) => return false
    }
}

// Handles still in this process's table, closed: one that went to a program is gone already, and closing it fails.
close_all :: fn(handles: slop_os.Handle[]) {
    for handle in handles {
        _ = slop_os.handle_close(handle)
    }
}
