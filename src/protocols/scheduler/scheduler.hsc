package scheduler

import os from "std"
import slop_os from "std/os"

/*
 * The scheduler service's protocol (roadmap 9a, decisions/0037, 0093): the CPU budget a service runs on, by its name in
 * system_config, which whoever starts the service puts it on before it starts (os.LaunchOptions). A service without a
 * budget of its own gets the default budget. Connections arrive on its listener as Connects.
 */

/**
 * The scheduler protocol, for the channels between the scheduler service and its clients, and its listener: the
 * clients send the requests, and the scheduler service answers them.
 */
Scheduler :: struct {}

/**
 * What the protocol says of itself: its name, which its channels' tag is made from, its major version, and that the
 * server, here the scheduler service, pays for its work from its own budget.
 */
PROTOCOL :: slop_os.Protocol.{name = "scheduler", major_version = 1, lending = .Server}

/** What a client asks the scheduler service. */
Request :: union {
    /**
     * Ask for the CPU budget of the service with this name, as UTF-8, compared exactly with system_config's names,
     * to put the service on (RIGHT_CPU_BUDGET_BIND); an empty or unknown name gets the default budget. Answered with
     * Budget, or NoBudget.
     */
    BudgetFor(slop_os.Relative[u8]),
    /**
     * Have the service serve another client, on the end given, which moves to the service; it's closed if the
     * service already has as many clients as it takes. Sent on the listener, and answered with nothing.
     */
    Connect(os.Channel[Scheduler]),
}

/** What the scheduler service answers. */
Response :: union {
    /**
     * BudgetFor's answer: a handle to the budget with only the rights to bind processes to it and to send it, which
     * moves to the client.
     */
    Budget(slop_os.CpuBudget),
    /** BudgetFor's answer when it has no budget to give: none could be split off the root's, or copied. */
    NoBudget,
    /** The answer to a request the service doesn't know, as from a newer client; every protocol has it. */
    Unsupported,
}

/**
 * Tell whether a request may be sent again, after a reconnect, without doing more than sending it once did.
 *
 * @param request The request, which isn't changed.
 * @return True for every request: asking again gives another handle to the same budget.
 */
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return true
}

#insert os.protocol_code(Request, Response)

/**
 * Make a new connection to the scheduler service: a channel for the protocol, one end sent to it in a Connect, as
 * entropy.connect does.
 *
 * It doesn't wait: the service takes the end when it next serves its listener, or closes it when it's full, which the
 * caller learns of as its end's peer gone.
 *
 * @param end The service's listener, or any connection to it, kept by the caller.
 * @param port A port bound to end, waited on while end's ring is full.
 * @param budget The memory budget that pays for the new channel.
 * @return The caller's end of the new connection, its own to keep and close; null if the channel couldn't be made, or
 *     the Connect couldn't be sent, in which case both its ends are closed.
 */
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

/**
 * Ask the scheduler service for the budget of a service, and wait for its answer.
 *
 * Responses that aren't one, unknown or invalid, are skipped while it waits.
 *
 * @param end A connection to the scheduler service, kept by the caller.
 * @param port A port bound to end, waited on for the answer.
 * @param name The service's name, as system_config names it.
 * @return A handle to the budget, to put the service on, the caller's to send or close; null if the request couldn't
 *     be sent, the connection's gone, or the scheduler service has no budget to give, when the service runs on its
 *     starter's budget.
 */
budget_for :: fn(end: slop_os.Channel, port: slop_os.Port, name: string) -> slop_os.CpuBudget? {
    out := os.Outgoing.{}
    request :: os.begin[Request](&out)
    request^ = .BudgetFor(os.append(&out, string_bytes(name)))
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
