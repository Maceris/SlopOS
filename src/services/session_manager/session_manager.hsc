/**
 * The session manager (decisions/0149, 0150, design/console-and-sessions.md §5): it makes a session once the trusted
 * path has logged someone in, and starts its first program, echo until the shell, with the session's terminal
 * connection and its home volume's root; on a boot with no accounts, the one session there is, with no user. It serves
 * the session protocol on its listener: Start and StartWithoutUser, List with a session's programs, each pinged on its
 * lifecycle channel, End, a Stop on that channel, then the program killed if it hasn't ended once a grace period's
 * over, and EndSession, every program of a session ended so. There are up to MAX_SESSIONS at once (decisions/0151). A
 * session's programs' budgets are split off its own, the session's node, and their log records go to the
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
import read_only_file from "std/os/slop_os"
import lifecycle from "std/os/slop_os"
import process_manager from "std/os/slop_os"
import terminal from "std/os/slop_os"
import network from "std/os/slop_os"
import schema from "std"
import strings from "std"
import echo from "../../apps/echo"
import shell from "../../apps/shell"
import programs from "../../protocols/programs"
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
import crash_reports from "../../crash_reports"

/** No channel: what a channel field is when there's none. */
NONE : slop_os.Channel : cast[slop_os.Channel](slop_os.NO_HANDLE)
/** The port key a program's end is watched under, plus its index among the programs. */
PROGRAM_KEY : u64 : 1000
/**
 * The port key a program's faults' intercept reports under, plus its index among the programs (decisions/0183): its
 * stops come as packets of kind Stop.
 */
CRASH_KEY : u64 : 2000
/** The port key the session manager's budget's pressure is bound under. */
PRESSURE_KEY : u64 : 900
/** The port key a session's shell's programs connection is bound under, plus the session's number. */
PROGRAMS_KEY : u64 : 800
/** The port key a finding connection's bound under, plus its index among the finders (decisions/0179, 11e6). */
FINDER_KEY : u64 : 850
/** The most installations remembered as stopped under memory pressure, to start again when their session's shown. */
MAX_PRESSED :: 16
/** The most finding connections, scripts' shells', open at once, across the sessions. */
MAX_FINDERS :: 8
/** The percentage of its budget's limit at which the session manager's under memory pressure. */
PRESSURE_PERCENT : u64 : 80
/** The percentage of its budget's limit it stops idle installations until it's under. */
RELIEVED_PERCENT : u64 : 70
/** The most programs of every session at once, first programs, powerboxes and installations together. */
MAX_PROGRAMS :: 16
/** The most sessions at once (decisions/0151). */
MAX_SESSIONS :: 4
/** echo's memory budget, in bytes. */
ECHO_BUDGET : u64 : 2 * 1024 * 1024
/** The shell's memory budget, in bytes, which the programs it runs have theirs split off. */
SHELL_BUDGET : u64 : 16 * 1024 * 1024
/** How long a program has to answer a Ping, in nanoseconds. */
PING_WAIT : u64 : 200_000_000
/** How long a program has to stop once asked, in nanoseconds, before it's killed. */
STOP_GRACE : u64 : 2_000_000_000
/** The most bytes of a session's user's name; a longer name's session is refused. */
USER_BYTES :: 32
/** The most bytes of a session's locale's name. */
LOCALE_BYTES :: 16
/** The most bytes of a config store owner: "user:", a user's name, ":" and an installation's name; more are cut. */
OWNER_BYTES :: 80
/** An installation's memory budget, in bytes. */
INSTALLATION_BUDGET : u64 : 4 * 1024 * 1024
/** A session's powerbox's memory budget, in bytes. */
POWERBOX_BUDGET : u64 : 2 * 1024 * 1024
/** How long test_installations waits for the counter to count, in nanoseconds. */
COUNT_WAIT : u64 : 20_000_000_000
/** No index: checking's value when test_installations has no session to check. */
NOWHERE : usize : ~cast[usize](0)

/** A user's settings for their sessions, in the config store: "session" of owner "user:" and their name. */
SessionSettings :: struct {
    /** A std/locale name, as "en-GB"; empty until it's chosen. Only en-US and en-GB are taken. */
    locale : slop_os.Relative[u8],
    /**
     * The bytes of records the events service keeps of each of the session's programs (decisions/0185, 12g), from
     * events.MIN_BUDGET; 0 for events.SESSION_BUDGET.
     */
    events_budget : u64,
    /**
     * The share of a CPU each of the user's sessions is guaranteed, in millionths (decisions/0187); 0 for a quarter of
     * the sessions' share. One that doesn't fit what's left of the sessions' share runs the session on the session
     * manager's budget.
     */
    cpu_share : u64,
}

/**
 * What the shell is given (shell.main), as each session's first program (decisions/0169, 0174).
 */
ShellGrants :: struct {
    /** A copy of the session manager's debug log, or null without one. */
    log : slop_os.DebugLog?,
    /** The session's terminal connection, which moves to the shell. */
    session_terminal : os.Channel[terminal.Terminal],
    /** The session's home volume's root, which moves to the shell; null for a session with no user. */
    home : os.Channel[dir.Dir]?,
    /** A connection of its own to the process manager, to launch what it calls; null if one couldn't be made. */
    manager : os.Channel[process_manager.ProcessManager]?,
    /** Its programs connection (decisions/0170), to find programs in the bundle store; null if one couldn't be made. */
    programs : os.Channel[programs.Programs]?,
    /**
     * Its data directory, SHELL_DATA in the session's apps directory, made if it isn't there, where it keeps its
     * history; null for a session without an apps directory.
     */
    data : installations.AppData?,
    /** A script to run instead of reading lines (decisions/0179, 11e6): never one for a session's first program. */
    script : os.Channel[read_only_file.ReadOnlyFile]?,
    /**
     * Its session's CPU budget with the right to split it, for a child of it for each job (decisions/0187); null for a
     * session without a budget of its own.
     */
    cpu_budget : slop_os.CpuBudget?,
    /**
     * The session's network connection (decisions/0188, 13c): public addresses, any port, no listening; copies of it
     * go to programs that take one. Null without a network.
     */
    network : os.Channel[network.Network]?,
    /** One line to run in place of reading lines, as SSH's exec asks (decisions/0191); null to read lines. */
    command : string?,
}

/**
 * Dial the network service, for the connection allowing everything that sessions' are made from.
 *
 * @param sessions The manager, whose network_end is set once it's dialed; without it, sessions have no network.
 * @param dialing The connector to the network service.
 */
take_network :: fn(sessions: ptr[mut Manager], dialing: os.Channel[connector.Connector]) {
    block :: slop_os.startup_block()
    port :: os.port_for(block.budget, dialing.end) or_return void
    match connector.dial[network.Network](dialing.end, port) {
        case Some(connection) => match os.port_for(block.budget, connection.end) {
            case Some(bound) => {
                sessions.network_end = connection.end
                sessions.network_port = bound
            }
            case None => _ = slop_os.handle_close(cast[slop_os.Handle](connection.end))
        }
        case None => runtime.log_info("no network for the sessions")
    }
    _ = slop_os.handle_close(cast[slop_os.Handle](port))
}

/**
 * Make a network connection for a session: its shell's, narrowed to public addresses, any port, and no listening; or
 * its powerbox's, allowing everything, which what the user allows a program is narrowed from.
 *
 * @param sessions The manager.
 * @param narrowed True for the shell's; false for the powerbox's.
 * @return The connection, which moves to who it's for; null without a network.
 */
session_network :: fn(sessions: ptr[mut Manager], narrowed: bool) -> os.Channel[network.Network]? {
    if sessions.network_end == NONE {
        return null
    }
    if narrowed {
        policy := network.public_only()
        return network.narrow(sessions.network_end, sessions.network_port, &policy)
    }
    return network.copy(sessions.network_end, sessions.network_port)
}

/**
 * The shell's data directory's name in a session's apps directory: begun with a dot, which an installation's name
 * can't have (system_records.valid_name), so it's never an installation's.
 */
SHELL_DATA :: ".shell"

/** What echo is given (echo.main): the session's terminal, its home volume's root if it has one, and its powerbox. */
EchoGrants :: struct {
    /** A copy of the session manager's debug log, or null without one. */
    log : slop_os.DebugLog?,
    /** The session's terminal connection, which moves to echo. */
    session_terminal : os.Channel[terminal.Terminal],
    /** The session's home volume's root, which moves to echo; null for a session with no user. */
    home : os.Channel[dir.Dir]?,
    /** A connection to the session's powerbox, served under echo's name; null without a powerbox. */
    powerbox : os.Channel[powerbox.Powerbox]?,
}

/**
 * What the powerbox is given (powerbox_service.main): the session's home, the trusted path's prompt connection, and the
 * session manager's connection, on which it's asked to serve each program.
 */
PowerboxGrants :: struct {
    /** Another connection to the session's home, its own; null if one couldn't be made, or there's no home. */
    home : os.Channel[dir.Dir]?,
    /** The trusted path's prompt connection, which moves to the powerbox. */
    prompts : os.Channel[prompt.Prompt],
    /** The powerbox's end of its connection to the session manager, which sends it Serve for each program. */
    manager : os.Channel[powerbox.Powerbox],
    /**
     * A programs connection of the powerbox's own (decisions/0185, 12f), the only one Attach is taken on, to attach a
     * debugger once the user's allowed it; null if it couldn't be made.
     */
    programs : os.Channel[programs.Programs]?,
    /**
     * A network connection allowing everything (decisions/0188, 13c), which what the user allows a program is narrowed
     * from; null without a network.
     */
    network : os.Channel[network.Network]?,
}

/** A session: whether it's one now, and its user's name, empty for a boot with no accounts. */
Session :: struct {
    /** Whether this place holds a session now. */
    in_use : bool,
    /** Its user's name, the first user_bytes of it. */
    user : u8[USER_BYTES],
    /** How many bytes its user's name has: 0 for a session with no user. */
    user_bytes : usize,
    /** Its user's programs' records' budget, from their settings; 0 for events.SESSION_BUDGET. */
    events_budget : u64,
    /** Its locale's name, the first locale_bytes of it. */
    locale : u8[LOCALE_BYTES],
    /** How many bytes its locale's name has: 0 for none, as for a session with no user. */
    locale_bytes : usize,
    /**
     * The page holding its locale's name, which its programs are given read-only copies of, kept while the session
     * lasts, since closing it would take the copies with it; NO_HANDLE until it's first given.
     */
    locale_page : slop_os.Memory,
    /** Its apps directory, its installations' data directories' parent, the session manager's own; NONE for none. */
    apps : slop_os.Channel,
    /** When it was last shown, by the count of Shown, 0 for never. */
    shown_at : u64,
    /** Its powerbox's connection for the session manager, the session manager's own; NONE for none. */
    powerbox_end : slop_os.Channel,
    /** A port bound to powerbox_end, waited on for the powerbox's answers; unset without one. */
    powerbox_port : slop_os.Port,
    /** Its shell's programs connection (decisions/0170), bound to the session manager's port; NONE for none. */
    programs_end : slop_os.Channel,
    /**
     * Its CPU budget, a child of the sessions' (decisions/0187), the owning handle, which every one of its programs runs
     * on, destroyed when it ends; NO_HANDLE for none, when they run on the session manager's.
     */
    cpu_budget : slop_os.CpuBudget,
    /** Its share of a CPU, in millionths, as asked for; 0 for the default. */
    cpu_share : u64,
    /** Whether its first program has ended, and how: its exit code, or EXIT_KILLED. */
    first_ended : bool,
    exit_code : u64,
    /** The client waiting for its first program's end (Wait), its end the client's; NONE for none. */
    waiter : slop_os.Channel,
}

/**
 * A program of a session's: its name, its session's number, its process and budget, its lifecycle channel's end, and
 * whether it's running.
 */
Program :: struct {
    /** Its session's number, its index among the sessions. */
    session : u32,
    /** Its name, the first name_bytes of it, as it was launched: "echo", "shell", "powerbox", or an installation's. */
    name : u8[session.NAME_BYTES],
    /** How many bytes its name has. */
    name_bytes : u8,
    /** Its process, the session manager's handle, closed once it's ended. */
    process : slop_os.Process,
    /** Its memory budget, split off the session manager's, closed, so given back, once it's ended. */
    budget : slop_os.MemoryBudget,
    /** The session manager's end of its lifecycle channel, for Ping and Stop; closed once it's ended. */
    lifecycle : slop_os.Channel,
    /**
     * Its log records' ring, the owning handle, kept to give back once it's ended (events' Retire); NO_HANDLE for
     * none.
     */
    ring : slop_os.Memory,
    /** Whether it's running; a place whose program isn't is free for the next. */
    running : bool,
    /** Whether it's one of the system's installations, not the session's first program. */
    installation : bool,
    /** Its faults' intercept and address space, the session manager's, closed once it's ended; null without them. */
    faults : os.LaunchedFaults?,
    /** Where its image is in its address space, for its crash reports. */
    image : u64,
    /** The name of the program it runs, the first program_bytes of it: an installation's program, not its name. */
    program_name : u8[session.NAME_BYTES],
    /** How many bytes program_name has. */
    program_bytes : u8,
}

/**
 * What a program's launch is given, made ready: its place among the programs, its options, and the ends of its
 * lifecycle channel and its log records' ring that the session manager keeps.
 */
Prepared :: struct {
    /** Its place among the programs: one a program that ended left, or the next after them. */
    index : usize,
    /** The launch's options: its end watched on the session manager's port, its lifecycle end, locale and ring. */
    options : os.LaunchOptions,
    /** The session manager's end of its lifecycle channel. */
    lifecycle : slop_os.Channel,
    /** The owning handle of its log records' ring; NO_HANDLE without the events service. */
    ring : slop_os.Memory,
}

/**
 * An object from the bundle store, copied to the session manager's heap to read, never mapped, so the store ending
 * meanwhile only fails the read (decisions/0098, 0181's F6).
 */
StoredObject :: struct {
    /** The object's bytes, from the context's allocator, freed by let_go_of_object. */
    bytes : u8[],
}

/**
 * An installation stopped under memory pressure (decisions/0181, F3), started again when its session's next shown.
 */
Pressed :: struct {
    /** Whether this place holds one. */
    in_use : bool,
    /** Its session's number. */
    session : u32,
    /** Its name, the first name_bytes of it. */
    name : u8[session.NAME_BYTES],
    /** How many bytes its name has. */
    name_bytes : u8,
}

/** A finding connection: a session's, which only finds programs (programs.Request.Connect). */
Finder :: struct {
    /** Whether this place holds one. */
    in_use : bool,
    /** Its session's number. */
    session : u32,
    /** The session manager's end, bound to its port under FINDER_KEY and the finder's index. */
    end : slop_os.Channel,
    /** Whether it's the session's powerbox's, the only connection Attach is taken on (decisions/0185). */
    powerbox : bool,
}

/** The session manager's state: its connections, its sessions and their programs, and its tests' progress. */
Manager :: struct {
    /** Its debug log, which programs it starts are given copies of; NO_HANDLE without one. */
    log : slop_os.DebugLog,
    /** The port it waits on: clients, programs' ends, shells' programs connections and its budget's pressure. */
    port : slop_os.Port,
    /** Its connection to the process manager, dialed through the manager grant, which it launches through. */
    manager : os.Channel[process_manager.ProcessManager],
    /** A port bound to manager, for the process manager's answers. */
    manager_port : slop_os.Port,
    /** echo's program, which each launch is given a copy of; null without one, when echo can't start. */
    echo_module : slop_os.Memory?,
    /** The events service, which opens and retires its programs' log rings; NONE without it. */
    events_end : slop_os.Channel,
    /** A port for events_end. */
    events_port : slop_os.Port,
    /** The config store's connection for users' values; NONE without it. */
    settings_end : slop_os.Channel,
    /** A port for settings_end. */
    settings_port : slop_os.Port,
    /** The bundle store, where the shell, the powerbox and the installations' programs come from; NONE without it. */
    store_end : slop_os.Channel,
    /** A port for store_end. */
    store_port : slop_os.Port,
    /** The system volume's apps directory, for a session with no user; NONE without it. */
    apps_end : slop_os.Channel,
    /** The system's list of installations, the config store's value "installations" of owner "system"; NONE without. */
    list_end : slop_os.Channel,
    /** A port for list_end. */
    list_port : slop_os.Port,
    /** Whether test_installations is still to come, in the first session with a user. */
    test_installations : bool,
    /** The session test_installations checks once it's been answered for, or NOWHERE. */
    checking : usize,
    /** The session the console shows, or session.NO_SESSION. */
    shown : u32,
    /** How many times it's been told which session's shown; a session's shown_at is this when it was. */
    showings : u64,
    /** Whether test_pressure is still to come, once two sessions are. */
    test_pressure : bool,
    /** Whether test_session_cpu is still to come, once two sessions are (decisions/0187). */
    test_session_cpu : bool,
    /**
     * Whether use_echo makes echo each session's first program, in the shell's place, as tests of the terminal and the
     * powerbox drive it.
     */
    use_echo : bool,
    /** The budget test_pressure charges its own with to bring on pressure, until it's relieved; NO_HANDLE for none. */
    ballast : slop_os.MemoryBudget,
    /**
     * The sessions' CPU budget, with the right to split it, for each session's (decisions/0187); NO_HANDLE without
     * one, when every session runs on the session manager's.
     */
    cpu_budget : slop_os.CpuBudget,
    /**
     * Its network connection, allowing everything (decisions/0188, 13c), which each session's are narrowed or copied
     * from; NONE without a network.
     */
    network_end : slop_os.Channel,
    /** A port bound to network_end, waited on for its answers. */
    network_port : slop_os.Port,
    /** The sessions, by number. */
    sessions : Session[MAX_SESSIONS],
    /** Every session's programs, the first count of them in use or once used. */
    programs : Program[MAX_PROGRAMS],
    /** The finding connections, scripts' shells' (decisions/0179, 11e6). */
    finders : Finder[MAX_FINDERS],
    /** The installations stopped under memory pressure, to start again when their sessions are shown. */
    pressed : Pressed[MAX_PRESSED],
    /** How many of programs have been used: those after it never have. */
    count : usize,
}

/**
 * Make sessions for those the trusted path logs in, and run each session's programs.
 *
 * It serves the session protocol on its listener until the system ends: Start and StartWithoutUser make a session and
 * start its first program, List gives a session's programs, End and EndSession end a program or a whole session, and
 * Shown says which session the console shows. A session's first program is the shell, from the bundle store, or echo
 * without one. Its command line's words test_installations, test_pressure and test_session_cpu turn on its tests, and
 * use_echo starts echo in the shell's place. Each session runs on a CPU budget of its own, split off cpu_budget
 * (decisions/0187).
 *
 * @param log The kernel's debug log, which every program it starts is given a copy of. Without it, they're given none.
 * @param manager The connector to the process manager, dialed for the connection programs are launched through.
 * @param echo_module echo's program, a session's first program with use_echo, or without a shell in the bundle store.
 *     Without either, a session can't start, and Start is refused.
 * @param events_service The events service, which opens a log records' ring for each program and reads what's left in
 *     it once it's ended. Without it, programs log to no ring.
 * @param settings The config store's connection for users' values: each user's locale, and installations' settings.
 *     Without it, each session's locale is the one its keyboard layout suggests, and installations have no settings.
 * @param store The bundle store, where the shell, each session's powerbox and the installations' programs come from.
 *     Without it, there's no powerbox, no installation, and no shell: echo's started instead.
 * @param apps The system volume's apps directory, the installations' data directories' parent for a session with no
 *     user. Without it, such a session runs no installations.
 * @param installation_list The system's list of installations in the config store. Without it, sessions run none.
 * @param command_line The kernel's command line, read for test_installations, test_pressure, test_session_cpu and
 *     use_echo. Without it, none of them is on.
 * @param clients Where connections from the session protocol's clients, the trusted path, arrive; more come through
 *     Connect.
 * @param cpu_budget The sessions' CPU budget, which it may split, for each session's (decisions/0187). Without it,
 *     every session runs on the session manager's own.
 * @return 1 if its port couldn't be made or bound to its budget's pressure; 2 if the process manager couldn't be
 *     dialed; 3 if the clients' listener couldn't be bound. It doesn't return otherwise.
 */
main :: fn(log: slop_os.DebugLog?, manager: os.Channel[connector.Connector], echo_module: slop_os.Memory?,
    events_service: os.Channel[events.Events]?, settings: os.Channel[config.ConfigValue]?, store: os.Channel[bundle_store.BundleStore]?,
    apps: os.Channel[dir.Dir]?, installation_list: config.Config[system_records.Installations]?, command_line: slop_os.Memory?,
    clients: os.Listener[session.Session], cpu_budget: slop_os.CpuBudget?, network: os.Channel[connector.Connector]?) -> int {
    block :: slop_os.startup_block()
    sessions := runtime.new(Manager)
    sessions.network_end = NONE
    match network {
        case Some(dialing) => take_network(sessions, dialing)
        case None => {}
    }
    sessions.cpu_budget = cpu_budget or_else cast[slop_os.CpuBudget](slop_os.NO_HANDLE)
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
            sessions.test_session_cpu = service_kit.has_word(text, "test_session_cpu")
            sessions.use_echo = service_kit.has_word(text, "use_echo")
        }
        case None => {}
    }
    sessions.port = slop_os.port_create(block.budget) or_return 1
    _ = service_kit.watch_stop(sessions.port)
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
        serve_programs(sessions, &into)
        serve_finders(sessions, &into)
        // test_installations, once the session it's for has been answered for
        if sessions.checking != NOWHERE {
            check_installations(sessions, cast[u32](sessions.checking))
            sessions.checking = NOWHERE
            continue
        }
        // Asked to stop, as the system shuts down (decisions/0182): what it was doing is done
        if service_kit.stopping() {
            return 0
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

/**
 * Mark the programs whose ends came among packets ended: their rings retired, and their process, budget and
 * lifecycle channel closed, which gives the budget back to the session manager's.
 *
 * @param sessions The session manager: each program whose end came is marked not running, its ring retired
 *     through the events service, and its handles closed.
 * @param packets The packets a port wait gave; those that aren't a program's end's signal are skipped.
 * @param taken How many of packets the wait filled.
 */
ended_in :: fn(sessions: ptr[mut Manager], packets: slop_os.Packet[], taken: usize) {
    for packet, i in packets {
        if i < taken && packet.kind == .Stop && packet.key >= CRASH_KEY && packet.key < CRASH_KEY + cast[u64](MAX_PROGRAMS) {
            crashed(sessions, cast[usize](packet.key - CRASH_KEY))
            continue
        }
        if i >= taken || packet.kind != .Signal || packet.key < PROGRAM_KEY {
            continue
        }
        index :: cast[usize](packet.key - PROGRAM_KEY)
        if index < sessions.count && index < sessions.programs.count && sessions.programs[index].running {
            program :: &sessions.programs[index]
            program.running = false
            runtime.log_info("% ended", name_of(program))
            first_ended(sessions, program, packet.data[1])
            retire_ring(sessions, program.ring)
            program.ring = cast[slop_os.Memory](slop_os.NO_HANDLE)
            // Its process, its budget, given back to the session manager's, and its lifecycle channel closed
            for handle in slop_os.Handle.[cast[slop_os.Handle](program.process), cast[slop_os.Handle](program.budget),
                cast[slop_os.Handle](program.lifecycle)] {
                _ = slop_os.handle_close(handle)
            }
            match program.faults {
                case Some(faults) => {
                    _ = slop_os.handle_close(cast[slop_os.Handle](faults.intercept))
                    _ = slop_os.handle_close(cast[slop_os.Handle](faults.space))
                }
                case None => {}
            }
            program.faults = null
        }
    }
}

/**
 * Note a session's first program's end, and answer the client waiting for it (Wait), if there is one.
 *
 * @param sessions The session manager.
 * @param program The program that ended; one that's the session's powerbox or an installation isn't its first.
 * @param code How it ended: its exit code, or EXIT_KILLED.
 */
first_ended :: fn(sessions: ptr[mut Manager], program: ptr[Program], code: u64) {
    if program.installation || is_named(program, "powerbox") || cast[usize](program.session) >= sessions.sessions.count {
        return void
    }
    made :: &sessions.sessions[cast[usize](program.session)]
    made.first_ended = true
    made.exit_code = code
    if made.waiter != NONE {
        out := os.Outgoing.{}
        os.begin[session.Response](&out)^ = .Exited(code)
        _ = session.send_response(made.waiter, sessions.port, &out)
        made.waiter = NONE
    }
}

/** Whether a program's name is the one given. */
is_named :: fn(program: ptr[Program], name: string) -> bool {
    given :: string_bytes(name)
    if cast[usize](program.name_bytes) != given.count {
        return false
    }
    for byte, i in given {
        if i < program.name.count && program.name[i] != byte {
            return false
        }
    }
    return true
}

/**
 * Take a session program's fault stops: report each, logged as a typed record, and kill the program, whose end then
 * comes as any other's (decisions/0183).
 *
 * @param sessions The session manager, whose program at index is reported on.
 * @param index The program's index among the programs; one not running, or without a faults' intercept, is left.
 */
crashed :: fn(sessions: ptr[mut Manager], index: usize) {
    if index >= sessions.count || index >= sessions.programs.count || !sessions.programs[index].running {
        return void
    }
    program :: &sessions.programs[index]
    faults :: program.faults or_return void
    storage := crash_reports.Storage.{}
    // A copy on the heap, for the reports to point to
    name :: strings.clone(name_of(program)) or_return void
    defer strings.free_string(name)
    reports :: crash_reports.take(program.process, faults, program.image, name, &storage)
    for &report in reports {
        crash_reports.log(report^)
    }
    if reports.count > 0 {
        runtime.log_info("% crashed: %", name_of(program), slop_os.fault_name(reports[0].fault))
        _ = slop_os.process_kill(program.process)
    }
}

/**
 * Answer every request a client has sent, until there are none left, or it's gone, in which case it's dropped.
 *
 * End and EndSession wait for programs to stop, up to STOP_GRACE each, and List up to PING_WAIT for their Pongs, so
 * other clients wait meanwhile. Connect adds a client and isn't answered.
 *
 * @param sessions The session manager, whose port the client's end is bound to; its requests start and end
 *     sessions and programs, which can wait on that port for STOP_GRACE or PING_WAIT.
 * @param connected The clients bound to the session manager's port; Connect adds one, and a client whose channel
 *     fails is dropped, its end closed.
 * @param index The client's index among them; past them, or a client that's gone, nothing's done.
 * @param into Where each request is received, reused.
 */
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
            case _ => {
                service_kit.drop_client(connected, index)
                return void
            }
        }
        out := os.Outgoing.{}
        response :: os.begin[session.Response](&out)
        match os.message_of[session.Request](into)^ {
            case Start(given) => response^ = start(sessions, os.items(into, given.user), os.items(into, given.layout), given.terminal, given.home,
                given.prompts, os.items(into, given.command))
            case Wait(number) => {
                if cast[usize](number) >= sessions.sessions.count || !sessions.sessions[cast[usize](number)].in_use {
                    response^ = .Refused
                }
                else if sessions.sessions[cast[usize](number)].first_ended {
                    response^ = .Exited(sessions.sessions[cast[usize](number)].exit_code)
                }
                else {
                    // Answered when it ends
                    sessions.sessions[cast[usize](number)].waiter = end
                    continue
                }
            }
            case StartWithoutUser(given) => response^ = start(sessions, u8.[], u8.[], given, null, null, u8.[])
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

/**
 * Make a session and start its programs: its powerbox, if it's given the prompt connection, its first program with
 * its terminal and home, and the system's installations.
 *
 * Its locale is its user's (locale_for). If test_installations is still to come and the session has a user, it's the
 * session the test is run in, once this has been answered.
 *
 * @param sessions The session manager, which takes the first free session's place, and starts and keeps the
 *     session's programs.
 * @param user The user's name, copied; empty for a boot with no accounts, a session with no user, no locale and no
 *     powerbox. One longer than USER_BYTES is refused.
 * @param layout The keyboard layout they logged in with, like "uk", which suggests their locale if they have none.
 * @param given_terminal The session's terminal connection, which moves to its first program, or is closed when the
 *     session's refused for want of room.
 * @param home The root of the user's home volume, which moves to the first program; null for none.
 * @param prompts The trusted path's prompt connection, which moves to the powerbox; null for no powerbox.
 * @return Started with the session's number; Refused when there's no room for another, the user's name is too long,
 *     or its first program didn't start.
 */
start :: fn(sessions: ptr[mut Manager], user: u8[], layout: u8[], given_terminal: os.Channel[terminal.Terminal], home: os.Channel[dir.Dir]?,
    prompts: os.Channel[prompt.Prompt]?, command: u8[]) -> session.Response {
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
        powerbox_end = NONE, programs_end = NONE, cpu_budget = cast[slop_os.CpuBudget](slop_os.NO_HANDLE), waiter = NONE}
    for byte, i in user {
        if i < made.user.count {
            made.user[i] = byte
        }
    }
    if user.count > 0 {
        settings :: user_settings(sessions, user)
        made.events_budget = if settings.events_budget >= events.MIN_BUDGET { settings.events_budget } else { cast[u64](0) }
        made.cpu_share = settings.cpu_share
        chosen :: locale_for(sessions, user, layout)
        for byte, i in string_bytes(chosen) {
            if i < made.locale.count {
                made.locale[i] = byte
                made.locale_bytes = i + 1
            }
        }
    }
    made.cpu_budget = session_budget(sessions, made.cpu_share)
    sessions.sessions[number] = made
    if user.count == 0 {
        runtime.log_info("a session with no user, on a boot with no accounts")
    }
    else {
        runtime.log_info("a session for %, in %", string_of(&user[0], user.count), locale_of(&sessions.sessions[number]))
    }
    // Its apps directory and its powerbox, before its home is its first program's
    sessions.sessions[number].apps = apps_of(sessions, home)
    match prompts {
        case Some(given) => _ = launch_powerbox(sessions, cast[u32](number), home, given)
        case None => {}
    }
    if command.count > session.COMMAND_BYTES || !launch_first(sessions, cast[u32](number), given_terminal, home, command) {
        close_session(sessions, cast[u32](number))
        return .Refused
    }
    start_installations(sessions, cast[u32](number))
    check_session_cpu(sessions)
    if sessions.test_installations && user.count > 0 {
        sessions.test_installations = false
        sessions.checking = number
    }
    return .Started(cast[u32](number))
}

/**
 * test_session_cpu (decisions/0187), once two sessions are: each on a CPU budget of its own, of a quarter of the
 * sessions' share, and the first's programs ran on its own, not the session manager's. Says what it found.
 *
 * @param sessions The session manager, whose test_session_cpu is cleared once it's checked.
 */
check_session_cpu :: fn(sessions: ptr[mut Manager]) {
    if !sessions.test_session_cpu {
        return void
    }
    on_budgets := 0
    first_ran := false
    share := cast[u64](0)
    for each in sessions.sessions {
        if !each.in_use || cast[slop_os.Handle](each.cpu_budget) == slop_os.NO_HANDLE {
            continue
        }
        info :: slop_os.cpu_budget_describe(each.cpu_budget) or_else slop_os.CpuBudgetInfo.{}
        if on_budgets == 0 {
            first_ran = info.ran > 0
            share = info.share
        }
        else if info.share != share {
            share = 0
        }
        on_budgets += 1
    }
    if on_budgets < 2 {
        return void
    }
    sessions.test_session_cpu = false
    parent :: slop_os.cpu_budget_describe(sessions.cpu_budget) or_else slop_os.CpuBudgetInfo.{}
    if share == 0 || share != parent.share / cast[u64](MAX_SESSIONS) || !first_ran {
        runtime.log_error("test_session_cpu: sessions' budgets wrong: shares % of the sessions' %, the first's programs ran on it: %", share,
            parent.share, first_ran)
        return void
    }
    runtime.log_info("test_session_cpu: % sessions on CPU budgets of their own, % millionths of a CPU each; the first's programs ran on its",
        on_budgets, share)
}

/**
 * End a session: each of its programs asked to stop and, if it hasn't once STOP_GRACE is over, killed; then the
 * session closed.
 *
 * @param sessions The session manager, whose session's programs are ended, waiting on its port up to STOP_GRACE
 *     each, and whose session's place is freed.
 * @param number The session's number; one that isn't a session now is already ended.
 * @return Ended, always.
 */
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

/**
 * Free a session's place, closing what it kept: its locale page, apps directory, powerbox connection and programs
 * connection. Its programs aren't touched.
 *
 * @param sessions The session manager, whose session's place is freed and what it kept closed; the programs
 *     connection's binding to its port is undone.
 * @param number The session's number; past MAX_SESSIONS, nothing's done.
 */
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
    if made.programs_end != NONE {
        _ = slop_os.port_unbind(sessions.port, PROGRAMS_KEY + cast[u64](number))
        _ = slop_os.handle_close(cast[slop_os.Handle](made.programs_end))
    }
    for &finder, i in sessions.finders {
        if finder.in_use && finder.session == number {
            drop_finder(sessions, i)
        }
    }
    // Its budget destroyed: what still runs on it runs on the session manager's
    if cast[slop_os.Handle](made.cpu_budget) != slop_os.NO_HANDLE {
        _ = slop_os.handle_close(cast[slop_os.Handle](made.cpu_budget))
    }
    made^ = Session.{locale_page = cast[slop_os.Memory](slop_os.NO_HANDLE), apps = NONE, powerbox_end = NONE, programs_end = NONE,
        cpu_budget = cast[slop_os.CpuBudget](slop_os.NO_HANDLE)}
}

/**
 * Start the session's first program, its end watched and its lifecycle channel kept: the shell, or echo with use_echo or
 * when the shell can't start, as without a bundle store.
 *
 * @param sessions The session manager, which launches through its process manager connection and keeps the
 *     program in its programs; echo's program it holds is duplicated, not given away.
 * @param number The session's number, below MAX_SESSIONS; the program's placed under it, and given its locale and
 *     powerbox.
 * @param given_terminal The session's terminal connection, given to the program.
 * @param home The session's home volume's root, given to the program; null for none.
 * @return Whether it started; not without the shell or echo's program, without room for another program, or if the
 *     launch failed.
 */
launch_first :: fn(sessions: ptr[mut Manager], number: u32, given_terminal: os.Channel[terminal.Terminal], home: os.Channel[dir.Dir]?,
    command: u8[]) -> bool {
    // The terminal stays the caller's when the shell doesn't start, so echo can have it
    if !sessions.use_echo && launch_shell(sessions, number, given_terminal, home, command) {
        return true
    }
    module :: sessions.echo_module or_return false
    rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_READ) | cast[u32](slop_os.RIGHT_DUPLICATE) | cast[u32](slop_os.RIGHT_TRANSFER))
    copy :: cast[slop_os.Memory](slop_os.handle_duplicate(cast[slop_os.Handle](module), rights) or_return false)
    prepared :: prepare(sessions, number, "echo") or_return false
    return placed(sessions, number, "echo", prepared, os.launch(sessions.manager, sessions.manager_port, "echo", copy, ECHO_BUDGET, echo.main,
        EchoGrants.{log = duplicate_log(sessions.log), session_terminal = given_terminal, home = home,
        powerbox = powerbox_for(sessions, number, "echo")}, prepared.options), false)
}

/**
 * Start the shell, from the bundle store, as the session's first program in echo's place.
 *
 * The bundle store's boot root's "shell" has to be a bundle whose manifest is shell.main's entry.
 *
 * @param sessions The session manager, which finds the shell in its bundle store, launches through its process
 *     manager connection, and keeps the program in its programs.
 * @param number The session's number, below MAX_SESSIONS; the shell's placed under it, and its programs
 *     connection made for it.
 * @param given_terminal The session's terminal connection, given to the shell.
 * @param home The session's home volume's root, given to the shell; null for none.
 * @return Whether it started; not without a shell in the bundle store, without room for another program, or if the
 *     launch failed.
 */
launch_shell :: fn(sessions: ptr[mut Manager], number: u32, given_terminal: os.Channel[terminal.Terminal], home: os.Channel[dir.Dir]?,
    command: u8[]) -> bool {
    expected :: bundle.Hash.{bytes = schema.hash(type_info_of(type_of(shell.main)))}
    program := cast[slop_os.Memory](slop_os.NO_HANDLE)
    match bundle_named(sessions, "shell") {
        case Some(found) => program = program_of(sessions, found, expected) or_else cast[slop_os.Memory](slop_os.NO_HANDLE)
        case None => {}
    }
    if cast[slop_os.Handle](program) == slop_os.NO_HANDLE {
        runtime.log_info("no shell in the bundle store")
        return false
    }
    prepared :: prepare(sessions, number, "shell") or_return false
    grants := ShellGrants.{log = duplicate_log(sessions.log), session_terminal = given_terminal, home = home}
    if command.count > 0 {
        // Kept for as long as the session manager runs: the shell's grant is a view of it
        copy, error :: runtime.new_array(u8, command.count)
        if error != null {
            return false
        }
        for byte, i in command {
            if i < copy.count {
                copy[i] = byte
            }
        }
        grants.command = if copy.count > 0 { string_of(&copy[0], copy.count) } else { "" }
    }
    if cast[usize](number) < sessions.sessions.count {
        grants.cpu_budget = budget_copy(sessions.sessions[cast[usize](number)].cpu_budget, true)
    }
    // Its own connection to the process manager, to launch what it calls, and its programs connection
    grants.manager = process_manager.connect(sessions.manager.end, sessions.manager_port, slop_os.startup_block().budget)
    grants.programs = programs_connection(sessions, number)
    // The session's network: public addresses, any port, no listening (decisions/0188)
    grants.network = session_network(sessions, true)
    if cast[usize](number) < sessions.sessions.count && sessions.sessions[cast[usize](number)].apps != NONE {
        match opened_directory(sessions.sessions[cast[usize](number)].apps, SHELL_DATA, true) {
            case Some(end) => grants.data = installations.AppData.{end = end}
            case None => runtime.log_info("no data directory for the shell")
        }
    }
    return placed(sessions, number, "shell", prepared, os.launch(sessions.manager, sessions.manager_port, "shell", program, SHELL_BUDGET,
        shell.main, grants, prepared.options), false)
}

/**
 * Make a programs connection for a session's shell (decisions/0170), the session manager's end kept and bound to its
 * port, in place of any the session had.
 *
 * @param sessions The session manager, whose port the kept end is bound to, under PROGRAMS_KEY plus number.
 * @param number The session's number; the session's programs connection, if it had one, is unbound and closed.
 * @return The shell's end, the caller's to give it; null for a number past MAX_SESSIONS, or if the channel couldn't
 *     be made or bound.
 */
programs_connection :: fn(sessions: ptr[mut Manager], number: u32) -> os.Channel[programs.Programs]? {
    if cast[usize](number) >= sessions.sessions.count {
        return null
    }
    made :: &sessions.sessions[cast[usize](number)]
    if made.programs_end != NONE {
        _ = slop_os.port_unbind(sessions.port, PROGRAMS_KEY + cast[u64](number))
        _ = slop_os.handle_close(cast[slop_os.Handle](made.programs_end))
        made.programs_end = NONE
    }
    pair :: os.channel_for[programs.Programs](slop_os.startup_block().budget, 0) or_return null
    signals :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    if slop_os.port_bind(sessions.port, cast[slop_os.Handle](pair.a), signals, PROGRAMS_KEY + cast[u64](number), .Persistent) is_error {
        _ = slop_os.handle_close(cast[slop_os.Handle](pair.a))
        _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
        return null
    }
    made.programs_end = pair.a
    return os.Channel[programs.Programs].{end = pair.b}
}

/**
 * Answer what each session's shell has asked of its programs connection, until it's asked nothing more; a connection
 * that's gone is closed.
 *
 * @param sessions The session manager, whose sessions' programs connections are read on its port, Find answered
 *     from its bundle store, and one that's gone unbound and closed.
 * @param into Where each request is received, reused.
 */
serve_programs :: fn(sessions: ptr[mut Manager], into: ptr[mut os.Incoming]) {
    for &made, number in sessions.sessions {
        if !made.in_use || made.programs_end == NONE {
            continue
        }
        loop {
            match programs.receive_request(made.programs_end, sessions.port, into, false) {
                case Received => {}
                case Empty => break
                case Unsupported => {
                    _ = programs.answer_unsupported(made.programs_end, sessions.port)
                    continue
                }
                case _ => {
                    _ = slop_os.port_unbind(sessions.port, PROGRAMS_KEY + cast[u64](number))
                    _ = slop_os.handle_close(cast[slop_os.Handle](made.programs_end))
                    made.programs_end = NONE
                    break
                }
            }
            out := os.Outgoing.{}
            response :: os.begin[programs.Response](&out)
            match os.message_of[programs.Request](into)^ {
                case Find(name) => response^ = find_program(sessions, os.items(into, name))
                case List(index) => response^ = program_at(sessions, index, &out)
                case Describe(name) => response^ = program_documentation(sessions, os.items(into, name))
                case Debug(name) => response^ = program_debug_file(sessions, os.items(into, name))
                case Connect(connection) => {
                    add_finder(sessions, cast[u32](number), connection.end)
                    continue
                }
                // Its own session's (users_installations.hsc)
                case _ => response^ = own_session_answer(sessions, cast[u32](number), os.message_of[programs.Request](into)^, into, &out)
            }
            _ = programs.send_response(made.programs_end, sessions.port, &out)
        }
    }
}

/**
 * Find a program the bundle store's boot root names: its bundle's executable and its manifest.
 *
 * @param sessions The session manager, whose bundle store is asked for the boot root, the bundle and its objects,
 *     waiting for each answer.
 * @param name The program's name, from 1 to programs.MAX_NAME bytes.
 * @return Found with the executable's and the manifest's memory, both new handles for the shell to own, and the
 *     manifest's size in bytes; Missing for a name out of range, one the root doesn't name, a bundle that refers to
 *     fewer than two objects, or an object the store didn't give.
 */
find_program :: fn(sessions: ptr[mut Manager], name: u8[]) -> programs.Response {
    if name.count == 0 || name.count > programs.MAX_NAME {
        return .Missing
    }
    found :: bundle_named(sessions, string_of(&name[0], name.count)) or_return .Missing
    record :: stored_object(sessions, found) or_return .Missing
    referred : bundle.Hash[..]
    defer runtime.array_free(&referred)
    read :: bundle.bundle_refers(record.bytes, &referred) or_else false
    let_go_of_object(record)
    if !read || referred.count < 2 {
        return .Missing
    }
    manifest :: match store_request(sessions, .Read(referred[1 % referred.count])) {
        case Got(object) => object
        case _ => return .Missing
    }
    match store_request(sessions, .Get(referred[0])) {
        case Got(object) => return .Found(programs.Program.{executable = object.memory, manifest = manifest.memory, manifest_size = manifest.size})
        case _ => {
            _ = slop_os.handle_close(cast[slop_os.Handle](manifest.memory))
            return .Missing
        }
    }
}

/**
 * Name the bundle store's boot root's program at an index, for a shell's List.
 *
 * @param sessions The session manager, whose bundle store is asked for its root, which is read into the heap and freed.
 * @param index The program's index among the root's entries, from 0, in the root's order.
 * @param out The response being made, which the name's bytes are appended to, copied before the root's freed.
 * @return Named with the name; End past the root's last entry, for a name empty or longer than programs.MAX_NAME,
 *     without a store, or if the root couldn't be read.
 */
program_at :: fn(sessions: ptr[mut Manager], index: u32, out: ptr[mut os.Outgoing]) -> programs.Response {
    root :: match store_request(sessions, .Root) {
        case Rooted(hash) => hash
        case _ => return .End
    }
    root_object :: stored_object(sessions, root) or_return .End
    defer let_go_of_object(root_object)
    names : string[..]
    defer runtime.array_free(&names)
    bundles : bundle.Hash[..]
    defer runtime.array_free(&bundles)
    if !(bundle.root_entries(root_object.bytes, &names, &bundles) or_else false) {
        return .End
    }
    for name, i in names {
        if i == cast[usize](index) && name.count > 0 && name.count <= programs.MAX_NAME {
            return .Named(os.append(out, string_bytes(name)))
        }
    }
    return .End
}

/**
 * Find the documentation of a program the bundle store's boot root names, for a shell's Describe.
 *
 * @param sessions The session manager, whose bundle store is asked for the root, the bundle and the documentation,
 *     waiting for each answer.
 * @param name The program's name, from 1 to programs.MAX_NAME bytes.
 * @return Documented with the record's memory, a new handle for the shell to own, and its size in bytes; Missing for a
 *     name out of range, one the root doesn't name, a bundle without documentation (its hash all zeros), or an object
 *     the store didn't give.
 */
program_documentation :: fn(sessions: ptr[mut Manager], name: u8[]) -> programs.Response {
    if name.count == 0 || name.count > programs.MAX_NAME {
        return .Missing
    }
    found :: bundle_named(sessions, string_of(&name[0], name.count)) or_return .Missing
    record :: stored_object(sessions, found) or_return .Missing
    referred : bundle.Hash[..]
    defer runtime.array_free(&referred)
    read :: bundle.bundle_refers(record.bytes, &referred) or_else false
    let_go_of_object(record)
    if !read || referred.count < 3 {
        return .Missing
    }
    documentation :: referred[2]
    if bundle.same(documentation, bundle.Hash.{}) {
        return .Missing
    }
    match store_request(sessions, .Read(documentation)) {
        case Got(object) => return .Documented(programs.ProgramDocumentation.{record = object.memory, size = object.size})
        case _ => return .Missing
    }
}

/**
 * Find a program's debug file in the boot root (decisions/0185), for a shell's Debug.
 *
 * @param sessions The session manager, whose bundle store connection is asked.
 * @param name The program's name's bytes, 1 to programs.MAX_NAME of them.
 * @return DebugFile with a copy of it, whose handle moves to the shell; Missing for a name that's too short or long, no
 *     such program, a bundle that doesn't read, or one without a debug file.
 */
program_debug_file :: fn(sessions: ptr[mut Manager], name: u8[]) -> programs.Response {
    if name.count == 0 || name.count > programs.MAX_NAME {
        return .Missing
    }
    found :: bundle_named(sessions, string_of(&name[0], name.count)) or_return .Missing
    record :: stored_object(sessions, found) or_return .Missing
    referred : bundle.Hash[..]
    defer runtime.array_free(&referred)
    read :: bundle.bundle_refers(record.bytes, &referred) or_else false
    let_go_of_object(record)
    if !read || referred.count < 4 {
        return .Missing
    }
    debug :: referred[3]
    if bundle.same(debug, bundle.Hash.{}) {
        return .Missing
    }
    match store_request(sessions, .Read(debug)) {
        case Got(object) => return .DebugFile(programs.ProgramDocumentation.{record = object.memory, size = object.size})
        case _ => return .Missing
    }
}

/**
 * Start the session's powerbox (decisions/0156), from the bundle store, given another connection to its home and the
 * prompt connection, and keep its connection for the session manager.
 *
 * The bundle store's boot root's "powerbox_service" has to be a bundle whose manifest is powerbox_service.main's entry.
 *
 * @param sessions The session manager, which finds the powerbox in its bundle store, launches it through its
 *     process manager connection, and keeps its connection in the session.
 * @param number The session's number; past MAX_SESSIONS, prompts is closed and nothing's started.
 * @param home The session's home volume's root, which stays the caller's; the powerbox gets a connection of its own.
 * @param prompts The trusted path's prompt connection, which moves to the powerbox, or is closed when there's none.
 * @return Whether it started; not without a powerbox in the bundle store, without room for another program, or if a
 *     channel or the launch failed.
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
    grants := PowerboxGrants.{prompts = prompts, manager = os.Channel[powerbox.Powerbox].{end = pair.a},
        network = session_network(sessions, false)}
    match home {
        case Some(root) => match connection_to(root.end) {
            case Some(another) => grants.home = os.Channel[dir.Dir].{end = another}
            case None => {}
        }
        case None => {}
    }
    // Its programs connection, for Attach, served as a finder marked as the powerbox's
    match os.channel_for[programs.Programs](slop_os.startup_block().budget, 0) {
        case Ok(ends) => {
            grants.programs = os.Channel[programs.Programs].{end = ends.a}
            add_finder(sessions, number, ends.b, true)
        }
        case Error(error) => {}
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

/**
 * Make a connection to a session's powerbox for a program, which it serves under the program's name.
 *
 * It sends the powerbox Serve, with the connection's other end, and waits for its answer.
 *
 * @param sessions The session manager, on whose session's powerbox connection Serve is sent and its answer
 *     waited for, with no deadline.
 * @param number The session's number; past MAX_SESSIONS, or a session without a powerbox, null comes back.
 * @param name The program's name, which the powerbox shows on the trusted path when it asks the user for it.
 * @return The program's end, the caller's to give it; null without a powerbox, or if the channel couldn't be made or
 *     the powerbox didn't answer Done.
 */
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

/**
 * Make a program's launch ready: a place one that ended left, or the next; its end watched under its place's key; a
 * lifecycle channel; its session's locale; and a ring for its log records, the owning handle kept, the program given
 * one that doesn't own it.
 *
 * What's made is the caller's, to give to placed with the launch's result.
 *
 * @param sessions The session manager: the place's old binding to its port is undone, and the events service
 *     opens the ring. Its programs aren't changed until placed.
 * @param number The session's number, whose locale the program's given.
 * @param name The program's name, which the events service opens its ring under.
 * @return What's ready; null with no place left among MAX_PROGRAMS, or if the lifecycle channel couldn't be made.
 *     Without the events service, or if it opens no ring, the program has none.
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
    prepared.options = os.LaunchOptions.{watch = os.LaunchWatch.{port = sessions.port, key = PROGRAM_KEY + cast[u64](index)},
        faults = os.LaunchFaults.{port = sessions.port, key = CRASH_KEY + cast[u64](index)}}
    prepared.options.lifecycle = ends.b
    if cast[usize](number) < sessions.sessions.count {
        prepared.options.locale = locale_page(&sessions.sessions[cast[usize](number)])
        // On its session's budget (decisions/0187)
        prepared.options.cpu_budget = budget_copy(sessions.sessions[cast[usize](number)].cpu_budget, false)
    }
    if sessions.events_end != NONE {
        match events.open(sessions.events_end, sessions.events_port, name) {
            case Some(opened) => {
                // A session's program's records kept to its budget (decisions/0183)
                configured :: if cast[usize](number) < sessions.sessions.count { sessions.sessions[cast[usize](number)].events_budget } else { cast[u64](0) }
                _ = events.set_budget(sessions.events_end, sessions.events_port, name, if configured != 0 { configured } else { events.SESSION_BUDGET })
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

/**
 * Keep a program launched with what prepare made ready in its place, or, if it didn't start, give back what was made
 * ready: its lifecycle channel closed and its ring retired.
 *
 * @param sessions The session manager, whose programs keep the program at prepared's index, their count grown to
 *     include it; on failure, the ring's retired through its events service.
 * @param number The session's number, kept as the program's session.
 * @param name The program's name, kept and logged; only session.NAME_BYTES of it are kept.
 * @param prepared What prepare made ready for it.
 * @param result The launch's result: its process and budget, kept by the program; or why it failed, logged.
 * @param installation Whether it's one of the system's installations, which memory pressure may stop.
 * @return Whether it started and was kept.
 */
placed :: fn(sessions: ptr[mut Manager], number: u32, name: string, prepared: Prepared, result: Result[os.Launched, os.LaunchError],
    installation: bool, program_name: string = "") -> bool {
    match result {
        case Ok(launched) => {
            program := Program.{session = number, process = launched.process, budget = launched.budget, lifecycle = prepared.lifecycle,
                ring = prepared.ring, running = true, installation = installation, faults = launched.faults, image = launched.image}
            for byte, i in string_bytes(name) {
                if i < program.name.count {
                    program.name[i] = byte
                    program.name_bytes += 1
                }
            }
            for byte, i in string_bytes(if program_name.count > 0 { program_name } else { name }) {
                if i < program.program_name.count {
                    program.program_name[i] = byte
                    program.program_bytes += 1
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

/**
 * List a session's programs that are running, each pinged on its lifecycle channel to say whether it's responding.
 *
 * It waits up to PING_WAIT for their Pongs; answers left from earlier pings are dropped first.
 *
 * @param sessions The session manager, whose running programs of the session are pinged on their lifecycle
 *     channels; their Pongs are read, waiting up to PING_WAIT.
 * @param number The session's number; one with no running programs lists none.
 * @param programs Where they're put, from the first: each one's index, name, memory used and limit, and whether it
 *     answered.
 * @return How many were put, at most session.MAX_PROGRAMS.
 */
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

/**
 * End a program: ask it to stop on its lifecycle channel, then kill it if it hasn't ended once STOP_GRACE is over.
 *
 * It waits on the session manager's port meanwhile, taking programs' ends as they come; other packets that come then
 * aren't acted on.
 *
 * @param sessions The session manager, whose program is asked to stop and killed after STOP_GRACE; programs
 *     whose ends come on its port meanwhile are marked ended.
 * @param index The program's index among the programs, as List gives it.
 * @param why Why it's ended, for the log.
 * @return Ended once it's stopped or been killed, or if it had ended already; Refused for an index that's never been a
 *     program's.
 */
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

/**
 * Read a user's settings for their sessions: what their programs' records keep (decisions/0185, 12g) and their CPU
 * share (decisions/0187). The locale is read on its own (locale_for).
 *
 * @param sessions The session manager, through whose config store the user's settings are read.
 * @param user The user's name, not empty.
 * @return The settings, as they're kept, their locale not to be read; zeros, each a default, without the config store
 *     or a setting.
 */
user_settings :: fn(sessions: ptr[mut Manager], user: u8[]) -> SessionSettings {
    none :: SessionSettings.{}
    if sessions.settings_end == NONE {
        return none
    }
    owner : u8[OWNER_BYTES]
    count :: owner_of(user, "", &owner)
    out := os.Outgoing.{}
    request :: os.begin[config.Request](&out)
    request^ = .ValueFor(config.ValueFor.{owner = os.append(&out, owner[0..<count]), name = os.append(&out, string_bytes("session"))})
    into := os.Incoming.{}
    connection :: match config.ask(sessions.settings_end, sessions.settings_port, &out, &into) {
        case Opened(opened) => config.Config[SessionSettings].{end = opened.end}
        case _ => return none
    }
    defer slop_os.handle_close(cast[slop_os.Handle](connection.end))
    port :: os.port_for(slop_os.startup_block().budget, connection.end) or_return none
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    if config.declare(connection, port) is_error {
        return none
    }
    value := os.Outgoing.{}
    if config.read(connection, port, &value) is_error {
        return none
    }
    read :: os.typed_value[SessionSettings](os.value_bytes(&value))
    return SessionSettings.{events_budget = read.events_budget, cpu_share = read.cpu_share}
}

/**
 * Make a session's CPU budget (decisions/0187): a child of the sessions' budget, at its priority and period, of the
 * share asked for, or a quarter of the sessions' share, so MAX_SESSIONS sessions fit. One that can't be made is
 * logged, and the session's programs run on the session manager's budget.
 *
 * @param sessions The session manager, whose cpu_budget it's split off, and whose memory budget pays for it.
 * @param share The share asked for, in millionths of a CPU; 0 for the default.
 * @return The budget's owning handle, the session's; NO_HANDLE without the sessions' budget or room in it.
 */
session_budget :: fn(sessions: ptr[Manager], share: u64) -> slop_os.CpuBudget {
    none :: cast[slop_os.CpuBudget](slop_os.NO_HANDLE)
    if cast[slop_os.Handle](sessions.cpu_budget) == slop_os.NO_HANDLE {
        return none
    }
    parent :: slop_os.cpu_budget_describe(sessions.cpu_budget) or_return none
    wanted :: if share != 0 { share } else { parent.share / cast[u64](MAX_SESSIONS) }
    time :: parent.period / 1_000_000 * wanted
    if time == 0 || time > parent.period {
        runtime.log_warn("a session's CPU share of % millionths doesn't fit its period, so it runs on the session manager's", wanted)
        return none
    }
    match slop_os.cpu_budget_create(sessions.cpu_budget, slop_os.startup_block().budget, cast[u32](parent.priority), parent.period, time) {
        case Ok(made) => return made
        case Error(error) => {
            runtime.log_warn("no CPU budget for a session (%), so it runs on the session manager's", error)
            return none
        }
    }
}

/**
 * Copy a session's CPU budget to give a program: to put it on, or for its shell, to split too.
 *
 * @param budget The session's budget, kept; NO_HANDLE for none.
 * @param splits Whether the copy may be split (RIGHT_CPU_BUDGET_SPLIT), as the shell's is for its jobs.
 * @return The copy, which moves to the program; null for no budget, or one that can't be copied.
 */
budget_copy :: fn(budget: slop_os.CpuBudget, splits: bool) -> slop_os.CpuBudget? {
    if cast[slop_os.Handle](budget) == slop_os.NO_HANDLE {
        return null
    }
    rights := cast[u32](slop_os.RIGHT_CPU_BUDGET_BIND) | cast[u32](slop_os.RIGHT_TRANSFER)
    if splits {
        rights |= cast[u32](slop_os.RIGHT_CPU_BUDGET_SPLIT)
    }
    match slop_os.handle_duplicate(cast[slop_os.Handle](budget), cast[slop_os.Rights](rights)) {
        case Ok(copy) => return cast[slop_os.CpuBudget](copy)
        case Error(error) => return null
    }
}

/**
 * Find a user's locale: their settings', or with none, the one the keyboard layout they logged in with suggests, kept
 * as their setting from then on.
 *
 * It declares SessionSettings for "session" of owner "user:" and their name, and reads it; a value that isn't a locale
 * it gives counts as none.
 *
 * @param sessions The session manager, through whose config store the user's settings are read, and written
 *     when they have none.
 * @param user The user's name, not empty; their values' owner is "user:" and it.
 * @param layout The keyboard layout they logged in with: "uk" suggests en-GB, any other en-US.
 * @return The locale's name, a constant: "en-US" or "en-GB". The suggested one without the config store, or if it
 *     can't be read.
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

/**
 * Make the config store's owner of a user's values, "user:" and their name, "-" for a session with no user, and for
 * an installation's, ":" and its name after that.
 *
 * @param user The user's name; empty for a session with no user.
 * @param installation The installation's name; empty for the user's own values.
 * @param owner Where it's put, from the start; what's past OWNER_BYTES is cut.
 * @return How many bytes of owner it is.
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

/**
 * Append bytes to an owner being made, as far as it has room.
 *
 * @param owner The owner being made.
 * @param count How many of owner's bytes are in use, moved on by those appended.
 * @param bytes The bytes; those past OWNER_BYTES are dropped.
 */
add_bytes :: fn(owner: ptr[mut u8[OWNER_BYTES]], count: ptr[mut usize], bytes: u8[]) {
    for byte in bytes {
        at :: count^
        if at < owner.count {
            owner^[at] = byte
            count^ = at + 1
        }
    }
}

/**
 * Find the locale bytes name, if it's one the session manager gives.
 *
 * @param bytes The name, as the config store kept it.
 * @return Its name as a constant, "en-US" or "en-GB"; null for any other, or none.
 */
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

/**
 * Find a session's locale's name, for the log.
 *
 * @param made The session, read only; the name returned is a view of it.
 * @return Its name, a view of the session's, good while it lasts; "no locale" for none.
 */
locale_of :: fn(made: ptr[Session]) -> string {
    return if made.locale_bytes > 0 && made.locale_bytes <= made.locale.count { string_of(&made.locale[0], made.locale_bytes) } else { "no locale" }
}

/**
 * Make a read-only copy of the page holding a session's locale's name, for a program's grant "locale".
 *
 * The page is made the first time and kept by the session, since closing it would take the copies with it.
 *
 * @param made The session, whose locale_page is made the first time it's asked for, kept until the session's
 *     closed.
 * @return The copy, the caller's to give; null for a session with no locale, or if the page or copy couldn't be made.
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

/**
 * Note the session the console shows now, its time shown counted; test_pressure's pressure brought on once two
 * sessions are.
 *
 * test_pressure charges a budget split off the session manager's own up to its pressure threshold, once.
 *
 * @param sessions The session manager, whose shown session and count of showings change, and which test_pressure
 *     gives a ballast budget.
 * @param number The session's number, or session.NO_SESSION when the console shows none, as on the trusted path.
 */
shown :: fn(sessions: ptr[mut Manager], number: u32) {
    sessions.shown = number
    sessions.showings += 1
    if cast[usize](number) < sessions.sessions.count {
        sessions.sessions[cast[usize](number)].shown_at = sessions.showings
    }
    restart_pressed(sessions, number)
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

/**
 * Relieve memory pressure: idle installations, those of the sessions not shown, the least recently shown session's
 * first, each asked to stop and ended, one at a time, until what its budget has charged is under RELIEVED_PERCENT of
 * its limit, or there are none left. test_pressure's charge is given back after.
 *
 * A session's first program and its powerbox are never asked. Each stop can take up to STOP_GRACE.
 *
 * @param sessions The session manager, whose idle installations are ended, waiting on its port up to
 *     STOP_GRACE each, and whose test_pressure ballast is closed after.
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
        remember_pressed(sessions, sessions.programs[idle].session, sessions.programs[idle].name, sessions.programs[idle].name_bytes)
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

/**
 * Start the system's installations in a session, then its user's own (users_installations.hsc), each as
 * start_installation does; one that can't start is logged and skipped.
 *
 * @param sessions The session manager, whose list of installations is read from the config store, and which
 *     starts and keeps each installation.
 * @param number The session's number, below MAX_SESSIONS; its apps directory holds the installations' data.
 */
start_installations :: fn(sessions: ptr[mut Manager], number: u32) {
    list :: read_installations(sessions)
    for i in cast[usize](0)..<list.entries.count {
        if i < cast[usize](list.count) {
            _ = start_installation(sessions, number, list.entries[i])
        }
    }
    start_user_installations(sessions, number)
}

/**
 * Read the system's installations, as the config store has them.
 *
 * @param sessions The session manager, whose list connection to the config store is read, waiting for its
 *     answer.
 * @return The list; empty without the list's connection, before it's written, or if it can't be read or isn't valid.
 */
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

/**
 * Write the system's installations to the config store, marked written.
 *
 * @param sessions The session manager, on whose list connection to the config store the list is written, waiting
 *     for its answer.
 * @param list The list; its set is made 1.
 * @return Whether the store kept it; false without the list's connection, or for a list that isn't valid.
 */
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

/**
 * Start an installation in a session: its bundle's program (the bundle it names, or the one the store's boot root
 * names after its program), given what its entry asks that an installation is given (entries.hsc, decisions/0181's
 * F3): its data directory, apps/<name> in the session's apps directory, made if it isn't there; its settings, of its
 * owner (owner_of); the clock and the locale.
 *
 * @param sessions The session manager, which finds the program in its bundle store, opens its settings through
 *     its config store, launches it, and keeps it.
 * @param number The session's number; past MAX_SESSIONS, or a session without an apps directory, it has no data
 *     directory, so one that asks for it isn't started.
 * @param entry The installation's record: its name, its program's name and the bundle it names, if any.
 * @return Whether it started; not without its bundle, for one whose entry takes what an installation isn't given,
 *     without a data directory it asks for, without room for another program, or if the launch failed. Each is logged.
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
    plan :: match entry_plan(sessions, bundle_hash) {
        case Ok(made) => made
        case Error(problem) => {
            match problem {
                case Needs(parameter) => runtime.log_info("installation %: its program needs %, which an installation isn't given", name, parameter)
                case Unreadable => runtime.log_info("installation %: its bundle couldn't be read", name)
            }
            return false
        }
    }
    return launch_installation(sessions, number, name, plan, system_records.text_of(&entry.program))
}

/**
 * Open a connection to an installation's settings in the config store, "settings" of its owner (owner_of).
 *
 * @tparam T The settings' type.
 * @param sessions The session manager, whose config store is asked for the value, waiting for its answer.
 * @param number The session's number, whose user owns the installation's values.
 * @param name The installation's name, put after the user's in the owner (owner_of); not checked to be
 *     installed.
 * @return The connection, the caller's to give; null without the config store, for a number past MAX_SESSIONS, or if
 *     the store didn't open it.
 */
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

/**
 * Find the bundle an installation runs: the one it names, or the store's boot root's of its program's name.
 *
 * @param sessions The session manager, whose bundle store's boot root is read when the record names no bundle.
 * @param entry The installation's record: its bundle, all zeros for none, and its program's name.
 * @return The bundle's hash; null if it names none and the boot root doesn't name its program.
 */
installation_bundle :: fn(sessions: ptr[mut Manager], entry: system_records.InstallationRecord) -> bundle.Hash? {
    named := bundle.Hash.{bytes = entry.bundle}
    if !bundle.same(named, bundle.Hash.{}) {
        return named
    }
    return bundle_named(sessions, system_records.text_of(&entry.program))
}

/**
 * Find the bundle the bundle store's boot root names by a name.
 *
 * @param sessions The session manager, whose bundle store is asked for its root, which is read into the heap and freed.
 * @param name The name, like "shell" or an installation's program's.
 * @return The bundle's hash; null without the store, if the root couldn't be read, or if it doesn't name it.
 */
bundle_named :: fn(sessions: ptr[mut Manager], name: string) -> bundle.Hash? {
    root :: match store_request(sessions, .Root) {
        case Rooted(hash) => hash
        case _ => return null
    }
    root_object :: stored_object(sessions, root) or_return null
    defer let_go_of_object(root_object)
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

/**
 * Find a bundle's program, as paged memory from the store, if its manifest is the one expected.
 *
 * A bundle refers to its program first and its manifest second.
 *
 * @param sessions The session manager, whose bundle store gives the bundle, read into the heap and freed, and its program.
 * @param bundle_hash The bundle's hash in the bundle store; one it doesn't have gives null.
 * @param expected The manifest's hash expected: the schema hash of the entry it's launched with.
 * @return The program's memory, the caller's; null for another manifest, a bundle that can't be read or refers to
 *     fewer than two objects, or a program the store doesn't give.
 */
program_of :: fn(sessions: ptr[mut Manager], bundle_hash: bundle.Hash, expected: bundle.Hash) -> slop_os.Memory? {
    record :: stored_object(sessions, bundle_hash) or_return null
    referred : bundle.Hash[..]
    defer runtime.array_free(&referred)
    read :: bundle.bundle_refers(record.bytes, &referred) or_else false
    let_go_of_object(record)
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

/**
 * Ask the bundle store something, and wait for its answer.
 *
 * @param sessions The session manager, on whose bundle store connection the request is sent and the answer
 *     waited for.
 * @param request The request, which can't carry items: Root or Get, as it's used here.
 * @return The store's answer; Unsupported without the store. Handles in it are the caller's.
 */
store_request :: fn(sessions: ptr[mut Manager], request: bundle_store.Request) -> bundle_store.Response {
    if sessions.store_end == NONE {
        return .Unsupported
    }
    out := os.Outgoing.{}
    os.begin[bundle_store.Request](&out)^ = request
    into := os.Incoming.{}
    return bundle_store.ask(sessions.store_end, sessions.store_port, &out, &into)
}

/**
 * Get a copy of a small object from the bundle store, a root or a bundle's record, read into the heap.
 *
 * The store's memory is read through memory_read and closed, so nothing stays open in the store, and its ending
 * meanwhile gives null rather than a fault.
 *
 * @param sessions The session manager, whose bundle store gives the copy.
 * @param hash The hash of the object wanted, sent to the store in a Read; a hash it doesn't have, or an object past
 *     bundle_store.MAX_READ bytes, gives null.
 * @return The object, its bytes on the heap, for the caller to give to let_go_of_object; null if the store didn't give
 *     it, it's empty, the heap couldn't hold it, or it couldn't be read.
 */
stored_object :: fn(sessions: ptr[mut Manager], hash: bundle.Hash) -> StoredObject? {
    object :: match store_request(sessions, .Read(hash)) {
        case Got(got) => got
        case _ => return null
    }
    defer slop_os.handle_close(cast[slop_os.Handle](object.memory))
    if object.size == 0 || object.size > bundle_store.MAX_READ {
        return null
    }
    bytes, made :: runtime.new_array(u8, cast[usize](object.size))
    if made != null {
        return null
    }
    if !service_kit.read_pages(object.memory, 0, bytes) {
        runtime.free_array(bytes)
        return null
    }
    return StoredObject.{bytes = bytes}
}

/**
 * Let go of an object stored_object read: free its bytes.
 *
 * @param object The object; its bytes are gone after this.
 */
let_go_of_object :: fn(object: StoredObject) {
    runtime.free_array(object.bytes)
}

/**
 * Open a session's apps directory: its home's apps, made if it isn't there, or for a session without a home, a
 * connection of its own to the system volume's.
 *
 * @param sessions The session manager, whose system apps directory a session without a home gets a connection
 *     to.
 * @param home The session's home volume's root, which stays the caller's; null for none.
 * @return The directory, the caller's; NONE without either, or if it couldn't be opened.
 */
apps_of :: fn(sessions: ptr[mut Manager], home: os.Channel[dir.Dir]?) -> slop_os.Channel {
    return match home {
        case Some(root) => opened_directory(root.end, "apps", true) or_else NONE
        case None => if sessions.apps_end == NONE { NONE } else { connection_to(sessions.apps_end) or_else NONE }
    }
}

/**
 * Open a directory beneath the one a channel speaks for, and wait for it.
 *
 * @param end The directory's channel, which stays the caller's.
 * @param name The directory's path beneath it.
 * @param create Whether to make it first if it isn't there.
 * @return The opened directory's channel, the caller's; null if it can't be opened, or the request fails.
 */
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
            case _ => return null
        }
    }
    return match os.message_of[dir.Response](&into)^ {
        case OpenedDirectory(opened) => opened.end
        case _ => null
    }
}

/**
 * Make another connection to the directory a channel speaks for, its one end sent to its server with Connect, which
 * takes it without answering.
 *
 * @param end The directory's channel, which stays the caller's.
 * @return The new connection's end, the caller's; null if the channel or a port couldn't be made, or Connect couldn't
 *     be sent.
 */
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

/**
 * Stop an installation in a session, if it's running: asked to stop, and killed if it hasn't once STOP_GRACE is over.
 *
 * @param sessions The session manager, whose running installation of that name in the session is ended, waiting
 *     on its port up to STOP_GRACE.
 * @param number The session's number, compared with each running program's; not checked against MAX_SESSIONS,
 *     so one with no programs does nothing.
 * @param name The installation's name, compared with each program's; none running by it does nothing.
 */
stop_installation :: fn(sessions: ptr[mut Manager], number: u32, name: string) {
    for i in 0..<sessions.count {
        if i < sessions.programs.count && sessions.programs[i].running && sessions.programs[i].installation
            && sessions.programs[i].session == number && name_of(&sessions.programs[i]) == name {
            _ = end_program(sessions, i, "to change its installation")
        }
    }
}

/**
 * Remove an installation, by a session: stopped there, taken from the system's list, its data directory in the
 * session's apps directory deleted, and its settings forgotten.
 *
 * Only the files directly in its data directory are deleted, so a directory in it keeps the data directory too.
 *
 * @param sessions The session manager: the installation is stopped, its list rewritten in the config store, its
 *     data deleted and its settings forgotten, waiting for each.
 * @param number The session's number, whose apps directory and user's settings it's removed from.
 * @param name The installation's name: the list's entry of that name is dropped, and it names the data
 *     directory and the settings' owner; one that isn't installed still has its data and settings removed.
 * @return Whether all of it went; false if any part didn't, or the session has no apps directory or there's no config
 *     store, though what could go has.
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
    written :: write_installations(sessions, kept)
    return remove_installation_data(sessions, number, name) && written
}

/**
 * Remove an installation's data and settings, by a session: its data directory in the session's apps directory
 * deleted, and its settings forgotten.
 *
 * Only the files directly in its data directory are deleted, so a directory in it keeps the data directory too.
 *
 * @param sessions The session manager: its data is deleted and its settings forgotten, waiting for each.
 * @param number The session's number, whose apps directory and user's settings it's removed from.
 * @param name The installation's name, which names the data directory and the settings' owner.
 * @return Whether all of it went; false if any part didn't, or the session has no apps directory or there's no config
 *     store, though what could go has.
 */
remove_installation_data :: fn(sessions: ptr[mut Manager], number: u32, name: string) -> bool {
    whole := true
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

/**
 * Join two names into a path, a/b.
 *
 * @param a The name before the slash, as given; may be empty.
 * @param b The name after the slash, as given; may be empty.
 * @param storage Where the path's put; what's past 256 bytes is cut.
 * @return The path, a view of storage, good as long as it is.
 */
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

/**
 * Run test_installations, in the first session with a user, once it's been answered for: the counter, once it's
 * counted, refused an update to hello's bundle, whose entry isn't the installations'; updated to counter_next's, which
 * counts on from its data; uninstalled, its data and settings with it; installed again, counting from 1; and made to
 * crash, which is reported, and ends it. What happened is logged.
 *
 * It takes the counter to be the list's first installation.
 *
 * @param sessions The session manager, whose list of installations, programs and the session's counter data
 *     the test reads, rewrites and restarts; it waits up to COUNT_WAIT at each step.
 * @param number The session's number, the first with a user, in which the counter runs.
 */
check_installations :: fn(sessions: ptr[mut Manager], number: u32) {
    list := read_installations(sessions)
    if list.count == 0 || !counted(sessions, number, "counter", 1) {
        runtime.log_info("test_installations: no installations")
        return void
    }
    // An update to a bundle whose entry needs what an installation isn't given (list's here) is refused before it's written
    list_bundle :: bundle_named(sessions, "list") or_else bundle.Hash.{}
    refused :: match entry_plan(sessions, list_bundle) {
        case Ok(plan) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](plan.program))
            false
        }
        case Error(problem) => match problem {
            case Needs(parameter) => parameter == "here"
            case _ => false
        }
    }
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
    runtime.log_info("test_installations: an update to list's bundle %, updated to counter_next %, uninstalled %, installed again %",
        if refused { "refused" } else { "taken" }, if updated { "and run" } else { "not run" }, if removed { "whole" } else { "not whole" },
        if reinstalled { "and run" } else { "not run" })
    // Crashed (decisions/0183): its fault reported, and it ended
    runtime.log_info("test_installations: the counter crashed %", if crash_installation(sessions, number, "counter") { "and ended" } else { "but didn't end" })
}

/**
 * Make an installation crash, for test_installations (crash_reports.make_crash), and wait up to STOP_GRACE for it to
 * end, its crash reported meanwhile (crashed).
 *
 * @param sessions The session manager, whose port is waited on.
 * @param number The session the installation runs in.
 * @param name The installation's name.
 * @return True once it's ended; false if it wasn't running, couldn't be made to crash, or didn't end in time.
 */
crash_installation :: fn(sessions: ptr[mut Manager], number: u32, name: string) -> bool {
    index := cast[usize](MAX_PROGRAMS)
    for i in 0..<sessions.count {
        if i < sessions.programs.count && sessions.programs[i].running && sessions.programs[i].session == number
            && name_of(&sessions.programs[i]) == name {
            index = i
        }
    }
    if index >= sessions.programs.count {
        return false
    }
    if !(crash_reports.make_crash(sessions.programs[index].process, sessions.programs[index].lifecycle) is_ok) {
        return false
    }
    deadline :: (slop_os.clock_monotonic() or_else 0) + STOP_GRACE
    loop {
        if !sessions.programs[index].running || (slop_os.clock_monotonic() or_else 0) >= deadline {
            break
        }
        packets : slop_os.Packet[8]
        taken :: slop_os.port_wait(sessions.port, packets, deadline) or_else 0
        ended_in(sessions, packets, cast[usize](taken))
    }
    return !sessions.programs[index].running
}

/**
 * Wait for a counter in a session to count to a number, in its data directory's file count.
 *
 * @param sessions The session manager, whose session's apps directory is read; it waits on a port of its own.
 * @param number The session's number, whose apps directory is read; one past MAX_SESSIONS gives false.
 * @param name The counter installation's name, its data directory's.
 * @param count The number waited for.
 * @return True once the file holds it; false if it doesn't within COUNT_WAIT, or the session has no apps directory.
 */
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

/**
 * Find a session's user's name.
 *
 * @param made The session, read only; the name returned is a view of it.
 * @return The name, a view of the session's, good while it lasts; empty for none.
 */
user_of :: fn(made: ptr[Session]) -> u8[] {
    count :: made.user_bytes
    return if count <= made.user.count { made.user[0..<count] } else { made.user[0..<0] }
}

/**
 * Make a port for a channel, from the session manager's budget.
 *
 * @param end The channel the port is bound to; the caller's, not closed.
 * @return The port, never closed; NO_HANDLE if it couldn't be made.
 */
port_of :: fn(end: slop_os.Channel) -> slop_os.Port {
    return os.port_for(slop_os.startup_block().budget, end) or_else cast[slop_os.Port](slop_os.NO_HANDLE)
}

/**
 * Give an ended program's log ring back to the events service (Retire), which reads what's left in it; or close it,
 * without the service or if it doesn't take it.
 *
 * @param sessions The session manager, on whose events service connection Retire is sent and its answer waited
 *     for.
 * @param ring The ring's owning handle, which moves; NO_HANDLE for none, which does nothing.
 */
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

/**
 * Make a copy of the session manager's debug log, for a program it starts, which logs through it.
 *
 * @param log The debug log, or NO_HANDLE.
 * @return The copy, with the rights to write, duplicate and transfer, the caller's to give; null without a log.
 */
duplicate_log :: fn(log: slop_os.DebugLog) -> slop_os.DebugLog? {
    rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_DEBUG_LOG_WRITE) | cast[u32](slop_os.RIGHT_DUPLICATE) | cast[u32](slop_os.RIGHT_TRANSFER))
    return match slop_os.handle_duplicate(cast[slop_os.Handle](log), rights) {
        case Ok(copy) => cast[slop_os.DebugLog](copy)
        case Error(error) => null
    }
}

/**
 * Wait for a while, on a port of its own, so no packet of the session manager's is taken meanwhile.
 *
 * @param sessions The session manager; not used, as the wait is on a port of its own.
 * @param nanoseconds How long to wait; if a port can't be made, it doesn't wait.
 */
pause :: fn(sessions: ptr[mut Manager], nanoseconds: u64) {
    waiter :: slop_os.port_create(slop_os.startup_block().budget) or_return void
    defer slop_os.handle_close(cast[slop_os.Handle](waiter))
    packets : slop_os.Packet[1]
    _ = slop_os.port_wait(waiter, packets, (slop_os.clock_monotonic() or_else 0) + nanoseconds)
}

/**
 * Find a program's name.
 *
 * @param program The program's place, read only; the name returned is a view of it.
 * @return Its name, a view of the program's, good while its place lasts; empty for none.
 */
name_of :: fn(program: ptr[Program]) -> string {
    count :: if cast[usize](program.name_bytes) <= program.name.count { cast[usize](program.name_bytes) } else { 0 }
    return if count == 0 { "" } else { string_of(&program.name[0], count) }
}
