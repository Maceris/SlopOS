/**
 * The powerbox (decisions/0018, 0156, design/console-and-sessions.md §5): one per session, which the session manager
 * starts with the session's home, the trusted path's prompt connection for the session, and a connection of its own,
 * on which it has the powerbox serve each of the session's programs, under the program's name. A program's RequestFile
 * or RequestDirectory goes to the trusted path as an Ask, with the program's name, its purpose and the home, read
 * only, for the chooser to list; the program's answered once the user has chosen, with what they chose opened on the
 * home, read only unless it asked to write, or refused. One request waits at a time; another is answered Busy. It
 * holds only its session's home, so a bug in it reaches one user's files.
 *
 * Kept grants (decisions/0158): a request that asks to be kept under a key, if the user ticks "keep for next time", is
 * granted again by the home and kept as a stored link, grants/<program>/<key>, in the home; Reopen with the key opens
 * it again without asking the user. Revoking its issued record, from the trusted path's grants view, makes it open
 * nothing.
 *
 * Elevation: RequestAccount goes to the trusted path as an Ask for an account, which it answers with the account made,
 * once the administrator has allowed it there; the program's told its name.
 */
package powerbox_service

import runtime from "base:runtime"
import os from "std:os"
import slop_os from "std:os/slop_os"
import dir from "std:os/slop_os/dir"
import files from "std:os/slop_os/files"
import lifecycle from "std:os/slop_os/lifecycle"
import network from "std:os/slop_os/network"
import process_manager from "std:os/slop_os/process_manager"
import text_buffer from "std:text_buffer"
import service_kit from "../../libraries/service_kit"
import powerbox from "../../protocols/powerbox"
import programs from "../../protocols/programs"
import prompt from "../../protocols/prompt"

/** No channel: what home_end is without a home, and prompt_end once the trusted path's gone. */
NONE : slop_os.Channel : cast[slop_os.Channel](slop_os.NO_HANDLE)
/** The key the prompt connection is bound to the port under, above the clients'. */
PROMPT_KEY : u64 : 1000
/** The key a request to stop is bound to the port under. */
STOP_KEY : u64 : 1001
/** The port key the session manager's answers come under, on the programs connection. */
SESSIONS_KEY : u64 : 1002
/**
 * A program asks at most this many times in a row, then about as many a minute (decisions/0193, 16e): its credit, in
 * thousandths of an ask, refills at ASKS_PER_MINUTE a minute, an ask spends one, and a refusal one more; an ask the
 * user grants gives its one back, so only what the user refuses or leaves unanswered limits it.
 */
ASKS_PER_MINUTE : u64 : 3
/**
 * The session asks at most this many times in a row, all its programs together, then about as many a minute
 * (decisions/0193, 16g), counted as ASKS_PER_MINUTE is. A connection's name is proved by the launch of the program
 * that holds it (decisions/0195, 18d), so a program asks only as itself; but it can start other programs, each asking
 * as itself, and a shell runs scripts under names of their own. This bounds them all, so the user can't be kept
 * answering.
 */
SESSION_ASKS_PER_MINUTE : u64 : 6
/** What follows a script's name where the user's shown it, as "backup.shell, a script". */
SCRIPT_SHOWN :: ", a script"
/**
 * What follows the name a launcher gives a program it asks to steer, shown to the user, when the program wasn't loaded
 * from an executable Find gave, so the name is only the launcher's word (decisions/0197, N2).
 */
NOT_FOUND_SHOWN :: ", by its launcher's word"
/** The programs whose asks are counted at once; the one heard from longest ago is forgotten for another. */
MAX_ASKERS :: 16
/** The most bytes of a kept grant's link's path, grants/<program>/<key>; a longer one is cut. */
PATH_BYTES :: 160
/** The client index of the session manager's connection, the first client, which alone may send Serve. */
MANAGER : usize : 0

/** A program's name, as the session manager gave it in Serve. */
Name :: struct {
    /** The name's bytes, the first count of them; a longer name is cut at NAME_BYTES. */
    bytes : u8[powerbox.NAME_BYTES],
    /** How many of bytes are the name: 0 for none, as for the session manager's own connection. */
    count #at_most(bytes.count) : usize,
}

/** The request waiting for the user: whose, what it asked for, and the key to keep it under, if it asked. */
Waiting :: struct {
    /** The client index of the program that asked; MAX_CLIENTS once it's gone, so no one's answered. */
    client : usize,
    /** What it asked for: a file, a directory, or an account. */
    kind : prompt.Kind,
    /** Whether it asked to write, not only read. */
    write : bool,
    /** The key to keep the grant under, the first key_count bytes, valid_key's. */
    key : u8[powerbox.KEY_BYTES],
    /** How many of key's bytes are the key: 0 if it didn't ask to keep it. */
    key_count #at_most(key.count) : usize,
    /** For a debugger (Debug or DebugOther): the program's name, the first name_count bytes. */
    name : u8[powerbox.NAME_BYTES],
    name_count #at_most(name.count) : usize,
    /** For a debugger: its port, the powerbox's to give the session manager, or close if it's refused. */
    port : slop_os.Port,
    /** For a debugger: the key its stops come under. */
    stop_key : u64,
    /** For a debugger: why it asks, the first purpose_count bytes, asked again of the administrator if need be. */
    purpose : u8[powerbox.PURPOSE_BYTES],
    purpose_count #at_most(purpose.count) : usize,
    /** For a network connection: what it would allow. */
    policy : network.Policy,
    /** For a program its launcher asks to steer: the launcher's handle to its process; NO_HANDLE for anything else. */
    steering : slop_os.Process,
}

/** A program's credit for asking the user, by its name (ASKS_PER_MINUTE). */
Asker :: struct {
    /** Its name, the first count bytes; count 0 for a place not in use. */
    name : u8[powerbox.NAME_BYTES],
    count #at_most(name.count) : usize,
    /** Its credit, in thousandths of an ask, at most ASKS_PER_MINUTE thousand. */
    credit : u64,
    /** When its credit was last brought up to date, in the monotonic clock's nanoseconds. */
    at : u64,
}

/** What the powerbox has asked the session manager and waits to hear, for its waiting request. */
SessionAsk :: enum {
    /** Nothing. */
    None,
    /** Where the program a debugger's asked for runs (Locate), before the user's asked. */
    Locate,
    /** To attach the debugger the user allowed (Attach). */
    Attach,
    /** To steer the program its launcher asked to, which the user allowed (SteerOwn). */
    Steer,
    /** What a program its launcher asks to steer was launched as (NameOwn), before the user's asked. */
    NameSteered,
}

/** The powerbox's state: its connections, its clients, and the request waiting for the user. */
Box :: struct {
    /** The port every client, the prompt connection and a stop are bound to, under their keys. */
    port : slop_os.Port,
    /** The session's home's dir connection, NONE without one; the grant's, never closed. */
    home_end : slop_os.Channel,
    /** A port bound to home_end, waited on for its answers. */
    home_port : slop_os.Port,
    /** The trusted path's prompt connection for the session; NONE once it's gone, which it closes. */
    prompt_end : slop_os.Channel,
    /** A port bound to prompt_end, waited on for its answers. */
    prompt_port : slop_os.Port,
    /** The clients: the session manager's connection first, then each program it has served. */
    clients : service_kit.Clients,
    /** Each client's program's name, by client index. */
    names : Name[service_kit.MAX_CLIENTS],
    /** The request waiting for the user, while has_waiting. */
    waiting : Waiting,
    /** Whether a request is waiting for the user; while one is, others are answered Busy. */
    has_waiting : bool,
    /**
     * What the waiting request asked the session manager, whose answer it waits for: it isn't waited for in place,
     * as the session manager may be asking the powerbox to Serve meanwhile, and each would wait on the other.
     */
    asking_sessions : SessionAsk,
    /** The programs that have asked, and their credit for asking again. */
    askers : Asker[MAX_ASKERS],
    /** The session's credit, all its programs' asks together (SESSION_ASKS_PER_MINUTE); its name's unused. */
    session_asks : Asker,
    /** The powerbox's programs connection to the session manager, for Attach (decisions/0185); NONE without one. */
    programs_end : slop_os.Channel,
    /** A port bound to programs_end, waited on for its answers. */
    programs_port : slop_os.Port,
    /**
     * A network connection allowing everything (decisions/0188, 13c), which what the user allows is narrowed from; NONE
     * without one, when every RequestNetwork is refused.
     */
    network_end : slop_os.Channel,
    /** A port bound to network_end, waited on for its answers. */
    network_port : slop_os.Port,
}

/**
 * Serve a session's programs as its powerbox: ask the user on the trusted path for files, directories and accounts
 * the programs request, and give them what the user chooses.
 *
 * A file or directory is opened on the home, read only unless the program asked to write; the program never sees the
 * home itself. Nothing is given without the user choosing it on the trusted path, except a grant the user chose to
 * keep, which Reopen opens again until it's revoked. It runs until it's asked to stop on its lifecycle channel.
 *
 * @param home The session's home volume's root, which every grant is opened on. Without it, as for a session no one's
 *     logged in to, every request is refused.
 * @param prompts The trusted path's prompt connection for the session, on which each request is asked of the user.
 *     If it goes, the request waiting is refused, and so is every request after it.
 * @param manager The session manager's connection, on which it sends Serve with each of the session's programs'
 *     connections and names.
 * @param programs A programs connection of the powerbox's own, on which it asks the session manager to attach a
 *     debugger the user's allowed (decisions/0185); without it, every RequestDebug is refused.
 * @param network A network connection allowing everything, which each network connection the user allows is narrowed
 *     from (decisions/0188); without it, every RequestNetwork is refused.
 * @return 0 when it's asked to stop; 1 if its port couldn't be made; 2 if a port for the home or the prompt
 *     connection couldn't be made or bound; 3 if the manager's connection couldn't be served.
 */
main :: fn(
    home : os.Channel[dir.Dir]?,
    prompts : os.Channel[prompt.Prompt],
    manager : os.Channel[powerbox.Powerbox],
    programs : os.Channel[programs.Programs]?,
    network : os.Channel[network.Network]?
) -> int {
    block :: slop_os.startup_block()
    box := runtime.new(Box)
    box.port = slop_os.port_create(block.budget) or_return 1
    box.programs_end = NONE
    box.network_end = NONE
    // Full from the start: charge() refills only for the time since, and the clock counts from boot, not from here
    box.session_asks = Asker.{credit = SESSION_ASKS_PER_MINUTE * 1000, at = slop_os.clock_monotonic() or_else 0}
    match network {
        case Some(found) => match os.port_for(block.budget, found.end) {
            case Some(port) => {
                box.network_end = found.end
                box.network_port = port
            }
            case None => {}
        }
        case None => {}
    }
    match programs {
        case Some(connection) => {
            box.programs_end = connection.end
            box.programs_port = os.port_for(block.budget, connection.end) or_return 2
            // Its answers wake the loop, taken as they come (take_sessions_answer)
            signals :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
            slop_os.port_bind(box.port, cast[slop_os.Handle](connection.end), signals, SESSIONS_KEY, .Persistent)
                or_return 2
        }
        case None => {}
    }
    box.home_end = NONE
    match home {
        case Some(root) => {
            box.home_end = root.end
            box.home_port = os.port_for(block.budget, root.end) or_return 2
        }
        case None => {}
    }
    box.prompt_end = prompts.end
    box.prompt_port = os.port_for(block.budget, prompts.end) or_return 2
    // Its answers wake the loop too
    signals :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    slop_os.port_bind(box.port, cast[slop_os.Handle](prompts.end), signals, PROMPT_KEY, .Persistent) or_return 2
    if !service_kit.add_client(&box.clients, box.port, manager.end) {
        return 3
    }
    _ = lifecycle.on_stop(box.port, STOP_KEY)
    runtime.log_info("serving")
    into := os.Incoming.{}
    loop {
        if lifecycle.stop_requested() {
            return 0
        }
        with {
            i : usize = 0
        }
        loop {
            serve(box, i, &into)
            i += 1
        }
        while i < box.clients.count
        take_answer(box, &into)
        take_sessions_answer(box, &into)
        packets : slop_os.Packet[8]
        _ = slop_os.port_wait(box.port, packets, slop_os.NO_DEADLINE)
    }
}

/**
 * Answer every request a client has sent, until there are none left, or it's gone.
 *
 * Serve is taken only from the session manager; from anyone else, it's refused and the end it gave is closed. A
 * request for the user waits unanswered until take_answer answers it. A client that's gone is dropped, and a request
 * of its that's waiting is answered to no one.
 *
 * @param box The powerbox, whose port the client's end is bound to: a client that's gone is dropped from its clients,
 *     a request for the user becomes its waiting one, and Serve adds a client.
 * @param index The client's index; one past the clients, or dropped, is passed over.
 * @param into Where each request is received, reused from one to the next.
 */
serve :: fn(box : ptr[mut Box], index : usize, into : ptr[mut os.Incoming]) {
    if index >= box.clients.ends.count {
        return void
    }
    end :: box.clients.ends[index]
    if cast[slop_os.Handle](end) == slop_os.NO_HANDLE {
        return void
    }
    loop {
        match powerbox.receive_request(end, box.port, into, false) {
            case Received => {}
            case Empty => return void
            case Unsupported => {
                _ = powerbox.answer_unsupported(end, box.port)
                continue
            }
            case _ => {
                service_kit.drop_client(&box.clients, index)
                // Its request, if one's waiting, is answered by no one
                if box.has_waiting && box.waiting.client == index {
                    box.waiting.client = service_kit.MAX_CLIENTS
                }
                return void
            }
        }
        out := os.Outgoing.{}
        response :: os.begin[powerbox.Response](&out)
        match os.message_of[powerbox.Request](into)^ {
            case Serve(served) => {
                response^ = if index == MANAGER && serve_program(box, os.items(into, served.name), served.end) {
                    .Done
                }
                else {
                    .Refused
                }
                if index != MANAGER {
                    _ = slop_os.handle_close(cast[slop_os.Handle](served.end.end))
                }
            }
            case RequestFile(asked) => {
                match ask(
                    box,
                    index,
                    .File,
                    asked.write,
                    os.items(into, asked.purpose),
                    os.items(into, asked.suggested),
                    os.items(into, asked.keep)
                ) {
                    case Some(answer) => response^ = answer
                    // Answered once the user has chosen
                    case None => continue
                }
            }
            case RequestDirectory(asked) => {
                match ask(
                    box,
                    index,
                    .Directory,
                    asked.write,
                    os.items(into, asked.purpose),
                    u8.[],
                    os.items(into, asked.keep)
                ) {
                    case Some(answer) => response^ = answer
                    case None => continue
                }
            }
            case Reopen(
                reopening
            ) => response^ = reopen(box, index, os.items(into, reopening.key), reopening.kind, reopening.write)
            case RequestAccount(asked) => {
                match ask(box, index, .Account, false, os.items(into, asked.purpose), u8.[], u8.[]) {
                    case Some(answer) => response^ = answer
                    case None => continue
                }
            }
            case RequestSystemLog(purpose) => {
                match ask(box, index, .SystemLog, false, os.items(into, purpose), u8.[], u8.[]) {
                    case Some(answer) => response^ = answer
                    case None => continue
                }
            }
            case RequestNetwork(asked) => {
                match ask_network(
                    box,
                    index,
                    os.items(into, asked.purpose),
                    os.items(into, asked.connect),
                    os.items(into, asked.listen)
                ) {
                    case Some(answer) => response^ = answer
                    case None => continue
                }
            }
            case RequestKeys(asked) => {
                kind :: if asked.change == .Add {
                    prompt.Kind.AddKey
                }
                else if asked.change == .Remove { prompt.Kind.RemoveKey } else { prompt.Kind.ListKeys }
                match ask(box, index, kind, false, os.items(into, asked.purpose), os.items(into, asked.key), u8.[]) {
                    case Some(answer) => response^ = answer
                    case None => continue
                }
            }
            case RequestMicrophone(purpose) => {
                match ask(box, index, .Microphone, false, os.items(into, purpose), u8.[], u8.[]) {
                    case Some(answer) => response^ = answer
                    case None => continue
                }
            }
            case RequestTrace(purpose) => {
                match ask(box, index, .Trace, false, os.items(into, purpose), u8.[], u8.[]) {
                    case Some(answer) => response^ = answer
                    case None => continue
                }
            }
            case RequestSteer(asked) => {
                match ask_steer(box, index, os.items(into, asked.name), os.items(into, asked.purpose), asked.process) {
                    case Some(answer) => response^ = answer
                    case None => continue
                }
            }
            case RequestDebug(asked) => {
                match ask_debug(
                    box,
                    index,
                    os.items(into, asked.name),
                    os.items(into, asked.purpose),
                    asked.port,
                    asked.key
                ) {
                    case Some(answer) => response^ = answer
                    case None => continue
                }
            }
            case RequestPower(asked) => {
                kind :: if asked.restart { prompt.Kind.Restart } else { prompt.Kind.ShutDown }
                match ask(box, index, kind, false, os.items(into, asked.purpose), u8.[], u8.[]) {
                    case Some(answer) => response^ = answer
                    case None => continue
                }
            }
        }
        _ = powerbox.send_response(end, box.port, &out)
    }
}

/**
 * Serve a program of the session's on a connection, under its name.
 *
 * @param box The powerbox: the connection is bound to its port as a new client, and the name kept in its names.
 * @param name The program's name, shown on the trusted path with each request it makes, and the folder its kept
 *     grants are in; cut at NAME_BYTES.
 * @param end The program's connection, which the powerbox keeps as a client from now on; on failure it isn't closed
 *     here.
 * @return True if it's served; false if there was no room for another client.
 */
serve_program :: fn(box : ptr[mut Box], name : u8[], end : os.Channel[powerbox.Powerbox]) -> bool {
    index :: service_kit.add_client_index(&box.clients, box.port, end.end) or_return false
    if index < box.names.count {
        box.names[index] = Name.{}
        for byte, i in name {
            if i < box.names[index].bytes.count {
                box.names[index].bytes[i] = byte
                box.names[index].count = i + 1
            }
        }
    }
    return true
}

/**
 * Find the name of the program a client is.
 *
 * @param box The powerbox, whose names are read.
 * @param index The client's index; past the names, the name is empty.
 * @return Its name, a view of the box's, good until the client's index is served again; empty for the session
 *     manager's connection or an index past the clients.
 */
name_of :: fn(box : ptr[Box], index : usize) -> u8[] {
    if index >= box.names.count {
        return box.names[0].bytes[0..<0]
    }
    name :: &box.names[index]
    return name.bytes[0..<name.count]
}

/**
 * Ask the user on the trusted path for what a program requests, with the program's name, its purpose and the home,
 * read only, for the chooser to list.
 *
 * @param box The powerbox; the request becomes its waiting one.
 * @param index The client index of the program asking.
 * @param kind What it asks for: a file, a directory, or an account.
 * @param write Whether it asks to write, not only read.
 * @param purpose Why it asks, in its own words, shown to the user as the program's.
 * @param suggested A file name to suggest, or empty.
 * @param key The key to keep the grant under if the user agrees, or empty not to ask; one that isn't valid_key's is
 *     refused.
 * @return Null once it's waiting for the user, to be answered by take_answer; or the answer at once: Busy with a
 *     request waiting already, Refused for a bad key, without a home or the trusted path, or if the home couldn't be
 *     narrowed or the Ask sent.
 */
ask :: fn(
    box : ptr[mut Box],
    index : usize,
    kind : prompt.Kind,
    write : bool,
    purpose : u8[],
    suggested : u8[],
    key : u8[]
) -> powerbox.Response? {
    if box.has_waiting {
        return .Busy
    }
    if key.count > 0 && !valid_key(key) {
        return .Refused
    }
    // Asked too often: refused without asking the user, who'd otherwise be asked over and over
    if !spend(box, name_of(box, index), 1000) {
        who :: name_of(box, index)
        runtime.log_info("refused % without asking: it's asked too often", as_text(who))
        return .Refused
    }
    if name_of(box, index).count > 0 && !charge(&box.session_asks, SESSION_ASKS_PER_MINUTE, 1000) {
        who :: name_of(box, index)
        runtime.log_info("refused % without asking: the session's asked too often", as_text(who))
        return .Refused
    }
    if box.home_end == NONE || box.prompt_end == NONE {
        return .Refused
    }
    home :: match ask_dir(box, box.home_end, box.home_port, .Narrow) {
        case Narrowed(narrowed) => narrowed
        case _ => return .Refused
    }
    // A script's shown as one, the shell that runs it vouching for its name (decisions/0195, 18e)
    shown : u8[programs.MAX_INSTALLATION_NAME + 16]
    shown_count := cast[usize](0)
    for byte in name_of(box, index) {
        if shown_count < shown.count {
            shown[shown_count] = byte
            shown_count += 1
        }
    }
    if programs.script_name(name_of(box, index)) {
        for byte in string_bytes(SCRIPT_SHOWN) {
            if shown_count < shown.count {
                shown[shown_count] = byte
                shown_count += 1
            }
        }
    }
    out := os.Outgoing.{}
    request :: os.begin[prompt.Request](&out)
    request^ = .Ask(
        prompt.Ask.{
            requester = os.append(&out, shown[0..<shown_count]),
            purpose = os.append(&out, purpose),
            suggested = os.append(&out, suggested),
            kind = kind,
            write = write,
            keep = key.count > 0,
            home = home,
        }
    )
    if prompt.send_request(box.prompt_end, box.prompt_port, &out) != null {
        return .Refused
    }
    box.waiting = Waiting.{client = index, kind = kind, write = write}
    for byte, i in key {
        if i < box.waiting.key.count {
            box.waiting.key[i] = byte
            box.waiting.key_count = i + 1
        }
    }
    box.has_waiting = true
    who :: name_of(box, index)
    runtime.log_info(
        "% asks for a %",
        if who.count > 0 { string_of(&who[0], who.count) } else { "a program" },
        if kind == .Account {
            "new account"
        }
        else if kind == .ShutDown {
            "shutdown"
        }
        else if kind == .Restart {
            "restart"
        }
        else if kind == .Debug || kind == .DebugOther {
            "debugger"
        }
        else if kind == .Trace {
            "trace"
        }
        else if kind == .SystemLog {
            "read of the system's log"
        }
        else if kind == .Network {
            "network connection"
        }
        else if kind == .Microphone {
            "microphone"
        }
        else if kind == .AddKey {
            "key added"
        }
        else if kind == .RemoveKey {
            "key removed"
        }
        else if kind == .ListKeys {
            "list of keys"
        }
        else if kind == .File {
            if write {
                "file to write"
            }
            else {
                "file to read"
            }
        }
        else {
            if write {
                "directory to write in"
            }
            else {
                "directory to read"
            }
        }
    )
    return null
}

/**
 * Ask the user for a network connection a program wants: its rules described on the trusted path.
 *
 * @param box The powerbox.
 * @param index The asking program's client index.
 * @param purpose Why it asks.
 * @param connect What it would connect to.
 * @param listen What it would listen on.
 * @return The answer now: Busy, or Refused without a network connection to give from, or with rules past MAX_RULES;
 *     null
 *     once it's asked, to be answered when the user has.
 */
ask_network :: fn(
    box : ptr[mut Box],
    index : usize,
    purpose : u8[],
    connect : network.Rule[],
    listen : network.Rule[]
) -> powerbox.Response? {
    if box.network_end == NONE {
        return .Refused
    }
    policy :: network.policy_of(connect, listen) or_return .Refused
    storage : u8[200]
    described := text_buffer.make(storage)
    network.describe(&policy, &described)
    asked :: ask(box, index, .Network, false, purpose, string_bytes(text_buffer.as_string(&described)), u8.[])
    if asked is_none {
        box.waiting.policy = policy
    }
    return asked
}

/**
 * Give the waiting program the network connection the user allowed, narrowed from the powerbox's own.
 *
 * @param box The powerbox, its waiting request a network connection's.
 */
network_allowed :: fn(box : ptr[mut Box]) {
    match network.narrow(box.network_end, box.network_port, &box.waiting.policy) {
        case Some(made) => {
            storage : u8[200]
            described := text_buffer.make(storage)
            network.describe(&box.waiting.policy, &described)
            who :: name_of(box, box.waiting.client)
            runtime.log_info("gave % a network connection: %", as_text(who), text_buffer.as_string(&described))
            answer(box, .NetworkGranted(made))
        }
        case None => answer(box, .Refused)
    }
}

/**
 * Take the trusted path's answer to the waiting request, if it's come, and answer the program that asked.
 *
 * What the user chose is opened on the home and given, and kept if the user ticked to keep it; an account made is
 * named; anything else is refused. If the trusted path's gone, its connection's closed and the request refused.
 *
 * @param box The powerbox; its waiting request is answered, unless the answer hasn't come.
 * @param into Where the answer is received.
 */
take_answer :: fn(box : ptr[mut Box], into : ptr[mut os.Incoming]) {
    if !box.has_waiting || box.prompt_end == NONE {
        return void
    }
    match prompt.receive_response(box.prompt_end, box.prompt_port, into, false) {
        case Received => {}
        case Failed(error) => {
            // The trusted path's gone, and nothing can be asked of the user from now on
            _ = slop_os.handle_close(cast[slop_os.Handle](box.prompt_end))
            box.prompt_end = NONE
            answer(box, .Refused)
            return void
        }
        case _ => return void
    }
    // What the user granted doesn't count against the program: only what's refused, or never answered, does
    granted :: match os.message_of[prompt.Response](into)^ {
        case Refused => false
        case Unsupported => false
        case _ => true
    }
    if granted {
        give_back(box, name_of(box, box.waiting.client), 1000)
        if name_of(box, box.waiting.client).count > 0 {
            refill_by(&box.session_asks, SESSION_ASKS_PER_MINUTE, 1000)
        }
    }
    match os.message_of[prompt.Response](into)^ {
        case Allowed => {
            if box.waiting.kind == .Debug && cast[slop_os.Handle](box.waiting.steering) != slop_os.NO_HANDLE {
                steer_allowed(box)
                return void
            }
            if box.waiting.kind == .Debug || box.waiting.kind == .DebugOther {
                attach_allowed(box, into)
                return void
            }
            if box.waiting.kind == .Network {
                network_allowed(box)
                return void
            }
            if box.waiting.kind == .AddKey || box.waiting.kind == .RemoveKey {
                runtime.log_info("the user % a key", if box.waiting.kind == .AddKey { "added" } else { "removed" })
                answer(box, .Done)
                return void
            }
            runtime.log_info(
                "the administrator allowed a %",
                if box.waiting.kind == .Restart { "restart" } else { "shutdown" }
            )
            answer(box, .Allowed)
        }
        case LogGranted(given) => {
            runtime.log_info("the administrator allowed reading the system's log")
            answer(box, .LogGranted(given))
        }
        case TraceGranted(given) => {
            runtime.log_info("the administrator allowed a trace")
            answer(box, .TraceGranted(given))
        }
        case MicrophoneGranted(given) => {
            who :: name_of(box, box.waiting.client)
            runtime.log_info("gave % the microphone", as_text(who))
            answer(box, .MicrophoneGranted(given))
        }
        case KeysListed(listed) => answer_listed(box, os.items(into, listed))
        case AccountMade(made) => {
            name :: os.items(into, made)
            who :: name_of(box, box.waiting.client)
            runtime.log_info("made the account % for %", as_text(name), as_text(who))
            answer_made(box, name)
        }
        case Chosen(choice) => {
            path :: os.items(into, choice.path)
            given :: opened(box, path, choice.new, box.waiting.kind, box.waiting.write)
            if given is_some {
                who :: name_of(box, box.waiting.client)
                runtime.log_info(
                    "gave % %",
                    if who.count > 0 { string_of(&who[0], who.count) } else { "a program" },
                    if path.count > 0 { string_of(&path[0], path.count) } else { "the home" }
                )
                if choice.keep && box.waiting.key_count > 0 {
                    keep(box, box.waiting.client, box.waiting.key[0..<box.waiting.key_count], path, box.waiting.write)
                }
            }
            answer(box, given or_else .Refused)
        }
        case _ => {
            runtime.log_info("the user refused")
            // A refusal counts double against the program, so one the user keeps refusing is asked less
            _ = spend(box, name_of(box, box.waiting.client), 1000)
            if name_of(box, box.waiting.client).count > 0 {
                _ = charge(&box.session_asks, SESSION_ASKS_PER_MINUTE, 1000)
            }
            refuse_debug_port(box)
            answer(box, .Refused)
        }
    }
}

/**
 * Spend some of a program's credit for asking the user, its credit first brought up to date: ASKS_PER_MINUTE thousand
 * thousandths a minute, at most that many.
 *
 * @param box The powerbox, whose askers keep the program's credit; one not among them takes the place of the one heard
 *     from longest ago, with full credit.
 * @param name The program's name; empty, as for the session manager's own connection, is never limited.
 * @param cost Thousandths of an ask.
 * @return Whether it had the credit, which is then spent; false leaves it as it was, but at zero for a refusal's.
 */
spend :: fn(box : ptr[mut Box], name : u8[], cost : u64) -> bool {
    if name.count == 0 {
        return true
    }
    now :: slop_os.clock_monotonic() or_else 0
    most :: ASKS_PER_MINUTE * 1000
    place := box.askers.count
    oldest := cast[usize](0)
    for asker, i in box.askers {
        if asker.count == name.count
            && same_text(asker.name[0..<asker.count], name) {
            place = i
        }
        if asker.at < box.askers[oldest].at {
            oldest = i
        }
    }
    if place >= box.askers.count {
        place = oldest
        if place >= box.askers.count {
            return true
        }
        fresh := Asker.{credit = most, at = now}
        for byte, i in name {
            if i < fresh.name.count {
                fresh.name[i] = byte
                fresh.count = i + 1
            }
        }
        box.askers[place] = fresh
    }
    return charge(&box.askers[place], ASKS_PER_MINUTE, cost)
}

/**
 * Spend some of a credit for asking, brought up to date first: per_minute thousand thousandths a minute, at most that
 * many.
 *
 * @param asker The credit, which should start full: one zeroed refills only for the clock's time, since boot.
 * @param per_minute How many asks a minute it refills by, and holds at most.
 * @param cost Thousandths of an ask.
 * @return Whether it had the credit, which is then spent; false leaves it at zero.
 */
charge :: fn(asker : ptr[mut Asker], per_minute : u64, cost : u64) -> bool {
    now :: slop_os.clock_monotonic() or_else 0
    most :: per_minute * 1000
    // Refilled for the time since, in nanoseconds' thousandths
    refill :: (now - asker.at) / (60_000_000_000 / most)
    asker.credit = if asker.credit + refill > most { most } else { asker.credit + refill }
    asker.at = now
    if asker.credit < cost {
        asker.credit = 0
        return false
    }
    asker.credit -= cost
    return true
}

/** Give back some of a credit for asking, at most per_minute thousand after, as for an ask the user granted. */
refill_by :: fn(asker : ptr[mut Asker], per_minute : u64, amount : u64) {
    most :: per_minute * 1000
    asker.credit = if asker.credit + amount > most { most } else { asker.credit + amount }
}

/**
 * Give back some of a program's credit for asking the user, as for an ask the user granted.
 *
 * @param box The powerbox, whose askers keep the program's credit; a program not among them is left out.
 * @param name The program's name; empty is never limited, so nothing's done.
 * @param amount Thousandths of an ask; its credit is at most ASKS_PER_MINUTE thousand after.
 */
give_back :: fn(box : ptr[mut Box], name : u8[], amount : u64) {
    if name.count == 0 {
        return void
    }
    most :: ASKS_PER_MINUTE * 1000
    for &asker in box.askers {
        if asker.count == name.count
            && same_text(asker.name[0..<asker.count], name) {
            asker.credit = if asker.credit + amount > most { most } else { asker.credit + amount }
        }
    }
}

/** Tell whether two byte slices hold the same bytes. */
same_text :: fn(a : u8[], b : u8[]) -> bool {
    if a.count != b.count {
        return false
    }
    for byte, i in a {
        if i >= b.count || b[i] != byte {
            return false
        }
    }
    return true
}

/**
 * Ask the user whether a program may debug another of the session's (decisions/0185, 12f), keeping what the session
 * manager needs to attach it once they've allowed it.
 *
 * @param box The powerbox.
 * @param index The asking client's index.
 * @param name The program to debug, by the name its session runs it under.
 * @param purpose Why it asks.
 * @param port The debugger's port, which the powerbox now holds; closed if it's refused.
 * @param key The key its stops come under.
 * @return An answer now, Busy or Refused, the port closed for Refused; null once it's asked, answered when the user
 *     has.
 */
ask_debug :: fn(
    box : ptr[mut Box],
    index : usize,
    name : u8[],
    purpose : u8[],
    port : slop_os.Port,
    key : u64
) -> powerbox.Response? {
    if box.has_waiting {
        _ = slop_os.handle_close(cast[slop_os.Handle](port))
        return .Busy
    }
    if box.programs_end == NONE || name.count == 0 || name.count > powerbox.NAME_BYTES {
        _ = slop_os.handle_close(cast[slop_os.Handle](port))
        return .Refused
    }
    /*
     * The user is asked for their own session's program, the administrator for another user's: where it runs is
     * asked of the session manager first, and the request waits for its answer (take_sessions_answer), not here
     */
    out := os.Outgoing.{}
    request :: os.begin[programs.Request](&out)
    request^ = .Locate(os.append(&out, name))
    if programs.send_request(box.programs_end, box.programs_port, &out) != null {
        _ = slop_os.handle_close(cast[slop_os.Handle](port))
        return .Refused
    }
    box.has_waiting = true
    box.asking_sessions = .Locate
    box.waiting = Waiting.{client = index, kind = .Debug}
    for byte, i in name {
        if i < box.waiting.name.count {
            box.waiting.name[i] = byte
            box.waiting.name_count = i + 1
        }
    }
    for byte, i in purpose {
        if i < box.waiting.purpose.count {
            box.waiting.purpose[i] = byte
            box.waiting.purpose_count = i + 1
        }
    }
    box.waiting.port = port
    box.waiting.stop_key = key
    return null
}

/**
 * The user, or for another user's program the administrator, allowed a debugger: ask the session manager to attach
 * it, and answer the program with what it gives. A program only another user's session runs is asked of the
 * administrator first, once.
 *
 * @param box The powerbox, whose waiting request is a debugger's.
 * @param into Where the session manager's answer is received.
 */
attach_allowed :: fn(box : ptr[mut Box], into : ptr[mut os.Incoming]) {
    elevated :: box.waiting.kind == .DebugOther
    count :: box.waiting.name_count
    if count == 0 || count > box.waiting.name.count {
        refuse_debug_port(box)
        answer(box, .Refused)
        return void
    }
    name :: box.waiting.name[0..<count]
    out := os.Outgoing.{}
    request :: os.begin[programs.Request](&out)
    request^ = .Attach(
        programs.Attaching.{
            name = os.append(&out, name),
            port = box.waiting.port,
            key = box.waiting.stop_key,
            elevated = elevated,
        }
    )
    // The port moves with the request, sent or not
    box.waiting.port = cast[slop_os.Port](slop_os.NO_HANDLE)
    if programs.send_request(box.programs_end, box.programs_port, &out) != null {
        answer(box, .Refused)
        return void
    }
    // Answered as it comes (take_sessions_answer), not waited for here
    box.asking_sessions = .Attach
}

/**
 * Take the session manager's answer to what the waiting request asked of it, if it's come: where a program runs, then
 * the user or the administrator asked; or the debugger attached, and the program answered.
 *
 * @param box The powerbox, whose waiting request goes on, or is answered.
 * @param into Where the answer's received.
 */
take_sessions_answer :: fn(box : ptr[mut Box], into : ptr[mut os.Incoming]) {
    if box.asking_sessions == .None || box.programs_end == NONE {
        return void
    }
    asked :: box.asking_sessions
    match programs.receive_response(box.programs_end, box.programs_port, into, false) {
        case Received => {}
        case Empty => return void
        case _ => {
            box.asking_sessions = .None
            refuse_debug_port(box)
            answer(box, .Refused)
            return void
        }
    }
    box.asking_sessions = .None
    name :: box.waiting.name[0..<box.waiting.name_count]
    if asked == .NameSteered {
        match os.message_of[programs.Response](into)^ {
            case Named(text) => ask_named_steer(box, os.items(into, text))
            case _ => ask_named_steer(box, u8.[])
        }
        return void
    }
    if asked == .Steer {
        match os.message_of[programs.Response](into)^ {
            case Steered(given) => {
                runtime.log_info("let % steer a program it launched", as_text(name))
                answer_steered(box, given)
            }
            case _ => answer(box, .Refused)
        }
        return void
    }
    if asked == .Attach {
        match os.message_of[programs.Response](into)^ {
            case Attached(attached) => {
                runtime.log_info("attached a debugger to %", as_text(name))
                answer_attached(box, attached, os.items(into, attached.program))
            }
            case Refused(problem) => {
                runtime.log_info("couldn't attach a debugger to %: %", as_text(name), problem)
                answer(box, .Refused)
            }
            case _ => answer(box, .Refused)
        }
        return void
    }
    // Located: the user's asked for their own session's program, the administrator for another user's
    location :: match os.message_of[programs.Response](into)^ {
        case Located(where) => where
        case _ => programs.Location.Nowhere
    }
    kind :: match location {
        case .Here => prompt.Kind.Debug
        case .Elsewhere => prompt.Kind.DebugOther
        case _ => {
            refuse_debug_port(box)
            answer(box, .Refused)
            return void
        }
    }
    // What ask keeps of the request is set again after it: the name, purpose, port and key stay the debugger's
    kept := box.waiting
    // The program that asked went meanwhile: no one's asked for it
    if kept.client >= box.clients.ends.count
        || cast[slop_os.Handle](box.clients.ends[kept.client]) == slop_os.NO_HANDLE {
        refuse_debug_port(box)
        box.has_waiting = false
        return void
    }
    box.has_waiting = false
    purpose :: kept.purpose[0..<kept.purpose_count]
    // From the copy: ask sets box.waiting afresh, which name was a view of
    kept_name :: kept.name[0..<kept.name_count]
    refused :: ask(box, kept.client, kind, false, purpose, kept_name, u8.[])
    match refused {
        case Some(response) => {
            box.waiting = kept
            refuse_debug_port(box)
            answer(box, response)
        }
        case None => {
            box.waiting.name = kept.name
            box.waiting.name_count = kept.name_count
            box.waiting.purpose = kept.purpose
            box.waiting.purpose_count = kept.purpose_count
            box.waiting.port = kept.port
            box.waiting.stop_key = kept.stop_key
        }
    }
}

/**
 * Ask the user whether a program may steer one it launched (decisions/0195, 18b), as debugging their own program is
 * asked. The program's shown by what it was launched as (decisions/0197, N2), which the session manager's asked first
 * (NameOwn), the request waiting for its answer (take_sessions_answer), not here; the name the asker gives is shown
 * only for a program not loaded from an executable Find gave, marked as such.
 *
 * @param box The powerbox.
 * @param index The asking client's index.
 * @param name The program's name, as the asker gives it.
 * @param purpose Why it asks.
 * @param process The launcher's handle to the program's process, which the powerbox now holds; closed if it's refused.
 * @return An answer now, Busy or Refused, the handle closed; null once the session manager's asked, answered when the
 *     user has.
 */
ask_steer :: fn(
    box : ptr[mut Box],
    index : usize,
    name : u8[],
    purpose : u8[],
    process : slop_os.Process
) -> powerbox.Response? {
    if box.has_waiting {
        _ = slop_os.handle_close(cast[slop_os.Handle](process))
        return .Busy
    }
    if box.programs_end == NONE || name.count == 0 || name.count > powerbox.NAME_BYTES {
        _ = slop_os.handle_close(cast[slop_os.Handle](process))
        return .Refused
    }
    // With RIGHT_DUPLICATE, as the session manager sends the process manager a copy of it in turn
    copy :: slop_os.handle_duplicate(
        cast[slop_os.Handle](process),
        cast[slop_os.Rights](cast[u32](slop_os.RIGHT_PROCESS_KILL)
            | cast[u32](slop_os.RIGHT_DUPLICATE)
            | cast[u32](slop_os.RIGHT_TRANSFER))
    ) or_else slop_os.NO_HANDLE
    if copy == slop_os.NO_HANDLE {
        _ = slop_os.handle_close(cast[slop_os.Handle](process))
        return .Refused
    }
    out := os.Outgoing.{}
    os.begin[programs.Request](&out)^ = .NameOwn(cast[slop_os.Process](copy))
    if programs.send_request(box.programs_end, box.programs_port, &out) != null {
        _ = slop_os.handle_close(cast[slop_os.Handle](process))
        return .Refused
    }
    box.has_waiting = true
    box.asking_sessions = .NameSteered
    box.waiting = Waiting.{client = index, kind = .Debug, steering = process}
    for byte, i in name {
        if i < box.waiting.name.count {
            box.waiting.name[i] = byte
            box.waiting.name_count = i + 1
        }
    }
    for byte, i in purpose {
        if i < box.waiting.purpose.count {
            box.waiting.purpose[i] = byte
            box.waiting.purpose_count = i + 1
        }
    }
    return null
}

/**
 * The session manager said what a program its launcher asks to steer was launched as: ask the user, showing that, or
 * for a program not loaded from an executable Find gave, the name its launcher gave, marked as such.
 *
 * @param box The powerbox, whose waiting request is a steering one.
 * @param named The name the session manager gave; empty for none.
 */
ask_named_steer :: fn(box : ptr[mut Box], named : u8[]) {
    kept := box.waiting
    // The program that asked went meanwhile: no one's asked for it
    if kept.client >= box.clients.ends.count
        || cast[slop_os.Handle](box.clients.ends[kept.client]) == slop_os.NO_HANDLE {
        refuse_debug_port(box)
        box.has_waiting = false
        return void
    }
    shown : u8[powerbox.NAME_BYTES + 32]
    shown_count := cast[usize](0)
    given :: kept.name[0..<kept.name_count]
    for byte in named {
        if shown_count < shown.count {
            shown[shown_count] = byte
            shown_count += 1
        }
    }
    if named.count == 0 {
        for byte in given {
            if shown_count < shown.count {
                shown[shown_count] = byte
                shown_count += 1
            }
        }
        for byte in string_bytes(NOT_FOUND_SHOWN) {
            if shown_count < shown.count {
                shown[shown_count] = byte
                shown_count += 1
            }
        }
    }
    purpose :: kept.purpose[0..<kept.purpose_count]
    box.has_waiting = false
    match ask(box, kept.client, .Debug, false, purpose, shown[0..<shown_count], u8.[]) {
        case Some(response) => {
            box.waiting = kept
            refuse_debug_port(box)
            answer(box, response)
        }
        case None => box.waiting.steering = kept.steering
    }
}

/**
 * The user allowed a program to steer one it launched: ask the session manager to have it steered, and answer with what
 * it gives (take_sessions_answer).
 *
 * @param box The powerbox, whose waiting request is a steering one; its handle moves with the request.
 */
steer_allowed :: fn(box : ptr[mut Box]) {
    out := os.Outgoing.{}
    os.begin[programs.Request](&out)^ = .SteerOwn(box.waiting.steering)
    box.waiting.steering = cast[slop_os.Process](slop_os.NO_HANDLE)
    if programs.send_request(box.programs_end, box.programs_port, &out) != null {
        answer(box, .Refused)
        return void
    }
    box.asking_sessions = .Steer
}

/**
 * Answer the waiting steering request with the program's steering handles, which move to the asker.
 *
 * @param box The powerbox.
 * @param given What the session manager gave.
 */
answer_steered :: fn(box : ptr[mut Box], given : process_manager.Steering) {
    box.has_waiting = false
    index :: box.waiting.client
    if index >= box.clients.ends.count || cast[slop_os.Handle](box.clients.ends[index]) == slop_os.NO_HANDLE {
        for handle in slop_os.Handle.[
            cast[slop_os.Handle](given.process),
            cast[slop_os.Handle](given.intercept),
            cast[slop_os.Handle](given.space)
        ] {
            _ = slop_os.handle_close(handle)
        }
        return void
    }
    out := os.Outgoing.{}
    os.begin[powerbox.Response](&out)^ = .Steered(given)
    _ = powerbox.send_response(box.clients.ends[index], box.port, &out)
}

/**
 * Answer the waiting debugger's request with the program attached; its handles move to the debugger.
 *
 * @param box The powerbox.
 * @param attached What the session manager gave.
 * @param program The program's name, attached.program's bytes.
 */
answer_attached :: fn(box : ptr[mut Box], attached : powerbox.Attached, program : u8[]) {
    box.has_waiting = false
    index :: box.waiting.client
    if index >= box.clients.ends.count || cast[slop_os.Handle](box.clients.ends[index]) == slop_os.NO_HANDLE {
        for handle in slop_os.Handle.[
            cast[slop_os.Handle](attached.process),
            cast[slop_os.Handle](attached.intercept),
            cast[slop_os.Handle](attached.space)
        ] {
            _ = slop_os.handle_close(handle)
        }
        return void
    }
    out := os.Outgoing.{}
    response :: os.begin[powerbox.Response](&out)
    response^ = .Attached(
        powerbox.Attached.{
            process = attached.process,
            intercept = attached.intercept,
            space = attached.space,
            image = attached.image,
            program = os.append(&out, program),
        }
    )
    _ = powerbox.send_response(box.clients.ends[index], box.port, &out)
}

/**
 * Close a refused debugger's port, if the waiting request is a debugger's.
 *
 * @param box The powerbox.
 */
refuse_debug_port :: fn(box : ptr[mut Box]) {
    if (box.waiting.kind == .Debug || box.waiting.kind == .DebugOther)
        && cast[slop_os.Handle](box.waiting.port) != slop_os.NO_HANDLE {
        _ = slop_os.handle_close(cast[slop_os.Handle](box.waiting.port))
        box.waiting.port = cast[slop_os.Port](slop_os.NO_HANDLE)
    }
    // A steering request's handle to its program, too
    if cast[slop_os.Handle](box.waiting.steering) != slop_os.NO_HANDLE {
        _ = slop_os.handle_close(cast[slop_os.Handle](box.waiting.steering))
        box.waiting.steering = cast[slop_os.Process](slop_os.NO_HANDLE)
    }
}

/**
 * Open what's at a path on the home as asked: a file, read only unless it would write, made if it's new; or a
 * directory, read only unless it would write, made if it's new.
 *
 * @param box The powerbox, on whose home everything's opened, each request waited for on its home port.
 * @param path The path beneath the home; empty for the home itself, as a directory.
 * @param new Whether it's to be made: a new file is made only to write, so a new one to read is refused.
 * @param kind A file or a directory.
 * @param write Whether to grant writing as well as reading.
 * @return The grant, whose end moves to the program in the answer; null if it can't be opened.
 */
opened :: fn(box : ptr[mut Box], path : u8[], new : bool, kind : prompt.Kind, write : bool) -> powerbox.Response? {
    out := os.Outgoing.{}
    if kind == .File {
        if write {
            opening :: os.begin[dir.Request](&out)
            opening^ = .OpenFile(
                dir.OpenFile.{
                    path = os.append(&out, path),
                    creation = if new { files.Creation.New } else { files.Creation.Existing },
                }
            )
            return match ask_dir_with(box, box.home_end, box.home_port, &out) {
                case OpenedFile(file) => .GrantedFile(file)
                case _ => null
            }
        }
        if new {
            return null
        }
        reading :: os.begin[dir.Request](&out)
        reading^ = .OpenReadOnlyFile(os.append(&out, path))
        return match ask_dir_with(box, box.home_end, box.home_port, &out) {
            case OpenedReadOnlyFile(file) => .GrantedReadOnlyFile(file)
            case _ => null
        }
    }
    // A directory: the home itself, or one beneath it
    directory := NONE
    if path.count == 0 {
        directory = connection_to(box.home_end, box.home_port) or_return null
    }
    else {
        opening_directory :: os.begin[dir.Request](&out)
        opening_directory^ = .OpenDirectory(dir.OpenDirectory.{path = os.append(&out, path), create = new})
        match ask_dir_with(box, box.home_end, box.home_port, &out) {
            case OpenedDirectory(opened_directory) => directory = opened_directory.end
            case _ => return null
        }
    }
    if write {
        return .GrantedDirectory(os.Channel[dir.Dir].{end = directory})
    }
    port :: os.port_for(slop_os.startup_block().budget, directory) or_else cast[slop_os.Port](slop_os.NO_HANDLE)
    narrowed :: if cast[slop_os.Handle](port) == slop_os.NO_HANDLE {
        dir.Response.Unsupported
    }
    else {
        ask_dir(box, directory, port, .Narrow)
    }
    if cast[slop_os.Handle](port) != slop_os.NO_HANDLE {
        _ = slop_os.handle_close(cast[slop_os.Handle](port))
    }
    _ = slop_os.handle_close(cast[slop_os.Handle](directory))
    return match narrowed {
        case Narrowed(read_only) => .GrantedReadOnlyDirectory(read_only)
        case _ => null
    }
}

/**
 * Keep what the user chose for a program under a key: granted by the home again, read only unless it was asked for
 * to write, and the grant kept as a stored link at grants/<program>/<key>, in place of one there before.
 *
 * Failing to keep it is only logged; the program has its grant either way.
 *
 * @param box The powerbox, whose home the grants folder and the link are made in, each request waited for.
 * @param index The client index of the program, whose name names the folder; a program without one keeps nothing.
 * @param key The key, valid_key's.
 * @param path What the user chose, beneath the home; the home itself, empty, isn't kept.
 * @param write Whether the kept grant writes.
 */
keep :: fn(box : ptr[mut Box], index : usize, key : u8[], path : u8[], write : bool) {
    who :: name_of(box, index)
    if who.count == 0 || path.count == 0 {
        return void
    }
    storage : u8[PATH_BYTES]
    if !made_directory(box, string_bytes("grants")) || !made_directory(box, kept_path(who, key[0..<0], &storage)) {
        return void
    }
    out := os.Outgoing.{}
    granting :: os.begin[dir.Request](&out)
    granting^ = .Grant(dir.GrantOf.{path = os.append(&out, path), write = write})
    given :: match ask_dir_with(box, box.home_end, box.home_port, &out) {
        case Granted(made) => made
        case _ => {
            runtime.log_info("couldn't keep it")
            return void
        }
    }
    link_storage : u8[PATH_BYTES]
    link :: kept_path(who, key, &link_storage)
    out = os.Outgoing.{}
    removing :: os.begin[dir.Request](&out)
    removing^ = .Remove(os.append(&out, link))
    _ = ask_dir_with(box, box.home_end, box.home_port, &out)
    out = os.Outgoing.{}
    linking :: os.begin[dir.Request](&out)
    linking^ = .Link(dir.LinkTo.{path = os.append(&out, link), grant = given})
    match ask_dir_with(box, box.home_end, box.home_port, &out) {
        case Done => runtime.log_info("kept % for %", string_of(&path[0], path.count), string_of(&who[0], who.count))
        case _ => runtime.log_info("couldn't keep it")
    }
}

/**
 * Open again, through its link, a grant a program kept under a key, without asking the user.
 *
 * @param box The powerbox, whose home the link is opened on, its answer waited for.
 * @param index The client index of the program, whose kept grants alone it can reopen.
 * @param key The key it was kept under.
 * @param kind A file or a directory.
 * @param write Whether to open it to write; a link kept read only won't open to write.
 * @return The grant; Refused without a home or a name, for a key that isn't valid_key's, or if it's gone or revoked.
 */
reopen :: fn(box : ptr[mut Box], index : usize, key : u8[], kind : powerbox.Kind, write : bool) -> powerbox.Response {
    who :: name_of(box, index)
    if box.home_end == NONE || who.count == 0 || !valid_key(key) {
        return .Refused
    }
    storage : u8[PATH_BYTES]
    link :: kept_path(who, key, &storage)
    match opened(box, link, false, if kind == .Directory { prompt.Kind.Directory } else { prompt.Kind.File }, write) {
        case Some(given) => {
            runtime.log_info("reopened % for %", as_text(key), as_text(who))
            return given
        }
        case None => {
            runtime.log_info("couldn't reopen % for %", as_text(key), as_text(who))
            return .Refused
        }
    }
}

/**
 * Make a directory beneath the home if it isn't there.
 *
 * @param box The powerbox, whose home the directory is made on, its answer waited for; the directory's end that comes
 *     back is closed.
 * @param path The directory's path beneath the home.
 * @return True if it's there now.
 */
made_directory :: fn(box : ptr[mut Box], path : u8[]) -> bool {
    out := os.Outgoing.{}
    making :: os.begin[dir.Request](&out)
    making^ = .OpenDirectory(dir.OpenDirectory.{path = os.append(&out, path), create = true})
    return match ask_dir_with(box, box.home_end, box.home_port, &out) {
        case OpenedDirectory(made) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](made.end))
            true
        }
        case _ => false
    }
}

/**
 * Write the path of a program's kept grants: grants/<program>, and /<key> after it if there's one.
 *
 * @param who The program's name, as its client was named (name_of), written after "grants/" as it is; callers
 *     pass a non-empty one.
 * @param key The key, or empty for the program's folder.
 * @param storage Where the path is written; what's past PATH_BYTES is cut.
 * @return The path, a view of storage, good as long as it is.
 */
kept_path :: fn(who : u8[], key : u8[], storage : ptr[mut u8[PATH_BYTES]]) -> u8[] {
    count : usize = 0
    append_bytes(storage, &count, string_bytes("grants/"))
    append_bytes(storage, &count, who)
    if key.count > 0 {
        append_bytes(storage, &count, string_bytes("/"))
        append_bytes(storage, &count, key)
    }
    return if count <= storage.count { storage^[0..<count] } else { storage^[0..<0] }
}

/**
 * Append bytes to a path being written, as many as fit.
 *
 * @param storage The path being written, from count on; bytes before count aren't touched.
 * @param count How many of its bytes are in use, moved on by those appended.
 * @param bytes The bytes; those past PATH_BYTES are dropped.
 */
append_bytes :: fn(storage : ptr[mut u8[PATH_BYTES]], count : ptr[mut usize], bytes : u8[]) {
    for byte in bytes {
        at :: count^
        if at < storage.count {
            storage^[at] = byte
            count^ = at + 1
        }
    }
}

/**
 * View bytes as text, for the log.
 *
 * @param bytes The bytes, not checked to be UTF-8.
 * @return The text, a view of bytes; empty for none.
 */
as_text :: fn(bytes : u8[]) -> string {
    return if bytes.count > 0 { string_of(&bytes[0], bytes.count) } else { "" }
}

/**
 * Tell whether a key is one a grant may be kept under, so it can't name a path outside the program's folder.
 *
 * @param key The key's bytes, as the program sent them; any length, read only.
 * @return True for 1 to KEY_BYTES ASCII letters, digits, - and _.
 */
valid_key :: fn(key : u8[]) -> bool {
    if key.count == 0 || key.count > powerbox.KEY_BYTES {
        return false
    }
    for byte in key {
        if !((byte >= cast[u8]('a') && byte <= cast[u8]('z'))
            || (byte >= cast[u8]('A') && byte <= cast[u8]('Z'))
            || (byte >= cast[u8]('0') && byte <= cast[u8]('9'))
            || byte == cast[u8]('-')
            || byte == cast[u8]('_')) {
            return false
        }
    }
    return true
}

/**
 * Answer the waiting request for an account with the account made, unless the program that asked has gone; either
 * way, it's no longer waiting.
 *
 * @param box The powerbox, whose waiting request is answered on its client's end and is no longer waiting.
 * @param name The account's name, as the trusted path gave it, copied into the answer.
 */
answer_made :: fn(box : ptr[mut Box], name : u8[]) {
    box.has_waiting = false
    index :: box.waiting.client
    if index >= box.clients.ends.count || cast[slop_os.Handle](box.clients.ends[index]) == slop_os.NO_HANDLE {
        return void
    }
    out := os.Outgoing.{}
    response :: os.begin[powerbox.Response](&out)
    response^ = .AccountMade(os.append(&out, name))
    _ = powerbox.send_response(box.clients.ends[index], box.port, &out)
}

/**
 * Answer the waiting request, a list of the user's keys, with them, unless the program that asked has gone.
 *
 * @param box The powerbox, whose waiting request is answered and no longer waiting.
 * @param keys The keys, a line each.
 */
answer_listed :: fn(box : ptr[mut Box], keys : u8[]) {
    box.has_waiting = false
    index :: box.waiting.client
    if index >= box.clients.ends.count || cast[slop_os.Handle](box.clients.ends[index]) == slop_os.NO_HANDLE {
        return void
    }
    out := os.Outgoing.{}
    response :: os.begin[powerbox.Response](&out)
    response^ = .KeysListed(os.append(&out, keys))
    _ = powerbox.send_response(box.clients.ends[index], box.port, &out)
}

/**
 * Answer the waiting request, unless the program that asked has gone; either way, it's no longer waiting.
 *
 * @param box The powerbox, whose waiting request is answered on its client's end and is no longer waiting.
 * @param given The answer; a grant's end moves to the program, and is lost if the program's gone.
 */
answer :: fn(box : ptr[mut Box], given : powerbox.Response) {
    box.has_waiting = false
    index :: box.waiting.client
    if index >= box.clients.ends.count || cast[slop_os.Handle](box.clients.ends[index]) == slop_os.NO_HANDLE {
        return void
    }
    out := os.Outgoing.{}
    os.begin[powerbox.Response](&out)^ = given
    _ = powerbox.send_response(box.clients.ends[index], box.port, &out)
}

/**
 * Send one request on a dir connection, and wait for its answer.
 *
 * @param box The powerbox; only passed on to ask_dir_with, which doesn't use it.
 * @param end The dir connection the request is sent on; the caller's, not closed.
 * @param port A port bound to it.
 * @param request The request, without items.
 * @return The answer; Unsupported if it couldn't be sent or answered.
 */
ask_dir :: fn(box : ptr[mut Box], end : slop_os.Channel, port : slop_os.Port, request : dir.Request) -> dir.Response {
    out := os.Outgoing.{}
    os.begin[dir.Request](&out)^ = request
    return ask_dir_with(box, end, port, &out)
}

/**
 * Send one request on a dir connection, and wait for its answer.
 *
 * @param box The powerbox; not used.
 * @param end The dir connection the request is sent on, and the answer waited for on, with no deadline; the caller's,
 *     not closed.
 * @param port A port bound to it.
 * @param out The request, put together by the caller.
 * @return The answer, whose handles are the caller's; Unsupported if it couldn't be sent or answered.
 */
ask_dir_with :: fn(
    box : ptr[mut Box],
    end : slop_os.Channel,
    port : slop_os.Port,
    out : ptr[mut os.Outgoing]
) -> dir.Response {
    if dir.send_request(end, port, out) is_some {
        return .Unsupported
    }
    into := os.Incoming.{}
    loop {
        match dir.receive_response(end, port, &into, true) {
            case Received => return os.message_of[dir.Response](&into)^
            case Failed(error) => return .Unsupported
            case _ => return .Unsupported
        }
    }
}

/**
 * Make another connection to the directory a dir connection speaks for: one end of a new channel sent to its server
 * in Connect, which takes it without answering.
 *
 * @param end The dir connection Connect is sent on; the caller's, not closed.
 * @param port A port bound to it.
 * @return The new connection's end, the caller's to give or close; null if the channel couldn't be made or Connect
 *     sent.
 */
connection_to :: fn(end : slop_os.Channel, port : slop_os.Port) -> slop_os.Channel? {
    pair :: os.channel_for[dir.Dir](slop_os.startup_block().budget, 0) or_return null
    out := os.Outgoing.{}
    os.begin[dir.Request](&out)^ = .Connect(os.Channel[dir.Dir].{end = pair.a})
    if dir.send_request(end, port, &out) is_some {
        _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
        return null
    }
    return pair.b
}
