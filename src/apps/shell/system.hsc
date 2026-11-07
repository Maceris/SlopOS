package shell

import runtime from "base"
import language from "../../shell_language"
import os from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import programs from "../../protocols/programs"

/*
 * The system, as a session sees it (decisions/0179, 11e4): processes, the session's programs and the shell's jobs as a
 * tree; end, an installation of the session's ended; install, uninstall and installations, the user's own
 * installations beside the system's, through the session manager; and grants, the grants kept through the powerbox,
 * from the home's issued links, revoked with --revoke. Each asks only of the shell's own session, user and home.
 */

/** The most kept grants grants lists. */
MAX_GRANTS :: 64

/**
 * Send a request on the shell's programs connection, to the session manager, and wait for its answer.
 *
 * @param shell The shell, whose programs connection is asked.
 * @param out The request, built with os.begin[programs.Request].
 * @param into Where the answer goes.
 * @return Whether it came; false without the connection, or if it's gone.
 */
ask_session :: fn(shell: ptr[mut Shell], out: ptr[mut os.Outgoing], into: ptr[mut os.Incoming]) -> bool {
    connection :: shell.programs or_return false
    if programs.send_request(connection.end, shell.programs_port, out) is_some {
        return false
    }
    return match programs.receive_response(connection.end, shell.programs_port, into, true) {
        case Received => true
        case _ => false
    }
}

/**
 * List the session's processes as a tree: the session's programs, then the shell's jobs' programs beneath the shell.
 *
 * It fails for arguments, or when the session manager can't be asked.
 *
 * @param shell The shell, whose session is asked and whose jobs are looked at.
 * @param tree The Call node of processes.
 * @return A list of records: name, parent ("session", or "shell" for a job's program), state ("running", "not
 *     responding" for a program that didn't answer a ping in time, or for a job's, "ended"), memory and limit, sizes
 *     of its budget's use and limit, 0 where they couldn't be read.
 */
list_processes :: fn(shell: ptr[mut Shell], tree: ptr[Node]) -> Result[Value, EvalError] {
    if tree.children.count > 0 {
        return error_at(tree.at, "processes takes nothing")
    }
    out := os.Outgoing.{}
    os.begin[programs.Request](&out)^ = .Running
    into := os.Incoming.{}
    if !ask_session(shell, &out, &into) {
        return error_at(tree.at, "the session manager couldn't be asked")
    }
    made :: new_list()
    match os.message_of[programs.Response](&into)^ {
        case RunningPrograms(running) => {
            for each in os.items(&into, running) {
                name :: copied_first(each.name[0..<each.name.count], cast[usize](each.name_bytes))
                state :: if each.responding != 0 { "running" } else { "not responding" }
                runtime.array_add(&made.items, process_record(name, "session", state, each.memory, each.memory_limit))
            }
        }
        case _ => return error_at(tree.at, "the session manager couldn't be asked")
    }
    for job in shell.jobs {
        for call in job.running.calls {
            used := cast[u64](0)
            limit := cast[u64](0)
            match slop_os.memory_budget_info(call.launched.budget) {
                case Ok(info) => {
                    used = info.used
                    limit = info.limit
                }
                case Error(_) => {}
            }
            state :: if has_ended(shell, call) { "ended" } else { "running" }
            runtime.array_add(&made.items, process_record(message("% (job %)", call.tree.text, job.number), "shell", state, used, limit))
        }
    }
    return .Ok(.List(made))
}

/**
 * Make a process's record, as processes lists it.
 *
 * @param name Its name, kept.
 * @param parent What started it: "session" or "shell".
 * @param state How it is.
 * @param memory Its budget's bytes in use.
 * @param limit Its budget's limit.
 * @return The record.
 */
process_record :: fn(name #escaping : string, parent #escaping : string, state #escaping : string, memory: u64, limit: u64) -> Value {
    record :: new_record()
    set_field(record, "name", .Text(name))
    set_field(record, "parent", .Text(parent))
    set_field(record, "state", .Text(state))
    set_field(record, "memory", .Size(memory))
    set_field(record, "limit", .Size(limit))
    return .Record(record)
}

/**
 * End an installation running in the session: end name. It starts again when the session next does.
 *
 * It fails for no name, or more than one, or when there's no installation running by it.
 *
 * @param shell The shell, whose session is asked.
 * @param tree The Call node of end, its one argument the installation's name.
 * @return Null.
 */
end_installation :: fn(shell: ptr[mut Shell], tree #escaping : ptr[Node]) -> Result[Value, EvalError] {
    name :: one_name(shell, tree, "end takes an installation's name: end tally")?
    out := os.Outgoing.{}
    request :: os.begin[programs.Request](&out)
    request^ = .EndInstallation(os.append(&out, string_bytes(name)))
    return session_done(shell, tree, &out, name)
}

/**
 * Install a program for the session's user: install program, or install program --as name, the name its data and
 * settings are kept under, the program's own without --as. It starts at once in each of the user's sessions, and with
 * each of them after.
 *
 * It fails for a program that isn't there, or isn't one installations can run, or a name that's taken or isn't
 * letters, digits and _.
 *
 * @param shell The shell, whose session is asked.
 * @param tree The Call node of install.
 * @return Null.
 */
install_program :: fn(shell: ptr[mut Shell], tree #escaping : ptr[Node]) -> Result[Value, EvalError] {
    program := ""
    name := ""
    skip := false
    for child, i in tree.children {
        if skip {
            skip = false
            continue
        }
        if child.kind == .Named {
            after :: i + 1
            if child.text != "as" || after >= tree.children.count {
                return error_at(child.at, "install takes a program, and --as and a name")
            }
            name = word_of(shell, tree.children[after])?
            skip = true
            continue
        }
        if program.count > 0 {
            return error_at(child.at, "install takes one program")
        }
        program = word_of(shell, child)?
    }
    if program.count == 0 {
        return error_at(tree.at, "install takes a program: install counter --as tally")
    }
    if name.count == 0 {
        name = program
    }
    out := os.Outgoing.{}
    request :: os.begin[programs.Request](&out)
    request^ = .Install(programs.Installing.{name = os.append(&out, string_bytes(name)), program = os.append(&out, string_bytes(program))})
    return session_done(shell, tree, &out, name)
}

/**
 * Uninstall one of the user's installations: uninstall name. A snapshot of the home is taken first, so recover can
 * bring its data, apps/name, back; then it's stopped in each of the user's sessions, and its data and settings removed.
 *
 * It fails for no name, one the user hasn't installed, or the system's.
 *
 * @param shell The shell, whose session is asked.
 * @param tree The Call node of uninstall, its one argument the name.
 * @return Null.
 */
uninstall_installation :: fn(shell: ptr[mut Shell], tree #escaping : ptr[Node]) -> Result[Value, EvalError] {
    name :: one_name(shell, tree, "uninstall takes an installation's name: uninstall tally")?
    out := os.Outgoing.{}
    request :: os.begin[programs.Request](&out)
    request^ = .Uninstall(os.append(&out, string_bytes(name)))
    return session_done(shell, tree, &out, name)
}

/**
 * List the installations the session runs: the system's, then the user's own.
 *
 * It fails for arguments, or when the session manager can't be asked.
 *
 * @param shell The shell, whose session is asked, one at a time.
 * @param tree The Call node of installations.
 * @return A list of records: name, program, and whose, "system" or "yours".
 */
list_installations :: fn(shell: ptr[mut Shell], tree: ptr[Node]) -> Result[Value, EvalError] {
    if tree.children.count > 0 {
        return error_at(tree.at, "installations takes nothing")
    }
    made :: new_list()
    index := cast[u32](0)
    loop {
        out := os.Outgoing.{}
        os.begin[programs.Request](&out)^ = .Installation(index)
        into := os.Incoming.{}
        if !ask_session(shell, &out, &into) {
            return error_at(tree.at, "the session manager couldn't be asked")
        }
        match os.message_of[programs.Response](&into)^ {
            case Listed(listed) => {
                record :: new_record()
                set_field(record, "name", .Text(copied(os.items(&into, listed.name))))
                set_field(record, "program", .Text(copied(os.items(&into, listed.program))))
                set_field(record, "whose", .Text(if listed.users { "yours" } else { "system" }))
                runtime.array_add(&made.items, Value.Record(record))
                index = listed.next
            }
            case End => break
            case _ => return error_at(tree.at, "the session manager couldn't be asked")
        }
    }
    return .Ok(.List(made))
}

/**
 * List the grants the user has let programs keep through the powerbox, or revoke one: grants, or grants --revoke n.
 * They're the links the home has issued; a revoked one opens nothing from then on.
 *
 * It fails without a home, for other arguments, or for --revoke of a number no kept grant has.
 *
 * @param shell The shell, whose home is asked.
 * @param tree The Call node of grants.
 * @return A list of records: number, which --revoke takes, path, beneath the home, and writes, whether it may write
 *     what it reaches; Null after a revoke, or when there are none, which is said.
 */
kept_grants :: fn(shell: ptr[mut Shell], tree #escaping : ptr[Node]) -> Result[Value, EvalError] {
    home :: shell.home or_return error_at(tree.at, "the shell has no home, so no kept grants")
    children :: tree.children
    if children.count > 0 {
        if children.count != 2 {
            return error_at(tree.at, "grants takes nothing, or --revoke and a grant's number")
        }
        named :: children[0]
        given :: children[1]
        if named.kind != .Named || named.text != "revoke" {
            return error_at(tree.at, "grants takes nothing, or --revoke and a grant's number")
        }
        // A bare word is read as a number, as a program's integer parameter reads it
        number :: if given.kind == .Word {
            language.integer_of(given.text) or_return error_at(given.at, "--revoke takes a grant's number")
        }
        else {
            match evaluate(shell, given)? {
                case Int(read) => read
                case _ => return error_at(given.at, "--revoke takes a grant's number")
            }
        }
        if number < 0 {
            return error_at(given.at, "--revoke takes a grant's number")
        }
        out := os.Outgoing.{}
        os.begin[dir.Request](&out)^ = .Revoke(cast[u64](number))
        into := os.Incoming.{}
        if !ask_home(shell, &out, &into) {
            return error_at(tree.at, "the home couldn't be asked")
        }
        match os.message_of[dir.Response](&into)^ {
            case Done => {
                say(shell, message("grant % revoked", number))
                return .Ok(.Null)
            }
            case _ => return error_at(given.at, message("there's no kept grant %", number))
        }
    }
    made :: new_list()
    cursor := cast[u64](0)
    loop {
        if made.items.count >= MAX_GRANTS {
            break
        }
        out := os.Outgoing.{}
        os.begin[dir.Request](&out)^ = .Links(cursor)
        into := os.Incoming.{}
        if !ask_home(shell, &out, &into) {
            return error_at(tree.at, "the home couldn't be asked")
        }
        match os.message_of[dir.Response](&into)^ {
            case Issued(link) => {
                record :: new_record()
                set_field(record, "number", .Int(cast[i64](link.number)))
                set_field(record, "path", .Text(copied(os.items(&into, link.path))))
                set_field(record, "writes", .Bool(link.write))
                runtime.array_add(&made.items, Value.Record(record))
                cursor = link.next
            }
            case _ => break
        }
    }
    if made.items.count == 0 {
        say(shell, "no kept grants")
        return .Ok(.Null)
    }
    return .Ok(.List(made))
}

/**
 * Send a request on the shell's home connection and wait for its answer.
 *
 * @param shell The shell, whose home is asked.
 * @param out The request, built with os.begin[dir.Request].
 * @param into Where the answer goes.
 * @return Whether it came; false without a home, or if it's gone.
 */
ask_home :: fn(shell: ptr[mut Shell], out: ptr[mut os.Outgoing], into: ptr[mut os.Incoming]) -> bool {
    home :: shell.home or_return false
    if dir.send_request(home.end, shell.home_port, out) is_some {
        return false
    }
    return match dir.receive_response(home.end, shell.home_port, into, true) {
        case Received => true
        case _ => false
    }
}

/**
 * Ask the session manager to do something, and make its answer the built-in's: Done is Null; Refused, an error saying
 * why.
 *
 * @param shell The shell, whose session is asked.
 * @param tree The built-in's Call node, where an error points.
 * @param out The request.
 * @param name The installation's name, for the error.
 * @return Null once it's done.
 */
session_done :: fn(shell: ptr[mut Shell], tree: ptr[Node], out: ptr[mut os.Outgoing], name: string) -> Result[Value, EvalError] {
    into := os.Incoming.{}
    if !ask_session(shell, out, &into) {
        return error_at(tree.at, "the session manager couldn't be asked")
    }
    return match os.message_of[programs.Response](&into)^ {
        case Done => .Ok(.Null)
        case Refused(problem) => error_at(tree.at, message("%1: %2", name, install_problem(problem)))
        case _ => error_at(tree.at, "the session manager couldn't be asked")
    }
}

/**
 * Say why an installation couldn't be made, removed or ended.
 *
 * @param problem Why, as the session manager said.
 * @return A phrase, static text.
 */
install_problem :: fn(problem: programs.InstallProblem) -> string {
    return match problem {
        case .NoUser => "this session has no user, so no installations of its own"
        case .BadName => "an installation's name is 1 to 31 letters, digits and _"
        case .NoSuchProgram => "there's no program of that name"
        case .NotInstallable => "that program isn't one an installation can run: its entry takes other things"
        case .NameTaken => "an installation has that name already; give another with --as"
        case .Full => "there's no room for another installation"
        case .NotInstalled => "there's no installation of yours by that name running or installed"
        case .Systems => "that's the system's installation, which only the administrator can remove"
        case .Failed => "it couldn't be done: the settings or the home couldn't be written"
    }
}

/**
 * Read a built-in's one argument, a name.
 *
 * @param shell The shell, which evaluates an argument that isn't a bare word.
 * @param tree The built-in's Call node.
 * @param usage What's said when it hasn't exactly one argument.
 * @return The name.
 */
one_name :: fn(shell: ptr[mut Shell], tree #escaping : ptr[Node], usage: string) -> Result[string, EvalError] {
    children :: tree.children
    if children.count != 1 {
        return .Error(EvalError.{message = usage, at = tree.at})
    }
    only :: children[0]
    if only.kind == .Named {
        return .Error(EvalError.{message = usage, at = tree.at})
    }
    return word_of(shell, only)
}

/**
 * Read an argument as a word: a bare word as written, or what an expression gives, text or a path.
 *
 * @param shell The shell, which evaluates an expression.
 * @param argument The argument's node.
 * @return The word.
 */
word_of :: fn(shell: ptr[mut Shell], argument #escaping : ptr[Node]) -> Result[string, EvalError] {
    if argument.kind == .Word {
        return .Ok(argument.text)
    }
    got :: match evaluate(shell, argument) {
        case Ok(value) => value
        case Error(error) => return .Error(error)
    }
    return match got {
        case Text(text) => .Ok(text)
        case Path(text) => .Ok(text)
        case _ => .Error(EvalError.{message = message("a name is text, not %", type_name(got)), at = argument.at})
    }
}

/**
 * Copy bytes to the heap, as text.
 *
 * @param bytes UTF-8, as a message holds a name.
 * @return The copy, on the heap, never freed; "" for none.
 */
copied :: fn(bytes: u8[]) -> string {
    if bytes.count == 0 {
        return ""
    }
    kept : u8[..]
    for byte in bytes {
        runtime.array_add(&kept, byte)
    }
    if kept.count == 0 {
        return ""
    }
    return string_of(&kept[0], kept.count)
}

/**
 * Copy the first bytes of a fixed field to the heap, as text.
 *
 * @param bytes The field.
 * @param count How many of its bytes are the text; those past the field aren't taken.
 * @return The copy, on the heap, never freed; "" for none.
 */
copied_first :: fn(bytes: u8[], count: usize) -> string {
    kept : u8[..]
    for byte, i in bytes {
        if i < count {
            runtime.array_add(&kept, byte)
        }
    }
    if kept.count == 0 {
        return ""
    }
    return string_of(&kept[0], kept.count)
}
