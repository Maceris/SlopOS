/**
 * The config store (roadmap 9c2, decisions/0107, 0109, design/software.md §4): each owner's values, in the directory
 * it's given on the system volume, a directory each, <owner>/<name>/: a typed file per kept version, named by its
 * number, each a Stored, holding the value's type, its default, its override and which fields that sets, its author and
 * when it was written; and newest, a Newest, the newest version's number. A version is written before newest names it,
 * so a store stopped between the two has the version before, whole; the one past MAX_VERSIONS is deleted after.
 *
 * Connections to values are made on the supervisor's, which arrives on the admin listener (ValueFor): each reaches only
 * its own value. The session manager's, on the users listener, makes connections only to users' values, those whose
 * owner is "user:" and an account's name (decisions/0152). The store doesn't know a value's type, only its schema
 * hash: the program, which does, checks what it reads (config.read), and what it writes, before it sends it.
 */
package config_service

import runtime from "base"
import os from "std"
import time from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import service_kit from "../../libraries/service_kit"
import config from "../../protocols/config"

/**
 * The most values connections reach at once, since the store started; a ValueFor for another value past this many is
 * answered with Failed(Refused). Values stay counted once reached, even when forgotten.
 */
MAX_VALUES :: 32
/** The longest value name, and service owner name, in bytes: letters, digits and underscores only. */
MAX_NAME :: 31
/**
 * The longest owner in bytes: a user's is "user:", an account's name, and an installation's after a ":"
 * (decisions/0153).
 */
MAX_OWNER :: 72
/** The index a connection that reaches no value has in place of one: the supervisor's and the session manager's. */
NOWHERE : usize : 0xffffffffffffffff

/** A version of a value, as its typed file, <owner>/<name>/<version>, holds it. */
Stored :: struct {
    /** The version's number, from 1, one more than the version before it. */
    version : u64,
    /** When it was written, in nanoseconds since 1970-01-01T00:00:00Z; 0 if the clock couldn't be read. */
    written : i64,
    /** The schema hash of the value's type, as the program declared it; the store doesn't know the type itself. */
    schema : u8[32],
    /** Which of the type's fields the override sets, a bit each, in the order the type declares them. */
    fields : u64,
    /** Who wrote it: the value's owner, as every version is written through the owner's connection. */
    author : slop_os.Relative[u8],
    /** The type's default, T.{}'s bytes, as the program declared it. */
    default : slop_os.Relative[u8],
    /** The owner's override, its bytes; empty when there's none, as after a declaration of a new type. */
    override : slop_os.Relative[u8],
}

/**
 * The newest version's number, as the value's typed file <owner>/<name>/newest holds it; written only once that
 * version's own file is, so it never names a version that isn't whole.
 */
Newest :: struct {
    /** The newest version's number, from 1. */
    version : u64,
}

/** A value connections reach: its owner and name, and its newest version, 0 before it's declared. */
Value :: struct {
    /** The owner's bytes, owner_count of them, checked by valid_owner. */
    owner : u8[MAX_OWNER],
    /** How many of owner's bytes are the owner's. */
    owner_count : usize,
    /** The value's name's bytes, name_count of them, checked by valid_name. */
    name : u8[MAX_OWNER],
    /** How many of name's bytes are the name's. */
    name_count : usize,
    /** The newest version's number, as newest says on the volume; 0 before it's declared, or once it's forgotten. */
    newest : u64,
}

/** What a connection is: the supervisor's, or one to a value, and the version a Next of its waits to be past. */
Client :: struct {
    /** Whether it's the supervisor's, which may ask for connections to any value, use a directory and forget owners. */
    admin : bool,
    /** Whether it's the session manager's, which may ask for connections to, and forget, users' values only. */
    users : bool,
    /** The index in Store's values of the value it reaches; NOWHERE for the supervisor's and the session manager's. */
    value : usize,
    /** Whether a Next of its waits, unanswered, for a version past seen. */
    waiting : bool,
    /** The version the waiting Next is to be past; meaningful only while waiting. */
    seen : u64,
}

/** The config service's state, made once in main, on the heap, and kept for as long as it runs. */
Store :: struct {
    /** The process's startup block, whose budget pays for the port and the channels made to values. */
    block : ptr[slop_os.StartupBlock],
    /** The port every connection is bound to, under its index in connected, and which the service waits on. */
    port : slop_os.Port,
    /** Every connection's end, the supervisor's, the session manager's and those to values, closed when it goes. */
    connected : service_kit.Clients,
    /** What each connection in connected is, by the same index. */
    clients : Client[service_kit.MAX_CLIENTS],
    /** The directory on the system volume values are kept in, a directory per owner; replaced by UseDirectory. */
    directory : os.Directory,
    /** The values connections reach, value_count of them, in the order they were first reached. */
    values : Value[MAX_VALUES],
    /** How many of values are in use; it only grows. */
    value_count : usize,
}

/**
 * Keep programs' configuration values, each owner's in a directory of its own on the system volume, and serve them.
 *
 * Runs until it's stopped, answering requests as they come. A connection to a value is made only on the supervisor's
 * connection, or on the session manager's for a user's value, and is given to the program that owns the value.
 *
 * @param store The directory on the system volume the values are kept in, a directory per owner, made as needed.
 * @param admin The supervisor's connection: it asks for connections to any owner's values, forgets an owner's values,
 *     and gives the store its directory again after the volume server restarts.
 * @param users The session manager's connection, which asks for connections to users' values only, and forgets them.
 *     Without it, only the supervisor's connection makes connections.
 * @return 99 without the memory for its state, 1 if its port couldn't be made, 2 if store couldn't be opened as a
 *     directory, and 3 if admin or users couldn't be added as a client. It doesn't return otherwise.
 */
main :: fn(store: os.Channel[dir.Dir], admin: os.Listener[config.ConfigValue], users: os.Listener[config.ConfigValue]?) -> int {
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
    match users {
        case Some(listener) => {
            added :: service_kit.add_client_index(&service.connected, service.port, listener.end) or_return 3
            if added < service.clients.count {
                service.clients[added] = Client.{users = true, value = NOWHERE}
            }
        }
        case None => {}
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

/**
 * Answer every request a connection has sent, until there are none left, or it's gone.
 *
 * Each request is answered as it's read, except a Next that waits for a newer version, answered by wake. A request
 * the connection isn't allowed is answered with Failed(Refused), and one the protocol doesn't know with Unsupported;
 * one that can't be read is skipped. A connection whose end fails is dropped, its end closed.
 *
 * @param service The service's state.
 * @param index The connection's index in service.connected; one past them, or one already dropped, is left alone.
 * @param into Where each request is read into, reused from one to the next.
 */
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
                if !client.admin && !(client.users && is_users(as_text(os.items(into, wanted.owner)))) {
                    refuse(end, service.port, .Refused)
                    continue
                }
                response :: os.begin[config.Response](&out)
                match connection_for(service, as_text(os.items(into, wanted.owner)), as_text(os.items(into, wanted.name))) {
                    case Some(connection) => response^ = .Opened(connection)
                    case None => response^ = .Failed(.Refused)
                }
            }
            case Forget(owner) => {
                // A user's values only on the session manager's, when an installation of theirs is removed (decisions/0153)
                if !client.admin && !(client.users && is_users(as_text(os.items(into, owner)))) {
                    refuse(end, service.port, .Refused)
                    continue
                }
                response :: os.begin[config.Response](&out)
                response^ = if forget(service, as_text(os.items(into, owner))) { .Done } else { .Failed(.NotKept) }
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

/**
 * Answer a request on a connection to a value: Declare, Read, Next, Write, Rollback or History.
 *
 * A Write, a Rollback, and a Declare that changes the value each write a new version to the volume, and a version
 * written wakes every connection whose Next waits on the value. A default or an override larger than
 * config.MAX_VALUE_BYTES is answered with Failed(TooLarge), and any other request with Failed(Refused).
 *
 * @param service The service's state.
 * @param client The connection the request came on, to client's value; its Next is recorded on it when it waits.
 * @param value The value the connection reaches.
 * @param request The request, as read.
 * @param into The message the request was read from, which holds its default or override.
 * @param out Where the answer is built, which the caller sends; untouched for a Next that waits.
 * @return False for a Next that waits for a version past the newest, to be answered later; true when out holds the
 *     answer.
 */
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

/**
 * Answer a request with Failed, at once.
 *
 * @param end The connection's end, which stays open.
 * @param port The service's port, waited on while the ring is full.
 * @param error Why the request is refused.
 */
refuse :: fn(end: slop_os.Channel, port: slop_os.Port, error: config.ConfigError) {
    out := os.Outgoing.{}
    failed(&out, error)
    _ = config.send_response(end, port, &out)
}

/**
 * Put Failed with an error in an answer being built, in place of anything begun there.
 *
 * @param out The answer, which the caller sends.
 * @param error Why the request failed.
 */
failed :: fn(out: ptr[mut os.Outgoing], error: config.ConfigError) {
    os.begin[config.Response](out)^ = .Failed(error)
}

/**
 * Put the answer to a write or a rollback in out: Written with its version, or Failed with why not; and, for a version
 * written, answer every connection whose Next waits on the value.
 *
 * @param service The service's state.
 * @param value The value's index in service.values.
 * @param out The answer, which the caller sends.
 * @param made What writing the version gave: its number, or why it wasn't written.
 */
wrote :: fn(service: ptr[mut Store], value: usize, out: ptr[mut os.Outgoing], made: Result[u64, config.ConfigError]) {
    match made {
        case Ok(version) => {
            os.begin[config.Response](out)^ = .Written(version)
            wake(service, value)
        }
        case Error(error) => failed(out, error)
    }
}

/**
 * Answer every connection whose Next waits on a value and whose version is now past the one it saw, with the value's
 * current version, sent at once.
 *
 * @param service The service's state.
 * @param value The value's index in service.values; one past them wakes no one.
 */
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

/**
 * Put a value's newest version in an answer: Current, with its number, default, fields and override, read from its
 * typed file on the volume.
 *
 * @param service The service's state.
 * @param value The value; one not declared, or whose newest version can't be read, is answered with
 *     Failed(NotDeclared).
 * @param out The answer, which the caller sends.
 */
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

/**
 * Put a kept version of a value in an answer: Kept, with its number, when it was written, its author and the fields
 * its override set.
 *
 * @param service The service's state, whose directory the version's file is read from; nothing in it changes.
 * @param value The value whose versions are read, declared or not; only read, its newest number bounding how far back
 *     goes.
 * @param back How many versions back from the newest: 0 for the newest, up to config.MAX_VERSIONS - 1. Past the
 *     versions kept, or past the first version, the answer is NoMore, as it is when the version's file can't be read.
 * @param out The answer, which the caller sends.
 */
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

/**
 * Declare a value's type and default, writing a new version when either changed.
 *
 * The first time, the value's first version is written, with no override; again with the same type and default,
 * nothing is written; with the same type and another default, a version with it, the override and its fields kept;
 * and with another type, a version without the override, which the new type can't read. The versions before it are
 * kept, but can't be rolled back to, being of another type.
 *
 * @param service The service's state.
 * @param value The value, whose newest is moved to the version written.
 * @param schema The type's schema hash.
 * @param default The type's default, T.{}'s bytes, at most config.MAX_VALUE_BYTES of them (the caller checks).
 * @return Null once the value has the type and default, written or already there; NotKept if the newest version
 *     couldn't be read, or the new one or newest couldn't be written.
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

/**
 * Write a new version of a value: the newest's type and default, with another override.
 *
 * @param service The service's state.
 * @param value The value, whose newest is moved to the version written.
 * @param fields Which of the type's fields override sets, a bit each.
 * @param override The override's bytes, at most config.MAX_VALUE_BYTES of them (the caller checks).
 * @param checked Whether schema is checked against the newest version's type, as for a rollback; a write isn't.
 * @param schema The type override is of, when checked; ignored otherwise.
 * @return The new version's number.
 * @error NotDeclared The value has no version, or its newest couldn't be read.
 * @error WrongType Checked, and schema isn't the newest version's type.
 * @error NotKept The version, or newest, couldn't be written.
 */
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

/**
 * Roll a value back: write a new version with the override, and its fields, a kept version had.
 *
 * @param service The service's state.
 * @param value The value, whose newest is moved to the version written.
 * @param version The kept version's number: from 1 to the newest, and one of the newest config.MAX_VERSIONS.
 * @return The new version's number.
 * @error NotFound No such version is kept, or its file couldn't be read.
 * @error WrongType The kept version is of another type than the newest's, from before a declaration of a new type.
 * @error NotDeclared The newest version couldn't be read.
 * @error NotKept The version, or newest, couldn't be written.
 */
roll_back :: fn(service: ptr[mut Store], value: ptr[mut Value], version: u64) -> Result[u64, config.ConfigError] {
    if version == 0 || version > value.newest || value.newest - version >= config.MAX_VERSIONS {
        return .Error(.NotFound)
    }
    stored :: read_version(service, value, version) or_return .Error(.NotFound)
    defer runtime.free_array(stored)
    held :: os.typed_value[Stored](stored)
    return write_version(service, value, held.fields, os.items_of(stored, held.override), true, held.schema)
}

/**
 * Write a value's next version, then name it newest, then delete the one config.MAX_VERSIONS before it.
 *
 * The owner's directory and the value's are made again first if they're gone, as after a Forget. The version's file
 * is written and closed before newest is, so a store stopped between them has the version before as the newest,
 * whole; a version written but not named is written over by the next. A failed delete of the oldest version is
 * ignored.
 *
 * @param service The service's state.
 * @param value The value, whose newest is moved to the version written once newest names it.
 * @param schema The type's schema hash.
 * @param default The type's default's bytes.
 * @param fields Which of the type's fields override sets, a bit each.
 * @param override The override's bytes, empty for none.
 * @return Null once the version is written and named newest; NotKept if either file couldn't be written, the value's
 *     newest left as it was.
 */
write_stored :: fn(service: ptr[mut Store], value: ptr[mut Value], schema: u8[32], default: u8[], fields: u64, override: u8[])
    -> config.ConfigError? {
    // Its directory made again, if its owner's values were forgotten since it was opened
    owner :: owner_of(value)
    if os.path_kind_in(service.directory, owner) != .DIRECTORY {
        _ = os.make_directory_in(service.directory, owner)
    }
    folder_path := Path.{}
    folder :: value_path(&folder_path, value, "")
    if os.path_kind_in(service.directory, folder) != .DIRECTORY {
        _ = os.make_directory_in(service.directory, folder)
    }
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

/**
 * Read a version's typed file, checked to hold a Stored.
 *
 * @param service The service's state, whose directory the file is read from; nothing in it changes.
 * @param value The value whose <owner>/<name>/<version> file is read; only read.
 * @param version The version's number; 0, a value not declared, gives null.
 * @return The file's bytes, from the context's allocator, which the caller frees; null for version 0, or if the file
 *     isn't there, isn't a Stored, or couldn't be read.
 */
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

/**
 * Make a connection to an owner's value, for the supervisor, or the session manager, to give its program.
 *
 * The value is found among those reached already, or, the first time, its directories are made and its newest version
 * read from the volume. A channel is made, paid for from the service's budget, and its end kept as a new client.
 *
 * @param service The service's state.
 * @param owner The value's owner, checked by valid_owner.
 * @param name The value's name, its program's entry's parameter's, checked by valid_name.
 * @return The other end of the connection, which the caller owns and passes on; null for an owner or a name that isn't
 *     valid, MAX_VALUES values reached already, directories that couldn't be made, or no channel or client room.
 */
connection_for :: fn(service: ptr[mut Store], owner: string, name: string) -> os.Channel[config.ConfigValue]? {
    if !valid_owner(owner) || !valid_name(name) {
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

/**
 * Open a value the first time it's reached: make its owner's directory and its own if they aren't there, and read its
 * newest version.
 *
 * @param service The service's state.
 * @param value The value, whose newest is set: what newest on the volume says, or 0 if it can't be read, as for a
 *     value never declared.
 * @return Whether both directories are there; false if either couldn't be made.
 */
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

/**
 * Remove every value of an owner's, as when it's uninstalled: each value's versions and newest, each value's own
 * directory, and the owner's directory.
 *
 * The owner's values reached already start again from nothing, newest 0, so the next declaration writes a first
 * version; connections to them stay open. What couldn't be removed is left, and the rest still removed.
 *
 * @param service The service's state.
 * @param owner The owner, checked by valid_owner.
 * @return Whether everything was removed, or there was nothing; false for an owner that isn't valid, a directory that
 *     couldn't be listed, or anything left.
 */
forget :: fn(service: ptr[mut Store], owner: string) -> bool {
    if !valid_owner(owner) {
        return false
    }
    for i in cast[usize](0)..<service.values.count {
        if i < service.value_count && owner_of(&service.values[i]) == owner {
            service.values[i].newest = 0
        }
    }
    if os.path_kind_in(service.directory, owner) != .DIRECTORY {
        return true
    }
    whole := true
    names :: os.list_directory_in(service.directory, owner) or_return false
    defer os.free_directory_listing(names)
    for name in names {
        folder := Path.{}
        add(&folder, owner)
        add(&folder, "/")
        add(&folder, name.name)
        folder_text :: text_of_path(&folder)
        versions :: os.list_directory_in(service.directory, folder_text) or_continue
        for version in versions {
            file := Path.{}
            add(&file, folder_text)
            add(&file, "/")
            add(&file, version.name)
            whole = os.delete_file_in(service.directory, text_of_path(&file)) == null && whole
        }
        os.free_directory_listing(versions)
        whole = os.remove_directory_in(service.directory, folder_text) == null && whole
    }
    whole = os.remove_directory_in(service.directory, owner) == null && whole
    runtime.log_info("forgot %'s values", owner)
    return whole
}

/**
 * Use another directory for the values from now on, as when the system volume's server was started again, closing
 * the one before.
 *
 * @param service The service's state.
 * @param end The new directory's end, which the service takes over, even when it fails.
 * @return Whether it's used; false if a port for it couldn't be made, the directory before kept.
 */
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

/** A path being made, on the stack, in the store's directory; what doesn't fit is cut off. */
Path :: struct {
    /** The path's bytes, count of them. */
    bytes : u8[160],
    /** How many of bytes are the path's. */
    count : usize,
}

/**
 * Make a value's path, or a file's in its directory.
 *
 * @param path Where it's made, from its start.
 * @param value The value whose owner and name make the path; only read.
 * @param file The file's name in the value's directory, or "" for the directory itself.
 * @return <owner>/<name>/<file>, or <owner>/<name> for no file, a view of path's bytes, good while path is unchanged.
 */
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

/**
 * Make a version's path, its file named by its number in decimal.
 *
 * @param path Where it's made, from its start.
 * @param value The value whose owner and name make the path's start; only read.
 * @param version The version's number, from 1, written in decimal with no leading zeros.
 * @return <owner>/<name>/<version>, a view of path's bytes, good while path is unchanged.
 */
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

/**
 * Add text to the end of a path being made; what doesn't fit is dropped.
 *
 * @param path The path being made, added to at its count, which grows by the bytes that fit in its 160.
 * @param text The bytes appended, as they are; those past the path's 160 bytes are dropped.
 */
add :: fn(path: ptr[mut Path], text: string) {
    for character in text {
        if path.count < path.bytes.count {
            path.bytes[path.count] = cast[u8](character)
            path.count += 1
        }
    }
}

/**
 * Give a path being made as text.
 *
 * @param path The path made so far; only read.
 * @return A view of path's bytes, good while path is unchanged; "" for an empty path.
 */
text_of_path :: fn(path: ptr[Path]) -> string {
    return if path.count > 0 { string_of(&path.bytes[0], path.count) } else { "" }
}

/**
 * Give a value's owner as text.
 *
 * @param value The value whose owner is given; only read.
 * @return A view of value's owner bytes, good while value is unchanged.
 */
owner_of :: fn(value: ptr[Value]) -> string {
    return if value.owner_count > 0 { string_of(&value.owner[0], value.owner_count) } else { "" }
}

/**
 * Give a value's name as text.
 *
 * @param value The value whose name is given; only read.
 * @return A view of value's name bytes, good while value is unchanged.
 */
name_of :: fn(value: ptr[Value]) -> string {
    return if value.name_count > 0 { string_of(&value.name[0], value.name_count) } else { "" }
}

/**
 * Copy a name into a value's fixed array; what doesn't fit is cut off.
 *
 * @param into The value's owner or name array, MAX_OWNER bytes, written from its start; bytes past the name are left as
 *     they were.
 * @param count Set to how many bytes were copied.
 * @param name The name, an owner or a value's name, checked already.
 */
copy_name :: fn(into: ptr[mut u8[MAX_OWNER]], count: ptr[mut usize], name: string) {
    copied := cast[usize](0)
    for character in name {
        if copied < into.count {
            into^[copied] = cast[u8](character)
            copied += 1
        }
    }
    count^ = copied
}

/**
 * Tell whether a name may be a value's, or a service owner's, and so a directory's.
 *
 * @param name The name to check, a value's or a service owner's as connection_for is given it, not yet checked; only
 *     read.
 * @return Whether it's 1 to MAX_NAME bytes, each an ASCII letter, a digit or an underscore.
 */
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

/**
 * Tell whether two byte arrays hold the same bytes.
 *
 * @param a The first bytes compared; only read.
 * @param b The second bytes compared; only read.
 * @return Whether they're as long as each other, with the same bytes.
 */
same_bytes :: fn(a: u8[], b: u8[]) -> bool {
    return as_text(a) == as_text(b)
}

/**
 * Give bytes as text, without checking they're UTF-8.
 *
 * @param bytes The bytes, kept by the caller; the view points into them, so they must outlive it.
 * @return A view of them, good while they are; "" for none.
 */
as_text :: fn(bytes: u8[]) -> string {
    return if bytes.count > 0 { string_of(&bytes[0], bytes.count) } else { "" }
}

/**
 * Tell whether an owner may be one, and so a directory's name.
 *
 * @param owner The owner: a service's name, as valid_name takes; or a user's, "user:" and an account's name, letters,
 *     digits, - and _, or "-" for a session with no user, and for an installation of theirs ":" and its name after
 *     that (decisions/0152, 0153).
 * @return Whether it's one of those, MAX_OWNER bytes at most, with no empty part around a ":".
 */
valid_owner :: fn(owner: string) -> bool {
    if !is_users(owner) {
        return valid_name(owner)
    }
    if owner.count > MAX_OWNER {
        return false
    }
    colons := 0
    previous := ':'
    for character, i in owner {
        if i < 5 {
            continue
        }
        if character == ':' {
            colons += 1
            if colons > 1 || previous == ':' {
                return false
            }
        }
        else if !((character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z') || (character >= '0' && character <= '9')
            || character == '_' || character == '-') {
            return false
        }
        previous = character
    }
    return previous != ':'
}

/**
 * Tell whether an owner is a user's.
 *
 * @param owner The owner, not yet checked.
 * @return Whether it starts with "user:" and has something after it.
 */
is_users :: fn(owner: string) -> bool {
    prefix :: "user:"
    return owner.count > prefix.count && owner[0..<prefix.count] == prefix
}
