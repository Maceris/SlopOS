/**
 * Record and replay (decisions/0183, 12c, design/observability.md §5): a program's system calls, recorded through an
 * intercept of every call (STOP_ALL_CALLS, at entry and exit) and of its threads' starts, with one thread at a time
 * running between calls; and replayed from the recording, the calls that read the world answered from it.
 *
 * The recorder lets one thread run its own code at a time, from a start or a call's end to its next call, the rest
 * waiting their turn, and writes each decision as an event: a thread started, entered a call (its number, its
 * argument words and the bytes of the buffers it reads), left it (its result and the bytes of the buffers it wrote),
 * was let run, read the counter, or the program ended. In base's deterministic mode, which a recording runs in, a
 * thread waiting for another makes calls as it spins, so the one that runs can't keep the rest waiting for good.
 *
 * The replayer walks the events in their order, the program started again with the recording's seeds, so its layout
 * and its randomness are the same. A call that reads the world, on a channel or a port, or the clock, or the kernel's
 * log, is answered from the recording, its buffers written and its result set, and skipped; every other call, which
 * only changes the program's own objects, runs again, and its result has to be the recording's. A call whose number,
 * argument words or read buffers differ from the recording's, or a thread that doesn't come to its next event, is the
 * divergence, reported where it is.
 *
 * Not replayed: handles received on a channel, which the replay doesn't have; shared memory another program writes,
 * like the clock page, which a recording isn't given.
 */
package recording

import compiler from "base"
import runtime from "base"
import os from "std"
import text_buffer from "std"
import slop_os from "std/os"

/** The most threads a recording follows; a program that starts more ends the recording. */
MAX_THREADS :: 32
/** The most bytes of one buffer a call reads or writes that are recorded; a bigger one ends the recording. */
MAX_BUFFER : u64 : 1 << 20
/** How long a replay waits for a thread to come to its next event before it's taken as diverged, in nanoseconds: 5 s. */
REPLAY_WAIT : u64 : 5_000_000_000
/** No thread. */
NO_THREAD : u32 : 0xffffffff
/** A pointer's buffer, which has no count word. */
NO_COUNT : u32 : 0xffffffff
/** The STOP_ points a recording's intercept stops at, which its launch attaches (os.LaunchFaults.points). */
RECORDING_POINTS : u32 : slop_os.STOP_SYSCALL_ENTRY | slop_os.STOP_SYSCALL_EXIT | slop_os.STOP_FAULT | slop_os.STOP_ALL_CALLS
    | slop_os.STOP_THREAD_START

#if TARGET_ARCH == .arm64 {
    /** Where a call's number is among thread_read_registers' registers: x8. */
    NUMBER_REGISTER :: 8
    /** Where its argument words are, in order: x0 to x5. */
    ARGUMENT_REGISTERS :: u32.[0, 1, 2, 3, 4, 5]
    /** Where its result is: x0 the tag, x1 and x2 the value. */
    RESULT_REGISTERS :: u32.[0, 1, 2]
}
#else {
    /** Where a call's number is among thread_read_registers' registers: rax. */
    NUMBER_REGISTER :: 0
    /** Where its argument words are, in order: rdi, rsi, rdx, r10, r8, r9. */
    ARGUMENT_REGISTERS :: u32.[5, 4, 3, 10, 8, 9]
    /** Where its result is: rax the tag, rdx and r8 the value. */
    RESULT_REGISTERS :: u32.[0, 3, 8]
}

/** A buffer a call reads or writes: the argument word with its address, and how many bytes it has. */
Buffer :: struct {
    /** The word with its address. */
    word : u32,
    /** The word with its count of elements, for a slice; NO_COUNT for a pointer. */
    count_word : u32,
    /** The bytes of each element, or of what a pointer points to. */
    element : u64,
}

/** What a system call reads and writes, as std's table says (slop_os.Syscalls), for recording it. */
CallShape :: struct {
    /** Its name. */
    name : string,
    /** The buffers it reads: its slices and pointers that aren't mut; inputs_count of them. */
    inputs : Buffer[6],
    /** How many inputs there are. */
    inputs_count : u32,
    /** The buffers it writes: its mut slices and pointers; outputs_count of them. */
    outputs : Buffer[6],
    /** How many outputs there are. */
    outputs_count : u32,
    /** Whether a replay answers it from the recording rather than running it again: it reads or changes the world. */
    answered : bool,
    /** Whether it never returns, so it has no exit stop. */
    never_returns : bool,
}

/**
 * Work out every system call's shape from std's table, by its type description: each slice takes two words, the
 * address then the count, and everything else one, as std's stubs pass them.
 *
 * @return The shapes, by call number, on the heap, never freed.
 */
call_shapes :: fn() -> CallShape[] {
    table :: cast[ptr[compiler.TypeInfoStruct]](type_info_of(slop_os.Syscalls))
    shapes, failed :: runtime.new_array(CallShape, table.members.count)
    if failed != null {
        return shapes[0..<0]
    }
    for member, number in table.members {
        if number >= shapes.count || member.member_type.variant != .FUNCTION {
            continue
        }
        function :: cast[ptr[compiler.TypeInfoFunction]](member.member_type)
        shape := CallShape.{name = member.name, never_returns = function.never_returns, answered = is_answered(member.name)}
        word : u32 = 0
        for input in function.input {
            base :: underlying(input.type)
            if base.variant == .ARRAY {
                array :: cast[ptr[compiler.TypeInfoArray]](base)
                buffer :: Buffer.{word = word, count_word = word + 1, element = cast[u64](array.base_type.size)}
                if array.dimensions.count > 0 && array.dimensions[0].is_mutable {
                    add_buffer(&shape.outputs, &shape.outputs_count, buffer)
                }
                else {
                    add_buffer(&shape.inputs, &shape.inputs_count, buffer)
                }
                word += 2
                continue
            }
            if base.variant == .POINTER {
                pointer :: cast[ptr[compiler.TypeInfoPointer]](base)
                size :: match pointer.base_type {
                    case Some(target) => cast[u64](target.size)
                    case None => cast[u64](0)
                }
                buffer :: Buffer.{word = word, count_word = NO_COUNT, element = size}
                if pointer.is_mutable {
                    add_buffer(&shape.outputs, &shape.outputs_count, buffer)
                }
                else {
                    add_buffer(&shape.inputs, &shape.inputs_count, buffer)
                }
            }
            word += 1
        }
        shapes[number] = shape
    }
    return shapes
}

/**
 * Tell whether a replay answers a call from the recording: one on a channel or a port, which talk to the world, but
 * those that make them; the clock's; and the kernel's log.
 *
 * @param name The call's name.
 * @return True if it's answered; false if it runs again.
 */
is_answered :: fn(name: string) -> bool {
    if name == "channel_create" || name == "port_create" {
        return false
    }
    return starts_with(name, "channel_") || starts_with(name, "port_") || starts_with(name, "clock_") || name == "debug_log_write"
}

/**
 * Add a buffer to a shape's list, if there's room.
 *
 * @param buffers The list.
 * @param count How many it has, one more after.
 * @param buffer The buffer.
 */
add_buffer :: fn(buffers: ptr[mut Buffer[6]], count: ptr[mut u32], buffer: Buffer) {
    slot :: cast[usize](count^)
    if slot < buffers^.count {
        buffers^[slot] = buffer
        count^ += 1
    }
}

/**
 * Look through aliases to the type underneath.
 *
 * @param type The type.
 * @return The first that isn't an alias, at most 16 deep.
 */
underlying :: fn(type: ptr[compiler.TypeInfo]) -> ptr[compiler.TypeInfo] {
    current := type
    for depth in 0..<16 {
        if current.variant != .ALIAS {
            break
        }
        current = cast[ptr[compiler.TypeInfoAlias]](current).base_type
    }
    return current
}

/**
 * Tell whether a string starts with another.
 *
 * @param text The string.
 * @param start What it may start with.
 * @return True if it does.
 */
starts_with :: fn(text: string, start: string) -> bool {
    bytes :: string_bytes(text)
    wanted :: string_bytes(start)
    if wanted.count > bytes.count {
        return false
    }
    for byte, i in wanted {
        if i >= bytes.count || bytes[i] != byte {
            return false
        }
    }
    return true
}

/** What an event of a recording is. */
EventKind :: enum {
    /** A thread started, stopped before its first instruction. */
    Start,
    /** A thread entered a call: its number, words, and the bytes of the buffers it reads. */
    Enter,
    /** A thread's call ended: its result, and the bytes of the buffers it wrote. */
    Leave,
    /** A thread was let run its own code, from a start or a call's end. */
    Resume,
    /** A thread read the counter, which gave value. */
    Counter,
    /** The program ended, with value its code. */
    End,
}

/** One event of a recording. */
Event :: struct {
    /** What it is. */
    kind : EventKind,
    /** The thread, by the order threads started in, from 0. */
    thread : u32,
    /** Enter's call number. */
    number : u32,
    /** Enter's argument words. */
    words : u64[6],
    /** Leave's result: its tag, then its value's words. */
    results : u64[3],
    /** Counter's value, or End's code. */
    value : u64,
    /** Where its bytes start in the recording's bytes: Enter's read buffers', Leave's written buffers', one after another. */
    bytes_at : usize,
    /** How many bytes it has. */
    bytes_count : usize,
}

/** A recording: its events, their bytes, and what the program was started with. */
Recording :: struct {
    /** The events, in the order they happened. */
    events : Event[..],
    /** The bytes the events' buffers had. */
    bytes : u8[..],
    /** The seeds the program was built with, which a replay builds it with. */
    seeds : u8[64],
    /** How many threads it had. */
    threads : u32,
    /** How many calls it made. */
    calls : u64,
    /** Why it stopped short, if it did: a sentence; empty if it recorded the program to its end. */
    problem : string,
}

/** A thread being followed: its kernel ID, and the call it's in. */
Followed :: struct {
    /** Its thread ID in the kernel. */
    id : u64,
    /** The call it's in, from its entry to its exit: its number; NO_THREAD's value when none. */
    number : u32,
    /** That call's argument words. */
    words : u64[6],
    /** For a replay: whether its call's answered, so it's let go by Skip. */
    answered : bool,
}

/** A recorder's or replayer's hold on a program: its process, intercept, space and the port its stops and end come on. */
Program :: struct {
    /** Its process, with every right. */
    process : slop_os.Process,
    /** Its intercept, attached with RECORDING_POINTS. */
    intercept : slop_os.Intercept,
    /** Its address space. */
    space : slop_os.AddressSpace,
    /** The port its stops and its end come on. */
    port : slop_os.Port,
    /** The key its end comes under on port. */
    end_key : u64,
}

/**
 * Record a program, started with its intercept attached with RECORDING_POINTS, in the deterministic mode, stopped
 * before its first instruction, until it ends.
 *
 * @param program The program.
 * @param shapes Every call's shape (call_shapes).
 * @param seeds The seeds it was built with, kept in the recording.
 * @return The recording, on the heap; its problem says why it stopped short, if it did, the program killed then.
 */
record :: fn(program: Program, shapes: CallShape[], seeds: u8[64]) -> ptr[mut Recording] {
    recording := runtime.new(Recording)
    recording.seeds = seeds
    _ = slop_os.process_set_traps(program.process, slop_os.TRAP_COUNTER)
    threads : Followed[MAX_THREADS]
    count : u32 = 0
    // Threads waiting their turn to run their own code, oldest first, by index
    waiting : u32[MAX_THREADS]
    waiting_count : u32 = 0
    running := NO_THREAD
    loop {
        stop := slop_os.StopInfo.{}
        if slop_os.intercept_next(program.intercept, &stop) is_ok {
            index := index_of(&threads, count, stop.thread)
            if stop.point == .ThreadStart {
                if count >= MAX_THREADS {
                    return stopped_short(program, recording, "it started more threads than a recording follows")
                }
                index = count
                threads[cast[usize](count)] = Followed.{id = stop.thread, number = NO_THREAD}
                count += 1
                recording.threads = count
                add_event(recording, Event.{kind = .Start, thread = index})
                push(&waiting, &waiting_count, index)
            }
            else if index == NO_THREAD {
                // A thread it didn't see start: let go as it is
                _ = slop_os.intercept_resume(program.intercept, stop.thread, .Continue)
            }
            else if stop.point == .SyscallEntry {
                registers : u64[slop_os.THREAD_REGISTERS]
                _ = slop_os.thread_read_registers(program.process, stop.thread, registers)
                event := Event.{kind = .Enter, thread = index, number = cast[u32](registers[NUMBER_REGISTER])}
                for register, i in ARGUMENT_REGISTERS {
                    if i < event.words.count && cast[usize](register) < registers.count {
                        event.words[i] = registers[cast[usize](register)]
                    }
                }
                if cast[usize](event.number) >= shapes.count {
                    return stopped_short(program, recording, "it made a call std's table doesn't have")
                }
                shape :: &shapes[cast[usize](event.number)]
                event.bytes_at = recording.bytes.count
                if !read_buffers(program, recording, shape.inputs, shape.inputs_count, event.words) {
                    return stopped_short(program, recording, "a call's buffer couldn't be read, or was too big to record")
                }
                event.bytes_count = recording.bytes.count - event.bytes_at
                add_event(recording, event)
                recording.calls += 1
                if cast[usize](index) >= threads.count {
                    return stopped_short(program, recording, "a thread it doesn't follow made a call")
                }
                followed :: &threads[cast[usize](index)]
                followed.number = event.number
                followed.words = event.words
                if running == index {
                    running = NO_THREAD
                }
                _ = slop_os.intercept_resume(program.intercept, stop.thread, .Continue)
            }
            else if stop.point == .SyscallExit {
                registers : u64[slop_os.THREAD_REGISTERS]
                _ = slop_os.thread_read_registers(program.process, stop.thread, registers)
                if cast[usize](index) >= threads.count {
                    return stopped_short(program, recording, "a thread it doesn't follow ended a call")
                }
                followed :: &threads[cast[usize](index)]
                event := Event.{kind = .Leave, thread = index}
                for register, i in RESULT_REGISTERS {
                    if i < event.results.count && cast[usize](register) < registers.count {
                        event.results[i] = registers[cast[usize](register)]
                    }
                }
                event.bytes_at = recording.bytes.count
                if cast[usize](followed.number) < shapes.count {
                    shape :: &shapes[cast[usize](followed.number)]
                    if !read_buffers(program, recording, shape.outputs, shape.outputs_count, followed.words) {
                        return stopped_short(program, recording, "a call's buffer couldn't be read, or was too big to record")
                    }
                }
                event.bytes_count = recording.bytes.count - event.bytes_at
                add_event(recording, event)
                followed.number = NO_THREAD
                push(&waiting, &waiting_count, index)
            }
            else if stop.number == slop_os.FAULT_COUNTER {
                add_event(recording, Event.{kind = .Counter, thread = index, value = stop.address})
                _ = slop_os.intercept_resume(program.intercept, stop.thread, .Continue)
            }
            else {
                return stopped_short(program, recording, sentence("it faulted: %", slop_os.fault_name(stop.number)))
            }
            continue
        }
        // Every stop taken: the next waiting thread runs, if none does
        if running == NO_THREAD && waiting_count > 0 {
            running = pop(&waiting, &waiting_count)
            if cast[usize](running) < threads.count {
                add_event(recording, Event.{kind = .Resume, thread = running})
                _ = slop_os.intercept_resume(program.intercept, threads[cast[usize](running)].id, .Continue)
            }
            continue
        }
        packets : slop_os.Packet[4]
        taken :: slop_os.port_wait(program.port, packets, slop_os.NO_DEADLINE) or_else 0
        for packet, i in packets {
            if cast[u64](i) < taken && packet.kind == .Signal && packet.key == program.end_key {
                add_event(recording, Event.{kind = .End, value = packet.data[1]})
                return recording
            }
        }
    }
}

/**
 * End a recording short: the program killed, and why kept.
 *
 * @param program The program.
 * @param recording The recording so far.
 * @param why Why, a sentence, kept.
 * @return The recording.
 */
stopped_short :: fn(program: Program, recording: ptr[mut Recording], why #escaping : string) -> ptr[mut Recording] {
    recording.problem = why
    _ = slop_os.process_kill(program.process)
    return recording
}

/**
 * Read the buffers a call names into a recording's bytes, one after another.
 *
 * @param program The program, whose memory they're in.
 * @param recording The recording, whose bytes grow.
 * @param buffers The buffers, the first count of them used.
 * @param count How many are used.
 * @param words The call's argument words, which say where they are and how big.
 * @return True once they're read; false if one couldn't be, or is past MAX_BUFFER.
 */
read_buffers :: fn(program: Program, recording: ptr[mut Recording], buffers: Buffer[6], count: u32, words: u64[6]) -> bool {
    for buffer, n in buffers {
        if cast[u32](n) >= count {
            break
        }
        address :: words[cast[usize](buffer.word) % words.count]
        size :: size_of_buffer(buffer, words)
        if size == 0 || address == 0 {
            continue
        }
        if size > MAX_BUFFER {
            return false
        }
        start :: recording.bytes.count
        for i in cast[u64](0)..<size {
            runtime.array_add(&recording.bytes, cast[u8](0))
        }
        end :: recording.bytes.count
        if start > end {
            return false
        }
        if !(slop_os.process_read_memory(program.process, program.space, address, recording.bytes[start..<end]) is_ok) {
            return false
        }
    }
    return true
}

/**
 * Work out how many bytes a buffer has.
 *
 * @param buffer The buffer.
 * @param words The call's argument words.
 * @return Its count of elements times their size, or for a pointer, what it points to's size.
 */
size_of_buffer :: fn(buffer: Buffer, words: u64[6]) -> u64 {
    if buffer.count_word == NO_COUNT {
        return buffer.element
    }
    count :: words[cast[usize](buffer.count_word) % words.count]
    if buffer.element != 0 && count > MAX_BUFFER / buffer.element {
        return MAX_BUFFER + 1
    }
    return count * buffer.element
}

/**
 * Add an event to a recording.
 *
 * @param recording The recording.
 * @param event The event.
 */
add_event :: fn(recording: ptr[mut Recording], event: Event) {
    runtime.array_add(&recording.events, event)
}

/**
 * Find a followed thread by its kernel ID.
 *
 * @param threads The threads followed.
 * @param count How many there are.
 * @param id The kernel ID.
 * @return Its index; NO_THREAD if it isn't followed.
 */
index_of :: fn(threads: ptr[Followed[MAX_THREADS]], count: u32, id: u64) -> u32 {
    for followed, i in threads^ {
        if cast[u32](i) < count && followed.id == id {
            return cast[u32](i)
        }
    }
    return NO_THREAD
}

/**
 * Add a thread to the end of a queue.
 *
 * @param queue The queue.
 * @param count Its length, one more after, if there's room.
 * @param index The thread.
 */
push :: fn(queue: ptr[mut u32[MAX_THREADS]], count: ptr[mut u32], index: u32) {
    slot :: cast[usize](count^)
    if slot < queue^.count {
        queue^[slot] = index
        count^ += 1
    }
}

/**
 * Take the thread at the front of a queue.
 *
 * @param queue The queue, not empty.
 * @param count Its length, one less after.
 * @return The thread.
 */
pop :: fn(queue: ptr[mut u32[MAX_THREADS]], count: ptr[mut u32]) -> u32 {
    if count^ == 0 || queue^.count == 0 {
        return NO_THREAD
    }
    first :: queue^[0]
    for i in cast[usize](1)..<queue^.count {
        if cast[u32](i) < count^ {
            queue^[i - 1] = queue^[i]
        }
    }
    count^ -= 1
    return first
}

/** How a replay went. */
Replayed :: struct {
    /** Whether it went as recorded to the end. */
    exact : bool,
    /** How many calls were replayed. */
    calls : u64,
    /** Where and how it diverged, a sentence on the heap; empty if it didn't. */
    divergence : string,
}

/**
 * Replay a recording: the program, started with the recording's seeds, its intercept attached with RECORDING_POINTS,
 * in the deterministic mode, stopped before its first instruction, led through the recording's events in order.
 *
 * @param program The program.
 * @param shapes Every call's shape (call_shapes).
 * @param recording The recording.
 * @return How it went; the program killed if it diverged.
 */
replay :: fn(program: Program, shapes: CallShape[], recording: ptr[Recording]) -> Replayed {
    _ = slop_os.process_set_traps(program.process, slop_os.TRAP_COUNTER)
    threads : Followed[MAX_THREADS]
    count : u32 = 0
    stops : slop_os.StopInfo[..]
    defer runtime.array_free(&stops)
    result := Replayed.{}
    for event, n in recording.events {
        index :: cast[usize](event.thread)
        if event.kind != .Start && event.kind != .End && (index >= threads.count || event.thread >= count) {
            return diverged(program, result, sentence("event % names a thread that hadn't started", n))
        }
        match event.kind {
            case .Start => {
                stop :: wait_for(program, &stops, 0, true, .ThreadStart) or_return diverged(program, result,
                    sentence("thread % didn't start", event.thread))
                if cast[usize](count) < threads.count {
                    threads[cast[usize](count)] = Followed.{id = stop.thread, number = NO_THREAD}
                    count += 1
                }
            }
            case .Enter => {
                followed :: &threads[index % threads.count]
                stop :: wait_for(program, &stops, followed.id, false, .SyscallEntry) or_return diverged(program, result,
                    sentence("thread % didn't make call % (%) as recorded", event.thread, result.calls, name_of(shapes, event.number)))
                if stop.point != .SyscallEntry {
                    return diverged(program, result, sentence("thread % was to make call % (%), but %", event.thread, result.calls,
                        name_of(shapes, event.number), what_it_did(program, shapes, stop)))
                }
                registers : u64[slop_os.THREAD_REGISTERS]
                _ = slop_os.thread_read_registers(program.process, stop.thread, registers)
                number :: cast[u32](registers[NUMBER_REGISTER])
                words : u64[6]
                for register, i in ARGUMENT_REGISTERS {
                    if i < words.count && cast[usize](register) < registers.count {
                        words[i] = registers[cast[usize](register)]
                    }
                }
                if number != event.number || words != event.words {
                    return diverged(program, result, sentence("thread %'s call % was % as recorded, but % now", event.thread, result.calls,
                        name_of(shapes, event.number), name_of(shapes, number)))
                }
                shape :: &shapes[cast[usize](number) % shapes.count]
                if !same_buffers(program, recording, event, shape.inputs, shape.inputs_count, words) {
                    return diverged(program, result, sentence("thread %'s call % (%) was given other bytes than recorded", event.thread,
                        result.calls, shape.name))
                }
                followed.number = number
                followed.words = words
                followed.answered = shape.answered
                result.calls += 1
                if !shape.answered {
                    _ = slop_os.intercept_resume(program.intercept, stop.thread, .Continue)
                }
            }
            case .Leave => {
                followed :: &threads[index % threads.count]
                shape :: &shapes[cast[usize](followed.number) % shapes.count]
                if followed.answered {
                    // Answered: the buffers it writes written, its result set, and it's let go by Skip at its Resume
                    if !write_buffers(program, recording, event, shape.outputs, shape.outputs_count, followed.words) {
                        return diverged(program, result, sentence("thread %'s call (%) couldn't be answered", event.thread, shape.name))
                    }
                    registers : u64[slop_os.THREAD_REGISTERS]
                    _ = slop_os.thread_read_registers(program.process, followed.id, registers)
                    for register, i in RESULT_REGISTERS {
                        if i < event.results.count && cast[usize](register) < registers.count {
                            registers[cast[usize](register)] = event.results[i]
                        }
                    }
                    _ = slop_os.thread_write_registers(program.process, followed.id, registers)
                }
                else {
                    stop :: wait_for(program, &stops, followed.id, false, .SyscallExit) or_return diverged(program, result,
                        sentence("thread %'s call (%) didn't end as recorded", event.thread, shape.name))
                    if stop.point != .SyscallExit {
                        return diverged(program, result, sentence("thread %'s call (%) was to end, but %", event.thread, shape.name,
                            what_it_did(program, shapes, stop)))
                    }
                    registers : u64[slop_os.THREAD_REGISTERS]
                    _ = slop_os.thread_read_registers(program.process, stop.thread, registers)
                    for register, i in RESULT_REGISTERS {
                        if i < event.results.count && cast[usize](register) < registers.count && registers[cast[usize](register)] != event.results[i] {
                            return diverged(program, result, sentence("thread %'s call (%) gave another result than recorded", event.thread,
                                shape.name))
                        }
                    }
                }
                followed.number = NO_THREAD
            }
            case .Resume => {
                followed :: &threads[index % threads.count]
                action :: if followed.answered { slop_os.InterceptAction.Skip } else { slop_os.InterceptAction.Continue }
                followed.answered = false
                _ = slop_os.intercept_resume(program.intercept, followed.id, action)
            }
            case .Counter => {
                followed :: &threads[index % threads.count]
                stop :: wait_for(program, &stops, followed.id, false, .Fault) or_return diverged(program, result,
                    sentence("thread % didn't read the counter as recorded", event.thread))
                if stop.point != .Fault || stop.number != slop_os.FAULT_COUNTER {
                    return diverged(program, result, sentence("thread % was to read the counter, but %", event.thread,
                        what_it_did(program, shapes, stop)))
                }
                give_counter(program, stop, event.value)
                _ = slop_os.intercept_resume(program.intercept, stop.thread, .Continue)
            }
            case .End => {
                code :: wait_for_end(program) or_return diverged(program, result, "it didn't end as recorded")
                if code != event.value {
                    return Replayed.{calls = result.calls, divergence = sentence("it ended with % rather than %", code, event.value)}
                }
            }
        }
    }
    result.exact = true
    return result
}

/**
 * End a replay that diverged: the program killed, and why given.
 *
 * @param program The program.
 * @param result The replay so far.
 * @param why Where and how, a sentence.
 * @return The result, not exact.
 */
diverged :: fn(program: Program, result: Replayed, why: string) -> Replayed {
    _ = slop_os.process_kill(program.process)
    return Replayed.{calls = result.calls, divergence = why}
}

/**
 * Wait for a thread's next stop, or any thread's stop at a point, keeping the stops that come meanwhile.
 *
 * @param program The program.
 * @param stops The stops come and not yet taken, which this takes from and adds to.
 * @param id The thread's kernel ID; ignored for any.
 * @param any Whether any thread's stop at point will do; otherwise the thread's next, at any point.
 * @param point The point, for any.
 * @return The stop; null if none came within REPLAY_WAIT, or the program ended.
 */
wait_for :: fn(program: Program, stops: ptr[mut slop_os.StopInfo[..]], id: u64, any: bool, point: slop_os.StopPoint) -> slop_os.StopInfo? {
    deadline :: (slop_os.clock_monotonic() or_else 0) + REPLAY_WAIT
    loop {
        loop {
            stop := slop_os.StopInfo.{}
            if !(slop_os.intercept_next(program.intercept, &stop) is_ok) {
                break
            }
            runtime.array_add(stops, stop)
        }
        for stop, i in stops^ {
            // A thread's next stop, wherever it is, for the caller to say where it went instead
            if (any && stop.point == point) || (!any && stop.thread == id) {
                runtime.array_remove(stops, i)
                return stop
            }
        }
        packets : slop_os.Packet[4]
        taken :: slop_os.port_wait(program.port, packets, deadline) or_else 0
        if taken == 0 {
            return null
        }
        for packet, i in packets {
            if cast[u64](i) < taken && packet.kind == .Signal && packet.key == program.end_key {
                return null
            }
        }
    }
}

/**
 * Say what a thread did, at a stop the recording didn't have: the call it made, or the fault.
 *
 * @param program The program.
 * @param shapes Every call's shape.
 * @param stop The stop.
 * @return "made call clock_monotonic", or "ended a call", or "faulted: <fault>", or "started".
 */
what_it_did :: fn(program: Program, shapes: CallShape[], stop: slop_os.StopInfo) -> string {
    match stop.point {
        case .SyscallEntry => {
            registers : u64[slop_os.THREAD_REGISTERS]
            _ = slop_os.thread_read_registers(program.process, stop.thread, registers)
            return sentence("made call %", name_of(shapes, cast[u32](registers[NUMBER_REGISTER])))
        }
        case .SyscallExit => return "ended a call"
        case .Fault => return sentence("faulted: %", slop_os.fault_name(stop.number))
        case .ThreadStart => return "started"
    }
}

/**
 * Wait for the program's end.
 *
 * @param program The program.
 * @return Its code; null if it didn't end within REPLAY_WAIT.
 */
wait_for_end :: fn(program: Program) -> u64? {
    deadline :: (slop_os.clock_monotonic() or_else 0) + REPLAY_WAIT
    loop {
        packets : slop_os.Packet[4]
        taken :: slop_os.port_wait(program.port, packets, deadline) or_else 0
        if taken == 0 {
            return null
        }
        for packet, i in packets {
            if cast[u64](i) < taken && packet.kind == .Signal && packet.key == program.end_key {
                return packet.data[1]
            }
        }
    }
}

/**
 * Tell whether the buffers a call reads hold what the recording's call's did.
 *
 * @param program The program.
 * @param recording The recording.
 * @param event The recorded Enter.
 * @param buffers The call's read buffers, the first count of them used.
 * @param count How many are used.
 * @param words Its argument words now.
 * @return True if every byte is the same.
 */
same_buffers :: fn(program: Program, recording: ptr[Recording], event: Event, buffers: Buffer[6], count: u32, words: u64[6]) -> bool {
    at := event.bytes_at
    for buffer, n in buffers {
        if cast[u32](n) >= count {
            break
        }
        address :: words[cast[usize](buffer.word) % words.count]
        size :: size_of_buffer(buffer, words)
        if size == 0 || address == 0 {
            continue
        }
        if size > MAX_BUFFER || at + cast[usize](size) > recording.bytes.count {
            return false
        }
        now, failed :: runtime.new_array(u8, cast[usize](size))
        if failed != null {
            return false
        }
        defer runtime.free_array(now)
        if !(slop_os.process_read_memory(program.process, program.space, address, now) is_ok) {
            return false
        }
        for byte, i in now {
            if at + i >= recording.bytes.count || recording.bytes[at + i] != byte {
                return false
            }
        }
        at += cast[usize](size)
    }
    return true
}

/**
 * Write the buffers an answered call writes, from the recording.
 *
 * @param program The program.
 * @param recording The recording.
 * @param event The recorded Leave, whose bytes they are.
 * @param buffers The call's written buffers, the first count of them used.
 * @param count How many are used.
 * @param words Its argument words.
 * @return True once they're written; false if one couldn't be.
 */
write_buffers :: fn(program: Program, recording: ptr[Recording], event: Event, buffers: Buffer[6], count: u32, words: u64[6]) -> bool {
    at := event.bytes_at
    for buffer, n in buffers {
        if cast[u32](n) >= count {
            break
        }
        address :: words[cast[usize](buffer.word) % words.count]
        size :: size_of_buffer(buffer, words)
        if size == 0 || address == 0 {
            continue
        }
        end :: at + cast[usize](size)
        if at > end || end > recording.bytes.count || end > event.bytes_at + event.bytes_count {
            return false
        }
        if !(slop_os.process_write_memory(program.process, program.space, address, recording.bytes[at..<end]) is_ok) {
            return false
        }
        at = end
    }
    return true
}

/**
 * Give a thread stopped at a counter read the recording's value: x86-64's edx and eax, or the register AArch64's MRS
 * named, read from the instruction before the thread's program counter.
 *
 * @param program The program.
 * @param stop The thread's FAULT_COUNTER stop.
 * @param value The recorded value.
 */
give_counter :: fn(program: Program, stop: slop_os.StopInfo, value: u64) {
    registers : u64[slop_os.THREAD_REGISTERS]
    _ = slop_os.thread_read_registers(program.process, stop.thread, registers)
    #if TARGET_ARCH == .arm64 {
        instruction : u32 = 0
        _ = slop_os.process_read_memory(program.process, program.space, registers[32] - 4, os.mut_bytes_of(&instruction))
        target :: cast[usize](instruction & 0x1f)
        if target < 31 {
            registers[target] = value
        }
    }
    #else {
        registers[0] = value & 0xffffffff
        registers[3] = value >> 32
    }
    _ = slop_os.thread_write_registers(program.process, stop.thread, registers)
}

/**
 * Name a call by its number.
 *
 * @param shapes Every call's shape.
 * @param number Its number.
 * @return Its name; "an unknown call" past the table.
 */
name_of :: fn(shapes: CallShape[], number: u32) -> string {
    return if cast[usize](number) < shapes.count { shapes[cast[usize](number)].name } else { "an unknown call" }
}

/**
 * Format a sentence on the heap.
 *
 * @param format The format.
 * @param values Its values.
 * @return The sentence, never freed.
 */
sentence :: fn(format: string, values: any...) -> string {
    storage : u8[512]
    text := text_buffer.make(storage)
    text_buffer.append_format(&text, format, values)
    copy, failed :: runtime.new_array(u8, text_buffer.as_string(&text).count)
    if failed != null || copy.count == 0 {
        return ""
    }
    for byte, i in string_bytes(text_buffer.as_string(&text)) {
        if i < copy.count {
            copy[i] = byte
        }
    }
    return string_of(&copy[0], copy.count)
}
