/**
 * An account's public keys, which log in as it over SSH (decisions/0191, 14c), asked for by a session's program through
 * its powerbox. A list is answered at once, without asking; adding a key or removing one is confirmed on the elevation
 * screen, the key's fingerprint and comment shown, and the account service does it for the view's user, on a
 * connection of its own whose answer is waited for, so no other screen's answers are taken for it.
 */
package terminal_service

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import text_buffer from "std"
import account_records from "../../account_records"
import accounts from "../../protocols/accounts"
import connector from "../../protocols/connector"
import prompt from "../../protocols/prompt"

/**
 * Tell whether a request's kind changes the user's keys, which the elevation screen confirms.
 *
 * @param kind The kind.
 * @return True for AddKey and RemoveKey.
 */
is_keys :: fn(kind: prompt.Kind) -> bool {
    return kind == .AddKey || kind == .RemoveKey
}

/**
 * Ask the account service one thing on a connection of its own, dialed for it and closed after, and wait for its answer.
 *
 * @param service The service, whose connector to the account service is dialed.
 * @param out The request.
 * @param into Where the answer's received.
 * @return True if it's answered, the answer in into; false without the account service, or if it couldn't be asked.
 */
ask_accounts_now :: fn(service: ptr[mut Service], out: ptr[mut os.Outgoing], into: ptr[mut os.Incoming]) -> bool {
    if service.accounts_connector == NONE {
        return false
    }
    budget :: slop_os.startup_block().budget
    port :: os.port_for(budget, service.accounts_connector) or_return false
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    connection :: connector.dial[accounts.Accounts](service.accounts_connector, port) or_return false
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

/**
 * Answer a view's request to list its user's keys at once, with them, or Refused without a user or the account
 * service; the request's home is closed.
 *
 * @param service The service.
 * @param index The view whose prompt connection asked.
 * @param home The request's home, which is closed here.
 */
list_keys :: fn(service: ptr[mut Service], index: usize, home: slop_os.Channel) {
    if home != NONE {
        _ = slop_os.handle_close(cast[slop_os.Handle](home))
    }
    if index >= service.views.count {
        return void
    }
    shown :: &service.views[index]
    out := os.Outgoing.{}
    reply :: os.begin[prompt.Response](&out)
    reply^ = .Refused
    into := os.Incoming.{}
    if shown.logged_in && shown.user_count > 0 {
        asking := os.Outgoing.{}
        request :: os.begin[accounts.Request](&asking)
        request^ = .ListKeys(os.append(&asking, first_of(shown.user[0..<shown.user.count], shown.user_count)))
        if ask_accounts_now(service, &asking, &into) {
            match os.message_of[accounts.Response](&into)^ {
                case KeysListed(listed) => reply^ = .KeysListed(os.append(&out, os.items(&into, listed)))
                case _ => {}
            }
        }
    }
    if shown.prompt_end != NONE {
        _ = prompt.send_response(shown.prompt_end, service.port, &out)
    }
}

/**
 * The user's allowed a key added or removed: have the account service do it for the view's user.
 *
 * @param service The service, its elevation screen up for the active view's AddKey or RemoveKey.
 * @return True once it's done; false if the account service refused it or isn't there, which is logged.
 */
change_key :: fn(service: ptr[mut Service]) -> bool {
    shown :: view(service)
    if !shown.logged_in || shown.user_count == 0 {
        return false
    }
    adding :: shown.ask.kind == .AddKey
    key :: if adding { first_of(shown.ask.key_line[0..<shown.ask.key_line.count], shown.ask.key_line_count) }
        else { first_of(shown.ask.suggested[0..<shown.ask.suggested.count], shown.ask.suggested_count) }
    out := os.Outgoing.{}
    request :: os.begin[accounts.Request](&out)
    change :: accounts.KeyChange.{name = os.append(&out, first_of(shown.user[0..<shown.user.count], shown.user_count)),
        key = os.append(&out, key)}
    request^ = if adding { accounts.Request.AddKey(change) } else { accounts.Request.RemoveKey(change) }
    into := os.Incoming.{}
    if !ask_accounts_now(service, &out, &into) {
        runtime.log_info("keys: the account service couldn't be asked")
        return false
    }
    match os.message_of[accounts.Response](&into)^ {
        case Done => {
            runtime.log_info("keys: % a key", if adding { "added" } else { "removed" })
            return true
        }
        case KeyRefused => runtime.log_info("keys: it isn't a key")
        case AlreadyExists => runtime.log_info("keys: the account has the key already")
        case Refused => runtime.log_info("keys: the account has as many keys as it may")
        case NoSuchKey => runtime.log_info("keys: the account has no key of that fingerprint")
        case _ => runtime.log_info("keys: the account service couldn't do it")
    }
    return false
}

/**
 * Describe a key line for the user: its fingerprint, and its comment if it has one.
 *
 * @param line The key's line.
 * @param into Where the description's appended.
 */
describe_key :: fn(line: u8[], into: ptr[mut text_buffer.TextBuffer]) {
    match account_records.key_fingerprint(line) {
        case Some(printed) => text_buffer.append(into, string_of(&printed[0], 50))
        case None => {
            text_buffer.append(into, "a line that isn't a key")
            return void
        }
    }
    comment : u8[account_records.COMMENT_BYTES]
    count :: account_records.comment_of(line, comment[0..<comment.count])
    if count > 0 && count <= comment.count {
        text_buffer.append(into, " (")
        text_buffer.append(into, string_of(&comment[0], count))
        text_buffer.append(into, ")")
    }
}
