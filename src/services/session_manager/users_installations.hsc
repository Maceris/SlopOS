package session_manager

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import programs from "../../protocols/programs"
import config from "../../protocols/config"
import session from "../../protocols/session"
import system_records from "../../system_records"
import bundle from "../../bundle"

/*
 * What a session's shell asks of its own session (decisions/0179, 11e4): its programs running, an installation of it
 * ended, and its user's own installations. A user's list is the config store's value "installations" of their owner,
 * "user:" and their name, of the system list's type; it runs beside the system's in each of the user's sessions. An
 * installation's name is unique across both lists, as it names the data directory and the settings.
 */

/** The config store's value of a user's own installations, of their owner. */
USER_LIST :: "installations"

/** A connection to a user's list in the config store, and a port for it, both closed by close_user_list. */
UserList :: struct {
    /** The value's connection. */
    connection : config.Config[system_records.Installations],
    /** A port bound to it. */
    port : slop_os.Port,
}

/**
 * Open a session's user's list in the config store, declared, so it reads as empty before it's written.
 *
 * @param sessions The session manager, whose config store connection for users' values is asked, waiting for its answer.
 * @param number The session's number; one past MAX_SESSIONS, or without a user, has no list.
 * @return The list's connection, the caller's to close with close_user_list; null without the store, for a session
 *     without a user, or if it couldn't be opened or declared.
 */
open_user_list :: fn(sessions: ptr[mut Manager], number: u32) -> UserList? {
    if sessions.settings_end == NONE || cast[usize](number) >= sessions.sessions.count {
        return null
    }
    made :: &sessions.sessions[cast[usize](number)]
    if !made.in_use || made.user_bytes == 0 {
        return null
    }
    owner : u8[OWNER_BYTES]
    count :: owner_of(user_of(made), "", &owner)
    out := os.Outgoing.{}
    request :: os.begin[config.Request](&out)
    request^ = .ValueFor(config.ValueFor.{owner = os.append(&out, owner[0..<count]), name = os.append(&out, string_bytes(USER_LIST))})
    into := os.Incoming.{}
    connection :: match config.ask(sessions.settings_end, sessions.settings_port, &out, &into) {
        case Opened(opened) => config.Config[system_records.Installations].{end = opened.end}
        case _ => return null
    }
    port :: os.port_for(slop_os.startup_block().budget, connection.end) or_else cast[slop_os.Port](slop_os.NO_HANDLE)
    if cast[slop_os.Handle](port) == slop_os.NO_HANDLE {
        _ = slop_os.handle_close(cast[slop_os.Handle](connection.end))
        return null
    }
    list :: UserList.{connection = connection, port = port}
    if config.declare(connection, port) is_error {
        close_user_list(list)
        return null
    }
    return list
}

/**
 * Close a user's list's connection and its port.
 *
 * @param list What open_user_list gave; not used after.
 */
close_user_list :: fn(list: UserList) {
    _ = slop_os.handle_close(cast[slop_os.Handle](list.port))
    _ = slop_os.handle_close(cast[slop_os.Handle](list.connection.end))
}

/**
 * Read a session's user's own installations.
 *
 * @param sessions The session manager, whose config store is asked, waiting for its answer.
 * @param number The session's number.
 * @return The list; empty for a session without a user, without the store, before it's written, or if it can't be read
 *     or isn't valid.
 */
read_user_installations :: fn(sessions: ptr[mut Manager], number: u32) -> system_records.Installations {
    list :: open_user_list(sessions, number) or_return system_records.Installations.{}
    defer close_user_list(list)
    value := os.Outgoing.{}
    if config.read(list.connection, list.port, &value) is_error {
        return system_records.Installations.{}
    }
    stored :: os.typed_value[system_records.Installations](os.value_bytes(&value))^
    if stored.set == 0 || (system_records.installations_check(&stored) is_some) {
        return system_records.Installations.{}
    }
    return stored
}

/**
 * Write a session's user's own installations, marked written.
 *
 * @param sessions The session manager, whose config store is asked, waiting for its answer.
 * @param number The session's number, whose user's list it is.
 * @param given The list; its set is made 1.
 * @return Whether the store kept it; false for a session without a user, without the store, or for a list that isn't
 *     valid.
 */
write_user_installations :: fn(sessions: ptr[mut Manager], number: u32, given: system_records.Installations) -> bool {
    written := given
    written.set = 1
    if system_records.installations_check(&written) is_some {
        return false
    }
    list :: open_user_list(sessions, number) or_return false
    defer close_user_list(list)
    value := os.Outgoing.{}
    os.begin[system_records.Installations](&value)^ = written
    fields :: config.field_bit[system_records.Installations]("count") | config.field_bit[system_records.Installations]("set")
        | config.field_bit[system_records.Installations]("entries")
    return config.write(list.connection, list.port, os.value_bytes(&value), fields) is_ok
}

/**
 * Start a session's user's own installations, each as start_installation does; one that can't start is logged and
 * skipped.
 *
 * @param sessions The session manager.
 * @param number The session's number; one without a user has none.
 */
start_user_installations :: fn(sessions: ptr[mut Manager], number: u32) {
    list :: read_user_installations(sessions, number)
    for i in cast[usize](0)..<list.entries.count {
        if i < cast[usize](list.count) {
            _ = start_installation(sessions, number, list.entries[i])
        }
    }
}

/**
 * Answer what a session's shell asks of its own session: Running, EndInstallation, Install, Uninstall or Installation.
 *
 * @param sessions The session manager.
 * @param number The session's number, whose shell asked.
 * @param request The request, one of those; any other is answered Unsupported.
 * @param into The request's message, whose items its names are.
 * @param out The answer's message, which items are appended to.
 * @return The answer.
 */
own_session_answer :: fn(sessions: ptr[mut Manager], number: u32, request: programs.Request, into: ptr[os.Incoming], out: ptr[mut os.Outgoing]) -> programs.Response {
    return match request {
        case Running => running_programs(sessions, number, out)
        case EndInstallation(name) => end_installation(sessions, number, text_from(os.items(into, name)))
        case Install(installing) => install(sessions, number, text_from(os.items(into, installing.name)), text_from(os.items(into, installing.program)), out)
        case Uninstall(name) => uninstall_users(sessions, number, text_from(os.items(into, name)))
        case Installation(index) => installation_at(sessions, number, index, out)
        case Powerbox(name) => powerbox_answer(sessions, number, text_from(os.items(into, name)))
        case _ => programs.Response.Unsupported
    }
}

/**
 * List a session's programs running, each pinged as list does.
 *
 * @param sessions The session manager.
 * @param number The session's number.
 * @param out The answer's message, the programs appended to it.
 * @return RunningPrograms.
 */
running_programs :: fn(sessions: ptr[mut Manager], number: u32, out: ptr[mut os.Outgoing]) -> programs.Response {
    listed : session.Program[session.MAX_PROGRAMS]
    count :: list(sessions, number, &listed)
    running : programs.RunningProgram[programs.MAX_RUNNING]
    made := cast[usize](0)
    for each, i in listed {
        if i >= count || made >= running.count {
            break
        }
        index :: cast[usize](each.index)
        installed :: index < sessions.programs.count && sessions.programs[index].installation
        running[made] = programs.RunningProgram.{name = each.name, name_bytes = each.name_bytes, responding = each.responding,
            installation = if installed { cast[u8](1) } else { cast[u8](0) }, memory = each.memory, memory_limit = each.memory_limit}
        made += 1
    }
    if made > running.count {
        return .RunningPrograms(os.append(out, running[0..<0]))
    }
    return .RunningPrograms(os.append(out, running[0..<made]))
}

/**
 * End an installation running in a session, by its name, as end_program does.
 *
 * @param sessions The session manager.
 * @param number The session's number; only its programs are looked at.
 * @param name The installation's name.
 * @return Done once it's ended; Refused(NotInstalled) if no installation of the session's is running by that name.
 */
end_installation :: fn(sessions: ptr[mut Manager], number: u32, name: string) -> programs.Response {
    for i in 0..<sessions.count {
        if i < sessions.programs.count && sessions.programs[i].running && sessions.programs[i].installation
            && sessions.programs[i].session == number && name_of(&sessions.programs[i]) == name {
            _ = end_program(sessions, i, "as its session's shell asked")
            return .Done
        }
    }
    return .Refused(.NotInstalled)
}

/**
 * Install a program for a session's user: added to their list, and started in each of their sessions.
 *
 * @param sessions The session manager.
 * @param number The session's number, whose user it's for.
 * @param name The installation's name: 1 to MAX_INSTALLATION_NAME letters, digits and _, and no installation's yet.
 * @param program The program's name in the boot root, whose entry may take only what an installation is given, and
 *     what it can go without (entries.hsc).
 * @param out The answer's message, a parameter's name appended to it for NeedsParameter.
 * @return Done once it's listed, started where it can be; NeedsParameter with a parameter it can't go without that an
 *     installation isn't given; Refused with why otherwise.
 */
install :: fn(sessions: ptr[mut Manager], number: u32, name: string, program: string, out: ptr[mut os.Outgoing]) -> programs.Response {
    if cast[usize](number) >= sessions.sessions.count || sessions.sessions[cast[usize](number)].user_bytes == 0 {
        return .Refused(.NoUser)
    }
    entry := system_records.InstallationRecord.{}
    if !record_of(name, &entry.name) {
        return .Refused(.BadName)
    }
    if !record_of(program, &entry.program) {
        return .Refused(.NoSuchProgram)
    }
    users := read_user_installations(sessions, number)
    if has_installation(read_installations(sessions), name) || has_installation(users, name) {
        return .Refused(.NameTaken)
    }
    at :: cast[usize](users.count)
    if at >= users.entries.count {
        return .Refused(.Full)
    }
    found :: bundle_named(sessions, program) or_return .Refused(.NoSuchProgram)
    match entry_plan(sessions, found) {
        case Ok(plan) => _ = slop_os.handle_close(cast[slop_os.Handle](plan.program))
        case Error(problem) => match problem {
            case Needs(parameter) => return .NeedsParameter(os.append(out, string_bytes(parameter)))
            case Unreadable => return .Refused(.NotInstallable)
        }
    }
    users.entries[at] = entry
    users.count += 1
    if !write_user_installations(sessions, number, users) {
        return .Refused(.Failed)
    }
    runtime.log_info("installed % (%) for %", name, program, text_from(user_of(&sessions.sessions[cast[usize](number)])))
    for other in user_sessions(sessions, number) {
        _ = start_installation(sessions, other, entry)
    }
    return .Done
}

/**
 * Uninstall one of a session's user's installations: a snapshot of their home taken, so its data can be recovered;
 * then it's stopped in each of their sessions, taken off their list, its data directory deleted and its settings
 * forgotten.
 *
 * @param sessions The session manager.
 * @param number The session's number, whose user's list it's taken from, and whose apps directory its data is in.
 * @param name The installation's name.
 * @return Done once it's gone; Refused(NotInstalled) if the user has none by that name, Systems if it's the system's,
 *     NoUser for a session without a user, Failed if the snapshot or the list couldn't be written, when nothing's
 *     changed.
 */
uninstall_users :: fn(sessions: ptr[mut Manager], number: u32, name: string) -> programs.Response {
    if cast[usize](number) >= sessions.sessions.count || sessions.sessions[cast[usize](number)].user_bytes == 0 {
        return .Refused(.NoUser)
    }
    users :: read_user_installations(sessions, number)
    if !has_installation(users, name) {
        return .Refused(if has_installation(read_installations(sessions), name) { programs.InstallProblem.Systems } else { programs.InstallProblem.NotInstalled })
    }
    if !snapshot_home(sessions, number) {
        return .Refused(.Failed)
    }
    kept := system_records.Installations.{}
    for i in cast[usize](0)..<users.entries.count {
        if i < cast[usize](users.count) && system_records.text_of(&users.entries[i].name) != name {
            at :: cast[usize](kept.count)
            if at < kept.entries.count {
                kept.entries[at] = users.entries[i]
                kept.count += 1
            }
        }
    }
    if !write_user_installations(sessions, number, kept) {
        return .Refused(.Failed)
    }
    for other in user_sessions(sessions, number) {
        stop_installation(sessions, other, name)
    }
    if !remove_installation_data(sessions, number, name) {
        runtime.log_info("uninstalled %, but not all of its data or settings could be removed", name)
    }
    runtime.log_info("uninstalled % for %", name, text_from(user_of(&sessions.sessions[cast[usize](number)])))
    return .Done
}

/**
 * Give the installation a session runs at an index: the system's first, then its user's.
 *
 * @param sessions The session manager.
 * @param number The session's number.
 * @param index The index, from 0.
 * @param out The answer's message, its names appended to it.
 * @return Listed; End past the last.
 */
installation_at :: fn(sessions: ptr[mut Manager], number: u32, index: u32, out: ptr[mut os.Outgoing]) -> programs.Response {
    systems :: read_installations(sessions)
    users :: read_user_installations(sessions, number)
    at := cast[usize](index)
    for list, i in system_records.Installations.[systems, users] {
        if at < cast[usize](list.count) && at < list.entries.count {
            entry :: &list.entries[at]
            return .Listed(programs.Installed.{name = os.append(out, string_bytes(system_records.text_of(&entry.name))),
                program = os.append(out, string_bytes(system_records.text_of(&entry.program))), users = i == 1, next = index + 1})
        }
        at -= if at < cast[usize](list.count) { at } else { cast[usize](list.count) }
    }
    return .End
}

/**
 * Take a snapshot of a session's home, through its apps directory's connection, and wait for it.
 *
 * @param sessions The session manager.
 * @param number The session's number.
 * @return Whether it was taken; false without an apps directory, or if its volume refused.
 */
snapshot_home :: fn(sessions: ptr[mut Manager], number: u32) -> bool {
    if cast[usize](number) >= sessions.sessions.count {
        return false
    }
    apps :: sessions.sessions[cast[usize](number)].apps
    if apps == NONE {
        return false
    }
    port :: os.port_for(slop_os.startup_block().budget, apps) or_return false
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    out := os.Outgoing.{}
    os.begin[dir.Request](&out)^ = .Snapshot
    if dir.send_request(apps, port, &out) is_some {
        return false
    }
    into := os.Incoming.{}
    match dir.receive_response(apps, port, &into, true) {
        case Received => {}
        case _ => return false
    }
    return match os.message_of[dir.Response](&into)^ {
        case Snapshotted(_) => true
        case _ => false
    }
}

/**
 * Find the sessions of a session's user, that session among them.
 *
 * @param sessions The session manager.
 * @param number The session's number, below MAX_SESSIONS.
 * @return Their numbers, on the heap, never freed; empty for a number past MAX_SESSIONS.
 */
user_sessions :: fn(sessions: ptr[mut Manager], number: u32) -> u32[] {
    found : u32[..]
    if cast[usize](number) >= sessions.sessions.count {
        return found[0..<0]
    }
    user :: user_of(&sessions.sessions[cast[usize](number)])
    for &other, i in sessions.sessions {
        if other.in_use && same_bytes(user_of(other), user) {
            runtime.array_add(&found, cast[u32](i))
        }
    }
    return found[0..<found.count]
}

/**
 * Tell whether a list has an installation of a name.
 *
 * @param list The list.
 * @param name The name.
 * @return True if one of its first count entries has it.
 */
has_installation :: fn(list: system_records.Installations, name: string) -> bool {
    for i in cast[usize](0)..<list.entries.count {
        if i < cast[usize](list.count) && system_records.text_of(&list.entries[i].name) == name {
            return true
        }
    }
    return false
}

/**
 * Put a name in a record's name field, if it's one the system's records take.
 *
 * @param name The name: 1 to MAX_INSTALLATION_NAME letters, digits and _.
 * @param into The field, filled with the name and zeros after it.
 * @return Whether it's such a name; into is left zeros, or part filled, if not.
 */
record_of :: fn(name: string, into: ptr[mut u8[system_records.NAME_BYTES]]) -> bool {
    bytes :: string_bytes(name)
    if bytes.count == 0 || bytes.count > programs.MAX_INSTALLATION_NAME {
        return false
    }
    for byte, i in bytes {
        if i < into.count {
            into^[i] = byte
        }
    }
    return system_records.valid_name(into, false)
}

/**
 * Tell whether two byte strings are the same.
 *
 * @param a One.
 * @param b The other.
 * @return True if they have the same bytes.
 */
same_bytes :: fn(a: u8[], b: u8[]) -> bool {
    if a.count != b.count {
        return false
    }
    for byte, i in a {
        if i < b.count && byte != b[i] {
            return false
        }
    }
    return true
}

/**
 * See a message's bytes as text.
 *
 * @param bytes UTF-8, a view of the message.
 * @return A view of them as a string, "" for none.
 */
text_from :: fn(bytes: u8[]) -> string {
    if bytes.count == 0 {
        return ""
    }
    return string_of(&bytes[0], bytes.count)
}

// ---- Finding connections (programs.Request.Connect)

/**
 * Take another connection to a session that only finds programs, bound to the session manager's port.
 *
 * @param sessions The session manager, whose finders take it.
 * @param number The session's number.
 * @param end The connection's end, which moves to the session manager; closed if there's no room, or it can't be bound.
 */
add_finder :: fn(sessions: ptr[mut Manager], number: u32, end: slop_os.Channel) {
    for &finder, i in sessions.finders {
        if finder.in_use {
            continue
        }
        signals :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
        if slop_os.port_bind(sessions.port, cast[slop_os.Handle](end), signals, FINDER_KEY + cast[u64](i), .Persistent) is_error {
            break
        }
        finder^ = Finder.{in_use = true, session = number, end = end}
        return void
    }
    _ = slop_os.handle_close(cast[slop_os.Handle](end))
}

/**
 * Let a finding connection go: unbound and closed.
 *
 * @param sessions The session manager.
 * @param index Its index among the finders; one not in use is left as it is.
 */
drop_finder :: fn(sessions: ptr[mut Manager], index: usize) {
    if index >= sessions.finders.count || !sessions.finders[index].in_use {
        return void
    }
    _ = slop_os.port_unbind(sessions.port, FINDER_KEY + cast[u64](index))
    _ = slop_os.handle_close(cast[slop_os.Handle](sessions.finders[index].end))
    sessions.finders[index] = Finder.{}
}

/**
 * Answer what each finding connection has asked, until it's asked nothing more: Find, List and Describe as a shell's
 * programs connection answers them, Connect with another finder, and Unsupported to the rest. One that's gone is let go.
 *
 * @param sessions The session manager.
 * @param into Where each request is received, reused.
 */
serve_finders :: fn(sessions: ptr[mut Manager], into: ptr[mut os.Incoming]) {
    for i in 0..<sessions.finders.count {
        loop {
            if i >= sessions.finders.count || !sessions.finders[i].in_use {
                break
            }
            end :: sessions.finders[i].end
            match programs.receive_request(end, sessions.port, into, false) {
                case Received => {}
                case Empty => break
                case Unsupported => {
                    _ = programs.answer_unsupported(end, sessions.port)
                    continue
                }
                case _ => {
                    drop_finder(sessions, i)
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
                    add_finder(sessions, sessions.finders[i].session, connection.end)
                    continue
                }
                case Powerbox(name) => response^ = powerbox_answer(sessions, sessions.finders[i].session, text_from(os.items(into, name)))
                case _ => response^ = .Unsupported
            }
            _ = programs.send_response(end, sessions.port, &out)
        }
    }
}

// ---- Installations stopped under memory pressure (decisions/0181, F3)

/**
 * Remember an installation stopped under memory pressure, to start it again when its session's next shown.
 *
 * @param sessions The session manager.
 * @param number Its session's number.
 * @param name Its name, as its program's.
 * @param name_bytes How many of name's bytes are its.
 */
remember_pressed :: fn(sessions: ptr[mut Manager], number: u32, name: u8[session.NAME_BYTES], name_bytes: u8) {
    for &pressed in sessions.pressed {
        if !pressed.in_use {
            pressed^ = Pressed.{in_use = true, session = number, name = name, name_bytes = name_bytes}
            return void
        }
    }
    runtime.log_info("memory pressure: no room to remember an installation stopped, to start it again")
}

/**
 * Start again a session's installations stopped under memory pressure, now that it's shown, each by its record in the
 * system's list or its user's.
 *
 * @param sessions The session manager.
 * @param number The session shown; NO_SESSION starts none.
 */
restart_pressed :: fn(sessions: ptr[mut Manager], number: u32) {
    for &pressed in sessions.pressed {
        if !pressed.in_use || pressed.session != number {
            continue
        }
        pressed.in_use = false
        name :: text_from(first_bytes(pressed.name[0..<pressed.name.count], cast[usize](pressed.name_bytes)))
        for list in system_records.Installations.[read_installations(sessions), read_user_installations(sessions, number)] {
            for i in cast[usize](0)..<list.entries.count {
                if i < cast[usize](list.count) && system_records.text_of(&list.entries[i].name) == name {
                    runtime.log_info("starting % again in session %, stopped under memory pressure", name, number)
                    _ = start_installation(sessions, number, list.entries[i])
                }
            }
        }
    }
}

/**
 * See the first bytes of a fixed field.
 *
 * @param bytes The field.
 * @param count How many of its bytes are used; past its end, all of them.
 * @return A view of them.
 */
first_bytes :: fn(bytes: u8[], count: usize) -> u8[] {
    if count > bytes.count {
        return bytes
    }
    return bytes[0..<count]
}

/**
 * Give a program the shell starts a connection to its session's powerbox, under its name (decisions/0181, F4).
 *
 * @param sessions The session manager, which asks the session's powerbox to serve another connection.
 * @param number The session's number.
 * @param name The program's name, as the powerbox shows it.
 * @return PowerboxGiven with the connection's end, the shell's; Refused(Failed) for a session without a powerbox, or
 *     if it couldn't be made.
 */
powerbox_answer :: fn(sessions: ptr[mut Manager], number: u32, name: string) -> programs.Response {
    return match powerbox_for(sessions, number, name) {
        case Some(made) => programs.Response.PowerboxGiven(made)
        case None => programs.Response.Refused(.Failed)
    }
}
