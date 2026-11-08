package shell

import runtime from "base"
import language from "../../shell_language"
import os from "std"
import slop_os from "std/os"
import lifecycle from "std/os/slop_os"
import recording from "../../recording"

/*
 * Record and replay (decisions/0183, 12c): record name arguments runs a program as a call would, recorded
 * (recording.record), one thread at a time, in base's deterministic mode, and keeps the recording; replay name
 * arguments runs it again from the recording, with its seeds (recording.replay), and says whether it went exactly as
 * recorded, or where it diverged. A recording isn't given the clock page, which isn't a system call's to record.
 */

/** The key a recorded or replayed program's stops come under, on a port of its own. */
RECORDING_STOP_KEY : u64 : 1
/** The key its end comes under. */
RECORDING_END_KEY : u64 : 2

/**
 * Record a program, for record: its call made as any other's, started recorded, and the recording kept for replay.
 *
 * @param shell The shell, which keeps the recording, replacing the one before.
 * @param tree The Call node of record, its first child the program's name, the rest its arguments.
 * @return Null once it's ended; an error if there's no program, or it couldn't be made or started.
 */
record_program :: fn(shell: ptr[mut Shell], tree #escaping : ptr[Node]) -> Result[Value, EvalError] {
    call :: prepare_recorded(shell, tree, "record")?
    defer end_call(call)
    port :: slop_os.port_create(slop_os.startup_block().budget) or_return error_at(tree.at, "there's no memory to record it")
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    match start_recorded(shell, call, port, null) {
        case Some(error) => return .Error(error)
        case None => {}
    }
    program :: program_of(call, port) or_return error_at(tree.at, "it started without its intercept")
    made :: recording.record(program, shapes_of(shell), call.launched.seeds)
    shell.recording = made
    if made.problem != "" {
        say(shell, message("% was recorded until %; % calls in % threads", call.tree.text, made.problem, made.calls, made.threads))
    }
    else {
        // Its last event is its end, with its code
        events :: made.events
        code :: if events.count > 0 { events[events.count - 1].value } else { cast[u64](0) }
        say(shell, message("% was recorded: % calls in % threads, ended with %", call.tree.text, made.calls, made.threads, code))
    }
    return .Ok(.Null)
}

/**
 * Replay the recording kept, for replay: the program's call made again, started with the recording's seeds, and led
 * through the recording.
 *
 * @param shell The shell, whose recording is replayed.
 * @param tree The Call node of replay, its first child the program's name, the rest its arguments: the recording's
 *     to replay it exactly; any others show where they make it diverge.
 * @return Null once it's replayed or diverged; an error if there's no recording, or the program couldn't be started.
 */
replay_program :: fn(shell: ptr[mut Shell], tree #escaping : ptr[Node]) -> Result[Value, EvalError] {
    kept :: shell.recording or_return error_at(tree.at, "there's no recording to replay: record name arguments makes one")
    call :: prepare_recorded(shell, tree, "replay")?
    defer end_call(call)
    port :: slop_os.port_create(slop_os.startup_block().budget) or_return error_at(tree.at, "there's no memory to replay it")
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    match start_recorded(shell, call, port, kept.seeds) {
        case Some(error) => return .Error(error)
        case None => {}
    }
    program :: program_of(call, port) or_return error_at(tree.at, "it started without its intercept")
    replayed :: recording.replay(program, shapes_of(shell), kept)
    if replayed.exact {
        say(shell, message("% was replayed exactly: % calls", call.tree.text, replayed.calls))
    }
    else {
        say(shell, message("% diverged after % calls: %", call.tree.text, replayed.calls, replayed.divergence))
    }
    return .Ok(.Null)
}

/**
 * Make the call record, replay or profile runs: its first child's program, the rest its arguments.
 *
 * @param shell The shell.
 * @param tree The Call node of record, replay or profile.
 * @param command Its name, for the error.
 * @return The call, prepared, the caller's to end.
 */
prepare_recorded :: fn(shell: ptr[mut Shell], tree #escaping : ptr[Node], command: string) -> Result[ptr[mut Call], EvalError] {
    if tree.children.count == 0 || tree.children[0].kind != .Word {
        return .Error(EvalError.{message = message("% needs a program and its arguments: % name arguments", command, command), at = tree.at})
    }
    named :: tree.children[0]
    inner := runtime.new(Node)
    inner^ = Node.{kind = .Call, at = named.at, text = named.text}
    for child, i in tree.children {
        if i > 0 {
            runtime.array_add(&inner.children, child)
        }
    }
    return prepare_call(shell, inner, false)
}

/**
 * Start a recorded or replayed program: as start_call would, but with its stops and end on port, its intercept a
 * recording's, in the deterministic mode, without the clock page, and with the seeds given, for a replay.
 *
 * @param shell The shell, whose process manager starts it.
 * @param call The call, prepared; started.
 * @param port The recorder's port.
 * @param seeds The recording's seeds, for a replay; null to have the manager draw them.
 * @return Null once it's started; why it didn't otherwise.
 */
start_recorded :: fn(shell: ptr[mut Shell], call: ptr[mut Call], port: slop_os.Port, seeds: u8[64]?) -> EvalError? {
    tree :: call.tree
    manager :: shell.manager or_return EvalError.{message = "the shell can't start programs: it has no process manager", at = tree.at}
    ends :: lifecycle.make(slop_os.startup_block().budget) or_return EvalError.{message = "there's no memory to start it", at = tree.at}
    options := os.LaunchOptions.{watch = os.LaunchWatch.{port = port, key = RECORDING_END_KEY}, lifecycle = ends.b,
        faults = os.LaunchFaults.{port = port, key = RECORDING_STOP_KEY, points = recording.RECORDING_POINTS}, deterministic = true,
        seeds = seeds}
    options.locale = copy_of_grant("locale")
    options.result = result_grant(call)
    budget :: if call.budget == 0 { PROGRAM_BUDGET } else { call.budget }
    match os.launch_named(manager, shell.manager_port, tree.text, call.executable, budget, call.grants, call.values, options) {
        case Ok(made) => {
            call.started = true
            call.launched = made
            call.lifecycle = ends.a
            return null
        }
        case Error(error) => {
            for handle in slop_os.Handle.[cast[slop_os.Handle](ends.a), cast[slop_os.Handle](ends.b)] {
                _ = slop_os.handle_close(handle)
            }
            close_copy(options.locale)
            close_copy(options.result)
            return EvalError.{message = message("% didn't start: %", tree.text, error), at = tree.at}
        }
    }
}

/**
 * Describe a started program for the recorder.
 *
 * @param call Its call, started with a recording's intercept.
 * @param port The port its stops and end come on.
 * @return The program; null if it has no intercept.
 */
program_of :: fn(call: ptr[Call], port: slop_os.Port) -> recording.Program? {
    faults :: call.launched.faults or_return null
    return recording.Program.{process = call.launched.process, intercept = faults.intercept, space = faults.space, port = port,
        end_key = RECORDING_END_KEY}
}

/**
 * Give every call's shape, worked out the first time and kept.
 *
 * @param shell The shell, which keeps them.
 * @return The shapes.
 */
shapes_of :: fn(shell: ptr[mut Shell]) -> recording.CallShape[] {
    if shell.call_shapes.count == 0 {
        shell.call_shapes = recording.call_shapes()
    }
    return shell.call_shapes
}
