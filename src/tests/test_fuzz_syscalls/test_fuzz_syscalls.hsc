/**
 * test_fuzz_syscalls (decisions/0186, He): the system call fuzzer. It makes calls from the ABI table (slop_os.Syscalls)
 * with arguments drawn by each parameter's type: handles to objects it made for fuzzing, under a budget of their own,
 * or ones that are wrong; its own scratch memory, or addresses no user mapping has; and numbers near limits. On a
 * kernel built with coverage counters (the build's coverage=on) it keeps the inputs that reached new code and changes
 * them, so it goes deeper; on another, every input is drawn afresh. The kernel has to survive, and the root task checks
 * the fuzzer's budget is back to nothing once it ends.
 *
 * It runs for FUZZ_SECONDS, or the build's fuzz_seconds setting. Calls that end it (thread_exit, process_exit), that
 * start code in it (thread_create), that change its own thread (thread_set_page, thread_use_cpu_budget) or that change
 * what it measures (coverage_take) aren't made; every other is. Waits get a deadline a few milliseconds off.
 */
package test_fuzz_syscalls

import compiler from "base"
import intrinsics from "base"
import runtime from "base"
import os from "std"
import testing from "std"
import slop_os from "std/os"
import process_manager from "std/os/slop_os"
import test_kit from "../../test_kit"
import log_line from "../../log_line"

/** The test's name, which starts each line it logs. */
NAME :: "test_fuzz_syscalls"
/** How long it fuzzes, in seconds, unless the build's fuzz_seconds setting says. */
FUZZ_SECONDS : u64 : #run setting_number("fuzz_seconds", 20)
/** The seed its random generator starts from: the build's fuzz_seed setting, or 0 for one from the clock, which it logs. */
FUZZ_SEED : u64 : #run setting_number("fuzz_seed", 0)
/** The most calls an input makes. */
MOST_CALLS :: 8
/** The most bytes an input has; draws past them read zeros. */
INPUT_BYTES :: 256
/** The most inputs kept, as reaching new code. */
MOST_KEPT :: 512
/** The most handles the fuzzer draws from. */
MOST_POOLED :: 64
/** The bytes of scratch memory calls are pointed at, between two unmapped ranges as big. */
SCRATCH_BYTES : u64 : 64 * 1024
/** The budget the objects it fuzzes with are charged to. */
POOL_BUDGET : u64 : 8 << 20
/** The most argument words a call takes. */
MOST_WORDS :: 6
/** How far off a wait's deadline is at most, in nanoseconds: 2 ms. */
MOST_WAIT : u64 : 2_000_000
/** An address in the kernel's half, which no user mapping has. */
KERNEL_ADDRESS : u64 : 0xffff_8000_0000_0000
/** An address that isn't canonical, which nothing maps. */
NON_CANONICAL : u64 : 0x8000_0000_0000_0000
/** How many system calls there are. */
CALL_COUNT :: #run call_count()
/** Bytes a changed input's byte may become: the edges of a byte's values. */
EDGE_BYTES :: u8.[0, 1, 0x7f, 0x80, 0xff]
/** Slice counts at and past the limits. */
EDGE_COUNTS :: u64.[0, 1, SCRATCH_BYTES, 0xffff_ffff, 0xffff_ffff_ffff_ffff, 1 << 40]
/** Numbers at and past the limits, and addresses nothing user space has is at. */
EDGE_NUMBERS :: u64.[0xffff_ffff, 0xffff_ffff_ffff_ffff, 0x8000_0000, 1 << 30, KERNEL_ADDRESS, NON_CANONICAL, 0x1000]
/** Addresses no user mapping has, or the first page, which is never mapped. */
EDGE_ADDRESSES :: u64.[0, KERNEL_ADDRESS, NON_CANONICAL, 8]

/** What main was given that the test uses. */
Given :: struct {
    /** The debug log. */
    log : slop_os.DebugLog,
}

/** What an argument word is drawn as, from its parameter's type. */
Kind :: enum {
    /** A plain number: an integer, an enum or a bool. */
    Number,
    /** A handle. */
    Handle,
    /** A pointer, to memory the call reads or writes. */
    Pointer,
    /** A slice's data address. */
    SliceData,
    /** A slice's count, after its data. */
    SliceCount,
    /** A wait's deadline, in nanoseconds of the monotonic clock. */
    Deadline,
}

/** A call, as the fuzzer makes it. */
Shape :: struct {
    /** How many argument words it takes. */
    words : u64,
    /** What each word is drawn as. */
    kinds : Kind[MOST_WORDS],
    /** For a Handle word, the slop_os.ObjectKind its parameter takes, as a number; 0 for a handle of any kind. */
    wanted : u64[MOST_WORDS],
    /** How many handles it gives back when it succeeds: 1 for a handle, 2 for a pair of them, 0 otherwise. */
    handles : u64,
    /** Whether it's never made. */
    left_out : bool,
}

/** An input: bytes the calls and their arguments are drawn from. */
Input :: struct {
    bytes : u8[INPUT_BYTES],
    count : usize,
}

/** What the fuzzing came to, for the log. */
Totals :: struct {
    inputs : u64,
    calls : u64,
    succeeded : u64,
    kept : u64,
    reached : u64,
}

/** The fuzzer's state. */
Fuzzer :: struct {
    /** The debug log, where it says how far it's come. */
    log : slop_os.DebugLog,
    /** The handles calls are given: objects made for fuzzing, and those calls gave back. */
    pool : slop_os.Handle[MOST_POOLED],
    /** Each pooled handle's slop_os.ObjectKind, as a number, from handle_info; 0 if it gave none. */
    pool_kinds : u64[MOST_POOLED],
    pool_count : usize,
    /** The scratch memory's address, mapped read/write for SCRATCH_BYTES. */
    scratch : u64,
    /** The kernel's counters, as taken after an input; empty without them. */
    counters : mut u8[],
    /** Which hit-count buckets each counter has reached, a bit each. */
    seen : mut u8[],
    /** The inputs kept. */
    kept : Input[..],
    /** The random generator for changing inputs, xorshift64*. */
    random : u64,
    totals : Totals,
}

/**
 * Read a number from the build's settings, at compile time.
 *
 * @param name The setting's name.
 * @param otherwise What it is without the setting, or for one that isn't a decimal number.
 * @return The number.
 */
setting_number :: fn(name: string, otherwise: u64) -> u64 {
    text :: compiler.target_setting(name, default = "")
    if text.count == 0 {
        return otherwise
    }
    value : u64 = 0
    for character in text {
        if character < '0' || character > '9' {
            return otherwise
        }
        value = value * 10 + cast[u64](cast[u8](character) - cast[u8]('0'))
    }
    return value
}

/**
 * Count the system calls, at compile time.
 *
 * @return How many members slop_os.Syscalls has.
 */
call_count :: fn() -> u64 {
    return cast[u64](slop_os.table().members.count)
}

/**
 * Generate shape_of's body, at compile time: for each call, an if statement filling in its Shape from its parameters'
 * types.
 *
 * @return The statements.
 */
shape_code :: fn() -> compiler.Code {
    made : compiler.Code[..]
    for member, number in slop_os.table().members {
        function :: cast[ptr[compiler.TypeInfoFunction]](member.member_type)
        stores : compiler.Code[..]
        index := cast[u64](0)
        for input in function.input {
            kind := #code(Kind.Number)
            if slop_os.is_slice(input.type) {
                runtime.array_add(&stores, #code {
                    shape.kinds[#insert index] = Kind.SliceData
                })
                index += 1
                kind = #code(Kind.SliceCount)
            }
            else if os.is_handle(input.type) {
                kind = #code(Kind.Handle)
                wanted :: object_kind_of(input.type)
                runtime.array_add(&stores, #code {
                    shape.wanted[#insert index] = #insert wanted
                })
            }
            else if slop_os.underlying(input.type).variant == .POINTER {
                kind = #code(Kind.Pointer)
            }
            else if input.name == "deadline" {
                kind = #code(Kind.Deadline)
            }
            runtime.array_add(&stores, #code {
                shape.kinds[#insert index] = #insert kind
            })
            index += 1
        }
        left_out := function.never_returns || member.name == "thread_create" || member.name == "thread_set_page"
            || member.name == "thread_use_cpu_budget" || member.name == "coverage_take"
        handles := cast[u64](0)
        if !function.never_returns {
            ok, error :: slop_os.result_types(slop_os.result_of(function), member.name)
            match ok {
                case Some(type) => {
                    if os.is_handle(type) {
                        handles = 1
                    }
                    else if slop_os.underlying(type).variant == .STRUCT {
                        members :: cast[ptr[compiler.TypeInfoStruct]](slop_os.underlying(type)).members
                        if members.count >= 2 && os.is_handle(members[0].member_type) && os.is_handle(members[1].member_type) {
                            handles = 2
                        }
                    }
                }
                case None => {}
            }
        }
        runtime.array_add(&made, #code {
            if number == #insert cast[u64](number) {
                shape.words = #insert index
                shape.handles = #insert handles
                shape.left_out = #insert left_out
                #insert compiler.list(stores)
                return shape
            }
        })
    }
    return compiler.list(made)
}

/**
 * Give the slop_os.ObjectKind a handle type names, at compile time: a handle type's name is its kind's, like Memory or
 * Port; Handle names none.
 *
 * @param type A handle type, an alias.
 * @return The kind's value; 0 for Handle, or a name that isn't a kind.
 */
object_kind_of :: fn(type: ptr[compiler.TypeInfo]) -> u64 {
    if type.variant != .ALIAS {
        return 0
    }
    name :: cast[ptr[compiler.TypeInfoAlias]](type).name
    kinds :: cast[ptr[compiler.TypeInfoEnum]](type_info_of(slop_os.ObjectKind))
    for member, i in kinds.members {
        if member == name && i < kinds.values.count {
            return cast[u64](kinds.values[i])
        }
    }
    return 0
}

/**
 * Say how a call is made.
 *
 * @param number The call's number, below CALL_COUNT.
 * @return Its shape; left out for a number past them.
 */
shape_of :: fn(number: u64) -> Shape {
    shape := Shape.{}
    #insert shape_code()
    shape.left_out = true
    return shape
}

/**
 * Fuzz the system calls for FUZZ_SECONDS: the kernel survives whatever it's given.
 *
 * @param t The test's state.
 * @return Ok once it's fuzzed; Error if what it fuzzes with couldn't be made.
 */
survives_calls_drawn_from_the_abi_table #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    block :: slop_os.startup_block()
    given :: test_kit.given(t, Given)?
    seed :: if FUZZ_SEED != 0 { FUZZ_SEED } else { 0x9e3779b97f4a7c15 ~ (slop_os.clock_monotonic() or_else 1) }
    log_line.write(given.log, "%: seed % (fuzz_seed=% replays it)", NAME, seed, seed)
    fuzzer := Fuzzer.{log = given.log, random = seed}
    defer {
        runtime.array_free(&fuzzer.kept)
        if fuzzer.counters.count > 0 {
            runtime.free_array(fuzzer.counters)
            runtime.free_array(fuzzer.seen)
        }
    }
    // The scratch memory, between unmapped ranges, so a call reaching past it finds nothing
    scratch_memory :: testing.require_ok(t, slop_os.memory_create(block.budget, SCRATCH_BYTES), "the scratch memory is made")?
    reserved :: testing.require_some(t, runtime.reserve_addresses(cast[usize](3 * SCRATCH_BYTES)), "addresses for it are reserved")?
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    testing.require_ok(t, slop_os.memory_map(scratch_memory, block.space, reserved + SCRATCH_BYTES, 0, SCRATCH_BYTES, read_write),
        "it's mapped")?
    fuzzer.scratch = reserved + SCRATCH_BYTES
    // What it fuzzes with, under a budget of their own
    budget :: testing.require_ok(t, slop_os.memory_budget_create(block.budget, POOL_BUDGET), "a budget for what's fuzzed")?
    add_handle(&fuzzer, cast[slop_os.Handle](budget))
    match slop_os.address_space_create(budget) {
        case Ok(made) => add_handle(&fuzzer, cast[slop_os.Handle](made))
        case Error(error) => {}
    }
    match slop_os.process_create(budget) {
        case Ok(made) => add_handle(&fuzzer, cast[slop_os.Handle](made))
        case Error(error) => {}
    }
    match slop_os.port_create(budget) {
        case Ok(made) => add_handle(&fuzzer, cast[slop_os.Handle](made))
        case Error(error) => {}
    }
    for size in u64.[4096, 16384] {
        match slop_os.memory_create(budget, size) {
            case Ok(made) => add_handle(&fuzzer, cast[slop_os.Handle](made))
            case Error(error) => {}
        }
    }
    match slop_os.channel_create(budget, 4096, 0x5eed) {
        case Ok(pair) => {
            add_handle(&fuzzer, cast[slop_os.Handle](pair.a))
            add_handle(&fuzzer, cast[slop_os.Handle](pair.b))
        }
        case Error(error) => {}
    }
    // The kernel's counters, if it has them
    none : u8[0]
    match slop_os.coverage_take(none) {
        case Ok(count) => {
            counters, failed :: runtime.new_array(u8, cast[usize](count))
            seen, seen_failed :: runtime.new_array(u8, cast[usize](count))
            testing.require(t, failed == null && seen_failed == null, "room for the kernel's counters")?
            fuzzer.counters = counters
            fuzzer.seen = seen
        }
        case Error(error) => log_line.write(given.log, "%: the kernel has no coverage counters, so every input is drawn afresh", NAME)
    }
    start :: slop_os.clock_monotonic() or_else 0
    deadline :: start + FUZZ_SECONDS * 1_000_000_000
    next_report := start + 5_000_000_000
    input := Input.{}
    loop {
        now :: slop_os.clock_monotonic() or_else deadline
        if now >= deadline {
            break
        }
        if now >= next_report {
            report_progress(&fuzzer)
            next_report = now + 5_000_000_000
        }
        choose_input(&fuzzer, &input)
        if fuzzer.counters.count > 0 {
            _ = slop_os.coverage_take(none)
        }
        run_input(&fuzzer, &input)
        if fuzzer.counters.count > 0 && fuzzer.counters.count <= fuzzer.seen.count {
            _ = slop_os.coverage_take(fuzzer.counters)
            if reached_more(&fuzzer) {
                keep(&fuzzer, &input)
            }
        }
    }
    report_progress(&fuzzer)
    testing.expect_gt(t, fuzzer.totals.calls, 0, "calls were made")
    return .Ok
}

/**
 * Add a handle to those calls are given, if there's room.
 *
 * @param fuzzer The fuzzer.
 * @param handle The handle.
 */
add_handle :: fn(fuzzer: ptr[mut Fuzzer], handle: slop_os.Handle) {
    at :: fuzzer.pool_count
    if at < fuzzer.pool.count && at < fuzzer.pool_kinds.count {
        fuzzer.pool[at] = handle
        fuzzer.pool_kinds[at] = 0
        match slop_os.handle_info(handle) {
            case Ok(info) => fuzzer.pool_kinds[at] = cast[u64](cast[u32](info.kind))
            case Error(error) => {}
        }
        fuzzer.pool_count += 1
    }
}

/**
 * Draw one of the pooled handles of a kind, if there's one.
 *
 * @param fuzzer The fuzzer.
 * @param source The input's source.
 * @param wanted The slop_os.ObjectKind, as a number; 0 for any.
 * @return The handle, as a word; null if none is of that kind.
 */
draw_pooled :: fn(fuzzer: ptr[Fuzzer], source: ptr[mut testing.Source], wanted: u64) -> u64? {
    matching : u64 = 0
    for kind, i in fuzzer.pool_kinds {
        if i < fuzzer.pool_count && (wanted == 0 || kind == wanted) {
            matching += 1
        }
    }
    if matching == 0 {
        return null
    }
    chosen := testing.draw_below(source, matching)
    for kind, i in fuzzer.pool_kinds {
        if i < fuzzer.pool_count && i < fuzzer.pool.count && (wanted == 0 || kind == wanted) {
            if chosen == 0 {
                return cast[u64](cast[u32](fuzzer.pool[i]))
            }
            chosen -= 1
        }
    }
    return null
}

/**
 * Choose the next input: drawn afresh one time in eight, or with nothing kept; otherwise a kept one, changed.
 *
 * @param fuzzer The fuzzer, whose random generator moves on.
 * @param input Where it goes.
 */
choose_input :: fn(fuzzer: ptr[mut Fuzzer], input: ptr[mut Input]) {
    if fuzzer.kept.count == 0 || next_random(fuzzer) % 8 == 0 {
        input.count = INPUT_BYTES
        for i in 0..<input.bytes.count {
            input.bytes[i] = cast[u8](next_random(fuzzer))
        }
        return void
    }
    from :: cast[usize](next_random(fuzzer) % cast[u64](fuzzer.kept.count))
    if from < fuzzer.kept.count {
        input^ = fuzzer.kept[from]
    }
    changes :: next_random(fuzzer) % 4 + 1
    for change in 0..<changes {
        at :: cast[usize](next_random(fuzzer) % INPUT_BYTES)
        if at >= input.bytes.count {
            continue
        }
        way :: next_random(fuzzer) % 4
        if way == 0 {
            input.bytes[at] = cast[u8](next_random(fuzzer))
        }
        else if way == 1 {
            input.bytes[at] = input.bytes[at] ~ cast[u8](1 << (next_random(fuzzer) % 8))
        }
        else if way == 2 {
            edge :: cast[usize](next_random(fuzzer) % cast[u64](EDGE_BYTES.count))
            if edge < EDGE_BYTES.count {
                input.bytes[at] = EDGE_BYTES[edge]
            }
        }
        else {
            // A run of bytes from another kept input
            other :: cast[usize](next_random(fuzzer) % cast[u64](fuzzer.kept.count))
            if other < fuzzer.kept.count {
                from_other :: fuzzer.kept[other]
                for byte, i in from_other.bytes {
                    if i >= at && i < input.bytes.count {
                        input.bytes[i] = byte
                    }
                }
            }
        }
    }
    input.count = INPUT_BYTES
}

/**
 * Make an input's calls: each call's number, then its argument words, drawn from its bytes; handles a call gives back
 * join those calls are given.
 *
 * @param fuzzer The fuzzer.
 * @param input The input.
 */
run_input :: fn(fuzzer: ptr[mut Fuzzer], input: ptr[Input]) {
    room : u8[INPUT_BYTES]
    for byte, i in input.bytes {
        if i < input.count {
            room[i] = byte
        }
    }
    source := testing.source_in(room, input.count, null)
    calls :: testing.draw_between(&source, 1, MOST_CALLS)
    for call in 0..<calls {
        number :: testing.draw_below(&source, CALL_COUNT)
        shape :: shape_of(number)
        if shape.left_out {
            continue
        }
        words : u64[MOST_WORDS]
        for i in 0..<shape.kinds.count {
            if cast[u64](i) < shape.words {
                words[i] = draw_word(fuzzer, &source, shape.kinds[i], shape.wanted[i])
            }
        }
        answer :: slop_os.system_call(number, words[0], words[1], words[2], words[3], words[4], words[5])
        fuzzer.totals.calls += 1
        if answer.tag == 0 {
            fuzzer.totals.succeeded += 1
            if shape.handles >= 1 {
                add_handle(fuzzer, cast[slop_os.Handle](cast[u32](answer.first)))
            }
            if shape.handles >= 2 {
                add_handle(fuzzer, cast[slop_os.Handle](cast[u32](answer.second)))
            }
        }
    }
    fuzzer.totals.inputs += 1
}

/**
 * Draw an argument word.
 *
 * @param fuzzer The fuzzer, whose handles and scratch memory it may name.
 * @param source The input's source.
 * @param kind What it's drawn as.
 * @param wanted For a handle, the slop_os.ObjectKind its parameter takes, as a number; 0 for any.
 * @return The word.
 */
draw_word :: fn(fuzzer: ptr[Fuzzer], source: ptr[mut testing.Source], kind: Kind, wanted: u64) -> u64 {
    way :: testing.draw_below(source, 16)
    match kind {
        case .Handle => {
            // Mostly one of the kind the call takes, sometimes any of its own
            if way < 10 {
                match draw_pooled(fuzzer, source, wanted) {
                    case Some(word) => return word
                    case None => {}
                }
            }
            if way < 13 {
                match draw_pooled(fuzzer, source, 0) {
                    case Some(word) => return word
                    case None => {}
                }
            }
            if way == 13 && fuzzer.pool_count > 0 {
                // One of its handles of another generation, as a closed one's next would be
                return cast[u64](cast[u32](fuzzer.pool[0])) ~ (cast[u64](1) << 16)
            }
            return if way == 14 { cast[u64](0) } else { cast[u64](0xffff_ffff) }
        }
        case .Pointer => return draw_address(fuzzer, source, way)
        case .SliceData => return draw_address(fuzzer, source, way)
        case .SliceCount => {
            if way < 10 {
                return testing.draw_below(source, SCRATCH_BYTES / 8 + 1)
            }
            edge :: cast[usize](way - 10) % EDGE_COUNTS.count
            return if edge < EDGE_COUNTS.count { EDGE_COUNTS[edge] } else { cast[u64](0) }
        }
        case .Deadline => return (slop_os.clock_monotonic() or_else 0) + testing.draw_below(source, MOST_WAIT)
        case .Number => {
            if way < 4 {
                return testing.draw_below(source, 64)
            }
            if way < 6 {
                return 4096 * testing.draw_below(source, 64)
            }
            if way == 6 {
                return fuzzer.scratch + testing.draw_below(source, SCRATCH_BYTES)
            }
            if way == 7 {
                shift :: testing.draw_below(source, 64)
                return (cast[u64](1) << shift) - testing.draw_below(source, 2)
            }
            if way == 8 {
                return testing.draw[u64](source)
            }
            edge :: cast[usize](way - 9) % EDGE_NUMBERS.count
            return if edge < EDGE_NUMBERS.count { EDGE_NUMBERS[edge] } else { cast[u64](0) }
        }
    }
}

/**
 * Draw an address a call reads or writes: mostly in the scratch memory, sometimes where nothing user space has is.
 *
 * @param fuzzer The fuzzer, whose scratch memory it names.
 * @param source The input's source.
 * @param way Which, as draw_word drew it, below 16.
 * @return The address.
 */
draw_address :: fn(fuzzer: ptr[Fuzzer], source: ptr[mut testing.Source], way: u64) -> u64 {
    if way < 11 {
        return fuzzer.scratch + (testing.draw_below(source, SCRATCH_BYTES) & ~cast[u64](7))
    }
    if way == 11 {
        // Near its end, so a call reaching past it finds the unmapped range after
        return fuzzer.scratch + SCRATCH_BYTES - 8 * testing.draw_below(source, 64)
    }
    edge :: cast[usize](way - 12) % EDGE_ADDRESSES.count
    return if edge < EDGE_ADDRESSES.count { EDGE_ADDRESSES[edge] } else { cast[u64](0) }
}

/**
 * Tell whether the kernel's counters, as taken after an input, reached a bucket of hits a counter hadn't before, and
 * note what they reached.
 *
 * @param fuzzer The fuzzer, whose seen grows.
 * @return True if anything was new.
 */
reached_more :: fn(fuzzer: ptr[mut Fuzzer]) -> bool {
    more := false
    seen :: fuzzer.seen
    for count, i in fuzzer.counters {
        if count == 0 || i >= seen.count {
            continue
        }
        bit :: bucket_of(count)
        if seen[i] & bit == 0 {
            if seen[i] == 0 {
                fuzzer.totals.reached += 1
            }
            seen[i] = seen[i] | bit
            more = true
        }
    }
    return more
}

/**
 * Give a counter's bucket of hits, as AFL's: 1, 2, 3, 4 to 7, 8 to 15, 16 to 31, 32 to 127, 128 and more.
 *
 * @param count The counter, above 0.
 * @return Its bucket's bit.
 */
bucket_of :: fn(count: u8) -> u8 {
    if count <= 3 {
        return cast[u8](1) << (count - 1)
    }
    if count < 8 {
        return 8
    }
    if count < 16 {
        return 16
    }
    if count < 32 {
        return 32
    }
    if count < 128 {
        return 64
    }
    return 128
}

/**
 * Keep an input that reached new code: added, or in place of a random one once MOST_KEPT are.
 *
 * @param fuzzer The fuzzer.
 * @param input The input.
 */
keep :: fn(fuzzer: ptr[mut Fuzzer], input: ptr[Input]) {
    fuzzer.totals.kept += 1
    if fuzzer.kept.count < MOST_KEPT {
        runtime.array_add(&fuzzer.kept, input^)
        return void
    }
    at :: cast[usize](next_random(fuzzer) % MOST_KEPT)
    if at < fuzzer.kept.count {
        fuzzer.kept[at] = input^
    }
}

/**
 * Log how far the fuzzing has come.
 *
 * @param fuzzer The fuzzer.
 */
report_progress :: fn(fuzzer: ptr[Fuzzer]) {
    totals :: fuzzer.totals
    log_line.write(fuzzer.log, "%: % inputs, % calls, % succeeded, % of the kernel's % counters reached, % inputs kept, % handles", NAME,
        totals.inputs, totals.calls, totals.succeeded, totals.reached, fuzzer.counters.count, fuzzer.kept.count, fuzzer.pool_count)
}

/**
 * Get the next random number, xorshift64*.
 *
 * @param fuzzer The fuzzer, whose generator moves on.
 * @return A number, any u64.
 */
next_random :: fn(fuzzer: ptr[mut Fuzzer]) -> u64 {
    x := fuzzer.random | 1
    x = x ~ (x >> 12)
    x = x ~ (x << 25)
    x = x ~ (x >> 27)
    fuzzer.random = x
    return x * 0x2545f4914f6cdd1d
}

main :: fn(log: slop_os.DebugLog, platform: slop_os.Platform?, test_device: slop_os.Memory?, firmware: slop_os.Memory?,
    manager: os.Channel[process_manager.ProcessManager]?, program: slop_os.Memory?, peer: slop_os.Channel?, cpu_budget: slop_os.CpuBudget?) -> int {
    given :: Given.{log = log}
    return test_kit.run(log, NAME, #insert testing.tests_of(compiler.load_package(".")), given)
}
