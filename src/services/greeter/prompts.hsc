package greeter

import runtime from "base:runtime"
import os from "std:os"
import slop_os from "std:os/slop_os"
import files from "std:os/slop_os/files"
import read_only_dir from "std:os/slop_os/read_only_dir"
import ui from "std:ui"
import gui_kit from "../../gui_kit"
import prompt from "../../protocols/prompt"
import surface from "../../protocols/surface"

/*
 * The powerbox's prompts in the GUI's trusted layer (decisions/0192, 15g; 0156, 0158): what a GUI session's powerbox
 * asks the user, on the prompt connection the greeter gave its session, is drawn in a window of the trusted layer,
 * above every client's and with the keyboard while it's shown, so no program can draw it or answer it.
 *
 * - A file or a directory: the chooser, over the home the powerbox gave, read only. A folder's entries are listed,
 *   folders first; one clicked opens it, or, a file, chooses it. Up goes back. For a directory, "Choose this folder"
 *   chooses the one it's in; for a file to write, a name typed first, the program's suggestion to start, and "New
 *   file" or Enter in it chooses a new file of that name in it.
 *   An Ask that may be kept offers "Keep for next time".
 * - Debugging one of the session's own programs, or a network connection allowing more than the session's: Allow or
 *   Refuse, with no password, as on the console (decisions/0185, 0188).
 * - What needs the administrator's password (an account, a shutdown or restart, another's program debugged, a trace,
 *   the system's log) or the account service (a public key added or removed, the keys listed) is refused, said in its
 *   debug log, as the GUI's elevation isn't built: those are the console's trusted path's.
 *
 * Refuse, Escape, and the session ending all refuse. It says what it does in its debug log: "asked by <program> for
 * <what>", "chose <path> for <program>", "allowed <program>", "refused <program>".
 */

/** The prompt window's width, in pixels. */
PROMPT_WIDTH : u32 : 480
/** Its height. */
PROMPT_HEIGHT : u32 : 440
/** The most bytes of an Ask's requester, purpose or suggestion kept; past them, cut. */
ASK_BYTES :: 160
/** The most entries of a folder listed. */
MAX_ENTRIES :: 256

/** An entry of the folder the chooser's in. */
Entry :: struct {
    /** Its name, on the heap; freed when the folder's listed again. */
    name : u8[..],
    /** Whether it's a folder, which opens when clicked, rather than a file. */
    directory : bool,
}

/** What the session's powerbox is waiting on the user for, while one's asked. */
Asking :: struct {
    /** Whether something's asked, and the prompt window shows it. */
    active : bool,
    /** The program asking, by the name the session manager gave it. */
    requester : u8[..],
    /** Why it asks, in its own words. */
    purpose : u8[..],
    /** What it asks for. */
    kind : prompt.Kind,
    /** Whether it would write what it's given. */
    write : bool,
    /** Whether it asked to keep what it's given, so "Keep for next time" is offered. */
    keep : bool,
    /** Whether the user's ticked "Keep for next time". */
    keep_ticked : bool,
    /** The home to choose in, read only, the greeter's until the Ask's answered; NO_HANDLE for none. */
    home : slop_os.Channel,
    /** The port home's bound to; NO_HANDLE for none. */
    home_port : slop_os.Port,
    /** The folder the chooser's in, its path beneath home; empty for home itself. */
    folder : u8[..],
    /** What's in it, folders first, then by name. */
    entries : Entry[..],
    /** A new file's name, as typed; it starts as the Ask's suggestion. */
    typed : u8[..],
}

/**
 * Take what the session's powerbox asks, one Ask at a time: a file, a directory, debugging or the network shown in the
 * prompt window; anything else refused at once.
 *
 * @param greeter The greeter, its prompt connection read without waiting while nothing's asked; its prompt window
 *     made the first time one's shown.
 */
take_prompts :: fn(greeter : ptr[mut Greeter]) {
    if greeter.prompts == cast[slop_os.Channel](slop_os.NO_HANDLE) || greeter.asking.active {
        return void
    }
    if cast[slop_os.Handle](greeter.prompts_port) == slop_os.NO_HANDLE {
        greeter.prompts_port = os.port_for(slop_os.startup_block().budget, greeter.prompts)
            or_else cast[slop_os.Port](slop_os.NO_HANDLE)
        if cast[slop_os.Handle](greeter.prompts_port) == slop_os.NO_HANDLE {
            return void
        }
    }
    into := os.Incoming.{}
    match prompt.receive_request(greeter.prompts, greeter.prompts_port, &into, false) {
        case Received => {}
        case _ => return void
    }
    asked :: match os.message_of[prompt.Request](&into)^ {
        case Ask(given) => given
    }
    made := Asking.{
        active = true,
        kind = asked.kind,
        write = asked.write,
        keep = asked.keep,
        home = asked.home.end,
        home_port = cast[slop_os.Port](slop_os.NO_HANDLE),
    }
    add_cut(&made.requester, os.items(&into, asked.requester))
    add_cut(&made.purpose, os.items(&into, asked.purpose))
    add_cut(&made.typed, os.items(&into, asked.suggested))
    greeter.asking = made
    runtime.log_info("asked by % for %", text(&greeter.asking.requester), what_of(&greeter.asking))
    shown :: asked.kind == .File || asked.kind == .Directory || asked.kind == .Debug || asked.kind == .Network
    if !shown {
        runtime.log_info("the GUI can't ask for %: that's the console's trusted path's", what_of(&greeter.asking))
        answer(greeter, null, false)
        return void
    }
    if asked.kind == .File || asked.kind == .Directory {
        greeter.asking.home_port = os.port_for(slop_os.startup_block().budget, greeter.asking.home)
            or_else cast[slop_os.Port](slop_os.NO_HANDLE)
        list_folder(greeter)
    }
    if greeter.prompt_window == null {
        budget :: slop_os.startup_block().budget
        // Its own connection, made from the trusted one, so it's in the trusted layer too
        connection :: surface.connect(greeter.window.end, greeter.window.port, budget)
        match connection {
            case Some(given) => greeter.prompt_window = gui_kit.open_on(given, "Asked", PROMPT_WIDTH, PROMPT_HEIGHT)
            case None => {}
        }
    }
    match greeter.prompt_window {
        case Some(window) => window.due = true
        case None => {
            runtime.log_info("the prompt window couldn't be made")
            answer(greeter, null, false)
        }
    }
}

/** What an Ask asks for, as the log and the window say it. */
what_of :: fn(asking : ptr[Asking]) -> string {
    return match asking.kind {
        case .File => if asking.write {
            "a file to write"
        }
        else {
            "a file to read"
        }
        case .Directory => if asking.write {
            "a folder to write in"
        }
        else {
            "a folder to read"
        }
        case .Account => "a new account"
        case .ShutDown => "the system shut down"
        case .Restart => "the system restarted"
        case .Debug => "one of your programs debugged"
        case .DebugOther => "another user's program debugged"
        case .Trace => "the whole system traced"
        case .SystemLog => "the system's log"
        case .Network => "more of the network"
        case .AddKey => "a public key added to your account"
        case .RemoveKey => "a public key removed from your account"
        case .ListKeys => "your public keys"
        case _ => "something it doesn't say"
    }
}

/**
 * A frame of the prompt window: who asks, for what and why, and the chooser or Allow; Refuse, and Escape, refuse.
 *
 * @param greeter The greeter, its prompt window made and something asked.
 */
prompt_frame :: fn(greeter : ptr[mut Greeter]) {
    window :: greeter.prompt_window or_return void
    asking :: &greeter.asking
    u :: gui_kit.begin(window)
    escaped :: ui.key_pressed(u, .Escape)
    _ = ui.open(u, "body", ui.Box.{width = ui.grow(), height = ui.grow(), padding_x = 16, padding_y = 14, gap = 8})
    _ = gui_kit.label_of(u, string.[text(&asking.requester), " asks for ", what_of(asking)], ui.TextStyle.{size = 17})
    if asking.purpose.count > 0 {
        _ = gui_kit.label_of(u, string.["“", text(&asking.purpose), "”"], ui.TextStyle.{size = 14})
    }
    chosen := false
    chosen_path : u8[..]
    defer runtime.array_free(&chosen_path)
    new := false
    allowed := false
    if asking.kind == .File || asking.kind == .Directory {
        folder :: text(&asking.folder)
        _ = gui_kit.label_of(
            u,
            if folder.count == 0 { string.["In your home"] } else { string.["In ", folder] },
            ui.TextStyle.{size = 14}
        )
        // A new file's name first, so Tab reaches it first and Enter in it makes the file
        if asking.kind == .File && asking.write {
            _ = ui.text_field(u, "New file's name", &asking.typed)
            if asking.typed.count > 0 && ui.button(u, "New file") {
                chosen = true
                new = true
            }
        }
        up :: folder.count > 0 && ui.button(u, "Up")
        clicked := asking.entries.count
        _ = ui.scroll_area(u, "entries", ui.Box.{width = ui.grow(), height = ui.grow(), gap = 4})
        for &entry, i in asking.entries {
            // Only folders, for a folder asked for
            if entry.directory || asking.kind == .File {
                name :: text(&entry.name)
                if gui_kit.button_of(u, string.[name, if entry.directory { "/" } else { "" }], key = cast[u64](i)) {
                    clicked = i
                }
            }
        }
        ui.close(u)
        if asking.kind == .Directory && ui.button(u, "Choose this folder") {
            chosen = true
            add_bytes(&chosen_path, ui.contents(&asking.folder))
        }
        if asking.keep {
            _ = ui.checkbox(u, "Keep for next time", &asking.keep_ticked)
        }
        if up {
            cut := cast[usize](0)
            for byte, i in asking.folder {
                if byte == cast[u8]('/') {
                    cut = i
                }
            }
            truncate(&asking.folder, cut)
            list_folder(greeter)
            window.due = true
        }
        else if !new && clicked < asking.entries.count {
            entry :: &asking.entries[clicked]
            if entry.directory {
                path : u8[..]
                add_path(&path, ui.contents(&asking.folder), ui.contents(&entry.name))
                runtime.array_reset(&asking.folder)
                add_bytes(&asking.folder, ui.contents(&path))
                runtime.array_free(&path)
                list_folder(greeter)
                window.due = true
            }
            else {
                chosen = true
                add_path(&chosen_path, ui.contents(&asking.folder), ui.contents(&entry.name))
            }
        }
    }
    else {
        allowed = ui.button(u, "Allow")
    }
    refused :: ui.button(u, "Refuse")
    ui.close(u)
    submitted := false
    for event in gui_kit.finish(window) {
        submitted = submitted || event.kind == .Submitted
    }
    // Enter in the new file's name, its only field, makes the file, as New file does
    if submitted && asking.kind == .File && asking.write && asking.typed.count > 0 {
        chosen = true
        new = true
    }
    if new {
        add_path(&chosen_path, ui.contents(&asking.folder), ui.contents(&asking.typed))
    }
    if chosen {
        answer(greeter, ui.contents(&chosen_path), new)
    }
    else if allowed {
        answer_allowed(greeter)
    }
    else if refused || escaped {
        answer(greeter, null, false)
    }
}

/**
 * Answer what's asked: what was chosen, or Refused; then let go of it, and hide the prompt window.
 *
 * @param greeter The greeter, something asked.
 * @param path The path chosen beneath the home, a new file's when new is set; null to refuse.
 * @param new Whether path names a new file, for the program to make.
 */
answer :: fn(greeter : ptr[mut Greeter], path : u8[]?, new : bool) {
    asking :: &greeter.asking
    out := os.Outgoing.{}
    response :: os.begin[prompt.Response](&out)
    match path {
        case Some(chosen) => {
            response^ = .Chosen(
                prompt.Choice.{path = os.append(&out, chosen), new = new, keep = asking.keep && asking.keep_ticked}
            )
            runtime.log_info(
                "chose % for %",
                if chosen.count > 0 { string_of(&chosen[0], chosen.count) } else { "the home" },
                text(&asking.requester)
            )
        }
        case None => {
            response^ = .Refused
            runtime.log_info("refused %", text(&asking.requester))
        }
    }
    _ = prompt.send_response(greeter.prompts, greeter.prompts_port, &out)
    drop_asking(greeter)
}

/** Answer what's asked with Allowed, for debugging or the network; then let go of it. */
answer_allowed :: fn(greeter : ptr[mut Greeter]) {
    out := os.Outgoing.{}
    response :: os.begin[prompt.Response](&out)
    response^ = .Allowed
    runtime.log_info("allowed %", text(&greeter.asking.requester))
    _ = prompt.send_response(greeter.prompts, greeter.prompts_port, &out)
    drop_asking(greeter)
}

/**
 * Let go of what's asked, answered or not: its home closed, its text and entries freed, and the prompt window hidden.
 *
 * @param greeter The greeter; nothing's sent.
 */
drop_asking :: fn(greeter : ptr[mut Greeter]) {
    asking :: &greeter.asking
    for each in slop_os.Handle.[cast[slop_os.Handle](asking.home), cast[slop_os.Handle](asking.home_port)] {
        if each != slop_os.NO_HANDLE {
            _ = slop_os.handle_close(each)
        }
    }
    free_entries(asking)
    runtime.array_free(&asking.requester)
    runtime.array_free(&asking.purpose)
    runtime.array_free(&asking.folder)
    runtime.array_free(&asking.typed)
    greeter.asking = Asking.{}
    match greeter.prompt_window {
        case Some(window) => gui_kit.hide(window)
        case None => {}
    }
}

/** Free the chooser's entries, and empty them. */
free_entries :: fn(asking : ptr[mut Asking]) {
    for &entry in asking.entries {
        runtime.array_free(&entry.name)
    }
    runtime.array_free(&asking.entries)
}

/**
 * List the folder the chooser's in, from the home given: up to MAX_ENTRIES of its entries, folders first, then by
 * name. Empty if it can't be opened or listed.
 *
 * @param greeter The greeter, a file or a directory asked.
 */
list_folder :: fn(greeter : ptr[mut Greeter]) {
    asking :: &greeter.asking
    free_entries(asking)
    if asking.home == cast[slop_os.Channel](slop_os.NO_HANDLE)
        || cast[slop_os.Handle](asking.home_port) == slop_os.NO_HANDLE {
        return void
    }
    budget :: slop_os.startup_block().budget
    // The folder beneath the home, opened, or the home itself
    listed := asking.home
    folder :: ui.contents(&asking.folder)
    if folder.count > 0 {
        out := os.Outgoing.{}
        opening :: os.begin[read_only_dir.Request](&out)
        opening^ = .OpenDirectory(os.append(&out, folder))
        into := os.Incoming.{}
        match ask_read_only(asking.home, asking.home_port, &out, &into) {
            case OpenedDirectory(opened) => listed = opened.end
            case _ => return void
        }
    }
    defer {
        if listed != asking.home {
            _ = slop_os.handle_close(cast[slop_os.Handle](listed))
        }
    }
    port :: if listed == asking.home {
        asking.home_port
    }
    else {
        os.port_for(budget, listed) or_else cast[slop_os.Port](slop_os.NO_HANDLE)
    }
    if cast[slop_os.Handle](port) == slop_os.NO_HANDLE {
        return void
    }
    defer {
        if port != asking.home_port {
            _ = slop_os.handle_close(cast[slop_os.Handle](port))
        }
    }
    cursor := cast[u64](0)
    loop {
        if asking.entries.count >= MAX_ENTRIES {
            break
        }
        out := os.Outgoing.{}
        os.begin[read_only_dir.Request](&out)^ = .List(cursor)
        into := os.Incoming.{}
        match ask_read_only(listed, port, &out, &into) {
            case Listed(found) => {
                made := Entry.{directory = found.kind == .Directory}
                add_bytes(&made.name, os.items(&into, found.name))
                insert_sorted(&asking.entries, made)
                cursor = found.next
            }
            case _ => break
        }
    }
}

/** Put an entry among others in order: folders first, then by name's bytes. */
insert_sorted :: fn(entries : ptr[mut Entry[..]], made #escaping : Entry) {
    runtime.array_add(entries, made)
    held := entries^
    all :: held[0..<held.count]
    j := all.count - 1
    loop {
        if j == 0 || j >= all.count {
            break
        }
        before :: j - 1
        moved :: all[j]
        if !comes_before(&moved, &all[before]) {
            break
        }
        all[j] = all[before]
        all[before] = moved
        j = before
    }
}

/** Whether an entry's listed before another: a folder before a file, then by name's bytes. */
comes_before :: fn(a : ptr[Entry], b : ptr[Entry]) -> bool {
    if a.directory != b.directory {
        return a.directory
    }
    first :: ui.contents(&a.name)
    second :: ui.contents(&b.name)
    for byte, i in first {
        if i >= second.count {
            return false
        }
        if byte != second[i] {
            return byte < second[i]
        }
    }
    return first.count < second.count
}

/**
 * Send one request on a read-only directory's connection and wait for its answer.
 *
 * @return The answer; Unsupported also when it couldn't be sent or the connection failed.
 */
ask_read_only :: fn(
    end : slop_os.Channel,
    port : slop_os.Port,
    out : ptr[mut os.Outgoing],
    into : ptr[mut os.Incoming]
) -> read_only_dir.Response {
    if read_only_dir.send_request(end, port, out) is_some {
        return .Unsupported
    }
    match read_only_dir.receive_response(end, port, into, true) {
        case Received => return os.message_of[read_only_dir.Response](into)^
        case _ => return .Unsupported
    }
}

/** Add a path beneath a folder: folder/name, or name alone beneath the home. */
add_path :: fn(path : ptr[mut u8[..]], folder : u8[], name : u8[]) {
    add_bytes(path, folder)
    if folder.count > 0 {
        runtime.array_add(path, cast[u8]('/'))
    }
    add_bytes(path, name)
}

/** Add bytes to an array, at most ASK_BYTES of them. */
add_cut :: fn(to : ptr[mut u8[..]], bytes : u8[]) {
    for byte, i in bytes {
        if i >= ASK_BYTES {
            break
        }
        runtime.array_add(to, byte)
    }
}

/** Add bytes to the end of an array. */
add_bytes :: fn(to : ptr[mut u8[..]], bytes : u8[]) {
    for byte in bytes {
        runtime.array_add(to, byte)
    }
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

/** An array's bytes as text, a view of them. */
text :: fn(bytes : ptr[u8[..]]) -> string {
    return string_of_bytes(ui.contents(bytes))
}
