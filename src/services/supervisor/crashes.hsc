package supervisor

import os from "std"
import slop_os from "std/os"
import lifecycle from "std/os/slop_os"
import log_line from "../../log_line"
import crash_reports from "../../crash_reports"

/*
 * Crash reports of the services the supervisor starts (decisions/0183, 12a). Each is launched with an intercept of its
 * faults (os.LaunchOptions.faults), reported on the supervisor's port under CRASH_KEY plus its entry's index. At a
 * fault the supervisor makes a report of it, logs it as a typed record in its own source, and kills the service, whose
 * end then comes as any other's, and which is started again as one that ended is.
 */

/** The port key of a service's faults' intercept, whose stops come as packets of kind Stop, plus its entry's index. */
CRASH_KEY : u64 : 9000

/**
 * Take a service's fault stops: report each, and kill the service, which is started again once its end arrives.
 *
 * @param supervisor The supervisor, whose entry at index is reported on.
 * @param index The entry's index in started; out of range, or one without a faults' intercept, does nothing.
 */
crashed :: fn(supervisor: ptr[mut Supervisor], index: usize) {
    if index >= supervisor.started_count || index >= supervisor.started.count {
        return void
    }
    entry :: &supervisor.started[index]
    faults :: entry.faults or_return void
    storage := crash_reports.Storage.{}
    reports :: crash_reports.take(entry.process, faults, entry.image, entry.name, &storage)
    for &report in reports {
        crash_reports.log(report^)
        log_line.write(supervisor.log, "supervisor: % crashed: %", entry.name, slop_os.fault_name(report.fault))
    }
    if reports.count > 0 {
        _ = slop_os.process_kill(entry.process)
    }
}

/**
 * Close a service's faults' intercept and its address space's handle, once it's ended.
 *
 * @param entry The entry, whose faults is null after.
 */
forget_faults :: fn(entry: ptr[mut Started]) {
    match entry.faults {
        case Some(faults) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](faults.intercept))
            _ = slop_os.handle_close(cast[slop_os.Handle](faults.space))
        }
        case None => {}
    }
    entry.faults = null
}

/**
 * Take the faults' intercept kept for the program launched last, for its entry.
 *
 * @param supervisor The supervisor, whose launched_faults is null after.
 * @return The intercept and address space, which move to the caller; null if there are none.
 */
take_faults :: fn(supervisor: ptr[mut Supervisor]) -> os.LaunchedFaults? {
    faults :: supervisor.launched_faults
    supervisor.launched_faults = null
    return faults
}

/**
 * Close a faults' intercept kept from a launch no entry took.
 *
 * @param supervisor The supervisor, whose launched_faults is null after.
 */
forget_launched_faults :: fn(supervisor: ptr[mut Supervisor]) {
    match take_faults(supervisor) {
        case Some(faults) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](faults.intercept))
            _ = slop_os.handle_close(cast[slop_os.Handle](faults.space))
        }
        case None => {}
    }
}

/** The number test_crash's ping carries, which a service's answer echoes and the supervisor ignores. */
TEST_CRASH_PING : u32 : 0x7e57
/** How many times, a millisecond apart, test_crash tries to read a suspended thread's registers. */
TEST_CRASH_ATTEMPTS :: 100

/**
 * Make a service crash, for test_crash: its first thread suspended, woken by a ping if it waits, its program counter
 * sent to its own stack, which can't be run, and resumed, so it faults there at once; then wait for its crash to be
 * reported and for it to be started again.
 *
 * @param supervisor The supervisor, whose port is handled meanwhile.
 * @param name The service's name, as started has it.
 * @return True once it's running again; false if nothing was running under name, its thread couldn't be changed, or
 *     it's done for good.
 */
crash_and_wait :: fn(supervisor: ptr[mut Supervisor], name: string) -> bool {
    index := NOWHERE
    for entry, i in supervisor.started {
        if i < supervisor.started_count && entry.name == name && entry.running {
            index = i
        }
    }
    if index >= supervisor.started.count {
        return false
    }
    process :: supervisor.started[index].process
    restarts :: supervisor.started[index].restarts
    ids : u64[1]
    if (slop_os.process_threads(process, ids) or_else 0) == 0 {
        return false
    }
    log_line.write(supervisor.log, "supervisor: test_crash: crashing %", name)
    slop_os.thread_suspend(process, ids[0]) or_return false
    // One waiting is suspended once it wakes, which a ping on its lifecycle channel makes it do
    if supervisor.started[index].lifecycle != NONE {
        _ = lifecycle.ping(supervisor.started[index].lifecycle, TEST_CRASH_PING)
    }
    registers : u64[slop_os.THREAD_REGISTERS]
    // A thread running on another CPU is suspended once it leaves it, so its registers are read when they can be
    read := false
    for attempt in 0..<TEST_CRASH_ATTEMPTS {
        if slop_os.thread_read_registers(process, ids[0], registers) is_ok {
            read = true
            break
        }
        pause(supervisor, 1_000_000)
    }
    changed :: read && cast[usize](crash_reports.PC_REGISTER) < registers.count
    if changed {
        registers[crash_reports.PC_REGISTER] = registers[crash_reports.STACK_REGISTER] & ~cast[u64](15)
    }
    wrote : Result[void, slop_os.ControlError] = .Error(.NotStopped)
    if changed {
        wrote = slop_os.thread_write_registers(process, ids[0], registers)
    }
    _ = slop_os.thread_resume(process, ids[0])
    if !(wrote is_ok) {
        log_line.write(supervisor.log, "supervisor: test_crash: %'s thread couldn't be sent elsewhere: read %, wrote %", name, read, wrote)
        return false
    }
    loop {
        wait_and_handle(supervisor)
    }
    while !supervisor.started[index].done && !(supervisor.started[index].running && supervisor.started[index].restarts > restarts)
    return supervisor.started[index].running
}
