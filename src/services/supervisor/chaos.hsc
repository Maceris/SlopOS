package supervisor

import runtime from "base"
import random from "std"
import slop_os from "std/os"
import lifecycle from "std/os/slop_os"
import log_line from "../../log_line"

/*
 * test_chaos (decisions/0096's R5, 0181's F6): once everything has started, kill services and drivers the supervisor
 * starts again, chosen at random, one at a time; each must be started again within CHAOS_DEADLINE and answer a Ping on
 * its lifecycle channel within CHAOS_ANSWER, and at the end the supervisor's budget, which every service's is split
 * off, must be back where it was, within CHAOS_SLACK for its own heap. The choice comes from a seed, logged, which
 * test_chaos_seed=S gives again to repeat a run. Each is killed once at most, so none reaches its RESTARTS.
 */

/** How long a service killed has to be started again, in nanoseconds: 10 seconds. */
CHAOS_DEADLINE : u64 : 10_000_000_000
/** How long one started again has to answer a Ping, in nanoseconds: 10 seconds, as a driver finds its device again. */
CHAOS_ANSWER : u64 : 10_000_000_000
/** How many bytes the supervisor's budget may have grown by at the end, its own heap's: 256 KiB. */
CHAOS_SLACK : u64 : 256 * 1024
/** The most kills a run makes. */
MAX_CHAOS :: 16

/**
 * Run test_chaos: kills services and drivers at random, checking each comes back and answers, then that the budgets are
 * as they were. Logs each kill, and a line saying how it went.
 *
 * @param supervisor The supervisor, whose started entries are killed and started again.
 * @param kills How many to kill, at most MAX_CHAOS and as many as there are that may be started again.
 * @param given_seed The seed to choose them with; 0 for one at random, which is logged.
 */
run_chaos :: fn(supervisor: ptr[mut Supervisor], kills: u64, given_seed: u64) {
    seed := if given_seed != 0 { given_seed } else { random.next_u64() | 1 }
    log_line.write(supervisor.log, "supervisor: test_chaos: % kills, seed %", kills, seed)
    budget :: supervisor.block.budget
    before :: (slop_os.memory_budget_info(budget) or_else slop_os.BudgetInfo.{}).used
    killed : bool[MAX_STARTED]
    failed := 0
    made := cast[u64](0)
    state := seed
    for round in 0..<(if kills < MAX_CHAOS { kills } else { cast[u64](MAX_CHAOS) }) {
        // The candidates left: running, started again when they end, and not killed yet
        count := cast[u64](0)
        for entry, i in supervisor.started {
            if i < supervisor.started_count && i < killed.count && !killed[i] && may_kill(supervisor, i) {
                count += 1
            }
        }
        if count == 0 {
            break
        }
        state = next_state(state)
        pick := state % count
        index := NOWHERE
        for entry, i in supervisor.started {
            if i < supervisor.started_count && i < killed.count && !killed[i] && may_kill(supervisor, i) {
                if pick == 0 {
                    index = i
                    break
                }
                pick -= 1
            }
        }
        if index >= supervisor.started.count || index >= killed.count {
            break
        }
        killed[index] = true
        made += 1
        name :: supervisor.started[index].name
        if !killed_and_back(supervisor, index) {
            log_line.write(supervisor.log, "supervisor: test_chaos: % wasn't started again in time", name)
            failed += 1
            continue
        }
        if !answers(supervisor, index) {
            log_line.write(supervisor.log, "supervisor: test_chaos: %, started again, didn't answer", name)
            failed += 1
        }
    }
    // What the ends brought, handled, and the budgets given back
    pause(supervisor, 1_000_000_000)
    after :: (slop_os.memory_budget_info(budget) or_else slop_os.BudgetInfo.{}).used
    log_line.write(supervisor.log, "supervisor: test_chaos: the supervisor's budget used % bytes before, % after", before, after)
    if failed == 0 && made > 0 && after <= before + CHAOS_SLACK {
        log_line.write(supervisor.log, "supervisor: test_chaos: every service killed was started again and answered, and the budgets are as they were")
    }
}

/**
 * Tell whether a started entry may be killed by test_chaos: running, a service or driver started again when it ends,
 * not one of the console's programs.
 *
 * @param supervisor The supervisor.
 * @param index The entry's index.
 * @return True if it may.
 */
may_kill :: fn(supervisor: ptr[mut Supervisor], index: usize) -> bool {
    if index >= supervisor.started.count {
        return false
    }
    entry :: &supervisor.started[index]
    if !entry.running || entry.done || entry.console || entry.restarts > 0 {
        return false
    }
    if entry.driver {
        return true
    }
    return match service_named(supervisor, entry.name) {
        case Some(service) => !service.not_restarted
        case None => false
    }
}

/**
 * Kill a started entry and wait, up to CHAOS_DEADLINE, for it to be started again.
 *
 * @param supervisor The supervisor, which handles what comes on its port meanwhile.
 * @param index The entry's index.
 * @return True once it's running again; false if it isn't by the deadline, or is done.
 */
killed_and_back :: fn(supervisor: ptr[mut Supervisor], index: usize) -> bool {
    if index >= supervisor.started.count {
        return false
    }
    restarts :: supervisor.started[index].restarts
    log_line.write(supervisor.log, "supervisor: test_chaos: killing %", supervisor.started[index].name)
    _ = slop_os.process_kill(supervisor.started[index].process)
    supervisor.started[index].running = false
    deadline :: (slop_os.clock_monotonic() or_else 0) + CHAOS_DEADLINE
    loop {
        if supervisor.started[index].done || (supervisor.started[index].running && supervisor.started[index].restarts > restarts) {
            break
        }
        if (slop_os.clock_monotonic() or_else 0) >= deadline {
            return false
        }
        wait_and_handle_until(supervisor, deadline)
    }
    return supervisor.started[index].running
}

/**
 * Ping a started entry on its lifecycle channel and wait, up to CHAOS_ANSWER, for its Pong. A driver has no lifecycle
 * channel, so one running again is taken as answering.
 *
 * @param supervisor The supervisor.
 * @param index The entry's index.
 * @return True if it answered, or is a driver running again; false for a service without a lifecycle channel, or no
 *     answer in time.
 */
answers :: fn(supervisor: ptr[mut Supervisor], index: usize) -> bool {
    if index >= supervisor.started.count {
        return false
    }
    if supervisor.started[index].driver {
        return supervisor.started[index].running
    }
    end :: supervisor.started[index].lifecycle
    if end == NONE {
        return false
    }
    // What came before is dropped, so only this Ping's Pong counts
    loop {
        _ = lifecycle.read(end) or_break
    }
    if !lifecycle.ping(end, 1) {
        return false
    }
    deadline :: (slop_os.clock_monotonic() or_else 0) + CHAOS_ANSWER
    loop {
        match lifecycle.read(end) {
            case Some(reply) => if reply.answer == .Pong {
                return true
            }
            case None => {}
        }
        if (slop_os.clock_monotonic() or_else 0) >= deadline {
            return false
        }
        pause(supervisor, 10_000_000)
    }
}

/**
 * Step a xorshift64 generator: test_chaos's choices, from its seed.
 *
 * @param state The state, not 0.
 * @return The next state.
 */
next_state :: fn(state: u64) -> u64 {
    x := state
    x ~= x << 13
    x ~= x >> 7
    x ~= x << 17
    return x
}
