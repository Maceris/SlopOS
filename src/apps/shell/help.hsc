package shell

import runtime from "base"
import language from "../../shell_language"
import os from "std"
import schema from "std"
import strings from "std"
import text_buffer from "std"
import slop_os from "std/os"
import bundle from "../../bundle"
import programs from "../../protocols/programs"

/*
 * Help (design/shell.md §6, decisions/0174): what the shell's built-ins do, a shell function's parameters, and a
 * program's documentation, which its build wrote from its main's documentation comment and its bundle keeps, with its
 * parameters' types from its manifest. The programs' names and documentation come from the session manager's
 * Programs connection, as the programs themselves do.
 */

/** One of the shell's built-ins, and what it does. */
Builtin :: struct {
    /** Its name, as it's called. */
    name : string,
    /** What it does, in a sentence, as help and completion show it. */
    summary : string,
}

/** The shell's built-ins, and the built-in stages, in the order help lists them. */
BUILTINS :: Builtin.[
    Builtin.{name = "print", summary = "Write its arguments on a line, separated by spaces."},
    Builtin.{name = "cd", summary = "Change the directory, beneath the home: a path, or ~ or nothing for the home."},
    Builtin.{name = "help", summary = "Say what a command does and takes: help name, or help alone for the built-ins."},
    Builtin.{name = "exit", summary = "End the shell, and the session with it."},
    Builtin.{name = "jobs", summary = "List the jobs in the background, started with & after a command."},
    Builtin.{name = "wait", summary = "Wait for a job to end, and give what it gave: wait n, or wait alone for the newest."},
    Builtin.{name = "stop", summary = "Stop a job, killing it if it hasn't stopped in 2 seconds: stop n, or the newest."},
    Builtin.{name = "where", summary = "Keep the items an expression is true for, in a pipeline: where size > 1MiB."},
    Builtin.{name = "map", summary = "Make each item an expression's value, in a pipeline: map name."},
    Builtin.{name = "sort", summary = "Sort the items by a field, or by themselves, in a pipeline: sort size --descending."},
    Builtin.{name = "take", summary = "Keep the first n items, in a pipeline: take 10."},
    Builtin.{name = "group", summary = "Group the items by a field, with their count, in a pipeline: group kind."},
]

/**
 * Find a built-in by its name.
 *
 * @param name The name, compared exactly.
 * @return The built-in, a constant's; null if none has the name.
 */
builtin_named :: fn(name: string) -> Builtin? {
    for each in BUILTINS {
        if each.name == name {
            return each
        }
    }
    return null
}

/**
 * List the names of the programs the shell can run, asking the session manager once, and keeping them after.
 *
 * @param shell The shell, whose programs connection is asked the first time, a name at a time, and whose names keep
 *     the answer.
 * @return The names, in the bundle store's boot root's order, the shell's own; empty without a programs connection,
 *     or if it couldn't be asked. One that couldn't be asked is asked again next time.
 */
program_names :: fn(shell: ptr[mut Shell]) -> string[] {
    if shell.names_listed {
        return shell.names[0..<shell.names.count]
    }
    connection :: shell.programs or_return shell.names[0..<0]
    index : u32 = 0
    loop {
        out := os.Outgoing.{}
        os.begin[programs.Request](&out)^ = .List(index)
        if programs.send_request(connection.end, shell.programs_port, &out) is_some {
            return shell.names[0..<shell.names.count]
        }
        into := os.Incoming.{}
        if !received(programs.receive_response(connection.end, shell.programs_port, &into, true)) {
            return shell.names[0..<shell.names.count]
        }
        match os.message_of[programs.Response](&into)^ {
            case Named(name) => {
                bytes :: os.items(&into, name)
                if bytes.count > 0 {
                    runtime.array_add(&shell.names, strings.clone(string_of(&bytes[0], bytes.count)) or_else "")
                }
            }
            case _ => break
        }
        index += 1
    }
    shell.names_listed = true
    return shell.names[0..<shell.names.count]
}

/**
 * Tell whether a response came, after waiting for it.
 *
 * @param result What receive_response gave.
 * @return True for Received; false for anything else: the connection failed, or the answer broke its rules.
 */
received :: fn(result: os.Arrival) -> bool {
    return match result {
        case Received => true
        case _ => false
    }
}

/**
 * Find a program's documentation, asking the session manager's Programs connection, and read it from the record its
 * bundle keeps.
 *
 * @param shell The shell, whose programs connection is asked, waiting for its answer.
 * @param name The program's name, 1 to programs.MAX_NAME bytes.
 * @return The documentation, its text the shell's, never freed; null without a programs connection, for a name too
 *     short or long, a program that's missing or has none, or a record that doesn't read as one.
 */
program_documentation :: fn(shell: ptr[mut Shell], name: string) -> bundle.Documentation? {
    connection :: shell.programs or_return null
    if name.count == 0 || name.count > programs.MAX_NAME {
        return null
    }
    out := os.Outgoing.{}
    // Begun first: the name's appended after the message, at a distance from it
    request :: os.begin[programs.Request](&out)
    request^ = .Describe(os.append(&out, string_bytes(name)))
    if programs.send_request(connection.end, shell.programs_port, &out) is_some {
        return null
    }
    into := os.Incoming.{}
    if !received(programs.receive_response(connection.end, shell.programs_port, &into, true)) {
        return null
    }
    found :: match os.message_of[programs.Response](&into)^ {
        case Documented(documented) => documented
        case _ => return null
    }
    defer slop_os.handle_close(cast[slop_os.Handle](found.record))
    size :: (found.size + 4095) & ~cast[u64](4095)
    if found.size == 0 {
        return null
    }
    address :: runtime.reserve_addresses(cast[usize](size)) or_return null
    if slop_os.memory_map(found.record, slop_os.startup_block().space, address, 0, size, slop_os.PROTECTION_READ) is_error {
        return null
    }
    defer {
        _ = slop_os.memory_unmap(slop_os.startup_block().space, address)
    }
    return bundle.documentation_of(view_of(cast[ptr[u8]](address), cast[usize](found.size)))
}

/**
 * Find a program's manifest, asking the session manager for the program, and read it; its executable isn't kept.
 *
 * @param shell The shell, whose programs connection is asked.
 * @param name The program's name.
 * @return The manifest, the caller's to free; null if there's no such program, or its manifest doesn't read.
 */
program_manifest :: fn(shell: ptr[mut Shell], name: string) -> schema.Schema? {
    found :: find_program(shell, name) or_return null
    _ = slop_os.handle_close(cast[slop_os.Handle](found.executable))
    manifest :: read_manifest(found)
    _ = slop_os.handle_close(cast[slop_os.Handle](found.manifest))
    return manifest
}

/**
 * Show help, for help [name]: alone, the built-ins and how to ask for more; with a name, a built-in's sentence, a shell
 * function's parameters, or a program's documentation and what it takes.
 *
 * It fails for more than one argument, or a name that's none of those.
 *
 * @param shell The shell, whose terminal it's written on, and whose functions and programs connection are asked.
 * @param tree The Call node of help, its one argument, if any, the name.
 * @return Null.
 */
show_help :: fn(shell: ptr[mut Shell], tree: ptr[Node]) -> Result[Value, EvalError] {
    if tree.children.count > 1 {
        return error_at(tree.at, "help takes one name")
    }
    named :: match first_child(tree) {
        case Some(given) => given
        case None => {
            say(shell, "The shell's built-ins, and the stages that work on what comes before them in a pipeline:")
            for each in BUILTINS {
                say_described(shell, each.name, each.summary, 8)
            }
            say(shell, "Anything else is a program, or a function defined with fn. help name says what one does and takes;")
            say(shell, "Tab completes commands, --parameters, $names and paths; & after a command runs it in the background,")
            say(shell, "and Ctrl-C stops what runs in the foreground.")
            return .Ok(.Null)
        }
    }
    name :: named.text
    match builtin_named(name) {
        case Some(found) => {
            say_described(shell, found.name, found.summary, 0)
            return .Ok(.Null)
        }
        case None => {}
    }
    match function_named(shell, name) {
        case Some(function) => {
            help_function(shell, function)
            return .Ok(.Null)
        }
        case None => {}
    }
    manifest := program_manifest(shell, name) or_return error_at(named.at, message("there's no command named %", name))
    defer schema.free(&manifest)
    help_program(shell, name, &manifest, program_documentation(shell, name))
    return .Ok(.Null)
}

/**
 * Write a name and what it is on a line, the text lined up a column past the name, or two spaces after it.
 *
 * @param shell The shell, whose terminal it's written on.
 * @param name The name, written first.
 * @param text What it is, after it; nothing after the name for empty text.
 * @param column How wide the name's column is, in bytes; 0 for the text two spaces after the name. The line's cut at
 *     1 KiB.
 */
say_described :: fn(shell: ptr[mut Shell], name: string, text: string, column: usize) {
    storage : u8[1024]
    out := text_buffer.make(storage)
    text_buffer.append(&out, name)
    if text.count > 0 {
        language.pad(&out, if column > name.count + 2 { column - name.count } else { 2 })
        text_buffer.append(&out, text)
    }
    say(shell, text_buffer.as_string(&out))
}

/**
 * Write a shell function's help: how it's called, each parameter with its type and default.
 *
 * @param shell The shell, whose terminal it's written on.
 * @param function The function's Function node, its parameters first.
 */
help_function :: fn(shell: ptr[mut Shell], function: ptr[Node]) {
    say(shell, message("% is a shell function, defined with fn. It takes:", function.text))
    taken := false
    for parameter in function.children {
        if parameter.kind != .Parameter {
            continue
        }
        taken = true
        type :: type_of_parameter(parameter)
        default :: if parameter.children.count > 0 { ", with a default" } else if type == "bool" { ", false if not given" } else { "" }
        say(shell, message("  --%1 (%2%3)", parameter.text, if type.count > 0 { type } else { "any type" }, default))
    }
    if !taken {
        say(shell, "  nothing")
    }
}

/**
 * Write a program's help: its documentation's summary and details, each parameter with what it's given and what its
 * documentation says of it, then what it gives back, its errors, and its notes.
 *
 * @param shell The shell, whose terminal it's written on.
 * @param name The program's name.
 * @param manifest Its manifest, whose entry's inputs are its parameters; only read.
 * @param documentation Its documentation; null for a program without, when only its parameters are written.
 */
help_program :: fn(shell: ptr[mut Shell], name: string, manifest: ptr[schema.Schema], documentation: bundle.Documentation?) {
    described := documentation or_else bundle.Documentation.{}
    say_described(shell, message("%:", name), if described.summary.count > 0 { described.summary } else { "a program, without documentation" }, 0)
    if described.details.count > 0 {
        say(shell, described.details)
    }
    entry :: schema.type_in(manifest, 0) or_return void
    if entry.inputs.count > 0 {
        say(shell, "It takes:")
    }
    for input in entry.inputs {
        parameter :: parameter_of(manifest, input)
        text := ""
        for each in described.parameters {
            if each.name == parameter.name {
                text = each.text
            }
        }
        say_described(shell, message("  --% (%)", parameter.name, given_text(manifest, parameter)), text, 0)
    }
    for result in described.results {
        say_described(shell, "It gives back:", result, 0)
    }
    for each in described.errors {
        say_described(shell, message("Error %:", each.name), each.text, 0)
    }
    for each in described.others {
        say_described(shell, message("%:", each.name), each.text, 0)
    }
}

/**
 * Say what a parameter's given, as help writes it after its name.
 *
 * @param manifest The program's manifest, which its type's in; only read.
 * @param parameter The parameter.
 * @return Its type's name, and ", optional" when it is; or for a grant, how the shell gives it. A message on the heap,
 *     never freed.
 */
given_text :: fn(manifest: ptr[schema.Schema], parameter: Parameter) -> string {
    optional :: if parameter.optional { ", optional" } else { "" }
    return match parameter.giving {
        case .Value => message("%1%2", type_text(manifest, parameter.held), optional)
        case .Terminal => "the shell's terminal, given without asking"
        case .Dir => message("a directory, by its path%", optional)
        case .File => message("a file to read and write, by its path%", optional)
        case .ReadOnlyFile => message("a file to read, by its path%", optional)
        case .Input => "what comes before it in a pipeline"
        case .Output => "what it writes for what comes after it in a pipeline"
        case .Other => message("a grant the shell can't give%", optional)
    }
}
