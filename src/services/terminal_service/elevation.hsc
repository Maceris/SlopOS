/**
 * Elevation (decisions/0158), on the trusted path: a session's program asked its powerbox for another account, and the
 * secure attention key opened this screen for it. It asks for the administrator's name and password, always, even in
 * their own session, then the new account's name and password, twice, as first-boot setup does, and has the account
 * service make the account (CreateBy), which checks the administrator's. The recovery code's shown once; Enter after it
 * answers the powerbox with the account's name, and Escape before the account's asked for refuses. No password typed
 * here reaches the program.
 */
package terminal_service

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import text_buffer from "std"
import terminal from "std/os/slop_os"
import time from "std"
import accounts from "../../protocols/accounts"
import prompt from "../../protocols/prompt"
import power_protocol from "../../protocols/power"
import trace from "../../protocols/trace"
import events from "../../protocols/events"
import screen from "../../screen"

/** The status line's text while the elevation screen is up. */
STATUS_ELEVATING :: " SlopOS │ console │ asking the administrator"
/**
 * The rows of fields the elevation screen has: the administrator's name and password, then the new account's name, its
 * password and the password again.
 */
ELEVATION_FIELDS :: 5

/**
 * Open the elevation screen over the active view, for the account its powerbox's request asks for.
 *
 * The secure attention key's screen is left for it, and the first step asks for the administrator's name; the status
 * line says an account is being made. Every key goes to setup_key until the request is answered.
 *
 * @param service The service, whose active view has an Account request waiting (asking is true).
 */
enter_elevation :: fn(service: ptr[mut Service]) {
    service.attention = false
    service.elevating = true
    kind :: view(service).ask.kind
    runtime.log_info("elevation: % asks %", bytes_text(first_of(view(service).ask.requester[0..<view(service).ask.requester.count],
        view(service).ask.requester_count)), if kind == .ShutDown { "to shut down" } else if kind == .Restart { "to restart" }
        else if is_debug(kind) { "to debug a program" } else if kind == .Trace { "to trace the system" }
        else if kind == .SystemLog { "to read the system's log" } else if kind == .Network { "to reach the network" }
        else { "for an account" })
    say(service, "")
    // The user's own program needs only their say; anything else, the administrator's
    setup_step(service, if kind == .Debug || kind == .Network { SetupStep.Confirm } else { SetupStep.AdminName })
    update_status(service)
}

/**
 * Tell whether a request's kind is one the elevation screen takes, rather than the chooser.
 *
 * @param kind The kind.
 * @return True for an account, a shutdown and a restart.
 */
is_elevation :: fn(kind: prompt.Kind) -> bool {
    return kind == .Account || is_power(kind) || is_debug(kind) || kind == .Trace || kind == .SystemLog || kind == .Network
}

/**
 * Tell whether a request's kind is debugging a program (decisions/0185).
 *
 * @param kind The kind.
 * @return True for Debug and DebugOther.
 */
is_debug :: fn(kind: prompt.Kind) -> bool {
    return kind == .Debug || kind == .DebugOther
}

/**
 * Tell whether a request's kind needs only the administrator's name and password, nothing more: a shutdown, a restart,
 * or debugging another user's program.
 *
 * @param kind The kind.
 * @return True for those.
 */
is_administrators :: fn(kind: prompt.Kind) -> bool {
    return is_power(kind) || kind == .DebugOther || kind == .Trace || kind == .SystemLog
}

/**
 * Ask the supervisor for a connection to the events service (power's EventsConnection, decisions/0185), once the
 * administrator's allowed reading the system's log, waiting for its answer.
 *
 * @param service The service, whose power connection is asked.
 * @return The connection; null without a power connection, or if the supervisor refused.
 */
events_connection :: fn(service: ptr[mut Service]) -> os.Channel[events.Events]? {
    connection :: service.power or_return null
    port :: os.port_for(slop_os.startup_block().budget, connection.end) or_return null
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    out := os.Outgoing.{}
    os.begin[power_protocol.Request](&out)^ = .EventsConnection
    if power_protocol.send_request(connection.end, port, &out) is_some {
        return null
    }
    into := os.Incoming.{}
    match power_protocol.receive_response(connection.end, port, &into, true) {
        case Received => {}
        case _ => return null
    }
    return match os.message_of[power_protocol.Response](&into)^ {
        case EventsConnection(given) => given
        case _ => null
    }
}

/**
 * Ask the supervisor for a trace connection (power's TraceConnection, decisions/0185), once the administrator's allowed
 * a trace, waiting for its answer.
 *
 * @param service The service, whose power connection is asked.
 * @return The connection, for the program that asked; null without a power connection, or if the supervisor refused.
 */
trace_connection :: fn(service: ptr[mut Service]) -> os.Channel[trace.Trace]? {
    connection :: service.power or_return log_none("no power connection")
    port :: os.port_for(slop_os.startup_block().budget, connection.end) or_return log_none("no port")
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    out := os.Outgoing.{}
    os.begin[power_protocol.Request](&out)^ = .TraceConnection
    if power_protocol.send_request(connection.end, port, &out) is_some {
        return log_none("not sent")
    }
    into := os.Incoming.{}
    match power_protocol.receive_response(connection.end, port, &into, true) {
        case Received => {}
        case Failed(error) => return log_none(message_of_error(error))
        case _ => return log_none("no answer")
    }
    return match os.message_of[power_protocol.Response](&into)^ {
        case TraceConnection(given) => given
        case _ => log_none("the supervisor refused")
    }
}

/**
 * Tell whether a request's kind is shutting down or restarting (decisions/0182).
 *
 * @param kind The kind.
 * @return True for ShutDown and Restart.
 */
is_power :: fn(kind: prompt.Kind) -> bool {
    return kind == .ShutDown || kind == .Restart
}

/**
 * Ask the account service whether the administrator's name and password typed are right, for a shutdown or a restart
 * (CheckAdministrator), without waiting for its answer, which comes to take_accounts: Done allows it.
 *
 * Once it's sent, or failed to be, the message's words and the password are zeroed. Without the account service, or
 * if it can't be sent, it says so and asks for the administrator's name again.
 *
 * @param service The service, its elevation screen up for a shutdown or a restart, the administrator's password typed.
 */
check_administrator :: fn(service: ptr[mut Service]) {
    if service.accounts_end == NONE || service.admin_count > service.admin.count || service.admin_password_count > service.admin_password.count {
        say(service, "The account service isn't there.")
        setup_step(service, .AdminName)
        return void
    }
    out := os.Outgoing.{}
    request :: os.begin[accounts.Request](&out)
    request^ = .CheckAdministrator(accounts.Credentials.{name = os.append(&out, service.admin[0..<service.admin_count]),
        password = os.append(&out, service.admin_password[0..<service.admin_password_count])})
    sent :: accounts.send_request(service.accounts_end, service.port, &out) == null
    for i in 0..<out.words.count {
        out.words[i] = 0
    }
    wipe(service.admin_password[0..<service.admin_password.count])
    service.admin_password_count = 0
    if !sent {
        say(service, "The administrator couldn't be checked. Type the name and password again.")
        setup_step(service, .AdminName)
        return void
    }
    say(service, "Checking.")
    setup_step(service, .Making)
}

/**
 * The administrator's allowed a shutdown or a restart: answer the powerbox, close the elevation screen, and ask the
 * supervisor for it, as P and R on the secure attention key's screen do.
 *
 * @param service The service, its elevation screen up for a shutdown or a restart.
 */
power_allowed :: fn(service: ptr[mut Service]) {
    restart :: view(service).ask.kind == .Restart
    runtime.log_info("elevation: the administrator allowed a %", if restart { "restart" } else { "shutdown" })
    end_elevation(service, true)
    shut_down(service, restart)
}

/**
 * Answer the active view's account request, close the elevation screen, and draw the session again.
 *
 * The answer, AccountMade with the new account's name or Refused, is sent on the view's prompt connection if it still
 * has one, and not waited for; the request is dropped, its home closed. Everything typed, the names, both passwords and
 * the recovery code, is zeroed, setup goes back to Off, and the program's rows are drawn again from the screen model.
 *
 * @param service The service, its elevation screen up.
 * @param made Whether the account was made: true answers with its name, which is service.name; false refuses, as Escape
 *     or the account service's Refused does.
 */
end_elevation :: fn(service: ptr[mut Service], made: bool) {
    shown :: view(service)
    out := os.Outgoing.{}
    response :: os.begin[prompt.Response](&out)
    if made && shown.ask.kind == .SystemLog {
        match events_connection(service) {
            case Some(connection) => {
                response^ = .LogGranted(connection)
                runtime.log_info("elevation: the administrator allowed reading the system's log")
            }
            case None => response^ = .Refused
        }
    }
    else if made && shown.ask.kind == .Trace {
        // The administrator's allowed it: a trace connection from the supervisor, for the program that asked
        match trace_connection(service) {
            case Some(connection) => {
                response^ = .TraceGranted(connection)
                runtime.log_info("elevation: the administrator allowed a trace")
            }
            case None => response^ = .Refused
        }
    }
    else if made && (is_power(shown.ask.kind) || is_debug(shown.ask.kind) || shown.ask.kind == .Network) {
        response^ = .Allowed
    }
    else if made && service.name_count <= service.name.count {
        name :: name_bytes(service)
        response^ = .AccountMade(os.append(&out, name))
        runtime.log_info("elevation: made the account %", bytes_text(name))
    }
    else {
        response^ = .Refused
        runtime.log_info("elevation: refused")
    }
    if shown.prompt_end != NONE {
        _ = prompt.send_response(shown.prompt_end, service.port, &out)
    }
    drop_ask(shown)
    wipe(service.code[0..<service.code.count])
    wipe(service.admin[0..<service.admin.count])
    service.admin_count = 0
    wipe(service.admin_password[0..<service.admin_password.count])
    service.admin_password_count = 0
    wipe(service.field[0..<service.field.count])
    service.field_count = 0
    wipe(service.password[0..<service.password.count])
    service.password_count = 0
    wipe(service.name[0..<service.name.count])
    service.name_count = 0
    service.elevating = false
    service.setup = .Off
    update_status(service)
    screen.show_panel(&view(service).screen, false)
    redraw(service)
}

/**
 * Ask the account service to make the new account on the administrator's say (CreateBy), without waiting for its
 * answer.
 *
 * The request carries the administrator's name and password, the new account's name and password, and the time now in
 * nanoseconds since the epoch (0 if the clock can't be read). Once it's sent, or failed to be, the message's words and
 * both passwords are zeroed. The answer comes to take_accounts: Created, which shows the recovery code, or a refusal
 * that asks again.
 *
 * Without the account service, or if the request can't be sent, it says so and goes back to asking for the
 * administrator's name; otherwise it says the account's being made and goes to the Making step, where keys are ignored.
 *
 * @param service The service, its elevation screen up, the new account's password typed twice and matching.
 */
make_account_by :: fn(service: ptr[mut Service]) {
    if service.accounts_end == NONE || service.name_count > service.name.count || service.password_count > service.password.count
        || service.admin_count > service.admin.count || service.admin_password_count > service.admin_password.count {
        say(service, "The account service isn't there.")
        setup_step(service, .AdminName)
        return void
    }
    now := cast[u64](0)
    match time.now() {
        case Ok(instant) => now = cast[u64](instant.seconds) * 1000000000 + cast[u64](instant.nanos)
        case Error(error) => {}
    }
    out := os.Outgoing.{}
    request :: os.begin[accounts.Request](&out)
    request^ = .CreateBy(accounts.Elevated.{
        administrator = accounts.Credentials.{name = os.append(&out, service.admin[0..<service.admin_count]),
            password = os.append(&out, service.admin_password[0..<service.admin_password_count])},
        creation = accounts.Creation.{name = os.append(&out, service.name[0..<service.name_count]),
            password = os.append(&out, service.password[0..<service.password_count]), now = now}})
    sent :: accounts.send_request(service.accounts_end, service.port, &out) == null
    for i in 0..<out.words.count {
        out.words[i] = 0
    }
    wipe(service.password[0..<service.password.count])
    service.password_count = 0
    wipe(service.admin_password[0..<service.admin_password.count])
    service.admin_password_count = 0
    if !sent {
        say(service, "The account couldn't be asked for. Type the administrator's name and password again.")
        setup_step(service, .AdminName)
        return void
    }
    say(service, "Making the account. This takes a few seconds.")
    setup_step(service, .Making)
}

/**
 * Draw the elevation screen for a shutdown or a restart: who asks and why, the administrator's name and password, what
 * it last said, and the keys.
 *
 * @param service The service, its elevation screen up for one.
 * @param whole Whether the panel's shown and drawn whole, or only its fields' rows, as draw_elevation's is.
 * @param restart Whether it's a restart.
 */
draw_power_elevation :: fn(service: ptr[mut Service], whole: bool, restart: bool) {
    panel :: &view(service).screen.panel
    bold :: terminal.Style.{attributes = terminal.BOLD}
    plain :: terminal.Style.{}
    asked :: &view(service).ask
    debugging :: is_debug(asked.kind)
    screen.write_at(panel, 1, 2, if debugging { "Debug a program" } else if asked.kind == .Trace { "Trace the system" }
        else if asked.kind == .Network { "Reach the network" }
        else if asked.kind == .SystemLog { "Read the system's log" }
        else if restart { "Restart the system" } else { "Shut the system down" }, bold)
    storage : u8[200]
    line := text_buffer.make(storage)
    text_buffer.append(&line, bytes_text(first_of(asked.requester[0..<asked.requester.count], asked.requester_count)))
    if debugging {
        // The program to debug, which it can then read and change
        text_buffer.append(&line, " asks to debug ")
        text_buffer.append(&line, bytes_text(first_of(asked.suggested[0..<asked.suggested.count], asked.suggested_count)))
        text_buffer.append(&line, if asked.kind == .DebugOther { ", another user's program, " } else { ", " })
    }
    else if asked.kind == .Trace {
        // Every process's scheduling, other users' sessions' too
        text_buffer.append(&line, " asks to trace the whole system, every user's programs, ")
    }
    else if asked.kind == .SystemLog {
        text_buffer.append(&line, " asks to read the system's log, every service's records, ")
    }
    else if asked.kind == .Network {
        // What it would reach, beyond the session's own
        text_buffer.append(&line, " asks to reach ")
        text_buffer.append(&line, bytes_text(first_of(asked.suggested[0..<asked.suggested.count], asked.suggested_count)))
        text_buffer.append(&line, ", ")
    }
    else {
        text_buffer.append(&line, if restart { " asks to restart the system, " } else { " asks to shut the system down, " })
    }
    text_buffer.append(&line, bytes_text(first_of(asked.purpose[0..<asked.purpose.count], asked.purpose_count)))
    text_buffer.append(&line, ".")
    screen.write_at(panel, 3, 2, text_buffer.as_string(&line), plain)
    if asked.kind == .Debug || asked.kind == .Network {
        screen.write_at(panel, 4, 2, if asked.kind == .Debug { "It could read and change everything the program has. Enter allows it, Esc refuses." }
            else { "It could send what the program has there. Enter allows it, Esc refuses." }, plain)
        if whole {
            redraw(service)
        }
        else {
            redraw_rows(service, SETUP_FIELDS_ROW, SETUP_FIELDS_ROW + cast[u16](ELEVATION_FIELDS) + 4)
        }
        return void
    }
    screen.write_at(panel, 4, 2, "The administrator's name and password allow it. Esc refuses.", plain)
    top :: SETUP_FIELDS_ROW
    column : u16 = 18
    screen.write_at(panel, top, 2, "Administrator:", plain)
    screen.write_at(panel, top + 1, 2, "Their password:", plain)
    step :: service.setup
    typed :: field_bytes(service)
    if step == .AdminName {
        screen.write_at(panel, top, column, bytes_text(typed), plain)
    }
    else {
        screen.write_at(panel, top, column, bytes_text(first_of(service.admin[0..<service.admin.count], service.admin_count)), plain)
    }
    if step == .AdminPassword {
        dots(panel, top + 1, column, clusters(typed))
    }
    else if step != .AdminName {
        dots(panel, top + 1, column, 8)
    }
    if service.message_count > 0 && service.message_count <= service.message.count {
        screen.write_at(panel, top + 6, 2, string_of(&service.message[0], service.message_count), plain)
    }
    screen.write_at(panel, top + 8, 2, "Enter goes on, Backspace takes back what was typed last.", plain)
    panel.row = if step == .AdminName { top } else { top + 1 }
    shown :: if step == .AdminName { cast[u16](min_count(typed.count, 40)) } else { cast[u16](min_count(clusters(typed), 40)) }
    panel.column = column + shown
    if whole {
        redraw(service)
    }
    else {
        redraw_rows(service, SETUP_FIELDS_ROW, SETUP_FIELDS_ROW + cast[u16](ELEVATION_FIELDS) + 4)
    }
}

/**
 * Draw the elevation screen on the active view's panel: who asks and why, the fields so far, what it last said, and the
 * keys; or, at the Code step, the recovery code.
 *
 * Names are shown as typed, passwords as one dot per grapheme cluster (8 for one already sent), at most 40; the cursor
 * is left at the end of the field being typed.
 *
 * @param service The service, its elevation screen up.
 * @param whole Whether to show the panel and draw every row of it; false clears and draws only the rows of the fields
 *     and the message, which is all a key changes.
 */
draw_elevation :: fn(service: ptr[mut Service], whole: bool) {
    panel :: &view(service).screen.panel
    rows :: cast[u16](ELEVATION_FIELDS) + 4
    if whole {
        screen.show_panel(&view(service).screen, true)
    }
    else {
        screen.clear(panel, terminal.Area.{row = SETUP_FIELDS_ROW, columns = COLUMNS, rows = rows})
    }
    bold :: terminal.Style.{attributes = terminal.BOLD}
    plain :: terminal.Style.{}
    asked :: &view(service).ask
    if is_power(asked.kind) || is_debug(asked.kind) || asked.kind == .Trace || asked.kind == .SystemLog || asked.kind == .Network {
        draw_power_elevation(service, whole, asked.kind == .Restart)
        return void
    }
    screen.write_at(panel, 1, 2, "Make an account", bold)
    if service.setup == .Code {
        screen.write_at(panel, 3, 2, "The account is made. Its recovery code, shown this once:", plain)
        screen.write_at(panel, 5, 6, string_of(&service.code[0], service.code.count), bold)
        screen.write_at(panel, 7, 2, "Give it to the account's owner, to keep apart from this computer: it opens the", plain)
        screen.write_at(panel, 8, 2, "account if the password is lost.", plain)
        screen.write_at(panel, 10, 2, "Press Enter once you have.", plain)
        panel.row = 10
        panel.column = 28
        redraw(service)
        return void
    }
    storage : u8[200]
    line := text_buffer.make(storage)
    text_buffer.append(&line, bytes_text(first_of(asked.requester[0..<asked.requester.count], asked.requester_count)))
    text_buffer.append(&line, " asks to make another account, ")
    text_buffer.append(&line, bytes_text(first_of(asked.purpose[0..<asked.purpose.count], asked.purpose_count)))
    text_buffer.append(&line, ".")
    screen.write_at(panel, 3, 2, text_buffer.as_string(&line), plain)
    screen.write_at(panel, 4, 2, "The administrator's name and password allow it. Esc refuses.", plain)
    top :: SETUP_FIELDS_ROW
    column : u16 = 18
    screen.write_at(panel, top, 2, "Administrator:", plain)
    screen.write_at(panel, top + 1, 2, "Their password:", plain)
    screen.write_at(panel, top + 2, 2, "New name:", plain)
    screen.write_at(panel, top + 3, 2, "Password:", plain)
    screen.write_at(panel, top + 4, 2, "Again:", plain)
    step :: service.setup
    typed :: field_bytes(service)
    // What each row shows: the field being typed, or what was typed for it, a password as dots
    if step == .AdminName {
        screen.write_at(panel, top, column, bytes_text(typed), plain)
    }
    else {
        screen.write_at(panel, top, column, bytes_text(first_of(service.admin[0..<service.admin.count], service.admin_count)), plain)
    }
    if step == .AdminPassword {
        dots(panel, top + 1, column, clusters(typed))
    }
    else if step != .AdminName {
        dots(panel, top + 1, column, 8)
    }
    if step == .Name {
        screen.write_at(panel, top + 2, column, bytes_text(typed), plain)
    }
    else if step == .Password || step == .Again || step == .Making {
        screen.write_at(panel, top + 2, column, bytes_text(name_bytes(service)), plain)
    }
    if step == .Password {
        dots(panel, top + 3, column, clusters(typed))
    }
    else if step == .Again || step == .Making {
        dots(panel, top + 3, column, if step == .Making { 8 } else { clusters(password_bytes(service)) })
    }
    if step == .Again {
        dots(panel, top + 4, column, clusters(typed))
    }
    else if step == .Making {
        dots(panel, top + 4, column, 8)
    }
    if service.message_count > 0 && service.message_count <= service.message.count {
        screen.write_at(panel, top + 6, 2, string_of(&service.message[0], service.message_count), plain)
    }
    screen.write_at(panel, top + 8, 2, "Enter goes on, Backspace takes back what was typed last.", plain)
    panel.row = if step == .AdminName { top } else if step == .AdminPassword { top + 1 } else if step == .Name { top + 2 }
        else if step == .Password { top + 3 } else { top + 4 }
    shown :: if step == .AdminName || step == .Name { cast[u16](min_count(typed.count, 40)) } else { cast[u16](min_count(clusters(typed), 40)) }
    panel.column = column + shown
    if whole {
        redraw(service)
    }
    else {
        redraw_rows(service, SETUP_FIELDS_ROW, SETUP_FIELDS_ROW + rows)
    }
}

/** Name an error for the log. */
message_of_error :: fn(error: slop_os.ChannelError) -> string {
    runtime.log_info("trace connection failed: %", error)
    return "failed"
}

/** Log why there's no trace connection. */
log_none :: fn(why: string) -> os.Channel[trace.Trace]? {
    runtime.log_info("trace connection: %", why)
    return null
}
