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

/** A program the manager loaded, kept while it runs, for Steer (decisions/0195, 18b). */
Record :: struct {
    /** Its process, every right but none to own it: a duplicate of the owning handle its launcher has. */
    process : slop_os.Process,
    /** Its address space, every right. */
    space : slop_os.AddressSpace,
    /** Its intercept's owning handle, the manager's; NO_HANDLE without one. */
    intercept : slop_os.Intercept,
    /** The executable it was loaded from, the Load's handle, kept (decisions/0195, 18d). */
    executable : slop_os.Memory,
    /**
     * Whether it's been steered (Steer), or was launched with an intercept that stops it at its calls, more than its
     * faults, as a debugger's, a recording's or a replay's launch is held at its first, to be steered on the user's
     * say (decisions/0195, 18e): what it does may be its steerer's, not its executable's.
     */
    steered : bool,
}

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
    /** Whether each client, by index, is a steering connection, or the steering listener, which Steer is answered on. */
    steering : bool[service_kit.MAX_CLIENTS],
    /** The programs it loaded that may still run, each pruned once its process is gone. */
    records : Record[..],
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
 * @param command_line The kernel's command line, for profile_boot.
 * @param steering The listener steering connections arrive on (decisions/0195, 18b), whose other end the root task
 *     keeps for the supervisor: Steer is answered on them alone. Without it, no Steer is.
 * @return 1 when the entropy service can't be reached at start, 2 when no port could be made, 3 when the listener
 *     couldn't be bound to it; it doesn't return otherwise.
 */
main :: fn(
    log : slop_os.DebugLog?,
    entropy : os.Channel[connector.Connector],
    clients : os.Listener[protocol.ProcessManager],
    command_line : slop_os.Memory?,
    steering : os.Listener[protocol.ProcessManager]?
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
    // Steer's listener, the supervisor's to give on (decisions/0195, 18b)
    match steering {
        case Some(listener) => match service_kit.add_client_index(&manager.clients, manager.port, listener.end) {
            case Some(at) => if at < manager.steering.count {
                manager.steering[at] = true
            }
            case None => return 3
        }
        case None => {}
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
                if index < manager.steering.count {
                    manager.steering[index] = false
                }
                return void
            }
        }
        steers :: index < manager.steering.count && manager.steering[index]
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
                match service_kit.add_client_index(&manager.clients, manager.port, connection.end) {
                    case Some(at) => if at < manager.steering.count {
                        manager.steering[at] = steers
                    }
                    case None => _ = slop_os.handle_close(cast[slop_os.Handle](connection.end))
                }
            }
            case IdentifyProcess(process) => {
                out := os.Outgoing.{}
                response :: os.begin[protocol.Response](&out)
                response^ = if steers {
                    identify_process(manager, process)
                }
                else {
                    protocol.Response.NotSteered(.NotAllowed)
                }
                _ = slop_os.handle_close(cast[slop_os.Handle](process))
                if protocol.send_response(end, manager.port, &out) is_some {
                    match response^ {
                        case Identified(found) => {
                            _ = slop_os.handle_close(cast[slop_os.Handle](found.process))
                            _ = slop_os.handle_close(cast[slop_os.Handle](found.executable))
                        }
                        case _ => {}
                    }
                }
            }
            case Identify(channel) => {
                out := os.Outgoing.{}
                response :: os.begin[protocol.Response](&out)
                response^ = if steers { identify(manager, channel) } else { protocol.Response.NotSteered(.NotAllowed) }
                _ = slop_os.handle_close(cast[slop_os.Handle](channel))
                if protocol.send_response(end, manager.port, &out) is_some {
                    match response^ {
                        case Identified(found) => {
                            _ = slop_os.handle_close(cast[slop_os.Handle](found.process))
                            _ = slop_os.handle_close(cast[slop_os.Handle](found.executable))
                        }
                        case _ => {}
                    }
                }
            }
            case Steer(asked) => {
                out := os.Outgoing.{}
                response :: os.begin[protocol.Response](&out)
                response^ = if steers { steer(manager, asked) } else { protocol.Response.NotSteered(.NotAllowed) }
                for handle in slop_os.Handle.[cast[slop_os.Handle](asked.process), cast[slop_os.Handle](asked.port)] {
                    if handle != slop_os.NO_HANDLE {
                        _ = slop_os.handle_close(handle)
                    }
                }
                if protocol.send_response(end, manager.port, &out) is_some {
                    match response^ {
                        case Steered(given) => close_steering(given)
                        case _ => {}
                    }
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
/** The rights a Load may ask for beside them: reading, never steering or starting threads (decisions/0195, 18b). */
ASKABLE_RIGHTS :: cast[u32](slop_os.RIGHT_PROCESS_READ_MEMORY)
/** The rights a launcher's handle to its program's intercept has: never RIGHT_INTERCEPT_STEER. */
INTERCEPT_GIVEN :: cast[u32](slop_os.RIGHT_DUPLICATE) | cast[u32](slop_os.RIGHT_TRANSFER)
/** The rights Steer gives a process's handle: to read it, change its threads' state and end it. */
STEERING_RIGHTS :: cast[u32](slop_os.RIGHT_PROCESS_INSPECT)
    | cast[u32](slop_os.RIGHT_PROCESS_READ_MEMORY)
    | cast[u32](slop_os.RIGHT_PROCESS_WRITE_STATE)
    | cast[u32](slop_os.RIGHT_PROCESS_KILL)
    | cast[u32](slop_os.RIGHT_DUPLICATE)
    | cast[u32](slop_os.RIGHT_TRANSFER)
/** The rights Steer gives an intercept's handle: to steer. */
STEERING_INTERCEPT :: cast[u32](slop_os.RIGHT_INTERCEPT_STEER)
    | cast[u32](slop_os.RIGHT_DUPLICATE)
    | cast[u32](slop_os.RIGHT_TRANSFER)

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
    /*
     * Ended programs' intercepts let go first: one still kept holds its port's key, which a program started again may
     * be watched under
     */
    prune(manager)
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
    // The space's handle goes to the program as it's built: the manager's own, kept for Steer
    kept_space :: copy_of(cast[slop_os.Handle](space))
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
            // Kept for Steer and Identify while it runs: the process and space, the intercept, and the executable
            executable :: cast[slop_os.Memory](copy_of(cast[slop_os.Handle](request.executable)))
            faults :: slop_os.STOP_FAULT | slop_os.STOP_FAULT_LIMITED
            stops :: cast[slop_os.Handle](made.intercept) != slop_os.NO_HANDLE
                && (request.intercept_calls != 0 || (request.intercept_points & ~faults) != 0)
            keep(manager, process, kept_space, made.intercept, executable, stops)
            if cast[slop_os.Handle](made.intercept) != slop_os.NO_HANDLE {
                made.intercept = cast[slop_os.Intercept](
                    slop_os.handle_duplicate(cast[slop_os.Handle](made.intercept), cast[slop_os.Rights](INTERCEPT_GIVEN))
                        or_else slop_os.NO_HANDLE
                )
            }
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
            if kept_space != slop_os.NO_HANDLE {
                _ = slop_os.handle_close(kept_space)
            }
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
 * Close what Steered would have given a requester it couldn't be sent to.
 *
 * @param given What Steered says; its handles, still the manager's, are closed.
 */
close_steering :: fn(given : protocol.Steering) {
    for handle in slop_os.Handle.[
        cast[slop_os.Handle](given.intercept),
        cast[slop_os.Handle](given.process),
        cast[slop_os.Handle](given.space)
    ] {
        if handle != slop_os.NO_HANDLE {
            _ = slop_os.handle_close(handle)
        }
    }
}

/**
 * Say which program the manager loaded holds the other end of a channel, on a steering connection's request
 * (decisions/0195, 18d).
 *
 * @param manager The manager, whose records are looked through.
 * @param channel The requester's end, or a duplicate of it; only read.
 * @return Identified with the program's process and executable, read only, and whether it's been steered; NotSteered
 *     NoProgram if none holds it, Failed if a handle couldn't be made.
 */
identify :: fn(manager : ptr[mut Manager], channel : slop_os.Channel) -> protocol.Response {
    prune(manager)
    for &record in manager.records {
        if slop_os.channel_peer_owned_by(channel, record.process) or_else false {
            return identity_of(record)
        }
    }
    return .NotSteered(.NoProgram)
}

/**
 * Say which program the manager loaded a launcher's handle is to, on a steering connection's request, as a steering
 * prompt names it (decisions/0197, N2).
 *
 * @param manager The manager, whose records are looked through.
 * @param process The launcher's handle, which needs RIGHT_PROCESS_KILL, as Steer's does; only read.
 * @return Identified, as identify's; NotSteered NoProgram for a handle without the right, or to no program kept,
 *     Failed if a handle couldn't be made.
 */
identify_process :: fn(manager : ptr[mut Manager], process : slop_os.Process) -> protocol.Response {
    prune(manager)
    info :: slop_os.handle_info(cast[slop_os.Handle](process)) or_return protocol.Response.NotSteered(.NoProgram)
    if cast[u32](info.rights) & cast[u32](slop_os.RIGHT_PROCESS_KILL) == 0 {
        return .NotSteered(.NoProgram)
    }
    for &record in manager.records {
        if slop_os.handle_same(cast[slop_os.Handle](record.process), cast[slop_os.Handle](process)) or_else false {
            return identity_of(record)
        }
    }
    return .NotSteered(.NoProgram)
}

/**
 * Identified's answer for a program kept.
 *
 * @param record The program's record, only read.
 * @return Identified with its process, to inspect, its executable, to read, and whether it's been steered; NotSteered
 *     Failed if a handle couldn't be made, none left open.
 */
identity_of :: fn(record : ptr[Record]) -> protocol.Response {
    process :: slop_os.handle_duplicate(
        cast[slop_os.Handle](record.process),
        cast[slop_os.Rights](cast[u32](slop_os.RIGHT_PROCESS_INSPECT) | cast[u32](slop_os.RIGHT_TRANSFER))
    ) or_return protocol.Response.NotSteered(.Failed)
    executable :: slop_os.handle_duplicate(
        cast[slop_os.Handle](record.executable),
        cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_READ) | cast[u32](slop_os.RIGHT_TRANSFER))
    ) or_else slop_os.NO_HANDLE
    if executable == slop_os.NO_HANDLE {
        _ = slop_os.handle_close(process)
        return .NotSteered(.Failed)
    }
    return .Identified(
        protocol.Identity.{
            process = cast[slop_os.Process](process),
            executable = cast[slop_os.Memory](executable),
            steered = record.steered,
        }
    )
}

/**
 * Duplicate a handle with every right it has.
 *
 * @param handle The handle, which stays the caller's.
 * @return The duplicate, not owning; NO_HANDLE if it couldn't be made.
 */
copy_of :: fn(handle : slop_os.Handle) -> slop_os.Handle {
    info :: slop_os.handle_info(handle) or_return slop_os.NO_HANDLE
    return slop_os.handle_duplicate(handle, info.rights) or_else slop_os.NO_HANDLE
}

/**
 * Keep a program just loaded for Steer, those kept before whose processes are gone let go first.
 *
 * @param manager The manager, whose records it joins.
 * @param process Its process's owning handle, still the manager's, duplicated with every right.
 * @param space A handle to its address space with every right, which the record keeps; NO_HANDLE for none.
 * @param intercept Its intercept's owning handle, which the record keeps; NO_HANDLE for none.
 * @param executable The executable it was loaded from, which the record keeps.
 * @param stops Whether its intercept stops it at its calls, not only at its faults: it's taken as steered.
 */
keep :: fn(
    manager : ptr[mut Manager],
    process : slop_os.Process,
    space : slop_os.Handle,
    intercept : slop_os.Intercept,
    executable : slop_os.Memory,
    stops : bool
) {
    prune(manager)
    made := Record.{
        process = cast[slop_os.Process](copy_of(cast[slop_os.Handle](process))),
        space = cast[slop_os.AddressSpace](space),
        intercept = intercept,
        executable = executable,
        steered = stops,
    }
    runtime.array_add(&manager.records, made)
}

/**
 * Let go of the records whose processes are gone: their handles closed, the intercept's owning one with them.
 *
 * @param manager The manager.
 */
prune :: fn(manager : ptr[mut Manager]) {
    at := cast[usize](0)
    loop {
        if at >= manager.records.count {
            break
        }
        record :: manager.records[at]
        if slop_os.handle_info(cast[slop_os.Handle](record.process)) is_ok {
            at += 1
            continue
        }
        for handle in slop_os.Handle.[
            cast[slop_os.Handle](record.process),
            cast[slop_os.Handle](record.space),
            cast[slop_os.Handle](record.intercept),
            cast[slop_os.Handle](record.executable)
        ] {
            if handle != slop_os.NO_HANDLE {
                _ = slop_os.handle_close(handle)
            }
        }
        runtime.array_remove(&manager.records, at)
    }
}

/**
 * Steer a program the manager loaded, on a steering connection's request: the user's allowed it (decisions/0195, 18b).
 *
 * @param manager The manager, whose record of it gets the new intercept, if one's attached.
 * @param asked The request; its handles stay where they are, the caller's to close.
 * @return Steered with the intercept, with RIGHT_INTERCEPT_STEER, the process, with STEERING_RIGHTS, and the space;
 *     NotSteered NoProgram for a handle without RIGHT_PROCESS_KILL, or to no program kept, Failed if the intercept or
 *     a handle couldn't be made.
 */
steer :: fn(manager : ptr[mut Manager], asked : protocol.Steer) -> protocol.Response {
    prune(manager)
    info :: slop_os.handle_info(cast[slop_os.Handle](asked.process)) or_return protocol.Response.NotSteered(.NoProgram)
    if cast[u32](info.rights) & cast[u32](slop_os.RIGHT_PROCESS_KILL) == 0 {
        return .NotSteered(.NoProgram)
    }
    found := manager.records.count
    for record, i in manager.records {
        if slop_os.handle_same(cast[slop_os.Handle](record.process), cast[slop_os.Handle](asked.process)) or_else false {
            found = i
        }
    }
    if found >= manager.records.count {
        return .NotSteered(.NoProgram)
    }
    record :: &manager.records[found]
    attached := cast[slop_os.Intercept](slop_os.NO_HANDLE)
    // Its stops to another port: the intercept it had detached, and a new one attached there
    if cast[slop_os.Handle](asked.port) != slop_os.NO_HANDLE {
        if cast[slop_os.Handle](record.intercept) != slop_os.NO_HANDLE {
            _ = slop_os.handle_close(cast[slop_os.Handle](record.intercept))
            record.intercept = cast[slop_os.Intercept](slop_os.NO_HANDLE)
        }
        // The new one's owning handle is the steerer's: closed, the program runs on unintercepted
        match slop_os.intercept_attach(record.process, asked.port, asked.key, 0, slop_os.STOP_FAULT) {
            case Ok(made) => attached = made
            case Error(error) => {
                log_line.write(manager.log, "process manager: steering: no intercept: %", error)
                return .NotSteered(.Failed)
            }
        }
    }
    given := protocol.Steering.{
        intercept = cast[slop_os.Intercept](slop_os.NO_HANDLE),
        process = cast[slop_os.Process](slop_os.NO_HANDLE),
        space = cast[slop_os.AddressSpace](
            slop_os.handle_duplicate(cast[slop_os.Handle](record.space), slop_os.RIGHT_TRANSFER) or_else slop_os.NO_HANDLE
        ),
    }
    match slop_os.handle_duplicate(cast[slop_os.Handle](record.process), cast[slop_os.Rights](STEERING_RIGHTS)) {
        case Ok(copy) => given.process = cast[slop_os.Process](copy)
        case Error(error) => {
            log_line.write(manager.log, "process manager: steering: no process handle: %", error)
            return .NotSteered(.Failed)
        }
    }
    if cast[slop_os.Handle](attached) != slop_os.NO_HANDLE {
        given.intercept = attached
    }
    else if cast[slop_os.Handle](record.intercept) != slop_os.NO_HANDLE {
        given.intercept = cast[slop_os.Intercept](
            slop_os.handle_duplicate(cast[slop_os.Handle](record.intercept), cast[slop_os.Rights](STEERING_INTERCEPT))
                or_else slop_os.NO_HANDLE
        )
    }
    record.steered = true
    log_line.write(manager.log, "process manager: a program steered, on the user's say")
    return .Steered(given)
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
