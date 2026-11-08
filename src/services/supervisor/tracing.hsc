package supervisor

import runtime from "base"
import slop_os from "std/os"
import lifecycle from "std/os/slop_os"
import log_line from "../../log_line"

/*
 * The trace (decisions/0183, 12d), which the supervisor's debug log may read (RIGHT_DEBUG_LOG_TRACE). With test_trace
 * and the kernel's trace_boot, the supervisor drains it as it starts each service, keeping when each thread first ran,
 * for the boot's timeline, logged once everything has started; and traces a known exchange, a ping of the clock
 * service on its lifecycle channel and its answer, which has to show the clock service woken by the ping and run to
 * answer it. The supervisor's own wake, by the answer, is there only when it waited, which it often doesn't, the
 * answer there first.
 */

/** How many trace events the supervisor takes at a time. */
TRACE_BATCH :: 256
/** The Ping's sequence test_trace's ping carries. */
TRACE_PING : u32 : 0x7ace
/** How long test_trace waits for the ping's answer, in nanoseconds: 2 s. */
TRACE_PING_WAIT : u64 : 2_000_000_000

/** When a thread first ran, as the trace showed it. */
FirstRun :: struct {
    /** The thread's ID. */
    thread : u64,
    /** When, in nanoseconds of the monotonic clock. */
    time : u64,
}

/**
 * Take the trace's events so far, keeping when each thread first ran, for the boot's timeline; nothing without
 * test_trace.
 *
 * @param supervisor The supervisor, whose first_runs grow.
 */
drain_trace :: fn(supervisor: ptr[mut Supervisor]) {
    if !supervisor.tracing {
        return void
    }
    events : slop_os.TraceEvent[TRACE_BATCH]
    loop {
        taken :: slop_os.trace_read(supervisor.log, events) or_else 0
        for event, i in events {
            if cast[u32](i) >= taken {
                break
            }
            if event.kind == .Switch && !has_run(supervisor, event.thread) {
                runtime.array_add(&supervisor.first_runs, FirstRun.{thread = event.thread, time = event.time})
            }
        }
        if taken < cast[u32](TRACE_BATCH) {
            break
        }
    }
}

/**
 * Tell whether a thread's first run is kept.
 *
 * @param supervisor The supervisor.
 * @param thread The thread's ID.
 * @return True if it is.
 */
has_run :: fn(supervisor: ptr[Supervisor], thread: u64) -> bool {
    for run in supervisor.first_runs {
        if run.thread == thread {
            return true
        }
    }
    return false
}

/**
 * Run test_trace once everything has started: log the boot's timeline, each running service's first run, earliest
 * first; then trace a ping of the clock service and its answer.
 *
 * @param supervisor The supervisor.
 */
check_trace :: fn(supervisor: ptr[mut Supervisor]) {
    drain_trace(supervisor)
    // Each running service's first run: its threads' earliest
    services : u32 = 0
    found : u32 = 0
    for entry, index in supervisor.started {
        if index >= supervisor.started_count || !entry.running {
            continue
        }
        services += 1
        ids : u64[16]
        count :: slop_os.process_threads(entry.process, ids) or_else 0
        earliest : u64 = 0
        for id, i in ids {
            if cast[u32](i) >= count {
                break
            }
            for run in supervisor.first_runs {
                if run.thread == id && (earliest == 0 || run.time < earliest) {
                    earliest = run.time
                }
            }
        }
        if earliest != 0 {
            found += 1
            log_line.write(supervisor.log, "supervisor: boot timeline: % first ran at % ms", entry.name, earliest / 1_000_000)
        }
    }
    if found == services {
        log_line.write(supervisor.log, "supervisor: test_trace: every running service is in the boot's timeline")
    }
    else {
        log_line.write(supervisor.log, "supervisor: test_trace: % of % running services are in the boot's timeline", found, services)
    }
    trace_ping(supervisor)
}

/**
 * Ping the clock service on its lifecycle channel and wait for its answer, then look for the exchange in the trace:
 * one of its threads made ready, then run.
 *
 * @param supervisor The supervisor.
 */
trace_ping :: fn(supervisor: ptr[mut Supervisor]) {
    index := NOWHERE
    for entry, i in supervisor.started {
        if i < supervisor.started_count && entry.name == "clock" && entry.running && entry.lifecycle != NONE {
            index = i
        }
    }
    if index >= supervisor.started.count {
        log_line.write(supervisor.log, "supervisor: test_trace: no clock service to ping")
        return void
    }
    entry :: &supervisor.started[index]
    // What came before, taken
    drain_trace(supervisor)
    if !lifecycle.ping(entry.lifecycle, TRACE_PING) {
        log_line.write(supervisor.log, "supervisor: test_trace: the clock service couldn't be pinged")
        return void
    }
    deadline :: (slop_os.clock_monotonic() or_else 0) + TRACE_PING_WAIT
    answered := false
    // Waiting on a port of its own for the answer, so the answer wakes it, as an exchange does
    waiter :: slop_os.port_create(supervisor.block.budget) or_return void
    defer slop_os.handle_close(cast[slop_os.Handle](waiter))
    loop {
        match lifecycle.read(entry.lifecycle) {
            case Some(reply) => answered = reply.answer == .Pong && reply.sequence == TRACE_PING
            case None => {
                _ = slop_os.port_bind(waiter, cast[slop_os.Handle](entry.lifecycle), slop_os.SIGNAL_READABLE, 1, .Once)
                packets : slop_os.Packet[1]
                _ = slop_os.port_wait(waiter, packets, deadline)
            }
        }
        if answered || (slop_os.clock_monotonic() or_else 0) >= deadline {
            break
        }
    }
    // Every CPU's, in the order they happened
    events : slop_os.TraceEvent[..]
    defer runtime.array_free(&events)
    batch : slop_os.TraceEvent[TRACE_BATCH]
    loop {
        taken :: slop_os.trace_read(supervisor.log, batch) or_else 0
        for event, i in batch {
            if cast[u32](i) < taken {
                runtime.array_add(&events, event)
            }
        }
        if taken < cast[u32](TRACE_BATCH) {
            break
        }
    }
    sort_by_time(events[0..<events.count])
    clocks : u64[16]
    clock_count :: slop_os.process_threads(entry.process, clocks) or_else 0
    // In order: a clock thread woken, then a clock thread run
    stage := 0
    for event in events {
        if stage == 0 && event.kind == .Wake && listed(clocks, clock_count, event.thread) {
            stage = 1
        }
        else if stage == 1 && event.kind == .Switch && listed(clocks, clock_count, event.thread) {
            stage = 2
        }
    }
    if answered && stage == 2 {
        log_line.write(supervisor.log, "supervisor: test_trace: a ping's exchange is in the trace: the clock service woken by it, and run to answer")
    }
    else {
        log_line.write(supervisor.log, "supervisor: test_trace: a ping's exchange isn't in the trace: answered %, got to step % in % events", answered,
            stage, events.count)
    }
}

/**
 * Sort trace events by when they happened, earliest first.
 *
 * @param events The events, sorted in place.
 */
sort_by_time :: fn(events: mut slop_os.TraceEvent[]) {
    for i in cast[usize](1)..<events.count {
        j := i
        loop {
            if j == 0 || j >= events.count {
                break
            }
            before :: j - 1
            if before >= events.count || events[before].time <= events[j].time {
                break
            }
            held :: events[j]
            events[j] = events[before]
            events[before] = held
            j = before
        }
    }
}

/**
 * Tell whether a thread's ID is among some.
 *
 * @param ids The IDs.
 * @param count How many of them are used.
 * @param thread The thread's ID.
 * @return True if it's among the first count.
 */
listed :: fn(ids: u64[16], count: u32, thread: u64) -> bool {
    for id, i in ids {
        if cast[u32](i) < count && id == thread {
            return true
        }
    }
    return false
}
