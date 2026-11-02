/*
 * The powerbox's chooser (decisions/0156), on the trusted path. A session's powerbox asks on its prompt connection (Ask):
 * the request's shown on the status line, naming the program and what it asks for, until the secure attention key
 * opens the chooser over the session, which lists the directory it's in from the home the powerbox gave, read only.
 * Up and Down move, Enter opens a directory or chooses, typing narrows the list to the names with what's typed in them
 * and, for a file to write, offers a new file of that name; Escape refuses. The answer goes back on the prompt
 * connection, and the session's drawn again.
 */
package terminal_service

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import text_buffer from "std"
import terminal from "std/os/slop_os"
import read_only_dir from "std/os/slop_os"
import files from "std/os/slop_os"
import prompt from "../../protocols/prompt"
import screen from "../../screen"

// Each view's prompt connection is bound to the port under this key and its index
PROMPT_KEY : u64 : 1100
CHOOSER_ENTRIES :: 64
ENTRY_BYTES :: 64
PATH_BYTES :: 256
ASK_BYTES :: 96
// The chooser's rows: its items from ITEMS_ROW, ITEMS_SHOWN of them at a time
ITEMS_ROW : u16 : 7
ITEMS_SHOWN :: 13

// A request a session's powerbox is waiting on the user for: whose, why, what it suggests, and the home to choose in.
Asked :: struct {
    requester : u8[ASK_BYTES],
    requester_count : usize,
    purpose : u8[ASK_BYTES],
    purpose_count : usize,
    suggested : u8[ENTRY_BYTES],
    suggested_count : usize,
    kind : prompt.Kind,
    write : bool,
    home : slop_os.Channel,
}

Entry :: struct {
    name : u8[ENTRY_BYTES],
    count : usize,
    directory : bool,
}

// The chooser's state: the directory it's in beneath the home, what's typed, what the directory has, and the item chosen.
Chooser :: struct {
    path : u8[PATH_BYTES],
    path_count : usize,
    filter : u8[ENTRY_BYTES],
    filter_count : usize,
    entries : Entry[CHOOSER_ENTRIES],
    entry_count : usize,
    selected : usize,
}

ItemKind :: enum {
    // The directory it's in, for a directory asked for
    Here,
    Up,
    Entry,
    // A new file of the name typed
    New,
}

Item :: struct {
    kind : ItemKind,
    entry : usize,
}

// Asks waiting on the views' prompt connections, kept for the user; a connection that's gone, closed.
take_prompts :: fn(service: ptr[mut Service], into: ptr[mut os.Incoming]) {
    for &each, i in service.views {
        if !each.in_use || each.prompt_end == NONE || each.asking {
            continue
        }
        match prompt.receive_request(each.prompt_end, service.port, into, false) {
            case Received => {}
            case Unsupported => {
                _ = prompt.answer_unsupported(each.prompt_end, service.port)
                continue
            }
            case Failed(error) => {
                _ = slop_os.handle_close(cast[slop_os.Handle](each.prompt_end))
                each.prompt_end = NONE
                continue
            }
            case _ => continue
        }
        match os.message_of[prompt.Request](into)^ {
            case Ask(asked) => {
                kept := Asked.{kind = asked.kind, write = asked.write, home = asked.home.end}
                kept.requester_count = copy_bytes(os.items(into, asked.requester), kept.requester[0..<kept.requester.count])
                kept.purpose_count = copy_bytes(os.items(into, asked.purpose), kept.purpose[0..<kept.purpose.count])
                kept.suggested_count = copy_bytes(os.items(into, asked.suggested), kept.suggested[0..<kept.suggested.count])
                each.ask = kept
                each.asking = true
                runtime.log_info("% asks for a %", bytes_text(first_of(kept.requester[0..<kept.requester.count], kept.requester_count)),
                    if kept.kind == .Directory { "directory" } else { "file" })
                if i == service.active && !service.attention && service.setup == .Off {
                    use_active(service)
                    update_status(service)
                }
            }
        }
    }
}

// What's waiting, for the status line: who asks for what, and the key that opens the chooser.
append_asking :: fn(status: ptr[mut text_buffer.TextBuffer], asked: ptr[Asked]) {
    text_buffer.append(status, " │ ")
    text_buffer.append(status, bytes_text(first_of(asked.requester[0..<asked.requester.count], asked.requester_count)))
    text_buffer.append(status, if asked.kind == .Directory { " asks for a directory" } else { " asks for a file" })
    text_buffer.append(status, ": Ctrl+Alt+Delete")
}

// The chooser opened over the active view, for its request, in the home, what was suggested typed already.
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

// A key while the chooser's up.
chooser_key :: fn(service: ptr[mut Service], event: terminal.Event, text: u8[]) {
    chooser :: &service.chooser
    if event.code == USAGE_ESCAPE {
        answer_ask(service, null, false)
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

// Enter on the item chosen: a directory opened, the one it's in or an entry chosen, or a new file named.
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

// The directory the chooser's in now, listed, with nothing typed.
opened_directory :: fn(service: ptr[mut Service]) {
    service.chooser.filter_count = 0
    list_chooser(service)
    select_best(service)
    draw_chooser(service)
}

/*
 * The request answered with path and whether it's new, or refused for null, on the active view's prompt connection; the
 * chooser closed, the home given back, and the session drawn again.
 */
answer_ask :: fn(service: ptr[mut Service], path: u8[]?, new: bool) {
    shown :: view(service)
    out := os.Outgoing.{}
    response :: os.begin[prompt.Response](&out)
    match path {
        case Some(chosen) => {
            response^ = .Chosen(prompt.Choice.{path = os.append(&out, chosen), new = new})
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

// A view's waiting request let go, its home closed.
drop_ask :: fn(each: ptr[mut View]) {
    if each.asking && each.ask.home != NONE {
        _ = slop_os.handle_close(cast[slop_os.Handle](each.ask.home))
    }
    each.asking = false
    each.ask = Asked.{}
}

// The chooser's directory's entries, from the home: up to CHOOSER_ENTRIES of them, as the volume lists them.
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

// One request on a read-only directory's connection, and its answer, waited for.
ask_read_only :: fn(end: slop_os.Channel, port: slop_os.Port, out: ptr[mut os.Outgoing], into: ptr[mut os.Incoming]) -> read_only_dir.Response {
    if read_only_dir.send_request(end, port, out) is_some {
        return .Unsupported
    }
    loop {
        match read_only_dir.receive_response(end, port, into, true) {
            case Received => return os.message_of[read_only_dir.Response](into)^
            case Failed(error) => return .Unsupported
            case _ => continue
        }
    }
}

/*
 * The chooser's items, into items unless it's null: the directory it's in, for a directory; the one above, below the
 * home; the entries with what's typed in their names, only directories for a directory; and a new file of the name
 * typed, for a file to write, if no entry has that name. How many.
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

// The item to start on: the entry named what's typed, or a new file of that name, or the first entry, or the first item.
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

NO_ITEM : usize : 0xffffffff

// The chooser, drawn on the panel: what's asked, by whom, the directory it's in, what's typed, and its items.
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

// The chooser's path with name added: name alone in the home.
join :: fn(chooser: ptr[mut Chooser], name: u8[]) {
    storage : u8[PATH_BYTES]
    path :: joined(chooser, name, &storage)
    chooser.path_count = copy_bytes(path, chooser.path[0..<chooser.path.count])
}

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

add_part :: fn(storage: ptr[mut u8[PATH_BYTES]], count: ptr[mut usize], part: u8[]) {
    for byte in part {
        at :: count^
        if at < storage.count {
            storage^[at] = byte
            count^ = at + 1
        }
    }
}

// from copied into into, as much as fits: how much did.
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

// The first count of bytes, or all of them.
first_of :: fn(bytes: u8[], count: usize) -> u8[] {
    return if count <= bytes.count { bytes[0..<count] } else { bytes }
}

bytes_text :: fn(bytes: u8[]) -> string {
    return if bytes.count > 0 { string_of(&bytes[0], bytes.count) } else { "" }
}
