/*
 * The powerbox (decisions/0018, 0156, design/console-and-sessions.md §5): one per session, which the session manager
 * starts with the session's home, the trusted path's prompt connection for the session, and a connection of its own, on
 * which it has the powerbox serve each of the session's programs, under the program's name. A program's RequestFile or
 * RequestDirectory goes to the trusted path as an Ask, with the program's name, its purpose and the home, read only, for
 * the chooser to list; the program's answered once the user has chosen, with what they chose opened on the home, read
 * only unless it asked to write, or refused. One request waits at a time; another is answered Busy. It holds only its
 * session's home, so a bug in it reaches one user's files.
 *
 * Kept grants (decisions/0158): a request that asks to be kept under a key, if the user ticks "keep for next time", is
 * granted again by the home and kept as a stored link, grants/<program>/<key>, in the home; Reopen with the key opens it
 * again without asking the user. Revoking its issued record, from the trusted path's grants view, makes it open nothing.
 */
package powerbox_service

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import files from "std/os/slop_os"
import lifecycle from "std/os/slop_os"
import powerbox from "../../protocols/powerbox"
import prompt from "../../protocols/prompt"
import service_kit from "../../libraries/service_kit"

NONE : slop_os.Channel : cast[slop_os.Channel](slop_os.NO_HANDLE)
// The prompt connection is bound to the port under this key, and a stop under the next, above the clients'
PROMPT_KEY : u64 : 1000
STOP_KEY : u64 : 1001
PATH_BYTES :: 160
// The session manager's connection is the first client
MANAGER : usize : 0

Name :: struct {
    bytes : u8[powerbox.NAME_BYTES],
    count : usize,
}

// The request waiting for the user: whose, what it asked for, and the key to keep it under, if it asked.
Waiting :: struct {
    client : usize,
    kind : prompt.Kind,
    write : bool,
    key : u8[powerbox.KEY_BYTES],
    key_count : usize,
}

Box :: struct {
    port : slop_os.Port,
    home_end : slop_os.Channel,
    home_port : slop_os.Port,
    prompt_end : slop_os.Channel,
    prompt_port : slop_os.Port,
    clients : service_kit.Clients,
    names : Name[service_kit.MAX_CLIENTS],
    waiting : Waiting,
    has_waiting : bool,
}

main :: fn(home: os.Channel[dir.Dir]?, prompts: os.Channel[prompt.Prompt], manager: os.Channel[powerbox.Powerbox]) -> int {
    block :: slop_os.startup_block()
    box := runtime.new(Box)
    box.port = slop_os.port_create(block.budget) or_return 1
    box.home_end = NONE
    match home {
        case Some(root) => {
            box.home_end = root.end
            box.home_port = os.port_for(block.budget, root.end) or_return 2
        }
        case None => {}
    }
    box.prompt_end = prompts.end
    box.prompt_port = os.port_for(block.budget, prompts.end) or_return 2
    // Its answers wake the loop too
    signals :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    slop_os.port_bind(box.port, cast[slop_os.Handle](prompts.end), signals, PROMPT_KEY, .Persistent) or_return 2
    if !service_kit.add_client(&box.clients, box.port, manager.end) {
        return 3
    }
    _ = lifecycle.on_stop(box.port, STOP_KEY)
    runtime.log_info("serving")
    into := os.Incoming.{}
    loop {
        if lifecycle.stop_requested() {
            return 0
        }
        with {
            i : usize = 0
        }
        loop {
            serve(box, i, &into)
            i += 1
        }
        while i < box.clients.count
        take_answer(box, &into)
        packets : slop_os.Packet[8]
        _ = slop_os.port_wait(box.port, packets, slop_os.NO_DEADLINE)
    }
}

// Every request client index has sent, until there are none left, or it's gone.
serve :: fn(box: ptr[mut Box], index: usize, into: ptr[mut os.Incoming]) {
    if index >= box.clients.ends.count {
        return void
    }
    end :: box.clients.ends[index]
    if cast[slop_os.Handle](end) == slop_os.NO_HANDLE {
        return void
    }
    loop {
        match powerbox.receive_request(end, box.port, into, false) {
            case Received => {}
            case Empty => return void
            case Unsupported => {
                _ = powerbox.answer_unsupported(end, box.port)
                continue
            }
            case Failed(error) => {
                service_kit.drop_client(&box.clients, index)
                // Its request, if one's waiting, is answered by no one
                if box.has_waiting && box.waiting.client == index {
                    box.waiting.client = service_kit.MAX_CLIENTS
                }
                return void
            }
            case _ => continue
        }
        out := os.Outgoing.{}
        response :: os.begin[powerbox.Response](&out)
        match os.message_of[powerbox.Request](into)^ {
            case Serve(served) => {
                response^ = if index == MANAGER && serve_program(box, os.items(into, served.name), served.end) { .Done } else { .Refused }
                if index != MANAGER {
                    _ = slop_os.handle_close(cast[slop_os.Handle](served.end.end))
                }
            }
            case RequestFile(asked) => {
                match ask(box, index, .File, asked.write, os.items(into, asked.purpose), os.items(into, asked.suggested), os.items(into, asked.keep)) {
                    case Some(answer) => response^ = answer
                    // Answered once the user has chosen
                    case None => continue
                }
            }
            case RequestDirectory(asked) => {
                match ask(box, index, .Directory, asked.write, os.items(into, asked.purpose), u8.[], os.items(into, asked.keep)) {
                    case Some(answer) => response^ = answer
                    case None => continue
                }
            }
            case Reopen(reopening) => response^ = reopen(box, index, os.items(into, reopening.key), reopening.kind, reopening.write)
        }
        _ = powerbox.send_response(end, box.port, &out)
    }
}

// A program of the session's served on end, under name: whether there was room.
serve_program :: fn(box: ptr[mut Box], name: u8[], end: os.Channel[powerbox.Powerbox]) -> bool {
    index :: service_kit.add_client_index(&box.clients, box.port, end.end) or_return false
    if index < box.names.count {
        box.names[index] = Name.{}
        for byte, i in name {
            if i < box.names[index].bytes.count {
                box.names[index].bytes[i] = byte
                box.names[index].count = i + 1
            }
        }
    }
    return true
}

name_of :: fn(box: ptr[Box], index: usize) -> u8[] {
    if index >= box.names.count {
        return box.names[0].bytes[0..<0]
    }
    name :: &box.names[index]
    return if name.count <= name.bytes.count { name.bytes[0..<name.count] } else { name.bytes[0..<0] }
}

/*
 * A request sent to the trusted path, with the home, read only, for the chooser: null once it's waiting there, or the
 * answer at once, Busy with one waiting already, Refused without a home or the trusted path.
 */
ask :: fn(box: ptr[mut Box], index: usize, kind: prompt.Kind, write: bool, purpose: u8[], suggested: u8[], key: u8[]) -> powerbox.Response? {
    if box.has_waiting {
        return .Busy
    }
    if key.count > 0 && !valid_key(key) {
        return .Refused
    }
    if box.home_end == NONE || box.prompt_end == NONE {
        return .Refused
    }
    home :: match ask_dir(box, box.home_end, box.home_port, .Narrow) {
        case Narrowed(narrowed) => narrowed
        case _ => return .Refused
    }
    out := os.Outgoing.{}
    request :: os.begin[prompt.Request](&out)
    request^ = .Ask(prompt.Ask.{requester = os.append(&out, name_of(box, index)), purpose = os.append(&out, purpose),
        suggested = os.append(&out, suggested), kind = kind, write = write, keep = key.count > 0, home = home})
    if prompt.send_request(box.prompt_end, box.prompt_port, &out) != null {
        return .Refused
    }
    box.waiting = Waiting.{client = index, kind = kind, write = write}
    for byte, i in key {
        if i < box.waiting.key.count {
            box.waiting.key[i] = byte
            box.waiting.key_count = i + 1
        }
    }
    box.has_waiting = true
    who :: name_of(box, index)
    runtime.log_info("% asks for a %", if who.count > 0 { string_of(&who[0], who.count) } else { "a program" },
        if kind == .File { if write { "file to write" } else { "file to read" } } else { if write { "directory to write in" } else { "directory to read" } })
    return null
}

// The trusted path's answer, if it's come: what the user chose opened and given to the program that asked, or refused.
take_answer :: fn(box: ptr[mut Box], into: ptr[mut os.Incoming]) {
    if !box.has_waiting || box.prompt_end == NONE {
        return void
    }
    match prompt.receive_response(box.prompt_end, box.prompt_port, into, false) {
        case Received => {}
        case Failed(error) => {
            // The trusted path's gone, and nothing can be asked of the user from now on
            _ = slop_os.handle_close(cast[slop_os.Handle](box.prompt_end))
            box.prompt_end = NONE
            answer(box, .Refused)
            return void
        }
        case _ => return void
    }
    match os.message_of[prompt.Response](into)^ {
        case Chosen(choice) => {
            path :: os.items(into, choice.path)
            given :: opened(box, path, choice.new, box.waiting.kind, box.waiting.write)
            if given is_some {
                who :: name_of(box, box.waiting.client)
                runtime.log_info("gave % %", if who.count > 0 { string_of(&who[0], who.count) } else { "a program" },
                    if path.count > 0 { string_of(&path[0], path.count) } else { "the home" })
                if choice.keep && box.waiting.key_count > 0 && box.waiting.key_count <= box.waiting.key.count {
                    keep(box, box.waiting.client, box.waiting.key[0..<box.waiting.key_count], path, box.waiting.write)
                }
            }
            answer(box, given or_else .Refused)
        }
        case _ => {
            runtime.log_info("the user refused")
            answer(box, .Refused)
        }
    }
}

// What's at path, opened on the home as asked: a file, read only unless it would write, made if it's new; or a directory,
// read only unless it would write. Null if it can't be.
opened :: fn(box: ptr[mut Box], path: u8[], new: bool, kind: prompt.Kind, write: bool) -> powerbox.Response? {
    out := os.Outgoing.{}
    if kind == .File {
        if write {
            opening :: os.begin[dir.Request](&out)
            opening^ = .OpenFile(dir.OpenFile.{path = os.append(&out, path),
                creation = if new { files.Creation.New } else { files.Creation.Existing }})
            return match ask_dir_with(box, box.home_end, box.home_port, &out) {
                case OpenedFile(file) => .GrantedFile(file)
                case _ => null
            }
        }
        if new {
            return null
        }
        reading :: os.begin[dir.Request](&out)
        reading^ = .OpenReadOnlyFile(os.append(&out, path))
        return match ask_dir_with(box, box.home_end, box.home_port, &out) {
            case OpenedReadOnlyFile(file) => .GrantedReadOnlyFile(file)
            case _ => null
        }
    }
    // A directory: the home itself, or one beneath it
    directory := NONE
    if path.count == 0 {
        directory = connection_to(box.home_end, box.home_port) or_return null
    }
    else {
        opening_directory :: os.begin[dir.Request](&out)
        opening_directory^ = .OpenDirectory(dir.OpenDirectory.{path = os.append(&out, path), create = new})
        match ask_dir_with(box, box.home_end, box.home_port, &out) {
            case OpenedDirectory(opened_directory) => directory = opened_directory.end
            case _ => return null
        }
    }
    if write {
        return .GrantedDirectory(os.Channel[dir.Dir].{end = directory})
    }
    port :: os.port_for(slop_os.startup_block().budget, directory) or_else cast[slop_os.Port](slop_os.NO_HANDLE)
    narrowed :: if cast[slop_os.Handle](port) == slop_os.NO_HANDLE { dir.Response.Unsupported } else { ask_dir(box, directory, port, .Narrow) }
    if cast[slop_os.Handle](port) != slop_os.NO_HANDLE {
        _ = slop_os.handle_close(cast[slop_os.Handle](port))
    }
    _ = slop_os.handle_close(cast[slop_os.Handle](directory))
    return match narrowed {
        case Narrowed(read_only) => .GrantedReadOnlyDirectory(read_only)
        case _ => null
    }
}

/*
 * What the user chose kept for the program at index, under key: granted by the home again, read only unless it was
 * asked for to write, and the grant kept as a stored link at grants/<program>/<key>, in place of one there before.
 */
keep :: fn(box: ptr[mut Box], index: usize, key: u8[], path: u8[], write: bool) {
    who :: name_of(box, index)
    if who.count == 0 || path.count == 0 {
        return void
    }
    storage : u8[PATH_BYTES]
    if !made_directory(box, string_bytes("grants")) || !made_directory(box, kept_path(who, key[0..<0], &storage)) {
        return void
    }
    out := os.Outgoing.{}
    granting :: os.begin[dir.Request](&out)
    granting^ = .Grant(dir.GrantOf.{path = os.append(&out, path), write = write})
    given :: match ask_dir_with(box, box.home_end, box.home_port, &out) {
        case Granted(made) => made
        case _ => {
            runtime.log_info("couldn't keep it")
            return void
        }
    }
    link_storage : u8[PATH_BYTES]
    link :: kept_path(who, key, &link_storage)
    out = os.Outgoing.{}
    removing :: os.begin[dir.Request](&out)
    removing^ = .Remove(os.append(&out, link))
    _ = ask_dir_with(box, box.home_end, box.home_port, &out)
    out = os.Outgoing.{}
    linking :: os.begin[dir.Request](&out)
    linking^ = .Link(dir.LinkTo.{path = os.append(&out, link), grant = given})
    match ask_dir_with(box, box.home_end, box.home_port, &out) {
        case Done => runtime.log_info("kept % for %", string_of(&path[0], path.count), string_of(&who[0], who.count))
        case _ => runtime.log_info("couldn't keep it")
    }
}

// A grant the program at index kept under key, opened again through its link, as asked; Refused if it's gone or revoked.
reopen :: fn(box: ptr[mut Box], index: usize, key: u8[], kind: powerbox.Kind, write: bool) -> powerbox.Response {
    who :: name_of(box, index)
    if box.home_end == NONE || who.count == 0 || !valid_key(key) {
        return .Refused
    }
    storage : u8[PATH_BYTES]
    link :: kept_path(who, key, &storage)
    match opened(box, link, false, if kind == .Directory { prompt.Kind.Directory } else { prompt.Kind.File }, write) {
        case Some(given) => {
            runtime.log_info("reopened % for %", as_text(key), as_text(who))
            return given
        }
        case None => {
            runtime.log_info("couldn't reopen % for %", as_text(key), as_text(who))
            return .Refused
        }
    }
}

// The directory at path beneath the home, made if it isn't there: whether it is.
made_directory :: fn(box: ptr[mut Box], path: u8[]) -> bool {
    out := os.Outgoing.{}
    making :: os.begin[dir.Request](&out)
    making^ = .OpenDirectory(dir.OpenDirectory.{path = os.append(&out, path), create = true})
    return match ask_dir_with(box, box.home_end, box.home_port, &out) {
        case OpenedDirectory(made) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](made.end))
            true
        }
        case _ => false
    }
}

// grants/<program>, and /<key> after it if there's one, into storage.
kept_path :: fn(who: u8[], key: u8[], storage: ptr[mut u8[PATH_BYTES]]) -> u8[] {
    count : usize = 0
    append_bytes(storage, &count, string_bytes("grants/"))
    append_bytes(storage, &count, who)
    if key.count > 0 {
        append_bytes(storage, &count, string_bytes("/"))
        append_bytes(storage, &count, key)
    }
    return if count <= storage.count { storage^[0..<count] } else { storage^[0..<0] }
}

append_bytes :: fn(storage: ptr[mut u8[PATH_BYTES]], count: ptr[mut usize], bytes: u8[]) {
    for byte in bytes {
        at :: count^
        if at < storage.count {
            storage^[at] = byte
            count^ = at + 1
        }
    }
}

as_text :: fn(bytes: u8[]) -> string {
    return if bytes.count > 0 { string_of(&bytes[0], bytes.count) } else { "" }
}

// A key: letters, digits, - and _, at most KEY_BYTES of them.
valid_key :: fn(key: u8[]) -> bool {
    if key.count == 0 || key.count > powerbox.KEY_BYTES {
        return false
    }
    for byte in key {
        if !((byte >= cast[u8]('a') && byte <= cast[u8]('z')) || (byte >= cast[u8]('A') && byte <= cast[u8]('Z')) || (byte >= cast[u8]('0') && byte <= cast[u8]('9'))
            || byte == cast[u8]('-') || byte == cast[u8]('_')) {
            return false
        }
    }
    return true
}

// The waiting request answered, unless the program that asked has gone, and no longer waiting.
answer :: fn(box: ptr[mut Box], given: powerbox.Response) {
    box.has_waiting = false
    index :: box.waiting.client
    if index >= box.clients.ends.count || cast[slop_os.Handle](box.clients.ends[index]) == slop_os.NO_HANDLE {
        return void
    }
    out := os.Outgoing.{}
    os.begin[powerbox.Response](&out)^ = given
    _ = powerbox.send_response(box.clients.ends[index], box.port, &out)
}

ask_dir :: fn(box: ptr[mut Box], end: slop_os.Channel, port: slop_os.Port, request: dir.Request) -> dir.Response {
    out := os.Outgoing.{}
    os.begin[dir.Request](&out)^ = request
    return ask_dir_with(box, end, port, &out)
}

// One request on a dir connection, and its answer, waited for.
ask_dir_with :: fn(box: ptr[mut Box], end: slop_os.Channel, port: slop_os.Port, out: ptr[mut os.Outgoing]) -> dir.Response {
    if dir.send_request(end, port, out) is_some {
        return .Unsupported
    }
    into := os.Incoming.{}
    loop {
        match dir.receive_response(end, port, &into, true) {
            case Received => return os.message_of[dir.Response](&into)^
            case Failed(error) => return .Unsupported
            case _ => continue
        }
    }
}

// Another connection to the directory end speaks for, its one end sent to its server, which takes it without answering.
connection_to :: fn(end: slop_os.Channel, port: slop_os.Port) -> slop_os.Channel? {
    pair :: os.channel_for[dir.Dir](slop_os.startup_block().budget, 0) or_return null
    out := os.Outgoing.{}
    os.begin[dir.Request](&out)^ = .Connect(os.Channel[dir.Dir].{end = pair.a})
    if dir.send_request(end, port, &out) is_some {
        _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
        return null
    }
    return pair.b
}
