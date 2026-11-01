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
 * keyboard's code, which the input service makes, is shown on the status line until it's typed on it. Both are reached
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
import connector from "../../protocols/connector"
import seat from "../../protocols/seat"
import session from "../../protocols/session"
import serial from "../../protocols/serial"
import service_kit from "../../libraries/service_kit"
import safe_text from "../../safe_text"
import screen from "../../screen"
import glyph_screen from "../../glyph_screen"
import vt from "../../vt"

// The serial line and the seat are bound to the port above the clients
SERIAL_KEY : u64 : 1000
SEAT_KEY : u64 : 1001
BANNER :: "SlopOS console"
NONE : slop_os.Channel : cast[slop_os.Channel](slop_os.NO_HANDLE)
TAB_STOP : u16 : 8
COLUMNS : u16 : screen.COLUMNS
ROWS : u16 : screen.ROWS
PROGRAM_ROWS : u16 : screen.PROGRAM_ROWS

// What the status line says: no one has logged in until sessions (10c)
STATUS :: " SlopOS │ console │ no session"
STATUS_ATTENTION :: " SlopOS │ console │ secure attention"

// Output waiting for the serial line, and how many Writes may be in flight on it, which its ring holds
OUTPUT_BYTES :: 16384
MAX_IN_FLIGHT : u32 : 2

USAGE_C : u16 : 0x06
USAGE_E : u16 : 0x08
USAGE_ENTER : u16 : 0x28
USAGE_ESCAPE : u16 : 0x29
USAGE_DELETE : u16 : 0x4c
USAGE_DOWN : u16 : 0x51
USAGE_UP : u16 : 0x52
// The panel's rows: where the list of programs starts
PROGRAMS_ROW : u16 : 7
PANIC_TEXT :: 160

Service :: struct {
    log : slop_os.DebugLog,
    port : slop_os.Port,
    // The connectors to the serial line and the input service, and the connections they gave, NONE without
    serial_connector : slop_os.Channel,
    seat_connector : slop_os.Channel,
    line_end : slop_os.Channel,
    seat_end : slop_os.Channel,
    // What's waiting to be sent on the serial line: a ring, from output_start
    output : u8[OUTPUT_BYTES],
    output_start : usize,
    output_count : usize,
    in_flight : u32,
    // What the terminal shows, and the framebuffer it's drawn on, if there's one
    screen : screen.Screen,
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
    // Input waiting for the owner: the client that read first, and how many events its Read held asks for
    decoder : vt.Decoder,
    decoded : vt.Decoded,
    owner : usize?,
    held : u32,
}

main :: fn(log: slop_os.DebugLog?, serial_line: os.Channel[connector.Connector]?, input: os.Channel[connector.Connector]?,
    framebuffer: slop_os.Memory?, framebuffer_layout: slop_os.Memory?, programs: os.Channel[session.Session]?,
    last_panic: slop_os.Memory?, clients: os.Listener[terminal.Terminal]) -> int {
    startup :: slop_os.startup_block()
    service := runtime.new(Service)
    service.log = log or_else cast[slop_os.DebugLog](slop_os.NO_HANDLE)
    service.serial_connector = NONE
    service.seat_connector = NONE
    service.line_end = NONE
    service.seat_end = NONE
    service.session_end = NONE
    match programs {
        case Some(found) => {
            service.session_end = found.end
            service.session_port = os.port_for(startup.budget, found.end) or_else cast[slop_os.Port](slop_os.NO_HANDLE)
        }
        case None => {}
    }
    keep_panic(service, last_panic)
    // Lines are written at the bottom, as a serial line's are, and scroll up
    service.screen.lines.row = PROGRAM_ROWS - 1
    screen.set_status(&service.screen, STATUS)
    update_status(service)
    screen.mark_all(&service.screen.lines)
    match canvas_on(framebuffer, framebuffer_layout) {
        case Some(made) => {
            service.canvas = made
            service.has_canvas = true
        }
        case None => {}
    }
    service.port = slop_os.port_create(startup.budget) or_return 2
    connected := service_kit.Clients.{}
    if !service_kit.add_client(&connected, service.port, clients.end) {
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
    dial_seat(service)
    dial_serial(service)
    runtime.log_info("serving")
    into := os.Incoming.{}
    loop {
        with {
            i : usize = 0
        }
        loop {
            serve(service, &connected, i, &into)
            i += 1
        }
        while i < connected.count
        take_serial(service, &into)
        take_seat(service, &into)
        deliver(service, &connected)
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
        glyph_screen.draw(&service.canvas, &service.screen, !service.attention)
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
                match service.owner {
                    case Some(owner) => {
                        if owner == index {
                            service.owner = null
                            service.held = 0
                        }
                    }
                    case None => {}
                }
                return void
            }
            case _ => continue
        }
        match os.message_of[terminal.Request](into)^ {
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
                owned :: match service.owner {
                    case Some(owner) => owner == index
                    case None => true
                }
                if owned {
                    service.owner = index
                    service.held = if most == 0 { cast[u32](1) } else { most }
                }
            }
            case Connect(connection) => {
                if !service_kit.add_client(connected, service.port, connection.end) {
                    _ = slop_os.handle_close(cast[slop_os.Handle](connection.end))
                }
            }
        }
    }
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
            screen.line_break(&service.screen)
        }
        else if safe_text.is_tab(bytes, at, end) {
            grid :: screen.current(&service.screen)
            loop {
                text_buffer.append_byte(&out, cast[u8](' '))
                screen.put(&service.screen, string_bytes(" "), 1, style)
            }
            while grid.column % TAB_STOP != 0 && grid.column < COLUMNS
        }
        else {
            shown := safe_text.Shown.{}
            safe_text.show(bytes, at, end, &shown)
            if shown.count <= shown.bytes.count {
                cluster :: shown.bytes[0..<shown.count]
                screen.put(&service.screen, cluster, shown.columns, style)
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
    screen.move(&service.screen, position.column, position.row)
    grid :: screen.current(&service.screen)
    storage : u8[32]
    out := text_buffer.make(storage)
    if service.screen.using_whole {
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
    grid :: screen.current(&service.screen)
    if !service.screen.using_whole {
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
    if !service.screen.using_whole || area.column != 0 || area.columns < COLUMNS || area.row >= PROGRAM_ROWS || area.rows == 0 {
        return void
    }
    screen.scroll(&service.screen.whole, area.row, area.rows, scrolled.lines)
    last :: if area.rows > PROGRAM_ROWS - area.row { PROGRAM_ROWS - 1 } else { area.row + area.rows - 1 }
    storage : u8[64]
    out := text_buffer.make(storage)
    vt.append_scroll(&out, area.row + 1, last + 1, scrolled.lines)
    vt.append_margins(&out, 1, ROWS - 1)
    emit_program(service, &out)
}

// A screen of the program's own, or back to the lines it left.
use_screen :: fn(service: ptr[mut Service], whole: bool) {
    if whole == service.screen.using_whole {
        return void
    }
    screen.use_whole(&service.screen, whole)
    storage : u8[64]
    out := text_buffer.make(storage)
    vt.append_alternate_screen(&out, whole)
    if whole {
        // A new screen is blank, the status line too, so it's drawn again
        vt.append_move(&out, 1, 0)
        service.screen.status_dirty = true
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
    text_buffer.append(&status, if service.attention { STATUS_ATTENTION } else { STATUS })
    if service.waiting_code != 0 {
        text_buffer.append(&status, " │ a new keyboard: type ")
        text_buffer.append_unsigned(&status, cast[u64](service.waiting_code))
        text_buffer.append(&status, " and Enter on it")
    }
    else if service.panic_count > 0 && !service.panic_seen {
        text_buffer.append(&status, " │ the boot before stopped: Ctrl+Alt+Delete")
    }
    screen.set_status(&service.screen, text_buffer.as_string(&status))
    draw_status(service)
}

// The status line, on the top row, inverse, with the cursor put back where it was.
draw_status :: fn(service: ptr[mut Service]) {
    storage : u8[384]
    out := text_buffer.make(storage)
    vt.append_save_cursor(&out)
    vt.append_move(&out, 0, 0)
    vt.append_style(&out, terminal.Style.{attributes = terminal.INVERSE})
    status :: screen.status_text(&service.screen)
    if status.count > 0 {
        text_buffer.append(&out, string_of(&status[0], status.count))
    }
    vt.append_clear_to_end(&out)
    vt.append_style(&out, terminal.Style.{})
    vt.append_restore_cursor(&out)
    emit(service, string_bytes(text_buffer.as_string(&out)))
    service.screen.status_dirty = false
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
    list_programs(service)
    service.chosen = 0
    draw_panel(service)
}

/*
 * The panel: what's waiting (nothing, until the powerbox), the boot before's panic if it stopped for one, and the
 * console's programs with their memory, those that didn't answer a Ping marked, the chosen one inverse.
 */
draw_panel :: fn(service: ptr[mut Service]) {
    screen.show_panel(&service.screen, true)
    panel :: &service.screen.panel
    bold :: terminal.Style.{attributes = terminal.BOLD}
    plain :: terminal.Style.{}
    chosen_style :: terminal.Style.{attributes = terminal.INVERSE}
    screen.write_at(panel, 1, 2, "Secure attention", bold)
    screen.write_at(panel, 3, 2, "Nothing is waiting for you: no prompt, and no one has logged in yet.", plain)
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
    redraw(service)
}

// The session's programs, asked for; none without a session channel, or if it doesn't answer.
list_programs :: fn(service: ptr[mut Service]) {
    service.program_count = 0
    reply :: ask_session(service, .List) or_return void
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
    runtime.log_info("secure attention ended")
    update_status(service)
    screen.show_panel(&service.screen, false)
    redraw(service)
}

/*
 * Every row of what's shown, the panel or the program's, from the screen model, each up to its last cell that isn't
 * blank, then cleared; and the cursor where the program left it.
 */
redraw :: fn(service: ptr[mut Service]) {
    grid :: screen.shown(&service.screen)
    plain :: terminal.Style.{}
    for row in 0..<PROGRAM_ROWS {
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
    if !service.attention {
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

// Another Read, held by the driver until something's typed.
read_more :: fn(service: ptr[mut Service]) {
    out := os.Outgoing.{}
    request :: os.begin[serial.Request](&out)
    request^ = .Read(serial.MAX_BYTES)
    _ = serial.send_request(service.line_end, service.port, &out)
}

read_seat :: fn(service: ptr[mut Service]) {
    out := os.Outgoing.{}
    request :: os.begin[seat.Request](&out)
    request^ = .Read(seat.MAX_EVENTS)
    _ = seat.send_request(service.seat_end, service.port, &out)
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
                first :: service.decoded.count
                vt.feed(&service.decoder, os.items(into, given), &service.decoded)
                vt.finish(&service.decoder, &service.decoded)
                screen_keys(service, first)
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
        if event.code == USAGE_DELETE && event.modifiers & (terminal.CONTROL | terminal.ALT) == terminal.CONTROL | terminal.ALT {
            enter_attention(service)
            continue
        }
        if !service.attention {
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
    }
    // What came with the key, or while its screen was up, is the trusted path's, and isn't kept
    if service.attention || attention_in(decoded, first) {
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
                text :: os.items(into, given.text)
                first :: service.decoded.count
                for event in os.items(into, given.events) {
                    take_seat_event(service, event, text)
                }
                screen_keys(service, first)
                read_seat(service)
            }
            case _ => {}
        }
    }
}

take_seat_event :: fn(service: ptr[mut Service], event: seat.Event, text: u8[]) {
    kind :: seat.kind_of(event) or_return void
    match kind {
        case .SecureAttention => enter_attention(service)
        case .Waiting => {
            service.waiting_code = event.waiting_code
            update_status(service)
        }
        case .Accepted => {
            service.waiting_code = 0
            update_status(service)
        }
        case .Key => {
            if event.code == USAGE_C && event.modifiers & terminal.CONTROL != 0 {
                vt.event(&service.decoded, terminal.event_of(.Interrupt))
                return void
            }
            start :: cast[usize](event.text_start)
            end :: start + cast[usize](event.text_bytes)
            typed :: if start <= end && end <= text.count { text[start..<end] } else { text[0..<0] }
            vt.key(&service.decoded, event.code, event.modifiers, typed)
        }
    }
}

// The input waiting, to the owner, once it holds a Read.
deliver :: fn(service: ptr[mut Service], connected: ptr[service_kit.Clients]) {
    if service.decoded.count == 0 || service.held == 0 || service.attention {
        return void
    }
    owner :: service.owner or_return void
    if owner >= connected.ends.count {
        return void
    }
    end :: connected.ends[owner]
    count :: if service.decoded.count < cast[usize](service.held) { service.decoded.count } else { cast[usize](service.held) }
    if count > service.decoded.events.count || service.decoded.text_count > service.decoded.text.count {
        return void
    }
    out := os.Outgoing.{}
    response :: os.begin[terminal.Response](&out)
    response^ = .Input(terminal.Events.{events = os.append(&out, service.decoded.events[0..<count]),
        text = os.append(&out, service.decoded.text[0..<service.decoded.text_count])})
    if terminal.send_response(end, service.port, &out) != null {
        return void
    }
    service.held = 0
    // Events past the Read's most are dropped with their text, which the next events' ranges would no longer match
    vt.reset(&service.decoder, &service.decoded)
}
