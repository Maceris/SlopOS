package shell

import runtime from "base"
import language from "../../shell_language"
import strings from "std"
import text_buffer from "std"
import slop_os from "std/os"
import crash_reports from "../../crash_reports"

/*
 * Crash reports of the shell's programs (decisions/0183, 12a). Each program's launched with an intercept of its faults
 * (os.LaunchOptions.faults), reported on the shell's port under its key plus FAULT_KEY. At a fault the shell makes a
 * report of it, logs it as a typed record, keeps its text for crashes, and ends the program, which its wait then says
 * crashed.
 */

/** Added to a program's key for its faults' intercept, whose stops come as packets of kind Stop. */
FAULT_KEY : u64 : 1 << 42
/** How many crash reports the shell keeps for crashes, the newest; older ones are dropped. */
MAX_CRASHES :: 16
/** The most bytes a kept report's text has; one longer is cut off. */
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
 * Take the fault stops of a program the shell started, if any: report each, keep its text, and end the program.
 *
 * @param shell The shell, whose crashes keep the reports' text.
 * @param call The program's call, started; one launched without a faults' intercept has none to take.
 */
take_faults_of :: fn(shell: ptr[mut Shell], call: ptr[mut Call]) {
    faults :: call.launched.faults or_return void
    storage := crash_reports.Storage.{}
    reports :: crash_reports.take(call.launched.process, faults, call.launched.image, call.tree.text, &storage)
    for &report in reports {
        crash_reports.log(report^)
        bytes : u8[CRASH_TEXT_LIMIT]
        text := text_buffer.make(bytes)
        crash_reports.describe(report, &text)
        keep_crash(shell, text_buffer.as_string(&text))
        if !call.crashed {
            call.crashed = true
            call.fault = report.fault
        }
    }
    if reports.count > 0 {
        _ = slop_os.process_kill(call.launched.process)
    }
}

/**
 * Keep a crash report's text for crashes, dropping the oldest past MAX_CRASHES.
 *
 * @param shell The shell, whose crashes it's added to.
 * @param text The report's text, copied.
 */
keep_crash :: fn(shell: ptr[mut Shell], text: string) {
    copy :: strings.clone(text) or_return void
    if shell.crashes.count >= MAX_CRASHES {
        strings.free_string(shell.crashes[0])
        runtime.array_remove(&shell.crashes, 0)
    }
    runtime.array_add(&shell.crashes, copy)
}

/**
 * Show the crash reports of the programs the shell started, oldest first, for crashes.
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
    for text in shell.crashes {
        say(shell, text)
    }
    return .Ok(.Null)
}
