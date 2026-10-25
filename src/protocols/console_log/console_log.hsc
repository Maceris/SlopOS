package console_log

import os from "std"
import slop_os from "std/os"

/*
 * The console service's protocol (decisions/0075): lines for the console, until M10's terminal service. A Line is
 * answered with nothing. Connections arrive on its listener as Connects.
 */

ConsoleLog :: struct {}

PROTOCOL :: slop_os.Protocol.{name = "console_log", major_version = 1, lending = .Server}

// The most bytes one Line has.
MAX_BYTES :: 256

Request :: union {
    // One line of text, without its line break
    Line(slop_os.Relative[u8]),
    // Serve another client, on its end
    Connect(os.Channel[ConsoleLog]),
}

Response :: union {
    Unsupported,
}

// A line sent again is shown twice.
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return match request^ {
        case Line(_) => false
        case Connect(_) => true
    }
}

#insert os.protocol_code(Request, Response)

// A new connection to the service listening on end, or null (as entropy.connect).
connect :: fn(end: slop_os.Channel, port: slop_os.Port, budget: slop_os.MemoryBudget) -> os.Channel[ConsoleLog]? {
    pair :: os.channel_for[ConsoleLog](budget, 0) or_return null
    out := os.Outgoing.{}
    request :: os.begin[Request](&out)
    request^ = .Connect(os.Channel[ConsoleLog].{end = pair.a})
    match send_request(end, port, &out) {
        case Some(error) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.a))
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
            return null
        }
        case None => return os.Channel[ConsoleLog].{end = pair.b}
    }
}

// line, sent to the console on end; whether it went.
write :: fn(end: slop_os.Channel, port: slop_os.Port, line: string) -> bool {
    out := os.Outgoing.{}
    request :: os.begin[Request](&out)
    count :: if line.count < MAX_BYTES { line.count } else { MAX_BYTES }
    request^ = .Line(os.append(&out, view_of(cast[ptr[u8]](line.data), count)))
    return send_request(end, port, &out) == null
}
