/*
 * Elevation in the GUI's trusted layer (decisions/0193, 16e; 0158, 0182, 0185, 0191), as the console's elevation screen
 * does it: what a GUI session's program asks its powerbox for beyond the user's own say.
 *
 * - The user's keys: adding one or removing one is confirmed, Allow or Refuse, the key's fingerprint shown, and the
 *   account service does it for the session's user; a list's answered at once, without asking.
 * - A shutdown, a restart, a trace, the system's log, or another user's program debugged: the administrator's name and
 *   password, always, checked by the account service (CheckAdministrator); then it's done, through the greeter's power
 *   connection for a shutdown, a restart, a trace connection or an events connection.
 * - An account: the administrator's name and password, and the new account's name and password, twice; the account
 *   service makes it on the administrator's say (CreateBy), and its recovery code's shown once, before the program's
 *   answered with its name.
 *
 * What's typed never reaches the program: the passwords are wiped once they're sent, and everything else once the ask
 * is answered.
 */

package greeter

import runtime from "base:runtime"
import os from "std:os"
import slop_os from "std:os/slop_os"
import text_buffer from "std:text_buffer"
import time from "std:time"
import ui from "std:ui"
import account_records from "../../account_records"
import gui_kit from "../../gui_kit"
import accounts from "../../protocols/accounts"
import events from "../../protocols/events"
import power as power_protocol from "../../protocols/power"
import prompt from "../../protocols/prompt"
import trace from "../../protocols/trace"

/** What's to be asked of the account service once the prompt window's said so, the ask's next frame. */
Pending :: enum {
    None,
    /** The administrator's name and password checked (CheckAdministrator). */
    Check,
    /** The account made on the administrator's say (CreateBy). */
    Create,
}

/**
 * Tell whether a kind is one this file's frame takes, rather than the chooser's or Allow and Refuse alone.
 *
 * @param kind What's asked for.
 * @return True for the user's keys changed, the administrator's kinds, and an account.
 */
is_elevation :: fn(kind : prompt.Kind) -> bool {
    return is_keys(kind) || is_administrators(kind) || kind == .Account
}

/** Tell whether a kind changes the session's user's keys: AddKey or RemoveKey. */
is_keys :: fn(kind : prompt.Kind) -> bool {
    return kind == .AddKey || kind == .RemoveKey
}

/** Tell whether a kind needs the administrator's name and password, nothing more. */
is_administrators :: fn(kind : prompt.Kind) -> bool {
    return kind == .ShutDown || kind == .Restart || kind == .Trace || kind == .SystemLog || kind == .DebugOther
}

/**
 * A frame of the prompt window for an elevation: who asks and for what; Allow for a key, or the administrator's fields
 * and an account's; what it last said; Refuse, which Escape does too. Once an account's made, its recovery code and
 * Done instead.
 *
 * What the last frame said it would ask the account service, it asks first, waiting for the answer: the frame that said
 * "Checking." is shown meanwhile.
 *
 * @param greeter The greeter, its prompt window made and an elevation asked.
 */
elevation_frame :: fn(greeter : ptr[mut Greeter]) {
    window :: greeter.prompt_window or_return void
    asking :: &greeter.asking
    pending :: asking.pending
    if pending != .None {
        asking.pending = .None
        if pending == .Check {
            check_administrator(greeter)
        }
        else {
            make_account(greeter)
        }
        if !greeter.asking.active {
            return void
        }
    }
    // Just shown: what came meanwhile was meant for something else
    if !asking.taking {
        gui_kit.drop_input(window)
    }
    u :: gui_kit.begin(window)
    escaped :: ui.key_pressed(u, .Escape)
    _ = ui.open(u, "body", ui.Box.{width = ui.grow(), height = ui.grow(), padding_x = 16, padding_y = 14, gap = 8})
    _ = gui_kit.label_of(u, string.[text(&asking.requester), " asks for ", what_of(asking)], ui.TextStyle.{size = 17})
    if asking.purpose.count > 0 {
        _ = gui_kit.label_of(u, string.["“", text(&asking.purpose), "”"], ui.TextStyle.{size = 14})
    }
    if asking.code.count > 0 {
        _ = gui_kit.label_of(
            u,
            string.["The account is made. Its recovery code, shown this once:"],
            ui.TextStyle.{size = 14}
        )
        _ = gui_kit.label_of(u, string.[text(&asking.code)], ui.TextStyle.{size = 18})
        _ = gui_kit.label_of(
            u,
            string.[
                "Give it to the account's owner, to keep apart from this computer: it opens the account if the password is lost."
            ],
            ui.TextStyle.{size = 13}
        )
        done :: ui.button(u, "Done")
        ui.close(u)
        _ = gui_kit.finish(window)
        if done {
            answer_made(greeter)
        }
        return void
    }
    go := false
    if is_keys(asking.kind) {
        storage : u8[200]
        line := text_buffer.make(storage)
        if asking.kind == .AddKey {
            text_buffer.append(&line, "The key: ")
            describe_key(ui.contents(&asking.key_line), &line)
            _ = gui_kit.label_of(u, string.[text_buffer.as_string(&line)], ui.TextStyle.{size = 14})
            _ = gui_kit.label_of(
                u,
                string.["Whoever has its private key could log in as you over SSH."],
                ui.TextStyle.{size = 13}
            )
        }
        else {
            _ = gui_kit.label_of(u, string.["The key: ", text(&asking.typed)], ui.TextStyle.{size = 14})
        }
        go = ui.button(u, "Allow")
    }
    else {
        _ = gui_kit.label_of(u, string.["The administrator's name and password allow it."], ui.TextStyle.{size = 13})
        _ = ui.text_field(u, "Administrator", &asking.admin)
        _ = ui.text_field(u, "Their password", &asking.admin_password, secret = true)
        if asking.kind == .Account {
            _ = ui.text_field(u, "New account's name", &asking.new_name)
            _ = ui.text_field(u, "Its password", &asking.new_password, secret = true)
            _ = ui.text_field(u, "Its password again", &asking.again, secret = true)
        }
        go = ui.button(u, if asking.kind == .Account { "Make the account" } else { "Allow" })
    }
    if asking.message.count > 0 {
        _ = gui_kit.label_of(u, string.[text(&asking.message)], ui.TextStyle.{size = 13})
    }
    refused :: ui.button(u, "Refuse")
    ui.close(u)
    submitted := false
    for event in gui_kit.finish(window) {
        submitted = submitted || event.kind == .Submitted
    }
    if is_keys(asking.kind) && go {
        respond_simply(greeter, if change_key(greeter) { prompt.Response.Allowed } else { prompt.Response.Refused })
    }
    else if !is_keys(asking.kind) && (go || submitted) {
        go_on(greeter)
    }
    else if refused || escaped {
        answer(greeter, null, false)
    }
}

/**
 * The administrator's fields, and an account's, submitted: once they're all typed, and an account's password typed the
 * same twice, the next frame says it's checking, and the one after asks the account service.
 *
 * @param greeter The greeter, an administrator's kind or an account asked; what's missing is said instead.
 */
go_on :: fn(greeter : ptr[mut Greeter]) {
    asking :: &greeter.asking
    window :: greeter.prompt_window or_return void
    window.due = true
    if asking.admin.count == 0 || asking.admin_password.count == 0 {
        say_asked(asking, "Type the administrator's name and password.")
        return void
    }
    if asking.kind == .Account {
        if asking.new_name.count == 0 || asking.new_password.count == 0 {
            say_asked(asking, "Type the new account's name and password.")
            return void
        }
        if !same_bytes(ui.contents(&asking.new_password), ui.contents(&asking.again)) {
            say_asked(asking, "The passwords aren't the same. Type them again.")
            wipe(&asking.new_password)
            wipe(&asking.again)
            forget_fields(window)
            return void
        }
        say_asked(asking, "Making the account. This takes a few seconds.")
        asking.pending = .Create
        return void
    }
    say_asked(asking, "Checking.")
    asking.pending = .Check
}

/**
 * Ask the account service whether the administrator's name and password are right (CheckAdministrator), and wait: if
 * they are, it's done as allowed_by_administrator says; otherwise what's wrong is said, the password to type again.
 *
 * @param greeter The greeter, an administrator's kind asked, both fields typed; the password's wiped, what was sent
 *     too.
 */
check_administrator :: fn(greeter : ptr[mut Greeter]) {
    asking :: &greeter.asking
    out := os.Outgoing.{}
    request :: os.begin[accounts.Request](&out)
    request^ = .CheckAdministrator(
        accounts.Credentials.{
            name = os.append(&out, ui.contents(&asking.admin)),
            password = os.append(&out, ui.contents(&asking.admin_password)),
        }
    )
    into := os.Incoming.{}
    asked :: ask_accounts(greeter, &out, &into)
    wipe(&asking.admin_password)
    match greeter.prompt_window {
        case Some(window) => forget_fields(window)
        case None => {}
    }
    if !asked {
        say_asked(asking, "The account service couldn't be asked.")
        return void
    }
    match os.message_of[accounts.Response](&into)^ {
        case Done => allowed_by_administrator(greeter)
        case WrongCredentials => {
            runtime.log_info("not the administrator's name and password")
            say_asked(asking, "That's not the administrator's name and password. Type them again.")
        }
        case RateLimited(wait) => say_wait(asking, wait)
        case _ => say_asked(asking, "The administrator couldn't be checked.")
    }
}

/**
 * The administrator's allowed it: answer the program, and do it. A shutdown or a restart is answered Allowed, then
 * asked of the supervisor; a trace or the system's log answered with a connection from it, or Refused if it gives none;
 * another user's program debugged, Allowed.
 *
 * @param greeter The greeter, an administrator's kind asked and allowed; the ask's let go of.
 */
allowed_by_administrator :: fn(greeter : ptr[mut Greeter]) {
    kind :: greeter.asking.kind
    runtime.log_info("the administrator allowed %", what_of(&greeter.asking))
    out := os.Outgoing.{}
    response :: os.begin[prompt.Response](&out)
    response^ = .Refused
    if kind == .Trace {
        match trace_connection(greeter) {
            case Some(connection) => response^ = .TraceGranted(connection)
            case None => runtime.log_info("no trace connection")
        }
    }
    else if kind == .SystemLog {
        match events_connection(greeter) {
            case Some(connection) => response^ = .LogGranted(connection)
            case None => runtime.log_info("no events connection")
        }
    }
    else {
        response^ = .Allowed
    }
    respond(greeter, &out)
    if kind == .ShutDown || kind == .Restart {
        restart :: kind == .Restart
        into := os.Incoming.{}
        request :: if restart { power_protocol.Request.Restart } else { power_protocol.Request.ShutDown }
        if ask_power(greeter, request, &into, false) {
            runtime.log_info(if restart { "restarting" } else { "shutting down" })
        }
        else {
            runtime.log_info("the supervisor couldn't be asked to %", if restart { "restart" } else { "shut down" })
        }
    }
}

/**
 * Ask the account service to make the account on the administrator's say (CreateBy), and wait: once it's made its
 * recovery code is shown; otherwise what's wrong is said.
 *
 * @param greeter The greeter, an account asked, every field typed and the password the same twice; the passwords are
 *     wiped, what was sent too.
 */
make_account :: fn(greeter : ptr[mut Greeter]) {
    asking :: &greeter.asking
    now := cast[u64](0)
    match time.now() {
        case Ok(instant) => now = cast[u64](instant.seconds) * 1_000_000_000 + cast[u64](instant.nanos)
        case Error(_) => {}
    }
    out := os.Outgoing.{}
    request :: os.begin[accounts.Request](&out)
    request^ = .CreateBy(
        accounts.Elevated.{
            administrator = accounts.Credentials.{
                name = os.append(&out, ui.contents(&asking.admin)),
                password = os.append(&out, ui.contents(&asking.admin_password)),
            },
            creation = accounts.Creation.{
                name = os.append(&out, ui.contents(&asking.new_name)),
                password = os.append(&out, ui.contents(&asking.new_password)),
                now = now,
            },
        }
    )
    into := os.Incoming.{}
    asked :: ask_accounts(greeter, &out, &into)
    wipe(&asking.admin_password)
    wipe(&asking.new_password)
    wipe(&asking.again)
    match greeter.prompt_window {
        case Some(window) => forget_fields(window)
        case None => {}
    }
    if !asked {
        say_asked(asking, "The account service couldn't be asked.")
        return void
    }
    match os.message_of[accounts.Response](&into)^ {
        case Created(shown) => {
            add_bytes(&asking.code, shown.text[0..<shown.text.count])
            say_asked(asking, "")
            runtime.log_info("made the account %", text(&asking.new_name))
        }
        case PasswordRefused(
            problem
        ) => say_asked(
            asking,
            if problem == 1 {
                "A password needs at least 8 characters."
            }
            else if problem == 2 {
                "That password is too long: 256 bytes at most."
            }
            else if problem == 3 {
                "That password is one of the most common ones. Choose another."
            }
            else if problem == 4 {
                "A password can't be the account's name."
            }
            else {
                "That password can't be used. Choose another."
            }
        )
        case NameRefused => say_asked(
            asking,
            "That name can't be an account's: a lowercase letter, then letters, digits, - or _."
        )
        case AlreadyExists => say_asked(asking, "There's an account of that name already.")
        case WrongCredentials => say_asked(asking, "That's not the administrator's name and password. Type them again.")
        case RateLimited(wait) => say_wait(asking, wait)
        case Refused => answer(greeter, null, false)
        case _ => say_asked(asking, "The account couldn't be made.")
    }
}

/** The account's made and its code shown: answer the program with its name (AccountMade), and let go of the ask. */
answer_made :: fn(greeter : ptr[mut Greeter]) {
    out := os.Outgoing.{}
    response :: os.begin[prompt.Response](&out)
    response^ = .AccountMade(os.append(&out, ui.contents(&greeter.asking.new_name)))
    runtime.log_info("answered % with the account %", text(&greeter.asking.requester), text(&greeter.asking.new_name))
    respond(greeter, &out)
}

/**
 * The user's allowed a key added or removed: have the account service do it for the session's user, and wait.
 *
 * @param greeter The greeter, AddKey or RemoveKey asked in a session.
 * @return True once it's done; false if the account service refused it or couldn't be asked, which is logged.
 */
change_key :: fn(greeter : ptr[mut Greeter]) -> bool {
    asking :: &greeter.asking
    adding :: asking.kind == .AddKey
    key :: if adding { ui.contents(&asking.key_line) } else { ui.contents(&asking.typed) }
    if greeter.name.count == 0 || key.count == 0 {
        runtime.log_info("keys: no key, or no user")
        return false
    }
    out := os.Outgoing.{}
    request :: os.begin[accounts.Request](&out)
    change :: accounts.KeyChange.{name = os.append(&out, ui.contents(&greeter.name)), key = os.append(&out, key)}
    request^ = if adding { accounts.Request.AddKey(change) } else { accounts.Request.RemoveKey(change) }
    into := os.Incoming.{}
    if !ask_accounts(greeter, &out, &into) {
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
 * Answer ListKeys at once, without asking: the session's user's keys, or Refused without a user or the account
 * service; then let go of the ask.
 *
 * @param greeter The greeter, ListKeys asked.
 */
list_keys :: fn(greeter : ptr[mut Greeter]) {
    out := os.Outgoing.{}
    reply :: os.begin[prompt.Response](&out)
    reply^ = .Refused
    into := os.Incoming.{}
    if greeter.name.count > 0 {
        asking := os.Outgoing.{}
        request :: os.begin[accounts.Request](&asking)
        request^ = .ListKeys(os.append(&asking, ui.contents(&greeter.name)))
        if ask_accounts(greeter, &asking, &into) {
            match os.message_of[accounts.Response](&into)^ {
                case KeysListed(listed) => reply^ = .KeysListed(os.append(&out, os.items(&into, listed)))
                case _ => {}
            }
        }
    }
    _ = prompt.send_response(greeter.prompts, greeter.prompts_port, &out)
    drop_asking(greeter)
}

/**
 * Send the account service one request on the greeter's connection to it, and wait for the answer.
 *
 * @param greeter The greeter.
 * @param out The request; its words are zeroed once it's sent, or failed to be, as they may hold a password.
 * @param into Where the answer's received.
 * @return True if it's answered, the answer in into; false if it couldn't be sent or the connection failed.
 */
ask_accounts :: fn(greeter : ptr[mut Greeter], out : ptr[mut os.Outgoing], into : ptr[mut os.Incoming]) -> bool {
    sent :: accounts.send_request(greeter.accounts_end, greeter.accounts_port, out) is_none
    for i in 0..<out.words.count {
        out.words[i] = 0
    }
    if !sent {
        return false
    }
    match accounts.receive_response(greeter.accounts_end, greeter.accounts_port, into, true) {
        case Received => return true
        case _ => return false
    }
}

/**
 * Send the supervisor one request on the greeter's power connection, and wait for its answer if asked to.
 *
 * @param greeter The greeter, whose power connection's asked.
 * @param request The request.
 * @param into Where the answer's received, when wait's set.
 * @param wait Whether to wait for the answer: a shutdown's or a restart's isn't.
 * @return True once it's sent and, when waited for, answered; false without a power connection, or if it failed.
 */
ask_power :: fn(
    greeter : ptr[mut Greeter],
    request : power_protocol.Request,
    into : ptr[mut os.Incoming],
    wait : bool
) -> bool {
    connection :: greeter.power or_return false
    port :: os.port_for(slop_os.startup_block().budget, connection.end) or_return false
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    out := os.Outgoing.{}
    os.begin[power_protocol.Request](&out)^ = request
    if power_protocol.send_request(connection.end, port, &out) is_some {
        return false
    }
    if !wait {
        return true
    }
    match power_protocol.receive_response(connection.end, port, into, true) {
        case Received => return true
        case _ => return false
    }
}

/** A trace connection from the supervisor (power's TraceConnection), for the program; null if it gives none. */
trace_connection :: fn(greeter : ptr[mut Greeter]) -> os.Channel[trace.Trace]? {
    into := os.Incoming.{}
    if !ask_power(greeter, .TraceConnection, &into, true) {
        return null
    }
    return match os.message_of[power_protocol.Response](&into)^ {
        case TraceConnection(given) => given
        case _ => null
    }
}

/** An events connection from the supervisor (power's EventsConnection), for the program; null if it gives none. */
events_connection :: fn(greeter : ptr[mut Greeter]) -> os.Channel[events.Events]? {
    into := os.Incoming.{}
    if !ask_power(greeter, .EventsConnection, &into, true) {
        return null
    }
    return match os.message_of[power_protocol.Response](&into)^ {
        case EventsConnection(given) => given
        case _ => null
    }
}

/** Send the program an answer that's only a word, such as Allowed, and let go of the ask. */
respond_simply :: fn(greeter : ptr[mut Greeter], word : prompt.Response) {
    out := os.Outgoing.{}
    os.begin[prompt.Response](&out)^ = word
    respond(greeter, &out)
}

/** Send the program its answer, and let go of the ask. */
respond :: fn(greeter : ptr[mut Greeter], out : ptr[mut os.Outgoing]) {
    _ = prompt.send_response(greeter.prompts, greeter.prompts_port, out)
    drop_asking(greeter)
}

/** Say something in the prompt window, under its fields. */
say_asked :: fn(asking : ptr[mut Asking], said : string) {
    runtime.array_reset(&asking.message)
    add_bytes(&asking.message, string_bytes(said))
}

/** Say how long until the account service hears the administrator's password again. */
say_wait :: fn(asking : ptr[mut Asking], wait : u64) {
    storage : u8[96]
    said := text_buffer.make(storage)
    text_buffer.append(&said, "Too many tries: wait ")
    text_buffer.append_unsigned(&said, (wait + 999_999_999) / 1_000_000_000)
    text_buffer.append(&said, " seconds, then type the password again.")
    say_asked(asking, text_buffer.as_string(&said))
}

/** Describe a key's line: its fingerprint, and its comment if it has one; or that it isn't a key. */
describe_key :: fn(line : u8[], into : ptr[mut text_buffer.TextBuffer]) {
    match account_records.key_fingerprint(line) {
        case Some(printed) => text_buffer.append(into, string_of(&printed[0], printed.count))
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

/**
 * Forget the prompt window's focus and editing state, so what a password field kept is wiped and nothing focused takes
 * the next Enter.
 */
forget_fields :: fn(window : ptr[mut gui_kit.Window]) {
    ui.set_focus(&window.ui, 0)
    ui.stop_editing(&window.ui)
}

/** Zero an array's bytes and empty it. */
wipe :: fn(bytes : ptr[mut u8[..]]) {
    for &byte in bytes^ {
        byte^ = 0
    }
    runtime.array_free(bytes)
}

/** Tell whether two byte slices hold the same bytes. */
same_bytes :: fn(a : u8[], b : u8[]) -> bool {
    if a.count != b.count {
        return false
    }
    for byte, i in a {
        if i >= b.count || b[i] != byte {
            return false
        }
    }
    return true
}
