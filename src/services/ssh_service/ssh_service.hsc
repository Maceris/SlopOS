/**
 * The SSH service (decisions/0191, 14d): remote login, when the system configuration enables it, or ssh is on the
 * kernel's command line. It listens on its port (22), speaks SSH through std/ssh, logs users in through the account
 * service, a password opening the home as the console's login does and a key the home its password's unlocked since the
 * boot, and starts a session for each through the session manager, serving its terminal itself (sessions.hsc).
 *
 * Its host key, Ed25519, is made the first time it starts, and kept in its system directory as host_key, OpenSSH's
 * private key text, with host_key.pub beside it; its fingerprint is logged as it starts.
 *
 * Before authentication, at most MAX_CONNECTIONS connections at once, MAX_FROM_ONE from one address, AUTH_SECONDS to log
 * in, and std/ssh's tries; past them, a connection's closed. It serves every connection on one port, waiting on none.
 */
package ssh_service

import compiler from "base"
import runtime from "base"
import crypto from "std"
import net from "std"
import os from "std"
import ssh from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import net_address from "std/os/slop_os"
import network from "std/os/slop_os"
import log_line from "../../log_line"
import accounts from "../../protocols/accounts"
import config from "../../protocols/config"
import connector from "../../protocols/connector"
import session from "../../protocols/session"
import service_kit from "../../libraries/service_kit"

/** The most connections at once. */
MAX_CONNECTIONS :: 10
/** The most connections from one address at once. */
MAX_FROM_ONE :: 3
/** How long a connection has to log in, in seconds. */
AUTH_SECONDS : u64 : 30
/** The listener's key on the service's port; each connection's keys follow, KEYS_EACH of them. */
LISTENER_KEY : u64 : 1
FIRST_KEY : u64 : 16
KEYS_EACH : u64 : 4
/** A connection's keys, after its first: its TCP stream, its session's terminal, its prompts, and its wait. */
TCP_KEY : u64 : 0
TERMINAL_KEY : u64 : 1
PROMPTS_KEY : u64 : 2
WAIT_KEY : u64 : 3
/** What's no channel. */
NONE :: cast[slop_os.Channel](slop_os.NO_HANDLE)

/** The service's settings, owner ssh_service's: whether it runs, and its port. */
SshSettings :: struct {
    /** Whether remote login is on; off unless the system configuration says so. */
    enabled : bool,
    /** The port it listens on. */
    port : u16 = 22,
}

/** The service's state. */
Service :: struct {
    log : slop_os.DebugLog,
    port : slop_os.Port,
    host : crypto.Ed25519SecretKey,
    listener : net.Listener,
    /** The connection asked of the listener, while asking. */
    pending : net.Tcp,
    asking : bool,
    /** The account service's connector, dialed for each question; and the session manager. */
    accounts_dialing : slop_os.Channel,
    sessions_end : slop_os.Channel,
    sessions_port : slop_os.Port,
    remotes : Slot[MAX_CONNECTIONS],
}

/** A place for a connection. */
Slot :: struct {
    remote : ptr[mut Remote]?,
}

main :: fn(log: slop_os.DebugLog?, network_service: os.Channel[connector.Connector]?, accounts_service: os.Channel[connector.Connector]?,
    sessions: os.Channel[session.Session]?, store: os.Channel[dir.Dir]?, settings: config.Config[SshSettings]?, command_line: slop_os.Memory?) -> int {
    startup :: slop_os.startup_block()
    service :: runtime.new(Service)
    service.log = log or_else cast[slop_os.DebugLog](slop_os.NO_HANDLE)
    service.port = slop_os.port_create(startup.budget) or_return 1
    _ = service_kit.watch_stop(service.port)
    asked :: read_settings(settings, command_line)
    if !asked.enabled {
        log_line.write(service.log, "ssh_service: remote login isn't enabled")
        return 0
    }
    service.host = host_key(service, store) or_return 3
    dialing :: network_service or_return 2
    dial_port :: os.port_for(startup.budget, dialing.end) or_return 2
    root :: connector.dial[network.Network](dialing.end, dial_port) or_return 2
    service.accounts_dialing = (accounts_service or_return 2).end
    service.sessions_end = (sessions or_return 2).end
    service.sessions_port = os.port_for(startup.budget, service.sessions_end) or_return 2
    match net.listen(root, asked.port) {
        case Ok(made) => service.listener = made
        case Error(failure) => {
            log_line.write(service.log, "ssh_service: can't listen on %: %", asked.port, failure)
            return 4
        }
    }
    if !net.listener_on(&service.listener, service.port, LISTENER_KEY) {
        return 4
    }
    log_line.write(service.log, "ssh_service: listening on %", asked.port)
    ask_next(service)
    loop {
        if service_kit.stopping() {
            return 0
        }
        take_accepted(service)
        now :: slop_os.clock_monotonic() or_else 0
        for &slot, i in service.remotes {
            match slot.remote {
                case Some(remote) => {
                    pump(service, remote)
                    if remote.closing || (!remote.authenticated && now > remote.started_at + AUTH_SECONDS * 1000000000) {
                        close_remote(service, remote)
                        runtime.free(remote)
                        slot.remote = null
                    }
                }
                case None => {}
            }
        }
        packets : slop_os.Packet[16]
        _ = slop_os.port_wait(service.port, packets, now + 1000000000)
    }
}

/**
 * Read whether the service is enabled, and its port: its settings, or ssh on the kernel's command line.
 *
 * @return The settings; disabled if neither says otherwise.
 */
read_settings :: fn(settings: config.Config[SshSettings]?, command_line: slop_os.Memory?) -> SshSettings {
    found := SshSettings.{}
    match settings {
        case Some(given) => {
            match os.port_for(slop_os.startup_block().budget, given.end) {
                case Some(port) => {
                    _ = config.declare(given, port)
                    value := os.Outgoing.{}
                    if config.read(given, port, &value) is_ok {
                        found = os.typed_value[SshSettings](os.value_bytes(&value))^
                    }
                    _ = slop_os.handle_close(cast[slop_os.Handle](port))
                }
                case None => {}
            }
        }
        case None => {}
    }
    match command_line {
        case Some(memory) => {
            text :: service_kit.text_of(slop_os.startup_block(), memory) or_else ""
            if service_kit.has_word(text, "ssh") {
                found.enabled = true
            }
        }
        case None => {}
    }
    if found.port == 0 {
        found.port = 22
    }
    return found
}

/**
 * The host key: read from the service's directory, or made the first time and kept there, with its public key's line
 * beside it; its fingerprint logged.
 *
 * @return The key; null without a directory, or if it couldn't be read or kept.
 */
host_key #constant_time :: fn(service: ptr[mut Service], store: os.Channel[dir.Dir]?) -> crypto.Ed25519SecretKey? {
    given :: store or_return null
    directory, opened :: os.directory_on(given.end)
    if opened != null {
        return null
    }
    key : crypto.Ed25519SecretKey
    match os.read_entire_file_in(directory, "host_key") {
        case Ok(text) => {
            key = ssh.parse_private_key(string_bytes(text)) or_return null
        }
        case Error(error) => {
            random : u8[32]
            ssh.random_bytes(random[0..<32])
            for i in cast[usize](0)..<32 {
                key[i] = random[i]
                random[i] = 0
            }
            text : u8[ssh.PRIVATE_KEY_TEXT_BYTES]
            length :: ssh.private_key_text(&key, "slopos host key", text[0..<ssh.PRIVATE_KEY_TEXT_BYTES])
            if length == 0 || length > text.count || (os.write_entire_file_in(directory, "host_key", string_of(&text[0], length)) is_some) {
                return null
            }
            for &byte in text {
                byte^ = 0
            }
            public :: crypto.ed25519_public_key(&key)
            blob :: ssh.ed25519_blob(&public)
            line : u8[200]
            made :: ssh.parse_public_key(blob[0..<ssh.ED25519_BLOB_BYTES]) or_return null
            line_length :: ssh.key_line(&made, "", line[0..<200])
            if line_length == 0 || line_length > line.count || (os.write_entire_file_in(directory, "host_key.pub", string_of(&line[0], line_length)) is_some) {
                return null
            }
            log_line.write(service.log, "ssh_service: made a host key")
        }
    }
    public :: crypto.ed25519_public_key(&key)
    blob :: ssh.ed25519_blob(&public)
    printed :: ssh.fingerprint(blob[0..<ssh.ED25519_BLOB_BYTES])
    log_line.write(service.log, "ssh_service: host key %", string_of(&printed[0], 50))
    return key
}

/** Ask the listener for the next connection, unless one's asked for already. */
ask_next :: fn(service: ptr[mut Service]) {
    if service.asking {
        return void
    }
    match net.ask_accept(&service.listener) {
        case Ok(made) => {
            service.pending = made
            service.asking = true
        }
        case Error(failure) => log_line.write(service.log, "ssh_service: can't ask for a connection: %", failure)
    }
}

/** Take the connection asked for, if it's come: served if there's room, closed if not; then ask for the next. */
take_accepted :: fn(service: ptr[mut Service]) {
    if !service.asking {
        ask_next(service)
        return void
    }
    match net.take_accepted(&service.listener, &service.pending) {
        case Waiting => return void
        case Failed(failure) => {
            service.asking = false
            ask_next(service)
            return void
        }
        case Came(remote) => {
            service.asking = false
            accept(service, remote.address)
            ask_next(service)
        }
    }
}

/** Serve the connection that came, from an address, if there's room for it. */
accept :: fn(service: ptr[mut Service], address: net_address.Address) {
    free := service.remotes.count
    from_there := cast[usize](0)
    for &slot, i in service.remotes {
        match slot.remote {
            case Some(remote) => {
                if same_address(remote.address, address) {
                    from_there += 1
                }
            }
            case None => {
                if free == service.remotes.count {
                    free = i
                }
            }
        }
    }
    if free >= service.remotes.count || from_there >= MAX_FROM_ONE {
        log_line.write(service.log, "ssh_service: refused a connection: too many")
        net.close(&service.pending)
        return void
    }
    remote :: runtime.new(Remote)
    remote.tcp = service.pending
    remote.address = address
    remote.key = FIRST_KEY + cast[u64](free) * KEYS_EACH
    remote.port = service.port
    remote.started_at = slop_os.clock_monotonic() or_else 0
    remote.terminal_end = NONE
    remote.prompts_end = NONE
    remote.wait_end = NONE
    remote.home = NONE
    if !net.serve_on(&remote.tcp, service.port, remote.key + TCP_KEY) {
        net.close(&remote.tcp)
        runtime.free(remote)
        return void
    }
    ssh.server(&remote.conn, &service.host)
    service.remotes[free].remote = remote
    log_line.write(service.log, "ssh_service: a connection")
}

/**
 * Move what's ready on a connection: bytes from the client to its SSH connection, its events taken, its session's
 * terminal served, and what's to go out written.
 */
pump :: fn(service: ptr[mut Service], remote: ptr[mut Remote]) {
    if !net.poll(&remote.tcp) {
        remote.closing = true
        return void
    }
    for round in 0..<64 {
        moved := false
        // In from the client, as far as the connection takes it
        if remote.inbox_count == 0 {
            remote.inbox_first = 0
            remote.inbox_count = net.read_now(&remote.tcp, remote.inbox[0..<remote.inbox.count])
        }
        if remote.inbox_count > 0 {
            taken :: ssh.received(&remote.conn, ssh.range(remote.inbox[0..<remote.inbox.count], remote.inbox_first, remote.inbox_first + remote.inbox_count))
            remote.inbox_first += taken
            remote.inbox_count -= taken
            moved = moved || taken > 0
        }
        moved = take_events(service, remote) || moved
        moved = serve_session(service, remote) || moved
        // Out to the client, as far as there's room
        out :: ssh.output(&remote.conn)
        if out.count > 0 {
            written :: net.write_now(&remote.tcp, out)
            ssh.sent(&remote.conn, written)
            moved = moved || written > 0
        }
        if !moved {
            break
        }
    }
    if ssh.is_ended(&remote.conn) && ssh.output(&remote.conn).count == 0 {
        remote.closing = true
    }
    if net.is_done(&remote.tcp) && remote.inbox_count == 0 {
        remote.closing = true
    }
}

/** Take a connection's SSH events: true if there were any. */
take_events :: fn(service: ptr[mut Service], remote: ptr[mut Remote]) -> bool {
    any := false
    loop {
        happened :: ssh.take_event(&remote.conn) or_break
        any = true
        match happened {
            case Password => log_in_with_password(service, remote)
            case PublicKey(signed) => log_in_with_key(service, remote, signed)
            case ChannelOpened(number) => {
                if remote.has_channel {
                    ssh.channel_close(&remote.conn, number)
                }
                else {
                    remote.channel = number
                    remote.has_channel = true
                }
            }
            case ChannelRequest(number) => channel_request(service, remote, number)
            case WindowChanged(number) => window_changed(remote)
            case ChannelData(number) => channel_input(remote, number)
            case ChannelEof(number) => {}
            case ChannelClosed(number) => {
                remote.has_channel = false
                end_session(remote)
            }
            case Ended => remote.closing = true
            case _ => {}
        }
    }
    while true
    return any
}

/** A password offered: the account service opens the home with it, or doesn't. */
log_in_with_password :: fn(service: ptr[mut Service], remote: ptr[mut Remote]) {
    name :: ssh.user_of(&remote.conn)
    offered :: ssh.offered_password_of(&remote.conn)
    password : u8[ssh.PASSWORD_BYTES]
    count :: if offered.count <= password.count { offered.count } else { password.count }
    for i in cast[usize](0)..<count {
        if i < offered.count && i < password.count {
            password[i] = compiler.declassify(cast[u8](offered[i]))
        }
    }
    out := os.Outgoing.{}
    request :: os.begin[accounts.Request](&out)
    request^ = .OpenHome(accounts.Credentials.{name = os.append(&out, name), password = os.append(&out, password[0..<count])})
    for &byte in password {
        byte^ = 0
    }
    into := os.Incoming.{}
    allowed :: ask_accounts(service, &out, &into) && opened_home(service, remote, &into, "a password")
    for i in 0..<out.words.count {
        out.words[i] = 0
    }
    ssh.answer_authentication(&remote.conn, allowed)
}

/**
 * A key offered: a query's answered yes, so the client signs; a signed one, whose signature std/ssh has checked, opens
 * the home if it's the account's and its password's unlocked it since the boot.
 */
log_in_with_key :: fn(service: ptr[mut Service], remote: ptr[mut Remote], signed: bool) {
    if !signed {
        ssh.answer_authentication(&remote.conn, true)
        return void
    }
    out := os.Outgoing.{}
    request :: os.begin[accounts.Request](&out)
    request^ = .OpenHomeByKey(accounts.KeyChange.{name = os.append(&out, ssh.user_of(&remote.conn)),
        key = os.append(&out, ssh.blob_of(ssh.offered_key_of(&remote.conn)))})
    into := os.Incoming.{}
    allowed :: ask_accounts(service, &out, &into) && opened_home(service, remote, &into, "a key")
    ssh.answer_authentication(&remote.conn, allowed)
}

/** Take the account service's answer to a login: true, the home kept, for OpenedHome. */
opened_home :: fn(service: ptr[mut Service], remote: ptr[mut Remote], into: ptr[mut os.Incoming], how: string) -> bool {
    name :: ssh.user_of(&remote.conn)
    match os.message_of[accounts.Response](into)^ {
        case OpenedHome(root) => {
            if remote.home != NONE {
                _ = slop_os.handle_close(cast[slop_os.Handle](remote.home))
            }
            remote.home = root.end
            remote.authenticated = true
            log_line.write(service.log, "ssh_service: % logged in with %", text_of(name), how)
            return true
        }
        case HomeLocked => log_line.write(service.log, "ssh_service: %'s home is locked until a password login", text_of(name))
        case RateLimited(wait) => log_line.write(service.log, "ssh_service: too many tries for %", text_of(name))
        case _ => log_line.write(service.log, "ssh_service: % refused", how)
    }
    return false
}

/** Ask the account service one thing, on a connection dialed for it, and wait for its answer. */
ask_accounts :: fn(service: ptr[mut Service], out: ptr[mut os.Outgoing], into: ptr[mut os.Incoming]) -> bool {
    budget :: slop_os.startup_block().budget
    port :: os.port_for(budget, service.accounts_dialing) or_return false
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    connection :: connector.dial[accounts.Accounts](service.accounts_dialing, port) or_return false
    defer slop_os.handle_close(cast[slop_os.Handle](connection.end))
    answers :: os.port_for(budget, connection.end) or_return false
    defer slop_os.handle_close(cast[slop_os.Handle](answers))
    if accounts.send_request(connection.end, answers, out) != null {
        return false
    }
    match accounts.receive_response(connection.end, answers, into, true) {
        case Received => return true
        case _ => return false
    }
}

/** Close a connection: its session ended, its home and channels closed. */
close_remote :: fn(service: ptr[mut Service], remote: ptr[mut Remote]) {
    stop_session(service, remote)
    end_session(remote)
    if remote.home != NONE {
        _ = slop_os.handle_close(cast[slop_os.Handle](remote.home))
        remote.home = NONE
    }
    net.close(&remote.tcp)
    log_line.write(service.log, "ssh_service: a connection closed")
}

/** Whether two addresses are the same. */
same_address :: fn(a: net_address.Address, b: net_address.Address) -> bool {
    return a.family == b.family && ssh.same(a.bytes[0..<16], b.bytes[0..<16])
}

/** Bytes as text, for the log. */
text_of :: fn(bytes: u8[]) -> string {
    return if bytes.count > 0 { string_of(&bytes[0], bytes.count) } else { "" }
}
