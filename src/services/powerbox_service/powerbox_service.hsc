/*
 * The powerbox (decisions/0018, 0156, design/console-and-sessions.md §5): one per session, which the session manager
 * starts with the session's home, the trusted path's prompt connection for the session, and a connection of its own, on
 * which it has the powerbox serve each of the session's programs, under the program's name. A program's RequestFile or
 * RequestDirectory goes to the trusted path as an Ask, with the program's name, its purpose and the home, read only, for
 * the chooser to list; the program's answered once the user has chosen, with what they chose opened on the home, read
 * only unless it asked to write, or refused. One request waits at a time; another is answered Busy. It holds only its
 * session's home, so a bug in it reaches one user's files.
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
// The session manager's connection is the first client
MANAGER : usize : 0

Name :: struct {
    bytes : u8[powerbox.NAME_BYTES],
    count : usize,
}

// The request waiting for the user: whose, and what it asked for.
Waiting :: struct {
    client : usize,
    kind : prompt.Kind,
    write : bool,
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
                match ask(box, index, .File, asked.write, os.items(into, asked.purpose), os.items(into, asked.suggested)) {
                    case Some(answer) => response^ = answer
                    // Answered once the user has chosen
                    case None => continue
                }
            }
            case RequestDirectory(asked) => {
                match ask(box, index, .Directory, asked.write, os.items(into, asked.purpose), u8.[]) {
                    case Some(answer) => response^ = answer
                    case None => continue
                }
            }
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
ask :: fn(box: ptr[mut Box], index: usize, kind: prompt.Kind, write: bool, purpose: u8[], suggested: u8[]) -> powerbox.Response? {
    if box.has_waiting {
        return .Busy
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
        suggested = os.append(&out, suggested), kind = kind, write = write, home = home})
    if prompt.send_request(box.prompt_end, box.prompt_port, &out) != null {
        return .Refused
    }
    box.waiting = Waiting.{client = index, kind = kind, write = write}
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
            given :: opened(box, path, choice.new)
            if given is_some {
                who :: name_of(box, box.waiting.client)
                runtime.log_info("gave % %", if who.count > 0 { string_of(&who[0], who.count) } else { "a program" },
                    if path.count > 0 { string_of(&path[0], path.count) } else { "the home" })
            }
            answer(box, given or_else .Refused)
        }
        case _ => {
            runtime.log_info("the user refused")
            answer(box, .Refused)
        }
    }
}

// What was chosen, opened on the home as the waiting request asked: a file, read only unless it would write, made if
// it's new; or a directory, read only unless it would write. Null if it can't be.
opened :: fn(box: ptr[mut Box], path: u8[], new: bool) -> powerbox.Response? {
    out := os.Outgoing.{}
    if box.waiting.kind == .File {
        if box.waiting.write {
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
    if box.waiting.write {
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
