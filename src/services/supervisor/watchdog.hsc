package supervisor

import os from "std"
import slop_os from "std/os"
import lifecycle from "std/os/slop_os"
import log_line from "../../log_line"
import watchdog from "../../protocols/watchdog"

/*
 * The hardware watchdog (decisions/0182, P5, design/lessons.md §6.2): armed once the supervisor's start is done, and
 * reset a few times each timeout from its steady loop, but only while every service it started answers a Ping on its
 * lifecycle channel; a hung supervisor, or a service that stops answering, lets the watchdog reset the machine, and boot
 * counting does the rest. A shutdown disarms it first.
 */

/** How many times each timeout the watchdog's reset: a service that misses one Ping doesn't reset the machine. */
PETS_EACH_TIMEOUT : u64 : 4
/** The Ping's sequence the watchdog's Pings carry, so their Pongs are told from others'. */
WATCHDOG_PING : u32 : 0x77d

/**
 * Arm the watchdog, if there's one and the supervisor's start is done: a connection made through its driver's listener,
 * the one before closed, and it armed for watchdog_seconds.
 *
 * @param supervisor The supervisor, whose watchdog_end, watchdog_port and next_pet are set.
 */
arm_watchdog :: fn(supervisor: ptr[mut Supervisor]) {
    if !supervisor.steady || supervisor.watchdog_listener == NONE {
        return void
    }
    if supervisor.watchdog_end != NONE {
        _ = slop_os.handle_close(cast[slop_os.Handle](supervisor.watchdog_end))
        _ = slop_os.handle_close(cast[slop_os.Handle](supervisor.watchdog_port))
        supervisor.watchdog_end = NONE
    }
    port :: slop_os.port_create(supervisor.block.budget) or_return void
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    connection :: watchdog.connect(supervisor.watchdog_listener, port, supervisor.block.budget) or_return void
    supervisor.watchdog_end = connection.end
    supervisor.watchdog_port = os.port_for(supervisor.block.budget, connection.end) or_return void
    match ask_watchdog(supervisor, .Arm(supervisor.watchdog_seconds)) {
        case Some(response) => match response {
            case Armed(seconds) => {
                log_line.write(supervisor.log, "supervisor: the watchdog's armed, % seconds", seconds)
                supervisor.next_pet = (slop_os.clock_monotonic() or_else 0) + cast[u64](seconds) * 1_000_000_000 / PETS_EACH_TIMEOUT
            }
            case _ => log_line.write(supervisor.log, "supervisor: the watchdog didn't arm")
        }
        case None => log_line.write(supervisor.log, "supervisor: the watchdog didn't answer")
    }
}

/**
 * Reset the watchdog, if it's time: every service pinged last time has to have answered, and each running service is
 * pinged again. A service that didn't answer is named, and the watchdog isn't reset.
 *
 * @param supervisor The supervisor, whose next_pet moves on, and whose entries' pinged are set.
 */
tend_watchdog :: fn(supervisor: ptr[mut Supervisor]) {
    if supervisor.watchdog_end == NONE {
        return void
    }
    now :: slop_os.clock_monotonic() or_else 0
    if now < supervisor.next_pet {
        return void
    }
    supervisor.next_pet = now + cast[u64](supervisor.watchdog_seconds) * 1_000_000_000 / PETS_EACH_TIMEOUT
    answering := true
    for &entry, i in supervisor.started {
        if i >= supervisor.started_count {
            break
        }
        if !entry.running || entry.driver || entry.lifecycle == NONE {
            continue
        }
        // Its Pong for the last Ping, if it was pinged on this same channel
        if entry.pinged == entry.lifecycle {
            answered := false
            loop {
                reply :: lifecycle.read(entry.lifecycle) or_break
                if reply.answer == .Pong && reply.sequence == WATCHDOG_PING {
                    answered = true
                }
            }
            if !answered {
                log_line.write(supervisor.log, "supervisor: % didn't answer, so the watchdog isn't reset", entry.name)
                answering = false
            }
        }
        entry.pinged = if lifecycle.ping(entry.lifecycle, WATCHDOG_PING) { entry.lifecycle } else { NONE }
    }
    if supervisor.watchdog_hang {
        if answering {
            log_line.write(supervisor.log, "supervisor: test_watchdog_hang: the watchdog isn't reset")
        }
        return void
    }
    if answering {
        _ = ask_watchdog(supervisor, .Pet)
    }
}

/**
 * Disarm the watchdog, as a shutdown does first.
 *
 * @param supervisor The supervisor; without a watchdog, nothing's done.
 */
disarm_watchdog :: fn(supervisor: ptr[mut Supervisor]) {
    if supervisor.watchdog_end == NONE {
        return void
    }
    _ = ask_watchdog(supervisor, .Disarm)
    _ = slop_os.handle_close(cast[slop_os.Handle](supervisor.watchdog_end))
    supervisor.watchdog_end = NONE
}

/**
 * Ask the watchdog's driver something and wait for its answer.
 *
 * @param supervisor The supervisor, whose watchdog connection it's asked on; its port isn't handled while it waits.
 * @param request The request.
 * @return The answer; null if the connection failed.
 */
ask_watchdog :: fn(supervisor: ptr[mut Supervisor], request #escaping : watchdog.Request) -> watchdog.Response? {
    out := os.Outgoing.{}
    made :: os.begin[watchdog.Request](&out)
    made^ = request
    if watchdog.send_request(supervisor.watchdog_end, supervisor.watchdog_port, &out) != null {
        return null
    }
    into := os.Incoming.{}
    loop {
        match watchdog.receive_response(supervisor.watchdog_end, supervisor.watchdog_port, &into, true) {
            case Received => break
            case _ => return null
        }
    }
    return os.message_of[watchdog.Response](&into)^
}
