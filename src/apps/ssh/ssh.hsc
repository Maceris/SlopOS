/**
 * ssh (decisions/0191, 14f): run a command on another computer over SSH, its output shown here and its exit status
 * given back. It logs in with your key, .ssh/id_ed25519 beneath the shell's directory (ssh_keygen makes it), or else
 * the password, asked for on the terminal and not shown. The first time it meets a computer, it shows the computer's
 * host key's fingerprint and asks whether to trust it, keeping it in .ssh/known_hosts; a key that's changed since is
 * refused. A private address, which the session's network doesn't allow, is asked of the powerbox, as connect does.
 *
 *     ssh admin@192.168.1.20 "list"
 *     ssh me@10.0.2.2 "uname -a" --port 2222
 *
 * Only commands are run, without a terminal of the other computer's: SlopOS's terminal shows text, never another
 * program's escape sequences.
 */
package ssh_app

import runtime from "base"
import crypto from "std"
import net from "std"
import os from "std"
import ssh from "std"
import strings from "std"
import terminal from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import net_address from "std/os/slop_os"
import network from "std/os/slop_os"
import terminal as protocol from "std/os/slop_os"
import powerbox_protocol from "../../protocols/powerbox"

/** An error naming the parameter it came from. */
Problem :: struct {
    parameter : os.ParameterName,
}

/** Why it couldn't. */
SshError :: union {
    /** The destination isn't user@address. */
    BadDestination(Problem),
    /** The session's network doesn't allow it, and the user didn't, or there was no powerbox to ask. */
    NotAllowed(Problem),
    /** It couldn't connect, or the connection broke. */
    Unreachable(Problem),
    /** The computer's host key isn't the one known for it: someone may be in the way. */
    HostKeyChanged(Problem),
    /** You didn't trust its host key. */
    NotTrusted(Problem),
    /** It refused your key and password. */
    Refused(Problem),
}

/** A connection, and what's needed while it runs. */
Client :: struct {
    conn : ssh.Connection,
    tcp : net.Tcp,
    console : terminal.Terminal,
    editor : terminal.LineEditor,
    directory : os.Directory,
    host : u8[256],
    host_count : usize,
    command_bytes : u8[4096],
    command_count : usize,
    exit_status : u32,
    exited : bool,
    finished : bool,
    failure : u8,
    inbox : u8[16384],
}

/** What failed, as Client.failure. */
FAILED_UNTRUSTED : u8 : 1
FAILED_CHANGED : u8 : 2
FAILED_REFUSED : u8 : 3

/**
 * Run a command on another computer.
 *
 * @param here The shell's directory, given without asking: your key and known hosts are in .ssh beneath it.
 * @param destination Who and where: user@address, an IPv4 address in dotted decimal or a name.
 * @param command The command, as the other computer's shell takes it.
 * @param port Its SSH port; 22 without it.
 * @param console The terminal, where the output's shown and questions asked.
 * @param network The session's network connection.
 * @param powerbox The session's powerbox, asked for an address the session's network doesn't allow.
 * @return The command's exit status.
 * @error BadDestination It isn't user@address.
 * @error NotAllowed The address wasn't allowed.
 * @error Unreachable It couldn't connect, or the connection broke.
 * @error HostKeyChanged Its host key isn't the one in .ssh/known_hosts: check it with whoever runs it.
 * @error NotTrusted You didn't trust its host key.
 * @error Refused Your key and password were refused.
 */
main :: fn(here: os.Channel[dir.Dir], destination: string, command: string, port: u16?, console: os.Channel[protocol.Terminal],
    network: os.Channel[network.Network], powerbox: os.Channel[powerbox_protocol.Powerbox]?) -> Result[u32, SshError] {
    where :: Problem.{parameter = os.ParameterName.{name = "destination"}}
    bytes :: string_bytes(destination)
    at := bytes.count
    for byte, i in bytes {
        if byte == 0x40 && at == bytes.count {
            at = i
        }
    }
    user :: as_text(ssh.range(bytes, 0, at))
    host :: as_text(ssh.range(bytes, at + 1, bytes.count))
    if user.count == 0 || host.count == 0 || host.count > 255 {
        return .Error(.BadDestination(where))
    }
    client :: runtime.new(Client)
    client.console = terminal.open(console) or_return .Error(.Unreachable(where))
    client.command_count = if command.count <= client.command_bytes.count { command.count } else { client.command_bytes.count }
    for byte, i in string_bytes(command) {
        if i < client.command_bytes.count {
            client.command_bytes[i] = byte
        }
    }
    for byte, i in string_bytes(host) {
        if i < client.host.count {
            client.host[i] = byte
        }
    }
    client.host_count = host.count
    directory, opened :: os.directory_on(here.end)
    if opened != null {
        return .Error(.Unreachable(where))
    }
    client.directory = directory
    // Connected, through the powerbox if the session's network doesn't allow it
    to_port :: port or_else 22
    client.tcp = connect(network, powerbox, host, to_port) or_return .Error(.NotAllowed(where))
    start_client(client, directory, user)
    run(client)
    net.close(&client.tcp)
    if client.failure == FAILED_CHANGED {
        return .Error(.HostKeyChanged(where))
    }
    if client.failure == FAILED_UNTRUSTED {
        return .Error(.NotTrusted(where))
    }
    if client.failure == FAILED_REFUSED {
        return .Error(.Refused(where))
    }
    if !client.exited {
        return .Error(.Unreachable(where))
    }
    return .Ok(client.exit_status)
}

/** Connect by TCP to a host and port: through the session's network, or, for what it doesn't allow, the powerbox's. */
connect :: fn(network: os.Channel[network.Network], powerbox: os.Channel[powerbox_protocol.Powerbox]?, host: string, port: u16) -> net.Tcp? {
    match net_address.parse_v4(host) {
        case Some(address) => {
            to :: net_address.Endpoint.{address = address, port = port}
            match net.open(network, to) {
                case Ok(opened) => return opened
                case Error(failure) => {
                    if failure != .NotAllowed {
                        return null
                    }
                    allowed :: ask(powerbox, to) or_return null
                    match net.open(allowed, to) {
                        case Ok(opened) => return opened
                        case Error(again) => return null
                    }
                }
            }
        }
        case None => {
            match net.open_name(network, host, port) {
                case Ok(opened) => return opened
                case Error(failure) => return null
            }
        }
    }
}

/** Ask the powerbox for a network connection to an endpoint by TCP, and wait for the user's answer. */
ask :: fn(powerbox: os.Channel[powerbox_protocol.Powerbox]?, to: net_address.Endpoint) -> os.Channel[network.Network]? {
    box :: powerbox or_return null
    port :: os.port_for(slop_os.startup_block().budget, box.end) or_return null
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    rule :: network.range_rule(to.address, 32, network.TRANSPORT_TCP, to.port, to.port)
    out := os.Outgoing.{}
    request :: os.begin[powerbox_protocol.Request](&out)
    request^ = .RequestNetwork(powerbox_protocol.NetworkRequest.{purpose = os.append(&out, string_bytes("to log in over SSH")),
        connect = os.append(&out, network.Rule.[rule]), listen = os.append(&out, network.Rule.[])})
    if powerbox_protocol.send_request(box.end, port, &out) is_some {
        return null
    }
    into := os.Incoming.{}
    match powerbox_protocol.receive_response(box.end, port, &into, true) {
        case Received => {}
        case _ => return null
    }
    return match os.message_of[powerbox_protocol.Response](&into)^ {
        case NetworkGranted(given) => given
        case _ => null
    }
}

/** Start the connection as a client, with your key from .ssh/id_ed25519 if there's one. */
start_client #constant_time :: fn(client: ptr[mut Client], directory: os.Directory, user: string) {
    text :: os.read_entire_file_in(directory, ".ssh/id_ed25519") or_else ""
    match ssh.parse_private_key(string_bytes(text)) {
        case Some(key) => {
            kept := key
            ssh.client(&client.conn, user, &kept)
        }
        case None => ssh.client(&client.conn, user, null)
    }
}

/** Move bytes between the connection and the network, taking its events, until it's done. */
run :: fn(client: ptr[mut Client]) {
    loop {
        events(client)
        out :: ssh.output(&client.conn)
        if out.count > 0 {
            written :: net.write(&client.tcp, out)
            ssh.sent(&client.conn, written)
            if written < out.count {
                return void
            }
            continue
        }
        if ssh.is_ended(&client.conn) || client.finished {
            return void
        }
        count :: net.read(&client.tcp, client.inbox[0..<client.inbox.count]) or_else 0
        if count == 0 {
            return void
        }
        taken := cast[usize](0)
        loop {
            taken += ssh.received(&client.conn, ssh.range(client.inbox[0..<client.inbox.count], taken, count))
            events(client)
            flush(client)
        }
        while taken < count && !ssh.is_ended(&client.conn)
    }
    while true
}

/** Send what the connection has out. */
flush :: fn(client: ptr[mut Client]) {
    out :: ssh.output(&client.conn)
    if out.count > 0 {
        ssh.sent(&client.conn, net.write(&client.tcp, out))
    }
}

/** The connection's events. */
events :: fn(client: ptr[mut Client]) {
    loop {
        happened :: ssh.take_event(&client.conn) or_break
        match happened {
            case HostKey => ssh.trust_host_key(&client.conn, check_host_key(client))
            case PasswordWanted => ask_password(client)
            case Authenticated => _ = ssh.open_session(&client.conn)
            case AuthenticationRefused => {
                client.failure = FAILED_REFUSED
                client.finished = true
            }
            case ChannelOpened(number) => {
                _ = ssh.channel_request(&client.conn, number, .Exec, as_text(ssh.range(client.command_bytes[0..<4096], 0, client.command_count)))
                ssh.channel_eof(&client.conn, number)
            }
            case ChannelRefused(number) => client.finished = true
            case ChannelData(number) => {
                chunk : u8[4096]
                loop {
                    got :: ssh.channel_read(&client.conn, number, chunk[0..<chunk.count])
                    if got == 0 || got > chunk.count {
                        break
                    }
                    _ = terminal.write(&client.console, string_of(&chunk[0], got))
                }
                while true
            }
            case ExitStatus(exit) => {
                client.exit_status = exit.status
                client.exited = true
            }
            case ChannelClosed(number) => {
                ssh.disconnect(&client.conn, ssh.DISCONNECT_BY_APPLICATION, "done")
                client.finished = true
            }
            case _ => {}
        }
    }
    while true
}

/**
 * Check the host's key against .ssh/known_hosts: the same, trusted; another, refused; none, shown and asked about,
 * and kept if it's trusted.
 */
check_host_key :: fn(client: ptr[mut Client]) -> bool {
    offered :: ssh.blob_of(ssh.host_key_of(&client.conn))
    host :: ssh.range(client.host[0..<client.host.count], 0, client.host_count)
    known :: os.read_entire_file_in(client.directory, ".ssh/known_hosts") or_else ""
    lines :: string_bytes(known)
    start := cast[usize](0)
    for i in cast[usize](0)..<lines.count + 1 {
        if i < lines.count && ssh.byte_at(lines, i) != 0x0a {
            continue
        }
        line :: ssh.range(lines, start, i)
        start = i + 1
        // host, a space, then the key's line
        space := line.count
        for byte, j in line {
            if byte == 0x20 && space == line.count {
                space = j
            }
        }
        if space >= line.count || !ssh.same(ssh.range(line, 0, space), host) {
            continue
        }
        key :: ssh.parse_key_line(ssh.range(line, space + 1, line.count)) or_continue
        if ssh.same(ssh.blob_of(&key), offered) {
            return true
        }
        client.failure = FAILED_CHANGED
        _ = terminal.write_line(&client.console, "Its host key has changed since you trusted it: someone may be in the way.")
        return false
    }
    printed :: ssh.fingerprint(offered)
    _ = terminal.write_line(&client.console, strings.format("%'s host key is %.", as_text(host), string_of(&printed[0], 50)) or_else "")
    // Asked again for an empty answer
    trusted := false
    for tries in 0..<5 {
        match terminal.read_line(&client.editor, &client.console, "Trust it? (yes or no) ") {
            case Line(answer) => {
                if answer.count > 0 {
                    trusted = answer == "yes"
                    break
                }
            }
            case _ => break
        }
    }
    if !trusted {
        client.failure = FAILED_UNTRUSTED
        return false
    }
    // Kept, after what's known
    line : u8[1500]
    count := cast[usize](0)
    for byte in host {
        ssh.set_byte(line[0..<line.count], count, byte)
        count += 1
    }
    ssh.set_byte(line[0..<line.count], count, 0x20)
    count += 1
    count += ssh.key_line(ssh.host_key_of(&client.conn), "", ssh.range_mut(line[0..<line.count], count, line.count))
    ssh.set_byte(line[0..<line.count], count, 0x0a)
    count += 1
    if count <= line.count {
        if os.path_kind_in(client.directory, ".ssh") == .NOTHING {
            _ = os.make_directory_in(client.directory, ".ssh")
        }
        // What's known, then the new line
        old :: string_bytes(known)
        kept, error :: runtime.new_array(u8, old.count + count)
        if error == null && kept.count > 0 {
            for byte, i in old {
                ssh.set_byte(kept, i, byte)
            }
            for i in cast[usize](0)..<count {
                ssh.set_byte(kept, old.count + i, ssh.byte_at(line[0..<line.count], i))
            }
            _ = os.write_entire_file_in(client.directory, ".ssh/known_hosts", string_of(&kept[0], kept.count))
        }
    }
    return true
}

/** Ask for the password on the terminal, not shown, and give it. */
ask_password :: fn(client: ptr[mut Client]) {
    _ = terminal.show_input(&client.console, string_bytes("Password: "), 10)
    typed : u8[256]
    count := cast[usize](0)
    loop {
        match terminal.next_event(&client.console) {
            case Event(event, text) => {
                kind :: protocol.kind_of(event) or_continue
                if kind == .Interrupt || kind == .HangUp {
                    break
                }
                if kind == .Key && event.code == 0x28 {
                    _ = terminal.show_input(&client.console, u8.[], 0)
                    give_password(client, ssh.range(typed[0..<typed.count], 0, count))
                    for &byte in typed {
                        byte^ = 0
                    }
                    return void
                }
                if kind == .Key && event.code == 0x2a {
                    if count > 0 {
                        count -= 1
                    }
                    continue
                }
                if kind == .Key || kind == .Paste {
                    for byte in text {
                        if byte >= 0x20 && count < typed.count {
                            typed[count] = byte
                            count += 1
                        }
                    }
                }
            }
            case _ => break
        }
    }
    while true
    _ = terminal.show_input(&client.console, u8.[], 0)
    client.failure = FAILED_REFUSED
    client.finished = true
}

/** Give the password typed. */
give_password #constant_time :: fn(client: ptr[mut Client], typed: u8[]) {
    ssh.give_password(&client.conn, crypto.as_secret(typed))
}

/** Bytes as text. */
as_text :: fn(bytes: u8[]) -> string {
    return if bytes.count > 0 { string_of(&bytes[0], bytes.count) } else { "" }
}
