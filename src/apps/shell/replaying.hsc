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
 *
 * record name arguments to path keeps the recording as a typed file too (recording.RecordingFile, decisions/0185,
 * 12g), with the program's name, arguments and hash; replay from path replays one, refusing another build of it.
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
    // to path, at its end, is where the recording's kept, not the program's
    path : string? = null
    dropped : usize = 0
    if tree.children.count >= 3 && tree.children[tree.children.count - 2].kind == .Word && tree.children[tree.children.count - 2].text == "to" {
        path = tree.children[tree.children.count - 1].text
        dropped = 2
    }
    call :: prepare_recorded(shell, tree, "record", dropped)?
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
    match path {
        case Some(where) => {
            match write_recording(shell, call, made, where) {
                case Some(problem) => return error_at(tree.at, message("the recording couldn't be kept in %: %", where, problem))
                case None => say(shell, message("kept in %", where))
            }
        }
        case None => {}
    }
    return .Ok(.Null)
}

/**
 * Keep a recording as a typed file.
 *
 * @param shell The shell, beneath whose home it's written.
 * @param call The recorded call: its program's name, arguments and file.
 * @param made The recording.
 * @param path Where, from the shell's directory, made or replaced.
 * @return Null once it's written; why not otherwise, a phrase.
 */
write_recording :: fn(shell: ptr[mut Shell], call: ptr[Call], made: ptr[recording.Recording], path #escaping : string) -> string? {
    arguments : u8[..]
    defer runtime.array_free(&arguments)
    for child in call.tree.children {
        for byte in string_bytes(child.text) {
            runtime.array_add(&arguments, byte)
        }
        runtime.array_add(&arguments, cast[u8](0x0a))
    }
    // Laid out as a message's value is, but on the heap, as a recording is bigger than a message: the struct, then its lists
    value : u8[..]
    defer runtime.array_free(&value)
    header :: (size_of(recording.RecordingFile) + 7) & ~cast[usize](7)
    for i in cast[usize](0)..<header {
        runtime.array_add(&value, cast[u8](0))
    }
    file := recording.RecordingFile.{program_hash = file_hash(call.executable), seeds = made.seeds, threads = made.threads, calls = made.calls}
    file.program = place_items(&value, string_bytes(call.tree.text))
    file.arguments = place_items(&value, arguments[0..<arguments.count])
    stored : recording.StoredEvent[..]
    defer runtime.array_free(&stored)
    for event in made.events {
        runtime.array_add(&stored, recording.stored_of(event))
    }
    file.events = place_items(&value, stored[0..<stored.count])
    file.bytes = place_items(&value, made.bytes[0..<made.bytes.count])
    if value.count < header || value.count == 0 {
        return "there wasn't the memory"
    }
    for byte, i in view_of(cast[ptr[u8]](&file), size_of(recording.RecordingFile)) {
        if i < value.count {
            value[i] = byte
        }
    }
    placed :: directory_of(shell, path) or_return "its directory couldn't be opened"
    defer os.close_directory(placed.directory)
    match os.write_typed_in[recording.RecordingFile](placed.directory, placed.name, value[0..<value.count]) {
        case Some(error) => return message("it couldn't be written: %", error)
        case None => {}
    }
    return null
}

/**
 * Add items to a value being laid out, aligned for them, as a message's appended data is.
 *
 * @tparam E The items' type: plain data.
 * @param value The value's bytes so far, grown.
 * @param items The items, copied.
 * @return Where they are, from the value's start, for a Relative field.
 */
place_items :: fn[E](value: ptr[mut u8[..]], items: E[]) -> slop_os.Relative[E] {
    alignment :: align_of(E)
    loop {
        if value.count % alignment == 0 {
            break
        }
        runtime.array_add(value, cast[u8](0))
    }
    start :: value.count
    bytes :: items.count * size_of(E)
    source :: cast[ptr[u8]](items.data)
    for i in cast[usize](0)..<bytes {
        runtime.array_add(value, cast[ptr[u8]](cast[u64](source) + cast[u64](i))^)
    }
    return slop_os.Relative[E].{offset = cast[u32](start), count = cast[u32](items.count)}
}

/** A path's directory, open, and its last name. */
Placed :: struct {
    /** The directory the path's in, the caller's to close. */
    directory : os.Directory,
    /** The path's last name, a view of it. */
    name : string,
}

/**
 * Open the directory a path's in, from the shell's directory, and give its last name.
 *
 * @param shell The shell, beneath whose home it's opened.
 * @param path The path.
 * @return The directory and the last name; null if it couldn't be opened, or the path ends in a /.
 */
directory_of :: fn(shell: ptr[mut Shell], path #escaping : string) -> Placed? {
    bytes :: string_bytes(path)
    split := bytes.count
    loop {
        if split == 0 || (split - 1 < bytes.count && bytes[split - 1] == 0x2f) {
            break
        }
        split -= 1
    }
    if split >= bytes.count {
        return null
    }
    name :: string_of(&bytes[split], bytes.count - split)
    place :: if split > 0 { message("%", string_of(&bytes[0], split)) } else { message(".") }
    handle :: match opened_beneath_home(shell, place, .Dir) {
        case Ok(opened) => opened
        case Error(problem) => return null
    }
    directory, error :: os.directory_on(cast[slop_os.Channel](handle))
    if error != null {
        _ = slop_os.handle_close(handle)
        return null
    }
    return Placed.{directory = directory, name = name}
}

/**
 * Hash a program's file, as a recording keeps it.
 *
 * @param executable The file.
 * @return Its BLAKE3-256 hash; all zeros if it couldn't be read.
 */
file_hash :: fn(executable: slop_os.Memory) -> u8[32] {
    none : u8[32]
    size :: slop_os.memory_size(executable) or_return none
    bytes, failed :: runtime.new_array(u8, cast[usize](size))
    if failed != null {
        return none
    }
    defer runtime.free_array(bytes)
    if slop_os.memory_read(executable, 0, bytes) is_error {
        return none
    }
    return runtime.hash_blake3(bytes)
}

/**
 * Replay a recording kept in a file, for replay from path: the program it names run with the arguments it keeps, if
 * it's the same build.
 *
 * @param shell The shell.
 * @param tree The Call node of replay, its children "from" and the path.
 * @return Null once it's replayed or diverged; an error if the file doesn't read as a recording, the program's another
 *     build, or it couldn't be started.
 */
replay_file :: fn(shell: ptr[mut Shell], tree #escaping : ptr[Node]) -> Result[Value, EvalError] {
    if tree.children.count < 2 {
        return error_at(tree.at, "replay from takes a recording's path")
    }
    path :: tree.children[1].text
    placed :: directory_of(shell, path) or_return error_at(tree.at, message("%'s directory couldn't be opened", path))
    defer os.close_directory(placed.directory)
    bytes :: match os.read_typed_in[recording.RecordingFile](placed.directory, placed.name) {
        case Ok(read) => read
        case Error(error) => return error_at(tree.at, message("% isn't a recording that reads: %", path, error))
    }
    file :: os.typed_value[recording.RecordingFile](bytes)
    // The recording, from the file's lists
    kept := runtime.new(recording.Recording)
    kept.seeds = file.seeds
    kept.threads = file.threads
    kept.calls = file.calls
    for each in os.items_of(bytes, file.events) {
        event :: recording.event_of(each) or_return error_at(tree.at, message("% has an event that isn't one", path))
        if event.bytes_at > cast[usize](file.bytes.count) || event.bytes_count > cast[usize](file.bytes.count) - event.bytes_at {
            return error_at(tree.at, message("% has an event past its bytes", path))
        }
        runtime.array_add(&kept.events, event)
    }
    for byte in os.items_of(bytes, file.bytes) {
        runtime.array_add(&kept.bytes, byte)
    }
    // The call it was of: its program and arguments, as words
    program :: os.items_of(bytes, file.program)
    if program.count == 0 {
        return error_at(tree.at, message("% names no program", path))
    }
    inner := runtime.new(Node)
    inner^ = Node.{kind = .Call, at = tree.at, text = message("%", string_of(&program[0], program.count))}
    words :: os.items_of(bytes, file.arguments)
    start : usize = 0
    for byte, i in words {
        if byte != 0x0a {
            continue
        }
        word := runtime.new(Node)
        word^ = Node.{kind = .Word, at = tree.at, text = if i > start && start < words.count { message("%", string_of(&words[start], i - start)) } else { "" }}
        runtime.array_add(&inner.children, word)
        start = i + 1
    }
    call :: prepare_call(shell, inner, false)?
    defer end_call(call)
    if file_hash(call.executable) != file.program_hash {
        return error_at(tree.at, message("% is a recording of another build of %", path, inner.text))
    }
    return replay_with(shell, tree, call, kept)
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
    if tree.children.count == 2 && tree.children[0].kind == .Word && tree.children[0].text == "from" {
        return replay_file(shell, tree)
    }
    kept :: shell.recording or_return error_at(tree.at, "there's no recording to replay: record name arguments makes one")
    call :: prepare_recorded(shell, tree, "replay")?
    defer end_call(call)
    return replay_with(shell, tree, call, kept)
}

/**
 * Replay a recording of a call, its program started with the recording's seeds.
 *
 * @param shell The shell.
 * @param tree The Call node of replay, for errors.
 * @param call The call, prepared, the caller's to end.
 * @param kept The recording.
 * @return Null once it's replayed or diverged; an error if the program couldn't be started.
 */
replay_with :: fn(shell: ptr[mut Shell], tree: ptr[Node], call: ptr[mut Call], kept: ptr[recording.Recording]) -> Result[Value, EvalError] {
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
 * @param dropped How many of its last children aren't the program's, like record's to path.
 * @return The call, prepared, the caller's to end.
 */
prepare_recorded :: fn(shell: ptr[mut Shell], tree #escaping : ptr[Node], command: string, dropped: usize = 0) -> Result[ptr[mut Call], EvalError] {
    if tree.children.count == 0 || tree.children[0].kind != .Word {
        return .Error(EvalError.{message = message("% needs a program and its arguments: % name arguments", command, command), at = tree.at})
    }
    named :: tree.children[0]
    inner := runtime.new(Node)
    inner^ = Node.{kind = .Call, at = named.at, text = named.text}
    for child, i in tree.children {
        if i > 0 && i + dropped < tree.children.count {
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
