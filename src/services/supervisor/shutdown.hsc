package supervisor

import os from "std"
import slop_os from "std/os"
import lifecycle from "std/os/slop_os"
import log_line from "../../log_line"

/*
 * A graceful shutdown (decisions/0182, P4): every service and driver the supervisor started is asked to stop on its
 * lifecycle channel, in the reverse of the order they started in, each given STOP_DEADLINE to end and all of them
 * SHUTDOWN_DEADLINE; what's still running then is killed, and named in the log. The volumes are committed just before
 * the storage manager is asked to stop, once everything that writes to them has, so nothing done is lost.
 */

/** How long each service is given to end once it's asked to stop, in nanoseconds. */
STOP_DEADLINE : u64 : 2_000_000_000
/** How long the services are given to stop, all of them, in nanoseconds; past it, each is killed at once. */
SHUTDOWN_DEADLINE : u64 : 20_000_000_000
/** How long a killed service is waited for, to know it's gone, in nanoseconds. */
KILL_WAIT : u64 : 500_000_000

/**
 * Stop everything the supervisor started, the last started first, the volumes committed before the storage manager
 * stops, and log how it went.
 *
 * @param supervisor The supervisor; each entry stopped is marked done and ended on request, so it isn't started again.
 *     Nothing else it does is handled meanwhile.
 */
stop_everything :: fn(supervisor: ptr[mut Supervisor]) {
    started_at :: slop_os.clock_monotonic() or_else 0
    deadline :: started_at + SHUTDOWN_DEADLINE
    committed := false
    stopped : u32 = 0
    killed : u32 = 0
    count :: supervisor.started_count
    for back in 0..<count {
        index :: count - 1 - back
        if index >= supervisor.started.count {
            continue
        }
        // The volumes, once what writes to them has stopped
        if index == supervisor.storage_slot && !committed {
            commit_volumes(supervisor)
            committed = true
        }
        entry :: &supervisor.started[index]
        if !entry.running {
            continue
        }
        if stop_entry(supervisor, index, deadline) {
            stopped += 1
        }
        else {
            killed += 1
        }
    }
    if !committed {
        commit_volumes(supervisor)
    }
    took :: ((slop_os.clock_monotonic() or_else started_at) - started_at) / 1_000_000
    log_line.write(supervisor.log, "supervisor: stopped % services in % ms, and killed %", stopped, took, killed)
}

/**
 * Have the storage manager commit every writable volume, if it's running.
 *
 * @param supervisor The supervisor.
 */
commit_volumes :: fn(supervisor: ptr[mut Supervisor]) {
    if !is_running(supervisor, supervisor.storage_slot) {
        return void
    }
    match ask_storage_once(supervisor, supervisor.storage_slot, .CommitAll) {
        case Done => {}
        case _ => log_line.write(supervisor.log, "supervisor: the volumes couldn't all be committed before shutting down")
    }
}

/**
 * Ask one entry to stop, and wait for it to end; kill it if it hasn't by its deadline.
 *
 * @param supervisor The supervisor.
 * @param index The entry's index, running.
 * @param deadline The shutdown's deadline, which the entry's own STOP_DEADLINE is cut to.
 * @return True if it ended when asked; false if it had to be killed.
 */
stop_entry :: fn(supervisor: ptr[mut Supervisor], index: usize, deadline: u64) -> bool {
    if index >= supervisor.started.count {
        return true
    }
    entry :: &supervisor.started[index]
    entry.ended_on_request = true
    entry.done = true
    entry.running = false
    now :: slop_os.clock_monotonic() or_else 0
    own :: if now + STOP_DEADLINE < deadline { now + STOP_DEADLINE } else { deadline }
    // test_ignore_stop's service isn't asked, as if it didn't listen
    if entry.lifecycle != NONE && entry.name != supervisor.ignore_stop {
        _ = lifecycle.stop(entry.lifecycle)
    }
    if ended_by(supervisor, entry.process, own) {
        return true
    }
    log_line.write(supervisor.log, "supervisor: killed %, which didn't stop when asked", entry.name)
    _ = slop_os.process_kill(entry.process)
    _ = ended_by(supervisor, entry.process, (slop_os.clock_monotonic() or_else 0) + KILL_WAIT)
    return false
}

/**
 * Wait for a process to end, until a deadline.
 *
 * @param supervisor The supervisor, whose budget pays for the port waited on.
 * @param process The process.
 * @param deadline When to stop waiting, in the monotonic clock's nanoseconds; one passed already waits not at all.
 * @return True if it's ended.
 */
ended_by :: fn(supervisor: ptr[mut Supervisor], process: slop_os.Process, deadline: u64) -> bool {
    port :: slop_os.port_create(supervisor.block.budget) or_return false
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    if slop_os.port_bind(port, cast[slop_os.Handle](process), slop_os.SIGNAL_TERMINATED, 0, .Once) is_error {
        // Its handle's gone, as once it's ended and been let go of
        return true
    }
    packets : slop_os.Packet[1]
    taken :: slop_os.port_wait(port, packets, deadline) or_else 0
    return taken > 0
}
