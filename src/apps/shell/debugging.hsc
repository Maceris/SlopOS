package shell

import runtime from "base"
import language from "../../shell_language"
import os from "std"
import terminal from "std"
import text_buffer from "std"
import slop_os from "std/os"
import lifecycle from "std/os/slop_os"
import crash_reports from "../../crash_reports"

/*
 * The debugger (decisions/0183, 12b): debug name arguments runs a program as a call would, under an intercept of its
 * faults and system calls (os.LaunchFaults.debugging), so it stops at its first call, before its main runs. Then lines
 * read at the "(debug) " prompt control it: breakpoints by function (break), found through the symbols program, and
 * watchpoints by address (watch), set in the stopped thread's debug registers (thread_set_debug); step, continue,
 * where, registers, threads, print and quit. A stop at a breakpoint or watchpoint is stepped past, its slots off for
 * the one instruction, before it goes on.
 */

/** The key the debugged program's stops come under, on the debugger's own port. */
DEBUG_STOP_KEY : u64 : 1
/** The key the debugged program's end comes under. */
DEBUG_END_KEY : u64 : 2
/** The most bytes of the symbols program's answer the debugger reads. */
DEBUG_ANSWER_BYTES :: 4096

/** A program being debugged. */
Debugging :: struct #scoped {
    /** The shell, which says what's found. */
    shell : ptr[mut Shell],
    /** The program's call, started; ended by end_call once the program has. */
    call : ptr[mut Call],
    /** The debugger's port, which the program's stops and end come on. */
    port : slop_os.Port,
    /** The program's intercept and address space, the call's. */
    faults : os.LaunchedFaults,
    /** The thread stopped now; 0 while none is. */
    thread : u64,
    /** Its stop, while it's stopped. */
    stop : slop_os.StopInfo,
    /** Whether the program has ended. */
    ended : bool,
    /** The code it ended with, once it has. */
    code : u64,
    /** The breakpoints and watchpoints set, which each stopped thread is given as it goes on. */
    debug : slop_os.ThreadDebug,
    /** Whether it's gone on since its first stop, so the intercept stops only at faults. */
    going : bool,
}

/**
 * Run a program under the debugger, for debug: its call made as any other's, started stopped at its first system
 * call, then controlled by lines read until it ends or quit ends it.
 *
 * @param shell The shell, which reads the lines and starts the program.
 * @param tree The Call node of debug, its first child the program's name, the rest its arguments.
 * @return Null once the program has ended; an error if there's no program to debug, or it couldn't be made or started.
 */
debug_program :: fn(shell: ptr[mut Shell], tree #escaping : ptr[Node]) -> Result[Value, EvalError] {
    if tree.children.count == 0 || tree.children[0].kind != .Word {
        return error_at(tree.at, "debug needs a program and its arguments: debug name arguments")
    }
    named :: tree.children[0]
    inner := runtime.new(Node)
    inner^ = Node.{kind = .Call, at = named.at, text = named.text}
    for child, i in tree.children {
        if i > 0 {
            runtime.array_add(&inner.children, child)
        }
    }
    call :: match prepare_call(shell, inner, false) {
        case Ok(made) => made
        case Error(error) => return .Error(error)
    }
    defer end_call(call)
    port :: slop_os.port_create(slop_os.startup_block().budget) or_return error_at(tree.at, "there's no memory to debug it")
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    match start_debugged(shell, call, port) {
        case Some(error) => return .Error(error)
        case None => {}
    }
    faults :: call.launched.faults or_return error_at(tree.at, "it started without its intercept")
    session := Debugging.{shell = shell, call = call, port = port, faults = faults}
    if !wait_debugged(&session) {
        say(shell, message("% ended with % before it stopped", inner.text, session.code))
        return .Ok(.Null)
    }
    say(shell, message("% stopped before it began; break, watch, step, continue, where, registers, threads, print, quit",
        inner.text))
    editor := terminal.LineEditor.{}
    loop {
        if session.ended {
            say(shell, message("% ended with %", inner.text, session.code))
            return .Ok(.Null)
        }
        match terminal.read_line(&editor, &shell.console, "(debug) ") {
            case Line(line) => {
                run_debug_line(&session, line)
                runtime.free_array(bit_cast[u8[]](line))
            }
            case Interrupted => {}
            case Other(packet) => take_while_reading(shell, packet)
            case _ => {
                end_debugged(&session)
                return .Ok(.Null)
            }
        }
    }
}

/**
 * Start a debugged program, as start_call starts a call's, but with its stops and end on the debugger's port.
 *
 * @param shell The shell, whose process manager starts it.
 * @param call The call, prepared; started, its launched and lifecycle set.
 * @param port The debugger's port.
 * @return Null once it's started; why it didn't otherwise.
 */
start_debugged :: fn(shell: ptr[mut Shell], call: ptr[mut Call], port: slop_os.Port) -> EvalError? {
    tree :: call.tree
    manager :: shell.manager or_return EvalError.{message = "the shell can't start programs: it has no process manager", at = tree.at}
    ends :: lifecycle.make(slop_os.startup_block().budget) or_return EvalError.{message = "there's no memory to start it", at = tree.at}
    options := os.LaunchOptions.{watch = os.LaunchWatch.{port = port, key = DEBUG_END_KEY}, lifecycle = ends.b,
        faults = os.LaunchFaults.{port = port, key = DEBUG_STOP_KEY, debugging = true}}
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
 * Wait for the debugged program's next stop, or its end.
 *
 * @param session The session, whose thread and stop are set at a stop, and ended and code at the end.
 * @return True at a stop; false once it's ended, or the port couldn't be waited on, as if it had.
 */
wait_debugged :: fn(session: ptr[mut Debugging]) -> bool {
    loop {
        stop := slop_os.StopInfo.{}
        if slop_os.intercept_next(session.faults.intercept, &stop) is_ok {
            session.thread = stop.thread
            session.stop = stop
            return true
        }
        packets : slop_os.Packet[4]
        taken :: match slop_os.port_wait(session.port, packets, slop_os.NO_DEADLINE) {
            case Ok(count) => count
            case Error(error) => {
                session.ended = true
                return false
            }
        }
        for packet, i in packets {
            if cast[u64](i) < taken && packet.kind == .Signal && packet.key == DEBUG_END_KEY {
                session.ended = true
                session.code = packet.data[1]
                session.thread = 0
                return false
            }
        }
    }
}

/**
 * Run one line read at the debugger's prompt.
 *
 * @param session The session.
 * @param line The line: a command and its words, separated by spaces.
 */
run_debug_line :: fn(session: ptr[mut Debugging], line #escaping : string) {
    words : string[4]
    count :: split_words(line, &words)
    if count == 0 {
        return void
    }
    command :: words[0]
    shell :: session.shell
    if command == "help" {
        say(shell, "break function, watch address [size], delete n, step, continue, where, registers, threads, print address, quit")
    }
    else if command == "break" && count == 2 {
        set_breakpoint(session, words[1])
    }
    else if command == "watch" && count >= 2 {
        size :: if count >= 3 { number_of(words[2]) or_else 0 } else { 8 }
        set_watchpoint(session, number_of(words[1]) or_else 0, size)
    }
    else if command == "delete" && count == 2 {
        slot :: number_of(words[1]) or_else 0
        if slot >= 1 && slot <= cast[u64](slop_os.DEBUG_SLOTS) && cast[usize](slot - 1) < session.debug.slots.count {
            session.debug.slots[cast[usize](slot - 1)] = slop_os.DebugSlot.{}
            say(shell, message("deleted %", slot))
        }
        else {
            say(shell, "no such breakpoint or watchpoint")
        }
    }
    else if command == "step" {
        if go_on(session, true) {
            say_stop(session)
        }
    }
    else if command == "continue" {
        if go_on(session, false) {
            say_stop(session)
        }
    }
    else if command == "where" {
        say_where(session)
    }
    else if command == "registers" {
        say_registers(session)
    }
    else if command == "threads" {
        say_threads(session)
    }
    else if command == "print" && count == 2 {
        say_memory(session, number_of(words[1]) or_else 0)
    }
    else if command == "quit" {
        end_debugged(session)
    }
    else {
        say(shell, message("% isn't a debugger command; help lists them", command))
    }
}

/**
 * Let the stopped thread go on: past a breakpoint or watchpoint it's at first, one instruction with its slots off;
 * then with them all, to its next stop, or, stepping, only that one instruction.
 *
 * @param session The session, whose intercept stops only at faults from the first time it goes on.
 * @param step Whether it runs only one instruction.
 * @return True at its next stop; false once it's ended, or with nothing stopped to go on.
 */
go_on :: fn(session: ptr[mut Debugging], step: bool) -> bool {
    if session.thread == 0 {
        say(session.shell, "nothing's stopped")
        return false
    }
    process :: session.call.launched.process
    if !session.going {
        _ = slop_os.intercept_set(session.faults.intercept, 0, slop_os.STOP_FAULT)
        session.going = true
    }
    at_slot :: session.stop.point == .Fault && (session.stop.number == slop_os.FAULT_BREAKPOINT || session.stop.number == slop_os.FAULT_WATCHPOINT)
    if at_slot || step {
        // One instruction, its slots off, so a breakpoint where it is doesn't stop it again
        stepping := slop_os.ThreadDebug.{step = true}
        _ = slop_os.thread_set_debug(process, session.thread, &stepping)
        _ = slop_os.intercept_resume(session.faults.intercept, session.thread, .Continue)
        if !wait_debugged(session) {
            return false
        }
        if step || session.stop.number != slop_os.FAULT_SINGLE_STEP {
            _ = slop_os.thread_set_debug(process, session.thread, &session.debug)
            return true
        }
    }
    _ = slop_os.thread_set_debug(process, session.thread, &session.debug)
    _ = slop_os.intercept_resume(session.faults.intercept, session.thread, .Continue)
    session.thread = 0
    return wait_debugged(session)
}

/**
 * Say where the stopped thread is and why: its function, by the symbols program, and the stop.
 *
 * @param session The session, stopped.
 */
say_stop :: fn(session: ptr[mut Debugging]) {
    registers : u64[slop_os.THREAD_REGISTERS]
    _ = slop_os.thread_read_registers(session.call.launched.process, session.thread, registers)
    at :: name_of_address(session, registers[crash_reports.PC_REGISTER])
    stop :: session.stop
    if stop.point != .Fault {
        say(session.shell, message("stopped at % before a system call", at))
    }
    else if stop.number == slop_os.FAULT_WATCHPOINT {
        say(session.shell, message("stopped at %: watchpoint at %{#x}", at, stop.address))
    }
    else if stop.number == slop_os.FAULT_SINGLE_STEP {
        say(session.shell, message("stopped at %: step", at))
    }
    else {
        say(session.shell, message("stopped at %: %", at, slop_os.fault_name(stop.number)))
    }
}

/**
 * Name an address in the debugged program: its function and the offset into it, as the symbols program finds it.
 *
 * @param session The session, whose program's file is read.
 * @param address The address.
 * @return "name+0x1c", on the heap, never freed; the address in hex if it's not in a function.
 */
name_of_address :: fn(session: ptr[mut Debugging], address: u64) -> string {
    image :: session.call.launched.image
    if address >= image {
        offsets :: u64.[address - image]
        answer : u8[DEBUG_ANSWER_BYTES]
        count :: ask_symbols(session.shell, session.call.executable, offsets, null, answer)
        at : usize = 0
        name :: next_line(answer, count, &at)
        if name != "" && name != "?" {
            return message("%", name)
        }
    }
    return message("%{#x}", address)
}

/**
 * Set a breakpoint at a function, found by name through the symbols program, in the first free slot.
 *
 * @param session The session, whose debug state takes it.
 * @param name The function's name, as the program's symbol table has it, like "program.main".
 */
set_breakpoint :: fn(session: ptr[mut Debugging], name: string) {
    offsets : u64[1]
    // On the heap, with its newline, as the symbols program takes names
    names :: message("%\n", name)
    answer : u8[DEBUG_ANSWER_BYTES]
    count :: ask_symbols(session.shell, session.call.executable, offsets[0..<0], names, answer)
    at : usize = 0
    line :: next_line(answer, count, &at)
    found :: number_of(line) or_else 0
    if found == 0 {
        say(session.shell, message("there's no function named %", name))
        return void
    }
    slot :: free_slot(session) or_return void
    if slot >= session.debug.slots.count {
        return void
    }
    session.debug.slots[slot] = slop_os.DebugSlot.{address = session.call.launched.image + found, kind = .Execute}
    say(session.shell, message("breakpoint % at %", slot + 1, name))
}

/**
 * Set a watchpoint on writes to an address, in the first free slot.
 *
 * @param session The session, whose debug state takes it.
 * @param address The address, a multiple of size.
 * @param size How many bytes: 1, 2, 4 or 8.
 */
set_watchpoint :: fn(session: ptr[mut Debugging], address: u64, size: u64) {
    if address == 0 || (size != 1 && size != 2 && size != 4 && size != 8) || address % size != 0 {
        say(session.shell, "watch takes an address, and a size of 1, 2, 4 or 8 bytes it's a multiple of")
        return void
    }
    slot :: free_slot(session) or_return void
    if slot >= session.debug.slots.count {
        return void
    }
    session.debug.slots[slot] = slop_os.DebugSlot.{address = address, kind = .Write, size = cast[u8](size)}
    say(session.shell, message("watchpoint % at %{#x}", slot + 1, address))
}

/**
 * Find the first slot that's Off.
 *
 * @param session The session; saying so when there's none.
 * @return Its index; null when every slot's used.
 */
free_slot :: fn(session: ptr[mut Debugging]) -> usize? {
    for slot, i in session.debug.slots {
        if slot.kind == .Off {
            return i
        }
    }
    say(session.shell, message("every one of the % breakpoints and watchpoints is set; delete one first", slop_os.DEBUG_SLOTS))
    return null
}

/**
 * Say the stopped thread's stack, each frame named, as a crash report walks it.
 *
 * @param session The session, stopped.
 */
say_where :: fn(session: ptr[mut Debugging]) {
    if session.thread == 0 {
        say(session.shell, "nothing's stopped")
        return void
    }
    launched :: session.call.launched
    report :: crash_reports.make(launched.process, session.faults.space, launched.image, session.call.tree.text, session.stop)
    count :: if report.frame_count <= crash_reports.MAX_FRAMES { report.frame_count } else { crash_reports.MAX_FRAMES }
    for i in cast[u32](0)..<count {
        if cast[usize](i) < report.frames.count {
            say(session.shell, message("  #% %", i, name_of_address(session, report.frames[cast[usize](i)])))
        }
    }
}

/**
 * Say the stopped thread's program counter, stack pointer and frame pointer.
 *
 * @param session The session, stopped.
 */
say_registers :: fn(session: ptr[mut Debugging]) {
    registers : u64[slop_os.THREAD_REGISTERS]
    if session.thread == 0 || !(slop_os.thread_read_registers(session.call.launched.process, session.thread, registers) is_ok) {
        say(session.shell, "nothing's stopped")
        return void
    }
    say(session.shell, message("pc %{#x}, sp %{#x}, fp %{#x}", registers[crash_reports.PC_REGISTER],
        registers[crash_reports.STACK_REGISTER], registers[crash_reports.FRAME_REGISTER]))
}

/**
 * Say the debugged program's threads, marking the stopped one.
 *
 * @param session The session.
 */
say_threads :: fn(session: ptr[mut Debugging]) {
    ids : u64[16]
    count :: slop_os.process_threads(session.call.launched.process, ids) or_else 0
    for id, i in ids {
        if cast[u32](i) >= count {
            break
        }
        say(session.shell, message("thread %%", id, if id == session.thread { ", stopped" } else { "" }))
    }
}

/**
 * Say the 8 bytes at an address in the debugged program, as a little-endian number.
 *
 * @param session The session.
 * @param address The address.
 */
say_memory :: fn(session: ptr[mut Debugging], address: u64) {
    bytes : u8[8]
    if !(slop_os.process_read_memory(session.call.launched.process, session.faults.space, address, bytes) is_ok) {
        say(session.shell, message("%{#x} can't be read", address))
        return void
    }
    say(session.shell, message("%{#x}: %{#x}", address, crash_reports.word_at(bytes, 0)))
}

/**
 * End the debugged program, killed, and wait for its end.
 *
 * @param session The session, ended after.
 */
end_debugged :: fn(session: ptr[mut Debugging]) {
    if session.ended {
        return void
    }
    _ = slop_os.process_kill(session.call.launched.process)
    loop {
        if !wait_debugged(session) {
            break
        }
        // Stops while it's killed let go
        _ = slop_os.intercept_resume(session.faults.intercept, session.thread, .Kill)
    }
}

/**
 * Split a line into words at spaces.
 *
 * @param line The line.
 * @param words Where the words go, views of line, as many as fit.
 * @return How many words were found, at most words' count.
 */
split_words :: fn(line #escaping : string, words: ptr[mut string[4]]) -> usize {
    bytes :: string_bytes(line)
    count : usize = 0
    start : usize = 0
    for i in cast[usize](0)..<(bytes.count + 1) {
        at_end :: i >= bytes.count || bytes[i] == 0x20
        if !at_end {
            continue
        }
        if i > start && count < words.count {
            words^[count] = string_of(&bytes[start], i - start)
            count += 1
        }
        start = i + 1
    }
    return count
}

/**
 * Read a number, decimal or, after 0x, hexadecimal.
 *
 * @param text The text.
 * @return Its value; null if it isn't a number, or doesn't fit 64 bits.
 */
number_of :: fn(text: string) -> u64? {
    bytes :: string_bytes(text)
    hex :: bytes.count > 2 && bytes[0] == 0x30 && (bytes[1] == 0x78 || bytes[1] == 0x58)
    base : u64 = if hex { 16 } else { 10 }
    value : u64 = 0
    if bytes.count == 0 {
        return null
    }
    for byte, i in bytes {
        if hex && i < 2 {
            continue
        }
        digit : u64 = 0
        if byte >= 0x30 && byte <= 0x39 {
            digit = cast[u64](byte - 0x30)
        }
        else if hex && byte >= 0x61 && byte <= 0x66 {
            digit = cast[u64](byte - 0x61) + 10
        }
        else if hex && byte >= 0x41 && byte <= 0x46 {
            digit = cast[u64](byte - 0x41) + 10
        }
        else {
            return null
        }
        if value > (~cast[u64](0) - digit) / base {
            return null
        }
        value = value * base + digit
    }
    return value
}
