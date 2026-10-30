/*
 * The config store (roadmap 9c2, decisions/0107, 0109, design/software.md §4): each owner's values, in the directory
 * it's given on the system volume, a directory each, <owner>/<name>/: a typed file per kept version, named by its
 * number, each a Stored, holding the value's type, its default, its override and which fields that sets, its author and
 * when it was written; and newest, a Newest, the newest version's number. A version is written before newest names it,
 * so a store stopped between the two has the version before, whole; the one past MAX_VERSIONS is deleted after.
 *
 * Connections to values are made on the supervisor's, which arrives on the admin listener (ValueFor): each reaches only
 * its own value. The store doesn't know a value's type, only its schema hash: the program, which does, checks what it
 * reads (config.read), and what it writes, before it sends it.
 */
package config_service

import runtime from "base"
import os from "std"
import time from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import service_kit from "../../service_kit"
import config from "../../protocols/config"

// The most values, at once, that connections reach
MAX_VALUES :: 32
MAX_NAME :: 31
NOWHERE : usize : 0xffffffffffffffff

// A version of a value, as its typed file holds it.
Stored :: struct {
    version : u64,
    written : i64,
    schema : u8[32],
    fields : u64,
    author : slop_os.Relative[u8],
    default : slop_os.Relative[u8],
    override : slop_os.Relative[u8],
}

// The newest version's number, as the value's typed file newest holds it.
Newest :: struct {
    version : u64,
}

// A value connections reach: its owner and name, and its newest version, 0 before it's declared.
Value :: struct {
    owner : u8[MAX_NAME],
    owner_count : usize,
    name : u8[MAX_NAME],
    name_count : usize,
    newest : u64,
}

// What a connection is: the supervisor's, or one to a value, and the version a Next of its waits to be past.
Client :: struct {
    admin : bool,
    value : usize,
    waiting : bool,
    seen : u64,
}

Store :: struct {
    block : ptr[slop_os.StartupBlock],
    port : slop_os.Port,
    connected : service_kit.Clients,
    clients : Client[service_kit.MAX_CLIENTS],
    directory : os.Directory,
    values : Value[MAX_VALUES],
    value_count : usize,
}

main :: fn(store: os.Channel[dir.Dir], admin: os.Listener[config.ConfigValue]) -> int {
    // Its state; without the memory for it, it ends with 99 (decisions/0104)
    service_made, service_error :: runtime.new_aligned(Store, align_of(Store))
    if service_error != null {
        return 99
    }
    service :: service_made
    service.block = slop_os.startup_block()
    service.port = slop_os.port_create(service.block.budget) or_return 1
    directory, error :: os.directory_on(store.end)
    if error != null {
        return 2
    }
    service.directory = directory
    index :: service_kit.add_client_index(&service.connected, service.port, admin.end) or_return 3
    if index < service.clients.count {
        service.clients[index] = Client.{admin = true, value = NOWHERE}
    }
    runtime.log_info("serving")
    into := os.Incoming.{}
    loop {
        // Every client, those ValueFor adds as it goes too: a channel wakes the port only once a read has found it empty
        i := cast[usize](0)
        loop {
            if i >= service.connected.count {
                break
            }
            serve(service, i, &into)
            i += 1
        }
        packets : slop_os.Packet[8]
        _ = slop_os.port_wait(service.port, packets, slop_os.NO_DEADLINE)
    }
}

// Every request client index has sent, until there are none left, or it's gone.
serve :: fn(service: ptr[mut Store], index: usize, into: ptr[mut os.Incoming]) {
    if index >= service.connected.ends.count || index >= service.clients.count {
        return void
    }
    end :: service.connected.ends[index]
    if cast[slop_os.Handle](end) == slop_os.NO_HANDLE {
        return void
    }
    client :: &service.clients[index]
    loop {
        match config.receive_request(end, service.port, into, false) {
            case Received => {}
            case Empty => return void
            case Unsupported => {
                _ = config.answer_unsupported(end, service.port)
                continue
            }
            case Invalid => continue
            case WrongProtocol => continue
            case Failed(error) => {
                service_kit.drop_client(&service.connected, index)
                client^ = Client.{value = NOWHERE}
                return void
            }
        }
        out := os.Outgoing.{}
        request :: os.message_of[config.Request](into)^
        match request {
            case ValueFor(wanted) => {
                if !client.admin {
                    refuse(end, service.port, .Refused)
                    continue
                }
                response :: os.begin[config.Response](&out)
                match connection_for(service, as_text(os.items(into, wanted.owner)), as_text(os.items(into, wanted.name))) {
                    case Some(connection) => response^ = .Opened(connection)
                    case None => response^ = .Failed(.Refused)
                }
            }
            case UseDirectory(directory) => {
                if !client.admin {
                    _ = slop_os.handle_close(cast[slop_os.Handle](directory.end))
                    refuse(end, service.port, .Refused)
                    continue
                }
                response :: os.begin[config.Response](&out)
                response^ = if use_directory(service, directory.end) { .Done } else { .Failed(.NotKept) }
            }
            case _ => {
                if client.admin || client.value >= service.value_count || client.value >= service.values.count {
                    refuse(end, service.port, .Refused)
                    continue
                }
                if !answer(service, client, &service.values[client.value], request, into, &out) {
                    // A Next, answered once there's a newer version
                    continue
                }
            }
        }
        _ = config.send_response(end, service.port, &out)
    }
}

// A request on client's connection to value, its answer into out: false for a Next that waits.
answer :: fn(service: ptr[mut Store], client: ptr[mut Client], value: ptr[mut Value], request: config.Request, into: ptr[os.Incoming],
    out: ptr[mut os.Outgoing]) -> bool {
    match request {
        case Declare(declared) => {
            default :: os.items(into, declared.default)
            if default.count > config.MAX_VALUE_BYTES {
                failed(out, .TooLarge)
                return true
            }
            match declare(service, value, declared.schema, default) {
                case Some(error) => failed(out, error)
                case None => current(service, value, out)
            }
        }
        case Read => current(service, value, out)
        case Next(seen) => {
            if value.newest <= seen && value.newest != 0 {
                client.waiting = true
                client.seen = seen
                return false
            }
            current(service, value, out)
        }
        case Write(written) => {
            override :: os.items(into, written.value)
            if override.count > config.MAX_VALUE_BYTES {
                failed(out, .TooLarge)
                return true
            }
            none : u8[32]
            wrote(service, client.value, out, write_version(service, value, written.fields, override, false, none))
        }
        case Rollback(version) => wrote(service, client.value, out, roll_back(service, value, version))
        case History(back) => kept(service, value, back, out)
        case _ => failed(out, .Refused)
    }
    return true
}

refuse :: fn(end: slop_os.Channel, port: slop_os.Port, error: config.ConfigError) {
    out := os.Outgoing.{}
    failed(&out, error)
    _ = config.send_response(end, port, &out)
}

failed :: fn(out: ptr[mut os.Outgoing], error: config.ConfigError) {
    os.begin[config.Response](out)^ = .Failed(error)
}

// A version written, or why not, as the answer into out, and every connection waiting on the value answered.
wrote :: fn(service: ptr[mut Store], value: usize, out: ptr[mut os.Outgoing], made: Result[u64, config.ConfigError]) {
    match made {
        case Ok(version) => {
            os.begin[config.Response](out)^ = .Written(version)
            wake(service, value)
        }
        case Error(error) => failed(out, error)
    }
}

// Every connection whose Next waits on value, given its current version.
wake :: fn(service: ptr[mut Store], value: usize) {
    if value >= service.values.count {
        return void
    }
    entry :: &service.values[value]
    for i in cast[usize](0)..<service.clients.count {
        client :: &service.clients[i]
        end :: service.connected.ends[i]
        if client.admin || client.value != value || !client.waiting || entry.newest <= client.seen || cast[slop_os.Handle](end) == slop_os.NO_HANDLE {
            continue
        }
        client.waiting = false
        out := os.Outgoing.{}
        current(service, entry, &out)
        _ = config.send_response(end, service.port, &out)
    }
}

// The value's newest version, as a Current into out, or NotDeclared.
current :: fn(service: ptr[mut Store], value: ptr[Value], out: ptr[mut os.Outgoing]) {
    match read_version(service, value, value.newest) {
        case Some(stored) => {
            defer runtime.free_array(stored)
            held :: os.typed_value[Stored](stored)
            response :: os.begin[config.Response](out)
            default :: os.append(out, os.items_of(stored, held.default))
            override :: os.append(out, os.items_of(stored, held.override))
            response^ = .Current(config.Current.{version = held.version, default = default, fields = held.fields, override = override})
        }
        case None => failed(out, .NotDeclared)
    }
}

// The kept version back versions from the newest, as Kept into out, or NoMore.
kept :: fn(service: ptr[mut Store], value: ptr[Value], back: u64, out: ptr[mut os.Outgoing]) {
    os.begin[config.Response](out)^ = .NoMore
    if back >= config.MAX_VERSIONS || back >= value.newest {
        return void
    }
    match read_version(service, value, value.newest - back) {
        case Some(stored) => {
            defer runtime.free_array(stored)
            held :: os.typed_value[Stored](stored)
            response :: os.begin[config.Response](out)
            author :: os.append(out, os.items_of(stored, held.author))
            response^ = .Kept(config.Version.{version = held.version, written = held.written, author = author, fields = held.fields})
        }
        case None => {}
    }
}

/*
 * The value's type and default declared: the first time, its first version, with no override; again with the same
 * type and default, nothing; with the same type and another default, a version with it, the override kept; and with
 * another type, a version without the override, which the new type can't read.
 */
declare :: fn(service: ptr[mut Store], value: ptr[mut Value], schema: u8[32], default: u8[]) -> config.ConfigError? {
    if value.newest == 0 {
        return write_stored(service, value, schema, default, 0, string_bytes(""))
    }
    stored :: read_version(service, value, value.newest) or_return config.ConfigError.NotKept
    defer runtime.free_array(stored)
    held :: os.typed_value[Stored](stored)
    if !same_bytes(held.schema, schema) {
        return write_stored(service, value, schema, default, 0, string_bytes(""))
    }
    if same_bytes(os.items_of(stored, held.default), default) {
        return null
    }
    return write_stored(service, value, schema, default, held.fields, os.items_of(stored, held.override))
}

// A new version, the newest's with fields and override, of type schema if checked: its number, or why not.
write_version :: fn(service: ptr[mut Store], value: ptr[mut Value], fields: u64, override: u8[], checked: bool, schema: u8[32])
    -> Result[u64, config.ConfigError] {
    stored :: read_version(service, value, value.newest) or_return .Error(.NotDeclared)
    defer runtime.free_array(stored)
    held :: os.typed_value[Stored](stored)
    if checked && !same_bytes(schema, held.schema) {
        return .Error(.WrongType)
    }
    match write_stored(service, value, held.schema, os.items_of(stored, held.default), fields, override) {
        case Some(error) => return .Error(error)
        case None => return .Ok(value.newest)
    }
}

// A new version with the override the kept version had, if it's of the newest's type.
roll_back :: fn(service: ptr[mut Store], value: ptr[mut Value], version: u64) -> Result[u64, config.ConfigError] {
    if version == 0 || version > value.newest || value.newest - version >= config.MAX_VERSIONS {
        return .Error(.NotFound)
    }
    stored :: read_version(service, value, version) or_return .Error(.NotFound)
    defer runtime.free_array(stored)
    held :: os.typed_value[Stored](stored)
    return write_version(service, value, held.fields, os.items_of(stored, held.override), true, held.schema)
}

/*
 * The value's next version written, with schema, default, fields and override, then named newest, and the one
 * MAX_VERSIONS before it deleted: why not, if it wasn't.
 */
write_stored :: fn(service: ptr[mut Store], value: ptr[mut Value], schema: u8[32], default: u8[], fields: u64, override: u8[])
    -> config.ConfigError? {
    version :: value.newest + 1
    written := cast[i64](0)
    match time.now() {
        case Ok(now) => written = now.seconds * 1000000000 + cast[i64](now.nanos)
        case Error(error) => {}
    }
    out := os.Outgoing.{}
    stored :: os.begin[Stored](&out)
    stored^ = Stored.{version = version, written = written, schema = schema, fields = fields}
    stored.author = os.append(&out, string_bytes(owner_of(value)))
    stored.default = os.append(&out, default)
    stored.override = os.append(&out, override)
    path := Path.{}
    if os.write_typed_in[Stored](service.directory, version_path(&path, value, version), os.value_bytes(&out)) != null {
        return config.ConfigError.NotKept
    }
    newest_out := os.Outgoing.{}
    os.begin[Newest](&newest_out)^ = Newest.{version = version}
    if os.write_typed_in[Newest](service.directory, value_path(&path, value, "newest"), os.value_bytes(&newest_out)) != null {
        return config.ConfigError.NotKept
    }
    value.newest = version
    if version > config.MAX_VERSIONS {
        _ = os.delete_file_in(service.directory, version_path(&path, value, version - config.MAX_VERSIONS))
    }
    return null
}

// A version's typed file's bytes, checked to hold a Stored, which the caller frees; null without one.
read_version :: fn(service: ptr[mut Store], value: ptr[Value], version: u64) -> u8[]? {
    if version == 0 {
        return null
    }
    path := Path.{}
    match os.read_typed_in[Stored](service.directory, version_path(&path, value, version)) {
        case Ok(bytes) => return bytes
        case Error(error) => return null
    }
}

/*
 * A connection to owner's value name, for the supervisor to give its program: the value found, or its directory made
 * and its newest version read, first. Null for a name that isn't one, or no room.
 */
connection_for :: fn(service: ptr[mut Store], owner: string, name: string) -> os.Channel[config.ConfigValue]? {
    if !valid_name(owner) || !valid_name(name) {
        return null
    }
    value := NOWHERE
    for i in cast[usize](0)..<service.values.count {
        if i < service.value_count && owner_of(&service.values[i]) == owner && name_of(&service.values[i]) == name {
            value = i
        }
    }
    if value == NOWHERE {
        if service.value_count >= service.values.count {
            return null
        }
        value = service.value_count
        entry :: &service.values[value]
        entry^ = Value.{}
        copy_name(&entry.owner, &entry.owner_count, owner)
        copy_name(&entry.name, &entry.name_count, name)
        if !open_value(service, entry) {
            return null
        }
        service.value_count += 1
    }
    pair :: os.channel_for[config.ConfigValue](service.block.budget, config.RING_BYTES) or_return null
    match service_kit.add_client_index(&service.connected, service.port, pair.a) {
        case Some(index) => if index < service.clients.count {
            service.clients[index] = Client.{value = value}
            return os.Channel[config.ConfigValue].{end = pair.b}
        }
        case None => {}
    }
    _ = slop_os.handle_close(cast[slop_os.Handle](pair.a))
    _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
    return null
}

// A value's directory, made if it isn't there, and its newest version read: whether it could be.
open_value :: fn(service: ptr[mut Store], value: ptr[mut Value]) -> bool {
    owner :: owner_of(value)
    if os.path_kind_in(service.directory, owner) != .DIRECTORY && os.make_directory_in(service.directory, owner) != null {
        return false
    }
    path := Path.{}
    folder :: value_path(&path, value, "")
    if os.path_kind_in(service.directory, folder) != .DIRECTORY && os.make_directory_in(service.directory, folder) != null {
        return false
    }
    value.newest = 0
    match os.read_typed_in[Newest](service.directory, value_path(&path, value, "newest")) {
        case Ok(bytes) => {
            value.newest = os.typed_value[Newest](bytes).version
            runtime.free_array(bytes)
        }
        case Error(error) => {}
    }
    return true
}

// The store's directory from now on, as when its volume server was started again: whether it took it.
use_directory :: fn(service: ptr[mut Store], end: slop_os.Channel) -> bool {
    directory, error :: os.directory_on(end)
    if error != null {
        return false
    }
    os.close_directory(service.directory)
    service.directory = directory
    runtime.log_info("using its directory again")
    return true
}

// A path being made.
Path :: struct {
    bytes : u8[96],
    count : usize,
}

// <owner>/<name>/<file>, or <owner>/<name> for no file, in path.
value_path :: fn(path: ptr[mut Path], value: ptr[Value], file: string) -> string {
    path.count = 0
    add(path, owner_of(value))
    add(path, "/")
    add(path, name_of(value))
    if file.count != 0 {
        add(path, "/")
        add(path, file)
    }
    return text_of_path(path)
}

// <owner>/<name>/<version>, in path.
version_path :: fn(path: ptr[mut Path], value: ptr[Value], version: u64) -> string {
    _ = value_path(path, value, "")
    add(path, "/")
    digits : u8[20]
    count := cast[usize](0)
    left := version
    loop {
        if count < digits.count {
            digits[count] = cast[u8](48 + left % 10)
            count += 1
        }
        left /= 10
    }
    while left != 0
    for i in cast[usize](0)..<count {
        at :: count - 1 - i
        if path.count < path.bytes.count && at < digits.count {
            path.bytes[path.count] = digits[at]
            path.count += 1
        }
    }
    return text_of_path(path)
}

add :: fn(path: ptr[mut Path], text: string) {
    for character in text {
        if path.count < path.bytes.count {
            path.bytes[path.count] = cast[u8](character)
            path.count += 1
        }
    }
}

text_of_path :: fn(path: ptr[Path]) -> string {
    return if path.count > 0 { string_of(&path.bytes[0], path.count) } else { "" }
}

owner_of :: fn(value: ptr[Value]) -> string {
    return if value.owner_count > 0 { string_of(&value.owner[0], value.owner_count) } else { "" }
}

name_of :: fn(value: ptr[Value]) -> string {
    return if value.name_count > 0 { string_of(&value.name[0], value.name_count) } else { "" }
}

copy_name :: fn(into: ptr[mut u8[MAX_NAME]], count: ptr[mut usize], name: string) {
    copied := cast[usize](0)
    for character in name {
        if copied < into.count {
            into^[copied] = cast[u8](character)
            copied += 1
        }
    }
    count^ = copied
}

// Letters, digits and underscores, MAX_NAME of them at most, and some.
valid_name :: fn(name: string) -> bool {
    if name.count == 0 || name.count > MAX_NAME {
        return false
    }
    for character in name {
        if !((character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z') || (character >= '0' && character <= '9') || character == '_') {
            return false
        }
    }
    return true
}

same_bytes :: fn(a: u8[], b: u8[]) -> bool {
    return as_text(a) == as_text(b)
}

as_text :: fn(bytes: u8[]) -> string {
    return if bytes.count > 0 { string_of(&bytes[0], bytes.count) } else { "" }
}
