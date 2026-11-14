/**
 * The GUI's login (decisions/0192, 15f; design/display.md §5): a window in the compositor's trusted layer, above every
 * client's and with the keyboard while it's shown, where a user logs in with their name and password. The account
 * service checks them and opens their home; the session manager then makes a GUI session, its first program the
 * launcher. The login window's hidden while the session runs, and shown again once its first program ends.
 *
 * A GUI session's powerbox asks the user through the greeter's prompt connection; until its prompts are drawn in the
 * trusted layer, each is refused, which its program is told as the user's refusal.
 */
package greeter

import runtime from "base"
import os from "std"
import ui from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import gui_kit from "../../gui_kit"
import accounts from "../../protocols/accounts"
import connector from "../../protocols/connector"
import prompt from "../../protocols/prompt"
import session from "../../protocols/session"
import surface from "../../protocols/surface"

/** The login window's width, in pixels. */
WIDTH : u32 : 360
/** Its height. */
HEIGHT : u32 : 230
/** The most bytes of a message. */
MESSAGE_BYTES :: 96

/** The greeter's state, on the heap. */
Greeter :: struct {
    /** Its login window. */
    window : ptr[mut gui_kit.Window],
    /** Its connection to the account service. */
    accounts_end : slop_os.Channel,
    /** The port it's bound to. */
    accounts_port : slop_os.Port,
    /** Its connection to the session manager. */
    sessions_end : slop_os.Channel,
    /** The port it's bound to. */
    sessions_port : slop_os.Port,
    /** The name being typed. */
    name : u8[..],
    /** The password being typed, wiped once it's used. */
    password : u8[..],
    /** What it says under the fields, the first message_count bytes. */
    message : u8[MESSAGE_BYTES],
    /** How many bytes of message there are. */
    message_count : usize,
    /** The session it started, while it runs; null when the login window's shown. */
    session : u32?,
    /** The prompt connection of the session it started, whose asks it refuses; NO_HANDLE without one. */
    prompts : slop_os.Channel,
}

/**
 * Show the login window, and make a GUI session for whoever logs in.
 *
 * @param log Its debug log; its lines go through base's logger instead.
 * @param accounts_service A connector to the account service.
 * @param sessions A connection to the session manager.
 * @param trusted Its connection to the compositor's trusted layer.
 * @return 2 without any of them; 3 if the account service can't be dialed, 4 if its session connection can't be
 *     bound, 5 if its window can't be made. It doesn't return otherwise.
 */
main :: fn(log: slop_os.DebugLog?, accounts_service: os.Channel[connector.Connector]?, sessions: os.Channel[session.Session]?,
    trusted: os.Channel[surface.Surface]?) -> int {
    startup :: slop_os.startup_block()
    greeter :: runtime.new(Greeter)
    greeter.prompts = cast[slop_os.Channel](slop_os.NO_HANDLE)
    accounts_dialer :: accounts_service or_return 2
    dial_port :: os.port_for(startup.budget, accounts_dialer.end) or_return 3
    greeter.accounts_end = (connector.dial[accounts.Accounts](accounts_dialer.end, dial_port) or_return 3).end
    greeter.accounts_port = os.port_for(startup.budget, greeter.accounts_end) or_return 3
    greeter.sessions_end = (sessions or_return 2).end
    greeter.sessions_port = os.port_for(startup.budget, greeter.sessions_end) or_return 4
    greeter.window = gui_kit.open_on(trusted or_return 2, "Log in", WIDTH, HEIGHT) or_return 5
    runtime.log_info("showing the login window")
    loop {
        if !gui_kit.take(greeter.window) {
            return 2
        }
        refuse_prompts(greeter)
        if greeter.session is_some {
            wait_for_session(greeter)
        }
        else if greeter.window.due {
            frame(greeter)
        }
        gui_kit.wait(greeter.window, (slop_os.clock_monotonic() or_else 0) + 250_000_000)
    }
}

/** Say something under the fields. */
say :: fn(greeter: ptr[mut Greeter], text: string) {
    greeter.message_count = 0
    for byte in string_bytes(text) {
        if greeter.message_count < greeter.message.count {
            greeter.message[greeter.message_count] = byte
            greeter.message_count += 1
        }
    }
}

/** A frame of the login window: the name and password, and Log in, which Enter in the password does too. */
frame :: fn(greeter: ptr[mut Greeter]) {
    u :: gui_kit.begin(greeter.window)
    _ = ui.open(u, "body", ui.Box.{width = ui.grow(), height = ui.grow(), padding_x = 20, padding_y = 16, gap = 10})
    _ = ui.label(u, "Log in to SlopOS", ui.TextStyle.{size = 18})
    _ = ui.text_field(u, "Name", &greeter.name)
    _ = ui.text_field(u, "Password", &greeter.password, secret = true)
    clicked :: ui.button(u, "Log in")
    kept :: greeter.message[0..<MESSAGE_BYTES]
    message :: if greeter.message_count <= kept.count { kept[0..<greeter.message_count] } else { kept }
    if message.count > 0 {
        _ = ui.label(u, string_of(&message[0], message.count))
    }
    ui.close(u)
    events :: gui_kit.finish(greeter.window)
    submitted := clicked
    for event in events {
        submitted = submitted || event.kind == .Submitted
    }
    if submitted {
        log_in(greeter)
    }
}

/** Check the name and password with the account service, and make the session if they're right. */
log_in :: fn(greeter: ptr[mut Greeter]) {
    runtime.log_info("logging in as %", string_of_bytes(greeter.name[0..<greeter.name.count]))
    out := os.Outgoing.{}
    request :: os.begin[accounts.Request](&out)
    request^ = .OpenHome(accounts.Credentials.{name = os.append(&out, greeter.name[0..<greeter.name.count]),
        password = os.append(&out, greeter.password[0..<greeter.password.count])})
    sent :: accounts.send_request(greeter.accounts_end, greeter.accounts_port, &out) is_none
    // The password's copies wiped: what was sent, and what was typed
    for i in 0..<out.words.count {
        out.words[i] = 0
    }
    for &byte in greeter.password {
        byte^ = 0
    }
    runtime.array_reset(&greeter.password)
    if !sent {
        say(greeter, "The account service couldn't be asked.")
        return void
    }
    into := os.Incoming.{}
    match accounts.receive_response(greeter.accounts_end, greeter.accounts_port, &into, true) {
        case Received => {}
        case _ => {
            say(greeter, "The account service didn't answer.")
            return void
        }
    }
    match os.message_of[accounts.Response](&into)^ {
        case OpenedHome(home) => start_session(greeter, home)
        case RateLimited(_) => {
            runtime.log_info("a login refused: too many tries")
            say(greeter, "Too many tries: wait a little, and try again.")
        }
        case _ => {
            runtime.log_info("a login refused")
            say(greeter, "That name and password don't match an account.")
        }
    }
}

/** Make the GUI session, its home and a prompt connection given to the session manager. */
start_session :: fn(greeter: ptr[mut Greeter], home: os.Channel[dir.Dir]) {
    budget :: slop_os.startup_block().budget
    pair :: os.channel_for[prompt.Prompt](budget, 0) or_else slop_os.ChannelPair.{a = cast[slop_os.Channel](slop_os.NO_HANDLE), b = cast[slop_os.Channel](slop_os.NO_HANDLE)}
    out := os.Outgoing.{}
    request :: os.begin[session.Request](&out)
    request^ = .StartGui(session.GuiStart.{user = os.append(&out, greeter.name[0..<greeter.name.count]), layout = os.append(&out, string_bytes("us")),
        home = home, prompts = os.Channel[prompt.Prompt].{end = pair.b}})
    if session.send_request(greeter.sessions_end, greeter.sessions_port, &out) is_some {
        say(greeter, "The session manager couldn't be asked.")
        return void
    }
    into := os.Incoming.{}
    match session.receive_response(greeter.sessions_end, greeter.sessions_port, &into, true) {
        case Received => {}
        case _ => {
            say(greeter, "The session manager didn't answer.")
            return void
        }
    }
    match os.message_of[session.Response](&into)^ {
        case Started(number) => {
            greeter.session = number
            greeter.prompts = pair.a
            runtime.log_info("started a GUI session for %", string_of_bytes(greeter.name[0..<greeter.name.count]))
            say(greeter, "")
            gui_kit.hide(greeter.window)
            // Its end waited for
            waiting := os.Outgoing.{}
            wait :: os.begin[session.Request](&waiting)
            wait^ = .Wait(number)
            _ = session.send_request(greeter.sessions_end, greeter.sessions_port, &waiting)
        }
        case _ => {
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.a))
            say(greeter, "The session couldn't be started.")
        }
    }
}

/** Bytes as text. */
string_of_bytes :: fn(bytes: u8[]) -> string {
    return if bytes.count > 0 { string_of(&bytes[0], bytes.count) } else { "" }
}

/** Once the session's first program has ended: the login window shown again, for the next. */
wait_for_session :: fn(greeter: ptr[mut Greeter]) {
    into := os.Incoming.{}
    match session.receive_response(greeter.sessions_end, greeter.sessions_port, &into, false) {
        case Received => {}
        case _ => return void
    }
    match os.message_of[session.Response](&into)^ {
        case Exited(_) => {
            greeter.session = null
            if greeter.prompts != cast[slop_os.Channel](slop_os.NO_HANDLE) {
                _ = slop_os.handle_close(cast[slop_os.Handle](greeter.prompts))
                greeter.prompts = cast[slop_os.Channel](slop_os.NO_HANDLE)
            }
            runtime.array_reset(&greeter.name)
            runtime.log_info("the GUI session ended")
            greeter.window.due = true
        }
        case _ => {}
    }
}

/** Refuse what the session's powerbox asks: its prompts aren't drawn in the trusted layer yet. */
refuse_prompts :: fn(greeter: ptr[mut Greeter]) {
    if greeter.prompts == cast[slop_os.Channel](slop_os.NO_HANDLE) {
        return void
    }
    port :: os.port_for(slop_os.startup_block().budget, greeter.prompts) or_return void
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    into := os.Incoming.{}
    loop {
        match prompt.receive_request(greeter.prompts, port, &into, false) {
            case Received => {}
            case _ => return void
        }
        out := os.Outgoing.{}
        response :: os.begin[prompt.Response](&out)
        response^ = .Refused
        _ = prompt.send_response(greeter.prompts, port, &out)
        runtime.log_info("refused a prompt: the GUI's prompts aren't drawn yet")
    }
}
