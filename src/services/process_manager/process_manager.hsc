/**
 * The process manager (decisions/0012, 0058, 0067, 0071, 0195): makes a process for each program it loads, paid for by
 * the requester's budget, and gives the requester its owning handle, so a program is the requester's and outlives the
 * manager; but with the rights to watch it and end it, and to read it only where the Load asks, never to start
 * threads in it or give it handles, which only the manager does, as it builds it (18a). Its protocol is std's (std/os/slop_os/process_manager). It serves clients, the listener the
 * root task connects through, and each connection a client sends it in a Connect; each Load gets a Response.
 * The entropy service gives each program its seed, and the randomness that places its parts; it's reached through a
 * connector the root task serves, and dialed again if it's started again (decisions/0140).
 */
package process_manager

import runtime from "base:runtime"
import os from "std:os"
import slop_os from "std:os/slop_os"
import process_manager as protocol from "std:os/slop_os/process_manager"
import service_kit from "../../libraries/service_kit"
import log_line from "../../log_line"
import process_builder from "../../process_builder"
import connector from "../../protocols/connector"
import entropy from "../../protocols/entropy"
import random_stream from "../../random_stream"

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
    /**
     * Where the builder stages each program it loads, kept so loading one after another doesn't use up its addresses.
     */
    staging : process_builder.Staging,
    /**
     * With profile_boot on the command line, where each program's image went is logged too, for the boot's profile
     * (decisions/0194, T3).
     */
    profile : bool,
}

/**
 * Load programs into processes it makes, for the root task, the supervisor and whoever else is given it.
 *
 * The program runs until the system stops. A requester hands over its budget, the executable and the program's grants
 * in a Load; the manager makes its process and address space from the budget, builds the program in, starts its first
 * thread, and gives the requester the process's owning handle, its rights cut to what a launcher may have.
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
main :: fn(
    log : slop_os.DebugLog?,
    entropy : os.Channel[connector.Connector],
    clients : os.Listener[protocol.ProcessManager],
    command_line : slop_os.Memory?
) -> int {
    block :: slop_os.startup_block()
    manager := Manager.{
        block = block,
        entropy_connector = entropy.end,
        entropy = cast[slop_os.Channel](slop_os.NO_HANDLE),
    }
    match command_line {
        case Some(memory) => {
            words :: service_kit.text_of(block, memory) or_else ""
            manager.profile = service_kit.has_word(words, "profile_boot")
        }
        case None => {}
    }
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
serve :: fn(manager : ptr[mut Manager], index : usize, into : ptr[mut os.Incoming]) {
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
                /*
                 * Not sent, the program's handles are still the manager's: closed, which ends the program. A program
                 * that's ended already can't have its handles moved, so it's answered again without them: its end was
                 * reported on its watch
                 */
                if protocol.send_response(end, manager.port, &out) is_some {
                    match response^ {
                        case Loaded(started) => {
                            close_started(started)
                            ended := started
                            ended.process = cast[slop_os.Process](slop_os.NO_HANDLE)
                            ended.intercept = cast[slop_os.Intercept](slop_os.NO_HANDLE)
                            ended.space = cast[slop_os.AddressSpace](slop_os.NO_HANDLE)
                            again := os.Outgoing.{}
                            os.begin[protocol.Response](&again)^ = .Loaded(ended)
                            _ = protocol.send_response(end, manager.port, &again)
                        }
                        case _ => {}
                    }
                }
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
 * Close what Loaded would have given a requester it couldn't be sent to: the process, which ends it, and its intercept
 * and address space.
 *
 * @param started What Loaded says; its handles, still the manager's, are closed.
 */
close_started :: fn(started : protocol.Started) {
    for handle in slop_os.Handle.[
        cast[slop_os.Handle](started.intercept),
        cast[slop_os.Handle](started.space),
        cast[slop_os.Handle](started.process)
    ] {
        if handle != slop_os.NO_HANDLE {
            _ = slop_os.handle_close(handle)
        }
    }
}

/** The rights a requester's handle to its program's process has, whatever its Load asks. */
GIVEN_RIGHTS :: cast[u32](slop_os.RIGHT_PROCESS_KILL)
    | cast[u32](slop_os.RIGHT_PROCESS_INSPECT)
    | cast[u32](slop_os.RIGHT_DUPLICATE)
    | cast[u32](slop_os.RIGHT_TRANSFER)
/** The rights a Load may ask for beside them; never RIGHT_PROCESS_THREADS. */
ASKABLE_RIGHTS :: cast[u32](slop_os.RIGHT_PROCESS_READ_MEMORY)
    | cast[u32](slop_os.RIGHT_PROCESS_WRITE_STATE)
    | cast[u32](slop_os.RIGHT_PROCESS_INTERCEPT)

/**
 * Build a Load's program into a new process and start its first thread.
 *
 * 64 bytes are drawn from the entropy service: the first 32 the program's seed, for its startup block, the rest the
 * seed of the stream that places its parts. The executable is copied to the manager's heap, through memory_read, to
 * be built from, and freed after; only the new process maps it. The process and its address space are made from the
 * Load's budget; before its first thread starts, it's put on the Load's CPU budget, its end watched and its intercept
 * attached, as the Load asks; once it's started, the owning handle's rights are cut to GIVEN_RIGHTS and those of the
 * Load's rights that are ASKABLE_RIGHTS. Whatever happens, the request's handles leave this process: to the program,
 * or closed; and when it fails, what was made for it is destroyed.
 *
 * @param manager The manager, whose entropy connection may be dialed again.
 * @param request The Load, whose handles are all gone from this process when it returns.
 * @return Loaded with the process, the intercept and its address space if asked, the first thread's ID, the image's
 *     address and the seeds, the handles the manager's until it's sent; or NotLoaded with BadRequest for
 *     more than MAX_GRANTS grants or an executable that's empty, larger than MAX_EXECUTABLE, or can't be read (its
 *     memory gone), NoRandom when the entropy service, asked when the Load gives no seeds, doesn't answer even when
 *     dialed again, NoMemory when the heap can't hold its copy, the budget its process, or the build ran out,
 *     NotAProgram when it isn't an executable the loader takes, NoCpuBudget when the CPU budget couldn't be put on,
 *     NoWatch when the watch or the intercept couldn't be made, and Failed for any other failure building it.
 */
load :: fn(manager : ptr[mut Manager], request : ptr[protocol.Load]) -> protocol.Response {
    defer close_all(request)
    grant_count :: cast[usize](request.grant_count)
    if grant_count > protocol.MAX_GRANTS {
        return .NotLoaded(.BadRequest)
    }
    name :: service_kit.text_of_label(&request.name)
    // The program's own seed, and one for where its parts go: the Load's, for a replay, or drawn
    seeds : u8[64] = request.seeds
    if !request.seeded && !draw(manager, seeds) {
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
    // The process and its space, the manager's until Loaded moves the process to the requester
    process :: slop_os.process_create(request.budget) or_return .NotLoaded(.NoMemory)
    started := false
    made := protocol.Started.{
        process = process,
        intercept = cast[slop_os.Intercept](slop_os.NO_HANDLE),
        space = cast[slop_os.AddressSpace](slop_os.NO_HANDLE),
    }
    defer {
        if !started {
            close_started(made)
        }
    }
    space :: slop_os.address_space_create(request.budget) or_return .NotLoaded(.NoMemory)
    // Given to the process by build; closed here if build doesn't get that far
    space_given := false
    defer {
        if !space_given {
            _ = slop_os.handle_close(cast[slop_os.Handle](space))
        }
    }
    if cast[slop_os.Handle](request.cpu_budget) != slop_os.NO_HANDLE
        && (slop_os.process_set_cpu_budget(process, request.cpu_budget) is_error) {
        return .NotLoaded(.NoCpuBudget)
    }
    if cast[slop_os.Handle](request.watch_port) != slop_os.NO_HANDLE
        && (slop_os.port_bind(request.watch_port, cast[slop_os.Handle](process), slop_os.SIGNAL_TERMINATED,
            request.watch_key, .Once) is_error) {
        return .NotLoaded(.NoWatch)
    }
    if cast[slop_os.Handle](request.intercept_port) != slop_os.NO_HANDLE {
        made.intercept = slop_os.intercept_attach(
            process,
            request.intercept_port,
            request.intercept_key,
            request.intercept_calls,
            request.intercept_points
        ) or_return .NotLoaded(.NoWatch)
        made.space = cast[slop_os.AddressSpace](slop_os.handle_duplicate(cast[slop_os.Handle](space), slop_os.RIGHT_TRANSFER)
            or_return .NotLoaded(.NoMemory))
    }
    target :: process_builder.Target.{process = process, space = space, budget = request.budget}
    match process_builder.build(
        target,
        file,
        view_of(&grants[0], grant_count),
        seed,
        &stream,
        slop_os.ABI_VERSION,
        &manager.staging
    ) {
        case Ok(built) => {
            space_given = true
            // The requester's from now on, to watch, end and read as it asked, never to start threads in
            kept :: cast[slop_os.Rights](GIVEN_RIGHTS | (cast[u32](request.rights) & ASKABLE_RIGHTS))
            // One that's ended already has nothing to restrict: answered without it, its end reported on its watch
            if slop_os.handle_restrict(cast[slop_os.Handle](process), kept) is_error {
                _ = slop_os.handle_close(cast[slop_os.Handle](process))
                made.process = cast[slop_os.Process](slop_os.NO_HANDLE)
            }
            started = true
            made.thread = built.thread
            made.image = built.image
            made.seeds = seeds
            log_line.write(manager.log, "process manager: started %", name)
            if manager.profile {
                log_line.write(manager.log, "process manager: profile: % at %", name, built.image)
            }
            return .Loaded(made)
        }
        case Error(error) => {
            log_line.write(manager.log, "process manager: % didn't start: %", name, error)
            return .NotLoaded(
                if error == .NotAProgram {
                    protocol.LoadStatus.NotAProgram
                }
                else if error == .NoMemory { protocol.LoadStatus.NoMemory } else { protocol.LoadStatus.Failed }
            )
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
dial_entropy :: fn(manager : ptr[mut Manager]) -> bool {
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
draw :: fn(manager : ptr[mut Manager], bytes : mut u8[]) -> bool {
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
draw_once :: fn(manager : ptr[mut Manager], bytes : mut u8[]) -> bool {
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
 * Close the request's handles still in this process's table: its budgets, ports, executable and grants.
 *
 * One that went to the program is gone from the table already, so closing it fails, harmlessly.
 *
 * @param request The Load, whose handle fields are left as they were, naming nothing of this process's now.
 */
close_all :: fn(request : ptr[protocol.Load]) {
    for handle in slop_os.Handle.[
        cast[slop_os.Handle](request.budget),
        cast[slop_os.Handle](request.cpu_budget),
        cast[slop_os.Handle](request.watch_port),
        cast[slop_os.Handle](request.intercept_port)
    ] {
        if handle != slop_os.NO_HANDLE {
            _ = slop_os.handle_close(handle)
        }
    }
    _ = slop_os.handle_close(cast[slop_os.Handle](request.executable))
    for handle in request.grants {
        _ = slop_os.handle_close(handle)
    }
}
