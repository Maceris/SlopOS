/**
 * The powerbox's chooser (decisions/0156), on the trusted path. A session's powerbox asks on its prompt connection
 * (Ask): the request's shown on the status line, naming the program and what it asks for, until the secure attention
 * key opens the chooser over the session, which lists the directory it's in from the home the powerbox gave, read only.
 * Up and Down move, Enter opens a directory or chooses, typing narrows the list to the names with what's typed in them
 * and, for a file to write, offers a new file of that name; Escape refuses. A request that may be kept offers "keep for
 * next time", off until Tab ticks it (decisions/0158). The answer goes back on the prompt connection, and the session's
 * drawn again.
 */
package terminal_service

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import text_buffer from "std"
import terminal from "std/os/slop_os"
import read_only_dir from "std/os/slop_os"
import files from "std/os/slop_os"
import account_records from "../../account_records"
import prompt from "../../protocols/prompt"
import screen from "../../screen"

/**
 * The first of the port keys the views' prompt connections are bound under: view i's is PROMPT_KEY + i, for i below
 * MAX_VIEWS.
 */
PROMPT_KEY : u64 : 1100
/** The most entries of a directory the chooser lists; those past it aren't shown. */
CHOOSER_ENTRIES :: 64
/** The most bytes of an entry's name, or of the filter, kept; a longer name is cut short. */
ENTRY_BYTES :: 64
/** The most bytes of a path beneath the home the chooser or a kept grant holds; a longer one is cut short. */
PATH_BYTES :: 256
/** The most bytes of an Ask's requester or purpose kept; longer text is cut short. */
ASK_BYTES :: 96
/** The panel row the chooser's first item is drawn on. */
ITEMS_ROW : u16 : 7
/** How many of the chooser's items are shown at a time, a window that follows the chosen one. */
ITEMS_SHOWN :: 13

/**
 * A request a session's powerbox is waiting on the user for: whose, why, what it suggests, and the home to choose in.
 */
Asked :: struct {
    /** The program asking, by the name the session manager gave it; its first requester_count bytes. */
    requester : u8[ASK_BYTES],
    /** How many bytes of requester are used, 0 to ASK_BYTES. */
    requester_count : usize,
    /** Why it asks, in the program's words; its first purpose_count bytes. */
    purpose : u8[ASK_BYTES],
    /** How many bytes of purpose are used, 0 to ASK_BYTES. */
    purpose_count : usize,
    /** A file's suggested name, which the chooser's filter starts with; its first suggested_count bytes. */
    suggested : u8[ENTRY_BYTES],
    /** How many bytes of suggested are used, 0 to ENTRY_BYTES; 0 for no suggestion. */
    suggested_count : usize,
    /** For AddKey, the key's line, all of it, as suggested; its first key_line_count bytes. */
    key_line : u8[account_records.KEY_LINE_BYTES],
    /** How many bytes of key_line are used; a line longer than it isn't kept, and the request's refused. */
    key_line_count : usize,
    /** What's asked for: a file or a directory, chosen in the chooser, or an account, made on the elevation screen. */
    kind : prompt.Kind,
    /** Whether the program asks to write what's chosen, not only read it; a file to write may be a new one. */
    write : bool,
    /** Whether the program asked to keep what's chosen, so the chooser offers "keep for next time". */
    keep : bool,
    /**
     * The home to choose in, a read-only directory connection the service holds while the request waits, closed by
     * drop_ask; NONE for none.
     */
    home : slop_os.Channel,
}

/** One entry of the directory the chooser is in. */
Entry :: struct {
    /** The entry's name, its first count bytes. */
    name : u8[ENTRY_BYTES],
    /** How many bytes of name are used, 0 to ENTRY_BYTES. */
    count : usize,
    /** Whether it's a directory, which Enter opens, rather than a file. */
    directory : bool,
}

/**
 * The chooser's state: the directory it's in beneath the home, what's typed, what the directory has, and the item
 * chosen.
 */
Chooser :: struct {
    /** The directory it's in, a path beneath the home without a leading or trailing /; empty for the home itself. */
    path : u8[PATH_BYTES],
    /** How many bytes of path are used, 0 to PATH_BYTES. */
    path_count : usize,
    /** What's typed: only entries whose names contain it are listed, and a new file is offered by this name. */
    filter : u8[ENTRY_BYTES],
    /** How many bytes of filter are used, 0 to ENTRY_BYTES. */
    filter_count : usize,
    /** The directory's entries, as the volume lists them; the first entry_count are used. */
    entries : Entry[CHOOSER_ENTRIES],
    /** How many of entries are used, 0 to CHOOSER_ENTRIES. */
    entry_count : usize,
    /** The index of the chosen item among those items_of gives, which Enter acts on. */
    selected : usize,
    /** Whether the user's ticked "keep for next time", which Tab toggles; sent only if the request may be kept. */
    keep : bool,
}

/** What one of the chooser's items is. */
ItemKind :: enum {
    /** The directory it's in, chosen as the answer, for a directory asked for. */
    Here,
    /** The directory above, which Enter goes up to; offered below the home only. */
    Up,
    /** One of the directory's entries, by its index in Chooser.entries. */
    Entry,
    /** A new file of the name typed, for a file to write that no entry has that name. */
    New,
}

/** One line of the chooser's list. */
Item :: struct {
    /** What the line is. */
    kind : ItemKind,
    /** For an Entry, its index in Chooser.entries; unused for the others. */
    entry : usize,
}

/**
 * Take what's waiting on the views' prompt connections: an Ask is kept in its view for the user, and shown on the
 * status line if its view is the one shown and nothing of the trusted path's is up.
 *
 * A view that's already asking isn't read, so one Ask waits at a time and the next stays in its connection. Requests
 * this side doesn't know are answered Unsupported. A connection that's failed is closed and set to NONE, leaving that
 * view without a powerbox.
 *
 * @param service The service's state, from its main loop: each view's prompt connection is read, an Ask kept in the
 *     view as asking, a failed connection closed and set to NONE, and the status line drawn for the active view.
 * @param into Where requests are received; an Ask's home handle moves into the view's Asked.
 */
take_prompts :: fn(service: ptr[mut Service], into: ptr[mut os.Incoming]) {
    for &each, i in service.views {
        if !each.in_use || each.prompt_end == NONE || each.asking {
            continue
        }
        match prompt.receive_request(each.prompt_end, service.port, into, false) {
            case Received => {}
            case Empty => continue
            case Unsupported => {
                _ = prompt.answer_unsupported(each.prompt_end, service.port)
                continue
            }
            case _ => {
                _ = slop_os.handle_close(cast[slop_os.Handle](each.prompt_end))
                each.prompt_end = NONE
                continue
            }
        }
        match os.message_of[prompt.Request](into)^ {
            case Ask(asked) => {
                if asked.kind == .ListKeys {
                    list_keys(service, i, asked.home.end)
                    continue
                }
                kept := Asked.{kind = asked.kind, write = asked.write, keep = asked.keep, home = asked.home.end}
                if asked.kind == .AddKey {
                    kept.key_line_count = copy_bytes(os.items(into, asked.suggested), kept.key_line[0..<kept.key_line.count])
                }
                kept.requester_count = copy_bytes(os.items(into, asked.requester), kept.requester[0..<kept.requester.count])
                kept.purpose_count = copy_bytes(os.items(into, asked.purpose), kept.purpose[0..<kept.purpose.count])
                kept.suggested_count = copy_bytes(os.items(into, asked.suggested), kept.suggested[0..<kept.suggested.count])
                each.ask = kept
                each.asking = true
                runtime.log_info("% asks for a %", bytes_text(first_of(kept.requester[0..<kept.requester.count], kept.requester_count)),
                    if kept.kind == .Directory { "directory" } else if kept.kind == .Account { "new account" }
                    else if kept.kind == .ShutDown { "shutdown" } else if kept.kind == .Restart { "restart" }
                    else if kept.kind == .Debug || kept.kind == .DebugOther { "debugger" } else if kept.kind == .Trace { "trace" }
                    else if kept.kind == .SystemLog { "read of the system's log" } else if kept.kind == .Network { "network connection" }
                    else if kept.kind == .AddKey { "key added" } else if kept.kind == .RemoveKey { "key removed" }
                    else { "file" })
                if i == service.active && !service.attention && service.setup == .Off {
                    use_active(service)
                    update_status(service)
                }
            }
        }
    }
}

/**
 * Append what's waiting to a status line: who asks for what, and the key that opens the chooser.
 *
 * @param status The status line's text so far; what doesn't fit its buffer is cut off as text_buffer does.
 * @param asked The request waiting, which isn't changed.
 */
append_asking :: fn(status: ptr[mut text_buffer.TextBuffer], asked: ptr[Asked]) {
    text_buffer.append(status, " │ ")
    text_buffer.append(status, bytes_text(first_of(asked.requester[0..<asked.requester.count], asked.requester_count)))
    text_buffer.append(status, if asked.kind == .Directory { " asks for a directory" } else if asked.kind == .Account { " asks to make an account" }
        else if asked.kind == .ShutDown { " asks to shut down" } else if asked.kind == .Restart { " asks to restart" }
        else if asked.kind == .Debug || asked.kind == .DebugOther { " asks to debug a program" }
        else if asked.kind == .Trace { " asks to trace the system" } else if asked.kind == .SystemLog { " asks to read the system's log" }
        else if asked.kind == .Network { " asks to reach the network" }
        else if asked.kind == .AddKey { " asks to add a key that logs in as you" }
        else if asked.kind == .RemoveKey { " asks to remove a key" }
        else { " asks for a file" })
    text_buffer.append(status, ": Ctrl+Alt+Delete")
}

/**
 * Open the chooser over the active view, for its file or directory request: in the home, with the suggested name typed
 * already, the best item chosen.
 *
 * Keys go to chooser_key until the request is answered or refused.
 *
 * @param service The service, its secure attention key's screen up and its active view asking.
 */
enter_chooser :: fn(service: ptr[mut Service]) {
    asked :: &view(service).ask
    service.choosing = true
    service.chooser = Chooser.{}
    service.chooser.filter_count = copy_bytes(first_of(asked.suggested[0..<asked.suggested.count], asked.suggested_count),
        service.chooser.filter[0..<service.chooser.filter.count])
    runtime.log_info("choosing for %", bytes_text(first_of(asked.requester[0..<asked.requester.count], asked.requester_count)))
    list_chooser(service)
    select_best(service)
    draw_chooser(service)
}

/**
 * Take a key while the chooser is up: Escape refuses, Tab ticks "keep for next time" if it's offered, Enter acts on the
 * item chosen, Up and Down choose, Backspace takes back the last character typed, and other text narrows the list.
 *
 * Text typed with Control or Alt is ignored, as are controls and /, which no name has.
 *
 * @param service The service, its chooser up.
 * @param event The key, by its USB HID usage and modifiers.
 * @param text The text the key typed, UTF-8, possibly empty; read only during the call.
 */
chooser_key :: fn(service: ptr[mut Service], event: terminal.Event, text: u8[]) {
    chooser :: &service.chooser
    if event.code == USAGE_ESCAPE {
        answer_ask(service, null, false)
        return void
    }
    if event.code == USAGE_TAB {
        if view(service).ask.keep {
            chooser.keep = !chooser.keep
            draw_chooser(service)
        }
        return void
    }
    if event.code == USAGE_ENTER {
        activate(service)
        return void
    }
    count :: items_of(service, null)
    if event.code == USAGE_UP {
        if chooser.selected > 0 {
            chooser.selected -= 1
        }
        draw_chooser(service)
        return void
    }
    if event.code == USAGE_DOWN {
        if chooser.selected + 1 < count {
            chooser.selected += 1
        }
        draw_chooser(service)
        return void
    }
    if event.code == USAGE_BACKSPACE {
        // The last character, its continuation bytes with it
        loop {
            if chooser.filter_count == 0 || chooser.filter_count > chooser.filter.count {
                break
            }
            chooser.filter_count -= 1
            if chooser.filter[chooser.filter_count] & 0xc0 != 0x80 {
                break
            }
        }
        select_best(service)
        draw_chooser(service)
        return void
    }
    if event.modifiers & (terminal.CONTROL | terminal.ALT) != 0 {
        return void
    }
    for byte in text {
        // What shows, and no separator, which a name can't have
        if byte >= 0x20 && byte != 0x7f && byte != cast[u8]('/') && chooser.filter_count < chooser.filter.count {
            chooser.filter[chooser.filter_count] = byte
            chooser.filter_count += 1
        }
    }
    select_best(service)
    draw_chooser(service)
}

/**
 * Take Enter on the item chosen: the directory it's in chosen (Here), the one above opened (Up), a directory entry
 * opened or a file entry chosen (Entry), or a new file of the name typed chosen (New).
 *
 * Choosing answers the request and closes the chooser; a directory's entry is never chosen, only opened, and a file's
 * entry is chosen only when a file was asked for.
 *
 * @param service The service, its chooser up.
 */
activate :: fn(service: ptr[mut Service]) {
    chooser :: &service.chooser
    items : Item[CHOOSER_ENTRIES + 3]
    count :: items_of(service, &items)
    if chooser.selected >= count || chooser.selected >= items.count {
        return void
    }
    item :: items[chooser.selected]
    asked :: &view(service).ask
    match item.kind {
        case .Here => answer_ask(service, first_of(chooser.path[0..<chooser.path.count], chooser.path_count), false)
        case .Up => {
            // The last component taken off
            at := min_count(chooser.path_count, chooser.path.count)
            loop {
                if at == 0 {
                    break
                }
                at -= 1
                if at < chooser.path.count && chooser.path[at] == cast[u8]('/') {
                    break
                }
            }
            chooser.path_count = at
            opened_directory(service)
        }
        case .Entry => {
            if item.entry >= chooser.entries.count {
                return void
            }
            entry :: &chooser.entries[item.entry]
            name :: first_of(entry.name[0..<entry.name.count], entry.count)
            if entry.directory {
                join(chooser, name)
                opened_directory(service)
            }
            else if asked.kind == .File {
                storage : u8[PATH_BYTES]
                answer_ask(service, joined(chooser, name, &storage), false)
            }
        }
        case .New => {
            storage : u8[PATH_BYTES]
            answer_ask(service, joined(chooser, first_of(chooser.filter[0..<chooser.filter.count], chooser.filter_count), &storage), true)
        }
    }
}

/**
 * List the directory the chooser is now in, with what was typed cleared, choose the best item, and draw the chooser.
 *
 * @param service The service, its chooser up, its path just changed.
 */
opened_directory :: fn(service: ptr[mut Service]) {
    service.chooser.filter_count = 0
    list_chooser(service)
    select_best(service)
    draw_chooser(service)
}

/**
 * Answer the active view's request on its prompt connection, close the chooser, and leave the secure attention key's
 * screen, drawing the session again.
 *
 * The answer, Chosen or Refused, is sent if the view still has a prompt connection, and not waited for. The request is
 * dropped and its home closed either way.
 *
 * @param service The service, its chooser up.
 * @param path The path chosen, beneath the home, empty for the home itself; null refuses. Copied into the answer, so it
 *     need only last the call.
 * @param new Whether the path names a new file for the program to make; ignored when refusing.
 */
answer_ask :: fn(service: ptr[mut Service], path: u8[]?, new: bool) {
    shown :: view(service)
    out := os.Outgoing.{}
    response :: os.begin[prompt.Response](&out)
    match path {
        case Some(chosen) => {
            response^ = .Chosen(prompt.Choice.{path = os.append(&out, chosen), new = new, keep = shown.ask.keep && service.chooser.keep})
            runtime.log_info("chose % for %", if chosen.count > 0 { bytes_text(chosen) } else { "the home" },
                bytes_text(first_of(shown.ask.requester[0..<shown.ask.requester.count], shown.ask.requester_count)))
        }
        case None => {
            response^ = .Refused
            runtime.log_info("refused %", bytes_text(first_of(shown.ask.requester[0..<shown.ask.requester.count], shown.ask.requester_count)))
        }
    }
    if shown.prompt_end != NONE {
        _ = prompt.send_response(shown.prompt_end, service.port, &out)
    }
    drop_ask(shown)
    service.choosing = false
    leave_attention(service)
}

/**
 * Let go of a view's waiting request, closing its home, and clear it; nothing is answered.
 *
 * @param each The view; if it isn't asking, its request is only cleared.
 */
drop_ask :: fn(each: ptr[mut View]) {
    if each.asking && each.ask.home != NONE {
        _ = slop_os.handle_close(cast[slop_os.Handle](each.ask.home))
    }
    each.asking = false
    each.ask = Asked.{}
}

/**
 * List the chooser's directory's entries from the active view's home: up to CHOOSER_ENTRIES of them, in the order the
 * volume lists them.
 *
 * The directory beneath the home is opened (OpenDirectory) and listed a cursor at a time (List), each answer waited
 * for; what was opened, and the ports made, are closed after. The list stops at the first answer that isn't Listed.
 * With no home, or a directory that can't be opened, it's left empty.
 *
 * @param service The service, its chooser up.
 */
list_chooser :: fn(service: ptr[mut Service]) {
    chooser :: &service.chooser
    chooser.entry_count = 0
    home :: view(service).ask.home
    if home == NONE {
        return void
    }
    budget :: slop_os.startup_block().budget
    home_port :: os.port_for(budget, home) or_return void
    defer slop_os.handle_close(cast[slop_os.Handle](home_port))
    // The directory beneath the home it's in, opened, or the home itself
    listed := home
    path :: first_of(chooser.path[0..<chooser.path.count], chooser.path_count)
    if path.count > 0 {
        out := os.Outgoing.{}
        opening :: os.begin[read_only_dir.Request](&out)
        opening^ = .OpenDirectory(os.append(&out, path))
        into := os.Incoming.{}
        match ask_read_only(home, home_port, &out, &into) {
            case OpenedDirectory(opened) => listed = opened.end
            case _ => return void
        }
    }
    defer {
        if listed != home {
            _ = slop_os.handle_close(cast[slop_os.Handle](listed))
        }
    }
    port :: if listed == home { home_port } else { os.port_for(budget, listed) or_else cast[slop_os.Port](slop_os.NO_HANDLE) }
    if cast[slop_os.Handle](port) == slop_os.NO_HANDLE {
        return void
    }
    defer {
        if port != home_port {
            _ = slop_os.handle_close(cast[slop_os.Handle](port))
        }
    }
    cursor := cast[u64](0)
    loop {
        if chooser.entry_count >= chooser.entries.count {
            break
        }
        out := os.Outgoing.{}
        os.begin[read_only_dir.Request](&out)^ = .List(cursor)
        into := os.Incoming.{}
        match ask_read_only(listed, port, &out, &into) {
            case Listed(entry) => {
                made := Entry.{directory = entry.kind == .Directory}
                made.count = copy_bytes(os.items(&into, entry.name), made.name[0..<made.name.count])
                at :: chooser.entry_count
                if at < chooser.entries.count {
                    chooser.entries[at] = made
                    chooser.entry_count = at + 1
                }
                cursor = entry.next
            }
            case _ => break
        }
    }
}

/**
 * Send one request on a read-only directory's connection and wait, with no deadline, for its answer.
 *
 * @param end The directory connection, which stays the caller's.
 * @param port A port for end, the caller's, which the answer is waited on.
 * @param out The request, built by the caller.
 * @param into Where the answer's message is received; its items, such as names, stay readable there until into is
 *     used again.
 * @return The answer; Unsupported also when the request couldn't be sent or the connection failed.
 */
ask_read_only :: fn(end: slop_os.Channel, port: slop_os.Port, out: ptr[mut os.Outgoing], into: ptr[mut os.Incoming]) -> read_only_dir.Response {
    if read_only_dir.send_request(end, port, out) is_some {
        return .Unsupported
    }
    loop {
        match read_only_dir.receive_response(end, port, into, true) {
            case Received => return os.message_of[read_only_dir.Response](into)^
            case Failed(error) => return .Unsupported
            case _ => return .Unsupported
        }
    }
}

/**
 * Make the chooser's list of items, in the order they're shown.
 *
 * They are: the directory it's in, for a directory asked for; the one above, below the home; the entries whose names
 * contain what's typed, only directories for a directory; and a new file of the name typed, for a file to write, when
 * something's typed and no entry has exactly that name.
 *
 * @param service The service, its chooser up; nothing is changed.
 * @param items Where the items go, the first of them as many as are returned; null to only count them.
 * @return How many items there are, 0 to CHOOSER_ENTRIES + 3.
 */
items_of :: fn(service: ptr[mut Service], items: ptr[mut Item[CHOOSER_ENTRIES + 3]]?) -> usize {
    chooser :: &service.chooser
    asked :: &view(service).ask
    filter :: first_of(chooser.filter[0..<chooser.filter.count], chooser.filter_count)
    made : Item[CHOOSER_ENTRIES + 3]
    count : usize = 0
    if asked.kind == .Directory {
        made[0] = Item.{kind = .Here}
        count = 1
    }
    if chooser.path_count > 0 && count < made.count {
        made[count] = Item.{kind = .Up}
        count += 1
    }
    exact := false
    for &entry, i in chooser.entries {
        if i >= chooser.entry_count || count >= made.count {
            break
        }
        name :: first_of(entry.name[0..<entry.name.count], entry.count)
        if (asked.kind == .Directory && !entry.directory) || !contains(name, filter) {
            continue
        }
        exact = exact || same_bytes(name, filter)
        made[count] = Item.{kind = .Entry, entry = i}
        count += 1
    }
    if asked.kind == .File && asked.write && filter.count > 0 && !exact && count < made.count {
        made[count] = Item.{kind = .New}
        count += 1
    }
    match items {
        case Some(into) => into^ = made
        case None => {}
    }
    return count
}

/**
 * Choose the item to start on: the entry named exactly what's typed; failing that, when something's typed, the first
 * entry matching it, or the new file if none does; failing that, the first item.
 *
 * @param service The service, its chooser up; only its selected changes.
 */
select_best :: fn(service: ptr[mut Service]) {
    chooser :: &service.chooser
    items : Item[CHOOSER_ENTRIES + 3]
    count :: items_of(service, &items)
    filter :: first_of(chooser.filter[0..<chooser.filter.count], chooser.filter_count)
    chosen := NO_ITEM
    for item, i in items {
        if i >= count {
            break
        }
        if item.kind == .Entry && item.entry < chooser.entries.count {
            entry :: &chooser.entries[item.entry]
            if same_bytes(first_of(entry.name[0..<entry.name.count], entry.count), filter) {
                chosen = i
                break
            }
        }
    }
    for item, i in items {
        if chosen != NO_ITEM || i >= count {
            break
        }
        if item.kind == .New || (item.kind == .Entry && filter.count > 0) {
            chosen = i
        }
    }
    chooser.selected = if chosen != NO_ITEM { chosen } else { 0 }
}

/** No item: what select_best has before it's found one. */
NO_ITEM : usize : 0xffffffff

/**
 * Draw the chooser on the active view's panel: what's asked, by whom, the directory it's in, what's typed, "keep for
 * next time" if it's offered, and a window of ITEMS_SHOWN items with the chosen one inverse.
 *
 * @param service The service, its chooser up.
 */
draw_chooser :: fn(service: ptr[mut Service]) {
    screen.show_panel(&view(service).screen, true)
    panel :: &view(service).screen.panel
    asked :: &view(service).ask
    chooser :: &service.chooser
    bold :: terminal.Style.{attributes = terminal.BOLD}
    plain :: terminal.Style.{}
    chosen_style :: terminal.Style.{attributes = terminal.INVERSE}
    screen.write_at(panel, 1, 2, if asked.kind == .Directory { "Choose a directory" } else { "Choose a file" }, bold)
    storage : u8[256]
    line := text_buffer.make(storage)
    text_buffer.append(&line, bytes_text(first_of(asked.requester[0..<asked.requester.count], asked.requester_count)))
    text_buffer.append(&line, if asked.kind == .Directory { " asks for a directory" } else { " asks for a file" })
    text_buffer.append(&line, if asked.write { " it may write, " } else { " it may read, " })
    text_buffer.append(&line, bytes_text(first_of(asked.purpose[0..<asked.purpose.count], asked.purpose_count)))
    text_buffer.append(&line, ".")
    screen.write_at(panel, 3, 2, text_buffer.as_string(&line), plain)
    line = text_buffer.make(storage)
    text_buffer.append(&line, "In: home/")
    text_buffer.append(&line, bytes_text(first_of(chooser.path[0..<chooser.path.count], chooser.path_count)))
    screen.write_at(panel, 4, 2, text_buffer.as_string(&line), plain)
    line = text_buffer.make(storage)
    text_buffer.append(&line, "Name: ")
    text_buffer.append(&line, bytes_text(first_of(chooser.filter[0..<chooser.filter.count], chooser.filter_count)))
    screen.write_at(panel, 5, 2, text_buffer.as_string(&line), plain)
    if asked.keep {
        screen.write_at(panel, 6, 2, if chooser.keep { "[x] Keep for next time (Tab)" } else { "[ ] Keep for next time (Tab)" }, plain)
    }
    items : Item[CHOOSER_ENTRIES + 3]
    count :: items_of(service, &items)
    // The window of items the chosen one's in
    first :: if chooser.selected >= ITEMS_SHOWN { chooser.selected + 1 - ITEMS_SHOWN } else { 0 }
    if count == 0 {
        screen.write_at(panel, ITEMS_ROW, 4, "Nothing here has that name.", plain)
    }
    for item, i in items {
        if i >= count || i < first {
            continue
        }
        if i - first >= ITEMS_SHOWN {
            break
        }
        line = text_buffer.make(storage)
        match item.kind {
            case .Here => text_buffer.append(&line, "[this directory]")
            case .Up => text_buffer.append(&line, "../")
            case .Entry => {
                if item.entry < chooser.entries.count {
                    entry :: &chooser.entries[item.entry]
                    text_buffer.append(&line, bytes_text(first_of(entry.name[0..<entry.name.count], entry.count)))
                    if entry.directory {
                        text_buffer.append(&line, "/")
                    }
                }
            }
            case .New => {
                text_buffer.append(&line, "new file: ")
                text_buffer.append(&line, bytes_text(first_of(chooser.filter[0..<chooser.filter.count], chooser.filter_count)))
            }
        }
        screen.write_at(panel, ITEMS_ROW + cast[u16](i - first), 4, text_buffer.as_string(&line), if i == chooser.selected { chosen_style } else { plain })
    }
    screen.write_at(panel, ITEMS_ROW + cast[u16](ITEMS_SHOWN) + 1, 2,
        "Up and Down choose, Enter opens or chooses, typing narrows the list, Esc refuses.", plain)
    redraw(service)
}

/**
 * Go down into a directory: add name to the chooser's path, after a /, or as the whole path in the home. A path longer
 * than PATH_BYTES is cut short.
 *
 * @param chooser The chooser, whose path changes.
 * @param name The entry's name, without a /; read only during the call.
 */
join :: fn(chooser: ptr[mut Chooser], name: u8[]) {
    storage : u8[PATH_BYTES]
    path :: joined(chooser, name, &storage)
    chooser.path_count = copy_bytes(path, chooser.path[0..<chooser.path.count])
}

/**
 * Make the path of name in the chooser's directory: the path, a /, and name, or name alone in the home.
 *
 * @param chooser The chooser, which isn't changed.
 * @param name The name to add; read only during the call.
 * @param storage Where the path is made; what doesn't fit its PATH_BYTES is cut off.
 * @return The path, a view of storage, good while storage is and until it's used again.
 */
joined :: fn(chooser: ptr[Chooser], name: u8[], storage: ptr[mut u8[PATH_BYTES]]) -> u8[] {
    count : usize = 0
    path :: first_of(chooser.path[0..<chooser.path.count], chooser.path_count)
    add_part(storage, &count, path)
    if path.count > 0 {
        add_part(storage, &count, string_bytes("/"))
    }
    add_part(storage, &count, name)
    return first_of(storage^[0..<storage.count], count)
}

/**
 * Append part to a path being made, as much of it as fits.
 *
 * @param storage The path being made, written from count on; bytes past PATH_BYTES are dropped, and those before
 *     count aren't touched.
 * @param count How many bytes of storage are used, moved on by as many as are appended, to PATH_BYTES at most.
 * @param part The bytes to append; read only during the call.
 */
add_part :: fn(storage: ptr[mut u8[PATH_BYTES]], count: ptr[mut usize], part: u8[]) {
    for byte in part {
        at :: count^
        if at < storage.count {
            storage^[at] = byte
            count^ = at + 1
        }
    }
}

/**
 * Copy bytes into a buffer from its start, as many as fit.
 *
 * @param from The bytes copied, from the first; only read.
 * @param into Where they go; bytes past those copied aren't touched.
 * @return How many were copied: the smaller of from's count and into's.
 */
copy_bytes :: fn(from: u8[], into: mut u8[]) -> usize {
    count : usize = 0
    for byte in from {
        if count < into.count {
            into[count] = byte
            count += 1
        }
    }
    return count
}

/**
 * Tell whether a name has part in it, byte for byte, as the chooser's filter matches.
 *
 * @param name The bytes searched, such as an entry's name; only read.
 * @param part The bytes looked for; empty is in every name.
 * @return True if part appears anywhere in name, matched exactly, case and all.
 */
contains :: fn(name: u8[], part: u8[]) -> bool {
    if part.count == 0 {
        return true
    }
    if part.count > name.count {
        return false
    }
    for start in 0..<(name.count - part.count + 1) {
        end :: start + part.count
        if start <= end && end <= name.count && same_bytes(name[start..<end], part) {
            return true
        }
    }
    return false
}

/**
 * Take the used part of a fixed buffer, given how many of its bytes are used.
 *
 * @param bytes A fixed buffer, not copied.
 * @param count How many of its bytes are used.
 * @return A view of bytes' first count bytes, or all of them if count is past its end; good while bytes is.
 */
first_of :: fn(bytes: u8[], count: usize) -> u8[] {
    return if count <= bytes.count { bytes[0..<count] } else { bytes }
}

/**
 * View bytes as a string, for showing or logging; they aren't checked to be UTF-8.
 *
 * @param bytes The bytes viewed, any of them, not copied.
 * @return A string over the same bytes, good while they are; "" for none.
 */
bytes_text :: fn(bytes: u8[]) -> string {
    return if bytes.count > 0 { string_of(&bytes[0], bytes.count) } else { "" }
}
