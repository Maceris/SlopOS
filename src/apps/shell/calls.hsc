package shell

import runtime from "base"
import language from "../../shell_language"
import os from "std"
import schema from "std"
import slop_os from "std/os"
import process_manager from "std/os/slop_os"
import lifecycle from "std/os/slop_os"
import dir from "std/os/slop_os"
import files from "std/os/slop_os"
import terminal as protocol from "std/os/slop_os"
import programs from "../../protocols/programs"

/*
 * Calls to programs through their manifests (design/shell.md §3, decisions/0170): the program found in the bundle
 * store's boot root by its name, its manifest read, each argument matched to a parameter by position or --name and
 * read by the parameter's type, the grants its types ask for made, and the values written as its entry reads them;
 * then it's launched in a process of the shell's and waited for. Its exit code is its error, if it isn't 0. Its
 * records, a Sink[T] parameter named output, are its value, read by the shell; a Stream[T] named input reads what comes
 * before it in a pipeline (decisions/0172).
 */

/** The memory a program the shell runs is given to run on, in bytes, split off the shell's budget: 4 MiB. */
PROGRAM_BUDGET : u64 : 4 * 1024 * 1024

/** What a parameter is given: a value written for it, or a grant of one of the kinds the shell can make. */
Giving :: enum {
    /** A value, written from its argument as the entry reads it. */
    Value,
    /** A connection to the shell's terminal, without an argument. */
    Terminal,
    /** A directory beneath the shell's home, from a path. */
    Dir,
    /**
     * The shell's directory, without an argument, for a Dir named here (decisions/0179); or, from --here, a directory
     * beneath its home, as Dir is.
     */
    Here,
    /** A file to read and write beneath the shell's home, from a path; made if it isn't there. */
    File,
    /** A file only to read beneath the shell's home, from a path. */
    ReadOnlyFile,
    /** A pipeline's records: the Stream[T] named input, which reads what comes before it. */
    Input,
    /** A pipeline's records: the Sink[T] named output, which writes for what comes after it, or for the shell. */
    Output,
    /** A grant the shell doesn't make: a parameter that's optional goes without it. */
    Other,
}

/** One of a program's parameters, as its manifest has it, and what it's given. */
Parameter :: struct {
    /** Its name, a view of the manifest's text, which --name matches. */
    name : string,
    /** Its type's place in the manifest. */
    type : usize,
    /** The type it holds if it's optional, its Some's; its type again if not. */
    held : usize,
    /** Whether it's optional, so it can go without an argument. */
    optional : bool,
    /** Whether it's a bool, whose --name alone is true. */
    is_bool : bool,
    /** What it's given. */
    giving : Giving,
    /** An input's or output's records' type's place; schema.NOWHERE for other parameters. */
    records : usize,
    /** The argument given for it; null if none is. */
    argument : ptr[Node]?,
    /** Whether it's a bool given by its --name alone, so it's true. */
    flag : bool,
}

/**
 * Run a call of a program, alone: a pipeline of one.
 *
 * @param shell The shell, which prepares, starts and waits for the program as run_programs does, until it's ended.
 * @param tree The Call node, its text the program's name.
 * @return The program's value: its output's records, or Null without an output (run_programs).
 */
run_program :: fn(shell: ptr[mut Shell], tree #escaping : ptr[Node]) -> Result[Value, EvalError] {
    trees : ptr[Node][..]
    defer runtime.array_free(&trees)
    runtime.array_add(&trees, tree)
    return run_programs(shell, trees, null)
}

/**
 * Make a call ready to start: its program found, its manifest read, its arguments matched, and its values and grants
 * made, but its input's and output's, which its pipeline makes.
 *
 * It fails, letting go of all it made, if there's no program of that name, its manifest isn't an entry's the shell can
 * read, the arguments don't match its parameters, or a value or grant can't be made.
 *
 * @param shell The shell, whose functions evaluate the arguments and whose home grants are opened in.
 * @param tree The Call node, kept by the call.
 * @param background Whether it runs in the background, where it isn't given the terminal: a program that needs it
 *     can't, and one for which it's optional goes without.
 * @return The call, on the heap, the caller's to start and then end with end_call.
 */
prepare_call :: fn(shell: ptr[mut Shell], tree #escaping : ptr[Node], background: bool) -> Result[ptr[mut Call], EvalError] {
    found :: find_program(shell, tree.text) or_return .Error(EvalError.{message = message("there's no command named %", tree.text), at = tree.at})
    call := runtime.new(Call)
    call.tree = tree
    call.executable = found.executable
    ready := false
    defer {
        if !ready {
            end_call(call)
        }
    }
    manifest :: read_manifest(found)
    _ = slop_os.handle_close(cast[slop_os.Handle](found.manifest))
    call.manifest = manifest or_return .Error(EvalError.{message = message("%'s manifest isn't one the shell can read", tree.text), at = tree.at})
    entry :: schema.type_in(&call.manifest, 0) or_return .Error(EvalError.{message = message("%'s manifest isn't one the shell can read", tree.text),
        at = tree.at})
    if entry.kind != .Function {
        return .Error(EvalError.{message = message("%'s manifest isn't an entry's", tree.text), at = tree.at})
    }
    for input in entry.inputs {
        runtime.array_add(&call.parameters, parameter_of(&call.manifest, input))
    }
    match match_arguments(tree, &call.parameters) {
        case Ok(_) => {}
        case Error(error) => return .Error(error)
    }
    for &parameter in call.parameters {
        if parameter.giving == .Value {
            match value_for(shell, &call.manifest, tree, parameter)? {
                case Some(bytes) => {
                    runtime.array_add(&call.written, bytes)
                    runtime.array_add(&call.values, os.NamedValue.{name = parameter.name, hash = schema.hash_rooted(&call.manifest, parameter.held),
                        value = bytes})
                }
                case None => {}
            }
        }
        else if parameter.giving != .Input && parameter.giving != .Output {
            match grant_for(shell, tree, parameter, background)? {
                case Some(handle) => runtime.array_add(&call.grants, os.NamedGrant.{label = parameter.name, handle = handle})
                case None => {}
            }
        }
    }
    // The views of the values' bytes, again, now that they're all written and won't move
    for &value, i in call.values {
        if i < call.written.count {
            value.value = call.written[i]
        }
    }
    ready = true
    return .Ok(call)
}

/** A call being made, on the heap: its program's manifest, its parameters, and the grants and values made for them. */
Call :: struct {
    /** The Call node it's for, whose name and place errors use. */
    tree : ptr[Node],
    /** The program's executable, the call's handle, closed by end_call. */
    executable : slop_os.Memory,
    /** The program's manifest, parsed, the call's own, freed by end_call. */
    manifest : schema.Schema,
    /** The entry's parameters, in order. */
    parameters : Parameter[..],
    /** The grants made for its parameters, the call's until the program starts, and then the program's. */
    grants : os.NamedGrant[..],
    /** The values written for its parameters, each a view of its bytes in written. */
    values : os.NamedValue[..],
    /** The values' bytes, each from the heap, freed by end_call. */
    written : u8[..][..],
    /** Whether the program started, which made the grants its. */
    started : bool,
    /** Whether its end's been seen. */
    waited : bool,
    /** Once it's started: the key its end's watched under on the shell's port. */
    key : u64,
    /** Once it's started: its process and budget, the call's handles, closed by end_call. */
    launched : os.Launched,
    /** Once it's started: the shell's end of its lifecycle channel, closed by end_call. */
    lifecycle : slop_os.Channel,
    /** The newest progress it's said on its lifecycle channel, in thousandths, once reporting. */
    progress : u32,
    /** Whether it's said its progress, so it's shown. */
    reporting : bool,
    /** The memory its program writes what its entry gives back in, the call's, closed by end_call; with has_result. */
    result : slop_os.Memory,
    /** Whether result was made, for an entry that gives back more than an exit code (result_grant). */
    has_result : bool,
    /** What its program's entry gave back as an Ok, once it's ended (read_result); Null for nothing. */
    returned : Value,
}

/**
 * Find a call's parameter that's given a kind of thing.
 *
 * @param call The call, prepared, whose parameters are searched in order; only read.
 * @param giving The kind, like Input or Output.
 * @return The first parameter given it, in the call; null if none is.
 */
parameter_giving :: fn(call: ptr[Call], giving: Giving) -> ptr[Parameter]? {
    for &parameter in call.parameters {
        if parameter.giving == giving {
            return parameter
        }
    }
    return null
}

/**
 * End a call: its memory and handles given back, and its grants closed if its program didn't start, since then they're
 * still the shell's. A started program isn't stopped or waited for.
 *
 * @param call The call, freed: it can't be used after.
 */
end_call :: fn(call: ptr[mut Call]) {
    if !call.started {
        for grant in call.grants {
            _ = slop_os.handle_close(grant.handle)
        }
    }
    else {
        for handle in slop_os.Handle.[cast[slop_os.Handle](call.launched.process), cast[slop_os.Handle](call.launched.budget),
            cast[slop_os.Handle](call.lifecycle)] {
            _ = slop_os.handle_close(handle)
        }
    }
    _ = slop_os.handle_close(cast[slop_os.Handle](call.executable))
    if call.has_result {
        _ = slop_os.handle_close(cast[slop_os.Handle](call.result))
    }
    for &each in call.written {
        runtime.array_free(each)
    }
    runtime.array_free(&call.written)
    runtime.array_free(&call.values)
    runtime.array_free(&call.grants)
    runtime.array_free(&call.parameters)
    schema.free(&call.manifest)
    runtime.free(call)
}

/**
 * Launch a call's program, through the process manager, in a process of the shell's, its end watched under a key, and
 * its lifecycle channel under the key plus LIFECYCLE_KEY, for what it says of its progress.
 *
 * It's given the call's grants and values, PROGRAM_BUDGET, a lifecycle channel, and copies of the shell's clock and
 * locale grants. Once it's started, its grants are its.
 *
 * @param shell The shell, whose process manager launches it and whose port (watch_port) watches its end.
 * @param call The call, prepared; its launched, lifecycle and key are set once it's started.
 * @param key The key its end is watched under, on the shell's port: FIRST_KEY or above, below LIFECYCLE_KEY.
 * @return Null once it's started; why it didn't otherwise: no process manager, no memory for its lifecycle channel, or
 *     the launch's error. A launch that fails leaves the lifecycle channel and the grants' copies the shell's, and
 *     they're closed.
 */
start_call :: fn(shell: ptr[mut Shell], call: ptr[mut Call], key: u64) -> EvalError? {
    tree :: call.tree
    manager :: shell.manager or_return EvalError.{message = "the shell can't start programs: it has no process manager", at = tree.at}
    block :: slop_os.startup_block()
    ends :: lifecycle.make(block.budget) or_return EvalError.{message = "there's no memory to start it", at = tree.at}
    options := os.LaunchOptions.{watch = os.LaunchWatch.{port = watch_port(shell), key = key}, lifecycle = ends.b}
    options.clock = copy_of_grant("clock")
    options.locale = copy_of_grant("locale")
    options.result = result_grant(call)
    match os.launch_named(manager, shell.manager_port, tree.text, call.executable, PROGRAM_BUDGET, call.grants, call.values, options) {
        case Ok(made) => {
            call.started = true
            call.launched = made
            call.lifecycle = ends.a
            call.key = key
            // Its lifecycle channel wakes the shell when it says its progress; without the binding, it's read anyway
            _ = slop_os.port_bind(watch_port(shell), cast[slop_os.Handle](ends.a), slop_os.SIGNAL_READABLE, key + LIFECYCLE_KEY, .Persistent)
            return null
        }
        case Error(error) => {
            for handle in slop_os.Handle.[cast[slop_os.Handle](ends.a), cast[slop_os.Handle](ends.b)] {
                _ = slop_os.handle_close(handle)
            }
            close_copy(options.clock)
            close_copy(options.locale)
            close_copy(options.result)
            return EvalError.{message = message("% didn't start: %", tree.text, error), at = tree.at}
        }
    }
}

/**
 * Wait for a started call's program to end, seeing to Ctrl-C meanwhile (wait_for), and stop watching it.
 *
 * @param shell The shell, whose port it waits on.
 * @param call The call; one not started, or already waited for, isn't waited for again.
 * @param running The programs it runs among, which Ctrl-C stops.
 * @return Null if it ended with 0, or wasn't waited for; the error its entry gave back, if it gave one (read_result);
 *     an error saying it was ended, or with what code, if not, or that the shell's port couldn't be waited on, when
 *     its end's never seen.
 */
wait_call :: fn(shell: ptr[mut Shell], call: ptr[mut Call], running: ptr[mut Running]) -> EvalError? {
    if !call.started || call.waited {
        return null
    }
    tree :: call.tree
    waited :: wait_for(shell, call.key, running)
    call.waited = true
    _ = slop_os.port_unbind(watch_port(shell), call.key)
    _ = slop_os.port_unbind(watch_port(shell), call.key + LIFECYCLE_KEY)
    ended :: waited or_return EvalError.{message = message("the shell couldn't wait for % to end", tree.text), at = tree.at}
    // What its entry gave back, which an Error makes its error
    match read_result(shell, call, ended) {
        case Some(error) => return error
        case None => {}
    }
    if ended == 0 {
        return null
    }
    if ended == slop_os.EXIT_KILLED {
        return EvalError.{message = message("% was ended", tree.text), at = tree.at}
    }
    return EvalError.{message = message("% ended with %", tree.text, ended), at = tree.at}
}

/** A program's end seen on the shell's port, by the key it's watched under, and its code. */
EndedProgram :: struct {
    /** The key its end's watched under. */
    key : u64,
    /** Its exit code: 0 for success, slop_os.EXIT_KILLED if it was ended, anything else its own. */
    code : u64,
}

/**
 * Copy one of the shell's own memory grants for a program it runs, read only: the clock page, or its locale's.
 *
 * @param label The grant's label, like "clock" or "locale".
 * @return The copy, a handle that can only be read and moved, which the launch gives the program; null if the shell
 *     wasn't given one, or it couldn't be copied.
 */
copy_of_grant :: fn(label: string) -> slop_os.Memory? {
    rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_READ) | cast[u32](slop_os.RIGHT_TRANSFER))
    for &grant in slop_os.grants_of(slop_os.startup_block()) {
        if grant.kind == .Memory && slop_os.label_of(grant) == label {
            match slop_os.handle_duplicate(grant.handle, rights) {
                case Ok(copy) => return cast[slop_os.Memory](copy)
                case Error(error) => return null
            }
        }
    }
    return null
}

/**
 * Close a copy of a grant a launch didn't take.
 *
 * @param copy The copy, as copy_of_grant made it, closed; null for none, when nothing is.
 */
close_copy :: fn(copy: slop_os.Memory?) {
    match copy {
        case Some(memory) => _ = slop_os.handle_close(cast[slop_os.Handle](memory))
        case None => {}
    }
}

/**
 * Find a program by its name, asking the session manager's Programs connection (decisions/0170), and wait for its
 * answer.
 *
 * @param shell The shell, whose programs connection is asked.
 * @param name The program's name, 1 to programs.MAX_NAME bytes.
 * @return Its executable and manifest, handles the caller owns and closes; null without a programs connection, for a
 *     name too short or long, if it couldn't be asked, or if there's no such program.
 */
find_program :: fn(shell: ptr[mut Shell], name: string) -> programs.Program? {
    connection :: shell.programs or_return null
    if name.count == 0 || name.count > programs.MAX_NAME {
        return null
    }
    out := os.Outgoing.{}
    request :: os.begin[programs.Request](&out)
    request^ = .Find(os.append(&out, string_bytes(name)))
    if programs.send_request(connection.end, shell.programs_port, &out) is_some {
        return null
    }
    into := os.Incoming.{}
    loop {
        match programs.receive_response(connection.end, shell.programs_port, &into, true) {
            case Received => break
            case Failed(error) => return null
            case _ => return null
        }
    }
    return match os.message_of[programs.Response](&into)^ {
        case Found(program) => program
        case _ => null
    }
}

/**
 * Read a program's manifest from its memory, mapped while it's parsed.
 *
 * @param found The program, whose manifest memory stays the caller's to close.
 * @return The manifest, the caller's to free; null if it's empty, couldn't be mapped, or isn't a schema.
 */
read_manifest :: fn(found: programs.Program) -> schema.Schema? {
    size :: (found.manifest_size + 4095) & ~cast[u64](4095)
    if found.manifest_size == 0 {
        return null
    }
    address :: runtime.reserve_addresses(cast[usize](size)) or_return null
    if slop_os.memory_map(found.manifest, slop_os.startup_block().space, address, 0, size, slop_os.PROTECTION_READ) is_error {
        return null
    }
    defer {
        _ = slop_os.memory_unmap(slop_os.startup_block().space, address)
    }
    return schema.parse(view_of(cast[ptr[u8]](address), cast[usize](found.manifest_size)))
}

/**
 * Make a parameter from its manifest's input: whether it's optional, and what it's given, by its type.
 *
 * Only parameters named input and output are a pipeline's; others of a Stream's or Sink's type are grants the shell
 * doesn't make (Other).
 *
 * @param manifest The program's manifest, which input's type is looked up in; only read.
 * @param input The entry's input, whose name the parameter views.
 * @return The parameter, given no argument yet.
 */
parameter_of :: fn(manifest: ptr[schema.Schema], input: schema.Input) -> Parameter {
    made := Parameter.{name = input.name, type = input.type, held = input.type}
    match some_of(manifest, input.type) {
        case Some(held) => {
            made.optional = true
            made.held = held
        }
        case None => {}
    }
    made.giving = giving_of(manifest, made.held)
    // A directory named here is the shell's own, given without asking (decisions/0179)
    if made.giving == .Dir && made.name == "here" {
        made.giving = .Here
    }
    if made.giving == .Input || made.giving == .Output {
        made.records = records_of(manifest, made.held)
        // Only the parameters named so are a pipeline's; others of their types are grants the shell doesn't make
        if made.name != (if made.giving == .Input { "input" } else { "output" }) || made.records == schema.NOWHERE {
            made.giving = .Other
        }
    }
    match schema.type_in(manifest, schema.unaliased_place(manifest, made.held)) {
        case Some(held) => made.is_bool = held.kind == .Boolean
        case None => {}
    }
    return made
}

/**
 * Find an optional's Some type, if the type at a place is an optional: a union of None and Some(T), not a pointer's.
 *
 * @param manifest The program's manifest, only read.
 * @param place The type's place among the manifest's types, taken as it is: an alias isn't followed.
 * @return The place of T; null if the type isn't such an optional.
 */
some_of :: fn(manifest: ptr[schema.Schema], place: usize) -> usize? {
    type :: schema.type_in(manifest, place) or_return null
    if type.kind != .Union || type.null_is_none || type.variants.count != 2 {
        return null
    }
    for variant in type.variants {
        if variant.name == "Some" && variant.held.count == 1 {
            for held in variant.held {
                return held.type
            }
        }
    }
    return null
}

/**
 * Tell what a parameter of the type at a place is given: a grant if it's a handle's type, by its name, or a value.
 *
 * @param manifest The program's manifest, only read.
 * @param place The type's place among the manifest's types, an optional's Some type already taken.
 * @return Input for a Stream, Output for a Sink, Terminal, Dir, File or ReadOnlyFile for a Channel of those protocols,
 *     Other for any other handle or a type not in the manifest, and Value for anything else.
 */
giving_of :: fn(manifest: ptr[schema.Schema], place: usize) -> Giving {
    type :: schema.type_in(manifest, place) or_return Giving.Other
    if type.size != 4 || (type.kind != .Struct && type.kind != .Alias) {
        return .Value
    }
    kind := type.name
    inner := ""
    for character, i in type.name {
        if character == '[' {
            kind = language.slice(type.name, 0, i)
            inner = language.slice(type.name, i + 1, type.name.count - 1)
            break
        }
    }
    if runtime.slop_os_kind_of(kind) == 0 {
        return .Value
    }
    // The protocol's own name, without its package
    for character, i in inner {
        if character == '.' {
            inner = language.slice(inner, i + 1, inner.count)
        }
    }
    if kind == "Stream" {
        return .Input
    }
    if kind == "Sink" {
        return .Output
    }
    if kind == "Channel" {
        if inner == "Terminal" {
            return .Terminal
        }
        if inner == "Dir" {
            return .Dir
        }
        if inner == "File" {
            return .File
        }
        if inner == "ReadOnlyFile" {
            return .ReadOnlyFile
        }
    }
    return .Other
}

/**
 * Find the type of the records a Stream[T] or Sink[T] reads or writes: its records member's elements'.
 *
 * @param manifest The program's manifest, only read.
 * @param place The Stream's or Sink's type's place among the manifest's types.
 * @return The records' type's place; schema.NOWHERE if the type has no records member that's an array.
 */
records_of :: fn(manifest: ptr[schema.Schema], place: usize) -> usize {
    type :: schema.type_in(manifest, place) or_return schema.NOWHERE
    for member in type.members {
        if member.name == "records" {
            records :: schema.type_in(manifest, member.type) or_return schema.NOWHERE
            if records.kind == .Array {
                return records.base
            }
        }
    }
    return schema.NOWHERE
}

/**
 * Match each argument to a parameter: --name to the parameter of that name, the argument after it its value but for a
 * bool's, which is true alone; the rest in order to the parameters left that take arguments (next_positional).
 *
 * It fails for a --name the program hasn't, one given twice, one for the terminal or a pipeline's input or output,
 * one without a value after it, or more arguments than parameters to take them.
 *
 * @param tree The Call node, whose children are the arguments.
 * @param parameters The program's parameters, whose argument and flag are set.
 * @return Null.
 */
match_arguments :: fn(tree: ptr[Node], parameters: ptr[mut Parameter[..]]) -> Result[Value, EvalError] {
    at : usize = 0
    loop {
        argument :: child(tree, at) or_break
        at += 1
        if argument.kind == .Named {
            parameter :: named_parameter(parameters, argument.text) or_return error_at(argument.at, message("% takes no --%", tree.text, argument.text))
            if (parameter.argument is_some) || parameter.flag {
                return error_at(argument.at, message("--% is given twice", argument.text))
            }
            if parameter.giving == .Terminal {
                return error_at(argument.at, message("--% is the shell's terminal, which it's given without asking", argument.text))
            }
            if parameter.giving == .Input || parameter.giving == .Output {
                return error_at(argument.at, message("--% is a pipeline's, given by |", argument.text))
            }
            next :: child(tree, at)
            if parameter.giving == .Value && parameter.is_bool && !is_bool_word(next) {
                parameter.flag = true
                continue
            }
            value :: next or_return error_at(argument.at, message("--% needs a value after it", argument.text))
            if value.kind == .Named {
                return error_at(value.at, message("--% needs a value after it", argument.text))
            }
            parameter.argument = value
            at += 1
            continue
        }
        parameter :: next_positional(parameters) or_return error_at(argument.at, message("% takes no more arguments", tree.text))
        parameter.argument = argument
    }
    return .Ok(.Null)
}

/**
 * Find a parameter by its name.
 *
 * @param parameters The program's parameters, searched in order; the one found can be changed through what's given
 *     back.
 * @param name The name, as typed after --: compared exactly, but that a - in it matches a _ in the parameter's, as
 *     Hemera's names have no -, so --ignore-case names ignore_case.
 * @return The parameter, in parameters; null if none has the name.
 */
named_parameter :: fn(parameters: ptr[mut Parameter[..]], name: string) -> ptr[mut Parameter]? {
    for &parameter in parameters^ {
        if same_option(parameter.name, name) {
            return parameter
        }
    }
    return null
}

/**
 * Tell whether a name typed after -- names a parameter: the same bytes, but that a - typed matches a _ in the name.
 *
 * @param parameter The parameter's name, as its manifest has it.
 * @param typed The name typed, without its --.
 * @return True if they match.
 */
same_option :: fn(parameter: string, typed: string) -> bool {
    named :: string_bytes(parameter)
    given :: string_bytes(typed)
    if named.count != given.count {
        return false
    }
    for byte, i in given {
        if i < named.count && byte != named[i] && !(byte == cast[u8]('-') && named[i] == cast[u8]('_')) {
            return false
        }
    }
    return true
}

/**
 * Give a parameter's name as it's typed after --: with a - for each _, as same_option matches it.
 *
 * @param name The parameter's name.
 * @return The name typed, on the heap, never freed; the name itself when it has no _.
 */
option_name :: fn(name: string) -> string {
    bytes :: string_bytes(name)
    changed : u8[..]
    for byte in bytes {
        runtime.array_add(&changed, if byte == cast[u8]('_') { cast[u8]('-') } else { byte })
    }
    if changed.count == 0 {
        return name
    }
    return string_of(&changed[0], changed.count)
}

/**
 * Find the first parameter left that takes an argument by position: a value, a directory or a file not given one yet.
 *
 * @param parameters The program's parameters, searched in order: one that's flagged or has an argument is taken.
 * @return The parameter, in parameters; null if none is left.
 */
next_positional :: fn(parameters: ptr[mut Parameter[..]]) -> ptr[mut Parameter]? {
    for &parameter in parameters^ {
        if (parameter.argument is_none) && !parameter.flag && (parameter.giving == .Value || parameter.giving == .Dir || parameter.giving == .File
            || parameter.giving == .ReadOnlyFile) {
            return parameter
        }
    }
    return null
}

/**
 * Tell whether an argument is the bare word true or false, so it's a bool's --name's value, not the next argument.
 *
 * @param node The argument; null for none.
 * @return True for a Word of true or false.
 */
is_bool_word :: fn(node: ptr[mut Node]?) -> bool {
    found :: node or_return false
    return found.kind == .Word && (found.text == "true" || found.text == "false")
}

// ---- Values

/**
 * Write a parameter's value as its entry reads it, from its argument: a bare word read by its type, anything else
 * evaluated.
 *
 * It fails for a parameter that's needed and given nothing, an argument whose evaluation fails, or a value that can't
 * be written as its type.
 *
 * @param shell The shell, which evaluates the argument.
 * @param manifest The program's manifest, which the parameter's type is in; only read.
 * @param tree The Call node, for errors.
 * @param parameter The parameter, a value's, matched.
 * @return The value's bytes, laid out as std/schema's write_value lays them out, from the heap, the caller's; null for
 *     an optional parameter given nothing. A bool given nothing is false.
 */
value_for :: fn(shell: ptr[mut Shell], manifest: ptr[schema.Schema], tree: ptr[Node], parameter: ptr[Parameter]) -> Result[u8[..]?, EvalError] {
    held :: schema.type_in(manifest, parameter.held) or_return .Error(EvalError.{message = "its manifest is cut short", at = tree.at})
    given : Value = .Null
    bare := false
    at := tree.at
    match parameter.argument {
        case Some(argument) => {
            at = argument.at
            if argument.kind == .Word {
                given = .Text(argument.text)
                bare = true
            }
            else {
                given = evaluate(shell, argument)?
            }
        }
        case None => {
            if parameter.flag {
                given = .Bool(true)
            }
            else if parameter.optional {
                return .Ok(null)
            }
            else if held.kind == .Boolean {
                given = .Bool(false)
            }
            else {
                return .Error(EvalError.{message = message("% needs its % (%)", tree.text, parameter.name, type_text(manifest, parameter.held)),
                    at = tree.at})
            }
        }
    }
    bytes : u8[..]
    zero(&bytes, cast[usize](held.size))
    match encode(manifest, parameter.held, given, bare, &bytes, 0) {
        case Some(problem) => {
            runtime.array_free(&bytes)
            return .Error(EvalError.{message = message("--%: %", parameter.name, problem), at = at})
        }
        case None => return .Ok(bytes)
    }
}

// ---- Grants

/**
 * Make a parameter's grant: a connection to the shell's terminal, the shell's directory for here given nothing, or a
 * directory or file beneath its home from a path given.
 *
 * It fails for one that's needed and given nothing, a grant the shell can't make, an argument that isn't a path, or a
 * path that can't be opened; a path with nothing there, whose name matches an entry's but for case or spaces at its
 * ends, says so (meant_path).
 *
 * @param shell The shell, whose terminal and home the grants come from.
 * @param tree The Call node, for errors.
 * @param parameter The parameter, a grant's, matched.
 * @param background Whether the program runs in the background, where it isn't given the terminal.
 * @return The grant's handle, the caller's, which a launch gives the program; null for an optional one given nothing,
 *     and for an optional terminal in the background. A terminal it needs there is an error.
 */
grant_for :: fn(shell: ptr[mut Shell], tree: ptr[Node], parameter: ptr[Parameter], background: bool) -> Result[slop_os.Handle?, EvalError] {
    budget :: slop_os.startup_block().budget
    if parameter.giving == .Terminal && background {
        if parameter.optional {
            return .Ok(null)
        }
        return .Error(EvalError.{message = message("% needs the terminal, which a job in the background hasn't: run it without &", tree.text),
            at = tree.at})
    }
    if parameter.giving == .Terminal {
        made :: protocol.connect(shell.console.end, shell.console.port, budget) or_return .Error(EvalError.{
            message = "there's no memory for its terminal connection", at = tree.at})
        return .Ok(cast[slop_os.Handle](made.end))
    }
    argument :: match parameter.argument {
        case Some(given) => given
        case None => {
            if parameter.giving == .Here {
                made :: opened_beneath_home(shell, ".", .Dir)
                return match made {
                    case Ok(handle) => .Ok(handle)
                    case Error(problem) => .Error(EvalError.{message = message("its directory: %", problem), at = tree.at})
                }
            }
            if parameter.optional {
                return .Ok(null)
            }
            if parameter.giving == .Other {
                return .Error(EvalError.{message = message("% needs a %, which the shell can't give", tree.text, parameter.name), at = tree.at})
            }
            return .Error(EvalError.{message = message("% needs its % (a path)", tree.text, parameter.name), at = tree.at})
        }
    }
    path := ""
    if argument.kind == .Word {
        path = argument.text
    }
    else {
        got :: evaluate(shell, argument)?
        match got {
            case Path(text) => path = text
            case Text(text) => path = text
            case _ => return .Error(EvalError.{message = message("--% takes a path, not %", parameter.name, type_name(got)), at = argument.at})
        }
    }
    made :: opened_beneath_home(shell, path, if parameter.giving == .Here { Giving.Dir } else { parameter.giving })
    match made {
        case Ok(handle) => return .Ok(handle)
        case Error(problem) => {
            // Nothing there, but a name that looks the same: said (paths.hsc)
            if problem == file_problem(.NotFound) && parameter.giving != .File {
                match meant_path(shell, path) {
                    case Some(meant) => return .Error(EvalError.{message = message("%1: %2; did you mean %3?", path, problem, meant), at = argument.at})
                    case None => {}
                }
            }
            return .Error(EvalError.{message = message("%: %", path, problem), at = argument.at})
        }
    }
}

/**
 * Open a path, from the shell's directory or its home (resolve_path), as a directory or file, asking the home's
 * directory and waiting for its answer.
 *
 * It fails, with why as a sentence for a person, without a home, for a path that doesn't resolve, the home itself as a
 * file, or what the directory answers.
 *
 * @param shell The shell, whose home is asked.
 * @param given The path, as written.
 * @param giving Dir, File, made if it isn't there, or ReadOnlyFile; anything else opens it read only.
 * @return The opened end's handle, the caller's to give away or close.
 */
opened_beneath_home :: fn(shell: ptr[mut Shell], given #escaping : string, giving: Giving) -> Result[slop_os.Handle, string] {
    home :: shell.home or_return .Error("the shell has no home to find it in")
    budget :: slop_os.startup_block().budget
    path :: match resolve_path(shell, given) {
        case Ok(resolved) => resolved
        case Error(problem) => return .Error(problem)
    }
    if path.count == 0 {
        if giving != .Dir {
            return .Error("that's a directory")
        }
        made :: dir.connect(home.end, shell.home_port, budget) or_return .Error("there's no memory to open it")
        return .Ok(cast[slop_os.Handle](made.end))
    }
    out := os.Outgoing.{}
    request :: os.begin[dir.Request](&out)
    if giving == .Dir {
        request^ = .OpenDirectory(dir.OpenDirectory.{path = os.append(&out, string_bytes(path))})
    }
    else if giving == .File {
        request^ = .OpenFile(dir.OpenFile.{path = os.append(&out, string_bytes(path)), creation = .Either})
    }
    else {
        request^ = .OpenReadOnlyFile(os.append(&out, string_bytes(path)))
    }
    if dir.send_request(home.end, shell.home_port, &out) is_some {
        return .Error("its directory is gone")
    }
    into := os.Incoming.{}
    loop {
        match dir.receive_response(home.end, shell.home_port, &into, true) {
            case Received => break
            case Failed(error) => return .Error("its directory is gone")
            case _ => return .Error("its directory is gone")
        }
    }
    return match os.message_of[dir.Response](&into)^ {
        case OpenedDirectory(opened) => .Ok(cast[slop_os.Handle](opened.end))
        case OpenedFile(opened) => .Ok(cast[slop_os.Handle](opened.end))
        case OpenedReadOnlyFile(opened) => .Ok(cast[slop_os.Handle](opened.end))
        case Failed(failure) => .Error(file_problem(failure))
        case _ => .Error("its directory couldn't open it")
    }
}

/**
 * Say what a directory's failure means, as a person reads it.
 *
 * @param failure The error a directory answered with; NotFound, NotADirectory, IsADirectory, InvalidPath and ReadOnly
 *     are said in words, any other by its name.
 * @return A sentence for a person; a literal, or the failure's name, on the heap.
 */
file_problem :: fn(failure: files.FileError) -> string {
    return match failure {
        case .NotFound => "there's nothing there"
        case .NotADirectory => "that isn't a directory"
        case .IsADirectory => "that's a directory"
        case .InvalidPath => "that isn't a path the shell can use"
        case .ReadOnly => "that can't be changed"
        case _ => message("%", failure)
    }
}
