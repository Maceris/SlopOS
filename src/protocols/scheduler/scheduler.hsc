package scheduler

import os from "std"
import slop_os from "std/os"

/*
 * The scheduler service's protocol (roadmap 9a, decisions/0037, 0093): the CPU budget a service runs on, by its name in
 * system_config, which whoever starts the service puts it on before it starts (os.LaunchOptions). A service without a
 * budget of its own gets the default budget. Connections arrive on its listener as Connects.
 */

Scheduler :: struct {}

PROTOCOL :: slop_os.Protocol.{name = "scheduler", major_version = 1, lending = .Server}

Request :: union {
    // The budget of the service with this name, to put it on (RIGHT_CPU_BUDGET_BIND)
    BudgetFor(slop_os.Relative[u8]),
    // Serve another client, on its end
    Connect(os.Channel[Scheduler]),
}

Response :: union {
    Budget(slop_os.CpuBudget),
    // It has no budget to give: none could be split off the root's
    NoBudget,
    Unsupported,
}

// Asking again gives another handle to the same budget.
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return true
}

#insert os.protocol_code(Request, Response)

// A new connection to the service listening on end, or null (as entropy.connect).
connect :: fn(end: slop_os.Channel, port: slop_os.Port, budget: slop_os.MemoryBudget) -> os.Channel[Scheduler]? {
    pair :: os.channel_for[Scheduler](budget, 0) or_return null
    out := os.Outgoing.{}
    request :: os.begin[Request](&out)
    request^ = .Connect(os.Channel[Scheduler].{end = pair.a})
    match send_request(end, port, &out) {
        case Some(error) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.a))
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
            return null
        }
        case None => return os.Channel[Scheduler].{end = pair.b}
    }
}

/*
 * The budget for the service named name, asked through end: a handle to put it on, or null if there's no scheduler
 * service or it has none to give, when the service runs on its starter's budget.
 */
budget_for :: fn(end: slop_os.Channel, port: slop_os.Port, name: string) -> slop_os.CpuBudget? {
    out := os.Outgoing.{}
    request :: os.begin[Request](&out)
    request^ = .BudgetFor(os.append(&out, view_of(cast[ptr[u8]](name.data), name.count)))
    if send_request(end, port, &out) is_some {
        return null
    }
    into := os.Incoming.{}
    loop {
        match receive_response(end, port, &into, true) {
            case Received => break
            case Failed(error) => return null
            case _ => continue
        }
    }
    return match os.message_of[Response](&into)^ {
        case Budget(budget) => budget
        case _ => null
    }
}
