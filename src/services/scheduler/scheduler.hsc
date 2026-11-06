/**
 * The scheduler service (roadmap 9a, decisions/0037, 0093): it holds the root CPU budget, which the root task gives it,
 * and splits a budget off it for each service the system configuration gives a CPU share, and one more, the default,
 * for every service without one. The system configuration is the boot set's, which the root task gives it, and it
 * checks again (decisions/0110). Whoever starts a service asks it for that service's budget by name (the scheduler
 * protocol), and puts the service on it before it starts, with the CPUs its share names, if it names any
 * (decisions/0099), so its threads run there and its IRQs are routed there. It adjusts nothing on its own yet; if it
 * ends, every budget keeps what it was given, as the kernel keeps them.
 */
package scheduler

import os from "std"
import slop_os from "std/os"
import log_line from "../../log_line"
import service_kit from "../../libraries/service_kit"
import protocol from "../../protocols/scheduler"
import system_records from "../../system_records"

/**
 * The most budgets it splits for services with a share of their own; services with a share past this many are given
 * the default instead. The default isn't counted.
 */
MAX_BUDGETS :: 32

/** A budget it split for a service with a share of its own. */
Split :: struct {
    /**
     * The service's name, as the system configuration has it; a view of the configuration's copy, which is kept for
     * the scheduler's life.
     */
    name : string,
    /** The budget, the scheduler's own, with every right; only bind-only copies are given away. */
    budget : slop_os.CpuBudget,
}

/** The service's state, all of it main's, kept for its life. */
Scheduler :: struct {
    /** Where its lines go, or NO_HANDLE when it wasn't given a log, so lines go nowhere. */
    log : slop_os.DebugLog,
    /** The port every client is bound to, waited on between passes. */
    port : slop_os.Port,
    /** The budgets split for services with a share of their own, in the configuration's order. */
    budgets : Split[MAX_BUDGETS],
    /** How many of budgets are in use, from the first: 0 to MAX_BUDGETS. */
    count : usize,
    /** The budget for every service without one of its own, or NO_HANDLE when it couldn't be made. */
    default_budget : slop_os.CpuBudget,
}

/**
 * Split the root CPU budget into the services' budgets, and give each to whoever starts that service.
 *
 * The default budget is made first, then one for each service the system configuration gives a CPU share, in its
 * order, restricted to the CPUs the share names; one that can't be made is logged, and its service gets the default.
 * Then the program serves BudgetFor requests until the system stops.
 *
 * @param log The debug log it writes its lines to: the budgets made, and each that couldn't be. Without one, it
 *     writes nothing.
 * @param cpu_budget The root CPU budget, from the root task, which every budget is split off; kept for the
 *     program's life.
 * @param clients The listener new clients' connections arrive on, from the root task; it's served as a client, its
 *     Connects each adding a client, up to service_kit's MAX_CLIENTS at once.
 * @param system The system configuration, the boot set's, from the root task; it's copied out and checked again, the
 *     copy kept for the program's life.
 * @return 1 when no port could be made, 2 when the listener couldn't be bound to it, 3 when the system configuration
 *     doesn't check out; it doesn't return otherwise.
 */
main :: fn(log: slop_os.DebugLog?, cpu_budget: slop_os.CpuBudget, clients: os.Listener[protocol.Scheduler], system: slop_os.Memory) -> int {
    block :: slop_os.startup_block()
    service := Scheduler.{log = log or_else cast[slop_os.DebugLog](slop_os.NO_HANDLE),
        default_budget = cast[slop_os.CpuBudget](slop_os.NO_HANDLE)}
    service.port = slop_os.port_create(block.budget) or_return 1
    records :: match service_kit.read_records(block, system) {
        case Ok(read) => read
        case Error(problem) => {
            log_line.write(service.log, "scheduler: the system configuration %", problem.reason)
            return 3
        }
    }
    // The default first, so the services' own shares are what's refused if there isn't room for all of them
    share :: records.default_cpu
    match slop_os.cpu_budget_create(cpu_budget, block.budget, share.priority, share.period_ns, share.time_ns) {
        case Ok(made) => service.default_budget = made
        case Error(error) => log_line.write(service.log, "scheduler: no default budget: %", error)
    }
    for i in cast[usize](0)..<records.services.count {
        if i >= cast[usize](records.service_count) {
            break
        }
        each :: &records.services[i]
        own :: each.cpu
        if own.has == 0 {
            continue
        }
        name :: system_records.text_of(&each.name)
        at :: service.count
        if at >= service.budgets.count {
            break
        }
        match slop_os.cpu_budget_create(cpu_budget, block.budget, own.priority, own.period_ns, own.time_ns) {
            case Ok(made) => {
                service.budgets[at] = Split.{name = name, budget = made}
                service.count = at + 1
                if own.cpus != 0 {
                    match slop_os.cpu_budget_set_cpus(made, own.cpus) {
                        case Ok => {}
                        case Error(error) => log_line.write(service.log, "scheduler: % can't run on CPUs %: %", name, own.cpus, error)
                    }
                }
            }
            case Error(error) => log_line.write(service.log, "scheduler: no budget for %: %", name, error)
        }
    }
    root :: slop_os.cpu_budget_describe(cpu_budget) or_else slop_os.CpuBudgetInfo.{}
    log_line.write(service.log, "scheduler: % budgets and the default split off the root's, % of its % millionths of a CPU", service.count,
        root.children_share, root.share)
    connected := service_kit.Clients.{}
    if !service_kit.add_client(&connected, service.port, clients.end) {
        return 2
    }
    into := os.Incoming.{}
    loop {
        with {
            i : usize = 0
        }
        loop {
            serve(&service, &connected, i, &into)
            i += 1
        }
        while i < connected.count
        packets : slop_os.Packet[8]
        _ = slop_os.port_wait(service.port, packets, slop_os.NO_DEADLINE)
    }
}

/**
 * Answer every request one client has sent, until none is left or the client's gone.
 *
 * A BudgetFor is answered with Budget, a bind-only copy of the named service's budget or of the default for a name
 * without one, or NoBudget when there's no budget to give or it can't be copied. A Connect adds its channel as a
 * client, closing it when the table's full. An unknown request is answered Unsupported; an invalid one is skipped.
 *
 * @param service The service, which isn't changed but for its budgets' copies given away.
 * @param connected The clients; a client whose channel failed is dropped, its channel closed and its place freed.
 * @param index Which client, an index in connected; one past its end, or a freed place, is nothing to serve.
 * @param into Where each request is received, reused for each and left holding the last.
 */
serve :: fn(service: ptr[mut Scheduler], connected: ptr[mut service_kit.Clients], index: usize, into: ptr[mut os.Incoming]) {
    if index >= connected.ends.count {
        return void
    }
    end :: connected.ends[index]
    if cast[slop_os.Handle](end) == slop_os.NO_HANDLE {
        return void
    }
    loop {
        match protocol.receive_request(end, service.port, into, false) {
            case Received => {}
            case Empty => return void
            case Unsupported => {
                _ = protocol.answer_unsupported(end, service.port)
                continue
            }
            case _ => {
                service_kit.drop_client(connected, index)
                return void
            }
        }
        match os.message_of[protocol.Request](into)^ {
            case BudgetFor(named) => {
                bytes :: os.items(into, named)
                name :: if bytes.count == 0 { "" } else { string_of(&bytes[0], bytes.count) }
                out := os.Outgoing.{}
                response :: os.begin[protocol.Response](&out)
                response^ = .NoBudget
                match bindable(budget_of(service, name)) {
                    case Some(budget) => response^ = .Budget(budget)
                    case None => {}
                }
                _ = protocol.send_response(end, service.port, &out)
            }
            case Connect(connection) => {
                if !service_kit.add_client(connected, service.port, connection.end) {
                    _ = slop_os.handle_close(cast[slop_os.Handle](connection.end))
                }
            }
        }
    }
}

/**
 * Find the budget for a service.
 *
 * @param service The service, which keeps the budget; the handle returned is still its own.
 * @param name The service's name, compared exactly with the configuration's names; "" or an unknown name gets the
 *     default.
 * @return The budget split for name, or the default budget when it has none, which is NO_HANDLE when the default
 *     couldn't be made.
 */
budget_of :: fn(service: ptr[Scheduler], name: string) -> slop_os.CpuBudget {
    for each, i in service.budgets {
        if i < service.count && each.name == name {
            return each.budget
        }
    }
    return service.default_budget
}

/**
 * Copy a budget's handle with only the rights to put processes on it and to send it, to give away.
 *
 * @param budget The budget, which stays the caller's, unchanged.
 * @return The copy, the caller's to send or close; null when budget is NO_HANDLE or can't be duplicated.
 */
bindable :: fn(budget: slop_os.CpuBudget) -> slop_os.CpuBudget? {
    if cast[slop_os.Handle](budget) == slop_os.NO_HANDLE {
        return null
    }
    rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_CPU_BUDGET_BIND) | cast[u32](slop_os.RIGHT_TRANSFER))
    match slop_os.handle_duplicate(cast[slop_os.Handle](budget), rights) {
        case Ok(copy) => return cast[slop_os.CpuBudget](copy)
        case Error(error) => return null
    }
}
