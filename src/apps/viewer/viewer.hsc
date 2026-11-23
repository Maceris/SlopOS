/**
 * The typed-data viewer (decisions/0192, 15g): a GUI program that shows what's in the session's home. It lists a
 * folder, and shows a file chosen in it as the shell's view does (decisions/0179): a typed file's value read by its
 * type's schema, found by its hash among the manifests of the programs the session can run, written as the shell
 * writes values, a record's fields and a table's rows; a text file's text; any other file's bytes in hexadecimal.
 * What's shown is a list of lines, only those on screen made each frame, so a long one costs no more than a short one.
 * Asked to open a path (GuiGrants' open), it shows that file first; a path typed in its path field, and Enter, shows
 * that one. Escape goes back from a file to the folder, and from the folder closes it. A sound, a WAV file of a format
 * the audio service takes (decisions/0196, 17g), is said to be one, its format and length, and Play plays it through
 * the session's sound, at the session's volume; Stop, Back or another file stops it. It says what it does in its
 * debug log: "showing its window" once it's first drawn, "showing <path>" with what's said of it (its type, or why it
 * couldn't be read), "playing <path>" and "played <ms> ms of <path>", "back to the folder", and "closed by Escape".
 */
package viewer

import runtime from "base:runtime"
import os from "std:os"
import slop_os from "std:os/slop_os"
import dir from "std:os/slop_os/dir"
import terminal from "std:os/slop_os/terminal"
import schema from "std:schema"
import strings from "std:strings"
import text_buffer from "std:text_buffer"
import ui from "std:ui"
import gui_kit from "../../gui_kit"
import audio as pcm from "std:audio"
import programs from "../../protocols/programs"
import sound as sound_protocol from "../../protocols/sound"
import surface from "../../protocols/surface"
import shell_language as language from "../../shell_language"

/** The most bytes of a file it reads: 1 MiB, as the shell's view does. What's past them is said to be there. */
MAX_FILE_BYTES : u64 : 1024 * 1024
/** The most bytes of what it shows, written out: 4 MiB. What's past them is cut. */
MAX_SHOWN_BYTES :: 4 * 1024 * 1024
/** The most bytes of a file that isn't text shown in hexadecimal: 64 KiB. */
MAX_HEX_BYTES :: 64 * 1024
/** How many bytes a line of hexadecimal shows. */
HEX_LINE_BYTES :: 16
/** The most bytes of a manifest read to find a typed file's type: 256 KiB. */
MAX_MANIFEST : u64 : 256 * 1024
/** The most bytes of a path beneath home. */
PATH_BYTES :: 1024
/** Each line's height, in pixels. */
LINE_HEIGHT : f32 : 18
/** The most programs whose manifests are looked through for a type. */
MAX_PROGRAMS : u32 : 256
/** How often it looks at the sound played while it plays, in nanoseconds: every 10 ms, under a period's two. */
PLAY_POLL_NS : u64 : 10_000_000

/** A sound being played: its stream's connection, ring and how far it's got. */
Playing :: struct {
    /** Whether one is. */
    active : bool,
    /** Its stream's connection, made from the viewer's, and a port bound to it. */
    end : slop_os.Channel,
    port : slop_os.Port,
    /** Its ring's layout, and where it's mapped. */
    opened : sound_protocol.Opened,
    ring : u64,
    ring_bytes : u64,
    /** Its periods: all of them, given, and played. */
    periods : usize,
    given : usize,
    played : usize,
    /** How many periods the service ran out of it for. */
    underruns : u32,
}

/** The viewer's state, on the heap. */
Viewer :: struct {
    /** Its log grant, which its lines are written to (gui_kit.log_to); null without one. */
    log : slop_os.DebugLog?,
    /** Its window. */
    window : ptr[mut gui_kit.Window],
    /** The session's home, which it lists and reads beneath; valid only while has_home. */
    home : os.Directory,
    /** Whether it has a home. */
    has_home : bool,
    /** Its programs connection, whose programs' manifests have the types typed files are of; null without one. */
    programs : os.Channel[programs.Programs]?,
    /** The port programs is bound to; NO_HANDLE without one. */
    programs_port : slop_os.Port,
    /** The folder listed, its path beneath home, without a / at either end; empty for home itself. */
    folder : u8[..],
    /** What's in the folder, sorted: folders first, then by name. */
    entries : os.DirectoryEntry[..],
    /** Whether a file's shown, in place of the folder. */
    viewing : bool,
    /** What's typed in the path field: a file's path beneath home, shown when Enter's pressed in it. */
    typed : u8[..],
    /** The file shown, its path beneath home. */
    shown_path : u8[..],
    /** What's said of it above it: its type, or why it couldn't be read. */
    note : u8[..],
    /** What's shown of it, written out. */
    text : u8[..],
    /** Where each of text's lines starts, in bytes. */
    lines : usize[..],
    /**
     * For a typed value shown, its schema's hash and its bytes, which Ctrl+C copies, typed, with its text
     * (decisions/0193, 16f); data empty for anything else.
     */
    shown_hash : u8[32],
    /** The typed value's bytes, in its schema's encoding; empty when what's shown isn't one. */
    shown_data : u8[..],
    /** Its sound connection, which each sound played gets a connection from; null without one. */
    sound : os.Channel[sound_protocol.Sound]?,
    /** A port bound to sound, waited on while its ring is full. */
    sound_port : slop_os.Port,
    /** For a sound shown: its format, how long it is, and its frames' bytes; data empty when what's shown isn't one. */
    sound_format : sound_protocol.Format,
    sound_ms : u64,
    sound_data : u8[..],
    /** The sound being played. */
    playing : Playing,
}

/**
 * List the session's home and show the files chosen in it, until the window's closed.
 *
 * @param log Its debug log, which its lines go to (gui_kit.log_to); without it, it says nothing.
 * @param surface Its connection to the compositor.
 * @param home The session's home, which it lists and reads; without it, it says there's nothing to show.
 * @param programs Its programs connection, whose programs' manifests have typed files' types; without it, a typed file
 *     can't be read, and says so.
 * @param open A file's path beneath home, shown first; null to start with home's listing.
 * @param terminal Not used: it serves no terminal.
 * @param activation The token for the gesture that started it, which its window presents to take focus.
 * @param sound A sound connection of the session's, which a sound shown is played through; without it, a sound's
 *     shown but can't be played.
 * @return 0 once its window's closed; 2 without a compositor, or when its window can't be made.
 */
main :: fn(
    log : slop_os.DebugLog?,
    surface : os.Channel[surface.Surface]?,
    home : os.Channel[dir.Dir]?,
    programs : os.Channel[programs.Programs]?,
    open : string?,
    terminal : os.Channel[terminal.Terminal]?,
    activation : u64?,
    sound : os.Channel[sound_protocol.Sound]?
) -> int {
    startup :: slop_os.startup_block()
    viewer :: runtime.new(Viewer)
    viewer.log = log
    match sound {
        case Some(given) => match os.port_for(startup.budget, given.end) {
            case Some(port) => {
                viewer.sound = given
                viewer.sound_port = port
            }
            case None => _ = slop_os.handle_close(cast[slop_os.Handle](given.end))
        }
        case None => {}
    }
    viewer.programs_port = cast[slop_os.Port](slop_os.NO_HANDLE)
    match programs {
        case Some(given) => {
            match os.port_for(startup.budget, given.end) {
                case Some(port) => {
                    viewer.programs = given
                    viewer.programs_port = port
                }
                case None => {}
            }
        }
        case None => {}
    }
    match home {
        case Some(given) => {
            directory, error :: os.directory_on(given.end)
            if error == null {
                viewer.home = directory
                viewer.has_home = true
            }
        }
        case None => {}
    }
    viewer.window = gui_kit.open_on(surface or_return 2, "Viewer", 720, 560, activation or_else 0) or_return 2
    list_folder(viewer)
    match open {
        case Some(path) => show_file(viewer, path)
        case None => {}
    }
    shown := false
    loop {
        if !gui_kit.take(viewer.window) {
            return 2
        }
        if viewer.window.closing {
            return 0
        }
        if viewer.window.due {
            frame(viewer)
            // Said once its first frame's drawn, so what's typed after is its
            if !shown {
                shown = true
                gui_kit.log_to(viewer.log, "viewer: showing its window")
            }
        }
        // Escape closes it in a frame, which may have sent nothing that brings an answer to wait for
        if viewer.window.closing {
            return 0
        }
        // While it plays, the sound's answers are looked at often enough that its ring stays full
        if viewer.playing.active {
            keep_playing(viewer)
            gui_kit.wait(viewer.window, (slop_os.clock_monotonic() or_else 0) + PLAY_POLL_NS)
        }
        else {
            gui_kit.wait(viewer.window)
        }
    }
}

/** A frame: the folder's listing, or the file shown; what's clicked acted on after. */
frame :: fn(viewer : ptr[mut Viewer]) {
    u :: gui_kit.begin(viewer.window)
    // A paste with typed data shows its value, as a typed file's is shown; its text alone is for the path field
    match gui_kit.take_paste(viewer.window) {
        case Some(given) => {
            pasted := given
            show_pasted(viewer, pasted)
            runtime.array_free(&pasted.bytes)
        }
        case None => {}
    }
    // Escape goes back from a file to its folder, and from the folder closes the window
    escaped :: ui.key_pressed(u, .Escape)
    _ = ui.open(u, "body", ui.Box.{width = ui.grow(), height = ui.grow(), padding_x = 12, padding_y = 12, gap = 8})
    if viewer.viewing {
        file_frame(viewer, u)
    }
    else {
        folder_frame(viewer, u)
    }
    ui.close(u)
    submitted := false
    for event in gui_kit.finish(viewer.window) {
        submitted = submitted || event.kind == .Submitted
    }
    // Enter in the path field shows what it names
    if submitted && !viewer.viewing && viewer.typed.count > 0 {
        path :: strings.clone(text_of(ui.contents(&viewer.typed))) or_else ""
        runtime.array_reset(&viewer.typed)
        show_file(viewer, path)
        return void
    }
    if escaped {
        if viewer.viewing {
            viewer.viewing = false
            viewer.window.due = true
            gui_kit.log_to(viewer.log, "viewer: back to the folder")
        }
        else {
            gui_kit.log_to(viewer.log, "viewer: closed by Escape")
            viewer.window.closing = true
        }
    }
}

/** The folder: its path, Up when it isn't home, and a button for each folder and file in it. */
folder_frame :: fn(viewer : ptr[mut Viewer], u : ptr[mut ui.Ui]) {
    folder :: text_of(ui.contents(&viewer.folder))
    _ = gui_kit.label_of(u, string.["Home", if folder.count == 0 { "" } else { "/" }, folder], ui.TextStyle.{size = 18})
    if !viewer.has_home {
        _ = ui.label(u, "There's no home to show.")
        return void
    }
    _ = ui.text_field(u, "Path", &viewer.typed)
    up :: folder.count > 0 && ui.button(u, "Up")
    clicked := viewer.entries.count
    _ = ui.scroll_area(u, "entries", ui.Box.{width = ui.grow(), height = ui.grow(), gap = 4})
    for entry, i in viewer.entries {
        if gui_kit.button_of(u, string.[entry.name, if entry.is_directory { "/" } else { "" }], key = cast[u64](i)) {
            clicked = i
        }
    }
    if viewer.entries.count == 0 {
        _ = ui.label(u, "Nothing's here.")
    }
    ui.close(u)
    if up {
        // Back to the folder it's in: what's after its last /, gone
        cut := cast[usize](0)
        for byte, i in viewer.folder {
            if byte == cast[u8]('/') {
                cut = i
            }
        }
        truncate(&viewer.folder, cut)
        list_folder(viewer)
        return void
    }
    if clicked >= viewer.entries.count {
        return void
    }
    entry :: viewer.entries[clicked]
    path :: path_beneath(viewer, entry.name)
    if entry.is_directory {
        runtime.array_reset(&viewer.folder)
        add_bytes(&viewer.folder, string_bytes(path))
        list_folder(viewer)
    }
    else {
        show_file(viewer, path)
    }
}

/** The file shown: its path and what's said of it, Back, and its lines, only those on screen made. */
file_frame :: fn(viewer : ptr[mut Viewer], u : ptr[mut ui.Ui]) {
    _ = ui.label(u, text_of(ui.contents(&viewer.shown_path)), ui.TextStyle.{size = 18})
    if viewer.note.count > 0 {
        _ = ui.label(u, text_of(ui.contents(&viewer.note)), ui.TextStyle.{size = 13})
    }
    // A sound's Play first, so Tab reaches it first
    played := false
    if viewer.sound_data.count > 0 && viewer.sound is_some {
        played = ui.button(u, if viewer.playing.active { "Stop" } else { "Play" })
    }
    back :: ui.button(u, "Back")
    // Ctrl+C copies a typed value, typed, with its text for what doesn't know its type
    if ui.key_pressed(u, .Copy) && viewer.shown_data.count > 0 {
        gui_kit.offer_typed(
            viewer.window,
            viewer.shown_hash,
            ui.contents(&viewer.shown_data),
            ui.contents(&viewer.text)
        )
        gui_kit.log_to(viewer.log, "viewer: copied %", text_of(ui.contents(&viewer.note)))
    }
    count :: viewer.lines.count
    range :: ui.list(u, "lines", count, LINE_HEIGHT, ui.Box.{width = ui.grow(), height = ui.grow()})
    for i in range.first..<range.last {
        _ = ui.list_item(u, i, LINE_HEIGHT)
        _ = ui.label(u, line_of(viewer, i), ui.TextStyle.{size = 14, mono = true, wrap = false}, key = cast[u64](i))
        ui.close(u)
    }
    ui.end_list(u, range, count, LINE_HEIGHT)
    if played {
        if viewer.playing.active {
            stop_playing(viewer)
        }
        else {
            start_playing(viewer)
        }
        viewer.window.due = true
    }
    if back {
        stop_playing(viewer)
        viewer.viewing = false
        viewer.window.due = true
    }
}

/**
 * Start playing the sound shown: a stream on a new connection of the viewer's, opened in its format, its ring mapped,
 * and its first periods given; keep_playing gives the rest as they're played.
 *
 * @param viewer The viewer, a sound shown, and its sound connection.
 */
start_playing :: fn(viewer : ptr[mut Viewer]) {
    stop_playing(viewer)
    given :: viewer.sound or_return void
    startup :: slop_os.startup_block()
    made :: sound_protocol.connect(given.end, viewer.sound_port, startup.budget) or_return void
    port :: os.port_for(startup.budget, made.end) or_else cast[slop_os.Port](slop_os.NO_HANDLE)
    playing :: &viewer.playing
    playing^ = Playing.{end = made.end, port = port}
    if cast[slop_os.Handle](port) == slop_os.NO_HANDLE || !open_stream(viewer) {
        gui_kit.log_to(viewer.log, "viewer: couldn't play %", text_of(ui.contents(&viewer.shown_path)))
        stop_playing(viewer)
        return void
    }
    period_bytes :: cast[usize](playing.opened.period_bytes)
    playing.periods = (viewer.sound_data.count + period_bytes - 1) / period_bytes
    playing.active = true
    for period in 0..<playing.opened.periods {
        if playing.given >= playing.periods {
            break
        }
        if !give_period(viewer, period) {
            stop_playing(viewer)
            return void
        }
    }
    gui_kit.log_to(viewer.log, "viewer: playing %", text_of(ui.contents(&viewer.shown_path)))
}

/**
 * Open the stream being played in the sound's format, and map its ring.
 *
 * @param viewer The viewer, its stream's connection made.
 * @return Whether it's open and mapped.
 */
open_stream :: fn(viewer : ptr[mut Viewer]) -> bool {
    playing :: &viewer.playing
    into := os.Incoming.{}
    out := os.Outgoing.{}
    os.begin[sound_protocol.Request](&out)^ = .Open(viewer.sound_format)
    if !call_sound(playing, &out, &into) {
        return false
    }
    match os.message_of[sound_protocol.Response](&into)^ {
        case Opened(layout) => playing.opened = layout
        case _ => return false
    }
    os.begin[sound_protocol.Request](&out)^ = .GetBuffer
    if !call_sound(playing, &out, &into) {
        return false
    }
    window :: match os.message_of[sound_protocol.Response](&into)^ {
        case Buffer(memory) => memory
        case _ => return false
    }
    bytes :: (cast[u64](playing.opened.periods) * cast[u64](playing.opened.period_bytes) + 4095) / 4096 * 4096
    startup :: slop_os.startup_block()
    ring :: runtime.reserve_addresses(cast[usize](bytes)) or_return false
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    if slop_os.memory_map(window, startup.space, cast[u64](ring), 0, bytes, read_write) is_error {
        return false
    }
    playing.ring = cast[u64](ring)
    playing.ring_bytes = bytes
    return true
}

/** Send a request on the stream being played's connection, and wait for its answer, in into; whether it came. */
call_sound :: fn(playing : ptr[mut Playing], out : ptr[mut os.Outgoing], into : ptr[mut os.Incoming]) -> bool {
    if sound_protocol.send_request(playing.end, playing.port, out) is_some {
        return false
    }
    return match sound_protocol.receive_response(playing.end, playing.port, into, true) {
        case Received => true
        case _ => false
    }
}

/**
 * Copy the sound's next period into a place in the ring, padded with silence past its end, and give it.
 *
 * @param viewer The viewer, playing.
 * @param period The place in the ring.
 * @return Whether it was given.
 */
give_period :: fn(viewer : ptr[mut Viewer], period : u32) -> bool {
    playing :: &viewer.playing
    period_bytes :: cast[usize](playing.opened.period_bytes)
    into :: view_of(cast[ptr[mut u8]](playing.ring + cast[u64](period) * cast[u64](period_bytes)), period_bytes)
    start :: playing.given * period_bytes
    for &byte, i in into {
        at :: start + i
        byte^ = if at < viewer.sound_data.count { viewer.sound_data[at] } else { 0 }
    }
    out := os.Outgoing.{}
    os.begin[sound_protocol.Request](&out)^ = .Play(period)
    if sound_protocol.send_request(playing.end, playing.port, &out) is_some {
        return false
    }
    playing.given += 1
    return true
}

/**
 * Take the answers of the sound being played that have come: each period played given again with the next, until
 * it's all played, when it's said and stopped.
 *
 * @param viewer The viewer, playing.
 */
keep_playing :: fn(viewer : ptr[mut Viewer]) {
    playing :: &viewer.playing
    into := os.Incoming.{}
    loop {
        match sound_protocol.receive_response(playing.end, playing.port, &into, false) {
            case Received => {}
            case Empty => return void
            case _ => {
                stop_playing(viewer)
                return void
            }
        }
        done :: match os.message_of[sound_protocol.Response](&into)^ {
            case Played(answer) => answer
            case _ => {
                stop_playing(viewer)
                return void
            }
        }
        playing.played += 1
        playing.underruns = done.underruns
        if playing.given < playing.periods && !give_period(viewer, done.period) {
            stop_playing(viewer)
            return void
        }
        if playing.played >= playing.periods {
            gui_kit.log_to(
                viewer.log,
                "viewer: played % ms of %, % underruns",
                viewer.sound_ms,
                text_of(ui.contents(&viewer.shown_path)),
                playing.underruns
            )
            stop_playing(viewer)
            viewer.window.due = true
            return void
        }
    }
}

/**
 * Stop the sound being played, if one is: its connection closed, which drops what's given, and its ring unmapped.
 *
 * @param viewer The viewer.
 */
stop_playing :: fn(viewer : ptr[mut Viewer]) {
    playing :: &viewer.playing
    if playing.ring != 0 {
        _ = slop_os.memory_unmap(slop_os.startup_block().space, playing.ring)
    }
    for each in slop_os.Handle.[cast[slop_os.Handle](playing.port), cast[slop_os.Handle](playing.end)] {
        if each != slop_os.NO_HANDLE && each != cast[slop_os.Handle](0) {
            _ = slop_os.handle_close(each)
        }
    }
    playing^ = Playing.{end = cast[slop_os.Channel](slop_os.NO_HANDLE), port = cast[slop_os.Port](slop_os.NO_HANDLE)}
}

/** A line of what's shown, without its line break; "" past them. */
line_of :: fn(viewer : ptr[Viewer], index : usize) -> string {
    if index >= viewer.lines.count {
        return ""
    }
    start :: viewer.lines[index]
    end := viewer.text.count
    if index + 1 < viewer.lines.count {
        end = viewer.lines[index + 1] - 1
    }
    text :: ui.contents(&viewer.text)
    if start > end || end > text.count {
        return ""
    }
    return text_of(text[start..<end])
}

/** A name in the folder listed, as its path beneath home, on the heap, never freed. */
path_beneath :: fn(viewer : ptr[Viewer], name : string) -> string {
    folder :: text_of(ui.contents(&viewer.folder))
    return if folder.count == 0 { name } else { language.joined(language.joined(folder, "/"), name) }
}

/** List the folder, folders first, then by name; empty, saying nothing, if it can't be listed. */
list_folder :: fn(viewer : ptr[mut Viewer]) {
    os.free_directory_listing(viewer.entries)
    none : os.DirectoryEntry[..]
    viewer.entries = none
    viewer.viewing = false
    viewer.window.due = true
    if !viewer.has_home {
        return void
    }
    match os.list_directory_in(viewer.home, text_of(ui.contents(&viewer.folder))) {
        case Ok(listing) => viewer.entries = listing
        case Error(error) => {
            gui_kit.log_to(viewer.log, "viewer: the folder couldn't be listed: %", error)
            return void
        }
    }
    // Insertion sort, in place through a view of the entries: folders are short
    entries :: viewer.entries[0..<viewer.entries.count]
    for i in cast[usize](1)..<entries.count {
        j := i
        loop {
            if j == 0 || j >= entries.count {
                break
            }
            before :: j - 1
            moved :: entries[j]
            if !comes_before(moved, entries[before]) {
                break
            }
            entries[j] = entries[before]
            entries[before] = moved
            j = before
        }
    }
}

/** Whether an entry's listed before another: a folder before a file, then by name's bytes. */
comes_before :: fn(a : os.DirectoryEntry, b : os.DirectoryEntry) -> bool {
    if a.is_directory != b.is_directory {
        return a.is_directory
    }
    return language.text_order(a.name, b.name) < 0
}

/**
 * Show a file: read it, and write out what it holds, a typed file's value, its text, or its bytes in hexadecimal.
 *
 * @param path Its path beneath home, copied.
 */
show_file :: fn(viewer : ptr[mut Viewer], path : string) {
    stop_playing(viewer)
    runtime.array_reset(&viewer.sound_data)
    runtime.array_reset(&viewer.shown_path)
    add_bytes(&viewer.shown_path, string_bytes(path))
    runtime.array_reset(&viewer.note)
    runtime.array_reset(&viewer.text)
    runtime.array_reset(&viewer.shown_data)
    viewer.viewing = true
    viewer.window.due = true
    shown :: written(viewer, path)
    set_text(viewer, shown)
    if viewer.note.count > 0 {
        gui_kit.log_to(viewer.log, "viewer: showing %, %", path, text_of(ui.contents(&viewer.note)))
    }
    else {
        gui_kit.log_to(viewer.log, "viewer: showing %", path)
    }
}

/**
 * Show what was pasted, typed: its value written out by its type, found as a typed file's is, under "What was pasted".
 *
 * @param pasted The paste's typed data, copied; another program's, decoded as a stranger's (language.decode).
 */
show_pasted :: fn(viewer : ptr[mut Viewer], pasted : gui_kit.TypedPaste) {
    stop_playing(viewer)
    runtime.array_reset(&viewer.sound_data)
    runtime.array_reset(&viewer.shown_path)
    add_bytes(&viewer.shown_path, string_bytes("What was pasted"))
    runtime.array_reset(&viewer.note)
    runtime.array_reset(&viewer.text)
    runtime.array_reset(&viewer.shown_data)
    viewer.viewing = true
    viewer.window.due = true
    viewer.shown_hash = pasted.schema
    add_bytes(&viewer.shown_data, pasted.bytes[0..<pasted.bytes.count])
    set_text(viewer, typed_text(viewer, pasted.schema, pasted.bytes[0..<pasted.bytes.count]))
    gui_kit.log_to(viewer.log, "viewer: showing what was pasted, %", text_of(ui.contents(&viewer.note)))
}

/**
 * Read a file, and write out what it holds.
 *
 * @return What's to be shown, on the heap; note's set for a typed file's type, or why it couldn't be read.
 */
written :: fn(viewer : ptr[mut Viewer], path : string) -> string {
    if !viewer.has_home {
        return say(viewer, "There's no home to read it from.")
    }
    file :: match os.open_in(viewer.home, path, .READ) {
        case Ok(opened) => opened
        case Error(error) => return say(viewer, language.message("It couldn't be opened: %.", error))
    }
    defer os.close(file)
    size, hash, described :: os.file_info(file)
    if described is_some {
        return say(viewer, "It couldn't be read.")
    }
    most :: if size < MAX_FILE_BYTES { size } else { MAX_FILE_BYTES }
    bytes, made :: runtime.new_array(u8, cast[usize](most))
    if made != null {
        return say(viewer, "There's no memory to read it.")
    }
    defer runtime.free_array(bytes)
    filled := cast[usize](0)
    loop {
        if filled >= bytes.count {
            break
        }
        count :: match os.read(file, bytes[filled..<bytes.count]) {
            case Ok(read) => read
            case Error(_) => return say(viewer, "It couldn't be read.")
        }
        if count == 0 {
            break
        }
        filled += count
    }
    if filled > bytes.count {
        return say(viewer, "It couldn't be read.")
    }
    held :: bytes[0..<filled]
    if !os.all_zero(hash) {
        // Kept whole, to be copied, only when it was read whole
        if cast[u64](filled) == size {
            viewer.shown_hash = hash
            add_bytes(&viewer.shown_data, held)
        }
        return typed_text(viewer, hash, held)
    }
    // A sound, read whole: said to be one, and played with Play
    if cast[u64](filled) == size {
        match pcm.read_wav(held) {
            case Ok(wav) => if wav.format.rate >= sound_protocol.MIN_RATE && wav.format.rate <= sound_protocol.MAX_RATE {
                return sound_text(viewer, wav)
            }
            case Error(_) => {}
        }
    }
    unread :: size - cast[u64](filled)
    tail :: if unread > 0 { language.message("\n(% more bytes not read)", unread) } else { "" }
    if is_text(held) {
        return language.joined(text_of(held), tail)
    }
    add_bytes(&viewer.note, string_bytes(language.message("% bytes, not text, in hexadecimal", size)))
    return hex_of(held)
}

/**
 * Keep a WAV file's sound to play, and say what it is.
 *
 * @param viewer The viewer, whose sound's kept and note set.
 * @param wav The file, read.
 * @return What's shown of it, on the heap: its format and length, and how to play it.
 */
sound_text :: fn(viewer : ptr[mut Viewer], wav : pcm.Wav) -> string {
    viewer.sound_format = sound_protocol.Format.{
        sample = cast[u8](wav.format.sample),
        rate = wav.format.rate,
        channels = wav.format.channels,
    }
    viewer.sound_ms = cast[u64](wav.frames) * 1000 / cast[u64](wav.format.rate)
    add_bytes(&viewer.sound_data, wav.data)
    add_bytes(&viewer.note, string_bytes(language.message("a sound, % ms", viewer.sound_ms)))
    return language.message(
        "% Hz, % channels, % bits a sample, % ms.\n%",
        wav.format.rate,
        wav.format.channels,
        pcm.sample_bytes(wav.format.sample) * 8,
        viewer.sound_ms,
        if viewer.sound is_some { "Play plays it at the session's volume." } else { "There's no sound to play it on." }
    )
}

/**
 * Write out a typed file's value, by the type whose schema hash it has, found among the manifests of the programs the
 * session can run: the first type with that hash, in the order the programs are listed.
 *
 * @return The value written out as the shell writes it, on the heap; why not, with note set, if no manifest has it.
 */
typed_text :: fn(viewer : ptr[mut Viewer], hash : u8[32], bytes : u8[]) -> string {
    for index in cast[u32](0)..<MAX_PROGRAMS {
        name :: program_name(viewer, index) or_break
        manifest := manifest_of(viewer, name) or_continue
        defer schema.free(&manifest)
        for i in 0..<manifest.types.count {
            if schema.hash_rooted(&manifest, i) == hash {
                value :: language.decode(&manifest, i, bytes, 0, 0)
                add_bytes(
                    &viewer.note,
                    string_bytes(language.message("a % of %", language.type_text(&manifest, i), name))
                )
                storage, made :: runtime.new_array(u8, MAX_SHOWN_BYTES)
                if made != null {
                    return say(viewer, "There's no memory to show it.")
                }
                defer runtime.free_array(storage)
                out := text_buffer.make(storage)
                language.render(&out, value)
                return strings.clone(text_buffer.as_string(&out)) or_else say(viewer, "There's no memory to show it.")
            }
        }
    }
    return say(viewer, "It's a typed file, and no program here has its type.")
}

/** Ask the programs connection something, giving its answer. */
ask :: fn(viewer : ptr[mut Viewer], out : ptr[mut os.Outgoing], into : ptr[mut os.Incoming]) -> programs.Response? {
    connection :: viewer.programs or_return null
    if programs.send_request(connection.end, viewer.programs_port, out) is_some {
        return null
    }
    match programs.receive_response(connection.end, viewer.programs_port, into, true) {
        case Received => return os.message_of[programs.Response](into)^
        case _ => return null
    }
}

/** The name of the program at an index of the session's list, on the heap; null past them. */
program_name :: fn(viewer : ptr[mut Viewer], index : u32) -> string? {
    out := os.Outgoing.{}
    request :: os.begin[programs.Request](&out)
    request^ = .List(index)
    into := os.Incoming.{}
    answer :: ask(viewer, &out, &into) or_return null
    match answer {
        case Named(given) => {
            copied :: strings.clone(text_of(os.items(&into, given))) or_return null
            return copied
        }
        case _ => return null
    }
}

/**
 * Read a program's manifest, asked for alone (ManifestOf), so nothing of the store's is held for it.
 *
 * @return The manifest, the caller's to free (schema.free); null if there's no such program, the answer didn't come,
 *     it's past MAX_MANIFEST bytes, or it doesn't read.
 */
manifest_of :: fn(viewer : ptr[mut Viewer], name : string) -> schema.Schema? {
    out := os.Outgoing.{}
    // Begun before the name's appended, as begin starts the message afresh
    request :: os.begin[programs.Request](&out)
    request^ = .ManifestOf(os.append(&out, string_bytes(name)))
    into := os.Incoming.{}
    answer :: ask(viewer, &out, &into) or_return null
    given :: match answer {
        case Manifest(given) => given
        case _ => return null
    }
    defer slop_os.handle_close(cast[slop_os.Handle](given.record))
    if given.size == 0 || given.size > MAX_MANIFEST {
        return null
    }
    bytes, made :: runtime.new_array(u8, cast[usize](given.size))
    if made != null {
        return null
    }
    defer runtime.free_array(bytes)
    if slop_os.memory_read(given.record, 0, bytes) is_error {
        return null
    }
    return schema.parse(bytes)
}

/** Say why a file isn't shown: the reason in note, and nothing to show. */
say :: fn(viewer : ptr[mut Viewer], why : string) -> string {
    add_bytes(&viewer.note, string_bytes(why))
    return ""
}

/** Keep what's shown, cut at MAX_SHOWN_BYTES, and where each of its lines starts. */
set_text :: fn(viewer : ptr[mut Viewer], shown : string) {
    runtime.array_reset(&viewer.text)
    runtime.array_reset(&viewer.lines)
    bytes :: string_bytes(shown)
    kept :: if bytes.count > MAX_SHOWN_BYTES { bytes[0..<MAX_SHOWN_BYTES] } else { bytes }
    add_bytes(&viewer.text, kept)
    runtime.array_add(&viewer.lines, cast[usize](0))
    for byte, i in kept {
        if byte == 10 {
            runtime.array_add(&viewer.lines, i + 1)
        }
    }
    // A last line break ends the last line, rather than starting an empty one
    if kept.count > 0 && kept[kept.count - 1] == 10 && viewer.lines.count > 1 {
        runtime.array_remove(&viewer.lines, viewer.lines.count - 1)
    }
}

/** Whether bytes are text: no 0 byte, and UTF-8 as far as a code point cut off at their end. */
is_text :: fn(bytes : u8[]) -> bool {
    at := cast[usize](0)
    loop {
        if at >= bytes.count {
            return true
        }
        lead :: bytes[at]
        if lead == 0 {
            return false
        }
        length :: if lead < 0x80 {
            cast[usize](1)
        }
        else if lead & 0xe0 == 0xc0 && lead >= 0xc2 {
            cast[usize](2)
        }
        else if lead & 0xf0 == 0xe0 {
            cast[usize](3)
        }
        else if lead & 0xf8 == 0xf0 && lead <= 0xf4 {
            cast[usize](4)
        }
        else {
            return false
        }
        for i in cast[usize](1)..<length {
            // Cut off at the end: the file goes on past what was read
            if at + i >= bytes.count {
                return true
            }
            if bytes[at + i] & 0xc0 != 0x80 {
                return false
            }
        }
        at += length
    }
}

/** Bytes in hexadecimal, HEX_LINE_BYTES a line after their offset, at most MAX_HEX_BYTES; on the heap. */
hex_of :: fn(bytes : u8[]) -> string {
    out : u8[..]
    shown :: if bytes.count > MAX_HEX_BYTES { bytes[0..<MAX_HEX_BYTES] } else { bytes }
    at := cast[usize](0)
    loop {
        if at >= shown.count {
            break
        }
        // The offset, eight digits
        for shift in u32.[28, 24, 20, 16, 12, 8, 4, 0] {
            runtime.array_add(&out, hex_digit(at >> shift))
        }
        for i in cast[usize](0)..<HEX_LINE_BYTES {
            runtime.array_add(&out, cast[u8](' '))
            if at + i < shown.count {
                byte :: shown[at + i]
                runtime.array_add(&out, hex_digit(cast[usize](byte >> 4)))
                runtime.array_add(&out, hex_digit(cast[usize](byte)))
            }
        }
        runtime.array_add(&out, cast[u8](10))
        at += HEX_LINE_BYTES
    }
    if bytes.count > shown.count {
        add_bytes(&out, string_bytes(language.message("(% more bytes not shown)\n", bytes.count - shown.count)))
    }
    return if out.count > 0 { string_of(&out[0], out.count) } else { "" }
}

/** Add bytes to the end of an array. */
add_bytes :: fn(to : ptr[mut u8[..]], bytes : u8[]) {
    for byte in bytes {
        runtime.array_add(to, byte)
    }
}

/** The lowercase hexadecimal digit of a number's low four bits. */
hex_digit :: fn(value : usize) -> u8 {
    low :: cast[u8](value & 15)
    return if low < 10 { cast[u8]('0') + low } else { cast[u8]('a') + low - 10 }
}

/** Cut an array to its first count bytes; one no longer is left as it is. */
truncate :: fn(bytes : ptr[mut u8[..]], count : usize) {
    loop {
        if bytes.count <= count {
            break
        }
        runtime.array_remove(bytes, bytes.count - 1)
    }
}

/** Bytes as text, a view of them. */
text_of :: fn(bytes : u8[]) -> string {
    return if bytes.count > 0 { string_of(&bytes[0], bytes.count) } else { "" }
}
