package shell

import runtime from "base"
import os from "std"
import schema from "std"
import strings from "std"
import slop_os from "std/os"
import stream from "std/os/slop_os"

/*
 * Pipelines (design/shell.md §4, decisions/0172): a | b | c. Programs next to each other are connected straight: one's
 * Sink[T] named output to the next one's Stream[T] named input, their T checked the same before either starts, and
 * they run together. The shell reads what the last of them writes, each record a value by its manifest's schema, and
 * writes what comes before the first, each value a record. The built-in stages, where, map, sort, take and group, and
 * a value as the first stage, work on those values in the shell, a list, so a filter needs no process.
 */

/** The built-in stages. */
STAGES :: string.["where", "map", "sort", "take", "group"]

is_stage :: fn(tree: ptr[Node]) -> bool {
    if tree.kind != .Call {
        return false
    }
    for each in STAGES {
        if each == tree.text {
            return true
        }
    }
    return false
}

/**
 * Whether a pipeline's element is a program's call: a call that isn't a variable, a built-in, a stage or a function.
 */
is_program :: fn(shell: ptr[Shell], tree: ptr[Node]) -> bool {
    if tree.kind != .Call || is_stage(tree) || tree.text == "print" || tree.text == "exit" || tree.text == "cd" {
        return false
    }
    return (lookup(shell.scope, tree.text) is_none) && (function_named(shell, tree.text) is_none)
}

/** A pipeline's value: what its last stage gives. */
pipeline :: fn(shell: ptr[mut Shell], tree #escaping : ptr[Node]) -> Result[Value, EvalError] {
    current : Value? = null
    at : usize = 0
    loop {
        stage :: child(tree, at) or_break
        if is_stage(stage) {
            given :: current or_return error_at(stage.at, message("% works on what comes before it in a pipeline", stage.text))
            current = run_stage(shell, stage, given)?
            at += 1
            continue
        }
        if is_program(shell, stage) {
            // The programs next to each other, run together
            trees : ptr[Node][..]
            defer runtime.array_free(&trees)
            loop {
                next :: child(tree, at) or_break
                if !is_program(shell, next) {
                    break
                }
                runtime.array_add(&trees, next)
                at += 1
            }
            current = run_programs(shell, trees, current)?
            continue
        }
        if at > 0 {
            return error_at(stage.at, "only a program or a stage takes what comes before it in a pipeline")
        }
        current = evaluate(shell, stage)?
        at += 1
    }
    return .Ok(current or_else Value.Null)
}

// ---- Programs

/**
 * Programs run together, each one's output to the next one's input, given what comes before the first, if anything:
 * what the last one writes, a list, or nothing if it has no output. The first to fail is the error.
 */
run_programs :: fn(shell: ptr[mut Shell], trees: ptr[Node][], given #escaping : Value?) -> Result[Value, EvalError] {
    running := runtime.new(Running)
    running.into = NO_END
    running.from = NO_END
    defer end_running(shell, running)
    for tree in trees {
        runtime.array_add(&running.calls, prepare_call(shell, tree)?)
    }
    // What each one reads and writes, checked before any starts
    previous : ptr[mut Call]? = null
    for call, k in running.calls {
        input :: parameter_giving(call, .Input)
        output :: parameter_giving(call, .Output)
        reads :: k > 0 || (given is_some)
        match input {
            case Some(parameter) => {
                if !reads && !parameter.optional {
                    return error_at(call.tree.at, message("% reads what comes before it in a pipeline: something | %", call.tree.text, call.tree.text))
                }
            }
            case None => {
                if reads {
                    return error_at(call.tree.at, message("% takes nothing from a pipeline", call.tree.text))
                }
            }
        }
        if k + 1 < running.calls.count && (output is_none) {
            return error_at(call.tree.at, message("% writes nothing for what comes after it", call.tree.text))
        }
        match previous {
            case Some(before) => {
                writes :: parameter_giving(before, .Output) or_return error_at(call.tree.at, "it has no output")
                reading :: input or_return error_at(call.tree.at, "it has no input")
                if !same_hash(schema.hash_rooted(&before.manifest, writes.records), schema.hash_rooted(&call.manifest, reading.records)) {
                    return error_at(call.tree.at, message("% writes %, and % reads %", before.tree.text, type_text(&before.manifest, writes.records),
                        call.tree.text, type_text(&call.manifest, reading.records)))
                }
            }
            case None => {}
        }
        previous = call
    }
    // A stream between each two, into the first from the shell, and from the last to the shell
    budget :: slop_os.startup_block().budget
    for call, k in running.calls {
        if k > 0 {
            ends :: stream_ends(budget) or_return error_at(call.tree.at, "there's no memory for its input")
            for before, j in running.calls {
                if j + 1 == k {
                    runtime.array_add(&before.grants, os.NamedGrant.{label = "output", handle = cast[slop_os.Handle](ends.a)})
                }
            }
            runtime.array_add(&call.grants, os.NamedGrant.{label = "input", handle = cast[slop_os.Handle](ends.b)})
        }
        else if (given is_some) && (parameter_giving(call, .Input) is_some) {
            ends :: stream_ends(budget) or_return error_at(call.tree.at, "there's no memory for its input")
            running.into = ends.a
            runtime.array_add(&call.grants, os.NamedGrant.{label = "input", handle = cast[slop_os.Handle](ends.b)})
        }
        if k + 1 == running.calls.count && (parameter_giving(call, .Output) is_some) {
            ends :: stream_ends(budget) or_return error_at(call.tree.at, "there's no memory for its output")
            runtime.array_add(&call.grants, os.NamedGrant.{label = "output", handle = cast[slop_os.Handle](ends.a)})
            running.from = ends.b
        }
    }
    // Started in order, each watched under a key of its own
    for call, k in running.calls {
        match start_call(shell, call, CALL_KEY + cast[u64](k)) {
            case Some(error) => return .Error(error)
            case None => {}
        }
    }
    // What's given written for the first, all of it, without waiting for it to be read; what the last writes, read
    match given {
        case Some(value) => {
            for call, k in running.calls {
                if k == 0 {
                    write_given(running, call, value)?
                }
            }
        }
        case None => {}
    }
    result := Value.Null
    first_error : EvalError? = null
    for call, k in running.calls {
        if k + 1 == running.calls.count && running.from != NO_END {
            match read_output(running, call) {
                case Ok(value) => result = value
                case Error(error) => first_error = error
            }
        }
    }
    // Each waited for; the first that failed is the pipeline's error
    for call in running.calls {
        match wait_call(shell, call) {
            case Some(error) => {
                if first_error is_none {
                    first_error = error
                }
            }
            case None => {}
        }
    }
    match first_error {
        case Some(error) => return .Error(error)
        case None => return .Ok(result)
    }
}

NO_END :: cast[slop_os.Channel](slop_os.NO_HANDLE)

/**
 * Programs running together, on the heap: their calls, and the shell's ends of the streams into the first and from the last.
 */
Running :: struct {
    calls : ptr[mut Call][..],
    into : slop_os.Channel,
    from : slop_os.Channel,
    writer : stream.Writer[stream.Untyped]?,
}

/** What programs running together held, given back, each waited for first if it started. */
end_running :: fn(shell: ptr[mut Shell], running: ptr[mut Running]) {
    match running.writer {
        case Some(writer) => {
            open := writer
            stream.close_writer(&open)
        }
        case None => {
            if running.into != NO_END {
                _ = slop_os.handle_close(cast[slop_os.Handle](running.into))
            }
        }
    }
    if running.from != NO_END {
        _ = slop_os.handle_close(cast[slop_os.Handle](running.from))
    }
    for call in running.calls {
        _ = wait_call(shell, call)
        end_call(call)
    }
    runtime.array_free(&running.calls)
    runtime.free(running)
}

stream_ends :: fn(budget: slop_os.MemoryBudget) -> slop_os.ChannelPair? {
    match slop_os.channel_create(budget, 0, os.protocol_tag[stream.Stream]()) {
        case Ok(pair) => return pair
        case Error(error) => return null
    }
}

same_hash :: fn(a: u8[32], b: u8[32]) -> bool {
    for byte, i in a {
        if i < b.count && byte != b[i] {
            return false
        }
    }
    return true
}

/**
 * What comes before the first program, written for it: each item of a list, or the value alone, as a record of its
 * input's type, into a ring big enough for all of them, so writing never waits for the program to read.
 */
write_given :: fn(running: ptr[mut Running], call: ptr[mut Call], given #escaping : Value) -> Result[Value, EvalError] {
    reading :: parameter_giving(call, .Input) or_return error_at(call.tree.at, "it has no input")
    items :: items_of(given).items
    records :: schema.type_in(&call.manifest, reading.records) or_return error_at(call.tree.at, "its manifest is cut short")
    encoded : u8[..][..]
    defer {
        for &each in encoded {
            runtime.array_free(each)
        }
        runtime.array_free(&encoded)
    }
    total : u64 = 0
    largest : u64 = 0
    for item, i in items {
        bytes : u8[..]
        zero(&bytes, cast[usize](records.size))
        match encode(&call.manifest, reading.records, item, false, &bytes, 0) {
            case Some(problem) => {
                runtime.array_free(&bytes)
                return error_at(call.tree.at, message("item % of what's given to %: %", i + 1, call.tree.text, problem))
            }
            case None => {}
        }
        need :: stream.RECORD_HEADER + stream.padded(cast[u64](bytes.count))
        total += need
        largest = if need > largest { need } else { largest }
        runtime.array_add(&encoded, bytes)
    }
    ring :: (if total > largest { total } else { largest }) * 2 + 4096
    writer := match stream.untyped_writer_on(running.into, schema.hash_rooted(&call.manifest, reading.records), ring, false) {
        case Ok(opened) => opened
        case Error(error) => return error_at(call.tree.at, message("% didn't take what's given to it: %", call.tree.text, error))
    }
    running.writer = writer
    for each in encoded {
        match stream.put(&writer, each) {
            case Some(error) => return error_at(call.tree.at, message("% didn't take what's given to it: %", call.tree.text, error))
            case None => {}
        }
    }
    match stream.end_without_waiting(&writer, 0) {
        case Some(error) => return error_at(call.tree.at, message("% didn't take what's given to it: %", call.tree.text, error))
        case None => {}
    }
    running.writer = writer
    return .Ok(.Null)
}

/** What the last program writes, read: a list of its records as values, by its manifest. */
read_output :: fn(running: ptr[mut Running], call: ptr[mut Call]) -> Result[Value, EvalError] {
    writes :: parameter_giving(call, .Output) or_return error_at(call.tree.at, "it has no output")
    end :: running.from
    running.from = NO_END
    made :: new_list()
    reader := match stream.untyped_reader_on(end, schema.hash_rooted(&call.manifest, writes.records)) {
        case Ok(opened) => opened
        // One that ended without writing anything wrote nothing
        case Error(error) => {
            if error == .Gone {
                _ = slop_os.handle_close(cast[slop_os.Handle](end))
                return .Ok(.List(made))
            }
            _ = slop_os.handle_close(cast[slop_os.Handle](end))
            return error_at(call.tree.at, message("%'s output couldn't be read: %", call.tree.text, error))
        }
    }
    defer stream.close_reader(&reader)
    loop {
        bytes :: stream.next_bytes(&reader) or_break
        runtime.array_add(&made.items, decode(&call.manifest, writes.records, bytes, 0, 0))
    }
    return .Ok(.List(made))
}

// ---- Records as values

/**
 * A value of the type at place, at `at` in a record's bytes (as std/schema's write_value writes one), as the shell's:
 * integers, bools, text, an enum's member's name, a duration, a record of a struct's fields, an optional's value or
 * null, and a list of an array's items. Text is copied: the record's bytes are the stream's.
 */
decode :: fn(manifest: ptr[schema.Schema], place: usize, bytes: u8[], at: usize, depth: usize) -> Value {
    type :: schema.type_in(manifest, schema.unaliased_place(manifest, place)) or_return Value.Null
    size :: cast[usize](type.size)
    if depth > 16 {
        return .Null
    }
    if type.kind == .Integer {
        bits :: number_in(bytes, at, size)
        if type.is_signed && size < 8 && size > 0 {
            shift :: 64 - 8 * cast[u64](size)
            return .Int(cast[i64](bits << shift) >> shift)
        }
        return .Int(cast[i64](bits))
    }
    if type.kind == .Boolean {
        return .Bool(number_in(bytes, at, size) != 0)
    }
    if type.kind == .String && !type.is_raw {
        count :: cast[usize](number_in(bytes, at, 8))
        distance :: cast[usize](number_in(bytes, at + 8, 8))
        return .Text(text_in(bytes, distance, count))
    }
    if type.kind == .Enum {
        value :: number_in(bytes, at, size)
        for constant in type.constants {
            if constant.value == value {
                return .Text(strings.clone(constant.name) or_else "")
            }
        }
        return .Int(cast[i64](value))
    }
    if type.kind == .Struct && type.name == "Duration" {
        nanoseconds := cast[i64](0)
        for member in type.members {
            if member.name == "seconds" {
                nanoseconds += cast[i64](number_in(bytes, at + cast[usize](member.offset), 8)) * 1000000000
            }
            else if member.name == "nanos" {
                nanoseconds += cast[i64](number_in(bytes, at + cast[usize](member.offset), 4))
            }
        }
        return .Duration(nanoseconds)
    }
    if type.kind == .Struct && !type.is_union {
        made :: new_record()
        for member in type.members {
            member_type :: schema.type_in(manifest, member.type) or_continue
            if member_type.size == 0 {
                continue
            }
            set_field(made, strings.clone(member.name) or_else "", decode(manifest, member.type, bytes, at + cast[usize](member.offset), depth + 1))
        }
        return .Record(made)
    }
    if type.kind == .Union {
        tag_size :: match schema.type_in(manifest, type.tag) {
            case Some(tag) => cast[usize](tag.size)
            case None => cast[usize](0)
        }
        tag :: cast[usize](number_in(bytes, at, tag_size))
        for variant, index in type.variants {
            if index != tag {
                continue
            }
            if variant.name == "None" {
                return .Null
            }
            for held in variant.held {
                inner :: decode(manifest, held.type, bytes, at + cast[usize](held.offset), depth + 1)
                if variant.name == "Some" {
                    return inner
                }
                made :: new_record()
                set_field(made, strings.clone(variant.name) or_else "", inner)
                return .Record(made)
            }
            return .Text(strings.clone(variant.name) or_else "")
        }
        return .Null
    }
    if type.kind == .Array && type.dimensions.count == 1 {
        element :: schema.type_in(manifest, type.base) or_return Value.Null
        element_size :: cast[usize](element.size)
        made :: new_list()
        for dimension in type.dimensions {
            count := cast[usize](dimension.count)
            start := at
            if dimension.kind != .Static {
                count = cast[usize](number_in(bytes, at, 8))
                start = cast[usize](number_in(bytes, at + 8, 8))
            }
            if element_size == 0 || count > bytes.count / element_size {
                return .List(made)
            }
            for i in 0..<count {
                runtime.array_add(&made.items, decode(manifest, type.base, bytes, start + i * element_size, depth + 1))
            }
        }
        return .List(made)
    }
    if type.kind == .Pointer {
        distance :: cast[usize](number_in(bytes, at, 8))
        if distance == 0 || type.base == schema.NOWHERE {
            return .Null
        }
        return decode(manifest, type.base, bytes, distance, depth + 1)
    }
    return .Null
}

/** count bytes at `at`, little-endian; 0 if they aren't all there. */
number_in :: fn(bytes: u8[], at: usize, count: usize) -> u64 {
    if count > 8 || at > bytes.count || count > bytes.count - at {
        return 0
    }
    result : u64 = 0
    for i in 0..<count {
        result |= cast[u64](bytes[(at + i) % bytes.count]) << (8 * cast[u64](i))
    }
    return result
}

/** count bytes at `at`, as text of the shell's own; "" if they aren't all there. */
text_in :: fn(bytes: u8[], at: usize, count: usize) -> string {
    if count == 0 || at >= bytes.count || count > bytes.count - at {
        return ""
    }
    return strings.clone(string_of(&bytes[at], count)) or_else ""
}

// ---- The built-in stages

/** A built-in stage's value, from what came before it. */
run_stage :: fn(shell: ptr[mut Shell], stage #escaping : ptr[Node], given #escaping : Value) -> Result[Value, EvalError] {
    items :: items_of(given).items
    made :: new_list()
    if stage.text == "where" || stage.text == "map" {
        expression :: first_child(stage) or_return error_at(stage.at, message("% needs an expression after it", stage.text))
        for item in items {
            value :: of_item(shell, item, expression)?
            if stage.text == "map" {
                runtime.array_add(&made.items, value)
                continue
            }
            match value {
                case Bool(keep) => if keep {
                    runtime.array_add(&made.items, item)
                }
                case _ => return error_at(expression.at, message("where needs true or false, not %", type_name(value)))
            }
        }
        return .Ok(.List(made))
    }
    if stage.text == "take" {
        count :: stage_number(shell, stage)?
        for item, i in items {
            if cast[i64](i) < count {
                runtime.array_add(&made.items, item)
            }
        }
        return .Ok(.List(made))
    }
    if stage.text == "sort" {
        return sorted(shell, stage, items)
    }
    return grouped(shell, stage, items)
}

/** What a stage works on: a list's items, nothing for null, or a value alone. */
items_of :: fn(given #escaping : Value) -> ptr[mut ValueList] {
    match given {
        case List(list) => return list
        case Null => return new_list()
        case _ => {
            made :: new_list()
            runtime.array_add(&made.items, given)
            return made
        }
    }
}

/** An expression's value for one item: its fields bound as names, and the item itself as it. */
of_item :: fn(shell: ptr[mut Shell], item #escaping : Value, expression #escaping : ptr[Node]) -> Result[Value, EvalError] {
    scope := runtime.new(Scope)
    scope.parent = shell.scope
    match item {
        case Record(record) => {
            for name, i in record.names {
                if i < record.values.count {
                    bind(scope, name, record.values[i])
                }
            }
        }
        case _ => {}
    }
    bind(scope, "it", item)
    outer :: shell.scope
    shell.scope = scope
    result :: evaluate(shell, expression)
    shell.scope = outer
    return result
}

/** take's count: its one argument, a whole number. */
stage_number :: fn(shell: ptr[mut Shell], stage: ptr[Node]) -> Result[i64, EvalError] {
    argument :: first_child(stage) or_return .Error(EvalError.{message = "take needs how many", at = stage.at})
    value :: if argument.kind == .Word { word_as("int", argument.text) or_else Value.Null } else { evaluate(shell, argument)? }
    match value {
        case Int(count) => return .Ok(count)
        case _ => return .Error(EvalError.{message = message("take needs a whole number, not %", argument.text), at = argument.at})
    }
}

/** The field a stage's first word names, and whether --descending follows: "" for the items themselves. */
stage_field :: fn(stage: ptr[Node]) -> (field : string, descending : bool) {
    field := ""
    descending := false
    for argument in stage.children {
        if argument.kind == .Named && argument.text == "descending" {
            descending = true
        }
        else if argument.kind == .Word {
            field = argument.text
        }
    }
    return field, descending
}

/** An item's field by name, or the item for "". */
key_of :: fn(item: Value, name: string) -> Value {
    if name.count == 0 {
        return item
    }
    match item {
        case Record(record) => return field(record, name) or_else Value.Null
        case _ => return .Null
    }
}

/**
 * sort [field] [--descending]: the items in order, by the field, or by themselves; those that don't compare stay put.
 */
sorted :: fn(shell: ptr[mut Shell], stage: ptr[Node], items #escaping : Value[]) -> Result[Value, EvalError] {
    field, descending :: stage_field(stage)
    made :: new_list()
    for item in items {
        // Insertion: after every item it doesn't come before
        position := made.items.count
        for placed, i in made.items {
            order :: compare(key_of(item, field), key_of(placed, field)) or_else 0
            if (if descending { order > 0 } else { order < 0 }) {
                position = i
                break
            }
        }
        // The list again, with it in its place
        next : Value[..]
        for placed, i in made.items {
            if i == position {
                runtime.array_add(&next, item)
            }
            runtime.array_add(&next, placed)
        }
        if position >= made.items.count {
            runtime.array_add(&next, item)
        }
        runtime.array_free(&made.items)
        made.items = next
    }
    return .Ok(.List(made))
}

/**
 * group field: a record for each of the field's values, in the order they first come: the value, how many, and the items.
 */
grouped :: fn(shell: ptr[mut Shell], stage: ptr[Node], items #escaping : Value[]) -> Result[Value, EvalError] {
    name, descending :: stage_field(stage)
    if name.count == 0 {
        return error_at(stage.at, "group needs the field to group by")
    }
    keys : Value[..]
    defer runtime.array_free(&keys)
    made :: new_list()
    for item in items {
        key :: key_of(item, name)
        found := made.items.count
        for each, i in keys {
            if (compare(each, key) or_else 1) == 0 {
                found = i
            }
        }
        if found >= made.items.count {
            group :: new_record()
            set_field(group, name, key)
            set_field(group, "count", .Int(0))
            set_field(group, "items", .List(new_list()))
            runtime.array_add(&keys, key)
            runtime.array_add(&made.items, Value.Record(group))
            found = made.items.count - 1
        }
        match made.items[found % made.items.count] {
            case Record(group) => {
                match field(group, "items") {
                    case Some(list) => match list {
                        case List(held) => runtime.array_add(&held.items, item)
                        case _ => {}
                    }
                    case None => {}
                }
                match field(group, "count") {
                    case Some(count) => match count {
                        case Int(number) => set_field(group, "count", .Int(number + 1))
                        case _ => {}
                    }
                    case None => {}
                }
            }
            case _ => {}
        }
    }
    return .Ok(.List(made))
}
