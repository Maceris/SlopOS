/**
 * keys (decisions/0191, 14c): the public keys that log in as you over SSH. Without arguments it lists them; --add takes
 * a public key's file, as ssh-keygen writes one (key.pub), beneath the shell's directory, and --remove a key's
 * fingerprint, as the list shows it. Each goes through the session's powerbox: the list is given at once, and adding or
 * removing a key is the user's to allow on the trusted path, where its fingerprint is shown.
 *
 *     keys
 *     keys --add id_ed25519.pub
 *     keys --remove SHA256:bBEtczzyIjtfN3fYz88H8A1mtM1727e1zgfHXEs8XyI
 */
package keys

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import stream from "std/os/slop_os"
import account_records from "../../account_records"
import file_tools from "../../file_tools"
import powerbox_protocol from "../../protocols/powerbox"

/** One of the keys: its kind, its fingerprint, and its comment. */
Key :: struct {
    /** Its kind, as OpenSSH names it: ssh-ed25519, ecdsa-sha2-nistp256 or ssh-rsa. */
    kind : string,
    /** Its fingerprint, SHA256: and 43 characters of base64, as ssh-keygen -l shows it, which --remove takes. */
    fingerprint : string,
    /** Its comment, often who made it where; empty for none. */
    comment : string,
}

/** An error naming the parameter it came from. */
Problem :: struct {
    /** The parameter: add, remove, or powerbox. */
    parameter : os.ParameterName,
}

/** Why it couldn't. */
KeysError :: union {
    /** The file to add can't be read, or its first line isn't a public key. */
    NotAKey(Problem),
    /** The user refused, the key's there already, the account has as many as it may, or no key has that fingerprint. */
    Refused(Problem),
    /** There's no powerbox to ask, as in a session with no trusted path, or it couldn't be asked. */
    NoPowerbox(Problem),
}

/**
 * List the keys that log in as you, or add or remove one.
 *
 * @param here The shell's directory, given without asking, which add's file is beneath.
 * @param add A public key's file to add, beneath here: its first line is the key, as authorized_keys has one.
 * @param remove A key's fingerprint to remove, as the list shows it.
 * @param powerbox The session's powerbox, which does it.
 * @param output Where the keys listed go; without it, they're only counted.
 * @return How many keys are listed, or 1 for one added or removed.
 * @error NotAKey The file can't be read, or isn't a public key's: add the .pub file, not the private key.
 * @error Refused It wasn't allowed, or couldn't be done: the key's there already, there are 16, or no key has that
 *     fingerprint.
 * @error NoPowerbox There's no powerbox to ask.
 */
main :: fn(here: os.Channel[dir.Dir], add: string?, remove: string?, powerbox: os.Channel[powerbox_protocol.Powerbox]?,
    output: os.Sink[Key]?) -> Result[u64, KeysError] {
    asked :: if add is_some { "add" } else if remove is_some { "remove" } else { "powerbox" }
    problem :: Problem.{parameter = os.ParameterName.{name = asked}}
    box :: powerbox or_return .Error(.NoPowerbox(problem))
    match add {
        case Some(path) => {
            directory, opened :: os.directory_on(here.end)
            if opened != null {
                return .Error(.NotAKey(problem))
            }
            text :: os.read_entire_file_in(directory, path) or_return .Error(.NotAKey(problem))
            line :: first_line(string_bytes(text))
            if account_records.key_fingerprint(line) is_none {
                return .Error(.NotAKey(problem))
            }
            ask(box, .Add, line) or_return .Error(.Refused(problem))
            return .Ok(1)
        }
        case None => {}
    }
    match remove {
        case Some(fingerprint) => {
            ask(box, .Remove, string_bytes(fingerprint)) or_return .Error(.Refused(problem))
            return .Ok(1)
        }
        case None => {}
    }
    listed :: ask(box, .List, u8.[]) or_return .Error(.NoPowerbox(problem))
    writer := stream.Writer[Key].{}
    writing := false
    match output {
        case Some(sink) => {
            writer = stream.writer_on(sink) or_return .Error(.NoPowerbox(problem))
            writing = true
        }
        case None => {}
    }
    count := cast[u64](0)
    reading := cast[usize](0)
    loop {
        line :: account_records.next_line(string_bytes(listed), &reading) or_break
        printed :: account_records.key_fingerprint(line) or_continue
        comment : u8[account_records.COMMENT_BYTES]
        comment_count :: account_records.comment_of(line, comment[0..<comment.count])
        key :: Key.{kind = file_tools.copy_of(first_word(line)) or_else "", fingerprint = file_tools.copy_of(printed[0..<50]) or_else "",
            comment = file_tools.copy_of(account_records.part(comment[0..<comment.count], comment_count)) or_else ""}
        count += 1
        if writing && (stream.write(&writer, key) is_some) {
            return .Error(.NoPowerbox(problem))
        }
    }
    while true
    if writing && (stream.finish(&writer, 0) is_some) {
        return .Error(.NoPowerbox(problem))
    }
    return .Ok(count)
}

/**
 * Ask the session's powerbox to list, add or remove a key, and wait for its answer.
 *
 * @param box The powerbox.
 * @param change What's asked.
 * @param key The key's line to add, or its fingerprint to remove; empty to list.
 * @return The keys' text for a list, "" once one's added or removed; null if it was refused or couldn't be asked.
 */
ask :: fn(box: os.Channel[powerbox_protocol.Powerbox], change: powerbox_protocol.KeysChange, key: u8[]) -> string? {
    port :: os.port_for(slop_os.startup_block().budget, box.end) or_return null
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    out := os.Outgoing.{}
    request :: os.begin[powerbox_protocol.Request](&out)
    request^ = .RequestKeys(powerbox_protocol.KeysRequest.{purpose = os.append(&out, string_bytes(
        if change == .Add { "to log in as you over SSH" } else if change == .Remove { "so it no longer logs in" } else { "to list them" })),
        change = change, key = os.append(&out, key)})
    if powerbox_protocol.send_request(box.end, port, &out) is_some {
        return null
    }
    into := os.Incoming.{}
    match powerbox_protocol.receive_response(box.end, port, &into, true) {
        case Received => {}
        case _ => return null
    }
    return match os.message_of[powerbox_protocol.Response](&into)^ {
        case KeysListed(listed) => file_tools.copy_of(os.items(&into, listed))
        case Done => ""
        case _ => null
    }
}

/** A text's first line, without its line break. */
first_line :: fn(text: u8[]) -> u8[] {
    for byte, i in text {
        if byte == 0x0a {
            return text[0..<i]
        }
    }
    return text
}

/** A line's first word: up to its first space. */
first_word :: fn(line: u8[]) -> u8[] {
    for byte, i in line {
        if byte == 0x20 {
            return line[0..<i]
        }
    }
    return line
}
