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
import screen from "../../screen"

/** The status line's text while the elevation screen is up. */
STATUS_ELEVATING :: " SlopOS │ console │ making an account"
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
    runtime.log_info("elevation: % asks for an account", bytes_text(first_of(view(service).ask.requester[0..<view(service).ask.requester.count],
        view(service).ask.requester_count)))
    say(service, "")
    setup_step(service, .AdminName)
    update_status(service)
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
    if made && service.name_count <= service.name.count {
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
