/**
 * A connection's session (decisions/0191, 14d): started by a shell or exec request on its session channel, through the
 * session manager, with the home the login opened, a terminal the service serves, and a prompt connection of the
 * service's own, which refuses whatever's asked, since a remote session has no trusted path (decisions/0043).
 *
 * The terminal's requests become what's sent on the channel (src/remote_terminal), at the size the client's pty-req and
 * window-change give, or plain without a pty; what the client sends becomes input events (src/vt). When the session's
 * first program ends, its exit status is sent, then EOF, and the channel's closed.
 */
package ssh_service

import runtime from "base"
import net from "std"
import os from "std"
import ssh from "std"
import text_buffer from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import net_address from "std/os/slop_os"
import terminal from "std/os/slop_os"
import log_line from "../../log_line"
import prompt from "../../protocols/prompt"
import session from "../../protocols/session"
import remote_terminal from "../../remote_terminal"
import vt from "../../vt"

/** The most bytes waiting to be sent on a session's channel; the terminal's requests wait while it's half full. */
PENDING_BYTES :: 65536

/** A connection, and its session once it has one. */
Remote :: struct {
    /** Its SSH connection, zeroed when it's made. */
    conn : ssh.Connection,
    tcp : net.Tcp,
    address : net_address.Address,
    /** The service's port, which its ends are bound to; its keys on it start at key. */
    port : slop_os.Port,
    /** Its keys on the service's port start here. */
    key : u64,
    started_at : u64,
    authenticated : bool,
    closing : bool,
    /** What's come from the client that the connection hasn't taken yet. */
    inbox : u8[16384],
    inbox_first : usize,
    inbox_count : usize,
    /** The home the login opened, until a session takes it; NONE for none. */
    home : slop_os.Channel,
    /** Its session channel. */
    channel : u32,
    has_channel : bool,
    /** Its pty's size, if it asked for one. */
    pty : bool,
    columns : u32,
    rows : u32,
    /** Its session, once it's started. */
    started : bool,
    session : u32,
    term : remote_terminal.RemoteTerminal,
    decoder : vt.Decoder,
    decoded : vt.Decoded,
    /** The terminal's, prompts' and wait's ends, the service's; NONE for none. */
    terminal_end : slop_os.Channel,
    prompts_end : slop_os.Channel,
    wait_end : slop_os.Channel,
    /** How many events a Read waits for; 0 for none waiting. */
    held : u32,
    /** What's to go on the channel. */
    pending : u8[PENDING_BYTES],
    pending_count : usize,
    /** The session's first program's end, once it's come, to be sent once what's pending is. */
    exited : bool,
    exit_code : u64,
    finished : bool,
    /** Whether the session manager's been asked to end the session. */
    stopped : bool,
    /** Its SFTP, for the sftp subsystem, in place of a session; null for none. */
    sftp : ptr[mut Sftp]?,
}

/** Take a channel request: a pty's size, then a shell or a command, which starts the session. */
channel_request :: fn(service: ptr[mut Service], remote: ptr[mut Remote], number: u32) {
    request :: ssh.request_of(&remote.conn)
    kind :: request.kind
    if kind == .Pty && !remote.started {
        remote.pty = true
        remote.columns = request.columns
        remote.rows = request.rows
        ssh.answer_request(&remote.conn, true)
        return void
    }
    if kind == .Subsystem && !remote.started && remote.has_channel && number == remote.channel {
        ssh.answer_request(&remote.conn, ssh.is(ssh.request_text(request), "sftp") && start_sftp(service, remote))
        return void
    }
    if (kind == .Shell || kind == .Exec) && !remote.started && remote.has_channel && number == remote.channel {
        command :: if kind == .Exec { ssh.request_text(request) } else { u8.[] }
        ssh.answer_request(&remote.conn, start_session(service, remote, command))
        return void
    }
    ssh.answer_request(&remote.conn, false)
}

/** The client's terminal was resized: the terminal's size, and a Resize for its reader. */
window_changed :: fn(remote: ptr[mut Remote]) {
    request :: ssh.request_of(&remote.conn)
    remote_terminal.resize(&remote.term, request.columns, request.rows)
    if remote.decoded.count < remote.decoded.events.count {
        remote.decoded.events[remote.decoded.count] = terminal.Event.{kind = cast[u8](terminal.EventKind.Resize),
            columns = remote.term.columns, rows = remote.term.rows}
        remote.decoded.count += 1
    }
    deliver(remote)
}

/** Take what the client sent on its channel: input for the session's terminal. */
channel_input :: fn(remote: ptr[mut Remote], number: u32) {
    // SFTP's requests are taken as serve_session has room for their answers
    if remote.sftp is_some {
        return void
    }
    chunk : u8[terminal.MAX_EVENT_TEXT]
    loop {
        // No more than its events and their text have room for, each byte an event at most: the rest waits on the channel
        events_room :: remote.decoded.events.count - remote.decoded.count
        text_room :: remote.decoded.text.count - remote.decoded.text_count
        room :: if events_room < text_room { events_room } else { text_room }
        if room < 4 || room > chunk.count {
            break
        }
        got :: ssh.channel_read(&remote.conn, number, chunk[0..<room - 2])
        if got == 0 {
            break
        }
        if remote.terminal_end != NONE && got <= chunk.count {
            vt.feed(&remote.decoder, chunk[0..<got], &remote.decoded)
            vt.finish(&remote.decoder, &remote.decoded)
        }
    }
    while true
    deliver(remote)
}

/**
 * Start a connection's session: its home, a terminal and a prompt connection of the service's, and the command if
 * there's one.
 *
 * @return True once it's started.
 */
start_session :: fn(service: ptr[mut Service], remote: ptr[mut Remote], command: u8[]) -> bool {
    if remote.home == NONE || command.count > session.COMMAND_BYTES {
        return false
    }
    budget :: slop_os.startup_block().budget
    terminals :: os.channel_for[terminal.Terminal](budget, terminal.RING_BYTES) or_return false
    prompts :: os.channel_for[prompt.Prompt](budget, 0) or_return false
    remote.term = if remote.pty { remote_terminal.make(remote.columns, remote.rows) } else { remote_terminal.make_plain() }
    out := os.Outgoing.{}
    request :: os.begin[session.Request](&out)
    request^ = .Start(session.SessionStart.{user = os.append(&out, ssh.user_of(&remote.conn)), layout = os.append(&out, string_bytes("us")),
        home = os.Channel[dir.Dir].{end = remote.home}, terminal = os.Channel[terminal.Terminal].{end = terminals.b},
        prompts = os.Channel[prompt.Prompt].{end = prompts.b}, command = os.append(&out, command)})
    // The home, the terminal's and prompts' other ends move with it
    remote.home = NONE
    into := os.Incoming.{}
    number := cast[u32](0)
    started := false
    if session.send_request(service.sessions_end, service.sessions_port, &out) == null {
        match session.receive_response(service.sessions_end, service.sessions_port, &into, true) {
            case Received => {
                match os.message_of[session.Response](&into)^ {
                    case Started(given) => {
                        number = given
                        started = true
                    }
                    case _ => {}
                }
            }
            case _ => {}
        }
    }
    if !started {
        _ = slop_os.handle_close(cast[slop_os.Handle](terminals.a))
        _ = slop_os.handle_close(cast[slop_os.Handle](prompts.a))
        log_line.write(service.log, "ssh_service: the session couldn't be started")
        return false
    }
    remote.started = true
    remote.session = number
    remote.terminal_end = terminals.a
    remote.prompts_end = prompts.a
    signals :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    _ = slop_os.port_bind(service.port, cast[slop_os.Handle](remote.terminal_end), signals, remote.key + TERMINAL_KEY, .Persistent)
    _ = slop_os.port_bind(service.port, cast[slop_os.Handle](remote.prompts_end), signals, remote.key + PROMPTS_KEY, .Persistent)
    // Its end waited for on a connection of its own
    match session.connect(service.sessions_end, service.sessions_port, budget) {
        case Some(waiting) => {
            remote.wait_end = waiting.end
            asking := os.Outgoing.{}
            os.begin[session.Request](&asking)^ = .Wait(number)
            _ = session.send_request(remote.wait_end, service.port, &asking)
            _ = slop_os.port_bind(service.port, cast[slop_os.Handle](remote.wait_end), signals, remote.key + WAIT_KEY, .Persistent)
        }
        case None => {}
    }
    log_line.write(service.log, "ssh_service: started a session for % %", text_of(ssh.user_of(&remote.conn)),
        if command.count > 0 { "to run a command" } else { "with a shell" })
    return true
}

/**
 * Serve a connection's session: its terminal's requests while there's room for their output, its prompts refused, its
 * end taken; then what's pending sent on its channel, and once its program's ended, its exit status, EOF and close.
 *
 * @return True if anything moved.
 */
serve_session :: fn(service: ptr[mut Service], remote: ptr[mut Remote]) -> bool {
    if !remote.started {
        return false
    }
    moved := false
    into := os.Incoming.{}
    match remote.sftp {
        case Some(sftp) => moved = serve_sftp(remote, sftp)
        case None => {}
    }
    // The terminal's requests, while what they make has room
    loop {
        if remote.terminal_end == NONE || remote.pending_count > PENDING_BYTES / 2 {
            break
        }
        match terminal.receive_request(remote.terminal_end, service.port, &into, false) {
            case Received => {}
            case Empty => break
            case Unsupported => {
                _ = terminal.answer_unsupported(remote.terminal_end, service.port)
                continue
            }
            case _ => {
                _ = slop_os.port_unbind(service.port, remote.key + TERMINAL_KEY)
                _ = slop_os.handle_close(cast[slop_os.Handle](remote.terminal_end))
                remote.terminal_end = NONE
                break
            }
        }
        moved = true
        terminal_request(service, remote, &into)
    }
    while true
    // A remote session's prompts: refused, as there's no trusted path
    loop {
        if remote.prompts_end == NONE {
            break
        }
        match prompt.receive_request(remote.prompts_end, service.port, &into, false) {
            case Received => {}
            case Empty => break
            case _ => {
                _ = slop_os.port_unbind(service.port, remote.key + PROMPTS_KEY)
                _ = slop_os.handle_close(cast[slop_os.Handle](remote.prompts_end))
                remote.prompts_end = NONE
                break
            }
        }
        match os.message_of[prompt.Request](&into)^ {
            case Ask(asked) => _ = slop_os.handle_close(cast[slop_os.Handle](asked.home.end))
        }
        out := os.Outgoing.{}
        os.begin[prompt.Response](&out)^ = .Refused
        _ = prompt.send_response(remote.prompts_end, service.port, &out)
        moved = true
    }
    while true
    // Its first program's end
    if remote.wait_end != NONE {
        match session.receive_response(remote.wait_end, service.port, &into, false) {
            case Received => {
                match os.message_of[session.Response](&into)^ {
                    case Refused => remote.stopped = true
                    case Exited(code) => {
                        remote.exited = true
                        remote.exit_code = code
                        log_line.write(service.log, "ssh_service: a session ended with %", code)
                        stop_session(service, remote)
                    }
                    case _ => {}
                }
                _ = slop_os.port_unbind(service.port, remote.key + WAIT_KEY)
                _ = slop_os.handle_close(cast[slop_os.Handle](remote.wait_end))
                remote.wait_end = NONE
                moved = true
            }
            case Empty => {}
            case _ => {
                _ = slop_os.port_unbind(service.port, remote.key + WAIT_KEY)
                _ = slop_os.handle_close(cast[slop_os.Handle](remote.wait_end))
                remote.wait_end = NONE
                // Its number may be another session's by the time this one closes
                remote.stopped = true
            }
        }
    }
    // What's pending, onto the channel
    if remote.pending_count > 0 && remote.has_channel {
        sent :: ssh.channel_write(&remote.conn, remote.channel, ssh.range(remote.pending[0..<PENDING_BYTES], 0, remote.pending_count))
        if sent > 0 {
            remote.pending_count = ssh.drop_front(remote.pending[0..<PENDING_BYTES], remote.pending_count, sent)
            moved = true
        }
    }
    if remote.exited && !remote.finished && remote.pending_count == 0 && remote.has_channel {
        status :: if remote.exit_code > 255 { cast[u32](255) } else { cast[u32](remote.exit_code) }
        ssh.channel_exit_status(&remote.conn, remote.channel, status)
        ssh.channel_eof(&remote.conn, remote.channel)
        ssh.channel_close(&remote.conn, remote.channel)
        remote.finished = true
        moved = true
    }
    return moved
}

/** Take one of the terminal's requests. */
terminal_request :: fn(service: ptr[mut Service], remote: ptr[mut Remote], into: ptr[mut os.Incoming]) {
    storage : u8[16384]
    out := text_buffer.make(storage)
    match os.message_of[terminal.Request](into)^ {
        case Write(text) => remote_terminal.write(&remote.term, os.items(into, text.text), os.items(into, text.runs), os.items(into, text.links), &out)
        case MoveCursor(position) => remote_terminal.move_cursor(&remote.term, position, &out)
        case ShowCursor(shown) => {
            if !remote.term.plain {
                vt.append_cursor_shown(&out, shown)
            }
        }
        case Clear(area) => remote_terminal.clear(&remote.term, area, &out)
        case Scroll(scrolled) => remote_terminal.scroll(&remote.term, scrolled, &out)
        case Screen(whole) => remote_terminal.use_screen(&remote.term, whole, &out)
        case Bell => {
            if !remote.term.plain {
                vt.append_bell(&out)
            }
        }
        case Describe => {
            answer := os.Outgoing.{}
            os.begin[terminal.Response](&answer)^ = .Described(remote_terminal.features(&remote.term))
            _ = terminal.send_response(remote.terminal_end, service.port, &answer)
        }
        case Read(most) => {
            remote.held = if most == 0 { cast[u32](1) } else { most }
            deliver(remote)
        }
        case InputLine(line) => remote_terminal.set_input(&remote.term, os.items(into, line.text), line.cursor, &out)
        case Connect(connection) => _ = slop_os.handle_close(cast[slop_os.Handle](connection.end))
        case ReleaseInput => {
            remote_terminal.drop_input(&remote.term, &out)
            if remote.held > 0 {
                answer_read(remote, 0)
            }
        }
    }
    // Output cut short could end inside a sequence, which the next could finish as the program likes: it's dropped
    if out.truncated {
        return void
    }
    add_pending(remote, string_bytes(text_buffer.as_string(&out)))
}

/** Add bytes to what's to go on the channel; what doesn't fit is dropped. */
add_pending :: fn(remote: ptr[mut Remote], bytes: u8[]) {
    for byte in bytes {
        if remote.pending_count < remote.pending.count {
            remote.pending[remote.pending_count] = byte
            remote.pending_count += 1
        }
    }
}

/** Answer a Read waiting with the events decoded, if there are any. */
deliver :: fn(remote: ptr[mut Remote]) {
    if remote.held == 0 || remote.decoded.count == 0 || remote.terminal_end == NONE {
        return void
    }
    answer_read(remote, remote.decoded.count)
}

/** Answer the Read waiting with the first count events decoded, all of them or none, and start again. */
answer_read :: fn(remote: ptr[mut Remote], count: usize) {
    if remote.terminal_end == NONE || count > remote.decoded.events.count || remote.decoded.text_count > remote.decoded.text.count {
        return void
    }
    out := os.Outgoing.{}
    response :: os.begin[terminal.Response](&out)
    response^ = .Input(terminal.Events.{events = os.append(&out, remote.decoded.events[0..<count]),
        text = os.append(&out, remote.decoded.text[0..<remote.decoded.text_count])})
    _ = terminal.send_response(remote.terminal_end, remote.port, &out)
    remote.held = 0
    remote.decoded.count = 0
    remote.decoded.text_count = 0
}

/** Have the session manager end a connection's session, every program of it, once, if it was started. */
stop_session :: fn(service: ptr[mut Service], remote: ptr[mut Remote]) {
    if !remote.started || remote.stopped || (remote.sftp is_some) {
        return void
    }
    remote.stopped = true
    out := os.Outgoing.{}
    os.begin[session.Request](&out)^ = .EndSession(remote.session)
    if session.send_request(service.sessions_end, service.sessions_port, &out) == null {
        into := os.Incoming.{}
        _ = session.receive_response(service.sessions_end, service.sessions_port, &into, true)
    }
}

/** End a connection's session: its terminal closed, which ends its programs, and its prompts and wait. */
end_session :: fn(remote: ptr[mut Remote]) {
    match remote.sftp {
        case Some(sftp) => {
            end_sftp(sftp)
            runtime.free(sftp)
            remote.sftp = null
        }
        case None => {}
    }
    for end in slop_os.Channel.[remote.terminal_end, remote.prompts_end, remote.wait_end] {
        if end != NONE {
            _ = slop_os.handle_close(cast[slop_os.Handle](end))
        }
    }
    remote.terminal_end = NONE
    remote.prompts_end = NONE
    remote.wait_end = NONE
}
