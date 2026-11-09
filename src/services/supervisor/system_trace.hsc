package supervisor

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import log_line from "../../log_line"
import trace from "../../protocols/trace"
import events from "../../protocols/events"

/*
 * Tracing the whole system for an administrator (decisions/0185, 12g): once one's allowed it on the trusted path, the
 * terminal service asks for a trace connection (power's TraceConnection), which the supervisor makes and serves; one
 * at a time, a new one closing the last. Trace turns the kernel's trace on for so long, drained into each thread's
 * counts as the supervisor's loop goes round, and answers with each service's switches and wakes once it's done.
 */

/**
 * The rings of an administrator's trace and events connections: 8 KiB, so a message of the most a message has, 4 KiB,
 * fits, as a trace's rows or a record with its typed argument can be; a channel's message is at most half its ring.
 */
ADMIN_RING_BYTES : u32 : 8192
/** The port key a trace connection's end is bound under. */
TRACE_KEY : u64 : 11000

/** What a thread did while traced. */
ThreadCount :: struct {
    /** Its ID. */
    thread : u64,
    /** How many times it was switched to. */
    switches : u32,
    /** How many times it was made ready. */
    wakes : u32,
}

/**
 * Make a trace connection for the terminal service, closing the one before.
 *
 * @param supervisor The supervisor, which keeps its end, bound to its port under TRACE_KEY.
 * @return The other end, for the terminal service; null if it couldn't be made.
 */
trace_connection :: fn(supervisor: ptr[mut Supervisor]) -> os.Channel[trace.Trace]? {
    close_trace(supervisor)
    pair :: match os.channel_for[trace.Trace](supervisor.block.budget, ADMIN_RING_BYTES) {
        case Ok(made) => made
        case Error(error) => {
            log_line.write(supervisor.log, "supervisor: no trace connection: %", error)
            return null
        }
    }
    signals :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    if slop_os.port_bind(supervisor.port, cast[slop_os.Handle](pair.b), signals, TRACE_KEY, .Persistent) is_error {
        log_line.write(supervisor.log, "supervisor: no trace connection: its end couldn't be bound")
        _ = slop_os.handle_close(cast[slop_os.Handle](pair.a))
        _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
        return null
    }
    supervisor.trace_end = pair.b
    log_line.write(supervisor.log, "supervisor: a trace connection for an administrator")
    return os.Channel[trace.Trace].{end = pair.a}
}

/**
 * Close the trace connection, if there's one, ending a trace under way, unanswered.
 *
 * @param supervisor The supervisor.
 */
close_trace :: fn(supervisor: ptr[mut Supervisor]) {
    if supervisor.trace_end == NONE {
        return void
    }
    _ = slop_os.port_unbind(supervisor.port, TRACE_KEY)
    _ = slop_os.handle_close(cast[slop_os.Handle](supervisor.trace_end))
    supervisor.trace_end = NONE
    stop_tracing(supervisor)
}

/**
 * Answer what's asked on the trace connection, and go on with a trace under way: drained, and answered once it's done.
 *
 * @param supervisor The supervisor, from its loop, each time round.
 */
serve_trace :: fn(supervisor: ptr[mut Supervisor]) {
    if supervisor.trace_until != 0 {
        drain_counts(supervisor)
        now :: slop_os.clock_monotonic() or_else 0
        if now >= supervisor.trace_until {
            finish_trace(supervisor)
        }
    }
    end :: supervisor.trace_end
    if end == NONE {
        return void
    }
    into := os.Incoming.{}
    loop {
        match trace.receive_request(end, supervisor.port, &into, false) {
            case Received => {}
            case Empty => return void
            case Unsupported => {
                _ = trace.answer_unsupported(end, supervisor.port)
                continue
            }
            case _ => {
                close_trace(supervisor)
                return void
            }
        }
        match os.message_of[trace.Request](&into)^ {
            case Trace(milliseconds) => {
                if supervisor.trace_until != 0 {
                    answer_trace(supervisor, .Busy)
                    continue
                }
                if milliseconds == 0 || milliseconds > cast[u32](trace.MAX_MILLISECONDS)
                    || (!supervisor.tracing && (slop_os.trace_set(supervisor.log, true) is_error)) {
                    answer_trace(supervisor, .Refused)
                    continue
                }
                // What's in the ring from before isn't this trace's
                runtime.array_reset(&supervisor.trace_counts)
                discard_ring(supervisor)
                supervisor.trace_events = 0
                supervisor.trace_until = (slop_os.clock_monotonic() or_else 0) + cast[u64](milliseconds) * 1_000_000
                log_line.write(supervisor.log, "supervisor: tracing for % ms", milliseconds)
            }
        }
    }
}

/**
 * The deadline the supervisor's loop waits until: a trace's end, if one's under way and earlier.
 *
 * @param supervisor The supervisor.
 * @param deadline Its deadline otherwise.
 * @return The earlier of the two.
 */
trace_deadline :: fn(supervisor: ptr[Supervisor], deadline: u64) -> u64 {
    return if supervisor.trace_until != 0 && supervisor.trace_until < deadline { supervisor.trace_until } else { deadline }
}

/**
 * Take the trace's events so far into each thread's counts.
 *
 * @param supervisor The supervisor, whose trace_counts grow.
 */
drain_counts :: fn(supervisor: ptr[mut Supervisor]) {
    events : slop_os.TraceEvent[TRACE_BATCH]
    loop {
        taken :: slop_os.trace_read(supervisor.log, events) or_else 0
        for event, i in events {
            if cast[u32](i) >= taken {
                break
            }
            supervisor.trace_events += 1
            count := count_of(supervisor, event.thread)
            if event.kind == .Switch {
                count.switches += 1
            }
            else {
                count.wakes += 1
            }
        }
        if taken < cast[u32](TRACE_BATCH) {
            break
        }
    }
}

/**
 * Drop what the trace's ring holds.
 *
 * @param supervisor The supervisor.
 */
discard_ring :: fn(supervisor: ptr[mut Supervisor]) {
    events : slop_os.TraceEvent[TRACE_BATCH]
    loop {
        taken :: slop_os.trace_read(supervisor.log, events) or_else 0
        if taken < cast[u32](TRACE_BATCH) {
            break
        }
    }
}

/**
 * Find a thread's counts, made if it has none.
 *
 * @param supervisor The supervisor.
 * @param thread The thread's ID.
 * @return Its counts, good until the next is made.
 */
count_of :: fn(supervisor: ptr[mut Supervisor], thread: u64) -> ptr[mut ThreadCount] {
    for &each in supervisor.trace_counts {
        if each.thread == thread {
            return each
        }
    }
    runtime.array_add(&supervisor.trace_counts, ThreadCount.{thread = thread})
    last :: supervisor.trace_counts.count - 1
    if last >= supervisor.trace_counts.count {
        return &supervisor.trace_counts[0]
    }
    return &supervisor.trace_counts[last]
}

/**
 * Turn the trace off, unless test_trace keeps it on, and forget the trace under way.
 *
 * @param supervisor The supervisor.
 */
stop_tracing :: fn(supervisor: ptr[mut Supervisor]) {
    if supervisor.trace_until != 0 && !supervisor.tracing {
        _ = slop_os.trace_set(supervisor.log, false)
    }
    supervisor.trace_until = 0
}

/**
 * End the trace under way and answer it: each service's threads' counts added up, the busiest first, those of no
 * service as "others".
 *
 * @param supervisor The supervisor.
 */
finish_trace :: fn(supervisor: ptr[mut Supervisor]) {
    drain_counts(supervisor)
    stop_tracing(supervisor)
    rows : trace.Row[..]
    defer runtime.array_free(&rows)
    others := trace.Row.{}
    for &count in supervisor.trace_counts {
        owner := supervisor.started.count
        for entry, index in supervisor.started {
            if index >= supervisor.started_count || !entry.running {
                continue
            }
            ids : u64[64]
            threads :: slop_os.process_threads(entry.process, ids) or_else 0
            for id, i in ids {
                if cast[u32](i) < threads && id == count.thread {
                    owner = index
                }
            }
        }
        if owner >= supervisor.started.count {
            others.switches += count.switches
            others.wakes += count.wakes
            continue
        }
        name :: supervisor.started[owner].name
        add_to_row(&rows, name, count.switches, count.wakes)
    }
    add_to_row(&rows, "others", others.switches, others.wakes)
    sort_rows(rows[0..<rows.count])
    shown :: if rows.count < cast[usize](trace.MAX_ROWS) { rows.count } else { cast[usize](trace.MAX_ROWS) }
    out := os.Outgoing.{}
    response :: os.begin[trace.Response](&out)
    response^ = .Traced(trace.Traced.{rows = os.append(&out, rows[0..<shown]), events = supervisor.trace_events})
    if supervisor.trace_end != NONE {
        _ = trace.send_response(supervisor.trace_end, supervisor.port, &out)
    }
    log_line.write(supervisor.log, "supervisor: traced % events", supervisor.trace_events)
}

/**
 * Add a thread's counts to its service's row, made if it has none.
 *
 * @param rows The rows.
 * @param name The service's name.
 * @param switches The thread's switches.
 * @param wakes The thread's wakes.
 */
add_to_row :: fn(rows: ptr[mut trace.Row[..]], name: string, switches: u32, wakes: u32) {
    bytes :: string_bytes(name)
    for &row in rows^ {
        if cast[usize](row.name_bytes) != bytes.count || bytes.count == 0 || bytes.count > row.name.count {
            continue
        }
        if string_of(&row.name[0], bytes.count) == name {
            row.switches += switches
            row.wakes += wakes
            return void
        }
    }
    made := trace.Row.{switches = switches, wakes = wakes}
    for byte, i in bytes {
        if i < made.name.count {
            made.name[i] = byte
            made.name_bytes += 1
        }
    }
    runtime.array_add(rows, made)
}

/**
 * Answer the trace connection.
 *
 * @param supervisor The supervisor.
 * @param response The answer, without items.
 */
answer_trace :: fn(supervisor: ptr[mut Supervisor], response: trace.Response) {
    out := os.Outgoing.{}
    os.begin[trace.Response](&out)^ = response
    _ = trace.send_response(supervisor.trace_end, supervisor.port, &out)
}

/**
 * Sort rows by how much their threads did, the most first.
 *
 * @param rows The rows, sorted in place.
 */
sort_rows :: fn(rows: mut trace.Row[]) {
    for i in cast[usize](1)..<rows.count {
        j := i
        loop {
            if j == 0 || j >= rows.count {
                break
            }
            before :: j - 1
            if before >= rows.count || rows[before].switches + rows[before].wakes >= rows[j].switches + rows[j].wakes {
                break
            }
            held :: rows[j]
            rows[j] = rows[before]
            rows[before] = held
            j = before
        }
    }
}

/**
 * Make a connection to the events service for the terminal service, once an administrator's allowed reading the
 * system's log (decisions/0185, 12g): its other end given to the events service to serve (Connect).
 *
 * @param supervisor The supervisor, whose own events connection asks.
 * @return The end for the terminal service; null without an events service, or if the channel couldn't be made.
 */
admin_events_connection :: fn(supervisor: ptr[mut Supervisor]) -> os.Channel[events.Events]? {
    if supervisor.events_end == NONE {
        return null
    }
    pair :: match os.channel_for[events.Events](supervisor.block.budget, ADMIN_RING_BYTES) {
        case Ok(made) => made
        case Error(error) => return null
    }
    out := os.Outgoing.{}
    os.begin[events.Request](&out)^ = .Connect(os.Channel[events.Events].{end = pair.b})
    if events.send_request(supervisor.events_end, supervisor.events_port, &out) != null {
        _ = slop_os.handle_close(cast[slop_os.Handle](pair.a))
        return null
    }
    log_line.write(supervisor.log, "supervisor: an events connection for an administrator")
    return os.Channel[events.Events].{end = pair.a}
}

