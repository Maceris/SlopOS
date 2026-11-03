package shell

import runtime from "base"
import os from "std"
import schema from "std"
import strings from "std"
import text_buffer from "std"
import slop_os from "std/os"
import process_manager from "std/os/slop_os"
import lifecycle from "std/os/slop_os"
import dir from "std/os/slop_os"
import files from "std/os/slop_os"
import terminal as protocol from "std/os/slop_os"
import programs from "../../protocols/programs"

/*
 * Calls to programs through their manifests (design/shell.md §3, decisions/0170): the program found in the bundle
 * store's boot root by its name, its manifest read, each argument matched to a parameter by position or --name and read
 * by the parameter's type, the grants its types ask for made, and the values written as its entry reads them; then it's
 * launched in a process of the shell's and waited for. Its exit code is its error, if it isn't 0. Its records, a
 * Sink[T] parameter named output, are its value, read by the shell; a Stream[T] named input reads what comes before it
 * in a pipeline (decisions/0172).
 */

// What a program the shell runs is given to run on, split off the shell's budget.
PROGRAM_BUDGET : u64 : 4 * 1024 * 1024
// The key the first program of a call or a pipeline has its end watched under, on the shell's port, the next ones after it
CALL_KEY : u64 : 1

// What a parameter is given: a value written for it, or a grant of one of the kinds the shell can make.
Giving :: enum {
    Value,
    // A connection to the shell's terminal, without an argument
    Terminal,
    // A directory, a file to write, or one only to read, beneath the shell's home, from a path
    Dir,
    File,
    ReadOnlyFile,
    // A pipeline's records: the Stream[T] named input reads what comes before it, and the Sink[T] named output writes
    // for what comes after it, or for the shell
    Input,
    Output,
    // A grant the shell doesn't make: a parameter that's optional goes without it
    Other,
}

// One of a program's parameters, as its manifest has it, and what it's given.
Parameter :: struct {
    name : string,
    // Its type's place in the manifest, and the type it holds if it's optional, or its type again
    type : usize,
    held : usize,
    optional : bool,
    // Whether it's a bool, whose --name alone is true
    is_bool : bool,
    giving : Giving,
    // An input's or output's records' type's place
    records : usize,
    // The argument given for it, and for a bool's --name alone, true
    argument : ptr[Node]?,
    flag : bool,
}

// A call of a program, alone: a pipeline of one.
run_program :: fn(shell: ptr[mut Shell], tree #escaping : ptr[Node]) -> Result[Value, EvalError] {
    trees : ptr[Node][..]
    defer runtime.array_free(&trees)
    runtime.array_add(&trees, tree)
    return run_programs(shell, trees, null)
}

/*
 * A call made ready to start, on the heap: its program found, its manifest read, its arguments matched, and its values
 * and grants made, but its input's and output's, which its pipeline makes.
 */
prepare_call :: fn(shell: ptr[mut Shell], tree #escaping : ptr[Node]) -> Result[ptr[mut Call], EvalError] {
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
            match grant_for(shell, tree, parameter)? {
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

// A call being made, on the heap: its program's manifest, its parameters, and the grants and values made for them.
Call :: struct {
    tree : ptr[Node],
    executable : slop_os.Memory,
    manifest : schema.Schema,
    parameters : Parameter[..],
    grants : os.NamedGrant[..],
    values : os.NamedValue[..],
    written : u8[..][..],
    // Whether the program started, which made the grants its, and whether its end's been seen
    started : bool,
    waited : bool,
    // Once it's started: the key its end's watched under, its process and budget, and its lifecycle channel's end
    key : u64,
    launched : os.Launched,
    lifecycle : slop_os.Channel,
}

// A call's parameter that's given giving, if it has one.
parameter_giving :: fn(call: ptr[Call], giving: Giving) -> ptr[Parameter]? {
    for &parameter in call.parameters {
        if parameter.giving == giving {
            return parameter
        }
    }
    return null
}

// A call's memory and handles given back, and its grants, if its program didn't start.
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

// A call's program launched, its end watched under key: why it didn't start, or null.
start_call :: fn(shell: ptr[mut Shell], call: ptr[mut Call], key: u64) -> EvalError? {
    tree :: call.tree
    manager :: shell.manager or_return EvalError.{message = "the shell can't start programs: it has no process manager", at = tree.at}
    block :: slop_os.startup_block()
    ends :: lifecycle.make(block.budget) or_return EvalError.{message = "there's no memory to start it", at = tree.at}
    options := os.LaunchOptions.{watch = os.LaunchWatch.{port = shell.port, key = key}, lifecycle = ends.b}
    options.clock = copy_of_grant("clock")
    options.locale = copy_of_grant("locale")
    match os.launch_named(manager, shell.manager_port, tree.text, call.executable, PROGRAM_BUDGET, call.grants, call.values, options) {
        case Ok(made) => {
            call.started = true
            call.launched = made
            call.lifecycle = ends.a
            call.key = key
            return null
        }
        case Error(error) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](ends.a))
            return EvalError.{message = message("% didn't start: %", tree.text, error), at = tree.at}
        }
    }
}

// A started call's program waited for: its error, if it didn't end with 0.
wait_call :: fn(shell: ptr[mut Shell], call: ptr[mut Call]) -> EvalError? {
    if !call.started || call.waited {
        return null
    }
    ended :: wait_for(shell, call.key)
    call.waited = true
    _ = slop_os.port_unbind(shell.port, call.key)
    tree :: call.tree
    if ended == 0 {
        return null
    }
    if ended == slop_os.EXIT_KILLED {
        return EvalError.{message = message("% was ended", tree.text), at = tree.at}
    }
    return EvalError.{message = message("% ended with %", tree.text, ended), at = tree.at}
}

// A program's end seen on the shell's port, by the key it's watched under, and its code.
EndedProgram :: struct {
    key : u64,
    code : u64,
}

// How the program watched under key ended, once it has; the ends of others seen meanwhile kept for their turn.
wait_for :: fn(shell: ptr[mut Shell], key: u64) -> u64 {
    loop {
        for each, i in shell.ended {
            if each.key == key {
                code :: each.code
                runtime.array_remove(&shell.ended, i)
                return code
            }
        }
        packets : slop_os.Packet[4]
        taken :: slop_os.port_wait(shell.port, packets, slop_os.NO_DEADLINE) or_else 0
        for packet, i in packets {
            if i < cast[usize](taken) && packet.kind == .Signal {
                runtime.array_add(&shell.ended, EndedProgram.{key = packet.key, code = packet.data[1]})
            }
        }
    }
}

// A copy of one of the shell's own grants, labeled label, for a program it runs: the clock page, its locale's.
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

// A program by its name, from the session manager: its executable and manifest, or null.
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
            case _ => continue
        }
    }
    return match os.message_of[programs.Response](&into)^ {
        case Found(program) => program
        case _ => null
    }
}

// A program's manifest, read from its memory: null if it isn't a schema.
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

// A parameter, as its manifest has it: what it's given, by its type.
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

// An optional's Some type, if the type at place is an optional: a union of None and Some(T), not a pointer's.
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

// What a parameter of the type at place is given: a grant if it's a handle's type, by its name, or a value.
giving_of :: fn(manifest: ptr[schema.Schema], place: usize) -> Giving {
    type :: schema.type_in(manifest, place) or_return Giving.Other
    if type.size != 4 || (type.kind != .Struct && type.kind != .Alias) {
        return .Value
    }
    kind := type.name
    inner := ""
    for character, i in type.name {
        if character == '[' {
            kind = slice(type.name, 0, i)
            inner = slice(type.name, i + 1, type.name.count - 1)
            break
        }
    }
    if runtime.slop_os_kind_of(kind) == 0 {
        return .Value
    }
    // The protocol's own name, without its package
    for character, i in inner {
        if character == '.' {
            inner = slice(inner, i + 1, inner.count)
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

// The place of the type of the records a Stream[T] or Sink[T] reads or writes: its records member's elements'.
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

/*
 * Each argument matched to a parameter: --name to the parameter of that name, the argument after it its value but for a
 * bool's, which is true alone; the rest in order to the parameters left that take arguments, the terminal not among them.
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

named_parameter :: fn(parameters: ptr[mut Parameter[..]], name: string) -> ptr[mut Parameter]? {
    for &parameter in parameters^ {
        if parameter.name == name {
            return parameter
        }
    }
    return null
}

// The first parameter left that takes an argument by position.
next_positional :: fn(parameters: ptr[mut Parameter[..]]) -> ptr[mut Parameter]? {
    for &parameter in parameters^ {
        if (parameter.argument is_none) && !parameter.flag && (parameter.giving == .Value || parameter.giving == .Dir || parameter.giving == .File
            || parameter.giving == .ReadOnlyFile) {
            return parameter
        }
    }
    return null
}

is_bool_word :: fn(node: ptr[mut Node]?) -> bool {
    found :: node or_return false
    return found.kind == .Word && (found.text == "true" || found.text == "false")
}

// ---- Values

/*
 * A parameter's value, written as its entry reads it: null for an optional one given nothing, a bool given nothing
 * false, and an error for one that's needed and missing or can't be read as its type.
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

/*
 * A value written at offset in out as a value of the type at place is laid out, with what it points to added after
 * everything (std/schema's write_value: a string's bytes, a list's items, at their distance from the start): why it
 * can't be, or null. A bare word is read by the type: a number, a member's name, a duration, or text.
 */
encode :: fn(manifest: ptr[schema.Schema], place: usize, given: Value, bare: bool, out: ptr[mut u8[..]], offset: usize) -> string? {
    unaliased :: schema.unaliased_place(manifest, place)
    type :: schema.type_in(manifest, unaliased) or_return "its manifest is cut short"
    size :: cast[usize](type.size)
    if type.kind == .Integer {
        number := cast[i64](0)
        match given {
            case Int(value) => number = value
            case Size(value) => number = cast[i64](value)
            case Text(text) => {
                if !bare {
                    return message("% isn't a number", type_text(manifest, place))
                }
                number = integer_of(text) or_return message("% isn't a number", text)
            }
            case _ => return message("it takes a number, not %", type_name(given))
        }
        if !type.is_signed && number < 0 {
            return message("% can't be below 0", number)
        }
        if size < 8 {
            bits :: 8 * cast[u64](size)
            limit :: if type.is_signed { cast[i64](1) << (bits - 1) } else { cast[i64](1) << bits }
            low :: if type.is_signed { 0 - limit } else { cast[i64](0) }
            if number >= limit || number < low {
                return message("% is too big for it", number)
            }
        }
        put(out, offset, cast[u64](number), size)
        return null
    }
    if type.kind == .Boolean {
        match given {
            case Bool(value) => put(out, offset, if value { cast[u64](1) } else { cast[u64](0) }, size)
            case Text(text) => {
                if !bare || (text != "true" && text != "false") {
                    return message("it takes true or false, not %", text)
                }
                put(out, offset, if text == "true" { cast[u64](1) } else { cast[u64](0) }, size)
            }
            case _ => return message("it takes true or false, not %", type_name(given))
        }
        return null
    }
    if type.kind == .String && !type.is_raw {
        text :: match given {
            case Text(value) => value
            case Path(value) => value
            case _ => return message("it takes text, not %", type_name(given))
        }
        put(out, offset, cast[u64](text.count), 8)
        put(out, offset + 8, cast[u64](tail(out, string_bytes(text))), 8)
        return null
    }
    if type.kind == .Enum {
        name :: match given {
            case Text(value) => value
            case _ => return message("it takes one of %'s members, not %", type.name, type_name(given))
        }
        for constant in type.constants {
            if constant.name == name {
                put(out, offset, constant.value, size)
                return null
            }
        }
        return message("% isn't one of %", name, members_text(type))
    }
    if type.kind == .Struct && type.name == "Duration" {
        nanoseconds := cast[i64](0)
        match given {
            case Duration(value) => nanoseconds = value
            case Text(text) => {
                if !bare {
                    return message("% isn't a duration, like 5s", text)
                }
                nanoseconds = duration_of(text) or_return message("% isn't a duration, like 5s", text)
            }
            case _ => return message("it takes a duration, like 5s, not %", type_name(given))
        }
        for member in type.members {
            if member.name == "seconds" {
                put(out, offset + cast[usize](member.offset), cast[u64](nanoseconds / 1000000000), 8)
            }
            else if member.name == "nanos" {
                put(out, offset + cast[usize](member.offset), cast[u64](nanoseconds % 1000000000), 4)
            }
        }
        return null
    }
    if type.kind == .Struct && !type.is_union {
        record :: match given {
            case Record(value) => value
            case _ => return message("it takes a record of %'s fields, not %", type.name, type_name(given))
        }
        for member in type.members {
            value :: field(record, member.name) or_return message("the record has no field %", member.name)
            problem :: encode(manifest, member.type, value, false, out, offset + cast[usize](member.offset))
            if problem is_some {
                return problem
            }
        }
        return null
    }
    if type.kind == .Union {
        // An optional's Some, written with its tag
        for variant, index in type.variants {
            if variant.name != "Some" || variant.held.count != 1 {
                continue
            }
            for held in variant.held {
                tag_size :: match schema.type_in(manifest, type.tag) {
                    case Some(tag) => cast[usize](tag.size)
                    case None => cast[usize](0)
                }
                put(out, offset, cast[u64](index), tag_size)
                return encode(manifest, held.type, given, bare, out, offset + cast[usize](held.offset))
            }
        }
        return message("the shell can't give a %", type_text(manifest, place))
    }
    if type.kind == .Array && type.dimensions.count == 1 {
        for dimension in type.dimensions {
            if dimension.kind != .View {
                break
            }
            list :: match given {
                case List(value) => value
                case _ => return message("it takes a list, not %", type_name(given))
            }
            element :: schema.type_in(manifest, type.base) or_return "its manifest is cut short"
            element_size :: cast[usize](element.size)
            start :: out.count
            zero(out, element_size * list.items.count)
            align(out)
            put(out, offset, cast[u64](list.items.count), 8)
            put(out, offset + 8, cast[u64](start), 8)
            for item, i in list.items {
                problem :: encode(manifest, type.base, item, false, out, start + i * element_size)
                if problem is_some {
                    return problem
                }
            }
            return null
        }
    }
    return message("the shell can't give a %", type_text(manifest, place))
}

// A number written at offset, its low count bytes, little-endian.
put :: fn(out: ptr[mut u8[..]], offset: usize, value: u64, count: usize) {
    target : mut u8[] = out^
    for i in cast[usize](0)..<count {
        at :: offset + i
        if at < target.count && i < 8 {
            target[at] = cast[u8]((value >> (8 * cast[u64](i))) & 0xff)
        }
    }
}

// Bytes added after everything, at 8 bytes' alignment: where they start.
tail :: fn(out: ptr[mut u8[..]], bytes: u8[]) -> usize {
    align(out)
    start :: out.count
    for byte in bytes {
        runtime.array_add(out, byte)
    }
    align(out)
    return start
}

zero :: fn(out: ptr[mut u8[..]], count: usize) {
    for i in cast[usize](0)..<count {
        runtime.array_add(out, cast[u8](0))
    }
}

align :: fn(out: ptr[mut u8[..]]) {
    loop {
        if out.count % 8 == 0 {
            break
        }
        runtime.array_add(out, cast[u8](0))
    }
}

// A word read as a whole number, in decimal, with a sign if it has one.
integer_of :: fn(text: string) -> i64? {
    if text.count == 0 {
        return null
    }
    negative :: slice(text, 0, 1) == "-"
    digits :: if negative { slice(text, 1, text.count) } else { text }
    if digits.count == 0 || digits.count > 18 {
        return null
    }
    result := cast[i64](0)
    for character in digits {
        if character < '0' || character > '9' {
            return null
        }
        result = result * 10 + cast[i64](cast[u8](character) - cast[u8]('0'))
    }
    return if negative { 0 - result } else { result }
}

// A word read as a duration, a number then its unit (5s, 250ms): nanoseconds.
duration_of :: fn(text: string) -> i64? {
    for character, i in text {
        if character < '0' || character > '9' {
            number :: integer_of(slice(text, 0, i)) or_return null
            unit :: unit_value(slice(text, i, text.count)) or_return null
            if unit.size {
                return null
            }
            return number * cast[i64](unit.scale)
        }
    }
    return null
}

// A type as a person reads it: its name, or its kind.
type_text :: fn(manifest: ptr[schema.Schema], place: usize) -> string {
    type :: schema.type_in(manifest, place) or_return "value"
    if type.name.count > 0 {
        return type.name
    }
    return match type.kind {
        case .Integer => if type.is_signed { "whole number" } else { "count" }
        case .Boolean => "bool"
        case .String => "string"
        case .Array => "list"
        case .Union => "choice"
        case _ => "value"
    }
}

// An enum's members, as a list to read: a, b or c.
members_text :: fn(type: ptr[schema.Type]) -> string {
    storage : u8[256]
    out := text_buffer.make(storage)
    for constant, i in type.constants {
        if i > 0 {
            text_buffer.append(&out, if i + 1 == type.constants.count { " or " } else { ", " })
        }
        text_buffer.append(&out, constant.name)
    }
    return strings.clone(text_buffer.as_string(&out)) or_else type.name
}

// ---- Grants

/*
 * A parameter's grant, made: a connection to the shell's terminal, or a directory or file beneath its home from a path
 * given; null for an optional one given nothing; an error for one that's needed and missing, or can't be made.
 */
grant_for :: fn(shell: ptr[mut Shell], tree: ptr[Node], parameter: ptr[Parameter]) -> Result[slop_os.Handle?, EvalError] {
    budget :: slop_os.startup_block().budget
    if parameter.giving == .Terminal {
        made :: protocol.connect(shell.console.end, shell.console.port, budget) or_return .Error(EvalError.{
            message = "there's no memory for its terminal connection", at = tree.at})
        return .Ok(cast[slop_os.Handle](made.end))
    }
    argument :: match parameter.argument {
        case Some(given) => given
        case None => {
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
    made :: opened_beneath_home(shell, path, parameter.giving)
    return match made {
        case Ok(handle) => .Ok(handle)
        case Error(problem) => .Error(EvalError.{message = message("%: %", path, problem), at = argument.at})
    }
}

// A path, from the shell's directory or its home (resolve_path), opened as giving asks.
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
            case _ => continue
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

// What a directory's failure means, as a person reads it.
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
