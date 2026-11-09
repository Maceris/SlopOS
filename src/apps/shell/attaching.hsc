package shell

import runtime from "base"
import language from "../../shell_language"
import os from "std"
import terminal from "std"
import slop_os from "std/os"
import powerbox from "../../protocols/powerbox"

/*
 * Attaching the debugger to a program the shell didn't start (decisions/0185, 12f): debug attach name asks the
 * session's powerbox, which asks the user on the trusted path, each time, or for another user's program the
 * administrator; once it's allowed, the session manager attaches an intercept of the program's faults on the shell's
 * port in place of its own, and gives the shell the program's process, address space and image. Its threads are
 * suspended, and the debugger's commands work as they do on a program it started; quit lets it go, running on.
 */

/**
 * Debug a program the session runs that the shell didn't start, for debug attach.
 *
 * @param shell The shell, whose session's powerbox is asked.
 * @param tree The Call node of debug, its first child "attach", its second the program's name as the session runs it.
 * @return Null once the debugger's let it go or it's ended; an error without a powerbox, if it's refused, or if
 *     there's no such program.
 */
attach_debugged :: fn(shell: ptr[mut Shell], tree #escaping : ptr[Node]) -> Result[Value, EvalError] {
    if tree.children.count != 2 || tree.children[1].kind != .Word {
        return error_at(tree.at, "debug attach takes the name of a program the session runs: debug attach name")
    }
    name :: tree.children[1].text
    end :: powerbox_connection(shell, "shell") or_return error_at(tree.at, "debug attach needs the session's powerbox, which this session hasn't")
    defer slop_os.handle_close(cast[slop_os.Handle](end))
    reply :: os.port_for(slop_os.startup_block().budget, end) or_return error_at(tree.at, "the powerbox can't be reached")
    defer slop_os.handle_close(cast[slop_os.Handle](reply))
    port :: slop_os.port_create(slop_os.startup_block().budget) or_return error_at(tree.at, "there's no memory to debug it")
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    // A copy of the port goes to the powerbox, then the session manager, which attaches the intercept on it
    given :: slop_os.handle_duplicate(cast[slop_os.Handle](port), cast[slop_os.Rights](cast[u32](slop_os.RIGHT_PORT_BIND)
        | cast[u32](slop_os.RIGHT_TRANSFER))) or_return error_at(tree.at, "the port can't be given")
    out := os.Outgoing.{}
    request :: os.begin[powerbox.Request](&out)
    request^ = .RequestDebug(powerbox.DebugRequest.{name = os.append(&out, string_bytes(name)),
        purpose = os.append(&out, string_bytes("as you asked in the shell")), port = cast[slop_os.Port](given), key = DEBUG_STOP_KEY})
    if powerbox.send_request(end, reply, &out) != null {
        return error_at(tree.at, "the powerbox can't be reached")
    }
    say(shell, message("Press Ctrl+Alt+Delete to allow the shell to debug %.", name))
    into := os.Incoming.{}
    loop {
        match powerbox.receive_response(end, reply, &into, true) {
            case Received => break
            case _ => return error_at(tree.at, "the powerbox can't be reached")
        }
    }
    attached := powerbox.Attached.{}
    match os.message_of[powerbox.Response](&into)^ {
        case Attached(given_back) => attached = given_back
        case Busy => return error_at(tree.at, "the powerbox is asking the user something else; try again once that's answered")
        case _ => return error_at(tree.at, message("debugging % was refused, or it isn't running", name))
    }
    program_bytes :: os.items(&into, attached.program)
    program :: if program_bytes.count > 0 { message("%", string_of(&program_bytes[0], program_bytes.count)) } else { name }
    // The call it's debugged through: its program's file for the symbols program, and what it was given
    named := runtime.new(Node)
    named^ = Node.{kind = .Call, at = tree.at, text = program}
    call := runtime.new(Call)
    call^ = Call.{tree = named, executable = cast[slop_os.Memory](slop_os.NO_HANDLE), started = true,
        lifecycle = cast[slop_os.Channel](slop_os.NO_HANDLE)}
    call.launched = os.Launched.{process = attached.process, budget = cast[slop_os.MemoryBudget](slop_os.NO_HANDLE), image = attached.image,
        faults = os.LaunchedFaults.{intercept = attached.intercept, space = attached.space}}
    match find_program(shell, program) {
        case Some(found) => {
            call.executable = found.executable
            _ = slop_os.handle_close(cast[slop_os.Handle](found.manifest))
        }
        case None => {}
    }
    defer end_call(call)
    // Its end, on the port too
    _ = slop_os.port_bind(port, cast[slop_os.Handle](attached.process), slop_os.SIGNAL_TERMINATED, DEBUG_END_KEY, .Once)
    faults :: call.launched.faults or_return error_at(tree.at, "it was attached without its intercept")
    session := Debugging.{shell = shell, call = call, port = port, faults = faults, going = true, attached = true}
    file := DebugFile.{}
    has_file := false
    match find_debug_file(shell, program) {
        case Some(found) => {
            file = found
            has_file = true
        }
        case None => {}
    }
    defer {
        if has_file {
            free_debug_file(&file)
        }
    }
    if has_file {
        session.file = &file
    }
    suspended :: suspend_all(&session)
    say(shell, message("attached to %, its % threads suspended; break, watch, step, continue, where, registers, threads, fibers, print, quit",
        name, suspended))
    editor := terminal.LineEditor.{}
    loop {
        if session.ended {
            say(shell, if session.let_go { message("let % go", name) } else { message("% ended", name) })
            return .Ok(.Null)
        }
        match terminal.read_line(&editor, &shell.console, "(debug) ") {
            case Line(line) => {
                run_debug_line(&session, line)
                runtime.free_array(bit_cast[u8[]](line))
            }
            case Interrupted => {}
            case Other(packet) => take_while_reading(shell, packet)
            case _ => {
                end_debugged(&session)
                return .Ok(.Null)
            }
        }
    }
}

/**
 * Suspend every thread of an attached program, the first of them the one the debugger looks at.
 *
 * @param session The session, whose thread becomes the first suspended and which is marked suspended.
 * @return How many were suspended.
 */
suspend_all :: fn(session: ptr[mut Debugging]) -> u32 {
    process :: session.call.launched.process
    ids : u64[64]
    count :: slop_os.process_threads(process, ids) or_else 0
    suspended : u32 = 0
    for id, i in ids {
        if cast[u32](i) >= count {
            break
        }
        if slop_os.thread_suspend(process, id) is_ok {
            if suspended == 0 {
                session.thread = id
                // Not a stop, but where and the rest read the thread from one
                session.stop = slop_os.StopInfo.{thread = id}
            }
            suspended += 1
        }
    }
    session.suspended = suspended > 0
    session.at_stop = false
    return suspended
}

/**
 * Resume every thread of an attached program that's suspended; those that aren't are left as they are.
 *
 * @param session The session, no longer marked suspended.
 */
resume_all :: fn(session: ptr[mut Debugging]) {
    process :: session.call.launched.process
    ids : u64[64]
    count :: slop_os.process_threads(process, ids) or_else 0
    for id, i in ids {
        if cast[u32](i) >= count {
            break
        }
        _ = slop_os.thread_resume(process, id)
    }
    session.suspended = false
}

/**
 * Let an attached program go, running on: its breakpoints and watchpoints cleared, its threads resumed, and the
 * intercept closed, so it runs unintercepted.
 *
 * @param session The session, ended after, as let go.
 */
let_go :: fn(session: ptr[mut Debugging]) {
    process :: session.call.launched.process
    none := slop_os.ThreadDebug.{}
    _ = slop_os.process_set_debug(process, &none)
    if session.thread != 0 {
        _ = slop_os.thread_set_debug(process, session.thread, &none)
        if session.at_stop {
            _ = slop_os.intercept_resume(session.faults.intercept, session.thread, .Continue)
        }
    }
    resume_all(session)
    session.ended = true
    session.let_go = true
}
