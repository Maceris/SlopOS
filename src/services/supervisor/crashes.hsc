package supervisor

import os from "std"
import slop_os from "std/os"
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

/**
 * Make a service crash, for test_crash (crash_reports.make_crash), then wait for its crash to be reported and for it
 * to be started again.
 *
 * @param supervisor The supervisor, whose port is handled meanwhile.
 * @param name The service's name, as started has it.
 * @return True once it's running again; false if nothing was running under name, it couldn't be made to crash, or
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
    restarts :: supervisor.started[index].restarts
    log_line.write(supervisor.log, "supervisor: test_crash: crashing %", name)
    ping : slop_os.Channel? = if supervisor.started[index].lifecycle != NONE { supervisor.started[index].lifecycle } else { null }
    match crash_reports.make_crash(supervisor.started[index].process, ping) {
        case Ok => {}
        case Error(error) => {
            log_line.write(supervisor.log, "supervisor: test_crash: % couldn't be made to crash: %", name, error)
            return false
        }
    }
    loop {
        wait_and_handle(supervisor)
    }
    while !supervisor.started[index].done && !(supervisor.started[index].running && supervisor.started[index].restarts > restarts)
    return supervisor.started[index].running
}
