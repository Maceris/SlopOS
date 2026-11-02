/*
 * The session manager (decisions/0149, 0150, design/console-and-sessions.md §5): it makes a session once the trusted
 * path has logged someone in, and starts its first program, echo until the shell, with the session's terminal
 * connection and its home volume's root; on a boot with no accounts, the one session there is, with no user. It serves
 * the session protocol on its listener: Start and StartWithoutUser, List with a session's programs, each pinged on its
 * lifecycle channel, End, a Stop on that channel, then the program killed if it hasn't ended once a grace period's
 * over, and EndSession, every program of a session ended so. There are up to MAX_SESSIONS at once (decisions/0151). A session's programs' budgets are split off its own, the session's node, and their log records go to the
 * events service through rings it opens for them, as the supervisor's programs' do.
 */
package session_manager

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import lifecycle from "std/os/slop_os"
import process_manager from "std/os/slop_os"
import terminal from "std/os/slop_os"
import echo from "../../apps/echo"
import connector from "../../protocols/connector"
import events from "../../protocols/events"
import session from "../../protocols/session"
import service_kit from "../../libraries/service_kit"

NONE : slop_os.Channel : cast[slop_os.Channel](slop_os.NO_HANDLE)
// A program's end is watched under this key and its index
PROGRAM_KEY : u64 : 1000
MAX_PROGRAMS :: 16
MAX_SESSIONS :: 4
ECHO_BUDGET : u64 : 2 * 1024 * 1024
// How long a program has to answer a Ping, and to stop once asked
PING_WAIT : u64 : 200_000_000
STOP_GRACE : u64 : 2_000_000_000
USER_BYTES :: 32

// What echo is given (echo.main): the session's terminal, and its home volume's root if it has one.
EchoGrants :: struct {
    log : slop_os.DebugLog?,
    session_terminal : os.Channel[terminal.Terminal],
    home : os.Channel[dir.Dir]?,
}

// A session: whether it's one now, and its user's name, empty for a boot with no accounts.
Session :: struct {
    in_use : bool,
    user : u8[USER_BYTES],
    user_bytes : usize,
}

// A program of a session's: its name, its session's number, its process and budget, its lifecycle channel's end, and
// whether it's running.
Program :: struct {
    session : u32,
    name : u8[session.NAME_BYTES],
    name_bytes : u8,
    process : slop_os.Process,
    budget : slop_os.MemoryBudget,
    lifecycle : slop_os.Channel,
    // Its log records' ring, the owning handle kept to give back once it's ended (events' Retire)
    ring : slop_os.Memory,
    running : bool,
}

Manager :: struct {
    log : slop_os.DebugLog,
    port : slop_os.Port,
    manager : os.Channel[process_manager.ProcessManager],
    manager_port : slop_os.Port,
    echo_module : slop_os.Memory?,
    events_end : slop_os.Channel,
    events_port : slop_os.Port,
    // The sessions, and every session's programs
    sessions : Session[MAX_SESSIONS],
    programs : Program[MAX_PROGRAMS],
    count : usize,
}

main :: fn(log: slop_os.DebugLog?, manager: os.Channel[connector.Connector], echo_module: slop_os.Memory?,
    events_service: os.Channel[events.Events]?, clients: os.Listener[session.Session]) -> int {
    block :: slop_os.startup_block()
    sessions := runtime.new(Manager)
    sessions.log = log or_else cast[slop_os.DebugLog](slop_os.NO_HANDLE)
    sessions.echo_module = echo_module
    sessions.events_end = NONE
    match events_service {
        case Some(found) => {
            sessions.events_end = found.end
            sessions.events_port = os.port_for(block.budget, found.end) or_else cast[slop_os.Port](slop_os.NO_HANDLE)
        }
        case None => {}
    }
    sessions.port = slop_os.port_create(block.budget) or_return 1
    dial_port :: os.port_for(block.budget, manager.end) or_return 2
    sessions.manager = connector.dial[process_manager.ProcessManager](manager.end, dial_port) or_return 2
    sessions.manager_port = os.port_for(block.budget, sessions.manager.end) or_return 2
    connected := service_kit.Clients.{}
    if !service_kit.add_client(&connected, sessions.port, clients.end) {
        return 3
    }
    runtime.log_info("serving")
    into := os.Incoming.{}
    loop {
        with {
            i : usize = 0
        }
        loop {
            serve(sessions, &connected, i, &into)
            i += 1
        }
        while i < connected.count
        packets : slop_os.Packet[8]
        taken :: slop_os.port_wait(sessions.port, packets, slop_os.NO_DEADLINE) or_else 0
        ended_in(sessions, packets, cast[usize](taken))
    }
}

// Programs whose ends came among packets, marked so.
ended_in :: fn(sessions: ptr[mut Manager], packets: slop_os.Packet[], taken: usize) {
    for packet, i in packets {
        if i >= taken || packet.kind != .Signal || packet.key < PROGRAM_KEY {
            continue
        }
        index :: cast[usize](packet.key - PROGRAM_KEY)
        if index < sessions.count && index < sessions.programs.count && sessions.programs[index].running {
            sessions.programs[index].running = false
            runtime.log_info("% ended", name_of(&sessions.programs[index]))
            retire_ring(sessions, sessions.programs[index].ring)
            sessions.programs[index].ring = cast[slop_os.Memory](slop_os.NO_HANDLE)
        }
    }
}

// Every request client index has sent, until there are none left, or it's gone.
serve :: fn(sessions: ptr[mut Manager], connected: ptr[mut service_kit.Clients], index: usize, into: ptr[mut os.Incoming]) {
    if index >= connected.ends.count {
        return void
    }
    end :: connected.ends[index]
    if cast[slop_os.Handle](end) == slop_os.NO_HANDLE {
        return void
    }
    loop {
        match session.receive_request(end, sessions.port, into, false) {
            case Received => {}
            case Empty => return void
            case Unsupported => {
                _ = session.answer_unsupported(end, sessions.port)
                continue
            }
            case Failed(error) => {
                service_kit.drop_client(connected, index)
                return void
            }
            case _ => continue
        }
        out := os.Outgoing.{}
        response :: os.begin[session.Response](&out)
        match os.message_of[session.Request](into)^ {
            case Start(given) => response^ = start(sessions, os.items(into, given.user), given.terminal, given.home)
            case StartWithoutUser(given) => response^ = start(sessions, u8.[], given, null)
            case List(number) => {
                programs : session.Program[session.MAX_PROGRAMS]
                count :: list(sessions, number, &programs)
                response^ = .Programs(os.append(&out, programs[0..<count]))
            }
            case End(which) => response^ = end_program(sessions, cast[usize](which))
            case EndSession(number) => response^ = end_session(sessions, number)
            case Connect(connection) => {
                if !service_kit.add_client(connected, sessions.port, connection.end) {
                    _ = slop_os.handle_close(cast[slop_os.Handle](connection.end))
                }
                continue
            }
        }
        _ = session.send_response(end, sessions.port, &out)
    }
}

/*
 * A session made, its first program started with its terminal and home: Started with its number, or Refused when
 * there's no room for another.
 */
start :: fn(sessions: ptr[mut Manager], user: u8[], given_terminal: os.Channel[terminal.Terminal], home: os.Channel[dir.Dir]?) -> session.Response {
    number := sessions.sessions.count
    for each, i in sessions.sessions {
        if !each.in_use {
            number = i
            break
        }
    }
    if number >= sessions.sessions.count || user.count > USER_BYTES {
        _ = slop_os.handle_close(cast[slop_os.Handle](given_terminal.end))
        match home {
            case Some(root) => _ = slop_os.handle_close(cast[slop_os.Handle](root.end))
            case None => {}
        }
        return .Refused
    }
    made := Session.{in_use = true, user_bytes = user.count}
    for byte, i in user {
        if i < made.user.count {
            made.user[i] = byte
        }
    }
    sessions.sessions[number] = made
    if user.count == 0 {
        runtime.log_info("a session with no user, on a boot with no accounts")
    }
    else {
        runtime.log_info("a session for %", string_of(&user[0], user.count))
    }
    if !launch_echo(sessions, cast[u32](number), given_terminal, home) {
        sessions.sessions[number].in_use = false
        return .Refused
    }
    return .Started(cast[u32](number))
}

// Every program of session number asked to stop, then ended, and the session with them.
end_session :: fn(sessions: ptr[mut Manager], number: u32) -> session.Response {
    if cast[usize](number) >= sessions.sessions.count || !sessions.sessions[cast[usize](number)].in_use {
        return .Ended
    }
    runtime.log_info("ending session %", number)
    for i in 0..<sessions.count {
        if i < sessions.programs.count && sessions.programs[i].session == number && sessions.programs[i].running {
            _ = end_program(sessions, i)
        }
    }
    sessions.sessions[cast[usize](number)] = Session.{}
    return .Ended
}

// echo started in the session, its end watched and its lifecycle channel kept; whether it started.
launch_echo :: fn(sessions: ptr[mut Manager], number: u32, given_terminal: os.Channel[terminal.Terminal], home: os.Channel[dir.Dir]?) -> bool {
    module :: sessions.echo_module or_return false
    // A place one that ended left, or the next
    index := sessions.count
    for i in 0..<sessions.count {
        if i < sessions.programs.count && !sessions.programs[i].running {
            index = i
            break
        }
    }
    if index >= sessions.programs.count {
        return false
    }
    options := os.LaunchOptions.{watch = os.LaunchWatch.{port = sessions.port, key = PROGRAM_KEY + cast[u64](index)}}
    ends :: lifecycle.make(slop_os.startup_block().budget) or_return false
    options.lifecycle = ends.b
    rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_READ) | cast[u32](slop_os.RIGHT_DUPLICATE) | cast[u32](slop_os.RIGHT_TRANSFER))
    copy :: cast[slop_os.Memory](slop_os.handle_duplicate(cast[slop_os.Handle](module), rights) or_return false)
    // A ring for its log records, the owning handle kept, the program given one that doesn't own it
    ring := cast[slop_os.Memory](slop_os.NO_HANDLE)
    if sessions.events_end != NONE {
        match events.open(sessions.events_end, sessions.events_port, "echo") {
            case Some(opened) => {
                ring_rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_READ) | cast[u32](slop_os.RIGHT_MEMORY_WRITE)
                    | cast[u32](slop_os.RIGHT_TRANSFER))
                match slop_os.handle_duplicate(cast[slop_os.Handle](opened.ring), ring_rights) {
                    case Ok(given) => {
                        ring = opened.ring
                        options.events = os.LaunchEvents.{ring = cast[slop_os.Memory](given), doorbell = opened.doorbell}
                    }
                    case Error(error) => {
                        _ = slop_os.handle_close(cast[slop_os.Handle](opened.ring))
                        _ = slop_os.handle_close(cast[slop_os.Handle](opened.doorbell))
                    }
                }
            }
            case None => {}
        }
    }
    match os.launch(sessions.manager, sessions.manager_port, "echo", copy, ECHO_BUDGET, echo.main,
        EchoGrants.{log = duplicate_log(sessions.log), session_terminal = given_terminal, home = home}, options) {
        case Ok(launched) => {
            program := Program.{session = number, process = launched.process, budget = launched.budget, lifecycle = ends.a, ring = ring,
                running = true}
            for byte, i in string_bytes("echo") {
                if i < program.name.count {
                    program.name[i] = byte
                    program.name_bytes += 1
                }
            }
            sessions.programs[index] = program
            if index == sessions.count {
                sessions.count = index + 1
            }
            runtime.log_info("started echo in the session")
            return true
        }
        case Error(error) => {
            runtime.log_info("echo didn't start: %", error)
            _ = slop_os.handle_close(cast[slop_os.Handle](ends.a))
            retire_ring(sessions, ring)
            return false
        }
    }
}

// Session number's programs that are running, into programs, each pinged: how many.
list :: fn(sessions: ptr[mut Manager], number: u32, programs: ptr[mut session.Program[session.MAX_PROGRAMS]]) -> usize {
    count : usize = 0
    for &program, i in sessions.programs {
        if i >= sessions.count || count >= programs.count {
            break
        }
        if !program.running || program.session != number {
            continue
        }
        listed := session.Program.{index = cast[u32](i), name = program.name, name_bytes = program.name_bytes}
        match slop_os.memory_budget_info(program.budget) {
            case Ok(info) => {
                listed.memory = info.used
                listed.memory_limit = info.limit
            }
            case Error(error) => {}
        }
        // Answers left from before are dropped, so only this Ping's counts
        loop {
            stale :: lifecycle.read(program.lifecycle) or_break
        }
        _ = lifecycle.ping(program.lifecycle, cast[u32](i))
        programs[count] = listed
        count += 1
    }
    if count > programs.count {
        return 0
    }
    // Each one's Pong, until all have answered or the wait's over
    deadline :: (slop_os.clock_monotonic() or_else 0) + PING_WAIT
    loop {
        waiting := false
        for &listed in programs[0..<count] {
            index :: cast[usize](listed.index)
            if listed.responding != 0 || index >= sessions.programs.count {
                continue
            }
            match lifecycle.read(sessions.programs[index].lifecycle) {
                case Some(answer) => {
                    if answer.answer == .Pong {
                        listed.responding = 1
                    }
                }
                case None => waiting = true
            }
        }
        if !waiting || (slop_os.clock_monotonic() or_else 0) >= deadline {
            break
        }
        pause(sessions, 10_000_000)
    }
    return count
}

// The program at index asked to stop on its lifecycle channel, then killed if it hasn't ended once the grace period's over.
end_program :: fn(sessions: ptr[mut Manager], index: usize) -> session.Response {
    if index >= sessions.count || index >= sessions.programs.count {
        return .Refused
    }
    if !sessions.programs[index].running {
        return .Ended
    }
    runtime.log_info("ending % on the trusted path's request", name_of(&sessions.programs[index]))
    _ = lifecycle.stop(sessions.programs[index].lifecycle)
    deadline :: (slop_os.clock_monotonic() or_else 0) + STOP_GRACE
    loop {
        if !sessions.programs[index].running || (slop_os.clock_monotonic() or_else 0) >= deadline {
            break
        }
        packets : slop_os.Packet[8]
        taken :: slop_os.port_wait(sessions.port, packets, deadline) or_else 0
        ended_in(sessions, packets, cast[usize](taken))
    }
    if sessions.programs[index].running {
        runtime.log_info("% didn't stop in time, so it's killed", name_of(&sessions.programs[index]))
        _ = slop_os.process_kill(sessions.programs[index].process)
    }
    return .Ended
}

// An ended program's ring given back to the events service, which reads what's left in it, or closed without one.
retire_ring :: fn(sessions: ptr[mut Manager], ring: slop_os.Memory) {
    if cast[slop_os.Handle](ring) == slop_os.NO_HANDLE {
        return void
    }
    if sessions.events_end != NONE {
        out := os.Outgoing.{}
        request :: os.begin[events.Request](&out)
        request^ = .Retire(ring)
        into := os.Incoming.{}
        match events.ask(sessions.events_end, sessions.events_port, &out, &into) {
            case Done => return void
            case _ => {}
        }
    }
    _ = slop_os.handle_close(cast[slop_os.Handle](ring))
}

// A copy of the session manager's debug log, for a program it starts, which logs through it.
duplicate_log :: fn(log: slop_os.DebugLog) -> slop_os.DebugLog? {
    rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_DEBUG_LOG_WRITE) | cast[u32](slop_os.RIGHT_DUPLICATE) | cast[u32](slop_os.RIGHT_TRANSFER))
    return match slop_os.handle_duplicate(cast[slop_os.Handle](log), rights) {
        case Ok(copy) => cast[slop_os.DebugLog](copy)
        case Error(error) => null
    }
}

pause :: fn(sessions: ptr[mut Manager], nanoseconds: u64) {
    waiter :: slop_os.port_create(slop_os.startup_block().budget) or_return void
    defer slop_os.handle_close(cast[slop_os.Handle](waiter))
    packets : slop_os.Packet[1]
    _ = slop_os.port_wait(waiter, packets, (slop_os.clock_monotonic() or_else 0) + nanoseconds)
}

name_of :: fn(program: ptr[Program]) -> string {
    count :: if cast[usize](program.name_bytes) <= program.name.count { cast[usize](program.name_bytes) } else { 0 }
    return if count == 0 { "" } else { string_of(&program.name[0], count) }
}
