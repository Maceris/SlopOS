/**
 * A terminal in a window (decisions/0192, 15e): the terminal protocol served to a shell it starts in its session, the
 * shell's output kept in a grid of cells (src/screen) and drawn in Noto Sans Mono, and the window's keys given to the
 * program that reads input. Programs the shell starts are given connections to it (Connect), as the console's are.
 *
 * Colours and attributes are kept in the cells but drawn plain; the line the reader edits is drawn where the cursor is.
 * It says what it does in its debug log: "started the shell", and "the shell ended" when it has, which closes it.
 */
package terminal_window

import runtime from "base"
import os from "std"
import ui from "std"
import unicode from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import process_manager from "std/os/slop_os"
import read_only_file from "std/os/slop_os"
import network from "std/os/slop_os"
import terminal from "std/os/slop_os"
import gui_kit from "../../gui_kit"
import gui_programs from "../../gui_programs"
import installations from "../../installations"
import programs from "../../protocols/programs"
import surface from "../../protocols/surface"
import safe_text from "../../safe_text"
import screen from "../../screen"
import shell from "../shell"
import service_kit from "../../libraries/service_kit"

/** The text's size, in pixels to the em. */
TEXT_SIZE : f32 : 15
/** A row's height, in pixels. */
ROW_HEIGHT : f32 : 20
/** A column's width, in pixels: Noto Sans Mono's advance at TEXT_SIZE, rounded up. */
COLUMN_WIDTH : f32 : 9.2
/** The most clients: the shell and what it starts. */
MAX_CLIENTS :: 16
/** The most input events waiting for the reader. */
QUEUED :: 64
/** The most bytes of their text. */
QUEUED_TEXT :: 1024
/** The most bytes of the reader's line. */
LINE_BYTES :: 1024
/** The memory the shell is given. */
SHELL_BUDGET : u64 : 32 * 1024 * 1024
/** Tab stops, every this many columns. */
TAB_STOP :: 8

/** What the shell's given; its handles move to it at its launch (shell.main). */
ShellGrants :: struct {
    /** A copy of the debug log. */
    log : slop_os.DebugLog?,
    /** Its terminal: the window's. */
    session_terminal : os.Channel[terminal.Terminal],
    /** The session's home; null as the window has none to give. */
    home : os.Channel[dir.Dir]?,
    /** Its own connection to the process manager. */
    manager : os.Channel[process_manager.ProcessManager]?,
    /** A programs connection that finds programs. */
    programs : os.Channel[programs.Programs]?,
    /** No data directory. */
    data : installations.AppData?,
    /** No script. */
    script : os.Channel[read_only_file.ReadOnlyFile]?,
    /** No CPU budget of its own. */
    cpu_budget : slop_os.CpuBudget?,
    /** No network. */
    network : os.Channel[network.Network]?,
    /** No command: it reads lines. */
    command : string?,
}

/** The terminal window's state, on the heap. */
Term :: struct {
    /** Its window. */
    window : ptr[mut gui_kit.Window],
    /** What's shown: the lines written, or a program's own screen. */
    screen : screen.Screen,
    /** Its clients, the shell and what it starts, bound to the window's port. */
    clients : service_kit.Clients,
    /** The client whose input it is: the first to Read, until it releases it; null for none. */
    reader : usize?,
    /** How many events the reader's held Read asks for; 0 for none held. */
    held : u32,
    /** Input waiting for the reader, the first count. */
    events : terminal.Event[QUEUED],
    /** How many are waiting. */
    count : usize,
    /** Their text. */
    text : u8[QUEUED_TEXT],
    /** How many bytes of text. */
    text_count : usize,
    /** The line the reader's editing, the first line_count bytes. */
    line : u8[LINE_BYTES],
    /** How many bytes of line. */
    line_count : usize,
    /** Whether the cursor's shown. */
    cursor_shown : bool,
    /** Whether what's shown changed since the last frame. */
    changed : bool,
}

/**
 * Start the shell on a terminal of its own, show what it writes, and give it the keys, until it ends or the window's
 * closed.
 *
 * @param log A copy of its starter's debug log, given to the shell too.
 * @param surface Its connection to the compositor.
 * @param home The session's home; not given on, as the window can't copy it.
 * @param manager Its connection to the process manager, which the shell's launched through.
 * @param programs Its programs connection, which finds the shell.
 * @return 0 once the shell's ended or the window's closed; 2 without a compositor, process manager or programs, or when
 *     the window or the shell can't start.
 */
main :: fn(log: slop_os.DebugLog?, surface: os.Channel[surface.Surface]?, home: os.Channel[dir.Dir]?,
    manager: os.Channel[process_manager.ProcessManager]?, programs: os.Channel[programs.Programs]?) -> int {
    term :: runtime.new(Term)
    term.cursor_shown = true
    columns :: cast[f32](screen.COLUMNS) * COLUMN_WIDTH + 16
    rows :: cast[f32](screen.PROGRAM_ROWS) * ROW_HEIGHT + 12
    term.window = gui_kit.open_on(surface or_return 2, "Terminal", cast[u32](columns), cast[u32](rows)) or_return 2
    if !start_shell(term, log, manager or_return 2, programs or_return 2) {
        return 2
    }
    runtime.log_info("started the shell")
    into := os.Incoming.{}
    loop {
        if !gui_kit.take(term.window) || term.window.closing {
            return 0
        }
        take_keys(term)
        for i in cast[usize](0)..<term.clients.count {
            serve(term, i, &into)
        }
        deliver(term)
        if term.clients.count > 0 && every_client_gone(term) {
            runtime.log_info("the shell ended")
            return 0
        }
        if term.changed || term.window.due {
            frame(term)
        }
        gui_kit.wait(term.window, (slop_os.clock_monotonic() or_else 0) + 500_000_000)
    }
}

/** Whether every client's gone: the shell, and whatever it started. */
every_client_gone :: fn(term: ptr[Term]) -> bool {
    for end in term.clients.ends {
        if cast[slop_os.Handle](end) != slop_os.NO_HANDLE {
            return false
        }
    }
    return true
}

/** Find the shell and launch it, on a terminal channel the window serves. */
start_shell :: fn(term: ptr[mut Term], log: slop_os.DebugLog?, manager: os.Channel[process_manager.ProcessManager],
    finder: os.Channel[programs.Programs]) -> bool {
    startup :: slop_os.startup_block()
    finder_port :: os.port_for(startup.budget, finder.end) or_return false
    out := os.Outgoing.{}
    request :: os.begin[programs.Request](&out)
    request^ = .Find(os.append(&out, string_bytes("shell")))
    if programs.send_request(finder.end, finder_port, &out) is_some {
        return false
    }
    into := os.Incoming.{}
    match programs.receive_response(finder.end, finder_port, &into, true) {
        case Received => {}
        case _ => return false
    }
    found :: match os.message_of[programs.Response](&into)^ {
        case Found(program) => program
        case _ => return false
    }
    _ = slop_os.handle_close(cast[slop_os.Handle](found.manifest))
    pair :: os.channel_for[terminal.Terminal](startup.budget, 0) or_return false
    if !service_kit.add_client(&term.clients, term.window.port, pair.a) {
        return false
    }
    manager_port :: os.port_for(startup.budget, manager.end) or_return false
    grants := ShellGrants.{log = log, session_terminal = os.Channel[terminal.Terminal].{end = pair.b}}
    grants.manager = process_manager.connect(manager.end, manager_port, startup.budget)
    grants.programs = programs.connect(finder.end, finder_port, startup.budget)
    launched :: os.launch(manager, manager_port, "shell", found.executable, SHELL_BUDGET, shell.main, grants)
    _ = slop_os.handle_close(cast[slop_os.Handle](found.executable))
    return launched is_ok
}

/** Take the window's keys as the terminal's input: Ctrl+C an interrupt, the rest keys with their text. */
take_keys :: fn(term: ptr[mut Term]) {
    window :: term.window
    raw_text :: window.raw_text[0..<window.raw_text.count]
    for key in window.raw_keys {
        start :: cast[usize](key.text_start)
        end :: start + cast[usize](key.text_bytes)
        typed :: if start <= end && end <= raw_text.count { raw_text[start..<end] } else { raw_text[0..<0] }
        if key.code == 0x06 && key.modifiers & terminal.CONTROL != 0 {
            queue(term, terminal.event_of(.Interrupt), raw_text[0..<0])
            continue
        }
        made := terminal.event_of(.Key)
        made.code = cast[u16](key.code)
        made.modifiers = key.modifiers
        queue(term, made, typed)
    }
    gui_kit.take_keys(window)
    // What's pasted goes in as a Paste
    if window.pasted.count > 0 {
        queue(term, terminal.event_of(.Paste), window.pasted[0..<window.pasted.count])
        runtime.array_reset(&window.pasted)
    }
}

/** Queue an input event for the reader, with its text; past what's kept, dropped. */
queue :: fn(term: ptr[mut Term], made: terminal.Event, text: u8[]) {
    if term.count >= term.events.count || text.count > term.text.count - term.text_count {
        return void
    }
    event := made
    event.text_start = cast[u32](term.text_count)
    event.text_bytes = cast[u32](text.count)
    for byte in text {
        if term.text_count < term.text.count {
            term.text[term.text_count] = byte
            term.text_count += 1
        }
    }
    if term.count < term.events.count {
        term.events[term.count] = event
        term.count += 1
    }
}

/** Answer the reader's held Read with what's waiting. */
deliver :: fn(term: ptr[mut Term]) {
    reader :: term.reader or_return void
    if term.count == 0 || term.held == 0 || reader >= term.clients.ends.count {
        return void
    }
    count :: if term.count < cast[usize](term.held) { term.count } else { cast[usize](term.held) }
    // Those given are the first; their text's the queue's up to the next's start
    text_end :: if count < term.count && count < term.events.count { cast[usize](term.events[count].text_start) } else { term.text_count }
    if count > term.events.count || text_end > term.text.count {
        return void
    }
    out := os.Outgoing.{}
    response :: os.begin[terminal.Response](&out)
    response^ = .Input(terminal.Events.{events = os.append(&out, term.events[0..<count]), text = os.append(&out, term.text[0..<text_end])})
    if terminal.send_response(term.clients.ends[reader], term.window.port, &out) is_some {
        return void
    }
    term.held = 0
    left :: term.count - count
    for i in cast[usize](0)..<left {
        if i + count < term.events.count && i < term.events.count {
            moved := term.events[i + count]
            moved.text_start = moved.text_start - cast[u32](text_end)
            term.events[i] = moved
        }
    }
    text_left :: term.text_count - text_end
    for i in cast[usize](0)..<text_left {
        if i + text_end < term.text.count && i < term.text.count {
            term.text[i] = term.text[i + text_end]
        }
    }
    term.count = left
    term.text_count = text_left
}

/** Take every request a client has sent, until there are none left, or it's gone. */
serve :: fn(term: ptr[mut Term], index: usize, into: ptr[mut os.Incoming]) {
    if index >= term.clients.ends.count {
        return void
    }
    end :: term.clients.ends[index]
    if cast[slop_os.Handle](end) == slop_os.NO_HANDLE {
        return void
    }
    loop {
        match terminal.receive_request(end, term.window.port, into, false) {
            case Received => {}
            case Empty => return void
            case Unsupported => {
                _ = terminal.answer_unsupported(end, term.window.port)
                continue
            }
            case _ => {
                service_kit.drop_client(&term.clients, index)
                if (term.reader or_else term.clients.ends.count) == index {
                    term.reader = null
                    term.held = 0
                    term.line_count = 0
                    term.changed = true
                }
                return void
            }
        }
        match os.message_of[terminal.Request](into)^ {
            case Write(text) => write(term, into, text)
            case MoveCursor(position) => {
                screen.move(&term.screen, position.column, position.row)
                term.changed = true
            }
            case ShowCursor(shown) => {
                term.cursor_shown = shown
                term.changed = true
            }
            case Clear(area) => {
                screen.clear(screen.current(&term.screen), area)
                term.changed = true
            }
            case Scroll(scrolled) => {
                screen.scroll(screen.current(&term.screen), scrolled.area.row, scrolled.area.rows, scrolled.lines)
                term.changed = true
            }
            case Screen(whole) => {
                screen.use_whole(&term.screen, whole)
                term.changed = true
            }
            case Bell => {}
            case Describe => {
                out := os.Outgoing.{}
                response :: os.begin[terminal.Response](&out)
                response^ = .Described(terminal.Features.{columns = screen.COLUMNS, rows = screen.PROGRAM_ROWS, colors = .Palette16,
                    unicode = 15})
                _ = terminal.send_response(end, term.window.port, &out)
            }
            case Read(most) => {
                owned :: (term.reader or_else index) == index
                if owned {
                    term.reader = index
                    term.held = if most == 0 { cast[u32](1) } else { most }
                }
            }
            case InputLine(given) => {
                if (term.reader or_else term.clients.ends.count) == index {
                    term.line_count = 0
                    for byte in os.items(into, given.text) {
                        if term.line_count < term.line.count {
                            term.line[term.line_count] = byte
                            term.line_count += 1
                        }
                    }
                    term.changed = true
                }
            }
            case Connect(connection) => {
                if !service_kit.add_client(&term.clients, term.window.port, connection.end) {
                    _ = slop_os.handle_close(cast[slop_os.Handle](connection.end))
                }
            }
            case ReleaseInput => {
                if (term.reader or_else term.clients.ends.count) == index {
                    if term.held > 0 {
                        out := os.Outgoing.{}
                        response :: os.begin[terminal.Response](&out)
                        response^ = .Input(terminal.Events.{events = os.append(&out, term.events[0..<0]), text = os.append(&out, term.text[0..<0])})
                        _ = terminal.send_response(end, term.window.port, &out)
                    }
                    term.reader = null
                    term.held = 0
                    term.line_count = 0
                    term.changed = true
                }
            }
        }
    }
}

/** Write text into the grid where the cursor is, a grapheme cluster at a time, made safe, in its runs' styles. */
write :: fn(term: ptr[mut Term], into: ptr[os.Incoming], text: terminal.Text) {
    bytes :: os.items(into, text.text)
    runs :: os.items(into, text.runs)
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
        loop {
            if at < run_end || run_index + 1 >= runs.count {
                break
            }
            run_index += 1
            if run_index < runs.count {
                run_end += cast[usize](runs[run_index].bytes)
            }
        }
        style :: if run_index < runs.count { runs[run_index].style } else { terminal.Style.{} }
        if safe_text.is_line_break(bytes, at, end) {
            screen.line_break(&term.screen)
        }
        else if safe_text.is_tab(bytes, at, end) {
            grid :: screen.current(&term.screen)
            loop {
                screen.put(&term.screen, string_bytes(" "), 1, style)
            }
            while grid.column % TAB_STOP != 0 && grid.column < screen.COLUMNS
        }
        else {
            shown := safe_text.Shown.{}
            safe_text.show(bytes, at, end, &shown)
            if shown.count <= shown.bytes.count {
                screen.put(&term.screen, shown.bytes[0..<shown.count], shown.columns, style)
            }
        }
        at = end
    }
    term.changed = true
}

/** A frame: each row of the grid a line of text, the reader's line and the cursor where the cursor is. */
frame :: fn(term: ptr[mut Term]) {
    term.changed = false
    u :: gui_kit.begin(term.window)
    u.theme.background = ui.rgb(30, 30, 30)
    _ = ui.open(u, "rows", ui.Box.{width = ui.grow(), height = ui.grow(), padding_x = 8, padding_y = 6, background = ui.rgb(30, 30, 30)})
    grid :: screen.current(&term.screen)
    row_text : u8[..]
    defer runtime.array_free(&row_text)
    for row in cast[u16](0)..<screen.PROGRAM_ROWS {
        runtime.array_reset(&row_text)
        for column in cast[u16](0)..<screen.COLUMNS {
            at_cursor :: row == grid.row && column == grid.column
            if at_cursor && term.line_count > 0 {
                // The reader's line, from the cursor on
                kept :: term.line[0..<LINE_BYTES]
                line :: if term.line_count <= kept.count { kept[0..<term.line_count] } else { kept }
                for byte in line {
                    runtime.array_add(&row_text, byte)
                }
                break
            }
            if at_cursor && term.cursor_shown {
                runtime.array_add(&row_text, cast[u8]('_'))
                continue
            }
            match screen.cell(grid, row, column) {
                case Some(cell) => {
                    if cell.count == 0 {
                        runtime.array_add(&row_text, cast[u8](' '))
                    }
                    else if cell.width > 0 {
                        kept :: cell.bytes[0..<screen.CELL_BYTES]
                        cluster :: if cast[usize](cell.count) <= kept.count { kept[0..<cast[usize](cell.count)] } else { kept }
                        for byte in cluster {
                            runtime.array_add(&row_text, byte)
                        }
                    }
                }
                case None => runtime.array_add(&row_text, cast[u8](' '))
            }
        }
        _ = ui.open(u, "row", ui.Box.{key = cast[u64](row), width = ui.grow(), height = ui.fixed(ROW_HEIGHT)})
        _ = ui.label(u, string_of_bytes(row_text[0..<row_text.count]), ui.TextStyle.{size = TEXT_SIZE, mono = true, wrap = false,
            colour = ui.rgb(230, 230, 230)}, key = cast[u64](row))
        ui.close(u)
    }
    ui.close(u)
    _ = gui_kit.finish(term.window)
}

/** Bytes as text. */
string_of_bytes :: fn(bytes: u8[]) -> string {
    return if bytes.count > 0 { string_of(&bytes[0], bytes.count) } else { "" }
}
