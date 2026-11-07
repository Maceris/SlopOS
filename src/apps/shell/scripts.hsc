package shell

import runtime from "base"
import language from "../../shell_language"
import os from "std"
import schema from "std"
import text_buffer from "std"
import unicode from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import file from "std/os/slop_os"
import read_only_file from "std/os/slop_os"
import process_manager from "std/os/slop_os"
import terminal as protocol from "std/os/slop_os"
import programs from "../../protocols/programs"

/*
 * Scripts (design/shell.md §7, decisions/0179, 11e6): a file whose name ends in .shell, run as a command, beneath the
 * shell's directory. Its first line may be param and its parameters, as a function's are written, which its call's
 * arguments are matched to; it runs in a shell of its own, a new process, given only what they say: a Dir, File or
 * ReadOnlyFile parameter is a grant, opened from the path it's given (a Dir named here, given none, is the shell's
 * directory, and becomes the script's: its paths are beneath it), and any other is a value. Besides, the script's shell
 * has the terminal, a process manager connection, and one to its session that only finds programs, so it can run
 * them, giving them only what it was given.
 */

/** The memory a script's shell is given to run on, and to run its programs on, in bytes: 10 MiB. */
SCRIPT_BUDGET : u64 : 10 * 1024 * 1024
/** The most bytes of a script read: 256 KiB. */
MAX_SCRIPT_BYTES : u64 : 256 * 1024
/** What a script's name ends with. */
SCRIPT_SUFFIX :: ".shell"
/** The shell's own parameters' names, and its runtime's grants', which a script's parameter can't be named. */
RESERVED :: string.["log", "session_terminal", "home", "manager", "programs", "data", "script", "arguments", "lifecycle",
    "result", "clock", "locale", "events"]

/**
 * Tell whether a command's name is a script's: a path ending in .shell.
 *
 * @param name The command's name.
 * @return True if it ends in SCRIPT_SUFFIX and has a name before it.
 */
is_script :: fn(name: string) -> bool {
    suffix :: SCRIPT_SUFFIX
    if name.count <= suffix.count {
        return false
    }
    return language.slice(name, name.count - suffix.count, name.count) == suffix
}

// ---- Calling a script

/**
 * Make a script's call ready to start: the shell's program, run on the script; its parameters, from its param line,
 * matched to the call's arguments; and the grants and values they're given.
 *
 * It fails, letting go of all it made, for a script that can't be read or parsed, arguments that don't match, a value
 * that isn't its parameter's type, a path that can't be opened, a parameter of a type a script can't take or with a
 * name of the shell's own, or in the background, as a script's shell needs the terminal.
 *
 * @param shell The shell, whose directory the script and its paths are beneath.
 * @param tree The Call node, its text the script's path, kept by the call.
 * @param background Whether it's to run in the background, which a script can't.
 * @return The call, on the heap, the caller's to start and then end with end_call.
 */
prepare_script_call :: fn(shell: ptr[mut Shell], tree #escaping : ptr[Node], background: bool) -> Result[ptr[mut Call], EvalError] {
    if background {
        return .Error(EvalError.{message = "a script needs the terminal, which a job in the background hasn't: run it without &", at = tree.at})
    }
    text :: read_script_text(shell, tree)?
    parameters :: script_parameters(text, tree.at)?
    found :: find_program(shell, "shell") or_return .Error(EvalError.{message = "there's no shell to run scripts with", at = tree.at})
    call := runtime.new(Call)
    call.tree = tree
    call.executable = found.executable
    call.budget = SCRIPT_BUDGET
    ready := false
    defer {
        if !ready {
            end_call(call)
        }
    }
    manifest :: read_manifest(found)
    _ = slop_os.handle_close(cast[slop_os.Handle](found.manifest))
    call.manifest = manifest or_return .Error(EvalError.{message = "the shell's manifest isn't one it can read", at = tree.at})
    budget :: slop_os.startup_block().budget
    // The shell's own grants: the terminal, which it can't run without, so the input's its while it runs
    runtime.array_add(&call.parameters, Parameter.{name = "session_terminal", giving = .Terminal})
    terminal_end :: protocol.connect(shell.console.end, shell.console.port, budget) or_return .Error(EvalError.{message = "there's no memory for its terminal connection", at = tree.at})
    runtime.array_add(&call.grants, os.NamedGrant.{label = "session_terminal", handle = cast[slop_os.Handle](terminal_end.end)})
    match shell.manager {
        case Some(given) => {
            made :: process_manager.connect(given.end, shell.manager_port, budget) or_return .Error(EvalError.{message = "there's no memory for its process manager connection", at = tree.at})
            runtime.array_add(&call.grants, os.NamedGrant.{label = "manager", handle = cast[slop_os.Handle](made.end)})
        }
        case None => {}
    }
    match finding_connection(shell) {
        case Some(made) => runtime.array_add(&call.grants, os.NamedGrant.{label = "programs", handle = cast[slop_os.Handle](made)})
        case None => {}
    }
    script :: match opened_beneath_home(shell, tree.text, .ReadOnlyFile) {
        case Ok(handle) => handle
        case Error(problem) => return .Error(EvalError.{message = message("%: %", tree.text, problem), at = tree.at})
    }
    runtime.array_add(&call.grants, os.NamedGrant.{label = "script", handle = script})
    // Its own parameters, as the call's arguments give them
    matched :: match_script_arguments(tree, parameters)?
    for parameter, i in parameters {
        given :: if i < matched.count { matched[i] } else { Matched.{} }
        give_parameter(shell, call, tree, parameter, given)?
    }
    for &value, i in call.values {
        if i < call.written.count {
            value.value = call.written[i]
        }
    }
    ready = true
    return .Ok(call)
}

/**
 * Give a script's parameter what its argument says: a grant for a Dir, File or ReadOnlyFile, opened from its path or
 * another connection to a handle it's given; a value written for any other, by its type.
 *
 * @param shell The shell, whose directory paths are beneath, and which evaluates an argument that isn't a bare word.
 * @param call The call, whose grants and values grow.
 * @param tree The Call node, where an error for a parameter not given points.
 * @param parameter The Parameter node, its type and default.
 * @param given Its argument, or that it's a bool given by its name alone, or nothing.
 * @return True once it's given; the error otherwise. A parameter given nothing, with a default or a bool, is left for
 *     the script's shell, which evaluates its default, and gives true too.
 */
give_parameter :: fn(shell: ptr[mut Shell], call: ptr[mut Call], tree: ptr[Node], parameter #escaping : ptr[Node], given #escaping : Matched) -> Result[bool, EvalError] {
    name :: parameter.text
    type :: type_of_parameter(parameter)
    for each in RESERVED {
        if each == name {
            return .Error(EvalError.{message = message("the script's parameter % has a name the shell's own grants have", name), at = tree.at})
        }
    }
    handle_kind :: handle_kind_of(type)
    match handle_kind {
        case Some(kind) => {
            label :: if name == "here" { "home" } else { name }
            giving :: giving_of_kind(kind)
            handle := slop_os.NO_HANDLE
            match given.node {
                case Some(node) => {
                    if node.kind == .Word {
                        handle = open_for(shell, node.text, giving, node.at)?
                    }
                    else {
                        got :: evaluate(shell, node)?
                        match got {
                            case Path(text) => handle = open_for(shell, text, giving, node.at)?
                            case Text(text) => handle = open_for(shell, text, giving, node.at)?
                            case Handle(held) => handle = another_connection(shell, held, giving, node.at)?
                            case _ => return .Error(EvalError.{message = message("--% takes %, not %", name, type_article(type), type_name(got)),
                                at = node.at})
                        }
                    }
                }
                case None => {
                    if name != "here" || kind != .Dir {
                        return .Error(EvalError.{message = message("% needs its % (a path)", tree.text, name), at = tree.at})
                    }
                    handle = open_for(shell, ".", .Dir, tree.at)?
                }
            }
            runtime.array_add(&call.grants, os.NamedGrant.{label = label, handle = handle})
            return .Ok(true)
        }
        case None => {}
    }
    if type == "list" || type == "record" {
        return .Error(EvalError.{message = message("a script's parameter can't be % yet: % is", type_article(type), name), at = parameter.at})
    }
    value := Value.Null
    match given.node {
        case Some(node) => {
            if node.kind == .Word {
                value = word_as(type, node.text) or_return .Error(EvalError.{message = message("--%: % isn't %", name, node.text,
                    type_article(type)), at = node.at})
            }
            else {
                value = evaluate(shell, node)?
            }
            if !of_type(type, value) {
                return .Error(EvalError.{message = message("--% takes %, not %", name, type_article(type), type_name(value)), at = node.at})
            }
        }
        case None => {
            if given.flag {
                value = .Bool(true)
            }
            else if (first_child(parameter) is_none) && type != "bool" {
                return .Error(EvalError.{message = message("% needs its %", tree.text, name), at = tree.at})
            }
            else {
                // Its default, the script's shell's to evaluate
                return .Ok(true)
            }
        }
    }
    bytes : u8[..]
    hash : u8[32]
    failed := false
    match value {
        case Int(number) => {
            failed = schema.try_write_value(number, &bytes) is_some
            hash = os.schema_hash_of[i64]()
        }
        case Duration(nanos) => {
            failed = schema.try_write_value(nanos, &bytes) is_some
            hash = os.schema_hash_of[i64]()
        }
        case Size(count) => {
            failed = schema.try_write_value(count, &bytes) is_some
            hash = os.schema_hash_of[u64]()
        }
        case Bool(truth) => {
            failed = schema.try_write_value(truth, &bytes) is_some
            hash = os.schema_hash_of[bool]()
        }
        case Text(text) => {
            failed = schema.try_write_value(text, &bytes) is_some
            hash = os.schema_hash_of[string]()
        }
        case Path(text) => {
            failed = schema.try_write_value(text, &bytes) is_some
            hash = os.schema_hash_of[string]()
        }
        case _ => return .Error(EvalError.{message = message("--% can't be given %", name, type_name(value)), at = tree.at})
    }
    if failed {
        return .Error(EvalError.{message = "there's no memory for its arguments", at = tree.at})
    }
    runtime.array_add(&call.written, bytes)
    runtime.array_add(&call.values, os.NamedValue.{name = name, hash = hash, value = bytes[0..<bytes.count]})
    return .Ok(true)
}

/**
 * Open a path for a script's parameter, as a program's is opened.
 *
 * @param shell The shell, whose directory it's beneath.
 * @param path The path, as written.
 * @param giving Dir, File or ReadOnlyFile.
 * @param at Where an error points.
 * @return The opened end's handle, the caller's.
 */
open_for :: fn(shell: ptr[mut Shell], path #escaping : string, giving: Giving, at: usize) -> Result[slop_os.Handle, EvalError] {
    return match opened_beneath_home(shell, path, giving) {
        case Ok(handle) => .Ok(handle)
        case Error(problem) => .Error(EvalError.{message = message("%: %", path, problem), at = at})
    }
}

/**
 * Make another connection to what a handle reaches, for a parameter of its kind.
 *
 * @param shell The shell.
 * @param handle The handle, a script's own, which stays its.
 * @param giving What the parameter takes: Dir or Here for a directory, File or ReadOnlyFile for a file.
 * @param at Where an error points.
 * @return The new connection's end, the caller's to give.
 */
another_connection :: fn(shell: ptr[mut Shell], handle: ptr[HandleValue], giving: Giving, at: usize) -> Result[slop_os.Handle, EvalError] {
    wanted :: if giving == .Here { HandleKind.Dir } else { handle_kind_of_giving(giving) or_else handle.kind }
    if wanted != handle.kind || giving == .Other || giving == .Value || giving == .Terminal {
        return .Error(EvalError.{message = message("% is %, which this doesn't take", handle.name, type_name(Value.Handle(cast[ptr[mut HandleValue]](handle)))),
            at = at})
    }
    budget :: slop_os.startup_block().budget
    port :: os.port_for(budget, handle.end) or_return .Error(EvalError.{message = "there's no memory to pass it on", at = at})
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    made := slop_os.NO_HANDLE
    match handle.kind {
        case .Dir => {
            connected :: dir.connect(handle.end, port, budget) or_return .Error(EvalError.{message = "there's no memory to pass it on", at = at})
            made = cast[slop_os.Handle](connected.end)
        }
        case .File => {
            pair :: os.channel_for[file.File](budget, 0) or_return .Error(EvalError.{message = "there's no memory to pass it on", at = at})
            out := os.Outgoing.{}
            os.begin[file.Request](&out)^ = .Connect(os.Channel[file.File].{end = pair.a})
            if file.send_request(handle.end, port, &out) is_some {
                _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
                return .Error(EvalError.{message = message("% couldn't be passed on", handle.name), at = at})
            }
            made = cast[slop_os.Handle](pair.b)
        }
        case .ReadOnlyFile => {
            pair :: os.channel_for[read_only_file.ReadOnlyFile](budget, 0) or_return .Error(EvalError.{message = "there's no memory to pass it on", at = at})
            out := os.Outgoing.{}
            os.begin[read_only_file.Request](&out)^ = .Connect(os.Channel[read_only_file.ReadOnlyFile].{end = pair.a})
            if read_only_file.send_request(handle.end, port, &out) is_some {
                _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
                return .Error(EvalError.{message = message("% couldn't be passed on", handle.name), at = at})
            }
            made = cast[slop_os.Handle](pair.b)
        }
    }
    return .Ok(made)
}

/**
 * Make a connection to the shell's session that only finds programs, for a script's shell.
 *
 * @param shell The shell, whose programs connection is asked to Connect another.
 * @return The new connection's end, the caller's; null without a programs connection, or if it couldn't be made.
 */
finding_connection :: fn(shell: ptr[mut Shell]) -> slop_os.Channel? {
    connection :: shell.programs or_return null
    pair :: os.channel_for[programs.Programs](slop_os.startup_block().budget, 0) or_return null
    out := os.Outgoing.{}
    os.begin[programs.Request](&out)^ = .Connect(os.Channel[programs.Programs].{end = pair.a})
    if programs.send_request(connection.end, shell.programs_port, &out) is_some {
        _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
        return null
    }
    return pair.b
}

/**
 * Read a script's text, beneath the shell's directory.
 *
 * @param shell The shell.
 * @param tree The Call node, its text the script's path.
 * @return Its text, on the heap, never freed; an error if it can't be opened or read, or is past MAX_SCRIPT_BYTES.
 */
read_script_text :: fn(shell: ptr[mut Shell], tree: ptr[Node]) -> Result[string, EvalError] {
    handle :: match opened_beneath_home(shell, tree.text, .ReadOnlyFile) {
        case Ok(made) => made
        case Error(problem) => {
            if problem == file_problem(.NotFound) {
                match meant_path(shell, tree.text) {
                    case Some(meant) => return .Error(EvalError.{message = message("%1: %2; did you mean %3?", tree.text, problem, meant), at = tree.at})
                    case None => {}
                }
            }
            return .Error(EvalError.{message = message("%: %", tree.text, problem), at = tree.at})
        }
    }
    return match text_of_file(cast[slop_os.Channel](handle)) {
        case Some(text) => .Ok(text)
        case None => .Error(EvalError.{message = message("%: it couldn't be read, or it's past 256 KiB", tree.text), at = tree.at})
    }
}

/**
 * Read a read-only file's whole text.
 *
 * @param end Its connection, speaking read_only_file, which is taken over and closed.
 * @return The text, on the heap, never freed; null if it couldn't be read, or is past MAX_SCRIPT_BYTES.
 */
text_of_file :: fn(end: slop_os.Channel) -> string? {
    opened, error :: os.file_on(end, false)
    if error is_some {
        return null
    }
    defer os.close(opened)
    bytes : u8[..]
    chunk : u8[4096]
    loop {
        count :: os.read(opened, chunk[0..<chunk.count]) or_return null
        if count == 0 {
            break
        }
        for byte, i in chunk {
            if i < count {
                runtime.array_add(&bytes, byte)
            }
        }
        if cast[u64](bytes.count) > MAX_SCRIPT_BYTES {
            return null
        }
    }
    if bytes.count == 0 {
        return ""
    }
    return string_of(&bytes[0], bytes.count)
}

/**
 * Find a script's parameters: its first statement's, if it's param.
 *
 * @param text The script's text, which the parse copies.
 * @param at Where an error points, in the caller's line.
 * @return The Parameter nodes, on the heap; empty for a script without param. An error if the script doesn't parse.
 */
script_parameters :: fn(text: string, at: usize) -> Result[ptr[Node][], EvalError] {
    tree :: match language.parse(text) {
        case Ok(made) => made
        case Error(error) => return .Error(EvalError.{message = message("the script doesn't parse, at line %: %", line_number(text, error.at), error.message), at = at})
    }
    found : ptr[Node][..]
    first :: first_child(tree) or_return .Ok(found[0..<0])
    if first.kind == language.NodeKind.Param {
        for each in first.children {
            if each.kind == .Parameter {
                runtime.array_add(&found, each)
            }
        }
    }
    return .Ok(found[0..<found.count])
}

/**
 * Find a script's parameters by its path, for help and completion: read and parsed, nothing said if it can't be.
 *
 * @param shell The shell, whose directory the path is beneath.
 * @param path The script's path.
 * @return Its Parameter nodes, on the heap; null if it can't be read or doesn't parse.
 */
script_parameters_at :: fn(shell: ptr[mut Shell], path #escaping : string) -> ptr[Node][]? {
    handle :: match opened_beneath_home(shell, path, .ReadOnlyFile) {
        case Ok(made) => made
        case Error(_) => return null
    }
    text :: text_of_file(cast[slop_os.Channel](handle)) or_return null
    return match script_parameters(text, 0) {
        case Ok(found) => found
        case Error(_) => null
    }
}

/**
 * Match a script's call's arguments to its parameters, as a function's are: by --name, or in order.
 *
 * @param tree The Call node.
 * @param parameters The script's parameters.
 * @return What each is given, in their order.
 */
match_script_arguments :: fn(tree: ptr[Node], parameters: ptr[Node][]) -> Result[Matched[], EvalError] {
    matched : Matched[..]
    for parameter in parameters {
        runtime.array_add(&matched, Matched.{})
    }
    at : usize = 0
    loop {
        argument :: child(tree, at) or_break
        at += 1
        index := parameters.count
        if argument.kind == .Named {
            for parameter, i in parameters {
                if same_option(parameter.text, argument.text) {
                    index = i
                }
            }
            if index >= parameters.count || index >= matched.count {
                return .Error(EvalError.{message = message("% takes no --%", tree.text, argument.text), at = argument.at})
            }
            next :: child(tree, at)
            if index >= matched.count || index >= parameters.count {
                return .Error(EvalError.{message = message("% takes no --%", tree.text, argument.text), at = argument.at})
            }
            if type_of_parameter(parameters[index]) == "bool" && !is_bool_word(next) {
                for &each, i in matched {
                    if i == index {
                        each.flag = true
                    }
                }
                continue
            }
            value :: next or_return .Error(EvalError.{message = message("--% needs a value after it", argument.text), at = argument.at})
            for &each, i in matched {
                if i == index {
                    each.node = value
                }
            }
            at += 1
            continue
        }
        for each, i in matched {
            if (each.node is_none) && !each.flag && i < parameters.count && !(parameters[i].text == "here" && is_handle_type(parameters[i])) {
                index = i
                break
            }
        }
        if index >= matched.count {
            return .Error(EvalError.{message = message("% takes no more arguments", tree.text), at = argument.at})
        }
        for &each, i in matched {
            if i == index {
                each.node = argument
            }
        }
    }
    return .Ok(matched[0..<matched.count])
}

// ---- Running a script, in its own shell

/**
 * Run a script, as a shell started with one does: its parameters bound to what it was given, then each statement in
 * turn, a value shown as the interactive shell shows it; the first error is shown with its line, and ends it.
 *
 * @param shell The shell, run for the script: its home is the script's here, if it has one.
 * @param script The script's file, which is read and closed.
 * @return 0 once it's run to its end; 1 for an error; 2 if it can't be read.
 */
run_script :: fn(shell: ptr[mut Shell], script: os.Channel[read_only_file.ReadOnlyFile]) -> int {
    text :: text_of_file(script.end) or_return 2
    tree :: match language.parse(text) {
        case Ok(made) => made
        case Error(error) => {
            script_error(shell, text, error.at, error.message)
            return 1
        }
    }
    for statement, i in tree.children {
        if i == 0 && statement.kind == language.NodeKind.Param {
            match bind_script_parameters(shell, statement) {
                case Some(error) => {
                    script_error(shell, text, error.at, error.message)
                    return 1
                }
                case None => {}
            }
            continue
        }
        match evaluate(shell, statement) {
            case Ok(value) => {
                match value {
                    case Null => {}
                    case _ => {
                        storage : u8[8192]
                        out := text_buffer.make(storage)
                        language.render(&out, value)
                        say(shell, text_buffer.as_string(&out))
                    }
                }
            }
            case Error(error) => {
                script_error(shell, text, error.at, if error.returning { "return is a function's, and this isn't in one" } else { error.message })
                return 1
            }
        }
    }
    return 0
}

/**
 * Bind a script's parameters to what it was given: here to another connection to its home, a Dir, File or
 * ReadOnlyFile to the grant of its name, and any other to the value of its name, or its default, or false for a bool.
 *
 * @param shell The shell running the script, whose scope the names are bound in.
 * @param param The Param node.
 * @return Null once they're bound; an error for one given nothing, without a default.
 */
bind_script_parameters :: fn(shell: ptr[mut Shell], param #escaping : ptr[Node]) -> EvalError? {
    block :: slop_os.startup_block()
    for parameter in param.children {
        name :: parameter.text
        type :: type_of_parameter(parameter)
        match handle_kind_of(type) {
            case Some(kind) => {
                end := cast[slop_os.Channel](slop_os.NO_HANDLE)
                if name == "here" {
                    home :: shell.home or_return EvalError.{message = "here wasn't given", at = parameter.at}
                    made :: dir.connect(home.end, shell.home_port, block.budget) or_return EvalError.{message = "there's no memory for here", at = parameter.at}
                    end = made.end
                }
                else {
                    found :: slop_os.find_grant(block, name, .Channel) or_return EvalError.{message = message("% wasn't given", name), at = parameter.at}
                    end = cast[slop_os.Channel](found)
                }
                held :: runtime.new(HandleValue)
                held^ = HandleValue.{kind = kind, end = end, name = name}
                bind(shell.scope, name, .Handle(held))
                continue
            }
            case None => {}
        }
        value :: given_value(type, name)
        match value {
            case Some(found) => bind(shell.scope, name, found)
            case None => {
                match first_child(parameter) {
                    case Some(default) => {
                        made :: match evaluate(shell, default) {
                            case Ok(evaluated) => evaluated
                            case Error(error) => return error
                        }
                        bind(shell.scope, name, if type == "path" { as_path(made) } else { made })
                    }
                    case None => {
                        if type != "bool" {
                            return EvalError.{message = message("% wasn't given", name), at = parameter.at}
                        }
                        bind(shell.scope, name, .Bool(false))
                    }
                }
            }
        }
    }
    return null
}

/**
 * Read the value a script's parameter was given, from the grant "arguments", by its type.
 *
 * @param type The parameter's type's name.
 * @param name Its name.
 * @return The value; null if none was written for it, as for one left to its default.
 */
given_value :: fn(type: string, name: string) -> Value? {
    if type == "int" || type == "duration" {
        bytes :: runtime.slop_os_argument(name, type_info_of(i64)) or_return null
        number :: schema.read_value[i64](bytes) or_return null
        return if type == "int" { Value.Int(number) } else { Value.Duration(number) }
    }
    if type == "size" {
        bytes :: runtime.slop_os_argument(name, type_info_of(u64)) or_return null
        return Value.Size(schema.read_value[u64](bytes) or_return null)
    }
    if type == "bool" {
        bytes :: runtime.slop_os_argument(name, type_info_of(bool)) or_return null
        return Value.Bool(schema.read_value[bool](bytes) or_return null)
    }
    bytes :: runtime.slop_os_argument(name, type_info_of(string)) or_return null
    text :: schema.read_value[string](bytes) or_return null
    return if type == "path" { Value.Path(text) } else { Value.Text(text) }
}

/**
 * Show a script's error: "error: line n: " and its message, the line, and a ^ under where in it the error is.
 *
 * @param shell The shell running the script, whose terminal it's shown on.
 * @param text The script's text.
 * @param at Where the error is, in bytes from the text's start.
 * @param what What's wrong.
 */
script_error :: fn(shell: ptr[mut Shell], text: string, at: usize, what: string) {
    bytes :: string_bytes(text)
    start := cast[usize](0)
    end := bytes.count
    for byte, i in bytes {
        if byte == cast[u8]('\n') {
            if i < at {
                start = i + 1
            }
            else {
                end = i
                break
            }
        }
    }
    line :: language.slice(text, start, end)
    show_error(shell, line, if at > start { at - start } else { 0 }, message("line %1: %2", line_number(text, at), what))
}

/**
 * Count which line a place in a text is on.
 *
 * @param text The text.
 * @param at The place, in bytes.
 * @return The line, from 1.
 */
line_number :: fn(text: string, at: usize) -> usize {
    count := cast[usize](1)
    for byte, i in string_bytes(text) {
        if i < at && byte == cast[u8]('\n') {
            count += 1
        }
    }
    return count
}

// ---- Types

/**
 * Tell what kind of handle a script's parameter's type is.
 *
 * @param type The type's name.
 * @return Dir, File or ReadOnlyFile; null for any other type.
 */
handle_kind_of :: fn(type: string) -> HandleKind? {
    if type == "Dir" {
        return HandleKind.Dir
    }
    if type == "File" {
        return HandleKind.File
    }
    if type == "ReadOnlyFile" {
        return HandleKind.ReadOnlyFile
    }
    return null
}

/**
 * Tell whether a script's parameter is a handle's.
 *
 * @param parameter The Parameter node.
 * @return True for Dir, File and ReadOnlyFile.
 */
is_handle_type :: fn(parameter: ptr[Node]) -> bool {
    return handle_kind_of(type_of_parameter(parameter)) is_some
}

/**
 * Give what a program's parameter of a handle's kind is given.
 *
 * @param kind The kind.
 * @return Dir, File or ReadOnlyFile.
 */
giving_of_kind :: fn(kind: HandleKind) -> Giving {
    return match kind {
        case .Dir => Giving.Dir
        case .File => Giving.File
        case .ReadOnlyFile => Giving.ReadOnlyFile
    }
}

/**
 * Give the kind of handle a program's parameter takes.
 *
 * @param giving What it's given.
 * @return Dir for Dir and Here, File, ReadOnlyFile; null for anything else.
 */
handle_kind_of_giving :: fn(giving: Giving) -> HandleKind? {
    return match giving {
        case .Dir => HandleKind.Dir
        case .Here => HandleKind.Dir
        case .File => HandleKind.File
        case .ReadOnlyFile => HandleKind.ReadOnlyFile
        case _ => null
    }
}
