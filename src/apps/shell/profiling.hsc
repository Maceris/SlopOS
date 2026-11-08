package shell

import runtime from "base"
import language from "../../shell_language"
import os from "std"
import slop_os from "std/os"
import lifecycle from "std/os/slop_os"

/*
 * The profiler (decisions/0183, 12d): profile name arguments runs a program as a call would, its intercept sampling
 * it at each tick (intercept_sample), and once it's ended, says where its samples were: the functions they're in,
 * named through the symbols program, the most first. A program the shell starts is the shell's to profile; nothing
 * more is needed.
 */

/** The key a profiled program's stops come under, on a port of its own. */
PROFILE_STOP_KEY : u64 : 1
/** The key its end comes under. */
PROFILE_END_KEY : u64 : 2
/** How many functions a profile names, the most sampled. */
PROFILE_TOP :: 5
/** How many distinct program counters are named, the most sampled; the rest count as elsewhere. */
PROFILE_PLACES :: 64

/** A program counter sampled, and how often. */
Place :: struct {
    /** The program counter. */
    address : u64,
    /** How many samples had it. */
    count : u64,
}

/** A function sampled, and how often. */
Hot :: struct {
    /** Its name, as the symbols program gives it, without the offset; on the heap. */
    name : string,
    /** How many samples were in it. */
    count : u64,
}

/**
 * Profile a program, for profile: its call made as any other's, started sampled, waited for, and its samples said by
 * function.
 *
 * @param shell The shell, which starts and names.
 * @param tree The Call node of profile, its first child the program's name, the rest its arguments.
 * @return Null once it's ended and its profile's said; an error if there's no program, or it couldn't be made or
 *     started.
 */
profile_program :: fn(shell: ptr[mut Shell], tree #escaping : ptr[Node]) -> Result[Value, EvalError] {
    call :: prepare_recorded(shell, tree, "profile")?
    defer end_call(call)
    port :: slop_os.port_create(slop_os.startup_block().budget) or_return error_at(tree.at, "there's no memory to profile it")
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    match start_profiled(shell, call, port) {
        case Some(error) => return .Error(error)
        case None => {}
    }
    faults :: call.launched.faults or_return error_at(tree.at, "it started without its intercept")
    _ = slop_os.intercept_sample(faults.intercept, true)
    // Its samples taken as it runs, so none are lost to the ring's size
    places : Place[..]
    defer runtime.array_free(&places)
    total : u64 = 0
    loop {
        packets : slop_os.Packet[4]
        taken :: slop_os.port_wait(port, packets, (slop_os.clock_monotonic() or_else 0) + 100_000_000) or_else 0
        total += take_samples(faults.intercept, &places)
        ended := false
        for packet, i in packets {
            if cast[u64](i) < taken && packet.kind == .Signal && packet.key == PROFILE_END_KEY {
                ended = true
            }
        }
        if ended {
            break
        }
    }
    total += take_samples(faults.intercept, &places)
    say(shell, message("profile of %: % samples", call.tree.text, total))
    if total == 0 {
        return .Ok(.Null)
    }
    sort_places(places[0..<places.count])
    say_hot(shell, call, &places, total)
    return .Ok(.Null)
}

/**
 * Start a profiled program: as start_call would, but with its end and its faults on port.
 *
 * @param shell The shell, whose process manager starts it.
 * @param call The call, prepared; started.
 * @param port The profiler's port.
 * @return Null once it's started; why it didn't otherwise.
 */
start_profiled :: fn(shell: ptr[mut Shell], call: ptr[mut Call], port: slop_os.Port) -> EvalError? {
    tree :: call.tree
    manager :: shell.manager or_return EvalError.{message = "the shell can't start programs: it has no process manager", at = tree.at}
    ends :: lifecycle.make(slop_os.startup_block().budget) or_return EvalError.{message = "there's no memory to start it", at = tree.at}
    options := os.LaunchOptions.{watch = os.LaunchWatch.{port = port, key = PROFILE_END_KEY}, lifecycle = ends.b,
        faults = os.LaunchFaults.{port = port, key = PROFILE_STOP_KEY}}
    options.clock = copy_of_grant("clock")
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
            close_copy(options.clock)
            close_copy(options.locale)
            close_copy(options.result)
            return EvalError.{message = message("% didn't start: %", tree.text, error), at = tree.at}
        }
    }
}

/**
 * Take an intercept's samples so far, counting each program counter.
 *
 * @param intercept The intercept.
 * @param places The program counters counted so far, which grow.
 * @return How many samples were taken.
 */
take_samples :: fn(intercept: slop_os.Intercept, places: ptr[mut Place[..]]) -> u64 {
    total : u64 = 0
    samples : slop_os.Sample[64]
    loop {
        taken :: slop_os.intercept_samples(intercept, samples) or_else 0
        for sample, i in samples {
            if cast[u32](i) >= taken {
                break
            }
            count_place(places, sample.frames[0])
        }
        total += cast[u64](taken)
        if taken < 64 {
            return total
        }
    }
}

/**
 * Count one more sample at a program counter.
 *
 * @param places The program counters counted.
 * @param address The program counter.
 */
count_place :: fn(places: ptr[mut Place[..]], address: u64) {
    for &place in places^ {
        if place.address == address {
            place.count += 1
            return void
        }
    }
    runtime.array_add(places, Place.{address = address, count = 1})
}

/**
 * Say the functions most sampled, each with its share of the samples.
 *
 * @param shell The shell, which says them, and asks the symbols program to name them.
 * @param call The profiled program's call, whose file names its functions.
 * @param places The program counters sampled, and how often, the most first.
 * @param total How many samples there were in all.
 */
say_hot :: fn(shell: ptr[mut Shell], call: ptr[Call], places: ptr[mut Place[..]], total: u64) {
    image :: call.launched.image
    offsets : u64[PROFILE_PLACES]
    count : usize = 0
    for place in places^ {
        if count >= offsets.count {
            break
        }
        offsets[count] = if place.address >= image { place.address - image } else { 0 }
        count += 1
    }
    answer : u8[8192]
    named :: ask_symbols(shell, call.executable, view_of(&offsets[0], count), null, answer)
    // Each place's function, its offset into it dropped, its samples added to the function's
    hot : Hot[..]
    defer runtime.array_free(&hot)
    at : usize = 0
    for place, i in places^ {
        if i >= count {
            break
        }
        line :: next_line(answer, named, &at)
        name :: function_of(line)
        found := false
        for &each in hot {
            if each.name == name {
                each.count += place.count
                found = true
            }
        }
        if !found {
            runtime.array_add(&hot, Hot.{name = name, count = place.count})
        }
    }
    sort_hot(hot[0..<hot.count])
    for each, i in hot {
        if i >= PROFILE_TOP {
            break
        }
        say(shell, message("  %. %: % of % samples", i + 1, each.name, each.count, total))
    }
}

/**
 * Give the function in a symbols program's name for a place, its offset dropped.
 *
 * @param line "name+0x1c", or "?".
 * @return "name", on the heap; "?" or an empty line as "elsewhere".
 */
function_of :: fn(line: string) -> string {
    bytes :: string_bytes(line)
    end := bytes.count
    for byte, i in bytes {
        if byte == 0x2b {
            end = i
            break
        }
    }
    if end == 0 || line == "?" {
        return "elsewhere"
    }
    return message("%", string_of(&bytes[0], end))
}

/**
 * Sort program counters by how often they were sampled, the most first.
 *
 * @param places The places, sorted in place.
 */
sort_places :: fn(places: mut Place[]) {
    for i in cast[usize](1)..<places.count {
        j := i
        loop {
            if j == 0 || j >= places.count {
                break
            }
            before :: j - 1
            if before >= places.count || places[before].count >= places[j].count {
                break
            }
            held :: places[j]
            places[j] = places[before]
            places[before] = held
            j = before
        }
    }
}

/**
 * Sort functions by how often they were sampled, the most first.
 *
 * @param hot The functions, sorted in place.
 */
sort_hot :: fn(hot: mut Hot[]) {
    for i in cast[usize](1)..<hot.count {
        j := i
        loop {
            if j == 0 || j >= hot.count {
                break
            }
            before :: j - 1
            if before >= hot.count || hot[before].count >= hot[j].count {
                break
            }
            held :: hot[j]
            hot[j] = hot[before]
            hot[before] = held
            j = before
        }
    }
}
