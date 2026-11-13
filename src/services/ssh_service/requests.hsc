/**
 * What the SSH service asks the account service and the session manager, without waiting (decisions/0191): each request
 * is sent on the service's one connection to it, which is bound to the service's port, and what it was for is queued;
 * answers come in order, and each is taken, as it comes, by what's first in the queue. A connection that's gone by then
 * is known by its serial, which no other connection has, and what's answered for it is undone: a home closed, a
 * session ended. So one connection's Argon2id or session start never holds up another's.
 */
package ssh_service

import compiler from "base"
import os from "std"
import ssh from "std"
import slop_os from "std/os"
import log_line from "../../log_line"
import accounts from "../../protocols/accounts"
import connector from "../../protocols/connector"
import session from "../../protocols/session"

/** The account service's connection's key on the service's port, and the session manager's. */
ACCOUNTS_KEY : u64 : 2
SESSIONS_KEY : u64 : 3
/** The most requests waiting for answers on one connection. */
QUEUED :: 32

/** What a request was for. */
Asked :: enum {
    /** Remote, marking the connection as a remote front end's. */
    Marking,
    /** OpenHome, for a password. */
    Password,
    /** OpenHomeByKey, for a signed key. */
    Key,
    /** Start, for a session. */
    Start,
    /** EndSession, whose answer isn't needed. */
    End,
}

/** A request waiting for its answer: what for, and whose. */
Waiting :: struct {
    asked : Asked,
    /** The connection's place, and its serial, which tells whether it's still the one that asked. */
    slot : usize,
    serial : u64,
}

/** Requests waiting for their answers, in the order they were sent. */
Queue :: struct {
    items : Waiting[QUEUED],
    first : usize,
    count : usize,
}

/** Add a request to a queue; false if it's full. */
push :: fn(queue: ptr[mut Queue], item: Waiting) -> bool {
    if queue.count >= QUEUED {
        return false
    }
    queue.items[(queue.first + queue.count) % QUEUED] = item
    queue.count += 1
    return true
}

/** Take the oldest request from a queue; null if there's none. */
pop :: fn(queue: ptr[mut Queue]) -> Waiting? {
    if queue.count == 0 {
        return null
    }
    item :: queue.items[queue.first % QUEUED]
    queue.first = (queue.first + 1) % QUEUED
    queue.count -= 1
    return item
}

/** The connection that asked, if it's still there: the one in its place with its serial. */
asker :: fn(service: ptr[mut Service], item: Waiting) -> ptr[mut Remote]? {
    if item.slot >= service.remotes.count {
        return null
    }
    remote :: service.remotes[item.slot].remote or_return null
    return if remote.serial == item.serial { remote } else { null }
}

/**
 * Send a request to the account service, dialed the first time and marked Remote, and queue what it's for.
 *
 * @return True once it's sent; false if the account service couldn't be reached, or too much waits already.
 */
send_accounts :: fn(service: ptr[mut Service], out: ptr[mut os.Outgoing], item: Waiting) -> bool {
    if service.accounts_end == NONE && !dial_accounts(service) {
        return false
    }
    if service.accounts_queue.count >= QUEUED {
        return false
    }
    if accounts.send_request(service.accounts_end, service.accounts_answers, out) != null {
        accounts_gone(service)
        return false
    }
    return push(&service.accounts_queue, item)
}

/** Dial the account service, bind its connection to the service's port, and mark it Remote. */
dial_accounts :: fn(service: ptr[mut Service]) -> bool {
    budget :: slop_os.startup_block().budget
    port :: os.port_for(budget, service.accounts_dialing) or_return false
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    connection :: connector.dial[accounts.Accounts](service.accounts_dialing, port) or_return false
    service.accounts_answers = os.port_for(budget, connection.end) or_else cast[slop_os.Port](slop_os.NO_HANDLE)
    if cast[slop_os.Handle](service.accounts_answers) == slop_os.NO_HANDLE {
        _ = slop_os.handle_close(cast[slop_os.Handle](connection.end))
        return false
    }
    signals :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    if slop_os.port_bind(service.port, cast[slop_os.Handle](connection.end), signals, ACCOUNTS_KEY, .Persistent) is_error {
        _ = slop_os.handle_close(cast[slop_os.Handle](service.accounts_answers))
        _ = slop_os.handle_close(cast[slop_os.Handle](connection.end))
        return false
    }
    service.accounts_end = connection.end
    // Its wrong tries count apart from the console's
    marking := os.Outgoing.{}
    os.begin[accounts.Request](&marking)^ = .Remote
    if accounts.send_request(service.accounts_end, service.accounts_answers, &marking) != null {
        accounts_gone(service)
        return false
    }
    _ = push(&service.accounts_queue, Waiting.{asked = .Marking})
    return true
}

/** The account service's connection failed: closed, and every login waiting on it refused. */
accounts_gone :: fn(service: ptr[mut Service]) {
    if service.accounts_end != NONE {
        _ = slop_os.port_unbind(service.port, ACCOUNTS_KEY)
        _ = slop_os.handle_close(cast[slop_os.Handle](service.accounts_answers))
        _ = slop_os.handle_close(cast[slop_os.Handle](service.accounts_end))
        service.accounts_end = NONE
    }
    loop {
        item :: pop(&service.accounts_queue) or_break
        match asker(service, item) {
            case Some(remote) => {
                if item.asked == .Password || item.asked == .Key {
                    ssh.answer_authentication(&remote.conn, false)
                }
            }
            case None => {}
        }
    }
    while true
}

/** Take every answer the account service has given: each login it's for answered, if its connection's still there. */
take_accounts :: fn(service: ptr[mut Service]) {
    loop {
        if service.accounts_end == NONE {
            break
        }
        into := os.Incoming.{}
        match accounts.receive_response(service.accounts_end, service.accounts_answers, &into, false) {
            case Received => {}
            case Empty => break
            case _ => {
                accounts_gone(service)
                break
            }
        }
        item :: pop(&service.accounts_queue) or_continue
        match asker(service, item) {
            case Some(remote) => {
                if item.asked == .Password {
                    password_answered(service, remote, &into)
                }
                else if item.asked == .Key {
                    ssh.answer_authentication(&remote.conn, opened_home(service, remote, &into, "a key"))
                }
            }
            case None => {
                // Gone: a home opened for it is closed
                match os.message_of[accounts.Response](&into)^ {
                    case OpenedHome(root) => _ = slop_os.handle_close(cast[slop_os.Handle](root.end))
                    case _ => {}
                }
            }
        }
        // What the answer held wiped before the next
        for i in 0..<into.words.count {
            into.words[i] = 0
        }
    }
    while true
}

/**
 * Send a request to the session manager, and queue what it's for.
 *
 * @return True once it's sent.
 */
send_sessions :: fn(service: ptr[mut Service], out: ptr[mut os.Outgoing], item: Waiting) -> bool {
    if service.sessions_end == NONE || service.sessions_queue.count >= QUEUED {
        return false
    }
    if session.send_request(service.sessions_end, service.sessions_port, out) != null {
        return false
    }
    return push(&service.sessions_queue, item)
}

/** Take every answer the session manager has given: each session start finished, or undone if its connection's gone. */
take_sessions :: fn(service: ptr[mut Service]) {
    loop {
        if service.sessions_end == NONE {
            break
        }
        into := os.Incoming.{}
        match session.receive_response(service.sessions_end, service.sessions_port, &into, false) {
            case Received => {}
            case Empty => break
            case _ => {
                sessions_gone(service)
                break
            }
        }
        item :: pop(&service.sessions_queue) or_continue
        if item.asked != .Start {
            continue
        }
        started := false
        number := cast[u32](0)
        match os.message_of[session.Response](&into)^ {
            case Started(given) => {
                started = true
                number = given
            }
            case _ => {}
        }
        match asker(service, item) {
            case Some(remote) => {
                if started {
                    session_started(service, remote, number)
                }
                else {
                    start_failed(service, remote)
                }
            }
            case None => {
                // Gone: the session started for it is ended
                if started {
                    out := os.Outgoing.{}
                    os.begin[session.Request](&out)^ = .EndSession(number)
                    _ = send_sessions(service, &out, Waiting.{asked = .End})
                }
            }
        }
    }
    while true
}

/** The session manager's connection failed: closed, and every session start waiting on it refused. */
sessions_gone :: fn(service: ptr[mut Service]) {
    _ = slop_os.port_unbind(service.port, SESSIONS_KEY)
    _ = slop_os.handle_close(cast[slop_os.Handle](service.sessions_end))
    service.sessions_end = NONE
    log_line.write(service.log, "ssh_service: the session manager's gone")
    loop {
        item :: pop(&service.sessions_queue) or_break
        if item.asked == .Start {
            match asker(service, item) {
                case Some(remote) => start_failed(service, remote)
                case None => {}
            }
        }
    }
    while true
}
