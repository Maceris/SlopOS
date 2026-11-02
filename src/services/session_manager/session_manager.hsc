/*
 * The session manager (decisions/0149, 0150, design/console-and-sessions.md §5): it makes a session once the trusted
 * path has logged someone in, and starts its first program, echo until the shell, with the session's terminal
 * connection and its home volume's root; on a boot with no accounts, the one session there is, with no user. It serves
 * the session protocol on its listener: Start and StartWithoutUser, List with a session's programs, each pinged on its
 * lifecycle channel, End, a Stop on that channel, then the program killed if it hasn't ended once a grace period's
 * over, and EndSession, every program of a session ended so. There are up to MAX_SESSIONS at once (decisions/0151). A session's programs' budgets are split off its own, the session's node, and their log records go to the
 * events service through rings it opens for them, as the supervisor's programs' do. Each program is given its session's
 * locale (decisions/0152), from its user's settings in the config store, "session" of owner "user:" and their name, or
 * the keyboard layout they logged in with, which is kept as their setting then. Each session runs the system's
 * installations (decisions/0153), their programs from the bundle store, each with its data directory in the session's
 * home, apps/<name>, or the system volume's apps for a session with no user, and its settings in the config store,
 * owned by "user:", the user's name, ":" and its name. Under memory pressure, its budget at PRESSURE_PERCENT of its
 * limit, it asks the idle installations, those of the sessions the console doesn't show, the least recently shown
 * session's first, to stop, one at a time, until it's back under RELIEVED_PERCENT; a session's first program is never
 * asked. A session with a user has a powerbox (decisions/0156), started before echo with a connection to the session's
 * home and the trusted path's prompt connection; each program it starts after is given a connection of its own to it,
 * served under the program's name.
 */
package session_manager

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import lifecycle from "std/os/slop_os"
import process_manager from "std/os/slop_os"
import terminal from "std/os/slop_os"
import schema from "std"
import echo from "../../apps/echo"
import powerbox_service from "../powerbox_service"
import counter from "../../apps/counter"
import counter_app from "../../counter_app"
import bundle from "../../bundle"
import installations from "../../installations"
import system_records from "../../system_records"
import bundle_store from "../../protocols/bundle_store"
import connector from "../../protocols/connector"
import config from "../../protocols/config"
import events from "../../protocols/events"
import powerbox from "../../protocols/powerbox"
import prompt from "../../protocols/prompt"
import session from "../../protocols/session"
import service_kit from "../../libraries/service_kit"

NONE : slop_os.Channel : cast[slop_os.Channel](slop_os.NO_HANDLE)
// A program's end is watched under this key and its index
PROGRAM_KEY : u64 : 1000
// Its budget's pressure is bound to its port under this key
PRESSURE_KEY : u64 : 900
PRESSURE_PERCENT : u64 : 80
RELIEVED_PERCENT : u64 : 70
MAX_PROGRAMS :: 16
MAX_SESSIONS :: 4
ECHO_BUDGET : u64 : 2 * 1024 * 1024
// How long a program has to answer a Ping, and to stop once asked
PING_WAIT : u64 : 200_000_000
STOP_GRACE : u64 : 2_000_000_000
USER_BYTES :: 32
LOCALE_BYTES :: 16
// "user:", a user's name, ":" and an installation's name
OWNER_BYTES :: 80
INSTALLATION_BUDGET : u64 : 4 * 1024 * 1024
POWERBOX_BUDGET : u64 : 2 * 1024 * 1024
// How long test_installations waits for the counter to count
COUNT_WAIT : u64 : 20_000_000_000
NOWHERE : usize : ~cast[usize](0)

// A user's settings for their sessions, in the config store.
SessionSettings :: struct {
    // A std/locale name, as "en-GB"; empty until it's chosen
    locale : slop_os.Relative[u8],
}

// What echo is given (echo.main): the session's terminal, and its home volume's root if it has one.
EchoGrants :: struct {
    log : slop_os.DebugLog?,
    session_terminal : os.Channel[terminal.Terminal],
    home : os.Channel[dir.Dir]?,
    powerbox : os.Channel[powerbox.Powerbox]?,
}

// What the powerbox is given (powerbox_service.main): the session's home, the trusted path's prompt connection, and the
// session manager's connection, on which it's asked to serve each program.
PowerboxGrants :: struct {
    home : os.Channel[dir.Dir]?,
    prompts : os.Channel[prompt.Prompt],
    manager : os.Channel[powerbox.Powerbox],
}

// What an installation is given (counter.main, the entry installations are launched with): its data directory and its
// settings.
InstallationGrants :: struct {
    data : installations.AppData,
    settings : config.Config[counter_app.CounterSettings]?,
}

// A session: whether it's one now, and its user's name, empty for a boot with no accounts.
Session :: struct {
    in_use : bool,
    user : u8[USER_BYTES],
    user_bytes : usize,
    // Its locale's name, "" for none, and the page holding it, which its programs are given copies of to read, kept
    // while it lasts
    locale : u8[LOCALE_BYTES],
    locale_bytes : usize,
    locale_page : slop_os.Memory,
    // Its apps directory, its installations' data directories' parent; NONE for none
    apps : slop_os.Channel,
    // When it was last shown, by the count of Shown, 0 for never
    shown_at : u64,
    // Its powerbox's connection for the session manager; NONE for none
    powerbox_end : slop_os.Channel,
    powerbox_port : slop_os.Port,
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
    // Whether it's one of the system's installations, not the session's first program
    installation : bool,
}

// What a program's launch is given, made ready: its place among the programs, its options, and the ends of its
// lifecycle channel and its log records' ring that the session manager keeps.
Prepared :: struct {
    index : usize,
    options : os.LaunchOptions,
    lifecycle : slop_os.Channel,
    ring : slop_os.Memory,
}

MappedObject :: struct {
    memory : slop_os.Memory,
    address : u64,
    bytes : u8[],
}

Manager :: struct {
    log : slop_os.DebugLog,
    port : slop_os.Port,
    manager : os.Channel[process_manager.ProcessManager],
    manager_port : slop_os.Port,
    echo_module : slop_os.Memory?,
    events_end : slop_os.Channel,
    events_port : slop_os.Port,
    // The config store's connection for users' values
    settings_end : slop_os.Channel,
    settings_port : slop_os.Port,
    // The bundle store, the system volume's apps directory, for a session with no user, and the system's list of
    // installations, the config store's value "installations" of owner "system"
    store_end : slop_os.Channel,
    store_port : slop_os.Port,
    apps_end : slop_os.Channel,
    list_end : slop_os.Channel,
    list_port : slop_os.Port,
    // test_installations' session, once there's one with a user, and whether it's still to come
    test_installations : bool,
    checking : usize,
    // The session the console shows, or session.NO_SESSION, and how many times it's been told
    shown : u32,
    showings : u64,
    // test_pressure: whether it's still to come, and the budget it charges its own with to bring on pressure, until
    // that's relieved
    test_pressure : bool,
    ballast : slop_os.MemoryBudget,
    // The sessions, and every session's programs
    sessions : Session[MAX_SESSIONS],
    programs : Program[MAX_PROGRAMS],
    count : usize,
}

main :: fn(log: slop_os.DebugLog?, manager: os.Channel[connector.Connector], echo_module: slop_os.Memory?,
    events_service: os.Channel[events.Events]?, settings: os.Channel[config.ConfigValue]?, store: os.Channel[bundle_store.BundleStore]?,
    apps: os.Channel[dir.Dir]?, installation_list: config.Config[system_records.Installations]?, command_line: slop_os.Memory?,
    clients: os.Listener[session.Session]) -> int {
    block :: slop_os.startup_block()
    sessions := runtime.new(Manager)
    sessions.log = log or_else cast[slop_os.DebugLog](slop_os.NO_HANDLE)
    sessions.echo_module = echo_module
    sessions.checking = NOWHERE
    sessions.events_end = NONE
    sessions.shown = session.NO_SESSION
    sessions.ballast = cast[slop_os.MemoryBudget](slop_os.NO_HANDLE)
    sessions.settings_end = NONE
    sessions.store_end = NONE
    sessions.apps_end = NONE
    sessions.list_end = NONE
    match settings {
        case Some(found) => {
            sessions.settings_end = found.end
            sessions.settings_port = port_of(found.end)
        }
        case None => {}
    }
    match events_service {
        case Some(found) => {
            sessions.events_end = found.end
            sessions.events_port = port_of(found.end)
        }
        case None => {}
    }
    match store {
        case Some(found) => {
            sessions.store_end = found.end
            sessions.store_port = port_of(found.end)
        }
        case None => {}
    }
    match apps {
        case Some(found) => sessions.apps_end = found.end
        case None => {}
    }
    match installation_list {
        case Some(found) => {
            sessions.list_end = found.end
            sessions.list_port = port_of(found.end)
        }
        case None => {}
    }
    match command_line {
        case Some(memory) => {
            text :: service_kit.text_of(block, memory) or_else ""
            sessions.test_installations = service_kit.has_word(text, "test_installations")
            sessions.test_pressure = service_kit.has_word(text, "test_pressure")
        }
        case None => {}
    }
    sessions.port = slop_os.port_create(block.budget) or_return 1
    // Pressure on its budget, which its sessions' programs' budgets are split off, wakes it to stop idle installations
    slop_os.port_bind(sessions.port, cast[slop_os.Handle](block.budget), slop_os.SIGNAL_PRESSURE, PRESSURE_KEY, .Persistent) or_return 1
    match slop_os.memory_budget_info(block.budget) {
        case Ok(info) => _ = slop_os.memory_budget_set_threshold(block.budget, info.limit / 100 * PRESSURE_PERCENT)
        case Error(error) => {}
    }
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
        // test_installations, once the session it's for has been answered for
        if sessions.checking != NOWHERE {
            check_installations(sessions, cast[u32](sessions.checking))
            sessions.checking = NOWHERE
            continue
        }
        packets : slop_os.Packet[8]
        taken :: slop_os.port_wait(sessions.port, packets, slop_os.NO_DEADLINE) or_else 0
        ended_in(sessions, packets, cast[usize](taken))
        for packet, i in packets {
            if i < cast[usize](taken) && packet.key == PRESSURE_KEY {
                relieve(sessions)
                break
            }
        }
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
            program :: &sessions.programs[index]
            program.running = false
            runtime.log_info("% ended", name_of(program))
            retire_ring(sessions, program.ring)
            program.ring = cast[slop_os.Memory](slop_os.NO_HANDLE)
            // Its process, its budget, given back to the session manager's, and its lifecycle channel closed
            for handle in slop_os.Handle.[cast[slop_os.Handle](program.process), cast[slop_os.Handle](program.budget),
                cast[slop_os.Handle](program.lifecycle)] {
                _ = slop_os.handle_close(handle)
            }
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
            case Start(given) => response^ = start(sessions, os.items(into, given.user), os.items(into, given.layout), given.terminal, given.home,
                given.prompts)
            case StartWithoutUser(given) => response^ = start(sessions, u8.[], u8.[], given, null, null)
            case List(number) => {
                programs : session.Program[session.MAX_PROGRAMS]
                count :: list(sessions, number, &programs)
                response^ = .Programs(os.append(&out, programs[0..<count]))
            }
            case End(which) => response^ = end_program(sessions, cast[usize](which), "on the trusted path's request")
            case EndSession(number) => response^ = end_session(sessions, number)
            case Shown(number) => {
                shown(sessions, number)
                response^ = .Noted
            }
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
start :: fn(sessions: ptr[mut Manager], user: u8[], layout: u8[], given_terminal: os.Channel[terminal.Terminal], home: os.Channel[dir.Dir]?,
    prompts: os.Channel[prompt.Prompt]?) -> session.Response {
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
        match prompts {
            case Some(given) => _ = slop_os.handle_close(cast[slop_os.Handle](given.end))
            case None => {}
        }
        return .Refused
    }
    made := Session.{in_use = true, user_bytes = user.count, locale_page = cast[slop_os.Memory](slop_os.NO_HANDLE), apps = NONE,
        powerbox_end = NONE}
    for byte, i in user {
        if i < made.user.count {
            made.user[i] = byte
        }
    }
    if user.count > 0 {
        chosen :: locale_for(sessions, user, layout)
        for byte, i in string_bytes(chosen) {
            if i < made.locale.count {
                made.locale[i] = byte
                made.locale_bytes = i + 1
            }
        }
    }
    sessions.sessions[number] = made
    if user.count == 0 {
        runtime.log_info("a session with no user, on a boot with no accounts")
    }
    else {
        runtime.log_info("a session for %, in %", string_of(&user[0], user.count), locale_of(&sessions.sessions[number]))
    }
    // Its apps directory and its powerbox, before its home is echo's
    sessions.sessions[number].apps = apps_of(sessions, home)
    match prompts {
        case Some(given) => _ = launch_powerbox(sessions, cast[u32](number), home, given)
        case None => {}
    }
    if !launch_echo(sessions, cast[u32](number), given_terminal, home) {
        close_session(sessions, cast[u32](number))
        return .Refused
    }
    start_installations(sessions, cast[u32](number))
    if sessions.test_installations && user.count > 0 {
        sessions.test_installations = false
        sessions.checking = number
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
            _ = end_program(sessions, i, "as its session ends")
        }
    }
    close_session(sessions, number)
    return .Ended
}

// Session number's place freed, what it kept closed.
close_session :: fn(sessions: ptr[mut Manager], number: u32) {
    if cast[usize](number) >= sessions.sessions.count {
        return void
    }
    made :: &sessions.sessions[cast[usize](number)]
    if cast[slop_os.Handle](made.locale_page) != slop_os.NO_HANDLE {
        _ = slop_os.handle_close(cast[slop_os.Handle](made.locale_page))
    }
    if made.apps != NONE {
        _ = slop_os.handle_close(cast[slop_os.Handle](made.apps))
    }
    if made.powerbox_end != NONE {
        _ = slop_os.handle_close(cast[slop_os.Handle](made.powerbox_end))
        _ = slop_os.handle_close(cast[slop_os.Handle](made.powerbox_port))
    }
    made^ = Session.{locale_page = cast[slop_os.Memory](slop_os.NO_HANDLE), apps = NONE, powerbox_end = NONE}
}

// echo started in the session, its end watched and its lifecycle channel kept; whether it started.
launch_echo :: fn(sessions: ptr[mut Manager], number: u32, given_terminal: os.Channel[terminal.Terminal], home: os.Channel[dir.Dir]?) -> bool {
    module :: sessions.echo_module or_return false
    rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_READ) | cast[u32](slop_os.RIGHT_DUPLICATE) | cast[u32](slop_os.RIGHT_TRANSFER))
    copy :: cast[slop_os.Memory](slop_os.handle_duplicate(cast[slop_os.Handle](module), rights) or_return false)
    prepared :: prepare(sessions, number, "echo") or_return false
    return placed(sessions, number, "echo", prepared, os.launch(sessions.manager, sessions.manager_port, "echo", copy, ECHO_BUDGET, echo.main,
        EchoGrants.{log = duplicate_log(sessions.log), session_terminal = given_terminal, home = home,
        powerbox = powerbox_for(sessions, number, "echo")}, prepared.options), false)
}

/*
 * The session's powerbox, from the bundle store, given another connection to its home and the prompt connection, and
 * its connection for the session manager kept: whether it started.
 */
launch_powerbox :: fn(sessions: ptr[mut Manager], number: u32, home: os.Channel[dir.Dir]?, prompts: os.Channel[prompt.Prompt]) -> bool {
    if cast[usize](number) >= sessions.sessions.count {
        _ = slop_os.handle_close(cast[slop_os.Handle](prompts.end))
        return false
    }
    expected :: bundle.Hash.{bytes = schema.hash(type_info_of(type_of(powerbox_service.main)))}
    program := cast[slop_os.Memory](slop_os.NO_HANDLE)
    match bundle_named(sessions, "powerbox_service") {
        case Some(found) => program = program_of(sessions, found, expected) or_else cast[slop_os.Memory](slop_os.NO_HANDLE)
        case None => {}
    }
    if cast[slop_os.Handle](program) == slop_os.NO_HANDLE {
        runtime.log_info("no powerbox for the session")
        _ = slop_os.handle_close(cast[slop_os.Handle](prompts.end))
        return false
    }
    pair :: os.channel_for[powerbox.Powerbox](slop_os.startup_block().budget, 0) or_return false
    grants := PowerboxGrants.{prompts = prompts, manager = os.Channel[powerbox.Powerbox].{end = pair.a}}
    match home {
        case Some(root) => match connection_to(root.end) {
            case Some(another) => grants.home = os.Channel[dir.Dir].{end = another}
            case None => {}
        }
        case None => {}
    }
    prepared :: prepare(sessions, number, "powerbox") or_return false
    if !placed(sessions, number, "powerbox", prepared, os.launch(sessions.manager, sessions.manager_port, "powerbox", program, POWERBOX_BUDGET,
        powerbox_service.main, grants, prepared.options), false) {
        _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
        return false
    }
    sessions.sessions[cast[usize](number)].powerbox_end = pair.b
    sessions.sessions[cast[usize](number)].powerbox_port = port_of(pair.b)
    return true
}

// A connection to session number's powerbox for the program named name, which it serves under that name; null without one.
powerbox_for :: fn(sessions: ptr[mut Manager], number: u32, name: string) -> os.Channel[powerbox.Powerbox]? {
    if cast[usize](number) >= sessions.sessions.count || sessions.sessions[cast[usize](number)].powerbox_end == NONE {
        return null
    }
    made :: &sessions.sessions[cast[usize](number)]
    pair :: os.channel_for[powerbox.Powerbox](slop_os.startup_block().budget, 0) or_return null
    out := os.Outgoing.{}
    request :: os.begin[powerbox.Request](&out)
    request^ = .Serve(powerbox.Served.{name = os.append(&out, string_bytes(name)),
        end = os.Channel[powerbox.Powerbox].{end = pair.a}})
    if powerbox.send_request(made.powerbox_end, made.powerbox_port, &out) != null {
        _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
        return null
    }
    into := os.Incoming.{}
    loop {
        match powerbox.receive_response(made.powerbox_end, made.powerbox_port, &into, true) {
            case Received => break
            case _ => {
                _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
                return null
            }
        }
    }
    return match os.message_of[powerbox.Response](&into)^ {
        case Done => os.Channel[powerbox.Powerbox].{end = pair.b}
        case _ => {
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
            null
        }
    }
}

/*
 * A program's launch made ready: a place one that ended left, or the next; its end watched under its place's key; a
 * lifecycle channel; its session's locale; and a ring for its log records, the owning handle kept, the program given one
 * that doesn't own it. Null with no place left.
 */
prepare :: fn(sessions: ptr[mut Manager], number: u32, name: string) -> Prepared? {
    index := sessions.count
    for i in 0..<sessions.count {
        if i < sessions.programs.count && !sessions.programs[i].running {
            index = i
            break
        }
    }
    if index >= sessions.programs.count {
        return null
    }
    // The binding that watched the one that ended there, which keeps its key once it's fired
    if index < sessions.count {
        _ = slop_os.port_unbind(sessions.port, PROGRAM_KEY + cast[u64](index))
    }
    ends :: lifecycle.make(slop_os.startup_block().budget) or_return null
    prepared := Prepared.{index = index, lifecycle = ends.a, ring = cast[slop_os.Memory](slop_os.NO_HANDLE)}
    prepared.options = os.LaunchOptions.{watch = os.LaunchWatch.{port = sessions.port, key = PROGRAM_KEY + cast[u64](index)}}
    prepared.options.lifecycle = ends.b
    if cast[usize](number) < sessions.sessions.count {
        prepared.options.locale = locale_page(&sessions.sessions[cast[usize](number)])
    }
    if sessions.events_end != NONE {
        match events.open(sessions.events_end, sessions.events_port, name) {
            case Some(opened) => {
                ring_rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_READ) | cast[u32](slop_os.RIGHT_MEMORY_WRITE)
                    | cast[u32](slop_os.RIGHT_TRANSFER))
                match slop_os.handle_duplicate(cast[slop_os.Handle](opened.ring), ring_rights) {
                    case Ok(given) => {
                        prepared.ring = opened.ring
                        prepared.options.events = os.LaunchEvents.{ring = cast[slop_os.Memory](given), doorbell = opened.doorbell}
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
    return prepared
}

// A program launched with what prepare made ready, kept in its place, or what was made ready given back: whether it started.
placed :: fn(sessions: ptr[mut Manager], number: u32, name: string, prepared: Prepared, result: Result[os.Launched, os.LaunchError],
    installation: bool) -> bool {
    match result {
        case Ok(launched) => {
            program := Program.{session = number, process = launched.process, budget = launched.budget, lifecycle = prepared.lifecycle,
                ring = prepared.ring, running = true, installation = installation}
            for byte, i in string_bytes(name) {
                if i < program.name.count {
                    program.name[i] = byte
                    program.name_bytes += 1
                }
            }
            if prepared.index >= sessions.programs.count {
                return false
            }
            sessions.programs[prepared.index] = program
            if prepared.index == sessions.count {
                sessions.count = prepared.index + 1
            }
            runtime.log_info("started % in the session", name)
            return true
        }
        case Error(error) => {
            runtime.log_info("% didn't start: %", name, error)
            _ = slop_os.handle_close(cast[slop_os.Handle](prepared.lifecycle))
            retire_ring(sessions, prepared.ring)
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

// The program at index asked to stop, for why on its lifecycle channel, then killed if it hasn't ended once the grace period's over.
end_program :: fn(sessions: ptr[mut Manager], index: usize, why: string) -> session.Response {
    if index >= sessions.count || index >= sessions.programs.count {
        return .Refused
    }
    if !sessions.programs[index].running {
        return .Ended
    }
    runtime.log_info("ending % %", name_of(&sessions.programs[index]), why)
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

/*
 * A user's locale: their settings', or with none, the one the keyboard layout they logged in with suggests, kept as their
 * setting from then on.
 */
locale_for :: fn(sessions: ptr[mut Manager], user: u8[], layout: u8[]) -> string {
    suggested :: if layout.count == 2 && layout[0] == cast[u8]('u') && layout[1] == cast[u8]('k') { "en-GB" } else { "en-US" }
    if sessions.settings_end == NONE {
        return suggested
    }
    owner : u8[OWNER_BYTES]
    count :: owner_of(user, "", &owner)
    out := os.Outgoing.{}
    request :: os.begin[config.Request](&out)
    request^ = .ValueFor(config.ValueFor.{owner = os.append(&out, owner[0..<count]), name = os.append(&out, string_bytes("session"))})
    into := os.Incoming.{}
    connection :: match config.ask(sessions.settings_end, sessions.settings_port, &out, &into) {
        case Opened(opened) => config.Config[SessionSettings].{end = opened.end}
        case _ => return suggested
    }
    defer slop_os.handle_close(cast[slop_os.Handle](connection.end))
    port :: os.port_for(slop_os.startup_block().budget, connection.end) or_return suggested
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    if config.declare(connection, port) is_error {
        return suggested
    }
    value := os.Outgoing.{}
    if config.read(connection, port, &value) is_ok {
        bytes :: os.value_bytes(&value)
        kept :: os.items_of(bytes, os.typed_value[SessionSettings](bytes).locale)
        if kept.count > 0 {
            match locale_named(kept) {
                case Some(name) => return name
                case None => {}
            }
        }
    }
    // None yet: the suggested one, kept as theirs
    override := os.Outgoing.{}
    written :: os.begin[SessionSettings](&override)
    written.locale = os.append(&override, string_bytes(suggested))
    _ = config.write(connection, port, os.value_bytes(&override), config.field_bit[SessionSettings]("locale"))
    return suggested
}

/*
 * The config store's owner of a user's values, "user:" and their name, "-" for a session with no user, and for an
 * installation's, ":" and its name after that, into owner: how many bytes it is.
 */
owner_of :: fn(user: u8[], installation: string, owner: ptr[mut u8[OWNER_BYTES]]) -> usize {
    count : usize = 0
    add_bytes(owner, &count, string_bytes("user:"))
    add_bytes(owner, &count, if user.count > 0 { user } else { string_bytes("-") })
    if installation.count > 0 {
        add_bytes(owner, &count, string_bytes(":"))
        add_bytes(owner, &count, string_bytes(installation))
    }
    return count
}

add_bytes :: fn(owner: ptr[mut u8[OWNER_BYTES]], count: ptr[mut usize], bytes: u8[]) {
    for byte in bytes {
        at :: count^
        if at < owner.count {
            owner^[at] = byte
            count^ = at + 1
        }
    }
}

// The locale named by bytes, if it's one the session manager gives: its name as a constant.
locale_named :: fn(bytes: u8[]) -> string? {
    if bytes.count == 0 {
        return null
    }
    for name in string.["en-US", "en-GB"] {
        if string_of(&bytes[0], bytes.count) == name {
            return name
        }
    }
    return null
}

locale_of :: fn(made: ptr[Session]) -> string {
    return if made.locale_bytes > 0 && made.locale_bytes <= made.locale.count { string_of(&made.locale[0], made.locale_bytes) } else { "no locale" }
}

/*
 * A read-only copy of the page holding a session's locale's name, for a program's grant "locale", the page made the
 * first time and kept by the session, since closing it would take the copies with it; null for a session with none.
 */
locale_page :: fn(made: ptr[mut Session]) -> slop_os.Memory? {
    count :: made.locale_bytes
    if count == 0 || count > made.locale.count {
        return null
    }
    if cast[slop_os.Handle](made.locale_page) == slop_os.NO_HANDLE {
        page :: slop_os.memory_create(slop_os.startup_block().budget, 4096) or_return null
        if slop_os.memory_write(page, 0, made.locale[0..<count]) is_error {
            _ = slop_os.handle_close(cast[slop_os.Handle](page))
            return null
        }
        made.locale_page = page
    }
    rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_READ) | cast[u32](slop_os.RIGHT_TRANSFER))
    given :: slop_os.handle_duplicate(cast[slop_os.Handle](made.locale_page), rights)
    return match given {
        case Ok(copy) => cast[slop_os.Memory](copy)
        case Error(error) => null
    }
}

// Memory pressure (decisions/0153)

// The session the console shows now, its time shown counted; test_pressure's pressure brought on once two sessions are.
shown :: fn(sessions: ptr[mut Manager], number: u32) {
    sessions.shown = number
    sessions.showings += 1
    if cast[usize](number) < sessions.sessions.count {
        sessions.sessions[cast[usize](number)].shown_at = sessions.showings
    }
    if !sessions.test_pressure || number == session.NO_SESSION {
        return void
    }
    in_use := 0
    for each in sessions.sessions {
        if each.in_use {
            in_use += 1
        }
    }
    if in_use < 2 {
        return void
    }
    // A budget split off its own, up to its threshold, which raises its pressure
    sessions.test_pressure = false
    budget :: slop_os.startup_block().budget
    info :: slop_os.memory_budget_info(budget) or_return void
    threshold :: info.limit / 100 * PRESSURE_PERCENT
    if info.used < threshold {
        runtime.log_info("test_pressure: charging % bytes more, to its threshold", threshold - info.used)
        sessions.ballast = slop_os.memory_budget_create(budget, threshold - info.used) or_else cast[slop_os.MemoryBudget](slop_os.NO_HANDLE)
    }
}

/*
 * Pressure relieved: idle installations, those of the sessions not shown, the least recently shown session's first,
 * each asked to stop and ended, one at a time, until what its budget has charged is under RELIEVED_PERCENT of its
 * limit, or there are none left. test_pressure's charge given back after.
 */
relieve :: fn(sessions: ptr[mut Manager]) {
    budget :: slop_os.startup_block().budget
    stopped := 0
    loop {
        info :: slop_os.memory_budget_info(budget) or_break
        if info.used < info.limit / 100 * RELIEVED_PERCENT {
            break
        }
        idle := NOWHERE
        for &program, i in sessions.programs {
            if i >= sessions.count || !program.running || !program.installation || program.session == sessions.shown
                || cast[usize](program.session) >= sessions.sessions.count {
                continue
            }
            if idle == NOWHERE || idle >= sessions.programs.count
                || sessions.sessions[cast[usize](program.session)].shown_at < sessions.sessions[cast[usize](sessions.programs[idle].session) % sessions.sessions.count].shown_at {
                idle = i
            }
        }
        if idle == NOWHERE || idle >= sessions.programs.count {
            runtime.log_info("memory pressure: no idle installation left to stop, % of % bytes in use", info.used, info.limit)
            break
        }
        runtime.log_info("memory pressure: asking % in session % to stop", name_of(&sessions.programs[idle]), sessions.programs[idle].session)
        _ = end_program(sessions, idle, "under memory pressure")
        stopped += 1
    }
    if cast[slop_os.Handle](sessions.ballast) != slop_os.NO_HANDLE {
        _ = slop_os.handle_close(cast[slop_os.Handle](sessions.ballast))
        sessions.ballast = cast[slop_os.MemoryBudget](slop_os.NO_HANDLE)
        runtime.log_info("test_pressure: idle installations stopped: %; the shown session's left running", stopped)
    }
}

// Installations (decisions/0153)

// The system's installations started in session number.
start_installations :: fn(sessions: ptr[mut Manager], number: u32) {
    list :: read_installations(sessions)
    for i in cast[usize](0)..<list.entries.count {
        if i < cast[usize](list.count) {
            _ = start_installation(sessions, number, list.entries[i])
        }
    }
}

// The system's installations, as the config store has them: none without the store, or before they're written.
read_installations :: fn(sessions: ptr[mut Manager]) -> system_records.Installations {
    if sessions.list_end == NONE {
        return system_records.Installations.{}
    }
    value := os.Outgoing.{}
    if config.read(config.Config[system_records.Installations].{end = sessions.list_end}, sessions.list_port, &value) is_error {
        return system_records.Installations.{}
    }
    stored :: os.typed_value[system_records.Installations](os.value_bytes(&value))^
    if stored.set == 0 || (system_records.installations_check(&stored) is_some) {
        return system_records.Installations.{}
    }
    return stored
}

// The system's installations written to the config store, marked written: whether it kept them.
write_installations :: fn(sessions: ptr[mut Manager], list: system_records.Installations) -> bool {
    if sessions.list_end == NONE {
        return false
    }
    written := list
    written.set = 1
    if system_records.installations_check(&written) is_some {
        return false
    }
    value := os.Outgoing.{}
    os.begin[system_records.Installations](&value)^ = written
    fields :: config.field_bit[system_records.Installations]("count") | config.field_bit[system_records.Installations]("set")
        | config.field_bit[system_records.Installations]("entries")
    return config.write(config.Config[system_records.Installations].{end = sessions.list_end}, sessions.list_port, os.value_bytes(&value),
        fields) is_ok
}

/*
 * An installation started in session number: its bundle's program (the bundle it names, or the one the store's boot root
 * names after its program), if the bundle's manifest is the entry installations are launched with; its data directory,
 * apps/<name> in the session's apps directory, made if it isn't there; and its settings, the config store's value
 * "settings" of its owner (owner_of). Whether it started.
 */
start_installation :: fn(sessions: ptr[mut Manager], number: u32, entry: system_records.InstallationRecord) -> bool {
    name :: system_records.text_of(&entry.name)
    bundle_hash :: match installation_bundle(sessions, entry) {
        case Some(found) => found
        case None => {
            runtime.log_info("installation %: no bundle for %", name, system_records.text_of(&entry.program))
            return false
        }
    }
    program :: match installation_program(sessions, bundle_hash) {
        case Some(found) => found
        case None => {
            runtime.log_info("installation %: its bundle isn't one an installation can run", name)
            return false
        }
    }
    data := NONE
    if cast[usize](number) < sessions.sessions.count && sessions.sessions[cast[usize](number)].apps != NONE {
        data = opened_directory(sessions.sessions[cast[usize](number)].apps, name, true) or_else NONE
    }
    if data == NONE {
        runtime.log_info("installation %: no data directory for it", name)
        _ = slop_os.handle_close(cast[slop_os.Handle](program))
        return false
    }
    grants := InstallationGrants.{data = installations.AppData.{end = data}}
    grants.settings = settings_for[counter_app.CounterSettings](sessions, number, name)
    prepared :: match prepare(sessions, number, name) {
        case Some(made) => made
        case None => {
            _ = slop_os.handle_close(cast[slop_os.Handle](program))
            _ = slop_os.handle_close(cast[slop_os.Handle](data))
            return false
        }
    }
    return placed(sessions, number, name, prepared, os.launch(sessions.manager, sessions.manager_port, name, program, INSTALLATION_BUDGET,
        counter.main, grants, prepared.options), true)
}

// A connection to an installation's value of type T, "settings" of its owner in session number; null without one.
settings_for :: fn[T](sessions: ptr[mut Manager], number: u32, name: string) -> config.Config[T]? {
    if sessions.settings_end == NONE || cast[usize](number) >= sessions.sessions.count {
        return null
    }
    made :: &sessions.sessions[cast[usize](number)]
    owner : u8[OWNER_BYTES]
    count :: owner_of(user_of(made), name, &owner)
    out := os.Outgoing.{}
    request :: os.begin[config.Request](&out)
    request^ = .ValueFor(config.ValueFor.{owner = os.append(&out, owner[0..<count]), name = os.append(&out, string_bytes("settings"))})
    into := os.Incoming.{}
    return match config.ask(sessions.settings_end, sessions.settings_port, &out, &into) {
        case Opened(opened) => config.Config[T].{end = opened.end}
        case _ => null
    }
}

// The bundle an installation runs: the one it names, or the store's boot root's of its program's name.
installation_bundle :: fn(sessions: ptr[mut Manager], entry: system_records.InstallationRecord) -> bundle.Hash? {
    named := bundle.Hash.{bytes = entry.bundle}
    if !bundle.same(named, bundle.Hash.{}) {
        return named
    }
    return bundle_named(sessions, system_records.text_of(&entry.program))
}

// The bundle the store's boot root names name, or null.
bundle_named :: fn(sessions: ptr[mut Manager], name: string) -> bundle.Hash? {
    root :: match store_request(sessions, .Root) {
        case Rooted(hash) => hash
        case _ => return null
    }
    root_object :: mapped_object(sessions, root) or_return null
    defer unmap_object(root_object)
    names : string[..]
    defer runtime.array_free(&names)
    bundles : bundle.Hash[..]
    defer runtime.array_free(&bundles)
    if !(bundle.root_entries(root_object.bytes, &names, &bundles) or_else false) {
        return null
    }
    for entry_name, i in names {
        if entry_name == name && i < bundles.count {
            return bundles[i]
        }
    }
    return null
}

/*
 * A bundle's program, as paged memory from the store, if its manifest is the entry installations are launched with
 * (counter_app's, the schema of counter.main's type): null for one of another entry, which can't be given what it takes.
 */
installation_program :: fn(sessions: ptr[mut Manager], bundle_hash: bundle.Hash) -> slop_os.Memory? {
    return program_of(sessions, bundle_hash, bundle.Hash.{bytes = schema.hash(type_info_of(type_of(counter.main)))})
}

// A bundle's program, as paged memory from the store, if its manifest is expected, the schema of the entry it's launched with.
program_of :: fn(sessions: ptr[mut Manager], bundle_hash: bundle.Hash, expected: bundle.Hash) -> slop_os.Memory? {
    record :: mapped_object(sessions, bundle_hash) or_return null
    referred : bundle.Hash[..]
    defer runtime.array_free(&referred)
    read :: bundle.bundle_refers(record.bytes, &referred) or_else false
    unmap_object(record)
    if !read || referred.count < 2 {
        return null
    }
    manifest :: referred[1 % referred.count]
    program :: referred[0]
    if !bundle.same(manifest, expected) {
        return null
    }
    return match store_request(sessions, .Get(program)) {
        case Got(object) => object.memory
        case _ => null
    }
}

store_request :: fn(sessions: ptr[mut Manager], request: bundle_store.Request) -> bundle_store.Response {
    if sessions.store_end == NONE {
        return .Unsupported
    }
    out := os.Outgoing.{}
    os.begin[bundle_store.Request](&out)^ = request
    into := os.Incoming.{}
    return bundle_store.ask(sessions.store_end, sessions.store_port, &out, &into)
}

// An object from the store, mapped to read; null without it.
mapped_object :: fn(sessions: ptr[mut Manager], hash: bundle.Hash) -> MappedObject? {
    object :: match store_request(sessions, .Get(hash)) {
        case Got(got) => got
        case _ => return null
    }
    address :: map_in(object.memory, (object.size + 4095) & ~cast[u64](4095))
    if address == 0 {
        _ = slop_os.handle_close(cast[slop_os.Handle](object.memory))
        return null
    }
    return MappedObject.{memory = object.memory, address = address, bytes = view_of(cast[ptr[u8]](address), cast[usize](object.size))}
}

// memory mapped to read, at an address of its own: 0 if it can't be.
map_in :: fn(memory: slop_os.Memory, size: u64) -> u64 {
    if size == 0 {
        return 0
    }
    address :: runtime.reserve_addresses(cast[usize](size)) or_return 0
    if slop_os.memory_map(memory, slop_os.startup_block().space, address, 0, size, slop_os.PROTECTION_READ) is_error {
        return 0
    }
    return address
}

unmap_object :: fn(object: MappedObject) {
    _ = slop_os.memory_unmap(slop_os.startup_block().space, object.address)
    _ = slop_os.handle_close(cast[slop_os.Handle](object.memory))
}

/*
 * A session's apps directory: its home's apps, made if it isn't there, or for a session without a home, a connection of
 * its own to the system volume's; NONE without either.
 */
apps_of :: fn(sessions: ptr[mut Manager], home: os.Channel[dir.Dir]?) -> slop_os.Channel {
    return match home {
        case Some(root) => opened_directory(root.end, "apps", true) or_else NONE
        case None => if sessions.apps_end == NONE { NONE } else { connection_to(sessions.apps_end) or_else NONE }
    }
}

// The directory name beneath the one end speaks for, opened, made first if create and it isn't there; null if it can't be.
opened_directory :: fn(end: slop_os.Channel, name: string, create: bool) -> slop_os.Channel? {
    port :: os.port_for(slop_os.startup_block().budget, end) or_return null
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    out := os.Outgoing.{}
    request :: os.begin[dir.Request](&out)
    request^ = .OpenDirectory(dir.OpenDirectory.{path = os.append(&out, string_bytes(name)), create = create})
    if dir.send_request(end, port, &out) is_some {
        return null
    }
    into := os.Incoming.{}
    loop {
        match dir.receive_response(end, port, &into, true) {
            case Received => break
            case Failed(error) => return null
            case _ => continue
        }
    }
    return match os.message_of[dir.Response](&into)^ {
        case OpenedDirectory(opened) => opened.end
        case _ => null
    }
}

// Another connection to the directory end speaks for, its one end sent to its server, which takes it without answering.
connection_to :: fn(end: slop_os.Channel) -> slop_os.Channel? {
    budget :: slop_os.startup_block().budget
    pair :: os.channel_for[dir.Dir](budget, 0) or_return null
    port :: os.port_for(budget, end) or_else cast[slop_os.Port](slop_os.NO_HANDLE)
    out := os.Outgoing.{}
    os.begin[dir.Request](&out)^ = .Connect(os.Channel[dir.Dir].{end = pair.a})
    if cast[slop_os.Handle](port) == slop_os.NO_HANDLE || (dir.send_request(end, port, &out) is_some) {
        if cast[slop_os.Handle](port) != slop_os.NO_HANDLE {
            _ = slop_os.handle_close(cast[slop_os.Handle](port))
        }
        _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
        return null
    }
    _ = slop_os.handle_close(cast[slop_os.Handle](port))
    return pair.b
}

// The installation named name in session number, if it's running, asked to stop, and ended.
stop_installation :: fn(sessions: ptr[mut Manager], number: u32, name: string) {
    for i in 0..<sessions.count {
        if i < sessions.programs.count && sessions.programs[i].running && sessions.programs[i].installation
            && sessions.programs[i].session == number && name_of(&sessions.programs[i]) == name {
            _ = end_program(sessions, i, "to change its installation")
        }
    }
}

/*
 * An installation removed, by session number: stopped there, taken from the system's list, its data directory in the
 * session's apps directory deleted, and its settings forgotten. Whether all of it went.
 */
uninstall :: fn(sessions: ptr[mut Manager], number: u32, name: string) -> bool {
    stop_installation(sessions, number, name)
    list :: read_installations(sessions)
    kept := system_records.Installations.{}
    for i in cast[usize](0)..<list.entries.count {
        if i < cast[usize](list.count) && system_records.text_of(&list.entries[i].name) != name {
            at :: cast[usize](kept.count)
            if at < kept.entries.count {
                kept.entries[at] = list.entries[i]
                kept.count += 1
            }
        }
    }
    whole := write_installations(sessions, kept)
    if cast[usize](number) >= sessions.sessions.count {
        return false
    }
    made :: &sessions.sessions[cast[usize](number)]
    // Its data: the files in its directory, then the directory
    if made.apps == NONE {
        return false
    }
    apps :: connection_to(made.apps) or_return false
    directory, error :: os.directory_on(apps)
    if error == null {
        match os.list_directory_in(directory, name) {
            case Ok(listed) => {
                for each in listed {
                    storage : u8[256]
                    path :: joined_path(name, each.name, &storage)
                    whole = os.delete_file_in(directory, path) == null && whole
                }
                os.free_directory_listing(listed)
                whole = os.remove_directory_in(directory, name) == null && whole
            }
            case Error(failure) => {}
        }
        os.close_directory(directory)
    }
    // Its settings
    if sessions.settings_end == NONE {
        return false
    }
    owner : u8[OWNER_BYTES]
    count :: owner_of(user_of(made), name, &owner)
    out := os.Outgoing.{}
    request :: os.begin[config.Request](&out)
    request^ = .Forget(os.append(&out, owner[0..<count]))
    into := os.Incoming.{}
    match config.ask(sessions.settings_end, sessions.settings_port, &out, &into) {
        case Done => {}
        case _ => whole = false
    }
    return whole
}

// a/b, into storage.
joined_path :: fn(a: string, b: string, storage: ptr[mut u8[256]]) -> string {
    count := cast[usize](0)
    for text in string.[a, "/", b] {
        for character in text {
            if count < storage.count {
                storage^[count] = cast[u8](character)
                count += 1
            }
        }
    }
    return if count > 0 { string_of(&storage^[0], count) } else { "" }
}

/*
 * test_installations, in the first session with a user, once it's been answered for: the counter, once it's counted,
 * refused an update to hello's bundle, whose entry isn't the installations'; updated to counter_next's, which counts on
 * from its data; uninstalled, its data and settings with it; and installed again, counting from 1.
 */
check_installations :: fn(sessions: ptr[mut Manager], number: u32) {
    list := read_installations(sessions)
    if list.count == 0 || !counted(sessions, number, "counter", 1) {
        runtime.log_info("test_installations: no installations")
        return void
    }
    // An update to a bundle of another entry is refused before it's written
    hello_bundle :: bundle_named(sessions, "hello") or_else bundle.Hash.{}
    refused :: installation_program(sessions, hello_bundle) is_none
    // Updated: stopped, then started from the bundle it runs now, its data kept
    stop_installation(sessions, number, "counter")
    next :: bundle_named(sessions, "counter_next") or_else bundle.Hash.{}
    entry := list.entries[0]
    list.entries[0].bundle = next.bytes
    updated :: write_installations(sessions, list) && start_installation(sessions, number, list.entries[0]) && counted(sessions, number, "counter", 2)
    // Uninstalled, and installed again as it was first
    removed :: uninstall(sessions, number, "counter")
    again := read_installations(sessions)
    at :: cast[usize](again.count)
    if at < again.entries.count {
        again.entries[at] = entry
        again.count += 1
    }
    reinstalled :: write_installations(sessions, again) && start_installation(sessions, number, entry) && counted(sessions, number, "counter", 1)
    runtime.log_info("test_installations: an update to hello's bundle %, updated to counter_next %, uninstalled %, installed again %",
        if refused { "refused" } else { "taken" }, if updated { "and run" } else { "not run" }, if removed { "whole" } else { "not whole" },
        if reinstalled { "and run" } else { "not run" })
}

// Whether the counter named name in session number has counted to count, in its data directory's file count, waited for.
counted :: fn(sessions: ptr[mut Manager], number: u32, name: string, count: u64) -> bool {
    if cast[usize](number) >= sessions.sessions.count || sessions.sessions[cast[usize](number)].apps == NONE {
        return false
    }
    deadline :: (slop_os.clock_monotonic() or_else 0) + COUNT_WAIT
    loop {
        data :: opened_directory(sessions.sessions[cast[usize](number)].apps, name, false) or_else NONE
        if data != NONE {
            directory, error :: os.directory_on(data)
            if error == null {
                found := cast[u64](0)
                match os.read_entire_file_in(directory, "count") {
                    case Ok(text) => {
                        found = counter_app.number_of(text)
                        runtime.free_array(bit_cast[u8[]](text))
                    }
                    case Error(failure) => {}
                }
                os.close_directory(directory)
                if found == count {
                    return true
                }
            }
        }
        if (slop_os.clock_monotonic() or_else 0) >= deadline {
            return false
        }
        pause(sessions, 50_000_000)
    }
}

// A session's user's name, empty for none.
user_of :: fn(made: ptr[Session]) -> u8[] {
    count :: made.user_bytes
    return if count <= made.user.count { made.user[0..<count] } else { made.user[0..<0] }
}

// A port for end, or none.
port_of :: fn(end: slop_os.Channel) -> slop_os.Port {
    return os.port_for(slop_os.startup_block().budget, end) or_else cast[slop_os.Port](slop_os.NO_HANDLE)
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
