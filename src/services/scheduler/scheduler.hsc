/*
 * The scheduler service (roadmap 9a, decisions/0037, 0093): it holds the root CPU budget, which the root task gives it,
 * and splits a budget off it for each service system_config gives a CpuShare, and one more, the default, for every
 * service without one. Whoever starts a service asks it for that service's budget by name (the scheduler protocol), and
 * puts the service on it before it starts, with the CPUs its share names, if it names any (decisions/0099), so its
 * threads run there and its IRQs are routed there. It adjusts nothing on its own yet; if it ends, every budget keeps
 * what it was given, as the kernel keeps them.
 */
package scheduler

import os from "std"
import slop_os from "std/os"
import log_line from "../../log_line"
import service_kit from "../../service_kit"
import protocol from "../../protocols/scheduler"
import system_config from "../../system_config"

// The budgets it splits: one per service with a share, and the default
MAX_BUDGETS :: 32

// A budget it split, and the service it's for, or "" for the default.
Split :: struct {
    name : string,
    budget : slop_os.CpuBudget,
}

Scheduler :: struct {
    log : slop_os.DebugLog,
    port : slop_os.Port,
    budgets : Split[MAX_BUDGETS],
    count : usize,
    default_budget : slop_os.CpuBudget,
}

main :: fn(log: slop_os.DebugLog?, cpu_budget: slop_os.CpuBudget, clients: os.Listener[protocol.Scheduler]) -> int {
    block :: slop_os.startup_block()
    service := Scheduler.{log = log or_else cast[slop_os.DebugLog](slop_os.NO_HANDLE),
        default_budget = cast[slop_os.CpuBudget](slop_os.NO_HANDLE)}
    service.port = slop_os.port_create(block.budget) or_return 1
    // The default first, so the services' own shares are what's refused if there isn't room for all of them
    share :: system_config.DEFAULT_CPU
    match slop_os.cpu_budget_create(cpu_budget, block.budget, share.priority, share.period_ns, share.time_ns) {
        case Ok(made) => service.default_budget = made
        case Error(error) => log_line.write(service.log, "scheduler: no default budget: %", error)
    }
    for each in system_config.SERVICES {
        own :: each.cpu or_continue
        at :: service.count
        if at >= service.budgets.count {
            break
        }
        match slop_os.cpu_budget_create(cpu_budget, block.budget, own.priority, own.period_ns, own.time_ns) {
            case Ok(made) => {
                service.budgets[at] = Split.{name = each.name, budget = made}
                service.count = at + 1
                if own.cpus != 0 {
                    match slop_os.cpu_budget_set_cpus(made, own.cpus) {
                        case Ok => {}
                        case Error(error) => log_line.write(service.log, "scheduler: % can't run on CPUs %: %", each.name, own.cpus, error)
                    }
                }
            }
            case Error(error) => log_line.write(service.log, "scheduler: no budget for %: %", each.name, error)
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

// Every request client index has sent, until there are none left, or it's gone.
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
            case Invalid => continue
            case WrongProtocol => continue
            case Failed(error) => {
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

// The budget split for the service named name, or the default.
budget_of :: fn(service: ptr[Scheduler], name: string) -> slop_os.CpuBudget {
    for each, i in service.budgets {
        if i < service.count && each.name == name {
            return each.budget
        }
    }
    return service.default_budget
}

// A handle to budget that may only put processes on it, to give away.
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
