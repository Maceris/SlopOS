package shell

import runtime from "base"
import language from "../../shell_language"
import strings from "std"
import text_buffer from "std"
import slop_os from "std/os"
import os from "std"
import crash_reports from "../../crash_reports"
import symbols from "../symbols"

/*
 * Crash reports of the shell's programs (decisions/0183, 12a). Each program's launched with an intercept of its faults
 * (os.LaunchOptions.faults), reported on the shell's port under its key plus FAULT_KEY. At a fault the shell makes a
 * report of it, logs it as a typed record, keeps it for crashes, which names its frames through the symbols program,
 * and ends the program, which its wait then says crashed.
 */

/** Added to a program's key for its faults' intercept, whose stops come as packets of kind Stop. */
FAULT_KEY : u64 : 1 << 42
/** How many crash reports the shell keeps for crashes, the newest; older ones are dropped. */
MAX_CRASHES :: 16
/** The most bytes a kept report's heading has; one longer is cut off. */
CRASH_TEXT_LIMIT :: 2048

/**
 * Take the fault stops of a program the shell started, at its Stop packet: report each, keep its text, and end the
 * program.
 *
 * @param shell The shell, whose crashes keep the reports' text.
 * @param key The key the program's end is watched under; nothing's done for one no running program has.
 */
take_faults :: fn(shell: ptr[mut Shell], key: u64) {
    call :: call_watched(shell, key) or_return void
    take_faults_of(shell, call)
}

/**
 * Take the fault stops of programs running together, for a wait that isn't on the shell's port, as a read of their
 * output is (attend).
 *
 * @param shell The shell, whose crashes keep the reports' text.
 * @param running The programs.
 */
poll_faults :: fn(shell: ptr[mut Shell], running: ptr[mut Running]) {
    for call in running.calls {
        if call.started && !call.crashed {
            take_faults_of(shell, call)
        }
    }
}

/**
 * Take the fault stops of a program the shell started, if any: report each, keep it for crashes, and end the program.
 *
 * @param shell The shell, whose crashes keep the reports.
 * @param call The program's call, started; one launched without a faults' intercept has none to take.
 */
take_faults_of :: fn(shell: ptr[mut Shell], call: ptr[mut Call]) {
    faults :: call.launched.faults or_return void
    storage := crash_reports.Storage.{}
    reports :: crash_reports.take(call.launched.process, faults, call.launched.image, call.tree.text, &storage)
    for &report in reports {
        crash_reports.log(report^)
        keep_crash(shell, report, call.executable)
        if !call.crashed {
            call.crashed = true
            call.fault = report.fault
        }
    }
    if reports.count > 0 {
        _ = slop_os.process_kill(call.launched.process)
    }
}

/** A crash the shell keeps for crashes: what the report says, and the program's file, to name its frames by. */
Crash :: struct {
    /** Its first lines: the program, the fault, and the thread (crash_reports.describe's), on the heap. */
    heading : string,
    /** The program's file, a handle the shell keeps to read it; NO_HANDLE if it couldn't be kept. */
    executable : slop_os.Memory,
    /** Where the program's image was. */
    image : u64,
    /** The stack, innermost first, as the report's frames. */
    frames : u64[crash_reports.MAX_FRAMES],
    /** How many of frames are used. */
    count : u32,
}

/**
 * Keep a crash report for crashes, dropping the oldest past MAX_CRASHES.
 *
 * @param shell The shell, whose crashes it's added to.
 * @param report The report, copied.
 * @param executable The program's file, duplicated to be read again; the call's still.
 */
keep_crash :: fn(shell: ptr[mut Shell], report: ptr[crash_reports.CrashReport], executable: slop_os.Memory) {
    bytes : u8[CRASH_TEXT_LIMIT]
    text := text_buffer.make(bytes)
    crash_reports.describe(report, &text, false)
    heading :: strings.clone(text_buffer.as_string(&text)) or_return void
    rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_READ) | cast[u32](slop_os.RIGHT_DUPLICATE) | cast[u32](slop_os.RIGHT_TRANSFER))
    kept :: slop_os.handle_duplicate(cast[slop_os.Handle](executable), rights) or_else slop_os.NO_HANDLE
    crash := Crash.{heading = heading, executable = cast[slop_os.Memory](kept), image = report.image, frames = report.frames,
        count = report.frame_count}
    if shell.crashes.count >= MAX_CRASHES {
        forget_crash(&shell.crashes[0])
        runtime.array_remove(&shell.crashes, 0)
    }
    runtime.array_add(&shell.crashes, crash)
}

/**
 * Let go of a kept crash's heading and file.
 *
 * @param crash The crash, which can't be used after.
 */
forget_crash :: fn(crash: ptr[mut Crash]) {
    strings.free_string(crash.heading)
    if cast[slop_os.Handle](crash.executable) != slop_os.NO_HANDLE {
        _ = slop_os.handle_close(cast[slop_os.Handle](crash.executable))
    }
}

/**
 * Show the crash reports of the programs the shell started, oldest first, for crashes: each one's heading, then its
 * frames, each named by the function it's in where the symbols program can say (name_frames).
 *
 * @param shell The shell, whose crashes are shown on its terminal.
 * @param tree The Call node of crashes, which takes nothing.
 * @return Null.
 */
show_crashes :: fn(shell: ptr[mut Shell], tree: ptr[Node]) -> Result[Value, EvalError] {
    if tree.children.count > 0 {
        return error_at(tree.at, "crashes takes nothing")
    }
    if shell.crashes.count == 0 {
        say(shell, "no crashes")
    }
    for &crash in shell.crashes {
        say(shell, crash.heading)
        names : u8[NAMES_BYTES]
        named :: name_frames(shell, crash, names)
        at : usize = 0
        count :: if crash.count <= crash_reports.MAX_FRAMES { crash.count } else { crash_reports.MAX_FRAMES }
        for i in cast[u32](0)..<count {
            if cast[usize](i) >= crash.frames.count {
                break
            }
            address :: crash.frames[cast[usize](i)]
            name :: next_line(names, named, &at)
            storage : u8[256]
            line := text_buffer.make(storage)
            if address < crash.image {
                text_buffer.append_format(&line, "  #% %{#x}", i, address)
            }
            else if name == "" || name == "?" {
                text_buffer.append_format(&line, "  #% image+%{#x}", i, address - crash.image)
            }
            else {
                text_buffer.append_format(&line, "  #% % (image+%{#x})", i, name, address - crash.image)
            }
            say(shell, text_buffer.as_string(&line))
        }
    }
    return .Ok(.Null)
}

/** The most bytes of the names the symbols program sends for one crash. */
NAMES_BYTES :: 8192
/** The memory the symbols program runs with: 8 MiB, room for the program file it reads whole. */
SYMBOLS_BUDGET : u64 : 8 << 20

/** What the symbols program's entry takes: its log, the crashed program's file, its reply channel and the offsets. */
SymbolsGrants :: struct {
    /** None: it logs through base's logger. */
    log : slop_os.DebugLog?,
    /** The crashed program's file, a read-only copy that moves to it. */
    program : slop_os.Memory,
    /** Its end of the channel it sends the names on. */
    reply : slop_os.Channel,
    /** The frames' offsets in the image. */
    offsets : u64[],
}

/**
 * Name a crash's frames through the symbols program (decisions/0183), a process that reads the crashed program's file
 * holding nothing else, and wait for its answer.
 *
 * @param shell The shell, whose programs connection finds the symbols program, and whose process manager starts it.
 * @param crash The crash, whose file is copied for it; its frames below the image are named "?".
 * @param into Where the names go: a line per frame, in order.
 * @return How many bytes of into are the names; 0 if there's no symbols program, the crash has no file, or it
 *     couldn't be started or didn't answer.
 */
name_frames :: fn(shell: ptr[mut Shell], crash: ptr[Crash], into: mut u8[]) -> usize {
    manager :: shell.manager or_return 0
    if cast[slop_os.Handle](crash.executable) == slop_os.NO_HANDLE {
        return 0
    }
    found :: find_program(shell, "symbols") or_return 0
    defer {
        _ = slop_os.handle_close(cast[slop_os.Handle](found.executable))
        _ = slop_os.handle_close(cast[slop_os.Handle](found.manifest))
    }
    offsets : u64[crash_reports.MAX_FRAMES]
    count :: if crash.count <= crash_reports.MAX_FRAMES { cast[usize](crash.count) } else { cast[usize](crash_reports.MAX_FRAMES) }
    for i in cast[usize](0)..<count {
        if i < offsets.count && i < crash.frames.count {
            offsets[i] = if crash.frames[i] >= crash.image { crash.frames[i] - crash.image } else { 0 }
        }
    }
    block :: slop_os.startup_block()
    pair :: slop_os.channel_create(block.budget, 0, 0) or_return 0
    defer slop_os.handle_close(cast[slop_os.Handle](pair.a))
    port :: os.port_for(block.budget, pair.a) or_else cast[slop_os.Port](slop_os.NO_HANDLE)
    if cast[slop_os.Handle](port) == slop_os.NO_HANDLE {
        _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
        return 0
    }
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_READ) | cast[u32](slop_os.RIGHT_TRANSFER))
    program :: slop_os.handle_duplicate(cast[slop_os.Handle](crash.executable), rights) or_else slop_os.NO_HANDLE
    if program == slop_os.NO_HANDLE {
        _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
        return 0
    }
    grants :: SymbolsGrants.{program = cast[slop_os.Memory](program), reply = pair.b, offsets = view_of(&offsets[0], count)}
    launched :: match os.launch(manager, shell.manager_port, "symbols", found.executable, SYMBOLS_BUDGET, symbols.main, grants) {
        case Ok(made) => made
        case Error(error) => {
            _ = slop_os.handle_close(program)
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
            return 0
        }
    }
    defer {
        _ = slop_os.handle_close(cast[slop_os.Handle](launched.process))
        _ = slop_os.handle_close(cast[slop_os.Handle](launched.budget))
    }
    handles : slop_os.Handle[1]
    got :: os.receive(pair.a, port, into, handles) or_return 0
    return cast[usize](got.size)
}

/**
 * Take the next line of text.
 *
 * @param text The text, lines ending in newlines.
 * @param count How many of its bytes are the text.
 * @param at Where the next line starts, moved past it.
 * @return The line, without its newline, a view of text; "" past the last.
 */
next_line :: fn(text: u8[], count: usize, at: ptr[mut usize]) -> string {
    start :: at^
    end := start
    loop {
        if end >= count || end >= text.count || text[end] == 0x0a {
            break
        }
        end += 1
    }
    at^ = end + 1
    if end <= start || start >= text.count {
        return ""
    }
    return string_of(&text[start], end - start)
}
