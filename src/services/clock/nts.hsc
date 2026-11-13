package clock

import runtime from "base"
import net from "std"
import ntp from "std"
import os from "std"
import text_buffer from "std"
import tls from "std"
import slop_os from "std/os"
import network from "std/os/slop_os"
import read_only_dir from "std/os/slop_os"
import service_kit from "../../libraries/service_kit"
import clock_setting from "../../protocols/clock_setting"

/*
 * Keeping the time from an NTS server (decisions/0188, 13g), once a Synchronize has given one: NTS-KE over TLS for keys
 * and cookies, its certificate checked against the trust store; then a few NTP exchanges, authenticated, the one with
 * the least delay taken. An offset past STEP_NANOSECONDS steps the clock, the real-time clock too; a smaller one is
 * slewed, the page's time moved SLEW_STEP at a time each second, so the time never jumps by more than that, though it
 * may go back by that much. It's done again every SYNC_INTERVAL, and sooner after a failure, from 2 s doubling to a
 * minute, as the network may not be up yet.
 */

/** The port keys the exchange's and the slew's timers are bound with, past every client's index and the save's. */
SYNC_KEY : u64 : 1001
SLEW_KEY : u64 : 1002
/** How long between synchronizations once one's worked: about 17 minutes, NTP's longest usual poll. */
SYNC_INTERVAL : u64 : 1024 * 1_000_000_000
/** How long after a failure it's tried again, first, and at most: doubling from 2 s to a minute. */
RETRY_FIRST : u64 : 2_000_000_000
RETRY_MOST : u64 : 64_000_000_000
/**
 * The longest round trip a sample may have and be used: its offset can be wrong by half of it, which one who delays
 * the answers, without the keys, chooses, so a longer one could have the clock stepped (13h).
 */
MOST_DELAY : i64 : 500_000_000
/** How many samples within MOST_DELAY a sync needs, so one answer alone doesn't move the clock. */
FEWEST_SAMPLES :: 2
/**
 * The largest step taken once the clock's synchronized: past it, the clock is left and the step logged, as ntpd's
 * panic threshold has it, so a server gone wrong can't move a clock that's been right (13h).
 */
MOST_STEP : i64 : 1000 * 1_000_000_000

/** How many exchanges a synchronization makes, the one with the least delay taken. */
SAMPLES :: 4
/** How long an exchange waits for its answer. */
QUERY_TIMEOUT : u64 : 2_000_000_000
/** An offset this far either way steps the clock: 128 ms, as ntpd and chrony have it; a smaller one's slewed. */
STEP_NANOSECONDS : i64 : 128_000_000
/** How far a slew moves the time each second: 0.5 ms, 500 parts per million. */
SLEW_STEP : i64 : 500_000
/** How often a slew moves it. */
SLEW_INTERVAL : u64 : 1_000_000_000

/** What the clock service keeps to synchronize with an NTS server. */
Synchronizing :: struct {
    /** Whether a Synchronize gave a server. */
    on : bool,
    server : u8[clock_setting.SERVER_BYTES],
    server_length : usize,
    network : os.Channel[network.Network],
    trust : os.Channel[read_only_dir.ReadOnlyDir],
    /** The trust anchors, loaded from the trust store at the first synchronization; null until then. */
    anchors : ptr[mut net.Anchors]?,
    /** The NTS session: its keys and cookies. */
    session : ntp.Session,
    /** When it's next synchronized, by the monotonic clock, and how long it waits after the next failure. */
    next : u64,
    retry : u64,
    /** Whether it's been synchronized yet, which is logged the first time. */
    synchronized : bool,
    /** How much of an offset is still to be slewed, in nanoseconds, and when the slew next moves the time. */
    slew : i64,
    next_slew : u64,
}

/**
 * Take a Synchronize: keep its server, connection and trust store, replacing any before, and synchronize at once.
 *
 * @param service The clock service's state.
 * @param port The port the timers wake.
 * @param asked The Synchronize, its channels the service's now.
 * @param into The message it came in, for the server's name.
 * @return True if it's taken; false, its channels closed, if the name's empty or too long.
 */
take_synchronize :: fn(service: ptr[mut Clock], port: slop_os.Port, asked: clock_setting.Synchronizing, into: ptr[os.Incoming]) -> bool {
    name :: os.items(into, asked.server)
    syncing :: &service.syncing
    if name.count == 0 || name.count > syncing.server.count {
        _ = slop_os.handle_close(cast[slop_os.Handle](asked.network.end))
        _ = slop_os.handle_close(cast[slop_os.Handle](asked.trust.end))
        return false
    }
    if syncing.on {
        _ = slop_os.handle_close(cast[slop_os.Handle](syncing.network.end))
        _ = slop_os.handle_close(cast[slop_os.Handle](syncing.trust.end))
    }
    match syncing.anchors {
        case Some(anchors) => runtime.free(anchors)
        case None => {}
    }
    syncing.anchors = null
    for byte, i in name {
        if i < syncing.server.count {
            syncing.server[i] = byte
        }
    }
    syncing.server_length = name.count
    syncing.network = asked.network
    syncing.trust = asked.trust
    syncing.session = ntp.Session.{}
    syncing.on = true
    syncing.retry = RETRY_FIRST
    syncing.next = slop_os.clock_monotonic() or_else 0
    _ = slop_os.port_set_timer(port, SYNC_KEY, syncing.next)
    return true
}

/** The server's name, as Synchronize gave it, without a port after it. */
server_name :: fn(syncing: ptr[Synchronizing]) -> string {
    return string_of(&syncing.server[0], name_length(syncing))
}

/** How long the server's name is, before a ":<port>" after it. */
name_length :: fn(syncing: ptr[Synchronizing]) -> usize {
    for byte, i in tls.range(syncing.server, 0, syncing.server_length) {
        if byte == 0x3a {
            return i
        }
    }
    return syncing.server_length
}

/** The NTS-KE server's port: the one after the name, or ntp.NTS_KE_PORT. */
server_port :: fn(syncing: ptr[Synchronizing]) -> u16 {
    after :: name_length(syncing) + 1
    if after >= syncing.server_length || after >= syncing.server.count {
        return ntp.NTS_KE_PORT
    }
    port :: service_kit.number_of(string_of(&syncing.server[after], syncing.server_length - after)) or_else 0
    return if port > 0 && port <= 65535 { cast[u16](port) } else { ntp.NTS_KE_PORT }
}

/**
 * Synchronize with the NTS server if it's time: keys first if the session has none, then SAMPLES exchanges, the clock
 * stepped or slewed by the best one's offset. A failure is logged, and tried again later.
 *
 * @param service The clock service's state.
 * @param port The port the timers wake.
 */
synchronize_if_due :: fn(service: ptr[mut Clock], port: slop_os.Port) {
    syncing :: &service.syncing
    now :: slop_os.clock_monotonic() or_else 0
    if !syncing.on || now < syncing.next {
        return void
    }
    if synchronize(service) {
        syncing.retry = RETRY_FIRST
        syncing.next = now + SYNC_INTERVAL
    }
    else {
        syncing.next = now + syncing.retry
        syncing.retry = if syncing.retry * 2 < RETRY_MOST { syncing.retry * 2 } else { RETRY_MOST }
    }
    _ = slop_os.port_set_timer(port, SYNC_KEY, syncing.next)
    if syncing.slew != 0 {
        syncing.next_slew = (slop_os.clock_monotonic() or_else 0) + SLEW_INTERVAL
        _ = slop_os.port_set_timer(port, SLEW_KEY, syncing.next_slew)
    }
}

/**
 * Synchronize once.
 *
 * @param service The clock service's state.
 * @return True if the clock was stepped or a slew begun; false if something failed, which is logged.
 */
synchronize :: fn(service: ptr[mut Clock]) -> bool {
    syncing :: &service.syncing
    name :: server_name(syncing)
    if syncing.anchors is_none {
        syncing.anchors = net.load_anchors(syncing.trust)
    }
    anchors :: match syncing.anchors {
        case Some(found) => found
        case None => {
            runtime.log_warn("no trust anchors to check % with", name)
            return false
        }
    }
    if !syncing.session.keyed || syncing.session.cookie_count == 0 {
        match net.nts_establish(syncing.network, name, net.anchor_bytes(anchors), &syncing.session, server_port(syncing)) {
            case Some(problem) => {
                log_problem(name, "NTS-KE", problem)
                return false
            }
            case None => runtime.log_info("NTS keys from %, % cookies", name, syncing.session.cookie_count)
        }
    }
    best := ntp.Sample.{}
    have := 0
    for exchange in 0..<SAMPLES {
        match net.nts_query(syncing.network, name, &syncing.session, QUERY_TIMEOUT) {
            case Ok(sample) => {
                if sample.delay < 0 || sample.delay > MOST_DELAY {
                    continue
                }
                if have == 0 || sample.delay < best.delay {
                    best = sample
                }
                have += 1
            }
            case Error(problem) => {
                log_problem(name, "NTP", problem)
                // Keys again next time, if the server can't read the cookies or there are none
                if problem.why == .Nak || problem.why == .NoCookie {
                    syncing.session.keyed = false
                    break
                }
            }
        }
    }
    if have < FEWEST_SAMPLES {
        if have > 0 {
            runtime.log_warn("% gave too few answers within % ms to be taken", name, MOST_DELAY / 1_000_000)
        }
        return false
    }
    adjust(service, name, best)
    return true
}

/**
 * Step the clock by an offset, or slew it.
 *
 * @param service The clock service's state.
 * @param name The server's name, for the log.
 * @param sample The best exchange.
 */
adjust :: fn(service: ptr[mut Clock], name: string, sample: ntp.Sample) {
    syncing :: &service.syncing
    storage : u8[160]
    line := text_buffer.make(storage)
    if sample.offset >= STEP_NANOSECONDS || sample.offset <= -STEP_NANOSECONDS {
        current :: time_now(service) or_else 0
        // Never below the floor, nor, once synchronized, by more than MOST_STEP
        if current + sample.offset < service.floor * NANOSECONDS {
            runtime.log_warn("%'s time is before the clock's floor: not taken", name)
            return void
        }
        if syncing.synchronized && (sample.offset > MOST_STEP || sample.offset < -MOST_STEP) {
            text_buffer.append_format(&line, "%'s time is off by ", name)
            append_milliseconds(&line, sample.offset)
            text_buffer.append(&line, ", past the most a synchronized clock's stepped: not taken")
            runtime.log_warn("%", text_buffer.as_string(&line))
            return void
        }
        syncing.slew = 0
        if !set(service, current + sample.offset) {
            return void
        }
        text_buffer.append_format(&line, "stepped to %'s time by ", name)
    }
    else {
        syncing.slew = sample.offset
        text_buffer.append_format(&line, "slewing to %'s time by ", name)
    }
    append_milliseconds(&line, sample.offset)
    text_buffer.append(&line, ", its delay ")
    append_milliseconds(&line, sample.delay)
    runtime.log_info("%", text_buffer.as_string(&line))
    if !syncing.synchronized {
        syncing.synchronized = true
        save(service)
    }
}

/**
 * Move the time by a step of the slew, if one's due, and set the timer for the next.
 *
 * @param service The clock service's state.
 * @param port The port the timers wake.
 */
slew_if_due :: fn(service: ptr[mut Clock], port: slop_os.Port) {
    syncing :: &service.syncing
    now :: slop_os.clock_monotonic() or_else 0
    if syncing.slew == 0 || now < syncing.next_slew {
        return void
    }
    step :: if syncing.slew > SLEW_STEP { SLEW_STEP } else if syncing.slew < -SLEW_STEP { -SLEW_STEP } else { syncing.slew }
    current :: time_now(service) or_return void
    put_time(service, current + step)
    syncing.slew -= step
    if syncing.slew != 0 {
        syncing.next_slew = now + SLEW_INTERVAL
        _ = slop_os.port_set_timer(port, SLEW_KEY, syncing.next_slew)
    }
}

/**
 * Log why synchronizing failed.
 *
 * @param name The server's name.
 * @param what The step: "NTS-KE" or "NTP".
 * @param problem Why.
 */
log_problem :: fn(name: string, what: string, problem: net.NtsProblem) {
    match problem.why {
        case .Tls => match problem.tls.network {
            case Some(failure) => runtime.log_warn("% with %: %", what, name, failure)
            case None => runtime.log_warn("% with %: TLS failed, alert %, %", what, name, problem.tls.alert, problem.tls.certificate)
        }
        case .KeyEstablishment => runtime.log_warn("% with %: %, error %", what, name, problem.ke, problem.error)
        case .Network => runtime.log_warn("% with %: %", what, name, problem.network)
        case _ => runtime.log_warn("% with %: %", what, name, problem.why)
    }
}

/**
 * Append a span of time in milliseconds, signed, to three places: "+5000.123 ms".
 *
 * @param line Where.
 * @param nanoseconds The span.
 */
append_milliseconds :: fn(line: ptr[mut text_buffer.TextBuffer], nanoseconds: i64) {
    sign :: if nanoseconds < 0 { "-" } else { "+" }
    magnitude :: if nanoseconds < 0 { cast[u64](0) - cast[u64](nanoseconds) } else { cast[u64](nanoseconds) }
    microseconds :: magnitude / 1000
    fraction :: microseconds % 1000
    // "%%" would be a literal %, so the sign goes on its own
    text_buffer.append(line, sign)
    text_buffer.append_format(line, "%.", microseconds / 1000)
    if fraction < 100 {
        text_buffer.append(line, "0")
    }
    if fraction < 10 {
        text_buffer.append(line, "0")
    }
    text_buffer.append_format(line, "% ms", fraction)
}
