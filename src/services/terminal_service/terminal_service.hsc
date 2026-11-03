/*
 * The terminal service (decisions/0136, 0137, 0138, design/console-and-sessions.md §2, §3), which replaced the console
 * service of decisions/0075 and 0077. It serves the console's terminal over the terminal protocol, keeping what it shows
 * in a screen model (src/screen): what its clients write goes into the model, a grapheme cluster at a time, made safe
 * (safe_text) so text can't become a control sequence, and is shown on the first serial line through the VT adapter and,
 * if there's one, on the framebuffer, drawn from the model (src/glyph_screen): one console, shown on both. The top row
 * is the status line, which only this service writes; programs have the rows below it.
 *
 * What's typed, on the serial line or the seat's keyboards, which the input service types through its keymap, becomes
 * typed input for the client that reads it first, except the secure attention key, Ctrl+Alt+Delete (on the serial line
 * as a terminal sends it, CSI 3;7~; from the input service as itself): that brings up this service's own screen, which
 * every key goes to until Esc or Enter leaves it, and the program's screen is drawn again from the model. A new
 * keyboard's code, which the input service makes, is shown on the status line until it's typed on it.
 *
 * The input's owner can hand it the line it's editing (InputLine, decisions/0147): kept below everything written in
 * lines, it's taken away before anything else is written, cleared, moved or scrolled, the cursor put back where the
 * output left off, and drawn again after, on the row after the output's if that one has something on it.
 *
 * First-boot setup (decisions/0148): with no accounts, which it asks the account service, its own screen asks for the
 * administrator's name and password, twice, has the account service make the account, and shows the recovery code
 * once. Every key is its own until then, as the secure attention key's screen's are. Then, and with accounts, its
 * login screen (decisions/0150) asks for a name and password, with the keyboard layout on the status line, which F2
 * changes; the account service opens the account's home volume with them, and the session manager makes the session,
 * with a terminal connection of its own and the home's root. With no account service, a boot with no accounts, the
 * session manager makes a session with no user at once.
 *
 * Several sessions (decisions/0151): each has a view of its own, which its programs write to, one shown at a time. The
 * secure attention key's screen switches to the next (S), logs in another (N), locks the console until the session's
 * user's password is typed (L), and logs out (O), the session manager ending the session's programs. A session's
 * powerbox asks the user through it (chooser.hsc, decisions/0156): the request's on the status line, and the secure
 * attention key opens the chooser instead of this screen, and G there shows what its user has let programs keep
 * (grants_view.hsc, decisions/0158); a request for another account opens the elevation screen instead (elevation.hsc),
 * and H there shares a volume with another user (share_form.hsc).
 * Both are reached
 * through connectors, dialed again when they go, with the banner shown on each new serial line. Without a serial line
 * it keeps the model and shows nothing.
 */
package terminal_service

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import text_buffer from "std"
import unicode from "std"
import terminal from "std/os/slop_os"
import time from "std"
import account_records from "../../account_records"
import accounts from "../../protocols/accounts"
import keymaps from "../../keymaps"
import dir from "std/os/slop_os"
import connector from "../../protocols/connector"
import seat from "../../protocols/seat"
import session from "../../protocols/session"
import prompt from "../../protocols/prompt"
import serial from "../../protocols/serial"
import service_kit from "../../libraries/service_kit"
import safe_text from "../../safe_text"
import screen from "../../screen"
import glyph_screen from "../../glyph_screen"
import vt from "../../vt"

// The serial line and the seat are bound to the port above the clients
SERIAL_KEY : u64 : 1000
SEAT_KEY : u64 : 1001
ACCOUNTS_KEY : u64 : 1002
BANNER :: "SlopOS console"
NONE : slop_os.Channel : cast[slop_os.Channel](slop_os.NO_HANDLE)
TAB_STOP : u16 : 8
COLUMNS : u16 : screen.COLUMNS
ROWS : u16 : screen.ROWS
PROGRAM_ROWS : u16 : screen.PROGRAM_ROWS

// What the status line says: no one has logged in until sessions (10c)
STATUS :: " SlopOS │ console │ no session"
STATUS_ATTENTION :: " SlopOS │ console │ secure attention"
STATUS_SETUP :: " SlopOS │ console │ first-boot setup"
STATUS_LOGIN :: " SlopOS │ console │ log in"
STATUS_NO_ACCOUNTS :: " SlopOS │ console │ no accounts"
STATUS_LOCKED :: " SlopOS │ console │ locked"

// Output waiting for the serial line, and how many Writes may be in flight on it, which its ring holds
OUTPUT_BYTES :: 16384
MAX_IN_FLIGHT : u32 : 2

USAGE_BACKSPACE : u16 : 0x2a
USAGE_F2 : u16 : 0x3b
USAGE_C : u16 : 0x06
USAGE_E : u16 : 0x08
USAGE_L : u16 : 0x0f
USAGE_N : u16 : 0x11
USAGE_O : u16 : 0x12
USAGE_S : u16 : 0x16
USAGE_ENTER : u16 : 0x28
USAGE_ESCAPE : u16 : 0x29
USAGE_DELETE : u16 : 0x4c
USAGE_DOWN : u16 : 0x51
USAGE_UP : u16 : 0x52
// The panel's rows: where the list of programs starts
PROGRAMS_ROW : u16 : 7
PANIC_TEXT :: 160
// Bytes typed on the serial line decoded at a time, fewer than the events held
FEED_SLICE : usize : 8
// The most sessions' views, and a client's with none
MAX_VIEWS :: 4
NO_VIEW : usize : 0xffffffff
// The most bytes of the line the input's owner is editing
INPUT_LINE_BYTES :: 512

// First-boot setup's steps (decisions/0148).
SetupStep :: enum {
    Off,
    Name,
    Password,
    Again,
    // The account service making the account, which takes Argon2id's time
    Making,
    // The recovery code shown, until Enter
    Code,
    // Logging in (decisions/0150): the name, the password, and the session being made
    LoginName,
    LoginPassword,
    LoggingIn,
    // Elevation (decisions/0158): the administrator's name and password, before the new account's
    AdminName,
    AdminPassword,
    // Sharing a volume: its name, the member's, and the account service sharing it
    ShareName,
    ShareMember,
    Sharing,
}

// Setup's first row of fields: the name, the password, it again, then a blank row and its message
SETUP_FIELDS_ROW : u16 : 6
// A field's bytes, and a setup message's
FIELD_BYTES :: 256
MESSAGE_BYTES :: 160

Service :: struct {
    log : slop_os.DebugLog,
    port : slop_os.Port,
    // The connectors to the serial line and the input service, and the connections they gave, NONE without
    serial_connector : slop_os.Channel,
    seat_connector : slop_os.Channel,
    line_end : slop_os.Channel,
    // Whether a Read to the serial line is waiting for its answer
    line_reading : bool,
    seat_end : slop_os.Channel,
    // Whether a Read to the input service is waiting for its answer, and the keys it's given that wait for room
    // among the decoded input, in order, with their text
    seat_reading : bool,
    typed : seat.Event[TYPED_KEYS],
    typed_count : usize,
    typed_text : u8[TYPED_TEXT],
    typed_text_count : usize,
    // What's waiting to be sent on the serial line: a ring, from output_start
    output : u8[OUTPUT_BYTES],
    output_start : usize,
    output_count : usize,
    in_flight : u32,
    // The sessions' views (decisions/0151), the one in use (view), which is the active one but while another's client
    // is served, and the active one, shown; each client's view, NO_VIEW for one in none, which writes to the active one's
    views : View[MAX_VIEWS],
    viewing : usize,
    active : usize,
    client_view : usize[service_kit.MAX_CLIENTS],
    // The framebuffer it's drawn on, if there's one
    canvas : glyph_screen.Canvas,
    has_canvas : bool,
    // Whether the secure attention key's screen is up, which every key goes to
    attention : bool,
    // A new keyboard's code, shown on the status line until it's typed, 0 for none
    waiting_code : u32,
    // The session's programs, from whoever runs them (decisions/0139), and the one chosen on the panel
    session_end : slop_os.Channel,
    session_port : slop_os.Port,
    programs : session.Program[session.MAX_PROGRAMS],
    program_count : usize,
    chosen : usize,
    // The first line of the boot before's panic record, if it stopped for a fault, and whether the panel's shown it
    panic : u8[PANIC_TEXT],
    panic_count : usize,
    panic_seen : bool,
    // Input waiting for the active view's owner: decoded, as the trusted path takes what's its own first
    decoder : vt.Decoder,
    decoded : vt.Decoded,
    // The account service, through its connector, and first-boot setup: its step, the field being typed, the name and
    // password so far, what it last said, and the recovery code to show
    accounts_connector : slop_os.Channel,
    accounts_end : slop_os.Channel,
    setup : SetupStep,
    field : u8[FIELD_BYTES],
    field_count : usize,
    name : u8[account_records.MAX_NAME_BYTES],
    name_count : usize,
    password : u8[FIELD_BYTES],
    password_count : usize,
    message : u8[MESSAGE_BYTES],
    message_count : usize,
    code : u8[accounts.RECOVERY_TEXT_BYTES],
    // The clients, and the keyboard layout the login screen chose
    connected : service_kit.Clients,
    layout : string,
    // The view a login for another session was started from, to go back to; and whether the login screen is unlocking
    previous : usize,
    unlocking : bool,
    // Whether the secure attention key brought up the powerbox's chooser, and its state
    choosing : bool,
    chooser : Chooser,
    // Whether its G brought up the grants view, and what it lists
    granting : bool,
    grants : GrantsView,
    // Whether the setup screen is elevation's, and the administrator's name and password typed there
    elevating : bool,
    admin : u8[account_records.MAX_NAME_BYTES],
    admin_count : usize,
    admin_password : u8[FIELD_BYTES],
    admin_password_count : usize,
    // Whether the setup screen is the share form, whether what it asked takes a member out, and the volume's name
    sharing : bool,
    unsharing : bool,
    share_name : u8[account_records.MAX_NAME_BYTES],
    share_name_count : usize,
}

/*
 * A session's view (decisions/0151): what it shows, its input's owner and the line that owner's editing, and whose it
 * is; one is shown at a time, and the others keep what their programs write for when they're switched to.
 */
View :: struct {
    in_use : bool,
    screen : screen.Screen,
    owner : usize?,
    held : u32,
    // The line the owner's editing, the cursor in it, and whether it's drawn, from which row
    input : u8[INPUT_LINE_BYTES],
    input_count : usize,
    input_cursor : usize,
    input_drawn : bool,
    input_row : u16,
    // While it's drawn, where the output goes on: its row and column, and the lines' scrolls then
    output_row : u16,
    output_column : u16,
    output_scrolls : u64,
    // Whose session it is, and the session manager's number for it
    user : u8[account_records.MAX_NAME_BYTES],
    user_count : usize,
    logged_in : bool,
    session : u32,
    // Its powerbox's prompt connection, NONE without one, and the request waiting on it for the user
    prompt_end : slop_os.Channel,
    asking : bool,
    ask : Asked,
    // A connection of its own to the session's home, for the grants view; NONE without one
    home_end : slop_os.Channel,
}

main :: fn(log: slop_os.DebugLog?, serial_line: os.Channel[connector.Connector]?, input: os.Channel[connector.Connector]?,
    framebuffer: slop_os.Memory?, framebuffer_layout: slop_os.Memory?, programs: os.Channel[session.Session]?,
    last_panic: slop_os.Memory?, accounts_service: os.Channel[connector.Connector]?, clients: os.Listener[terminal.Terminal]) -> int {
    startup :: slop_os.startup_block()
    service := runtime.new(Service)
    service.log = log or_else cast[slop_os.DebugLog](slop_os.NO_HANDLE)
    service.serial_connector = NONE
    service.seat_connector = NONE
    service.line_end = NONE
    service.seat_end = NONE
    service.session_end = NONE
    service.accounts_connector = NONE
    service.accounts_end = NONE
    match programs {
        case Some(found) => {
            service.session_end = found.end
            service.session_port = os.port_for(startup.budget, found.end) or_else cast[slop_os.Port](slop_os.NO_HANDLE)
        }
        case None => {}
    }
    keep_panic(service, last_panic)
    for i in 0..<service.client_view.count {
        service.client_view[i] = NO_VIEW
    }
    open_view(service, 0)
    service.active = 0
    service.viewing = 0
    update_status(service)
    match canvas_on(framebuffer, framebuffer_layout) {
        case Some(made) => {
            service.canvas = made
            service.has_canvas = true
        }
        case None => {}
    }
    service.port = slop_os.port_create(startup.budget) or_return 2
    service.layout = keymaps.US.name
    connected :: &service.connected
    if !service_kit.add_client(connected, service.port, clients.end) {
        return 3
    }
    match serial_line {
        case Some(found) => service.serial_connector = found.end
        case None => {}
    }
    match input {
        case Some(found) => service.seat_connector = found.end
        case None => {}
    }
    match accounts_service {
        case Some(found) => service.accounts_connector = found.end
        case None => {}
    }
    dial_seat(service)
    dial_serial(service)
    dial_accounts(service)
    // A boot with no accounts has the one session with no user, at once
    if service.accounts_connector == NONE {
        start_session(service, null)
    }
    runtime.log_info("serving")
    into := os.Incoming.{}
    loop {
        with {
            i : usize = 0
        }
        loop {
            serve(service, connected, i, &into)
            i += 1
        }
        while i < connected.count
        take_serial(service, &into)
        take_seat(service, &into)
        take_accounts(service, &into)
        take_prompts(service, &into)
        deliver(service, connected)
        // Keys that waited for room, decoded now that a delivery's made some, and the serial line read again if it waited
        take_typed(service)
        read_more(service)
        pump(service)
        draw_framebuffer(service)
        packets : slop_os.Packet[8]
        _ = slop_os.port_wait(service.port, packets, slop_os.NO_DEADLINE)
    }
}

// A canvas on the framebuffer, if there's one: its pixels mapped, as its layout says they're laid out.
canvas_on :: fn(framebuffer: slop_os.Memory?, layout_page: slop_os.Memory?) -> glyph_screen.Canvas? {
    pixels :: framebuffer or_return null
    page :: layout_page or_return null
    block :: slop_os.startup_block()
    layout_at :: runtime.reserve_addresses(cast[usize](4096)) or_return null
    slop_os.memory_map(page, block.space, layout_at, 0, 4096, slop_os.PROTECTION_READ) or_return null
    layout :: cast[ptr[slop_os.FramebufferLayout]](layout_at)^
    size :: slop_os.memory_size(pixels) or_return null
    at :: runtime.reserve_addresses(cast[usize](size)) or_return null
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    slop_os.memory_map(pixels, block.space, at, 0, size, read_write) or_return null
    if cast[u64](layout.pitch) * cast[u64](layout.height) > size {
        return null
    }
    made :: glyph_screen.make_canvas(at, layout) or_return null
    runtime.log_info("drawing on the framebuffer, %x%", layout.width, layout.height)
    return made
}

// What changed, drawn on the framebuffer, with the cursor where a program's is.
draw_framebuffer :: fn(service: ptr[mut Service]) {
    if service.has_canvas {
        glyph_screen.draw(&service.canvas, &view(service).screen, !service.attention)
    }
}

/*
 * A serial line through its connector, if there's one: bound to the port, with the banner shown, the rows below the
 * status line made the ones that scroll, the status line drawn, and a Read held.
 */
dial_serial :: fn(service: ptr[mut Service]) {
    if cast[slop_os.Handle](service.serial_connector) == slop_os.NO_HANDLE {
        return void
    }
    port :: os.port_for(slop_os.startup_block().budget, service.serial_connector) or_return void
    line :: connector.dial[serial.Serial](service.serial_connector, port) or_return void
    signals :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    match slop_os.port_bind(service.port, cast[slop_os.Handle](line.end), signals, SERIAL_KEY, .Persistent) {
        case Ok => {}
        case Error(error) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](line.end))
            return void
        }
    }
    service.line_end = line.end
    service.line_reading = false
    service.in_flight = 0
    // Firmware may have left a line unfinished on the same console
    storage : u8[96]
    shown := text_buffer.make(storage)
    vt.append_line_break(&shown)
    text_buffer.append(&shown, BANNER)
    vt.append_line_break(&shown)
    vt.append_margins(&shown, 1, ROWS - 1)
    vt.append_move(&shown, ROWS - 1, 0)
    emit(service, string_bytes(text_buffer.as_string(&shown)))
    draw_status(service)
    read_more(service)
    pump(service)
}

// The input service through its connector, if there's one: bound to the port, with a Read held.
dial_seat :: fn(service: ptr[mut Service]) {
    if cast[slop_os.Handle](service.seat_connector) == slop_os.NO_HANDLE {
        return void
    }
    port :: os.port_for(slop_os.startup_block().budget, service.seat_connector) or_return void
    keys :: connector.dial[seat.Seat](service.seat_connector, port) or_return void
    signals :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    match slop_os.port_bind(service.port, cast[slop_os.Handle](keys.end), signals, SEAT_KEY, .Persistent) {
        case Ok => {}
        case Error(error) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](keys.end))
            return void
        }
    }
    service.seat_end = keys.end
    service.seat_reading = false
    read_seat(service)
}

serve :: fn(service: ptr[mut Service], connected: ptr[mut service_kit.Clients], index: usize, into: ptr[mut os.Incoming]) {
    if index >= connected.ends.count {
        return void
    }
    end :: connected.ends[index]
    if cast[slop_os.Handle](end) == slop_os.NO_HANDLE {
        return void
    }
    loop {
        match terminal.receive_request(end, service.port, into, false) {
            case Received => {}
            case Empty => return void
            case Unsupported => {
                _ = terminal.answer_unsupported(end, service.port)
                continue
            }
            case Failed(error) => {
                service_kit.drop_client(connected, index)
                use_view_of(service, index)
                match view(service).owner {
                    case Some(owner) => {
                        if owner == index {
                            hide_input(service)
                            view(service).input_count = 0
                            view(service).owner = null
                            view(service).held = 0
                        }
                    }
                    case None => {}
                }
                use_active(service)
                if index < service.client_view.count {
                    service.client_view[index] = NO_VIEW
                }
                return void
            }
            case _ => continue
        }
        // Served in its own session's view, which is shown only if it's the active one
        use_view_of(service, index)
        defer use_active(service)
        request :: os.message_of[terminal.Request](into)
        // What's written, cleared, moved or scrolled goes above the line being typed
        moves_output :: match request^ {
            case Write(_) => true
            case MoveCursor(_) => true
            case Clear(_) => true
            case Scroll(_) => true
            case Screen(_) => true
            case _ => false
        }
        if moves_output {
            hide_input(service)
        }
        match request^ {
            case Write(text) => write(service, into, text)
            case MoveCursor(position) => move_cursor(service, position)
            case ShowCursor(shown) => {
                storage : u8[16]
                out := text_buffer.make(storage)
                vt.append_cursor_shown(&out, shown)
                emit_program(service, &out)
            }
            case Clear(area) => clear(service, area)
            case Scroll(scrolled) => scroll(service, scrolled)
            case Screen(whole) => use_screen(service, whole)
            case Bell => {
                storage : u8[4]
                out := text_buffer.make(storage)
                vt.append_bell(&out)
                emit_program(service, &out)
            }
            case Describe => {
                out := os.Outgoing.{}
                response :: os.begin[terminal.Response](&out)
                response^ = .Described(terminal.Features.{columns = COLUMNS, rows = PROGRAM_ROWS, colors = .Rgb,
                    attributes = terminal.BOLD | terminal.DIM | terminal.ITALIC | terminal.UNDERLINE | terminal.INVERSE | terminal.STRIKETHROUGH,
                    links = true, unicode = 17 * 256})
                _ = terminal.send_response(end, service.port, &out)
            }
            case Read(most) => {
                // The first client to read owns the input, until it goes (sessions decide this in 10c)
                owned :: match view(service).owner {
                    case Some(owner) => owner == index
                    case None => true
                }
                if owned {
                    view(service).owner = index
                    view(service).held = if most == 0 { cast[u32](1) } else { most }
                }
            }
            case InputLine(line) => {
                if is_owner(service, index) {
                    hide_input(service)
                    bytes :: os.items(into, line.text)
                    view(service).input_count = if bytes.count < view(service).input.count { bytes.count } else { view(service).input.count }
                    for byte, i in bytes {
                        if i < view(service).input.count {
                            view(service).input[i] = byte
                        }
                    }
                    view(service).input_cursor = if cast[usize](line.cursor) < view(service).input_count { cast[usize](line.cursor) } else { view(service).input_count }
                    show_input(service)
                }
            }
            case Connect(connection) => {
                if !service_kit.add_client(connected, service.port, connection.end) {
                    _ = slop_os.handle_close(cast[slop_os.Handle](connection.end))
                }
            }
        }
        if moves_output {
            show_input(service)
        }
    }
}

is_owner :: fn(service: ptr[mut Service], index: usize) -> bool {
    return match view(service).owner {
        case Some(owner) => owner == index
        case None => false
    }
}

/*
 * The line being typed taken away, if it's drawn: its rows cleared, and the cursor back where the output left off, the
 * row it was on moved up by the lines' scrolls since, or at the top if it's scrolled away.
 */
hide_input :: fn(service: ptr[mut Service]) {
    if !view(service).input_drawn {
        return void
    }
    view(service).input_drawn = false
    grid :: &view(service).screen.lines
    screen.clear(grid, terminal.Area.{row = view(service).input_row, columns = COLUMNS, rows = PROGRAM_ROWS})
    scrolled :: grid.scrolls - view(service).output_scrolls
    grid.row = if cast[u64](view(service).output_row) >= scrolled { view(service).output_row - cast[u16](scrolled) } else { 0 }
    grid.column = view(service).output_column
    storage : u8[32]
    out := text_buffer.make(storage)
    vt.append_move(&out, view(service).input_row + 1, 0)
    vt.append_clear_below(&out)
    vt.append_move(&out, grid.row + 1, grid.column)
    emit_program(service, &out)
}

/*
 * The line being typed drawn below the output, in lines, if there's one: from the start of the row after the output's,
 * if the output's has something on it, made safe a cluster at a time as written text is, with the cursor left where
 * the owner says.
 */
show_input :: fn(service: ptr[mut Service]) {
    if view(service).input_drawn || view(service).input_count == 0 || view(service).screen.using_whole || view(service).input_count > view(service).input.count {
        return void
    }
    grid :: &view(service).screen.lines
    view(service).output_row = grid.row
    view(service).output_column = grid.column
    view(service).output_scrolls = grid.scrolls
    storage : u8[64]
    out := text_buffer.make(storage)
    if grid.column > 0 {
        screen.line_break(&view(service).screen)
        vt.append_line_break(&out)
        emit_program(service, &out)
    }
    first_scrolls :: grid.scrolls
    first_row :: grid.row
    plain :: terminal.Style.{}
    count :: view(service).input_count
    if count > view(service).input.count {
        return void
    }
    line :: view(service).input[0..<count]
    cursor_row := grid.row
    cursor_column := grid.column
    cursor_scrolls := grid.scrolls
    at : usize = 0
    loop {
        if at == view(service).input_cursor {
            cursor_row = grid.row
            cursor_column = grid.column
            cursor_scrolls = grid.scrolls
        }
        if at >= line.count {
            break
        }
        end :: unicode.grapheme_end(line, at)
        if end <= at || end > line.count {
            break
        }
        shown := safe_text.Shown.{}
        // A line break or tab in it is shown as its substitute, as the line is one line
        safe_text.show(line, at, end, &shown)
        if shown.count <= shown.bytes.count {
            cluster :: shown.bytes[0..<shown.count]
            wrapped :: grid.column + cast[u16](shown.columns) > COLUMNS
            screen.put(&view(service).screen, cluster, shown.columns, plain)
            text_buffer.clear(&out)
            if wrapped {
                vt.append_line_break(&out)
            }
            if cluster.count > 0 {
                text_buffer.append(&out, string_of(&cluster[0], cluster.count))
            }
            emit_program(service, &out)
        }
        at = end
    }
    // Where it starts, and the cursor, moved up by any scrolling the line itself did
    since_first :: grid.scrolls - first_scrolls
    view(service).input_row = if cast[u64](first_row) >= since_first { first_row - cast[u16](since_first) } else { 0 }
    since_cursor :: grid.scrolls - cursor_scrolls
    grid.row = if cast[u64](cursor_row) >= since_cursor { cursor_row - cast[u16](since_cursor) } else { 0 }
    grid.column = cursor_column
    text_buffer.clear(&out)
    vt.append_move(&out, grid.row + 1, grid.column)
    emit_program(service, &out)
    view(service).input_drawn = true
}

// Whether two styles are the same.
same_style :: fn(a: terminal.Style, b: terminal.Style) -> bool {
    return a.attributes == b.attributes && same_color(a.foreground, b.foreground) && same_color(a.background, b.background)
}

same_color :: fn(a: terminal.Color, b: terminal.Color) -> bool {
    return a.kind == b.kind && a.index == b.index && a.red == b.red && a.green == b.green && a.blue == b.blue
}

/*
 * A Write: its text a grapheme cluster at a time, each in its run's style, made safe, into the screen and onto the
 * serial line; line breaks as CR LF, tabs as spaces to the next stop. The style and any link are ended with it, so
 * another client's text starts plain.
 */
write :: fn(service: ptr[mut Service], into: ptr[os.Incoming], text: terminal.Text) {
    bytes :: os.items(into, text.text)
    runs :: os.items(into, text.runs)
    links :: os.items(into, text.links)
    plain :: terminal.Style.{}
    current := plain
    linked := false
    run_index : usize = 0
    run_end : usize = if runs.count > 0 { cast[usize](runs[0].bytes) } else { bytes.count }
    at : usize = 0
    loop {
        if at >= bytes.count {
            break
        }
        end :: unicode.grapheme_end(bytes, at)
        if end <= at || end > bytes.count {
            break
        }
        // The run this cluster starts in; past the last, the last's style
        loop {
            if at < run_end || run_index + 1 >= runs.count {
                break
            }
            run_index += 1
            if run_index < runs.count {
                run_end += cast[usize](runs[run_index].bytes)
            }
        }
        storage : u8[160]
        out := text_buffer.make(storage)
        style := plain
        if run_index < runs.count {
            run :: runs[run_index]
            style = run.style
            if !same_style(run.style, current) {
                vt.append_style(&out, run.style)
                current = run.style
            }
            // A link starts or stops with its run
            wanted :: run.link_bytes > 0
            if wanted || linked {
                start :: cast[usize](run.link_start)
                stop :: start + cast[usize](run.link_bytes)
                if wanted && stop <= links.count && start <= stop {
                    vt.append_link(&out, links[start..<stop])
                }
                else if linked {
                    vt.append_link(&out, links[0..<0])
                }
                linked = wanted
            }
        }
        if safe_text.is_line_break(bytes, at, end) {
            vt.append_line_break(&out)
            screen.line_break(&view(service).screen)
        }
        else if safe_text.is_tab(bytes, at, end) {
            grid :: screen.current(&view(service).screen)
            loop {
                text_buffer.append_byte(&out, cast[u8](' '))
                screen.put(&view(service).screen, string_bytes(" "), 1, style)
            }
            while grid.column % TAB_STOP != 0 && grid.column < COLUMNS
        }
        else {
            shown := safe_text.Shown.{}
            safe_text.show(bytes, at, end, &shown)
            if shown.count <= shown.bytes.count {
                cluster :: shown.bytes[0..<shown.count]
                screen.put(&view(service).screen, cluster, shown.columns, style)
                if cluster.count > 0 {
                    text_buffer.append(&out, string_of(&cluster[0], cluster.count))
                }
            }
        }
        emit_program(service, &out)
        at = end
    }
    storage : u8[32]
    out := text_buffer.make(storage)
    if linked {
        vt.append_link(&out, links[0..<0])
    }
    if !same_style(current, plain) {
        vt.append_style(&out, plain)
    }
    emit_program(service, &out)
}

// The cursor: anywhere on a whole screen; on lines, only along the line being written.
move_cursor :: fn(service: ptr[mut Service], position: terminal.Position) {
    screen.move(&view(service).screen, position.column, position.row)
    grid :: screen.current(&view(service).screen)
    storage : u8[32]
    out := text_buffer.make(storage)
    if view(service).screen.using_whole {
        vt.append_move(&out, grid.row + 1, grid.column)
    }
    else {
        vt.append_column(&out, grid.column)
    }
    emit_program(service, &out)
}

/*
 * An area made blank: on a whole screen, each of its rows; on lines, the line being written, with the cursor at its
 * start, which is how a program redraws a line it's editing.
 */
clear :: fn(service: ptr[mut Service], area: terminal.Area) {
    storage : u8[128]
    out := text_buffer.make(storage)
    grid :: screen.current(&view(service).screen)
    if !view(service).screen.using_whole {
        screen.clear_line_from(grid, 0)
        text_buffer.append_byte(&out, 0x0d)
        vt.append_clear_to_end(&out)
        emit_program(service, &out)
        return void
    }
    screen.clear(grid, area)
    if area.column >= COLUMNS || area.row >= PROGRAM_ROWS {
        return void
    }
    columns :: if area.columns > COLUMNS - area.column { COLUMNS - area.column } else { area.columns }
    rows :: if area.rows > PROGRAM_ROWS - area.row { PROGRAM_ROWS - area.row } else { area.rows }
    for row in area.row..<area.row + rows {
        text_buffer.clear(&out)
        vt.append_move(&out, row + 1, area.column)
        if area.column + columns >= COLUMNS {
            vt.append_clear_to_end(&out)
        }
        else {
            for i in 0..<columns {
                text_buffer.append_byte(&out, cast[u8](' '))
            }
        }
        emit_program(service, &out)
    }
}

// An area scrolled, on a whole screen, where it's as wide as the screen, which is what a VT can scroll.
scroll :: fn(service: ptr[mut Service], scrolled: terminal.ScrollArea) {
    area :: scrolled.area
    if !view(service).screen.using_whole || area.column != 0 || area.columns < COLUMNS || area.row >= PROGRAM_ROWS || area.rows == 0 {
        return void
    }
    screen.scroll(&view(service).screen.whole, area.row, area.rows, scrolled.lines)
    last :: if area.rows > PROGRAM_ROWS - area.row { PROGRAM_ROWS - 1 } else { area.row + area.rows - 1 }
    storage : u8[64]
    out := text_buffer.make(storage)
    vt.append_scroll(&out, area.row + 1, last + 1, scrolled.lines)
    vt.append_margins(&out, 1, ROWS - 1)
    emit_program(service, &out)
}

// A screen of the program's own, or back to the lines it left.
use_screen :: fn(service: ptr[mut Service], whole: bool) {
    if whole == view(service).screen.using_whole {
        return void
    }
    screen.use_whole(&view(service).screen, whole)
    storage : u8[64]
    out := text_buffer.make(storage)
    vt.append_alternate_screen(&out, whole)
    if whole {
        // A new screen is blank, the status line too, so it's drawn again
        vt.append_move(&out, 1, 0)
        view(service).screen.status_dirty = true
    }
    emit_program(service, &out)
    if !service.attention {
        draw_status(service)
    }
}

// The status line's text, for whether the secure attention key's screen is up and any keyboard is waiting, drawn.
update_status :: fn(service: ptr[mut Service]) {
    storage : u8[160]
    status := text_buffer.make(storage)
    if service.attention {
        text_buffer.append(&status, STATUS_ATTENTION)
    }
    else if service.setup != .Off && service.unlocking {
        text_buffer.append(&status, STATUS_LOCKED)
    }
    else if service.setup != .Off && service.elevating {
        text_buffer.append(&status, STATUS_ELEVATING)
    }
    else if service.setup != .Off && service.sharing {
        text_buffer.append(&status, STATUS_SHARING)
    }
    else if service.setup != .Off {
        text_buffer.append(&status, if is_login(service.setup) { STATUS_LOGIN } else { STATUS_SETUP })
        layout :: keymaps.find(service.layout) or_else keymaps.US
        text_buffer.append(&status, " │ keyboard: ")
        text_buffer.append(&status, layout.title)
        text_buffer.append(&status, " │ F2: layout")
    }
    else if view(service).logged_in && view(service).user_count > 0 && view(service).user_count <= view(service).user.count {
        text_buffer.append(&status, " SlopOS │ console │ ")
        text_buffer.append(&status, string_of(&view(service).user[0], view(service).user_count))
    }
    else if view(service).logged_in {
        text_buffer.append(&status, STATUS_NO_ACCOUNTS)
    }
    else {
        text_buffer.append(&status, STATUS)
    }
    if service.waiting_code != 0 {
        text_buffer.append(&status, " │ a new keyboard: type ")
        text_buffer.append_unsigned(&status, cast[u64](service.waiting_code))
        text_buffer.append(&status, " and Enter on it")
    }
    else if !service.attention && service.setup == .Off && view(service).asking {
        append_asking(&status, &view(service).ask)
    }
    else if service.panic_count > 0 && !service.panic_seen {
        text_buffer.append(&status, " │ the boot before stopped: Ctrl+Alt+Delete")
    }
    screen.set_status(&view(service).screen, text_buffer.as_string(&status))
    draw_status(service)
}

// The status line, on the top row, inverse, with the cursor put back where it was.
draw_status :: fn(service: ptr[mut Service]) {
    storage : u8[384]
    out := text_buffer.make(storage)
    vt.append_save_cursor(&out)
    vt.append_move(&out, 0, 0)
    vt.append_style(&out, terminal.Style.{attributes = terminal.INVERSE})
    status :: screen.status_text(&view(service).screen)
    if status.count > 0 {
        text_buffer.append(&out, string_of(&status[0], status.count))
    }
    vt.append_clear_to_end(&out)
    vt.append_style(&out, terminal.Style.{})
    vt.append_restore_cursor(&out)
    emit(service, string_bytes(text_buffer.as_string(&out)))
    view(service).screen.status_dirty = false
}

/*
 * The secure attention key's screen: drawn over the program's rows, with the status line saying so. Nothing a program
 * writes is shown until it's left, though the screen model keeps it.
 */
enter_attention :: fn(service: ptr[mut Service]) {
    if service.attention {
        return void
    }
    service.attention = true
    service.panic_seen = true
    runtime.log_info("secure attention")
    update_status(service)
    // What's waiting for the user first: the powerbox's request
    if view(service).asking {
        if view(service).ask.kind == .Account {
            enter_elevation(service)
        }
        else {
            enter_chooser(service)
        }
        return void
    }
    list_programs(service)
    service.chosen = 0
    draw_panel(service)
}

/*
 * The panel: what's waiting (nothing, until the powerbox), the boot before's panic if it stopped for one, and the
 * console's programs with their memory, those that didn't answer a Ping marked, the chosen one inverse.
 */
draw_panel :: fn(service: ptr[mut Service]) {
    screen.show_panel(&view(service).screen, true)
    panel :: &view(service).screen.panel
    bold :: terminal.Style.{attributes = terminal.BOLD}
    plain :: terminal.Style.{}
    chosen_style :: terminal.Style.{attributes = terminal.INVERSE}
    screen.write_at(panel, 1, 2, "Secure attention", bold)
    if view(service).logged_in && view(service).user_count > 0 && view(service).user_count <= view(service).user.count {
        storage : u8[96]
        line := text_buffer.make(storage)
        text_buffer.append(&line, "Nothing is waiting for you. This is ")
        text_buffer.append(&line, string_of(&view(service).user[0], view(service).user_count))
        text_buffer.append(&line, "'s session.")
        screen.write_at(panel, 3, 2, text_buffer.as_string(&line), plain)
    }
    else {
        screen.write_at(panel, 3, 2, "Nothing is waiting for you: no prompt, and no one has logged in.", plain)
    }
    if service.panic_count > 0 && service.panic_count <= service.panic.count {
        screen.write_at(panel, 4, 2, "The boot before stopped for a fault: ", plain)
        screen.write_at(panel, 5, 4, string_of(&service.panic[0], service.panic_count), plain)
    }
    if service.session_end == NONE {
        screen.write_at(panel, PROGRAMS_ROW, 2, "No programs to show.", plain)
    }
    else {
        screen.write_at(panel, PROGRAMS_ROW, 2, if service.program_count == 0 { "No programs running on the console." }
            else { "Programs on the console:" }, plain)
    }
    for &program, i in service.programs {
        if i >= service.program_count {
            break
        }
        storage : u8[96]
        line := text_buffer.make(storage)
        text_buffer.append(&line, session.name_of(program))
        loop {
            text_buffer.append_byte(&line, cast[u8](' '))
        }
        while text_buffer.as_string(&line).count < 18
        text_buffer.append_unsigned(&line, program.memory / 1024)
        text_buffer.append(&line, " KiB of ")
        text_buffer.append_unsigned(&line, program.memory_limit / 1024)
        text_buffer.append(&line, " KiB")
        if program.responding == 0 {
            text_buffer.append(&line, "   not responding")
        }
        screen.write_at(panel, PROGRAMS_ROW + 1 + cast[u16](i), 4, text_buffer.as_string(&line), if i == service.chosen { chosen_style } else { plain })
    }
    help :: PROGRAMS_ROW + 2 + cast[u16](service.program_count)
    screen.write_at(panel, help, 2, if service.program_count > 0 { "Up and Down choose, E ends the one chosen, Esc or Enter goes back." }
        else { "Esc or Enter goes back." }, plain)
    // The sessions' keys, those that do something here
    if service.accounts_end != NONE && view(service).logged_in && view(service).user_count > 0 {
        if view(service).home_end != NONE {
            screen.write_at(panel, help + 2, 2, "G shows what you've let programs keep, H shares a volume with another user.", plain)
        }
        screen.write_at(panel, help + 1, 2, if another_session(service) != NO_VIEW { "S switches session, N logs in another, L locks, O logs out." }
            else { "N logs in another session, L locks, O logs out." }, plain)
    }
    redraw(service)
}

// The session's programs, asked for; none without a session channel, or if it doesn't answer.
list_programs :: fn(service: ptr[mut Service]) {
    service.program_count = 0
    reply :: ask_session(service, .List(view(service).session)) or_return void
    into :: &reply
    match os.message_of[session.Response](into)^ {
        case Programs(given) => {
            for program in os.items(into, given) {
                if service.program_count < service.programs.count {
                    service.programs[service.program_count] = program
                    service.program_count += 1
                }
            }
        }
        case _ => {}
    }
}

// The chosen program ended, and the list asked for again.
end_chosen :: fn(service: ptr[mut Service]) {
    if service.chosen >= service.program_count || service.chosen >= service.programs.count {
        return void
    }
    program :: service.programs[service.chosen]
    runtime.log_info("ending % on the console's request", session.name_of(&program))
    _ = ask_session(service, .End(program.index))
    list_programs(service)
    if service.chosen >= service.program_count && service.chosen > 0 {
        service.chosen = service.program_count - 1
    }
    draw_panel(service)
}

// request, sent on the session channel, and its answer waited for; null without one.
ask_session :: fn(service: ptr[mut Service], request: session.Request) -> os.Incoming? {
    if service.session_end == NONE {
        return null
    }
    out := os.Outgoing.{}
    os.begin[session.Request](&out)^ = request
    if session.send_request(service.session_end, service.session_port, &out) != null {
        return null
    }
    into := os.Incoming.{}
    loop {
        match session.receive_response(service.session_end, service.session_port, &into, true) {
            case Received => return into
            case Failed(error) => return null
            case _ => continue
        }
    }
}

// The first line of the boot before's panic record, without where in the kernel, as the root task logs it.
keep_panic :: fn(service: ptr[mut Service], last_panic: slop_os.Memory?) {
    record :: last_panic or_return void
    text :: service_kit.text_of(slop_os.startup_block(), record) or_return void
    first := text
    for character, i in text {
        if character == '\n' {
            first = text[0..<i]
            break
        }
    }
    for character, i in first {
        end :: i + 4
        if character == ' ' && end <= first.count && i < end {
            if first[i..<end] == " at " {
                first = first[0..<i]
                break
            }
        }
    }
    for byte in string_bytes(first) {
        if service.panic_count < service.panic.count {
            service.panic[service.panic_count] = byte
            service.panic_count += 1
        }
    }
    runtime.log_info("showing the boot before's fault: %", first)
}

// Back from the secure attention key's screen: the program's rows drawn again from the screen model.
leave_attention :: fn(service: ptr[mut Service]) {
    if !service.attention {
        return void
    }
    service.attention = false
    service.choosing = false
    service.granting = false
    runtime.log_info("secure attention ended")
    update_status(service)
    screen.show_panel(&view(service).screen, false)
    redraw(service)
}

/*
 * Every row of what's shown, the panel or the program's, from the screen model, each up to its last cell that isn't
 * blank, then cleared; and the cursor where the program left it.
 */
redraw :: fn(service: ptr[mut Service]) {
    redraw_rows(service, 0, PROGRAM_ROWS)
}

// Rows first to last, not including last, of what's shown, as redraw draws them; and the cursor where it is.
redraw_rows :: fn(service: ptr[mut Service], first: u16, last_row: u16) {
    grid :: screen.shown(&view(service).screen)
    plain :: terminal.Style.{}
    for row in first..<(if last_row < PROGRAM_ROWS { last_row } else { PROGRAM_ROWS }) {
        storage : u8[2048]
        out := text_buffer.make(storage)
        vt.append_move(&out, row + 1, 0)
        current := plain
        // The row's last cell that shows something, or its style does
        last : u16 = 0
        for column in 0..<COLUMNS {
            found :: screen.cell(grid, row, column) or_break
            if found.count > 0 || !same_style(found.style, plain) {
                last = column + 1
            }
        }
        for column in 0..<last {
            cell :: screen.cell(grid, row, column) or_break
            if cell.width == 0 && cell.count == 0 && column > 0 {
                // The second column of a wide cluster, or a blank after one; blanks are spaces
                previous :: screen.cell(grid, row, column - 1) or_break
                if previous.width == 2 {
                    continue
                }
            }
            if !same_style(cell.style, current) {
                vt.append_style(&out, cell.style)
                current = cell.style
            }
            if cell.count == 0 {
                text_buffer.append_byte(&out, cast[u8](' '))
            }
            else if cast[usize](cell.count) <= cell.bytes.count {
                text_buffer.append(&out, string_of(&cell.bytes[0], cast[usize](cell.count)))
            }
        }
        vt.append_style(&out, plain)
        vt.append_clear_to_end(&out)
        emit(service, string_bytes(text_buffer.as_string(&out)))
    }
    storage : u8[32]
    out := text_buffer.make(storage)
    vt.append_move(&out, grid.row + 1, grid.column)
    emit(service, string_bytes(text_buffer.as_string(&out)))
}

// A program's output for the serial line, unless the secure attention key's screen is up.
emit_program :: fn(service: ptr[mut Service], out: ptr[text_buffer.TextBuffer]) {
    if !service.attention && service.setup == .Off && is_shown(service) {
        emit(service, string_bytes(text_buffer.as_string(out)))
    }
}

// bytes, queued for the serial line; what doesn't fit the queue is dropped. Without a serial line nothing is kept.
emit :: fn(service: ptr[mut Service], bytes: u8[]) {
    if cast[slop_os.Handle](service.serial_connector) == slop_os.NO_HANDLE {
        return void
    }
    for byte in bytes {
        if service.output_count >= service.output.count {
            return void
        }
        at :: (service.output_start + service.output_count) % service.output.count
        if at < service.output.count {
            service.output[at] = byte
        }
        service.output_count += 1
    }
}

// Writes on the serial line from the queue, while it has room for them.
pump :: fn(service: ptr[mut Service]) {
    if cast[slop_os.Handle](service.line_end) == slop_os.NO_HANDLE {
        return void
    }
    loop {
        if service.output_count == 0 || service.in_flight >= MAX_IN_FLIGHT {
            break
        }
        chunk : u8[serial.MAX_BYTES]
        taken :: if service.output_count < chunk.count { service.output_count } else { chunk.count }
        for i in 0..<taken {
            at :: (service.output_start + i) % service.output.count
            if at < service.output.count && i < chunk.count {
                chunk[i] = service.output[at]
            }
        }
        out := os.Outgoing.{}
        request :: os.begin[serial.Request](&out)
        request^ = .Write(os.append(&out, chunk[0..<taken]))
        if serial.send_request(service.line_end, service.port, &out) != null {
            break
        }
        service.in_flight += 1
        service.output_start = (service.output_start + taken) % service.output.count
        service.output_count -= taken
    }
}

/*
 * Another Read, held by the driver until something's typed, unless one's waiting: for as many bytes as the decoded
 * input has room for events, each byte at most one, so typing faster than a client reads waits in the driver rather than
 * being dropped here; with too little room, it's asked once a delivery makes some.
 */
read_more :: fn(service: ptr[mut Service]) {
    if service.line_end == NONE || service.line_reading || service.decoded.count + FEED_SLICE > service.decoded.events.count {
        return void
    }
    room :: service.decoded.events.count - service.decoded.count
    out := os.Outgoing.{}
    request :: os.begin[serial.Request](&out)
    request^ = .Read(cast[u32](if room < cast[usize](serial.MAX_BYTES) { room } else { cast[usize](serial.MAX_BYTES) }))
    service.line_reading = serial.send_request(service.line_end, service.port, &out) is_none
}

// A Read to the input service, unless one's waiting.
read_seat :: fn(service: ptr[mut Service]) {
    if service.seat_end == NONE || service.seat_reading {
        return void
    }
    out := os.Outgoing.{}
    request :: os.begin[seat.Request](&out)
    request^ = .Read(seat.MAX_EVENTS)
    service.seat_reading = seat.send_request(service.seat_end, service.port, &out) is_none
}

// What the serial line answered: Writes taken, and bytes typed, decoded. A line that's gone, dialed again.
take_serial :: fn(service: ptr[mut Service], into: ptr[mut os.Incoming]) {
    if cast[slop_os.Handle](service.line_end) == slop_os.NO_HANDLE {
        return void
    }
    loop {
        match serial.receive_response(service.line_end, service.port, into, false) {
            case Received => {}
            case Empty => return void
            case Failed(error) => {
                _ = slop_os.handle_close(cast[slop_os.Handle](service.line_end))
                service.line_end = NONE
                service.line_reading = false
                runtime.log_info("its serial line went; dialing again")
                dial_serial(service)
                // Read the new one until it's empty, since only a read that finds nothing has its next answer wake the port
                if cast[slop_os.Handle](service.line_end) == slop_os.NO_HANDLE {
                    return void
                }
                continue
            }
            case _ => continue
        }
        match os.message_of[serial.Response](into)^ {
            case Written(_) => {
                service.in_flight = if service.in_flight > 0 { service.in_flight - 1 } else { cast[u32](0) }
                pump(service)
            }
            case Data(given) => {
                service.line_reading = false
                // A slice at a time, each slice's keys looked at before the next: what the trusted path's screens take
                // is gone once they've taken it, so typing faster than events are held loses none of theirs
                bytes :: os.items(into, given)
                at : usize = 0
                loop {
                    if at >= bytes.count {
                        break
                    }
                    end :: if bytes.count - at > FEED_SLICE { at + FEED_SLICE } else { bytes.count }
                    if end > bytes.count || at > end {
                        break
                    }
                    first :: service.decoded.count
                    vt.feed(&service.decoder, bytes[at..<end], &service.decoded)
                    if end == bytes.count {
                        vt.finish(&service.decoder, &service.decoded)
                    }
                    screen_keys(service, first)
                    at = end
                }
                read_more(service)
            }
            case _ => {}
        }
    }
}

/*
 * The events decoded from first on, checked before anything reads them: the secure attention key brings up its screen,
 * and while that's up every key is its own, so none of them reach a program.
 */
screen_keys :: fn(service: ptr[mut Service], first: usize) {
    decoded :: &service.decoded
    for i in first..<decoded.count {
        if i >= decoded.events.count {
            break
        }
        event :: decoded.events[i]
        if event.kind != cast[u8](terminal.EventKind.Key) {
            continue
        }
        if service.setup != .Off {
            // Setup is the trusted path's already: the secure attention key brings up nothing over it
            start :: cast[usize](event.text_start)
            end :: start + cast[usize](event.text_bytes)
            text :: if start <= end && end <= decoded.text_count && end <= decoded.text.count { decoded.text[start..<end] } else { decoded.text[0..<0] }
            setup_key(service, event, text)
            continue
        }
        if event.code == USAGE_DELETE && event.modifiers & (terminal.CONTROL | terminal.ALT) == terminal.CONTROL | terminal.ALT {
            enter_attention(service)
            continue
        }
        if !service.attention {
            continue
        }
        if service.choosing {
            start :: cast[usize](event.text_start)
            end :: start + cast[usize](event.text_bytes)
            text :: if start <= end && end <= decoded.text_count && end <= decoded.text.count { decoded.text[start..<end] } else { decoded.text[0..<0] }
            chooser_key(service, event, text)
            if !service.attention {
                // Answered: what came after is the program's again, but for what's in this batch
                drop_from(service, first)
                return void
            }
            continue
        }
        if service.granting {
            grants_key(service, event)
            continue
        }
        if event.code == USAGE_ESCAPE || event.code == USAGE_ENTER {
            leave_attention(service)
        }
        else if event.code == USAGE_UP && service.chosen > 0 {
            service.chosen -= 1
            draw_panel(service)
        }
        else if event.code == USAGE_DOWN && service.chosen + 1 < service.program_count {
            service.chosen += 1
            draw_panel(service)
        }
        else if (event.code == USAGE_E || event.code == USAGE_DELETE) && event.modifiers & (terminal.CONTROL | terminal.ALT) == 0 {
            end_chosen(service)
        }
        else if event.code == USAGE_G && event.modifiers & (terminal.CONTROL | terminal.ALT) == 0 {
            enter_grants(service)
        }
        else if event.code == USAGE_H && event.modifiers & (terminal.CONTROL | terminal.ALT) == 0 {
            enter_share_form(service)
        }
        else if event.modifiers & (terminal.CONTROL | terminal.ALT) == 0 && session_key(service, event.code) {
            // A session's key: the screen it brought up takes what comes after
            drop_from(service, first)
            return void
        }
    }
    // What came with the key, or while its screen or setup's was up, is the trusted path's, and isn't kept
    if service.attention || service.setup != .Off || attention_in(decoded, first) {
        drop_from(service, first)
    }
}

// Whether a Ctrl+Alt+Delete is among the events from first on.
attention_in :: fn(decoded: ptr[vt.Decoded], first: usize) -> bool {
    for i in first..<decoded.count {
        if i < decoded.events.count && decoded.events[i].kind == cast[u8](terminal.EventKind.Key) && decoded.events[i].code == USAGE_DELETE
            && decoded.events[i].modifiers & (terminal.CONTROL | terminal.ALT) == terminal.CONTROL | terminal.ALT {
            return true
        }
    }
    return false
}

// The events from first on taken back, with their text, as if they'd never come.
drop_from :: fn(service: ptr[mut Service], first: usize) {
    decoded :: &service.decoded
    if first >= decoded.count {
        return void
    }
    text_from :: if first < decoded.events.count { cast[usize](decoded.events[first].text_start) } else { decoded.text_count }
    decoded.count = first
    if text_from <= decoded.text_count {
        decoded.text_count = text_from
    }
}

/*
 * What the input service gave: keys, typed into the input; the secure attention key; and a new keyboard's code, shown
 * on the status line until it's typed. A seat that's gone is dialed again.
 */
take_seat :: fn(service: ptr[mut Service], into: ptr[mut os.Incoming]) {
    if cast[slop_os.Handle](service.seat_end) == slop_os.NO_HANDLE {
        return void
    }
    loop {
        match seat.receive_response(service.seat_end, service.port, into, false) {
            case Received => {}
            case Empty => return void
            case Failed(error) => {
                _ = slop_os.handle_close(cast[slop_os.Handle](service.seat_end))
                service.seat_end = NONE
                service.seat_reading = false
                runtime.log_info("the input service went; dialing again")
                dial_seat(service)
                if cast[slop_os.Handle](service.seat_end) == slop_os.NO_HANDLE {
                    return void
                }
                continue
            }
            case _ => continue
        }
        match os.message_of[seat.Response](into)^ {
            case Input(given) => {
                service.seat_reading = false
                text :: os.items(into, given.text)
                for event in os.items(into, given.events) {
                    take_seat_event(service, event, text)
                }
                take_typed(service)
                read_seat(service)
            }
            case _ => {}
        }
    }
}

// The most keys kept waiting for room among the decoded input, and their text's bytes; and the most text one key has.
TYPED_KEYS :: 256
TYPED_TEXT :: 1024
KEY_TEXT :: 8

take_seat_event :: fn(service: ptr[mut Service], event: seat.Event, text: u8[]) {
    kind :: seat.kind_of(event) or_return void
    match kind {
        case .SecureAttention => {
            if service.setup == .Off {
                // Keys typed before it are for what was shown, not the trusted path
                service.typed_count = 0
                service.typed_text_count = 0
                enter_attention(service)
            }
        }
        case .Waiting => {
            service.waiting_code = event.waiting_code
            update_status(service)
        }
        case .Accepted => {
            service.waiting_code = 0
            update_status(service)
        }
        case .Key => {
            // Kept in order behind any waiting, its text with it; past what's kept, dropped
            start :: cast[usize](event.text_start)
            end :: start + cast[usize](event.text_bytes)
            typed :: if start <= end && end <= text.count { text[start..<end] } else { text[0..<0] }
            if service.typed_count >= service.typed.count || typed.count > service.typed_text.count - service.typed_text_count {
                return void
            }
            kept := event
            kept.text_start = cast[u32](service.typed_text_count)
            for byte in typed {
                if service.typed_text_count < service.typed_text.count {
                    service.typed_text[service.typed_text_count] = byte
                    service.typed_text_count += 1
                }
            }
            if service.typed_count < service.typed.count {
                service.typed[service.typed_count] = kept
                service.typed_count += 1
            }
        }
    }
}

/*
 * The keys waiting decoded, in order, as many as the decoded input has room for: the rest wait for a delivery to make
 * some, so a burst of typing longer than one delivery isn't lost. The screens the trusted path shows take theirs.
 */
take_typed :: fn(service: ptr[mut Service]) {
    decoded :: &service.decoded
    first :: decoded.count
    taken : usize = 0
    for event in service.typed {
        // Room for the event, and for its text, at most a key's
        if taken >= service.typed_count || decoded.count >= decoded.events.count || decoded.text_count + KEY_TEXT > decoded.text.count {
            break
        }
        taken += 1
        if event.code == USAGE_C && event.modifiers & terminal.CONTROL != 0 {
            vt.event(decoded, terminal.event_of(.Interrupt))
            continue
        }
        start :: cast[usize](event.text_start)
        end :: start + cast[usize](event.text_bytes)
        typed :: if start <= end && end <= service.typed_text_count && end <= service.typed_text.count { service.typed_text[start..<end] }
            else { service.typed_text[0..<0] }
        vt.key(decoded, event.code, event.modifiers, typed)
    }
    if taken == 0 {
        return void
    }
    // Those left moved to the front, their text with them
    text_from :: if taken < service.typed_count && taken < service.typed.count { cast[usize](service.typed[taken].text_start) }
        else { service.typed_text_count }
    left :: service.typed_count - taken
    for i in 0..<left {
        from :: i + taken
        if from < service.typed.count && i < service.typed.count {
            moved := service.typed[from]
            moved.text_start = if cast[usize](moved.text_start) >= text_from { moved.text_start - cast[u32](text_from) } else { 0 }
            service.typed[i] = moved
        }
    }
    text_left :: if text_from <= service.typed_text_count { service.typed_text_count - text_from } else { cast[usize](0) }
    for i in 0..<text_left {
        from :: i + text_from
        if from < service.typed_text.count && i < service.typed_text.count {
            service.typed_text[i] = service.typed_text[from]
        }
    }
    service.typed_count = left
    service.typed_text_count = text_left
    screen_keys(service, first)
}

/*
 * The input waiting, to the owner, once it holds a Read: as many events as it asked for, and as fit its connection's
 * ring, halved until they do; those after wait for its next Read.
 */
deliver :: fn(service: ptr[mut Service], connected: ptr[service_kit.Clients]) {
    if service.decoded.count == 0 || view(service).held == 0 || service.attention || service.setup != .Off {
        return void
    }
    owner :: view(service).owner or_return void
    if owner >= connected.ends.count {
        return void
    }
    end :: connected.ends[owner]
    decoded :: &service.decoded
    count := if decoded.count < cast[usize](view(service).held) { decoded.count } else { cast[usize](view(service).held) }
    loop {
        if count == 0 || count > decoded.events.count || decoded.text_count > decoded.text.count {
            return void
        }
        // The text up to the next event's
        text_end :: if count < decoded.count && count < decoded.events.count { cast[usize](decoded.events[count].text_start) } else { decoded.text_count }
        if text_end > decoded.text_count {
            return void
        }
        out := os.Outgoing.{}
        response :: os.begin[terminal.Response](&out)
        response^ = .Input(terminal.Events.{events = os.append(&out, decoded.events[0..<count]), text = os.append(&out, decoded.text[0..<text_end])})
        match terminal.send_response(end, service.port, &out) {
            case Some(failure) => {
                if failure != .TooBig || count == 1 {
                    return void
                }
                count /= 2
            }
            case None => break
        }
    }
    view(service).held = 0
    keep_after(service, count)
}

// The decoded events after the first count, with their text, kept for the next Read; none left, the decoder reset.
keep_after :: fn(service: ptr[mut Service], count: usize) {
    decoded :: &service.decoded
    if count >= decoded.count || count >= decoded.events.count {
        vt.reset(&service.decoder, decoded)
        return void
    }
    text_from :: cast[usize](decoded.events[count].text_start)
    if text_from > decoded.text_count || decoded.text_count > decoded.text.count {
        vt.reset(&service.decoder, decoded)
        return void
    }
    left :: decoded.count - count
    for i in 0..<left {
        from :: i + count
        if from < decoded.events.count && i < decoded.events.count {
            moved := decoded.events[from]
            moved.text_start = if cast[usize](moved.text_start) >= text_from { moved.text_start - cast[u32](text_from) } else { 0 }
            decoded.events[i] = moved
        }
    }
    text_left :: decoded.text_count - text_from
    for i in 0..<text_left {
        from :: i + text_from
        if from < decoded.text.count && i < decoded.text.count {
            decoded.text[i] = decoded.text[from]
        }
    }
    decoded.count = left
    decoded.text_count = text_left
}

// ---- First-boot setup (decisions/0148)

// The account service through its connector, if there's one: bound to the port, and asked how many accounts there are.
dial_accounts :: fn(service: ptr[mut Service]) {
    if service.accounts_connector == NONE {
        return void
    }
    port :: os.port_for(slop_os.startup_block().budget, service.accounts_connector) or_return void
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    connection :: connector.dial[accounts.Accounts](service.accounts_connector, port) or_return void
    signals :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    if slop_os.port_bind(service.port, cast[slop_os.Handle](connection.end), signals, ACCOUNTS_KEY, .Persistent) is_error {
        _ = slop_os.handle_close(cast[slop_os.Handle](connection.end))
        return void
    }
    service.accounts_end = connection.end
    out := os.Outgoing.{}
    os.begin[accounts.Request](&out)^ = .Describe
    _ = accounts.send_request(service.accounts_end, service.port, &out)
}

// What the account service answered: how many accounts there are, and how making the first went. One that's gone,
// dialed again.
take_accounts :: fn(service: ptr[mut Service], into: ptr[mut os.Incoming]) {
    if service.accounts_end == NONE {
        return void
    }
    loop {
        match accounts.receive_response(service.accounts_end, service.port, into, false) {
            case Received => {}
            case Empty => return void
            case Failed(error) => {
                _ = slop_os.port_unbind(service.port, ACCOUNTS_KEY)
                _ = slop_os.handle_close(cast[slop_os.Handle](service.accounts_end))
                service.accounts_end = NONE
                runtime.log_info("the account service went; dialing again")
                if service.setup == .Making {
                    say(service, "The account service stopped while it made the account. Type the password again.")
                    setup_step(service, if service.elevating { SetupStep.AdminName } else { SetupStep.Password })
                }
                dial_accounts(service)
                if service.accounts_end == NONE {
                    return void
                }
                continue
            }
            case _ => continue
        }
        // The share form's answers
        if service.sharing && service.setup == .Sharing {
            match os.message_of[accounts.Response](into)^ {
                case Shared(given) => shared(service, given)
                case NoSuchAccount => {
                    say(service, "There's no account of that name, or it hasn't logged in since it was made.")
                    setup_step(service, .ShareMember)
                }
                case AlreadyExists => {
                    say(service, if service.unsharing { "They aren't in it." } else { "That's the owner, or they're in it already." })
                    setup_step(service, .ShareMember)
                }
                case NameRefused => {
                    say(service, "That can't be a volume's name. Type another.")
                    setup_step(service, .ShareName)
                }
                case Refused => {
                    say(service, "That volume isn't yours to share, or isn't open. Type another.")
                    setup_step(service, .ShareName)
                }
                case _ => {
                    say(service, "It couldn't be shared. Type the volume's name again.")
                    setup_step(service, .ShareName)
                }
            }
            continue
        }
        match os.message_of[accounts.Response](into)^ {
            case Described(status) => {
                if service.setup == .Off && !view(service).logged_in {
                    if status.accounts == 0 {
                        enter_setup(service)
                    }
                    else {
                        enter_login(service)
                    }
                }
            }
            case OpenedHome(root) => {
                if service.unlocking {
                    _ = slop_os.handle_close(cast[slop_os.Handle](root.end))
                    unlocked(service)
                }
                else {
                    logged_in(service, root)
                }
            }
            case WrongCredentials => {
                if service.elevating {
                    say(service, "That's not the administrator's name and password. Type them again.")
                    setup_step(service, .AdminName)
                }
                else if service.unlocking {
                    say(service, "That's not the password. Type it again.")
                    setup_step(service, .LoginPassword)
                }
                else {
                    say(service, "That name and password don't open an account. Type them again.")
                    setup_step(service, .LoginName)
                }
            }
            case RateLimited(wait) => {
                storage : u8[MESSAGE_BYTES]
                text := text_buffer.make(storage)
                text_buffer.append(&text, "Too many tries: wait ")
                text_buffer.append_unsigned(&text, (wait + 999_999_999) / 1_000_000_000)
                text_buffer.append(&text, " seconds, then type the password again.")
                say(service, text_buffer.as_string(&text))
                setup_step(service, if service.elevating { SetupStep.AdminName } else { SetupStep.LoginPassword })
            }
            case Created(shown) => {
                service.code = shown.text
                if !service.elevating {
                    runtime.log_info("first-boot setup: made the administrator's account")
                }
                say(service, "")
                setup_step(service, .Code)
            }
            case PasswordRefused(problem) => {
                say_problem(service, problem)
                setup_step(service, .Password)
            }
            case NameRefused => {
                say(service, "That name can't be an account's. Type another.")
                setup_step(service, .Name)
            }
            case AlreadyExists => {
                if service.elevating {
                    say(service, "There's an account of that name already. Type the administrator's name and password again.")
                    setup_step(service, .AdminName)
                }
                else {
                    leave_setup(service)
                }
            }
            case Refused => {
                if service.elevating {
                    end_elevation(service, false)
                }
                else {
                    leave_setup(service)
                }
            }
            case _ => {
                if service.elevating {
                    say(service, "The account couldn't be made. Type the administrator's name and password again.")
                    setup_step(service, .AdminName)
                }
                else if is_login(service.setup) {
                    say(service, "The session couldn't be opened. Type the password again.")
                    setup_step(service, .LoginPassword)
                }
                else {
                    say(service, "The account couldn't be made. Type the password again.")
                    setup_step(service, .Password)
                }
            }
        }
    }
}

enter_setup :: fn(service: ptr[mut Service]) {
    runtime.log_info("first-boot setup: no accounts yet")
    service.setup = .Name
    update_status(service)
    draw_setup(service, true)
}

// Setup done: the recovery code forgotten, and the login screen up.
leave_setup :: fn(service: ptr[mut Service]) {
    wipe(service.code[0..<service.code.count])
    runtime.log_info("first-boot setup ended")
    enter_login(service)
}

// The login screen (decisions/0150).
enter_login :: fn(service: ptr[mut Service]) {
    runtime.log_info("login: asking for a name and password")
    say(service, "")
    setup_step(service, .LoginName)
    update_status(service)
}

// The login screen's name and password opened the account's home: the session made with it, and the screen gone.
logged_in :: fn(service: ptr[mut Service], root: os.Channel[dir.Dir]) {
    name :: name_bytes(service)
    for byte, i in name {
        if i < view(service).user.count {
            view(service).user[i] = byte
        }
    }
    view(service).user_count = name.count
    if !start_session(service, root) {
        say(service, "The session couldn't be made. Type the password again.")
        setup_step(service, .LoginPassword)
        return void
    }
    runtime.log_info("logged in as %", string_of(&view(service).user[0], view(service).user_count))
    wipe(service.field[0..<service.field.count])
    wipe(service.password[0..<service.password.count])
    service.field_count = 0
    service.password_count = 0
    service.setup = .Off
    update_status(service)
    screen.show_panel(&view(service).screen, false)
    redraw(service)
}

/*
 * The session made by the session manager, with a terminal connection of its own, which this serves as any client, and
 * the home's root: the user's who logged in, or with no home, the one with no user of a boot with no accounts.
 */
start_session :: fn(service: ptr[mut Service], home: os.Channel[dir.Dir]?) -> bool {
    if service.session_end == NONE {
        return false
    }
    budget :: slop_os.startup_block().budget
    pair :: os.channel_for[terminal.Terminal](budget, 0) or_return false
    client :: match service_kit.add_client_index(&service.connected, service.port, pair.a) {
        case Some(added) => added
        case None => {
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.a))
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
            return false
        }
    }
    // The session's programs write to its view
    if client < service.client_view.count {
        service.client_view[client] = service.viewing
    }
    // Its powerbox asks the user through its view (decisions/0156), and the grants view reads its home (0158)
    prompts := NONE
    home_copy := NONE
    out := os.Outgoing.{}
    request :: os.begin[session.Request](&out)
    match home {
        case Some(root) => {
            home_copy = another_connection(root.end) or_else NONE
            prompt_pair :: os.channel_for[prompt.Prompt](budget, 0) or_return false
            prompts = prompt_pair.a
            request^ = .Start(session.SessionStart.{user = os.append(&out, view(service).user[0..<min_count(view(service).user_count, view(service).user.count)]),
                layout = os.append(&out, string_bytes(service.layout)), home = root, terminal = os.Channel[terminal.Terminal].{end = pair.b},
                prompts = os.Channel[prompt.Prompt].{end = prompt_pair.b}})
        }
        case None => request^ = .StartWithoutUser(os.Channel[terminal.Terminal].{end = pair.b})
    }
    if session.send_request(service.session_end, service.session_port, &out) != null {
        return false
    }
    into := os.Incoming.{}
    loop {
        match session.receive_response(service.session_end, service.session_port, &into, true) {
            case Received => break
            case Failed(error) => return false
            case _ => continue
        }
    }
    started :: match os.message_of[session.Response](&into)^ {
        case Started(number) => {
            view(service).session = number
            true
        }
        case _ => false
    }
    view(service).logged_in = started
    if home_copy != NONE {
        if started {
            view(service).home_end = home_copy
        }
        else {
            _ = slop_os.handle_close(cast[slop_os.Handle](home_copy))
        }
    }
    if prompts != NONE {
        signals :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
        if started && (slop_os.port_bind(service.port, cast[slop_os.Handle](prompts), signals, PROMPT_KEY + cast[u64](service.viewing), .Persistent) is_ok) {
            view(service).prompt_end = prompts
        }
        else {
            _ = slop_os.handle_close(cast[slop_os.Handle](prompts))
        }
    }
    if started && (home is_none) {
        runtime.log_info("a session with no user, on a boot with no accounts")
        update_status(service)
    }
    if started {
        tell_shown(service)
    }
    return started
}

// The session manager told which session is shown, none on a login screen, for its memory pressure policy (decisions/0153).
tell_shown :: fn(service: ptr[mut Service]) {
    shown :: &service.views[service.active % service.views.count]
    _ = ask_session(service, .Shown(if shown.in_use && shown.logged_in { shown.session } else { session.NO_SESSION }))
}

is_login :: fn(step: SetupStep) -> bool {
    return step == .LoginName || step == .LoginPassword || step == .LoggingIn
}

// The next keyboard layout, for the input service to type through, and shown on the status line.
next_layout :: fn(service: ptr[mut Service]) {
    layout :: keymaps.next(service.layout)
    service.layout = layout.name
    if service.seat_end != NONE {
        out := os.Outgoing.{}
        request :: os.begin[seat.Request](&out)
        request^ = .SetLayout(os.append(&out, string_bytes(layout.name)))
        _ = seat.send_request(service.seat_end, service.port, &out)
    }
    runtime.log_info("login: the % keyboard layout", layout.name)
    update_status(service)
}

// A step, its field empty, drawn.
setup_step :: fn(service: ptr[mut Service], step: SetupStep) {
    wipe(service.field[0..<service.field.count])
    service.field_count = 0
    if step == .Name || step == .Password || step == .LoginName || step == .LoginPassword {
        wipe(service.password[0..<service.password.count])
        service.password_count = 0
    }
    if step == .LoginName {
        wipe(service.name[0..<service.name.count])
        service.name_count = 0
    }
    if step == .AdminName {
        wipe(service.admin_password[0..<service.admin_password.count])
        service.admin_password_count = 0
    }
    service.setup = step
    draw_setup(service, true)
}

// One key on setup's screen: text typed into the field, Backspace taking a cluster back, Enter going on.
setup_key :: fn(service: ptr[mut Service], event: terminal.Event, text: u8[]) {
    if service.setup == .Making || service.setup == .LoggingIn {
        return void
    }
    if event.code == USAGE_F2 {
        next_layout(service)
        return void
    }
    if event.code == USAGE_ESCAPE && service.setup == .LoginName && !service.unlocking {
        abandon_login(service)
        return void
    }
    if event.code == USAGE_ESCAPE && service.elevating && service.setup != .Making && service.setup != .Code {
        end_elevation(service, false)
        return void
    }
    if service.sharing {
        if service.setup == .Sharing {
            return void
        }
        if event.code == USAGE_ESCAPE {
            end_share_form(service)
            return void
        }
        if event.code == USAGE_DELETE && service.setup == .ShareMember {
            send_share(service, true)
            return void
        }
        if event.code == USAGE_ENTER {
            share_enter(service)
            return void
        }
    }
    if event.code == USAGE_ENTER {
        setup_enter(service)
        return void
    }
    if service.setup == .Code {
        return void
    }
    if event.code == USAGE_BACKSPACE {
        if service.field_count > 0 && service.field_count <= service.field.count {
            typed :: service.field[0..<service.field_count]
            last : usize = 0
            at : usize = 0
            loop {
                end :: unicode.grapheme_end(typed, at)
                if end <= at {
                    break
                }
                last = at
                at = end
            }
            while at < service.field_count
            if last <= service.field_count && service.field_count <= service.field.count {
                wipe(service.field[last..<service.field_count])
            }
            service.field_count = last
        }
        draw_setup(service, false)
        return void
    }
    if event.modifiers & (terminal.CONTROL | terminal.ALT) != 0 {
        return void
    }
    for byte in text {
        // Only what shows: a line break or a control isn't part of a name or password
        if byte >= 0x20 && byte != 0x7f && service.field_count < service.field.count {
            service.field[service.field_count] = byte
            service.field_count += 1
        }
    }
    draw_setup(service, false)
}

// Enter: the name checked, the password checked against the rules, the two compared, and the account asked for.
setup_enter :: fn(service: ptr[mut Service]) {
    if service.field_count > service.field.count {
        return void
    }
    typed :: service.field[0..<service.field_count]
    match service.setup {
        case .Name => {
            if !account_records.valid_name(typed) {
                say(service, "A name is 1 to 32 letters, digits, - or _, and starts with a lowercase letter.")
                setup_step(service, .Name)
                return void
            }
            for byte, i in typed {
                if i < service.name.count {
                    service.name[i] = byte
                }
            }
            service.name_count = typed.count
            say(service, "")
            setup_step(service, .Password)
        }
        case .Password => {
            name :: name_bytes(service)
            match account_records.password_problem(name, typed) {
                case Some(problem) => {
                    say_problem(service, cast[u8](problem))
                    setup_step(service, .Password)
                    return void
                }
                case None => {}
            }
            for byte, i in typed {
                if i < service.password.count {
                    service.password[i] = byte
                }
            }
            service.password_count = typed.count
            say(service, "")
            setup_step(service, .Again)
        }
        case .Again => {
            if service.password_count > service.password.count || !same_bytes(typed, service.password[0..<service.password_count]) {
                say(service, "The two didn't match. Type the password again.")
                setup_step(service, .Password)
                return void
            }
            if service.elevating {
                make_account_by(service)
            }
            else {
                make_account(service)
            }
        }
        case .Code => {
            if service.elevating {
                end_elevation(service, true)
            }
            else {
                leave_setup(service)
            }
        }
        case .AdminName => {
            if typed.count == 0 || typed.count > service.admin.count {
                return void
            }
            for byte, i in typed {
                if i < service.admin.count {
                    service.admin[i] = byte
                }
            }
            service.admin_count = typed.count
            say(service, "")
            setup_step(service, .AdminPassword)
        }
        case .AdminPassword => {
            if typed.count > service.admin_password.count {
                return void
            }
            for byte, i in typed {
                if i < service.admin_password.count {
                    service.admin_password[i] = byte
                }
            }
            service.admin_password_count = typed.count
            say(service, "")
            setup_step(service, .Name)
        }
        case .LoginName => {
            if typed.count == 0 || typed.count > service.name.count {
                return void
            }
            for byte, i in typed {
                if i < service.name.count {
                    service.name[i] = byte
                }
            }
            service.name_count = typed.count
            say(service, "")
            setup_step(service, .LoginPassword)
        }
        case .LoginPassword => open_home(service, typed)
        case _ => {}
    }
}

// The account's home asked for with the name and password typed, the password forgotten once it's sent.
open_home :: fn(service: ptr[mut Service], password: u8[]) {
    if service.accounts_end == NONE || service.name_count > service.name.count {
        say(service, "The account service isn't there. Type the password again.")
        setup_step(service, .LoginPassword)
        return void
    }
    out := os.Outgoing.{}
    request :: os.begin[accounts.Request](&out)
    request^ = .OpenHome(accounts.Credentials.{name = os.append(&out, service.name[0..<service.name_count]), password = os.append(&out, password)})
    sent :: accounts.send_request(service.accounts_end, service.port, &out) == null
    for i in 0..<out.words.count {
        out.words[i] = 0
    }
    wipe(service.field[0..<service.field.count])
    service.field_count = 0
    if !sent {
        say(service, "The account service couldn't be asked. Type the password again.")
        setup_step(service, .LoginPassword)
        return void
    }
    say(service, "Opening your session.")
    setup_step(service, .LoggingIn)
}

// The account asked for, the password forgotten once it's sent.
make_account :: fn(service: ptr[mut Service]) {
    if service.accounts_end == NONE || service.name_count > service.name.count || service.password_count > service.password.count {
        say(service, "The account service isn't there. Type the password again.")
        setup_step(service, .Password)
        return void
    }
    now := cast[u64](0)
    match time.now() {
        case Ok(instant) => now = cast[u64](instant.seconds) * 1000000000 + cast[u64](instant.nanos)
        case Error(error) => {}
    }
    out := os.Outgoing.{}
    request :: os.begin[accounts.Request](&out)
    request^ = .Create(accounts.Creation.{name = os.append(&out, service.name[0..<service.name_count]),
        password = os.append(&out, service.password[0..<service.password_count]), now = now})
    sent :: accounts.send_request(service.accounts_end, service.port, &out) == null
    for i in 0..<out.words.count {
        out.words[i] = 0
    }
    wipe(service.password[0..<service.password.count])
    service.password_count = 0
    if !sent {
        say(service, "The account couldn't be asked for. Type the password again.")
        setup_step(service, .Password)
        return void
    }
    say(service, "Making the administrator's account. This takes a few seconds.")
    setup_step(service, .Making)
}

// Why a password was refused, as account_records.PasswordProblem's value.
say_problem :: fn(service: ptr[mut Service], problem: u8) {
    say(service, if problem == 1 { "A password needs at least 8 characters." }
        else if problem == 2 { "That password is too long: 256 bytes at most." }
        else if problem == 3 { "That password is one of the most common ones. Choose another." }
        else if problem == 4 { "A password can't be the account's name." }
        else { "That password can't be used. Choose another." })
}

say :: fn(service: ptr[mut Service], text: string) {
    service.message_count = 0
    for byte in string_bytes(text) {
        if service.message_count < service.message.count {
            service.message[service.message_count] = byte
            service.message_count += 1
        }
    }
}

/*
 * Setup's screen: what it's for, the name, the password and it again as dots, what it last said, and once the account's
 * made, the recovery code; the cursor at the field being typed. All of it drawn, or as keys are typed, only the fields'
 * rows and the message's, which is all a key changes.
 */
draw_setup :: fn(service: ptr[mut Service], whole: bool) {
    panel :: &view(service).screen.panel
    if whole {
        screen.show_panel(&view(service).screen, true)
    }
    else {
        screen.clear(panel, terminal.Area.{row = SETUP_FIELDS_ROW, columns = COLUMNS, rows = 5})
    }
    bold :: terminal.Style.{attributes = terminal.BOLD}
    plain :: terminal.Style.{}
    if service.elevating {
        draw_elevation(service, whole)
        return void
    }
    if service.sharing {
        draw_share_form(service, whole)
        return void
    }
    if is_login(service.setup) {
        draw_login(service, whole)
        return void
    }
    screen.write_at(panel, 1, 2, "First-boot setup", bold)
    if service.setup == .Code {
        screen.write_at(panel, 3, 2, "The administrator's account is made. Its recovery code, shown this once:", plain)
        screen.write_at(panel, 5, 6, string_of(&service.code[0], service.code.count), bold)
        screen.write_at(panel, 7, 2, "Write it down, and keep it apart from this computer: it opens the account if", plain)
        screen.write_at(panel, 8, 2, "the password is lost.", plain)
        screen.write_at(panel, 10, 2, "Press Enter once you have.", plain)
        panel.row = 10
        panel.column = 28
        redraw(service)
        return void
    }
    name_row :: SETUP_FIELDS_ROW
    screen.write_at(panel, 3, 2, "No one has an account on this computer yet. Make the administrator's account:", plain)
    screen.write_at(panel, 4, 2, "the first, and the one that can make others.", plain)
    screen.write_at(panel, name_row, 2, "Name:", plain)
    screen.write_at(panel, name_row + 1, 2, "Password:", plain)
    screen.write_at(panel, name_row + 2, 2, "Again:", plain)
    field_column : u16 = 13
    if service.setup == .Name {
        if service.field_count <= service.field.count && service.field_count > 0 {
            screen.write_at(panel, name_row, field_column, string_of(&service.field[0], service.field_count), plain)
        }
    }
    else if service.name_count > 0 && service.name_count <= service.name.count {
        screen.write_at(panel, name_row, field_column, string_of(&service.name[0], service.name_count), plain)
    }
    if service.setup == .Again || service.setup == .Making {
        dots(panel, name_row + 1, field_column, if service.setup == .Making { 8 } else { clusters(password_bytes(service)) })
    }
    if service.setup == .Password || service.setup == .Again {
        dots(panel, if service.setup == .Password { name_row + 1 } else { name_row + 2 }, field_column,
            clusters(field_bytes(service)))
    }
    if service.message_count > 0 && service.message_count <= service.message.count {
        screen.write_at(panel, name_row + 4, 2, string_of(&service.message[0], service.message_count), plain)
    }
    screen.write_at(panel, name_row + 6, 2, "Enter goes on, Backspace takes back what was typed last.", plain)
    // The cursor at the end of the field being typed
    panel.row = if service.setup == .Name { name_row } else if service.setup == .Password { name_row + 1 } else { name_row + 2 }
    shown :: if service.setup == .Name { cast[u16](min_count(service.field_count, 40)) }
        else { cast[u16](min_count(clusters(field_bytes(service)), 40)) }
    panel.column = field_column + shown
    if whole {
        redraw(service)
    }
    else {
        redraw_rows(service, SETUP_FIELDS_ROW, SETUP_FIELDS_ROW + 5)
    }
}

/*
 * The login screen: the name, the password as dots, what it last said, and how to change the keyboard layout, which the
 * status line shows; drawn whole, or only its fields and message.
 */
draw_login :: fn(service: ptr[mut Service], whole: bool) {
    panel :: &view(service).screen.panel
    bold :: terminal.Style.{attributes = terminal.BOLD}
    plain :: terminal.Style.{}
    name_row :: SETUP_FIELDS_ROW
    field_column : u16 = 13
    if service.unlocking {
        screen.write_at(panel, 1, 2, "Locked", bold)
        screen.write_at(panel, 3, 2, "The console is locked. Type the session's password to unlock it.", plain)
    }
    else {
        screen.write_at(panel, 1, 2, "Log in", bold)
        screen.write_at(panel, 3, 2, "Type your account's name and password.", plain)
    }
    screen.write_at(panel, name_row, 2, "Name:", plain)
    screen.write_at(panel, name_row + 1, 2, "Password:", plain)
    typed :: field_bytes(service)
    if service.setup == .LoginName {
        if typed.count > 0 {
            screen.write_at(panel, name_row, field_column, string_of(&typed[0], typed.count), plain)
        }
    }
    else {
        name :: name_bytes(service)
        if name.count > 0 {
            screen.write_at(panel, name_row, field_column, string_of(&name[0], name.count), plain)
        }
        dots(panel, name_row + 1, field_column, if service.setup == .LoggingIn { 8 } else { clusters(typed) })
    }
    if service.message_count > 0 && service.message_count <= service.message.count {
        screen.write_at(panel, name_row + 4, 2, string_of(&service.message[0], service.message_count), plain)
    }
    screen.write_at(panel, name_row + 6, 2, "Enter goes on, Backspace takes back what was typed last, F2 changes the layout.", plain)
    if !service.unlocking && another_session(service) != NO_VIEW {
        screen.write_at(panel, name_row + 7, 2, "Esc goes back to the session you came from.", plain)
    }
    panel.row = if service.setup == .LoginName { name_row } else { name_row + 1 }
    panel.column = field_column + cast[u16](min_count(if service.setup == .LoginName { typed.count } else { clusters(typed) }, 40))
    if whole {
        redraw(service)
    }
    else {
        redraw_rows(service, SETUP_FIELDS_ROW, SETUP_FIELDS_ROW + 5)
    }
}

// What's typed in the field, the name and the password so far, as far as they're in their buffers.
field_bytes :: fn(service: ptr[Service]) -> u8[] {
    return if service.field_count <= service.field.count { service.field[0..<service.field_count] } else { service.field[0..<0] }
}

name_bytes :: fn(service: ptr[Service]) -> u8[] {
    return if service.name_count <= service.name.count { service.name[0..<service.name_count] } else { service.name[0..<0] }
}

password_bytes :: fn(service: ptr[Service]) -> u8[] {
    return if service.password_count <= service.password.count { service.password[0..<service.password_count] } else { service.password[0..<0] }
}

// count dots in a row, for a password's clusters, up to 40.
dots :: fn(panel: ptr[mut screen.Grid], row: u16, column: u16, count: usize) {
    for i in 0..<min_count(count, 40) {
        screen.write_at(panel, row, column + cast[u16](i), "•", terminal.Style.{})
    }
}

clusters :: fn(bytes: u8[]) -> usize {
    count : usize = 0
    at : usize = 0
    loop {
        if at >= bytes.count {
            break
        }
        end :: unicode.grapheme_end(bytes, at)
        if end <= at {
            break
        }
        at = end
        count += 1
    }
    return count
}

min_count :: fn(a: usize, b: usize) -> usize {
    return if a < b { a } else { b }
}

same_bytes :: fn(a: u8[], b: u8[]) -> bool {
    if a.count != b.count {
        return false
    }
    for byte, i in a {
        if i < b.count && byte != b[i] {
            return false
        }
    }
    return true
}

wipe :: fn(bytes: mut u8[]) {
    for i in 0..<bytes.count {
        bytes[i] = 0
    }
}

// ---- Sessions' views (decisions/0151)

// A view made ready for a session: blank, its lines written at the bottom, as a serial line's are, and scroll up.
open_view :: fn(service: ptr[mut Service], index: usize) {
    if index >= service.views.count {
        return void
    }
    view :: &service.views[index]
    view^ = View.{in_use = true}
    view.screen.lines.row = PROGRAM_ROWS - 1
    screen.set_status(&view.screen, STATUS)
    screen.mark_all(&view.screen.lines)
}

// The view in use: the session's whose client is being served, or the active one.
view :: fn(service: ptr[mut Service]) -> ptr[mut View] {
    return &service.views[service.viewing % service.views.count]
}

// The view client index writes to used: its session's, or with none, the active one's.
use_view_of :: fn(service: ptr[mut Service], index: usize) {
    which :: if index < service.client_view.count { service.client_view[index] } else { NO_VIEW }
    service.viewing = if which < service.views.count && service.views[which].in_use { which } else { service.active }
}

use_active :: fn(service: ptr[mut Service]) {
    service.viewing = service.active
}

// Whether the view in use is the one shown.
is_shown :: fn(service: ptr[Service]) -> bool {
    return service.viewing == service.active
}

// One of the session keys on the secure attention key's screen, done: whether it was one.
session_key :: fn(service: ptr[mut Service], code: u16) -> bool {
    if code == USAGE_S {
        switch_next(service)
    }
    else if code == USAGE_N {
        log_in_another(service)
    }
    else if code == USAGE_L {
        lock(service)
    }
    else if code == USAGE_O {
        log_out(service)
    }
    else {
        return false
    }
    return true
}

// A logged-in view other than the active one, the next after it going round, or NO_VIEW.
another_session :: fn(service: ptr[Service]) -> usize {
    for step in 1..<service.views.count {
        index :: (service.active + step) % service.views.count
        if service.views[index].in_use && service.views[index].logged_in {
            return index
        }
    }
    return NO_VIEW
}

// The view at index shown, the secure attention key's screen left.
switch_to :: fn(service: ptr[mut Service], index: usize) {
    if index >= service.views.count {
        return void
    }
    service.attention = false
    screen.show_panel(&view(service).screen, false)
    service.active = index
    service.viewing = index
    screen.show_panel(&view(service).screen, false)
    update_status(service)
    redraw(service)
    tell_shown(service)
    if view(service).user_count > 0 && view(service).user_count <= view(service).user.count {
        runtime.log_info("switched to %'s session", string_of(&view(service).user[0], view(service).user_count))
    }
}

// The next session shown, if there's another.
switch_next :: fn(service: ptr[mut Service]) {
    next :: another_session(service)
    if next == NO_VIEW {
        return void
    }
    switch_to(service, next)
}

// A view of its own for another session, its login screen up; Esc there goes back.
log_in_another :: fn(service: ptr[mut Service]) {
    if service.accounts_end == NONE {
        return void
    }
    free := NO_VIEW
    for each, i in service.views {
        if !each.in_use {
            free = i
            break
        }
    }
    if free == NO_VIEW {
        return void
    }
    service.attention = false
    screen.show_panel(&view(service).screen, false)
    service.previous = service.active
    open_view(service, free)
    service.active = free
    service.viewing = free
    runtime.log_info("login: another session")
    tell_shown(service)
    enter_login(service)
}

// A login for another session given up: its view let go, and the session it was started from shown again.
abandon_login :: fn(service: ptr[mut Service]) {
    back :: if service.previous < service.views.count && service.views[service.previous].logged_in { service.previous } else { another_session(service) }
    if back == NO_VIEW || view(service).logged_in {
        return void
    }
    wipe(service.field[0..<service.field.count])
    service.field_count = 0
    service.setup = .Off
    view(service).in_use = false
    switch_to(service, back)
}

// The console locked: the session's user's password, through the account service, unlocks it.
lock :: fn(service: ptr[mut Service]) {
    if !view(service).logged_in || view(service).user_count == 0 || view(service).user_count > service.name.count {
        return void
    }
    service.attention = false
    screen.show_panel(&view(service).screen, false)
    for byte, i in view(service).user {
        if i < view(service).user_count && i < service.name.count {
            service.name[i] = byte
        }
    }
    service.name_count = view(service).user_count
    service.unlocking = true
    runtime.log_info("locked")
    say(service, "")
    service.setup = .LoginPassword
    wipe(service.field[0..<service.field.count])
    service.field_count = 0
    update_status(service)
    draw_setup(service, true)
}

// The password was right: the session shown again.
unlocked :: fn(service: ptr[mut Service]) {
    service.unlocking = false
    wipe(service.field[0..<service.field.count])
    service.field_count = 0
    service.setup = .Off
    runtime.log_info("unlocked")
    update_status(service)
    screen.show_panel(&view(service).screen, false)
    redraw(service)
}

// The active session ended: its programs, by the session manager, its connections, and its view; another shown, or the login screen.
log_out :: fn(service: ptr[mut Service]) {
    if !view(service).logged_in {
        return void
    }
    service.attention = false
    screen.show_panel(&view(service).screen, false)
    _ = ask_session(service, .EndSession(view(service).session))
    for i in 0..<service.client_view.count {
        if service.client_view[i] == service.viewing {
            service_kit.drop_client(&service.connected, i)
            service.client_view[i] = NO_VIEW
        }
    }
    gone :: service.active
    runtime.log_info("logged out")
    drop_ask(view(service))
    if view(service).prompt_end != NONE {
        _ = slop_os.handle_close(cast[slop_os.Handle](view(service).prompt_end))
        view(service).prompt_end = NONE
    }
    if view(service).home_end != NONE {
        _ = slop_os.handle_close(cast[slop_os.Handle](view(service).home_end))
        view(service).home_end = NONE
    }
    view(service).in_use = false
    next :: another_session(service)
    if next != NO_VIEW {
        switch_to(service, next)
        return void
    }
    open_view(service, gone)
    service.viewing = gone
    tell_shown(service)
    enter_login(service)
}
