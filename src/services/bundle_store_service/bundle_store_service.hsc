/*
 * The bundle store (roadmap 9b, decisions/0094, design/software.md §2): objects by their BLAKE3-256 hashes, in the
 * directory it's given on the system volume: objects/<hex>, each written as objects/<hex>.part and renamed once whole;
 * root, the boot root's hash in hex; pins/<name>, a pin's.
 *
 * Get gives an object as paged memory (decisions/0094), one memory object per object however many ask: the store is
 * its pager, reading each page as it's wanted through a read-only connection to the object's file, into a page of its
 * own memory the file server reads into, which it supplies from. Put takes an object's bytes in memory given, kept
 * only if they have the hash given. Collect marks the boot root, every pin, and what each refers to (a root's bundles,
 * a bundle's program, manifest, libraries and resources), and removes every other object, but those it has open.
 */
package bundle_store_service

import intrinsics from "base"
import runtime from "base"
import os from "std"
import crypto from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import read_only_file from "std/os/slop_os"
import files from "std/os/slop_os"
import service_kit from "../../service_kit"
import bundle from "../../bundle"
import bundle_store from "../../protocols/bundle_store"

MAX_OBJECTS :: 64
// The keys open objects' pager bindings are bound to the port with, after the clients'
PAGER_KEY : u64 : 1000
PAGE : u64 : 4096
NOWHERE : usize : 0xffffffffffffffff

// An object given out: its paged memory, which it supplies, its file's connection, and the page that's read into.
Open :: struct {
    used : bool,
    hash : bundle.Hash,
    memory : slop_os.Memory,
    size : u64,
    file : slop_os.Channel,
    file_port : slop_os.Port,
    buffer : slop_os.Memory,
    buffer_at : u64,
}

Store :: struct {
    block : ptr[slop_os.StartupBlock],
    port : slop_os.Port,
    connected : service_kit.Clients,
    // The store's directory: a connection of its own for opening objects' files, and one std's files use
    raw : slop_os.Channel,
    raw_port : slop_os.Port,
    directory : os.Directory,
    objects : Open[MAX_OBJECTS],
    // Pages wanted that couldn't be read, kept until there's a directory to read them through again
    unread : Unread[..],
}

Unread :: struct {
    slot : usize,
    offset : u64,
}

main :: fn(store: os.Channel[dir.Dir], clients: os.Listener[bundle_store.BundleStore]) -> int {
    service :: runtime.new(Store)
    service.block = slop_os.startup_block()
    service.port = slop_os.port_create(service.block.budget) or_return 1
    service.raw = store.end
    service.raw_port = os.port_for(service.block.budget, store.end) or_return 2
    second :: dir.connect(store.end, service.raw_port, service.block.budget) or_return 3
    directory, error :: os.directory_on(second.end)
    if error != null {
        return 4
    }
    service.directory = directory
    for folder in string.["objects", "pins"] {
        if os.path_kind_in(directory, folder) != .DIRECTORY {
            _ = os.make_directory_in(directory, folder)
        }
    }
    if !service_kit.add_client(&service.connected, service.port, clients.end) {
        return 5
    }
    runtime.log_info("serving")
    into := os.Incoming.{}
    loop {
        for i in cast[usize](0)..<service.connected.count {
            serve(service, i, &into)
        }
        packets : slop_os.Packet[8]
        taken :: slop_os.port_wait(service.port, packets, slop_os.NO_DEADLINE) or_else 0
        for packet, i in packets {
            if i >= cast[usize](taken) {
                break
            }
            if packet.key >= PAGER_KEY {
                supply_wanted(service, cast[usize](packet.key - PAGER_KEY))
            }
        }
    }
}

// Every request client index has sent, until there are none left, or it's gone.
serve :: fn(service: ptr[mut Store], index: usize, into: ptr[mut os.Incoming]) {
    if index >= service.connected.ends.count {
        return void
    }
    end :: service.connected.ends[index]
    if cast[slop_os.Handle](end) == slop_os.NO_HANDLE {
        return void
    }
    loop {
        match bundle_store.receive_request(end, service.port, into, false) {
            case Received => {}
            case Empty => return void
            case Unsupported => {
                _ = bundle_store.answer_unsupported(end, service.port)
                continue
            }
            case Invalid => continue
            case WrongProtocol => continue
            case Failed(error) => {
                service_kit.drop_client(&service.connected, index)
                return void
            }
        }
        out := os.Outgoing.{}
        response :: os.begin[bundle_store.Response](&out)
        match os.message_of[bundle_store.Request](into)^ {
            case Get(hash) => {
                match get(service, hash) {
                    case Some(object) => response^ = .Got(object)
                    case None => response^ = .Missing
                }
            }
            case Put(put) => response^ = if store_object(service, put) { .Done } else { .Refused }
            case Pin(pin) => {
                name :: as_text(os.items(into, pin.name))
                response^ = if valid_name(name) && write_hash(service, "pins", name, pin.hash) { .Done } else { .Refused }
            }
            case Unpin(name_bytes) => {
                name :: as_text(os.items(into, name_bytes))
                path_storage : u8[80]
                path :: path_in("pins/", name, &path_storage)
                response^ = if valid_name(name) && os.delete_file_in(service.directory, path) == null { .Done } else { .Missing }
            }
            case SetRoot(hash) => {
                response^ = if has_object(service, hash) && write_hash(service, "", "root", hash) { .Done } else { .Refused }
            }
            case Root => {
                match read_hash(service, "root") {
                    case Some(hash) => response^ = .Rooted(hash)
                    case None => response^ = .Missing
                }
            }
            case Collect => response^ = .Collected(collect(service))
            case UseDirectory(directory) => response^ = if use_directory(service, directory.end) { .Done } else { .Refused }
            case Connect(connection) => {
                if !service_kit.add_client(&service.connected, service.port, connection.end) {
                    _ = slop_os.handle_close(cast[slop_os.Handle](connection.end))
                }
                continue
            }
        }
        _ = bundle_store.send_response(end, service.port, &out)
    }
}

/*
 * An object as paged memory, read-only, which this store supplies: the same memory each time it's asked for, once
 * it's open. Null if there's no such object, or no room to open another.
 */
get :: fn(service: ptr[mut Store], hash: bundle.Hash) -> bundle_store.Object? {
    slot := NOWHERE
    for i in cast[usize](0)..<MAX_OBJECTS {
        if service.objects[i].used && bundle.same(service.objects[i].hash, hash) {
            return hand_out(service, i)
        }
        if !service.objects[i].used && slot == NOWHERE {
            slot = i
        }
    }
    if slot >= MAX_OBJECTS {
        return null
    }
    hex_storage : u8[64]
    path_storage : u8[80]
    path :: path_in("objects/", bundle.hex(hash, &hex_storage), &path_storage)
    out := os.Outgoing.{}
    request :: os.begin[dir.Request](&out)
    request^ = .OpenReadOnlyFile(os.append(&out, view_of(cast[ptr[u8]](path.data), path.count)))
    into := os.Incoming.{}
    file :: match ask_dir(service, &out, &into) {
        case OpenedReadOnlyFile(connection) => connection.end
        case _ => return null
    }
    open := Open.{used = true, hash = hash, file = file}
    open.file_port = os.port_for(service.block.budget, file) or_else cast[slop_os.Port](slop_os.NO_HANDLE)
    if !set_up(service, &open, slot) {
        close_open(service, &open)
        return null
    }
    service.objects[slot] = open
    return hand_out(service, slot)
}

/*
 * An open object's size, the page its file reads into, and its paged memory, bound to the port under PAGER_KEY plus
 * slot: false if any of it couldn't be made.
 */
set_up :: fn(service: ptr[mut Store], open: ptr[mut Open], slot: usize) -> bool {
    if cast[slop_os.Handle](open.file_port) == slop_os.NO_HANDLE {
        return false
    }
    asking := os.Outgoing.{}
    info_request :: os.begin[read_only_file.Request](&asking)
    info_request^ = .Info
    into := os.Incoming.{}
    match ask_file(open, &asking, &into) {
        case Described(info) => open.size = info.size
        case _ => return false
    }
    block :: service.block
    open.buffer = slop_os.memory_create(block.budget, PAGE) or_return false
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    open.buffer_at = runtime.reserve_addresses(cast[usize](PAGE)) or_else 0
    if open.buffer_at == 0 || (slop_os.memory_map(open.buffer, block.space, open.buffer_at, 0, PAGE, read_write) is_error) {
        open.buffer_at = 0
        return false
    }
    rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_READ) | cast[u32](slop_os.RIGHT_MEMORY_WRITE) | cast[u32](slop_os.RIGHT_TRANSFER))
    given :: slop_os.handle_duplicate(cast[slop_os.Handle](open.buffer), rights) or_return false
    buffering := os.Outgoing.{}
    buffer_request :: os.begin[read_only_file.Request](&buffering)
    buffer_request^ = .UseBuffer(cast[slop_os.Memory](given))
    match ask_file(open, &buffering, &into) {
        case Done => {}
        case _ => return false
    }
    key :: PAGER_KEY + cast[u64](slot)
    slop_os.port_bind_wake(service.port, key) or_return false
    pages :: if open.size == 0 { PAGE } else { (open.size + PAGE - 1) & ~(PAGE - 1) }
    match slop_os.memory_create_paged(block.budget, service.port, key, pages) {
        case Ok(made) => open.memory = made
        case Error(error) => {
            _ = slop_os.port_unbind(service.port, key)
            return false
        }
    }
    return true
}

// A handle to an open object's memory, to read and execute.
hand_out :: fn(service: ptr[Store], slot: usize) -> bundle_store.Object? {
    open :: service.objects[slot % MAX_OBJECTS]
    rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_READ) | cast[u32](slop_os.RIGHT_MEMORY_EXECUTE) | cast[u32](slop_os.RIGHT_DUPLICATE)
        | cast[u32](slop_os.RIGHT_TRANSFER))
    copy :: slop_os.handle_duplicate(cast[slop_os.Handle](open.memory), rights) or_return null
    return bundle_store.Object.{memory = cast[slop_os.Memory](copy), size = open.size}
}

close_open :: fn(service: ptr[Store], open: ptr[mut Open]) {
    if open.buffer_at != 0 {
        _ = slop_os.memory_unmap(service.block.space, open.buffer_at)
    }
    for each in slop_os.Handle.[cast[slop_os.Handle](open.buffer), cast[slop_os.Handle](open.file), cast[slop_os.Handle](open.file_port)] {
        if each != slop_os.NO_HANDLE {
            _ = slop_os.handle_close(each)
        }
    }
}

/*
 * The store's directory from now on: the same directory served again, as when the system volume's server was started
 * again. Open objects' files are opened again as their pages are next wanted.
 */
use_directory :: fn(service: ptr[mut Store], end: slop_os.Channel) -> bool {
    port :: os.port_for(service.block.budget, end) or_return false
    second :: dir.connect(end, port, service.block.budget) or_return false
    directory, error :: os.directory_on(second.end)
    if error != null {
        return false
    }
    os.close_directory(service.directory)
    _ = slop_os.handle_close(cast[slop_os.Handle](service.raw))
    _ = slop_os.handle_close(cast[slop_os.Handle](service.raw_port))
    service.raw = end
    service.raw_port = port
    service.directory = directory
    runtime.log_info("using its directory again")
    // The pages that couldn't be read meanwhile, read now
    waiting : Unread[..]
    defer runtime.array_free(&waiting)
    for each in service.unread {
        runtime.array_add(&waiting, each)
    }
    runtime.array_reset(&service.unread)
    for each in waiting {
        if !supply_page(service, each.slot, each.offset) {
            runtime.array_add(&service.unread, each)
        }
    }
    return true
}

/*
 * An open object's file opened again, through the store's directory, after its connection went with the server it was
 * on: whether it was.
 */
reopen :: fn(service: ptr[mut Store], open: ptr[mut Open]) -> bool {
    for each in slop_os.Handle.[cast[slop_os.Handle](open.file), cast[slop_os.Handle](open.file_port)] {
        if each != slop_os.NO_HANDLE {
            _ = slop_os.handle_close(each)
        }
    }
    hex_storage : u8[64]
    path_storage : u8[80]
    path :: path_in("objects/", bundle.hex(open.hash, &hex_storage), &path_storage)
    out := os.Outgoing.{}
    request :: os.begin[dir.Request](&out)
    request^ = .OpenReadOnlyFile(os.append(&out, view_of(cast[ptr[u8]](path.data), path.count)))
    into := os.Incoming.{}
    match ask_dir(service, &out, &into) {
        case OpenedReadOnlyFile(connection) => open.file = connection.end
        case _ => return false
    }
    open.file_port = os.port_for(service.block.budget, open.file) or_return false
    rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_READ) | cast[u32](slop_os.RIGHT_MEMORY_WRITE) | cast[u32](slop_os.RIGHT_TRANSFER))
    given :: slop_os.handle_duplicate(cast[slop_os.Handle](open.buffer), rights) or_return false
    buffering := os.Outgoing.{}
    buffer_request :: os.begin[read_only_file.Request](&buffering)
    buffer_request^ = .UseBuffer(cast[slop_os.Memory](given))
    return match ask_file(open, &buffering, &into) {
        case Done => true
        case _ => false
    }
}

// Each page of the open object at slot that's wanted, read from its file and supplied.
supply_wanted :: fn(service: ptr[mut Store], slot: usize) {
    if slot >= MAX_OBJECTS || !service.objects[slot].used {
        return void
    }
    loop {
        offset :: slop_os.memory_page_wanted(service.objects[slot].memory) or_break
        // Nothing to read it from until the store's given its directory again: kept for then, never supplied wrong
        if !supply_page(service, slot, offset) {
            runtime.array_add(&service.unread, Unread.{slot = slot, offset = offset})
        }
    }
}

/*
 * The page at offset of the open object at slot, read from its file, its file opened again if its connection went with
 * the server it was on, and supplied: false, with nothing supplied, if it couldn't be read.
 */
supply_page :: fn(service: ptr[mut Store], slot: usize, offset: u64) -> bool {
    if slot >= MAX_OBJECTS || !service.objects[slot].used {
        return true
    }
    open :: &service.objects[slot]
    reading := os.Outgoing.{}
    request :: os.begin[read_only_file.Request](&reading)
    request^ = .Read(files.Transfer.{offset = offset, count = cast[u32](PAGE), buffer_offset = 0})
    into := os.Incoming.{}
    read : u64 = 0
    transferred := false
    match ask_file(open, &reading, &into) {
        case Transferred(count) => {
            read = cast[u64](count)
            transferred = true
        }
        case _ => {}
    }
    if !transferred && reopen(service, open) {
        match ask_file(open, &reading, &into) {
            case Transferred(count) => {
                read = cast[u64](count)
                transferred = true
            }
            case _ => {}
        }
    }
    if !transferred {
        return false
    }
    // Past the object's end, zeros
    for i in read..<PAGE {
        intrinsics.volatile_store_u8(cast[ptr[mut u8]](cast[rawptr](open.buffer_at + i)), 0)
    }
    _ = slop_os.memory_supply(open.memory, offset, open.buffer, 0)
    return true
}

// An object put: its bytes, the first size of the memory given, kept if they have its hash; whether they're kept.
store_object :: fn(service: ptr[mut Store], put: bundle_store.PutOf) -> bool {
    defer slop_os.handle_close(cast[slop_os.Handle](put.data))
    available :: slop_os.memory_size(put.data) or_return false
    if put.size > available {
        return false
    }
    if has_object(service, put.hash) {
        return true
    }
    block :: service.block
    mapped_size :: if available == 0 { PAGE } else { available }
    address :: runtime.reserve_addresses(cast[usize](mapped_size)) or_return false
    slop_os.memory_map(put.data, block.space, address, 0, mapped_size, slop_os.PROTECTION_READ) or_return false
    defer slop_os.memory_unmap(block.space, address)
    bytes :: view_of(cast[ptr[u8]](address), cast[usize](put.size))
    if !bundle.same(bundle.hash_of(bytes), put.hash) {
        return false
    }
    hex_storage : u8[64]
    hex :: bundle.hex(put.hash, &hex_storage)
    part_storage : u8[80]
    final_storage : u8[80]
    part :: joined("objects/", hex, ".part", &part_storage)
    final :: joined("objects/", hex, "", &final_storage)
    if os.write_entire_file_in(service.directory, part, as_text(bytes)) != null {
        return false
    }
    return os.rename_in(service.directory, part, final) == null
}

has_object :: fn(service: ptr[Store], hash: bundle.Hash) -> bool {
    hex_storage : u8[64]
    path_storage : u8[80]
    return os.path_kind_in(service.directory, path_in("objects/", bundle.hex(hash, &hex_storage), &path_storage)) == .FILE
}

// A hash written in hex to folder/name, through a .part file renamed over it.
write_hash :: fn(service: ptr[mut Store], folder: string, name: string, hash: bundle.Hash) -> bool {
    hex_storage : u8[64]
    hex :: bundle.hex(hash, &hex_storage)
    part_storage : u8[80]
    final_storage : u8[80]
    prefix_storage : u8[80]
    prefix :: if folder.count > 0 { path_in(folder, "/", &prefix_storage) } else { "" }
    part :: joined(prefix, name, ".part", &part_storage)
    final :: joined(prefix, name, "", &final_storage)
    if os.write_entire_file_in(service.directory, part, hex) != null {
        return false
    }
    return os.rename_in(service.directory, part, final) == null
}

// The hash in hex in the file at path, or null.
read_hash :: fn(service: ptr[Store], path: string) -> bundle.Hash? {
    text :: os.read_entire_file_in(service.directory, path) or_return null
    defer runtime.free_array(bit_cast[u8[]](text))
    return bundle.from_hex(text)
}

/*
 * Every object no root reaches removed, but those open: marked from the boot root and every pin, through what each
 * refers to. How many were removed.
 */
collect :: fn(service: ptr[mut Store]) -> u64 {
    marked : bundle.Hash[..]
    defer runtime.array_free(&marked)
    match read_hash(service, "root") {
        case Some(root) => mark(service, root, &marked, 0)
        case None => {}
    }
    match os.list_directory_in(service.directory, "pins") {
        case Ok(pins) => {
            for pin in pins {
                if ends_with(pin.name, ".part") {
                    continue
                }
                path_storage : u8[80]
                match read_hash(service, path_in("pins/", pin.name, &path_storage)) {
                    case Some(hash) => mark(service, hash, &marked, 0)
                    case None => {}
                }
            }
            os.free_directory_listing(pins)
        }
        case Error(error) => {}
    }
    removed : u64 = 0
    match os.list_directory_in(service.directory, "objects") {
        case Ok(objects) => {
            for object in objects {
                path_storage : u8[80]
                path :: joined("objects/", object.name, "", &path_storage)
                keep := false
                match bundle.from_hex(object.name) {
                    case Some(hash) => {
                        keep = object.name.count == 64 && (is_marked(&marked, hash) || is_open(service, hash))
                    }
                    case None => {}
                }
                if !keep && os.delete_file_in(service.directory, path) == null {
                    removed += 1
                }
            }
            os.free_directory_listing(objects)
        }
        case Error(error) => {}
    }
    return removed
}

// hash marked, and what it refers to, if it's a root or a bundle; no deeper than a root's bundles' objects.
mark :: fn(service: ptr[Store], hash: bundle.Hash, marked: ptr[mut bundle.Hash[..]], depth: int) {
    if is_marked(marked, hash) || depth > 2 {
        return void
    }
    runtime.array_add(marked, hash)
    hex_storage : u8[64]
    path_storage : u8[80]
    record :: os.read_entire_file_in(service.directory, path_in("objects/", bundle.hex(hash, &hex_storage), &path_storage)) or_return void
    defer runtime.free_array(bit_cast[u8[]](record))
    bytes :: bit_cast[u8[]](record)
    referred : bundle.Hash[..]
    defer runtime.array_free(&referred)
    names : string[..]
    defer runtime.array_free(&names)
    if bundle.bundle_refers(bytes, &referred) {
        for each in referred {
            if !is_marked(marked, each) {
                runtime.array_add(marked, each)
            }
        }
        return void
    }
    if bundle.root_entries(bytes, &names, &referred) {
        for each in referred {
            mark(service, each, marked, depth + 1)
        }
    }
}

is_marked :: fn(marked: ptr[bundle.Hash[..]], hash: bundle.Hash) -> bool {
    for each in marked^ {
        if bundle.same(each, hash) {
            return true
        }
    }
    return false
}

is_open :: fn(service: ptr[Store], hash: bundle.Hash) -> bool {
    for open in service.objects {
        if open.used && bundle.same(open.hash, hash) {
            return true
        }
    }
    return false
}

// 1 to 32 letters, digits and underscores.
valid_name :: fn(name: string) -> bool {
    if name.count == 0 || name.count > 32 {
        return false
    }
    for character in name {
        if !((character >= 'a' && character <= 'z') || (character >= '0' && character <= '9') || character == '_') {
            return false
        }
    }
    return true
}

ask_dir :: fn(service: ptr[Store], out: ptr[mut os.Outgoing], into: ptr[mut os.Incoming]) -> dir.Response {
    if dir.send_request(service.raw, service.raw_port, out) is_some {
        return .Unsupported
    }
    loop {
        match dir.receive_response(service.raw, service.raw_port, into, true) {
            case Received => break
            case Failed(error) => return .Unsupported
            case _ => continue
        }
    }
    return os.message_of[dir.Response](into)^
}

ask_file :: fn(open: ptr[Open], out: ptr[mut os.Outgoing], into: ptr[mut os.Incoming]) -> read_only_file.Response {
    if read_only_file.send_request(open.file, open.file_port, out) is_some {
        return .Unsupported
    }
    loop {
        match read_only_file.receive_response(open.file, open.file_port, into, true) {
            case Received => break
            case Failed(error) => return .Unsupported
            case _ => continue
        }
    }
    return os.message_of[read_only_file.Response](into)^
}

// prefix then name, in storage.
path_in :: fn(prefix: string, name: string, storage: ptr[mut u8[80]]) -> string {
    count : usize = 0
    for text in string.[prefix, name] {
        for character in text {
            if count < storage.count {
                storage^[count] = cast[u8](character)
                count += 1
            }
        }
    }
    return if count > 0 { string_of(&storage^[0], count) } else { "" }
}

joined :: fn(a: string, b: string, c: string, storage: ptr[mut u8[80]]) -> string {
    count : usize = 0
    for text in string.[a, b, c] {
        for character in text {
            if count < storage.count {
                storage^[count] = cast[u8](character)
                count += 1
            }
        }
    }
    return if count > 0 { string_of(&storage^[0], count) } else { "" }
}

ends_with :: fn(text: string, end: string) -> bool {
    if end.count > text.count {
        return false
    }
    start :: text.count - end.count
    for character, i in end {
        at :: start + i
        if at >= text.count || text[at] != character {
            return false
        }
    }
    return true
}

as_text :: fn(bytes: u8[]) -> string {
    return if bytes.count > 0 { string_of(&bytes[0], bytes.count) } else { "" }
}
