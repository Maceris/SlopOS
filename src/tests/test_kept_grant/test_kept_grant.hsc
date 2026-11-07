/**
 * test_kept_grant (decisions/0181, F4): a file asked of the session's powerbox and kept, then opened again by its key,
 * for the shell's boot test of kept grants, listed and revoked with grants.
 */
package test_kept_grant

import os from "std"
import strings from "std"
import terminal from "std"
import slop_os from "std/os"
import terminal as protocol from "std/os/slop_os"
import powerbox_protocol from "../../protocols/powerbox"

/** The key the file's kept under. */
KEY :: "kept"
/** The line written in the file, and read back. */
LINE :: "a kept line"

/** What it did. */
Kept :: struct {
    /** The file's first line: what it wrote, or what it read back. */
    line : string,
}

/** An error naming the parameter it came from. */
Problem :: struct {
    /** The parameter: powerbox. */
    parameter : os.ParameterName,
}

/** Why it couldn't. */
KeptError :: union {
    /** The powerbox gave nothing: the user refused, or there's nothing kept under the key. */
    Refused(Problem),
    /** What it gave couldn't be written or read. */
    Unusable(Problem),
}

/**
 * Ask the powerbox for a file to write, suggesting kept.txt and asking to keep it as kept, and write a line in it; or,
 * with reopen, open what's kept as kept again, to read, and read its line.
 *
 * @param console The terminal, where it says it's asked the powerbox, as the user answers on the trusted path. Without
 *     it, it says nothing.
 * @param powerbox The session's powerbox, which the shell gives without asking.
 * @param reopen Whether to open the kept file again, rather than ask for one.
 * @return The file's line.
 * @error Refused The powerbox gave nothing; for reopen, nothing's kept under the key, or it was revoked.
 * @error Unusable What it gave couldn't be written or read.
 */
main :: fn(console: os.Channel[protocol.Terminal]?, powerbox: os.Channel[powerbox_protocol.Powerbox], reopen: bool) -> Result[Kept, KeptError] {
    problem :: Problem.{parameter = os.ParameterName.{name = "powerbox"}}
    port :: os.port_for(slop_os.startup_block().budget, powerbox.end) or_return .Error(.Unusable(problem))
    out := os.Outgoing.{}
    request :: os.begin[powerbox_protocol.Request](&out)
    if reopen {
        request^ = .Reopen(powerbox_protocol.Reopening.{key = os.append(&out, string_bytes(KEY)), kind = .File, write = false})
    }
    else {
        request^ = .RequestFile(powerbox_protocol.FileRequest.{purpose = os.append(&out, string_bytes("to keep a line in it")),
            suggested = os.append(&out, string_bytes("kept.txt")), write = true, keep = os.append(&out, string_bytes(KEY))})
        match console {
            case Some(given) => {
                match terminal.open(given) {
                    case Some(opened) => {
                        shown := opened
                        _ = terminal.write_line(&shown, "Asked the powerbox; Ctrl+Alt+Delete shows what it asks.")
                    }
                    case None => {}
                }
            }
            case None => {}
        }
    }
    if powerbox_protocol.send_request(powerbox.end, port, &out) != null {
        return .Error(.Unusable(problem))
    }
    into := os.Incoming.{}
    match powerbox_protocol.receive_response(powerbox.end, port, &into, true) {
        case Received => {}
        case _ => return .Error(.Unusable(problem))
    }
    match os.message_of[powerbox_protocol.Response](&into)^ {
        case GrantedFile(given) => {
            file, error :: os.file_on(given.end, true)
            if error is_some {
                return .Error(.Unusable(problem))
            }
            defer os.close(file)
            if os.write(file, LINE) is_some {
                return .Error(.Unusable(problem))
            }
            return .Ok(Kept.{line = LINE})
        }
        case GrantedReadOnlyFile(given) => {
            file, error :: os.file_on(given.end, false)
            if error is_some {
                return .Error(.Unusable(problem))
            }
            defer os.close(file)
            buffer : u8[64]
            read :: os.read(file, buffer[0..<buffer.count]) or_return .Error(.Unusable(problem))
            if read == 0 || read > buffer.count {
                return .Error(.Unusable(problem))
            }
            line :: strings.clone(string_of(&buffer[0], read)) or_return .Error(.Unusable(problem))
            return .Ok(Kept.{line = line})
        }
        case _ => return .Error(.Refused(problem))
    }
}
