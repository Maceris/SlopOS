package shell

import runtime from "base"
import language from "../../shell_language"
import os from "std"
import schema from "std"
import slop_os from "std/os"
import stream from "std/os/slop_os"

/*
 * Pipelines (design/shell.md §4, decisions/0172): a | b | c. Programs next to each other are connected straight:
 * one's Sink[T] named output to the next one's Stream[T] named input, their T checked the same before either starts,
 * and they run together. The shell reads what the last of them writes, each record a value by its manifest's schema,
 * and writes what comes before the first, each value a record. The built-in stages, where, map, sort, take and group,
 * and a value as the first stage, work on those values in the shell, a list, so a filter needs no process.
 */

/** The built-in stages. */
STAGES :: string.["where", "map", "sort", "take", "group"]

/**
 * Tell whether a pipeline's element is a built-in stage.
 *
 * @param tree One of a Pipeline node's children, of any kind; only a Call's name is looked at.
 * @return True for a call named one of STAGES.
 */
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
 * Tell whether a pipeline's element is a program's call: a call that isn't a variable, a built-in (BUILTINS, the stages
 * among them) or a function.
 *
 * @param shell The shell, whose names and functions are looked in.
 * @param tree One of a Pipeline node's children, of any kind; anything but a Call isn't a program's.
 * @return True if it's a program's call; whether there's such a program isn't asked.
 */
is_program :: fn(shell: ptr[Shell], tree: ptr[Node]) -> bool {
    if tree.kind != .Call || (builtin_named(tree.text) is_some) {
        return false
    }
    return (lookup(shell.scope, tree.text) is_none) && (function_named(shell, tree.text) is_none)
}

/**
 * Evaluate a pipeline: programs next to each other run together, built-in stages work on what came before them, and
 * the first element may be any value.
 *
 * It fails with the first error a stage or program meets, for a stage with nothing before it, or for an element after
 * the first that's neither a program nor a stage.
 *
 * @param shell The shell: its scope and functions say what each element is, and it runs the programs and evaluates
 *     the rest, as run_programs, run_stage and evaluate do.
 * @param tree The Pipeline node, its elements its children.
 * @return What its last stage gives; Null for a pipeline of nothing.
 */
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
 * Run programs together in the foreground, each one's output to the next one's input, given what comes before the
 * first, if anything: started (start_programs), then finished (finish_programs), Ctrl-C stopping them meanwhile.
 * Everything they held is given back before this returns.
 *
 * @param shell The shell, whose process manager, home and programs connection the programs are prepared and started
 *     through, and whose port their ends are watched on; it waits on that port until every one has ended.
 * @param trees The programs' Call nodes, in order, at least one.
 * @param given What comes before the first, written to its input; null if nothing does.
 * @return What the last one writes, a list of its records as values; Null if it has no output; or why they couldn't
 *     run, or the first program's error, as start_programs and finish_programs say.
 */
run_programs :: fn(shell: ptr[mut Shell], trees: ptr[Node][], given #escaping : Value?) -> Result[Value, EvalError] {
    running :: start_programs(shell, trees, given, false)?
    shell.foreground = running
    defer {
        shell.foreground = null
        end_running(shell, running)
    }
    return finish_programs(shell, running)
}

/**
 * Start programs together, each one's output to the next one's input, and write what's given for the first.
 *
 * Each is prepared, and their inputs and outputs checked, before any starts; then they're started in order, each
 * watched under keys of their own, from the shell's next_key, and what's given is written, without waiting for it to
 * be read.
 *
 * It fails, giving back what it made and waiting for any that started, if there are more than MAX_PROGRAMS, a program
 * can't be prepared or started, one reads from a pipeline and has nothing before it or takes nothing and has, one
 * before another writes nothing, two next to each other write and read different types, or what's given can't be
 * written.
 *
 * @param shell The shell, whose process manager, home and programs connection the programs are prepared and started
 *     through, and whose port their ends are watched on.
 * @param trees The programs' Call nodes, in order, at least one.
 * @param given What comes before the first, written to its input; null if nothing does.
 * @param background Whether they run in the background, where none is given the terminal.
 * @return The programs, on the heap, the caller's to finish and then end with end_running.
 */
start_programs :: fn(shell: ptr[mut Shell], trees: ptr[Node][], given #escaping : Value?, background: bool) -> Result[ptr[mut Running], EvalError] {
    if trees.count > MAX_PROGRAMS {
        return .Error(EvalError.{message = message("a pipeline runs at most % programs", MAX_PROGRAMS), at = 0})
    }
    running := runtime.new(Running)
    running.into = NO_END
    running.from = NO_END
    running.first_key = shell.next_key
    shell.next_key += MAX_PROGRAMS
    started := false
    defer {
        if !started {
            end_running(shell, running)
        }
    }
    for tree in trees {
        match prepare_call(shell, tree, background) {
            case Ok(call) => runtime.array_add(&running.calls, call)
            case Error(error) => return .Error(error)
        }
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
                    return failed_at(call.tree.at, message("% reads what comes before it in a pipeline: something | %", call.tree.text, call.tree.text))
                }
            }
            case None => {
                if reads {
                    return failed_at(call.tree.at, message("% takes nothing from a pipeline", call.tree.text))
                }
            }
        }
        if k + 1 < running.calls.count && (output is_none) {
            return failed_at(call.tree.at, message("% writes nothing for what comes after it", call.tree.text))
        }
        match previous {
            case Some(before) => {
                writes :: parameter_giving(before, .Output) or_return failed_at(call.tree.at, "it has no output")
                reading :: input or_return failed_at(call.tree.at, "it has no input")
                if !same_hash(schema.hash_rooted(&before.manifest, writes.records), schema.hash_rooted(&call.manifest, reading.records)) {
                    return failed_at(call.tree.at, message("% writes %, and % reads %", before.tree.text, type_text(&before.manifest, writes.records),
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
            ends :: stream_ends(budget) or_return failed_at(call.tree.at, "there's no memory for its input")
            for before, j in running.calls {
                if j + 1 == k {
                    runtime.array_add(&before.grants, os.NamedGrant.{label = "output", handle = cast[slop_os.Handle](ends.a)})
                }
            }
            runtime.array_add(&call.grants, os.NamedGrant.{label = "input", handle = cast[slop_os.Handle](ends.b)})
        }
        else if (given is_some) && (parameter_giving(call, .Input) is_some) {
            ends :: stream_ends(budget) or_return failed_at(call.tree.at, "there's no memory for its input")
            running.into = ends.a
            runtime.array_add(&call.grants, os.NamedGrant.{label = "input", handle = cast[slop_os.Handle](ends.b)})
        }
        if k + 1 == running.calls.count && (parameter_giving(call, .Output) is_some) {
            ends :: stream_ends(budget) or_return failed_at(call.tree.at, "there's no memory for its output")
            runtime.array_add(&call.grants, os.NamedGrant.{label = "output", handle = cast[slop_os.Handle](ends.a)})
            running.from = ends.b
        }
    }
    // Started in order, each watched under a key of its own
    for call, k in running.calls {
        match start_call(shell, call, running.first_key + cast[u64](k)) {
            case Some(error) => return .Error(error)
            case None => {}
        }
    }
    // What's given written for the first, all of it, without waiting for it to be read
    match given {
        case Some(value) => {
            for call, k in running.calls {
                if k == 0 {
                    match write_given(running, call, value) {
                        case Ok(_) => {}
                        case Error(error) => return .Error(error)
                    }
                }
            }
        }
        case None => {}
    }
    started = true
    return .Ok(running)
}

/**
 * Make a start's error result.
 *
 * @param at Where in the line, in bytes from 0.
 * @param message What went wrong, kept by the error.
 * @return The error, as start_programs's result.
 */
failed_at :: fn(at: usize, message #escaping : string) -> Result[ptr[mut Running], EvalError] {
    return .Error(EvalError.{message = message, at = at})
}

/**
 * Finish programs started together: what the last writes read, and each waited for, Ctrl-C stopping them meanwhile.
 *
 * It fails if the last one's output can't be read, or with the first program's error, by exit code.
 *
 * @param shell The shell, whose port the programs' ends are waited on until every one has ended.
 * @param running The programs, started; its stream from the last is taken.
 * @return What the last one writes, a list of its records as values; Null if it has no output.
 */
finish_programs :: fn(shell: ptr[mut Shell], running: ptr[mut Running]) -> Result[Value, EvalError] {
    result := Value.Null
    first_error : EvalError? = null
    for call, k in running.calls {
        if k + 1 == running.calls.count && (parameter_giving(call, .Output) is_some) {
            match read_output(shell, running, call) {
                case Ok(value) => result = value
                case Error(error) => first_error = error
            }
        }
    }
    // Each waited for; the first that failed is the pipeline's error
    for call, k in running.calls {
        match wait_call(shell, call, running) {
            case Some(error) => {
                if first_error is_none {
                    first_error = error
                }
            }
            case None => {
                // A last program without an output gives what its entry gave back, if it gave something
                if k + 1 == running.calls.count && (parameter_giving(call, .Output) is_none) {
                    result = call.returned
                }
            }
        }
    }
    match first_error {
        case Some(error) => return .Error(error)
        case None => return .Ok(result)
    }
}

/** No channel: what Running's into and from are without a stream. */
NO_END :: cast[slop_os.Channel](slop_os.NO_HANDLE)

/**
 * Programs running together, on the heap: their calls, the shell's ends of the streams into the first and from the
 * last, and whether they've been asked to stop.
 */
Running :: struct {
    /** The programs' calls, in order, each the Running's to end. */
    calls : ptr[mut Call][..],
    /** The shell's writing end of the stream into the first; NO_END without one. Once writer's open, it's writer's. */
    into : slop_os.Channel,
    /** The shell's reading end of the stream from the last; NO_END without one, or once read_output has taken it. */
    from : slop_os.Channel,
    /** The writer open on into, once what's given is being written; null until then. */
    writer : stream.Writer[stream.Untyped]?,
    /** The key the first program's end is watched under; the next ones' are after it. */
    first_key : u64,
    /**
     * When the programs asked to stop are killed, in the monotonic clock's nanoseconds; 0 until they're asked, and
     * slop_os.NO_DEADLINE once they've been killed.
     */
    stop_by : u64,
    /** The reader open on from, once the last program's opened its output; null before, and once it's closed. */
    reader : stream.Reader[stream.Untyped]?,
    /** What the last program has written so far, as values; null until its output's first read. */
    collected : ptr[mut ValueList]?,
    /** Whether the last program's output is read to its end, or couldn't be read; output_error says which. */
    output_done : bool,
    /** Why its output couldn't be read; null if it could, or hasn't been tried. */
    output_error : EvalError?,
}

/**
 * Give back what programs running together held: the stream ends and writer closed, then each call waited for, if it
 * started, Ctrl-C stopping them meanwhile, and ended.
 *
 * @param shell The shell, whose port the programs' ends are waited on.
 * @param running The programs, freed: it can't be used after.
 */
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
        _ = slop_os.port_unbind(watch_port(shell), running.first_key + OUTPUT_KEY)
        _ = slop_os.handle_close(cast[slop_os.Handle](running.from))
    }
    match running.reader {
        case Some(reader) => {
            _ = slop_os.port_unbind(watch_port(shell), running.first_key + OUTPUT_KEY)
            open := reader
            stream.close_reader(&open)
        }
        case None => {}
    }
    for call in running.calls {
        _ = wait_call(shell, call, running)
    }
    for call in running.calls {
        end_call(call)
    }
    runtime.array_free(&running.calls)
    runtime.free(running)
}

/**
 * Make a stream's channel: its two ends, tagged with the stream protocol.
 *
 * @param budget The memory budget that pays for the channel.
 * @return The ends, a the writing end and b the reading end, the caller's; null if the channel couldn't be made.
 */
stream_ends :: fn(budget: slop_os.MemoryBudget) -> slop_os.ChannelPair? {
    match slop_os.channel_create(budget, 0, os.protocol_tag[stream.Stream]()) {
        case Ok(pair) => return pair
        case Error(error) => return null
    }
}

/**
 * Tell whether two schema hashes are the same.
 *
 * @param a A schema's 32-byte hash, as schema.hash_rooted gives it.
 * @param b The hash it's compared with, of the same form; the order doesn't matter.
 * @return True if every byte is the same.
 */
same_hash :: fn(a: u8[32], b: u8[32]) -> bool {
    for byte, i in a {
        if i < b.count && byte != b[i] {
            return false
        }
    }
    return true
}

/**
 * Write what comes before the first program for it: each item of a list, or the value alone, as a record of its
 * input's type, into a ring big enough for all of them, so writing never waits for the program to read.
 *
 * Every item is encoded before anything's written; then the writer is opened on the Running's into, without waiting
 * for the program's answer, the records put, and the stream ended without waiting.
 *
 * It fails if the program has no input, an item can't be written as its input's type, or the stream can't be opened
 * or written.
 *
 * @param running The programs, whose into the writer is opened on and kept in writer, for end_running to close.
 * @param call The first program's call, started.
 * @param given What's given: a list's items, nothing for Null, or a value alone.
 * @return Null.
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
    // The writer as it is after the last put, however this returns, for end_running to close
    defer running.writer = writer
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
    return .Ok(.Null)
}

/**
 * Read what the last program writes, until it ends: a list of its records as values, by its manifest. While the
 * program's slow to open its output or to write, the shell sees to Ctrl-C and progress every ATTEND_EVERY (attend).
 *
 * It fails if the program writes another type than its manifest says, or the stream can't be opened. A program that
 * ended without opening its output wrote nothing.
 *
 * @param shell The shell, which attends to its terminal while it reads.
 * @param running The programs, whose from is taken, and closed once it's read; Ctrl-C stops them.
 * @param call The last program's call, started.
 * @return The records, a list, empty if it wrote nothing.
 */
read_output :: fn(shell: ptr[mut Shell], running: ptr[mut Running], call: ptr[mut Call]) -> Result[Value, EvalError] {
    // Opening waits for the program to open its end, which it may do late: Ctrl-C's seen to meanwhile
    if (running.reader is_none) && running.from != NO_END {
        wait_readable(shell, running, running.from)
    }
    loop {
        if read_some(running, call, (slop_os.clock_monotonic() or_else 0) + ATTEND_EVERY) {
            break
        }
        attend(shell, running)
    }
    match running.output_error {
        case Some(error) => return .Error(error)
        case None => {}
    }
    return .Ok(.List(running.collected or_else new_list()))
}

/**
 * Read what the last program has written, up to a deadline, into the running's collected: its output opened first if
 * it isn't, which waits for the program to open its end.
 *
 * @param running The programs, whose from moves into its reader once it's open, and whose collected, output_done and
 *     output_error change; its reader is closed once its output's read to the end, or can't be.
 * @param call The last program's call, started, whose manifest decodes the records.
 * @param deadline When to stop waiting for more, in the monotonic clock's nanoseconds; one past already reads only
 *     what's there.
 * @return True once the output's read to its end, or couldn't be read; false if more may come.
 */
read_some :: fn(running: ptr[mut Running], call: ptr[mut Call], deadline: u64) -> bool {
    if running.output_done {
        return true
    }
    made :: running.collected or_else new_list()
    running.collected = made
    writes :: match parameter_giving(call, .Output) {
        case Some(found) => found
        case None => {
            running.output_done = true
            return true
        }
    }
    if running.reader is_none {
        end :: running.from
        if end == NO_END {
            running.output_done = true
            return true
        }
        running.from = NO_END
        match stream.untyped_reader_on(end, schema.hash_rooted(&call.manifest, writes.records)) {
            case Ok(opened) => running.reader = opened
            // One that ended without writing anything wrote nothing
            case Error(error) => {
                _ = slop_os.handle_close(cast[slop_os.Handle](end))
                if error != .Gone {
                    running.output_error = EvalError.{message = message("%'s output couldn't be read: %", call.tree.text, error), at = call.tree.at}
                }
                running.output_done = true
                return true
            }
        }
    }
    reader := running.reader or_return true
    defer {
        if running.output_done {
            stream.close_reader(&reader)
            running.reader = null
        }
        else {
            running.reader = reader
        }
    }
    loop {
        match stream.next_bytes_before(&reader, deadline) {
            case Record(bytes) => runtime.array_add(&made.items, decode(&call.manifest, writes.records, bytes, 0, 0))
            case End => {
                running.output_done = true
                return true
            }
            case Waiting => return false
        }
    }
}

// ---- The built-in stages

/**
 * Run a built-in stage on what came before it: where keeps the items its expression is true for, map makes each
 * item its expression's value, take keeps the first n, sort orders them, and group groups them by a field.
 *
 * It fails for where or map without an expression, an expression's error, where's expression not a bool, or take's,
 * sort's or group's errors.
 *
 * @param shell The shell, in whose scope the expressions are evaluated.
 * @param stage The stage's Call node.
 * @param given What came before it: a list's items, nothing for Null, or a value alone.
 * @return A new list; given's own isn't changed.
 */
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

/**
 * Find what a stage works on: a list's items, nothing for null, or a value alone.
 *
 * @param given What came before the stage: a List's own list is given back, Null is no items, and anything else is
 *     one item, kept by the new list.
 * @return The list itself for a List, so changing it changes given; a new list otherwise.
 */
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

/**
 * Evaluate an expression for one item, in a scope of its own: a record's fields bound as names, and the item itself
 * as it.
 *
 * @param shell The shell, whose scope the item's is in while it's evaluated, and is again after.
 * @param item The item, kept by the scope.
 * @param expression The expression's node, evaluated once for this item; its names find the record's fields and it
 *     before the shell's own.
 * @return The expression's value, or its error, as evaluate gives it.
 */
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

/**
 * Find take's count: its first argument, a whole number.
 *
 * It fails without an argument, with one that isn't a whole number, or with its evaluation's error.
 *
 * @param shell The shell, which evaluates an argument that isn't a bare word.
 * @param stage take's Call node.
 * @return How many items it keeps; 0 or less keeps none.
 */
stage_number :: fn(shell: ptr[mut Shell], stage: ptr[Node]) -> Result[i64, EvalError] {
    argument :: first_child(stage) or_return .Error(EvalError.{message = "take needs how many", at = stage.at})
    value :: if argument.kind == .Word { word_as("int", argument.text) or_else Value.Null } else { evaluate(shell, argument)? }
    match value {
        case Int(count) => return .Ok(count)
        case _ => return .Error(EvalError.{message = message("take needs a whole number, not %", argument.text), at = argument.at})
    }
}

/**
 * Find the field a stage's bare word names, and whether it has --descending.
 *
 * @param stage The stage's Call node; of several bare words, the last is the field.
 * @return field The field's name, a view of the line; "" for the items themselves.
 * @return descending Whether --descending is among its arguments.
 */
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

/**
 * Sort items, for sort [field] [--descending]: in order by the field, or by themselves, those that don't compare
 * staying in the order they came. Equal ones keep their order too.
 *
 * @param shell The shell; not used, since sort evaluates nothing.
 * @param stage sort's Call node.
 * @param items The items, which aren't changed.
 * @return A new list of them, sorted.
 */
sorted :: fn(shell: ptr[mut Shell], stage: ptr[Node], items #escaping : Value[]) -> Result[Value, EvalError] {
    field, descending :: stage_field(stage)
    return .Ok(.List(language.sort_items(items, field, descending)))
}

/**
 * Group items, for group field: a record for each of the field's values, in the order they first come, of the value
 * (named as the field), count, how many, and items, the items with it.
 *
 * Grouped by a field named count or items, the value is named key instead, so the group's own fields don't take its
 * place. It fails without a field.
 *
 * @param shell The shell; not used, since group evaluates nothing.
 * @param stage group's Call node.
 * @param items The items, which aren't changed.
 * @return A new list of the groups.
 */
grouped :: fn(shell: ptr[mut Shell], stage: ptr[Node], items #escaping : Value[]) -> Result[Value, EvalError] {
    name, descending :: stage_field(stage)
    if name.count == 0 {
        return error_at(stage.at, "group needs the field to group by")
    }
    return .Ok(.List(language.group_items(items, name)))
}
