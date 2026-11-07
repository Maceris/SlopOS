package shell

import runtime from "base"
import language from "../../shell_language"
import os from "std"
import terminal from "std"
import text_buffer from "std"
import slop_os from "std/os"
import lifecycle from "std/os/slop_os"

/*
 * Jobs (design/shell.md §6, decisions/0174): the programs a line runs together. One runs in the foreground while the
 * shell waits for it, and Ctrl-C asks its programs to stop over their lifecycle channels, killing those that haven't
 * ended after STOP_GRACE; a line ending with & runs its programs in the background, without the terminal, as a numbered
 * job that jobs lists, wait n finishes, taking its value or error, and stop n ends. A program's Progress shows in the
 * input line while it runs in the foreground, and in jobs.
 *
 * Everything is watched on the terminal client's port, so one wait sees input, programs' ends and their lifecycle
 * channels: a program's end under its key, from FIRST_KEY on, its lifecycle channel under its key plus LIFECYCLE_KEY,
 * and a job's output under its first key plus OUTPUT_KEY, read as it's written.
 */

/** The first key programs are watched under: the terminal client keeps 0 and its STOP_KEY for itself. */
FIRST_KEY : u64 : 1 << 16
/** The most programs a pipeline runs together; each pipeline's keys are this many apart. */
MAX_PROGRAMS :: 64
/** Added to a program's key for its lifecycle channel's binding, which wakes the shell when it says something. */
LIFECYCLE_KEY : u64 : 1 << 40
/**
 * Added to a job's first key for its last program's output's binding, which wakes the shell when it writes, so a job's
 * output is read as it comes rather than held up until wait.
 */
OUTPUT_KEY : u64 : 1 << 41
/** How long programs asked to stop, by Ctrl-C or stop, have to end before they're killed, in nanoseconds: 2 s. */
STOP_GRACE : u64 : 2_000_000_000
/** How long a read of a foreground pipeline's output waits before the shell looks for Ctrl-C again: 50 ms. */
ATTEND_EVERY : u64 : 50_000_000

/** A job in the background: programs started with &, and the number it's known by. */
Job :: struct {
    /** Its number, from 1, which jobs, wait and stop use; never reused while the shell runs. */
    number : u32,
    /** Its programs, the job's own until wait or stop ends them. */
    running : ptr[mut Running],
    /** Whether its end has been said at the prompt, so it's said once. */
    announced : bool,
}

/**
 * Give the port the shell waits on: its terminal client's, which programs and their lifecycle channels are watched on
 * too.
 *
 * @param shell The shell, whose terminal client's port it is.
 * @return The port, the terminal client's own.
 */
watch_port :: fn(shell: ptr[Shell]) -> slop_os.Port {
    return shell.console.port
}

/**
 * Take the packets a wait on the shell's port brought that are its own: a program's end, kept in ended for its turn,
 * or its lifecycle channel saying something, whose Progress is read.
 *
 * @param shell The shell, whose ended grows, whose jobs' and foreground's calls' progress is read, and whose jobs'
 *     output is read as it comes.
 * @param packets The packets; the terminal client's own, under keys below FIRST_KEY, are skipped.
 * @param taken How many of packets the wait filled in, from the first.
 */
take_packets :: fn(shell: ptr[mut Shell], packets: slop_os.Packet[], taken: usize) {
    for packet, i in packets {
        if i >= taken || packet.kind != .Signal || packet.key < FIRST_KEY {
            continue
        }
        if packet.key >= OUTPUT_KEY {
            read_job_output(shell, packet.key - OUTPUT_KEY)
            continue
        }
        if packet.key >= LIFECYCLE_KEY {
            read_progress(shell, packet.key - LIFECYCLE_KEY)
            continue
        }
        runtime.array_add(&shell.ended, EndedProgram.{key = packet.key, code = packet.data[1]})
    }
}

/**
 * Read what a job's last program has written so far, without waiting, into the job's collected values.
 *
 * @param shell The shell, whose jobs are looked in.
 * @param first_key The job's first key; nothing's read for one no job has.
 */
read_job_output :: fn(shell: ptr[mut Shell], first_key: u64) {
    for job in shell.jobs {
        if job.running.first_key != first_key || job.running.calls.count == 0 {
            continue
        }
        last :: job.running.calls[job.running.calls.count - 1]
        if read_some(job.running, last, 0) {
            _ = slop_os.port_unbind(watch_port(shell), first_key + OUTPUT_KEY)
        }
    }
}

/**
 * Read what a program's lifecycle channel says, keeping its newest Progress.
 *
 * @param shell The shell, among whose foreground's and jobs' calls the program's is found by its key.
 * @param key The key the program's end is watched under.
 */
read_progress :: fn(shell: ptr[mut Shell], key: u64) {
    call :: call_watched(shell, key) or_return void
    loop {
        reply :: lifecycle.read(call.lifecycle) or_break
        if reply.answer == .Progress {
            call.progress = reply.sequence
            call.reporting = true
        }
    }
}

/**
 * Find a started program by the key its end's watched under, in the foreground or a job.
 *
 * @param shell The shell, whose foreground and jobs are looked in.
 * @param key The key.
 * @return The program's call; null if none running has the key.
 */
call_watched :: fn(shell: ptr[mut Shell], key: u64) -> ptr[mut Call]? {
    match shell.foreground {
        case Some(running) => {
            for call in running.calls {
                if call.started && call.key == key {
                    return call
                }
            }
        }
        case None => {}
    }
    for job in shell.jobs {
        for call in job.running.calls {
            if call.started && call.key == key {
                return call
            }
        }
    }
    return null
}

/**
 * Tell whether a program's end has been seen, without taking it.
 *
 * @param shell The shell, whose ended is looked in.
 * @param call The program's call; one not started has nothing to end, and counts as ended.
 * @return True if it's ended, or never started, or its end was waited for already.
 */
has_ended :: fn(shell: ptr[Shell], call: ptr[Call]) -> bool {
    if !call.started || call.waited {
        return true
    }
    for each in shell.ended {
        if each.key == call.key {
            return true
        }
    }
    return false
}

/**
 * See to what the shell does while it waits for programs: Ctrl-C, which asks them to stop, unless one has the terminal,
 * whose Ctrl-C is its own; programs that haven't stopped after STOP_GRACE, which are killed; and their progress, shown
 * in the input line.
 *
 * @param shell The shell, whose terminal is asked for an Interrupt without waiting, and shows the progress.
 * @param running The programs waited for, which Ctrl-C stops.
 */
attend :: fn(shell: ptr[mut Shell], running: ptr[mut Running]) {
    // A program on the terminal has the input, Ctrl-C with it
    if !running.terminal && running.stop_by == 0 && terminal.interrupted(&shell.console) {
        _ = terminal.write_line(&shell.console, "^C")
        stop_running(shell, running)
    }
    if running.stop_by != 0 && (slop_os.clock_monotonic() or_else 0) >= running.stop_by {
        kill_running(shell, running)
    }
    show_progress(shell, running)
}

/**
 * Ask programs running together to stop, over their lifecycle channels, giving them STOP_GRACE to end.
 *
 * @param shell The shell, whose ended says which have ended already, and aren't asked.
 * @param running The programs; their stop_by is set, once.
 */
stop_running :: fn(shell: ptr[mut Shell], running: ptr[mut Running]) {
    if running.stop_by != 0 {
        return void
    }
    for call in running.calls {
        if !has_ended(shell, call) {
            _ = lifecycle.stop(call.lifecycle)
        }
    }
    running.stop_by = (slop_os.clock_monotonic() or_else 0) + STOP_GRACE
}

/**
 * Kill the programs running together that haven't ended, with the kill right the shell has over its children.
 *
 * @param shell The shell, whose ended says which have ended already.
 * @param running The programs; once killed, their ends come as any other's do, as killed.
 */
kill_running :: fn(shell: ptr[mut Shell], running: ptr[mut Running]) {
    for call in running.calls {
        if !has_ended(shell, call) {
            runtime.log_info("% didn't stop in time, so it's killed", call.tree.text)
            _ = slop_os.process_kill(call.launched.process)
        }
    }
    running.stop_by = slop_os.NO_DEADLINE
}

/**
 * Show the progress of programs running in the foreground in the input line: each that's said any, by name and
 * percent; nothing's shown if none has.
 *
 * @param shell The shell, whose terminal shows it.
 * @param running The programs, whose calls' progress is shown.
 */
show_progress :: fn(shell: ptr[mut Shell], running: ptr[Running]) {
    storage : u8[256]
    out := text_buffer.make(storage)
    progress_text(&out, running)
    if out.count > 0 {
        shown :: text_buffer.as_string(&out)
        _ = terminal.show_input(&shell.console, string_bytes(shown), shown.count)
    }
}

/**
 * Append the progress programs running together have said: each that's said any, as its name and percent.
 *
 * @param out The text appended to; nothing's appended if none has.
 * @param running The programs.
 */
progress_text :: fn(out: ptr[mut text_buffer.TextBuffer], running: ptr[Running]) {
    for call in running.calls {
        if !call.reporting {
            continue
        }
        if out.count > 0 {
            text_buffer.append(out, "  ")
        }
        text_buffer.append(out, call.tree.text)
        text_buffer.append(out, " ")
        text_buffer.append_unsigned(out, cast[u64](call.progress / 10))
        text_buffer.append(out, "%")
    }
}

/**
 * Wait for the program watched under a key to end, seeing to Ctrl-C and progress meanwhile (attend); the ends of others
 * seen meanwhile are kept, in the shell's ended, for their turn.
 *
 * @param shell The shell, whose port it waits on.
 * @param key The key the program's end is watched under.
 * @param running The programs it's among, which Ctrl-C stops.
 * @return The program's exit code; null if the port couldn't be waited on, so its end can't be seen.
 */
wait_for :: fn(shell: ptr[mut Shell], key: u64, running: ptr[mut Running]) -> u64? {
    loop {
        for each, i in shell.ended {
            if each.key == key {
                code :: each.code
                runtime.array_remove(&shell.ended, i)
                return code
            }
        }
        attend(shell, running)
        deadline :: if running.stop_by != 0 && running.stop_by != slop_os.NO_DEADLINE { running.stop_by } else { slop_os.NO_DEADLINE }
        packets : slop_os.Packet[8]
        taken :: match slop_os.port_wait(watch_port(shell), packets, deadline) {
            case Ok(count) => count
            case Error(error) => return null
        }
        take_packets(shell, packets, cast[usize](taken))
    }
}

/**
 * Wait until a channel end has something to read, or its other end's gone, seeing to Ctrl-C and progress every
 * ATTEND_EVERY meanwhile (attend).
 *
 * @param shell The shell, which attends to its terminal.
 * @param running The programs the end's from, which Ctrl-C stops.
 * @param end The end, which stays the caller's; a port is bound to it while this waits, and closed after.
 */
wait_readable :: fn(shell: ptr[mut Shell], running: ptr[mut Running], end: slop_os.Channel) {
    port :: os.port_for(slop_os.startup_block().budget, end) or_return void
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    loop {
        packets : slop_os.Packet[1]
        if (slop_os.port_wait(port, packets, (slop_os.clock_monotonic() or_else 0) + ATTEND_EVERY) or_else 1) > 0 {
            return void
        }
        attend(shell, running)
    }
}

/**
 * Take a packet that came while the shell read a line (terminal.read_line's Other), and say a job's end once all its
 * programs have ended.
 *
 * @param shell The shell, whose ended and progress take the packet, and whose terminal says which jobs have ended.
 * @param packet The packet.
 */
take_while_reading :: fn(shell: ptr[mut Shell], packet: slop_os.Packet) {
    packets :: slop_os.Packet.[packet]
    take_packets(shell, packets, 1)
    for &job in shell.jobs {
        if job.announced {
            continue
        }
        finished := true
        for call in job.running.calls {
            finished = finished && has_ended(shell, call)
        }
        if finished {
            job.announced = true
            say(shell, ended_text(job^))
        }
    }
}

/** The most records of what a job's last program writes that the shell keeps for wait; past them, they're dropped. */
MAX_JOB_RECORDS :: 10000

/**
 * Say that a job has ended: how many records it wrote, if any, and how many of them were dropped past MAX_JOB_RECORDS.
 *
 * @param job The job, its programs ended.
 * @return The line, on the heap, never freed.
 */
ended_text :: fn(job: Job) -> string {
    kept :: match job.running.collected {
        case Some(list) => list.items.count
        case None => cast[usize](0)
    }
    if kept == 0 && job.running.dropped == 0 {
        return message("[%1] ended: wait %1 for what it gave", job.number)
    }
    if job.running.dropped == 0 {
        return message("[%1] ended, with %2 records: wait %1 for them", job.number, kept)
    }
    return message("[%1] ended, with %2 records, the first %3 kept: wait %1 for them", job.number,
        cast[u64](kept) + job.running.dropped, kept)
}

// ---- Jobs in the background

/**
 * Start a line's programs in the background, for pipeline &: a numbered job, which jobs, wait and stop work on.
 *
 * Only programs run in the background: a call of one, or a pipeline of them. None is given the terminal; one that needs
 * it can't run there. What the last writes is read as it's written, and kept for wait.
 *
 * @param shell The shell, which starts the programs and keeps the job.
 * @param tree The Background node, its child the call or pipeline.
 * @return Null once it's started; an error for anything but programs, or the start's.
 */
start_job :: fn(shell: ptr[mut Shell], tree #escaping : ptr[Node]) -> Result[Value, EvalError] {
    inner :: first_child(tree) or_return error_at(tree.at, "& needs a command before it")
    trees : ptr[Node][..]
    defer runtime.array_free(&trees)
    if inner.kind == .Pipeline {
        for each in inner.children {
            runtime.array_add(&trees, each)
        }
    }
    else {
        runtime.array_add(&trees, inner)
    }
    for each in trees {
        if !is_program(shell, each) {
            return error_at(each.at, "only programs run in the background: a call, or a pipeline of them")
        }
    }
    running :: start_programs(shell, trees, null, true)?
    running.keep_at_most = MAX_JOB_RECORDS
    // Its output read as it's written, so it never waits for wait
    if running.from != NO_END {
        signals :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
        _ = slop_os.port_bind(watch_port(shell), cast[slop_os.Handle](running.from), signals, running.first_key + OUTPUT_KEY, .Persistent)
    }
    shell.last_job += 1
    runtime.array_add(&shell.jobs, Job.{number = shell.last_job, running = running})
    say(shell, message("[%] started", shell.last_job))
    return .Ok(.Null)
}

/**
 * List the jobs in the background, for jobs: each one's number, whether it's running or ended, its programs, and their
 * progress.
 *
 * @param shell The shell, whose jobs are listed on its terminal.
 * @param tree The Call node of jobs, which takes nothing.
 * @return Null.
 */
list_jobs :: fn(shell: ptr[mut Shell], tree: ptr[Node]) -> Result[Value, EvalError] {
    if tree.children.count > 0 {
        return error_at(tree.at, "jobs takes nothing")
    }
    if shell.jobs.count == 0 {
        say(shell, "no jobs")
    }
    for job in shell.jobs {
        storage : u8[512]
        out := text_buffer.make(storage)
        text_buffer.append(&out, "[")
        text_buffer.append_unsigned(&out, cast[u64](job.number))
        finished := true
        for call in job.running.calls {
            finished = finished && has_ended(shell, call)
        }
        text_buffer.append(&out, if finished { "]  ended    " } else { "]  running  " })
        for call, i in job.running.calls {
            if i > 0 {
                text_buffer.append(&out, " | ")
            }
            text_buffer.append(&out, call.tree.text)
        }
        progress : u8[256]
        said := text_buffer.make(progress)
        progress_text(&said, job.running)
        if said.count > 0 && !finished {
            text_buffer.append(&out, "  ")
            text_buffer.append(&out, text_buffer.as_string(&said))
        }
        say(shell, text_buffer.as_string(&out))
    }
    return .Ok(.Null)
}

/**
 * Find the job a call of wait or stop names: its one argument, a job's number, or with none, the newest.
 *
 * @param shell The shell, whose jobs are looked in.
 * @param tree The Call node, of wait or stop.
 * @return The job's index in the shell's jobs; an error for more than one argument, one that isn't a number, or a
 *     number no job has.
 */
job_named :: fn(shell: ptr[mut Shell], tree: ptr[Node]) -> Result[usize, EvalError] {
    if tree.children.count > 1 {
        return .Error(EvalError.{message = message("% takes a job's number", tree.text), at = tree.at})
    }
    if shell.jobs.count == 0 {
        return .Error(EvalError.{message = "there are no jobs", at = tree.at})
    }
    argument :: first_child(tree) or_return .Ok(shell.jobs.count - 1)
    given :: if argument.kind == .Word { word_as("int", argument.text) or_else Value.Null } else { evaluate(shell, argument)? }
    number :: match given {
        case Int(value) => value
        case _ => return .Error(EvalError.{message = message("% takes a job's number, not %", tree.text, argument.text), at = argument.at})
    }
    for job, i in shell.jobs {
        if cast[i64](job.number) == number {
            return .Ok(i)
        }
    }
    return .Error(EvalError.{message = message("there's no job %", number), at = argument.at})
}

/**
 * Finish a job, for wait [n]: its output read and its programs waited for, as in the foreground, where Ctrl-C stops it;
 * the job is gone after.
 *
 * @param shell The shell, whose job is finished and taken off its jobs.
 * @param tree The Call node of wait.
 * @return What its last program wrote, a list of records, or Null without an output; or its first program's error.
 */
wait_job :: fn(shell: ptr[mut Shell], tree: ptr[Node]) -> Result[Value, EvalError] {
    index :: job_named(shell, tree)?
    if index >= shell.jobs.count {
        return error_at(tree.at, "there's no such job")
    }
    running :: shell.jobs[index].running
    runtime.array_remove(&shell.jobs, index)
    defer end_running(shell, running)
    return finish_programs(shell, running)
}

/**
 * End a job, for stop [n]: its programs asked to stop, killed if they haven't after STOP_GRACE, and waited for; the job
 * is gone after, and what it wrote with it.
 *
 * @param shell The shell, whose job is ended and taken off its jobs.
 * @param tree The Call node of stop.
 * @return Null.
 */
stop_job :: fn(shell: ptr[mut Shell], tree: ptr[Node]) -> Result[Value, EvalError] {
    index :: job_named(shell, tree)?
    if index >= shell.jobs.count {
        return error_at(tree.at, "there's no such job")
    }
    job :: shell.jobs[index]
    runtime.array_remove(&shell.jobs, index)
    stop_running(shell, job.running)
    end_running(shell, job.running)
    say(shell, message("[%] stopped", job.number))
    return .Ok(.Null)
}
