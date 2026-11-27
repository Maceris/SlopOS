/**
 * The bundle store (roadmap 9b, decisions/0094, design/software.md §2): objects by their BLAKE3-256 hashes, in the
 * directory it's given on the system volume: objects/<hex>, each written as objects/<hex>.part and renamed once whole;
 * root, the boot root's hash in hex; pins/<name>, a pin's.
 *
 * Get gives an object as paged memory (decisions/0094), one memory object per object however many ask: the store is
 * its pager, reading each page as it's wanted through a read-only connection to the object's file, into a page of its
 * own memory the file server reads into, which it supplies from. Read gives a copy of a small object, and keeps those
 * up to MAX_KEPT_OBJECT bytes, MAX_KEPT_BYTES of them, so one asked for again isn't read from its file; it keeps the
 * boot root's hash, too, once read or set. Put takes an object's bytes in memory given, kept
 * only if they have the hash given. Collect marks the boot root, every pin, and what each refers to (a root's bundles,
 * a bundle's program, manifest, libraries and resources), and removes every other object, but those it has open.
 *
 * The pages it has supplied are a cache, which its budget pays for a page at a time (decisions/0111): once they bring
 * its budget to its threshold, three quarters of its limit, or what CacheLimit sets, the kernel raises SIGNAL_PRESSURE,
 * and the store gives pages back until it's below LOW_WATER of the threshold, by a clock over them: a page touched
 * since the hand last passed it is passed again, one that wasn't is given back. A page given back is read again when
 * it's next wanted. A supply its budget refuses gives pages back first, too.
 */
package bundle_store_service

import intrinsics from "base:intrinsics"
import runtime from "base:runtime"
import crypto from "std:crypto"
import os from "std:os"
import slop_os from "std:os/slop_os"
import dir from "std:os/slop_os/dir"
import files from "std:os/slop_os/files"
import read_only_file from "std:os/slop_os/read_only_file"
import bundle from "../../bundle"
import service_kit from "../../libraries/service_kit"
import bundle_store from "../../protocols/bundle_store"

/**
 * The most objects open at once: given out by Get, each a slot of Store's objects. When they're all open, a Get for
 * another closes the one given out longest ago that no one holds any more (decisions/0178), and answers Missing only if
 * every one is held.
 */
MAX_OBJECTS :: 256
/**
 * The most objects' files open at once, each a connection to the system volume's server. A file's opened when its
 * object's pages are read, and the one read from longest ago closed to make room, so an object that's open, or held,
 * costs no connection, and the store never takes up more than this many of the server's.
 */
MAX_FILES :: 16
/** The keys open objects' pager bindings are bound to the port with, PAGER_KEY plus the slot, after the clients'. */
PAGER_KEY : u64 : 1000
/** The key its budget's pressure is bound to the port with, between the clients' and the objects'. */
PRESSURE_KEY : u64 : 900
/**
 * What it gives pages back down to, under pressure: this many sixteenths of the threshold, past what its pages don't
 * pay for.
 */
LOW_WATER_SIXTEENTHS : u64 : 12
/** A page's size in bytes, what's read from an object's file and supplied at a time. */
PAGE : u64 : 4096
/** The slot a search found none in. */
NOWHERE : usize : 0xffffffffffffffff
/**
 * The most bytes of objects Read keeps, so a manifest or a bundle's record asked for again isn't read from its file
 * again: 512 KiB. Past them, all it keeps is forgotten, and kept again as it's read.
 */
MAX_KEPT_BYTES : u64 : 512 * 1024
/** The largest object Read keeps, in bytes: 64 KiB; a larger one's read from its file each time. */
MAX_KEPT_OBJECT : u64 : 64 * 1024

/** An object Read keeps: its bytes, on the heap, the same as its file's, as an object's hash names its bytes. */
Kept :: struct {
    /** The object's hash. */
    hash : bundle.Hash,
    /** Its bytes, the store's. */
    bytes : u8[],
}

/** An object given out: its paged memory, which it supplies, its pages read from its file through files (FileOpen). */
Open :: struct {
    /** Whether the slot holds an open object; cleared when it's closed to make room (close_slot). */
    used : bool,
    /** When it was last given out, by the store's count of what it's given (Store's given); 0 for never. */
    given_at : u64,
    /** The object's BLAKE3-256 hash, its file's name in hex under objects/. */
    hash : bundle.Hash,
    /** The paged memory, the store's own, supplied by it; each Get gives a duplicate to read and execute. */
    memory : slop_os.Memory,
    /** The object's size in bytes, its file's; memory is that rounded up to whole pages, one page for an empty one. */
    size : u64,
}

/**
 * An object's file, opened to read its pages from: the connection, and a page of the store's the file server reads
 * into, which is kept when the file's closed, for the next file opened in its place.
 */
FileOpen :: struct {
    /** Whether file and file_port are open, for the object in slot. */
    used : bool,
    /** The object's slot in Store's objects; meaningless while it isn't used. */
    slot : usize,
    /** When it was last read from, by the store's count of reads (Store's reads); the oldest is closed for another. */
    read_at : u64,
    /** A read-only connection to the object's file, closed if it fails, as when the server it was on has gone. */
    file : slop_os.Channel,
    /** A port bound to file, waited on for its answers; NO_HANDLE if it couldn't be made. */
    file_port : slop_os.Port,
    /** The page the file server reads into, the store's own memory, supplied from; made the first time it's needed. */
    buffer : slop_os.Memory,
    /** Where buffer is mapped, readable and writable, in the store's address space; 0 until it's made. */
    buffer_at : u64,
}

/** The bundle store's state, made once in main, on the heap, and kept for as long as it runs. */
Store :: struct {
    /** The process's startup block, whose budget pays for the pages supplied, the port and the open objects. */
    block : ptr[slop_os.StartupBlock],
    /** The port clients, open objects' pagers and the budget's pressure are bound to, waited on in main. */
    port : slop_os.Port,
    /** The clients' ends: the listener's, and connections arrived as Connects; bound under their indices. */
    connected : service_kit.Clients,
    /** The store's directory: a connection of its own, for opening objects' files. */
    raw : slop_os.Channel,
    /** A port bound to raw, waited on for its answers. */
    raw_port : slop_os.Port,
    /** A second connection to the store's directory, which std's files use. */
    directory : os.Directory,
    /** The objects given out, by slot. */
    objects : Open[MAX_OBJECTS],
    /** The objects' files open, to read their pages from, in no order. */
    files : FileOpen[MAX_FILES],
    /** How many pages, and objects' sizes, it's read from files since it started, which marks each's read_at. */
    reads : u64,
    /**
     * How many of files it uses, from the first: MAX_FILES, or fewer with store_files=N on the kernel's command line,
     * so a
     * test can have it open and close them far more often.
     */
    file_limit : usize,
    /** Pages wanted that couldn't be read, kept until there's a directory to read them through again. */
    unread : Unread[..],
    /** The pages supplied, in the order the clock's hand goes round them. */
    resident : Unread[..],
    /** Where the clock's hand is: an index in resident, past its end meaning its start. */
    hand : usize,
    /** Pages given back since it started, as Evictions answers. */
    evicted : u64,
    /** How many times it's given out an object, which marks each open one's given_at. */
    given : u64,
    /** Objects closed to make room for others, since it started. */
    closed : u64,
    /**
     * How many objects it keeps open, from the first slot: MAX_OBJECTS, or fewer with store_objects=N on the kernel's
     * command line, so a test can open more than it keeps without as many programs.
     */
    limit : usize,
    /** What its budget had charged that isn't pages, in bytes, when its threshold was last set from a cache limit. */
    cache_base : u64,
    /** The cache limit in bytes, as CacheLimit last set it; 0 for three quarters of its budget's limit. */
    cache_limit : u64,
    /**
     * The boot root's hash as last read from root or set by SetRoot, so Root, asked by each program's launch and each
     * lookup, doesn't read the file each time; null until it's read, and again once the directory's replaced. Only
     * the store writes root.
     */
    root : bundle.Hash?,
    /** The objects Read keeps, at most MAX_KEPT_BYTES of them; forgotten under pressure, and by a collection. */
    kept : Kept[..],
    /** How many bytes kept holds. */
    kept_bytes : u64,
}

/** A page of an open object: one wanted that's waiting to be read, or one supplied. */
Unread :: struct {
    /** The object's slot in Store's objects. */
    slot : usize,
    /** The page's offset in the object's memory, in bytes, a multiple of PAGE. */
    offset : u64,
}

/**
 * Keep objects by their hashes in a directory on the system volume, and serve them as paged memory.
 *
 * Runs until it's stopped. Makes objects/ and pins/ in the directory if they aren't there.
 *
 * @param store The directory on the system volume the objects, the boot root and the pins are kept in.
 * @param clients The listener clients' connections arrive on; more arrive as Connects on those.
 * @param command_line The kernel's command line, read for store_objects=N: how many objects it keeps open, 1 to
 *     MAX_OBJECTS, and store_files=N: how many of their files, 1 to MAX_FILES, both for tests. Without it, or a word,
 *     MAX_OBJECTS or MAX_FILES.
 * @return 99 without the memory for its state, 1 if its port couldn't be made or bound to its budget's pressure, 2 if
 *     a port for store couldn't be made, 3 if a second connection to store couldn't be made, 4 if that couldn't be
 *     opened as a directory, and 5 if clients couldn't be added as a client. It doesn't return otherwise.
 */
main :: fn(
    store : os.Channel[dir.Dir],
    clients : os.Listener[bundle_store.BundleStore],
    command_line : slop_os.Memory?
) -> int {
    // Its state; without the memory for it, it ends with 99 (decisions/0104)
    service_made, service_error :: runtime.new_aligned(Store, align_of(Store))
    if service_error != null {
        return 99
    }
    service :: service_made
    service.block = slop_os.startup_block()
    service.limit = MAX_OBJECTS
    service.file_limit = MAX_FILES
    service.root = null
    match command_line {
        case Some(memory) => {
            text :: service_kit.text_of(service.block, memory) or_else ""
            wanted :: service_kit.number_of(service_kit.word_after(text, "store_objects=") or_else "") or_else 0
            if wanted > 0 && wanted < cast[u64](MAX_OBJECTS) {
                service.limit = cast[usize](wanted)
            }
            files_wanted :: service_kit.number_of(service_kit.word_after(text, "store_files=") or_else "") or_else 0
            if files_wanted > 0 && files_wanted < cast[u64](MAX_FILES) {
                service.file_limit = cast[usize](files_wanted)
            }
        }
        case None => {}
    }
    service.port = slop_os.port_create(service.block.budget) or_return 1
    _ = service_kit.watch_stop(service.port)
    // Pressure on its budget, which its pages bring it to, wakes it to give some back
    slop_os.port_bind(
        service.port,
        PRESSURE_KEY,
        cast[slop_os.Handle](service.block.budget),
        slop_os.SIGNAL_PRESSURE,
        .Persistent
    )
        or_return 1
    set_cache_limit(service, 0)
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
        // Asked to stop, as the system shuts down (decisions/0182): what it was doing is done
        if service_kit.stopping() {
            return 0
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
            else if packet.key == PRESSURE_KEY {
                relieve(service)
            }
        }
    }
}

/**
 * Answer every request a client has sent, until there are none left, or it's gone.
 *
 * Each request is answered as it's read, but a Connect, whose connection is added as a client, and closed if there's
 * no room, with no answer. One the protocol doesn't know is answered with Unsupported; one that can't be read is
 * skipped. A client whose end fails is dropped, its end closed.
 *
 * @param service The store's state: requests are read from, and answered on, service.connected's ends through its port,
 *     and acted on through its directory, objects and cache; a client whose end fails is dropped from connected, and a
 *     Connect adds one.
 * @param index The client's index in service.connected; one past them, or one already dropped, is left alone.
 * @param into Where each request is read into, reused from one to the next.
 */
serve :: fn(service : ptr[mut Store], index : usize, into : ptr[mut os.Incoming]) {
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
            case _ => {
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
            case Read(hash) => {
                match read_copy(service, hash) {
                    case Some(object) => response^ = .Got(object)
                    case None => response^ = .Missing
                }
            }
            case Put(put) => response^ = if store_object(service, put) { .Done } else { .Refused }
            case Pin(pin) => {
                name :: as_text(os.items(into, pin.name))
                response^ = if valid_name(name) && write_hash(service, "pins", name, pin.hash) {
                    .Done
                }
                else {
                    .Refused
                }
            }
            case Unpin(name_bytes) => {
                name :: as_text(os.items(into, name_bytes))
                path_storage : u8[80]
                path :: path_in("pins/", name, &path_storage)
                response^ = if valid_name(name) && os.delete_file_in(service.directory, path) == null {
                    .Done
                }
                else {
                    .Missing
                }
            }
            case SetRoot(hash) => {
                if has_object(service, hash) && write_hash(service, "", "root", hash) {
                    service.root = hash
                    response^ = .Done
                }
                else {
                    response^ = .Refused
                }
            }
            case Root => {
                if service.root is_none {
                    service.root = read_hash(service, "root")
                }
                match service.root {
                    case Some(hash) => response^ = .Rooted(hash)
                    case None => response^ = .Missing
                }
            }
            case Collect => response^ = .Collected(collect(service))
            case UseDirectory(
                directory
            ) => response^ = if use_directory(service, directory.end) { .Done } else { .Refused }
            case CacheLimit(bytes) => {
                set_cache_limit(service, bytes)
                relieve(service)
                response^ = .Done
            }
            case Evictions => response^ = .Collected(service.evicted)
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

/**
 * Give a copy of a small object, for Read: its bytes, kept from an earlier Read or read from its file through the
 * store's directory, written to new memory, charged to the store's budget until its owning handle moves to the client.
 * Nothing stays open.
 *
 * @param service The store's state, whose directory and budget are used; its open objects aren't touched. An object
 *     read from its file, up to MAX_KEPT_OBJECT bytes, is added to its kept.
 * @param hash The object's hash, naming the file objects/<hex>, which isn't checked against its bytes, as Get doesn't.
 * @return The copy: its memory, whole pages with zeros past the object, its owning handle the caller's to give away,
 *     and the object's size in bytes. Null if there's no such object, it's empty or past bundle_store.MAX_READ bytes,
 *     or there wasn't the memory for it.
 */
read_copy :: fn(service : ptr[mut Store], hash : bundle.Hash) -> bundle_store.Object? {
    for each in service.kept {
        if bundle.same(each.hash, hash) {
            return copy_of(service, each.bytes)
        }
    }
    hex_storage : u8[64]
    path_storage : u8[80]
    read :: match os.read_entire_file_in(
        service.directory,
        path_in("objects/", bundle.hex(hash, &hex_storage), &path_storage)
    ) {
        case Ok(contents) => contents
        case Error(error) => return null
    }
    bytes :: bit_cast[u8[]](read)
    size :: cast[u64](bytes.count)
    if size == 0 || size > bundle_store.MAX_READ {
        runtime.free_array(bytes)
        return null
    }
    copy :: copy_of(service, bytes)
    if size > MAX_KEPT_OBJECT {
        runtime.free_array(bytes)
        return copy
    }
    if service.kept_bytes + size > MAX_KEPT_BYTES {
        forget_kept(service)
    }
    runtime.array_add(&service.kept, Kept.{hash = hash, bytes = bytes})
    service.kept_bytes += size
    return copy
}

/**
 * Write an object's bytes to new memory, for Read.
 *
 * @param service The store's state, whose budget pays for the memory.
 * @param bytes The object's bytes, 1 to bundle_store.MAX_READ of them; only read.
 * @return The memory, whole pages with zeros past the bytes, its owning handle the caller's, and the bytes' count; null
 *     if there wasn't the memory for it.
 */
copy_of :: fn(service : ptr[mut Store], bytes : u8[]) -> bundle_store.Object? {
    size :: cast[u64](bytes.count)
    memory :: slop_os.memory_create(service.block.budget, (size + PAGE - 1) & ~(PAGE - 1)) or_return null
    if slop_os.memory_write(memory, 0, bytes) is_error {
        _ = slop_os.handle_close(cast[slop_os.Handle](memory))
        return null
    }
    return bundle_store.Object.{memory = memory, size = size}
}

/** Forget the objects Read keeps: their bytes freed, so the next Read of each reads its file. */
forget_kept :: fn(service : ptr[mut Store]) {
    for each in service.kept {
        runtime.free_array(each.bytes)
    }
    runtime.array_free(&service.kept)
    service.kept_bytes = 0
}

/**
 * Give an object as paged memory, read-only, which this store supplies: the same memory each time it's asked for,
 * once it's open.
 *
 * The first time, the object's file is opened read-only through the store's directory, for its size, and its memory
 * made, paged by the store; no page is read until it's wanted. It stays open until it's closed to make room for
 * another (unheld_slot); its file stays open only while it's among the MAX_FILES read from last (file_for).
 *
 * @param service The store's state: a used slot of its objects that holds hash is handed out again; otherwise the
 *     object's set up in the first free slot, or one closed to make room.
 * @param hash The object's BLAKE3-256 hash, any: it names the file objects/<hex>, and isn't checked against the file's
 *     bytes, which Put checked before it kept them. A hash with no such file gives null.
 * @return The object: a new handle to its memory, to read and execute, which the caller owns and passes on, and its
 *     size in bytes. Null if there's no such object, its file couldn't be opened or set up, MAX_OBJECTS are open
 *     already and every one is held (unheld_slot), or the handle couldn't be duplicated.
 */
get :: fn(service : ptr[mut Store], hash : bundle.Hash) -> bundle_store.Object? {
    slot := NOWHERE
    for open, i in service.objects {
        if i >= service.limit {
            break
        }
        if open.used && bundle.same(open.hash, hash) {
            return hand_out(service, i)
        }
        if !open.used && slot == NOWHERE {
            slot = i
        }
    }
    if slot >= service.limit {
        slot = unheld_slot(service) or_return null
    }
    if slot >= service.objects.count {
        return null
    }
    service.objects[slot] = Open.{used = true, hash = hash}
    if !set_up(service, slot) {
        close_file_of(service, slot)
        service.objects[slot] = Open.{}
        return null
    }
    return hand_out(service, slot)
}

/**
 * Set up an object being opened: ask its file for its size, and make its paged memory, its wanted pages waking the port
 * under PAGER_KEY plus slot.
 *
 * @param service The store's state: its file is opened in files (file_for), its budget pays for the paged memory, and
 *     its port gets the pager's binding.
 * @param slot The object's slot, used, with its hash; its size and memory are set. When it fails, nothing's bound, no
 *     memory's made, and the caller closes the file (close_file_of).
 * @return Whether all of it was made; false if the file couldn't be opened, didn't answer Info, or the memory or the
 *     binding couldn't be had.
 */
set_up :: fn(service : ptr[mut Store], slot : usize) -> bool {
    index :: file_for(service, slot) or_return false
    if slot >= service.objects.count || index >= service.files.count {
        return false
    }
    asking := os.Outgoing.{}
    info_request :: os.begin[read_only_file.Request](&asking)
    info_request^ = .Info
    into := os.Incoming.{}
    open :: &service.objects[slot]
    match ask_file(&service.files[index], &asking, &into) {
        case Described(info) => open.size = info.size
        case _ => return false
    }
    block :: service.block
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

/**
 * Give out a new handle to an open object's memory, marking when.
 *
 * @param service The store's state: the slot's memory is duplicated, and its given_at set from the store's given. The
 *     slot isn't checked to be used; callers give one that is.
 * @param slot The object's slot, taken modulo MAX_OBJECTS.
 * @return The object: a handle to its memory with the rights to read, execute, duplicate and transfer it, which the
 *     caller owns, and its size in bytes; null if the handle couldn't be duplicated.
 */
hand_out :: fn(service : ptr[mut Store], slot : usize) -> bundle_store.Object? {
    open :: &service.objects[slot % MAX_OBJECTS]
    rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_READ)
        | cast[u32](slop_os.RIGHT_MEMORY_EXECUTE)
        | cast[u32](slop_os.RIGHT_DUPLICATE)
        | cast[u32](slop_os.RIGHT_TRANSFER))
    copy :: slop_os.handle_duplicate(cast[slop_os.Handle](open.memory), rights) or_return null
    service.given += 1
    open.given_at = service.given
    return bundle_store.Object.{memory = cast[slop_os.Memory](copy), size = open.size}
}

/**
 * Find a slot to open another object in, when every one is used: the object given out longest ago that no one holds
 * now (decisions/0178), closed to make room.
 *
 * Who holds each is asked just now (memory_holders), not taken from a signal that could be older than a Get since.
 * Only the store gives its objects out, on this one thread, so none becomes held between the asking and the closing.
 *
 * @param service The store's state, whose open objects are asked about; the one closed is taken out (close_slot).
 * @return The slot, empty now; null if every open object is held, or none could be asked about.
 */
unheld_slot :: fn(service : ptr[mut Store]) -> usize? {
    chosen := NOWHERE
    oldest := ~cast[u64](0)
    for open, i in service.objects {
        if !open.used || open.given_at >= oldest {
            continue
        }
        holders :: slop_os.memory_holders(open.memory) or_else 1
        if holders == 0 {
            chosen = i
            oldest = open.given_at
        }
    }
    if chosen >= MAX_OBJECTS {
        return null
    }
    close_slot(service, chosen)
    return chosen
}

/**
 * Close an open object no one holds, to make room: its paged memory destroyed, its pager's binding and its file, if
 * it's open, let go of, and its pages forgotten, both those supplied and those waiting to be read.
 *
 * @param service The store's state: the slot's no longer used, and its pages are taken off resident and unread, so
 *     the next object in the slot isn't given them.
 * @param slot The slot, used; one past MAX_OBJECTS, or not used, is left alone.
 */
close_slot :: fn(service : ptr[mut Store], slot : usize) {
    if slot >= MAX_OBJECTS || !service.objects[slot].used {
        return void
    }
    open :: &service.objects[slot]
    _ = slop_os.handle_close(cast[slop_os.Handle](open.memory))
    _ = slop_os.port_unbind(service.port, PAGER_KEY + cast[u64](slot))
    close_file_of(service, slot)
    open^ = Open.{}
    service.closed += 1
    for list in u8.[0, 1] {
        pages :: if list == 0 { &service.resident } else { &service.unread }
        i := cast[usize](0)
        loop {
            current :: pages^
            if i >= current.count {
                break
            }
            if current[i].slot == slot {
                runtime.array_remove(pages, i)
            }
            else {
                i += 1
            }
        }
    }
    if service.hand > service.resident.count {
        service.hand = 0
    }
    runtime.log_info("closed an object no one held, to make room: % closed so far", service.closed)
}

/**
 * Close a file of files, if it's open: its connection and port. Its page is kept, for the next file opened in its
 * place.
 *
 * @param entry The file; it isn't used afterwards. One that isn't used is left alone.
 */
close_file :: fn(entry : ptr[mut FileOpen]) {
    if !entry.used {
        return void
    }
    for each in slop_os.Handle.[cast[slop_os.Handle](entry.file), cast[slop_os.Handle](entry.file_port)] {
        if each != slop_os.NO_HANDLE {
            _ = slop_os.handle_close(each)
        }
    }
    entry.used = false
    entry.file = cast[slop_os.Channel](slop_os.NO_HANDLE)
    entry.file_port = cast[slop_os.Port](slop_os.NO_HANDLE)
}

/**
 * Close an object's file, if it's open in files.
 *
 * @param service The store's state, whose files are searched.
 * @param slot The object's slot in service.objects; one with no file open closes nothing.
 */
close_file_of :: fn(service : ptr[mut Store], slot : usize) {
    for i in cast[usize](0)..<MAX_FILES {
        if service.files[i].used && service.files[i].slot == slot {
            close_file(&service.files[i])
        }
    }
}

/**
 * Find an open object's file open in files, opening it through the store's directory if it isn't: in a free entry,
 * or in place of the one read from longest ago, which is closed (MAX_FILES). Either way, it's marked read now.
 *
 * @param service The store's state: its reads counts the asking, and the entry's read_at is set from it; a file is
 *     opened through raw, its budget paying for the port, and its entry's page made the first time.
 * @param slot The object's slot, used, whose hash names its file objects/<hex>.
 * @return The entry's index in service.files, its file open and given its page to read into; null if the directory
 *     didn't open it, as while it's gone or when there's no such object, or a port, the page or its handle couldn't be
 *     had, the entry left closed.
 */
file_for :: fn(service : ptr[mut Store], slot : usize) -> usize? {
    if slot >= service.objects.count {
        return null
    }
    service.reads += 1
    chosen := NOWHERE
    oldest := ~cast[u64](0)
    for i in cast[usize](0)..<service.files.count {
        if i >= service.file_limit {
            break
        }
        entry :: &service.files[i]
        if entry.used && entry.slot == slot {
            entry.read_at = service.reads
            return i
        }
        // A free entry's taken before any open one
        at :: if entry.used { entry.read_at } else { cast[u64](0) }
        if chosen == NOWHERE || at < oldest {
            chosen = i
            oldest = at
        }
    }
    if chosen >= service.files.count {
        return null
    }
    entry :: &service.files[chosen]
    close_file(entry)
    if entry.buffer_at == 0 && !make_page(service, entry) {
        return null
    }
    hex_storage : u8[64]
    path_storage : u8[80]
    path :: path_in("objects/", bundle.hex(service.objects[slot].hash, &hex_storage), &path_storage)
    out := os.Outgoing.{}
    request :: os.begin[dir.Request](&out)
    request^ = .OpenReadOnlyFile(os.append(&out, string_bytes(path)))
    into := os.Incoming.{}
    match ask_dir(service, &out, &into) {
        case OpenedReadOnlyFile(connection) => entry.file = connection.end
        case _ => return null
    }
    entry.used = true
    entry.slot = slot
    entry.read_at = service.reads
    entry.file_port = os.port_for(service.block.budget, entry.file) or_else cast[slop_os.Port](slop_os.NO_HANDLE)
    rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_READ)
        | cast[u32](slop_os.RIGHT_MEMORY_WRITE)
        | cast[u32](slop_os.RIGHT_TRANSFER))
    given :: slop_os.handle_duplicate(cast[slop_os.Handle](entry.buffer), rights) or_else slop_os.NO_HANDLE
    if cast[slop_os.Handle](entry.file_port) == slop_os.NO_HANDLE || given == slop_os.NO_HANDLE {
        if given != slop_os.NO_HANDLE {
            _ = slop_os.handle_close(given)
        }
        close_file(entry)
        return null
    }
    buffering := os.Outgoing.{}
    buffer_request :: os.begin[read_only_file.Request](&buffering)
    buffer_request^ = .UseBuffer(cast[slop_os.Memory](given))
    match ask_file(entry, &buffering, &into) {
        case Done => {}
        case _ => {
            close_file(entry)
            return null
        }
    }
    return chosen
}

/**
 * Make a file's page, which the file server reads into and pages are supplied from, and map it.
 *
 * @param service The store's state, only read: its budget pays for the page, and its address space maps it.
 * @param entry The file whose buffer and buffer_at are set; buffer_at stays 0 if it fails, with nothing kept.
 * @return Whether the page was made and mapped; false if the memory or the addresses couldn't be had.
 */
make_page :: fn(service : ptr[Store], entry : ptr[mut FileOpen]) -> bool {
    block :: service.block
    buffer :: slop_os.memory_create(block.budget, PAGE) or_return false
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    at :: runtime.reserve_addresses(cast[usize](PAGE)) or_else 0
    if at == 0 || (slop_os.memory_map(buffer, block.space, at, 0, PAGE, read_write) is_error) {
        _ = slop_os.handle_close(cast[slop_os.Handle](buffer))
        return false
    }
    entry.buffer = buffer
    entry.buffer_at = at
    return true
}

/**
 * Use another connection to the store's directory from now on: the same directory served again, as when the system
 * volume's server was started again.
 *
 * The connections before are closed. Open objects' files are opened again as their pages are next wanted, and the
 * pages wanted meanwhile, kept in unread, are read and supplied now; those that still can't be read are kept for the
 * next time, as all are when there isn't the memory to go through them.
 *
 * @param service The store's state: once end is used, its raw, raw_port and directory are closed and replaced, and its
 *     unread pages are read and supplied, or kept in unread again.
 * @param end The directory's end, which the store takes over when it's used.
 * @return Whether it's used; false if a port for it or a second connection to it couldn't be made, the connections
 *     before kept.
 */
use_directory :: fn(service : ptr[mut Store], end : slop_os.Channel) -> bool {
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
    service.root = null
    // Its files were on the server before, and are opened through the new directory as they're next read
    for i in cast[usize](0)..<MAX_FILES {
        close_file(&service.files[i])
    }
    runtime.log_info("using its directory again")
    // The pages that couldn't be read meanwhile, read now
    waiting : Unread[..]
    defer runtime.array_free(&waiting)
    // Without the memory to sort them, they wait for the next time it's given its directory
    if runtime.array_try_reserve(&waiting, service.unread.count) != null {
        return true
    }
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

/**
 * Read and supply each page of an open object that's wanted, as its pager's binding wakes the port.
 *
 * A page that can't be read, as while the directory's gone, is kept in unread for use_directory; if it can't be kept,
 * it's asked for again by the next fault on it.
 *
 * @param service The store's state: the slot's wanted pages are read and supplied, those supplied added to resident and
 *     those that can't be read to unread.
 * @param slot The object's slot; one past them, or one not open, is left alone.
 */
supply_wanted :: fn(service : ptr[mut Store], slot : usize) {
    if slot >= MAX_OBJECTS || !service.objects[slot].used {
        return void
    }
    loop {
        offset :: slop_os.memory_page_wanted(service.objects[slot].memory) or_break
        // Nothing to read it from until the store's given its directory again: kept for then, never supplied wrong
        if !supply_page(service, slot, offset)
            && runtime.array_try_add(&service.unread, Unread.{slot = slot, offset = offset}) != null {
            // Kept nowhere, it's asked for again by the next fault on it
            runtime.log_warn("a wanted page can't be kept until the directory's back")
            break
        }
    }
}

/**
 * Read a page of an open object from its file and supply it, its file opened if it isn't (file_for), and opened again
 * if its connection fails, as when it went with the server it was on.
 *
 * Past the object's end, the page is zeros. If the budget refuses the supply, a page is given back first and it's
 * supplied again. A page supplied is added to resident, for the clock; one the kernel still refuses isn't supplied,
 * and is asked for again by the next fault on it.
 *
 * @param service The store's state: the slot's file may be opened, in place of another, the page is added to resident
 *     once supplied,
 *     and a page is evicted first when its budget refuses the supply.
 * @param slot The object's slot in service.objects; one past MAX_OBJECTS, or one not used, supplies nothing and gives
 *     true.
 * @param offset The page's offset in the object's memory, in bytes, a multiple of PAGE.
 * @return False, with nothing supplied, if it couldn't be read; true otherwise, and for a slot that isn't open,
 *     where there's nothing to supply.
 */
supply_page :: fn(service : ptr[mut Store], slot : usize, offset : u64) -> bool {
    if slot >= MAX_OBJECTS || !service.objects[slot].used {
        return true
    }
    open :: &service.objects[slot]
    reading := os.Outgoing.{}
    request :: os.begin[read_only_file.Request](&reading)
    request^ = .Read(files.Transfer.{offset = offset, count = cast[u32](PAGE), buffer_offset = 0})
    into := os.Incoming.{}
    read : u64 = 0
    // Read from its file, opened if it isn't; one open that fails, as when its server's gone, is opened again once
    entry := NOWHERE
    tries := 0
    loop {
        if tries == 2 {
            break
        }
        tries += 1
        index :: file_for(service, slot) or_break
        if index >= service.files.count {
            break
        }
        match ask_file(&service.files[index], &reading, &into) {
            case Transferred(count) => {
                read = cast[u64](count)
                entry = index
                break
            }
            case _ => close_file(&service.files[index])
        }
    }
    if entry >= service.files.count {
        return false
    }
    buffer :: service.files[entry].buffer
    buffer_at :: service.files[entry].buffer_at
    // Past the object's end, zeros
    for i in read..<PAGE {
        intrinsics.volatile_store_u8(cast[ptr[mut u8]](buffer_at + i), 0)
    }
    supplied := slop_os.memory_supply(open.memory, offset, buffer, 0)
    // Its budget full: pages given back first, then supplied again
    match supplied {
        case Error(error) => if error == .BudgetExceeded {
            evict(service, 1)
            supplied = slop_os.memory_supply(open.memory, offset, buffer, 0)
        }
        case Ok => {}
    }
    match supplied {
        case Ok => _ = runtime.array_try_add(&service.resident, Unread.{slot = slot, offset = offset})
        case Error(error) => {}
    }
    return true
}

/**
 * Set its budget's threshold, at which the kernel raises SIGNAL_PRESSURE, for a cache of pages of at most a limit.
 *
 * @param service The store's state, whose cache_limit and cache_base are set.
 * @param limit The most bytes of pages to keep, past what its budget has charged for everything else now; 0 for a
 *     threshold of three quarters of its budget's limit. Nothing's set if the budget's info can't be read.
 */
set_cache_limit :: fn(service : ptr[mut Store], limit : u64) {
    info :: slop_os.memory_budget_info(service.block.budget) or_return void
    pages :: cast[u64](service.resident.count) * PAGE
    service.cache_limit = limit
    service.cache_base = if info.used > pages { info.used - pages } else { 0 }
    threshold :: if limit == 0 { info.limit / 4 * 3 } else { service.cache_base + limit }
    _ = slop_os.memory_budget_set_threshold(service.block.budget, threshold)
}

/**
 * Forget what Read keeps, and give pages back until its budget's use is at its low water, LOW_WATER_SIXTEENTHS of the
 * way from what isn't pages to the threshold, as pressure on it asks; no pages if it's below already, or the budget's
 * info can't be read.
 *
 * @param service The store's state: its kept objects are forgotten; its budget's info, cache_limit and cache_base set
 *     the low water, and pages are evicted from resident, counted in evicted.
 */
relieve :: fn(service : ptr[mut Store]) {
    forget_kept(service)
    info :: slop_os.memory_budget_info(service.block.budget) or_return void
    threshold :: if service.cache_limit == 0 { info.limit / 4 * 3 } else { service.cache_base + service.cache_limit }
    base :: if service.cache_limit == 0 { cast[u64](0) } else { service.cache_base }
    low :: base + (threshold - base) / 16 * LOW_WATER_SIXTEENTHS
    if info.used <= low {
        return void
    }
    evict(service, (info.used - low + PAGE - 1) / PAGE)
}

/**
 * Give pages back by the clock: going round the pages supplied from the hand, one touched since the hand last passed
 * it is passed, its mark cleared, and one that wasn't is given back.
 *
 * Twice round at most, so a cache of only touched pages still gives some back. A page mapped by too many to give back
 * now is passed, as a touched one is; one that can't be given back for another reason, or whose object isn't open, is
 * taken off the pages supplied. A page given back is read again when it's next wanted.
 *
 * @param service The store's state, whose evicted counts the pages given back.
 * @param count The most pages to give back; fewer when there aren't that many it can.
 */
evict :: fn(service : ptr[mut Store], count : u64) {
    given := cast[u64](0)
    steps := cast[usize](0)
    limit :: service.resident.count * 2
    loop {
        if given >= count || service.resident.count == 0 || steps >= limit {
            break
        }
        steps += 1
        at :: if service.hand < service.resident.count { service.hand } else { cast[usize](0) }
        service.hand = at
        if at >= service.resident.count {
            break
        }
        page :: service.resident[at]
        if page.slot >= MAX_OBJECTS || !service.objects[page.slot].used {
            forget(service, at)
            continue
        }
        memory :: service.objects[page.slot].memory
        touched :: slop_os.memory_page_accessed(memory, page.offset) or_else false
        if touched && steps <= service.resident.count {
            service.hand = at + 1
            continue
        }
        match slop_os.memory_evict(memory, page.offset) {
            case Ok => {
                forget(service, at)
                given += 1
                service.evicted += 1
            }
            // Mapped by too many to give back now: passed, as a touched one is
            case Error(error) => if error == .MappedWidely {
                service.hand = at + 1
            }
            else {
                forget(service, at)
            }
        }
    }
}

/**
 * Take a page off the pages supplied, the hand staying on the one after it.
 *
 * @param service The store's state, whose resident loses the page; hand isn't moved, so it's left on the page after.
 * @param index The page's index in resident; one past them is ignored.
 */
forget :: fn(service : ptr[mut Store], index : usize) {
    if index < service.resident.count {
        runtime.array_remove(&service.resident, index)
    }
}

/** How many bytes of a Put's memory are read at a time, hashed and written: 64 KiB. */
PUT_CHUNK : u64 : 64 * 1024

/**
 * Keep an object put, if its bytes have its hash.
 *
 * Its bytes are read from put's memory PUT_CHUNK at a time, through memory_read, never mapped, so the client ending
 * meanwhile only fails the put (decisions/0098, 0181's F6); each chunk is hashed and written to objects/<hex>.part,
 * which is renamed to objects/<hex> once whole and its hash checked, so a crash leaves no object file that's partly
 * written, only a .part file, which Collect removes. A .part file whose bytes don't have the hash is deleted.
 *
 * @param service The store's state: the object's file is written in its directory, and its heap holds a chunk while
 *     it's read.
 * @param put The object: its hash, and the memory holding its bytes, the first size bytes of it, which is closed
 *     here whatever happens.
 * @return Whether it's kept, or was already; false if size is past the memory's, the bytes don't have the hash, the
 *     memory couldn't be read (its owner gone) or a chunk's room had, or the file couldn't be written or renamed.
 */
store_object :: fn(service : ptr[mut Store], put : bundle_store.PutOf) -> bool {
    defer slop_os.handle_close(cast[slop_os.Handle](put.data))
    available :: slop_os.memory_size(put.data) or_return false
    if put.size > available {
        return false
    }
    if has_object(service, put.hash) {
        return true
    }
    hex_storage : u8[64]
    hex :: bundle.hex(put.hash, &hex_storage)
    part_storage : u8[80]
    final_storage : u8[80]
    part :: joined("objects/", hex, ".part", &part_storage)
    final :: joined("objects/", hex, "", &final_storage)
    chunk, made :: runtime.new_array(u8, cast[usize](PUT_CHUNK))
    if made != null {
        return false
    }
    defer runtime.free_array(chunk)
    file :: os.open_in(service.directory, part, .WRITE) or_return false
    hasher := crypto.blake3_start()
    whole := true
    done := cast[u64](0)
    loop {
        if done >= put.size {
            break
        }
        now :: if put.size - done < PUT_CHUNK { put.size - done } else { PUT_CHUNK }
        length :: cast[usize](now)
        if length > chunk.count {
            whole = false
            break
        }
        piece :: chunk[0..<length]
        if (slop_os.memory_read(put.data, done, piece) is_error) || os.write(file, as_text(piece)) != null {
            whole = false
            break
        }
        crypto.blake3_update(&hasher, piece)
        done += now
    }
    os.close(file)
    got := bundle.Hash.{}
    crypto.blake3_finish(&hasher, got.bytes)
    if !whole || !bundle.same(got, put.hash) {
        _ = os.delete_file_in(service.directory, part)
        return false
    }
    return os.rename_in(service.directory, part, final) == null
}

/**
 * Tell whether an object is kept.
 *
 * @param service The store's state, only read: the file is looked for through its directory.
 * @param hash The hash looked for, as the file objects/<hex>; the file's bytes aren't read or checked against it.
 * @return Whether objects/<hex> is a file.
 */
has_object :: fn(service : ptr[Store], hash : bundle.Hash) -> bool {
    hex_storage : u8[64]
    path_storage : u8[80]
    return os.path_kind_in(service.directory, path_in("objects/", bundle.hex(hash, &hex_storage), &path_storage))
        == .FILE
}

/**
 * Write a hash in hex to a file, a pin or the boot root, through a .part file renamed over it, so the file has the
 * hash before or the one after, whole.
 *
 * @param service The store's state, whose directory the file is written in.
 * @param folder The folder the file is in, without a "/": "pins", or "" for the store's directory itself.
 * @param name The file's name, checked already.
 * @param hash The hash written into the file, as its 64 hex characters and nothing more; it needn't be an object's
 *     that's kept.
 * @return Whether it's written and renamed.
 */
write_hash :: fn(service : ptr[mut Store], folder : string, name : string, hash : bundle.Hash) -> bool {
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

/**
 * Read a hash in hex from a file: a pin or the boot root.
 *
 * @param service The store's state, only read: path is read through its directory.
 * @param path The file's path in the store's directory.
 * @return The hash; null if the file isn't there, can't be read, or doesn't hold a hash in hex.
 */
read_hash :: fn(service : ptr[Store], path : string) -> bundle.Hash? {
    text :: os.read_entire_file_in(service.directory, path) or_return null
    defer runtime.free_array(bit_cast[u8[]](text))
    return bundle.from_hex(text)
}

/**
 * Read a hash a collection marks from, a pin or the boot root, telling a file that isn't there from one that can't be
 * read or doesn't hold a hash.
 *
 * @param service The store's state, only read: path is read through its directory.
 * @param path The file's path in the store's directory.
 * @return The hash; Ok(null) if there's no such file; an error if it couldn't be read, or Unsupported if it doesn't
 *     hold a hash in hex, which a collection can't mark from, and so has to stop for.
 */
marked_from :: fn(service : ptr[Store], path : string) -> Result[bundle.Hash?, os.OsError] {
    text :: match os.read_entire_file_in(service.directory, path) {
        case Ok(read) => read
        case Error(error) => {
            if error == .NotFound {
                return .Ok(null)
            }
            return .Error(error)
        }
    }
    defer runtime.free_array(bit_cast[u8[]](text))
    match bundle.from_hex(text) {
        case Some(hash) => return .Ok(hash)
        case None => return .Error(.Unsupported)
    }
}

/**
 * Remove every object no root reaches, but those open: marked from the boot root and every pin, through what each
 * refers to.
 *
 * Anything not marked is removed, so a root or a pin that can't be read, or read through, or a pins directory that
 * can't be listed, stops the collection before anything's removed; so does a pin or root file that doesn't hold a hash,
 * since what it was meant to keep isn't known.
 * Every file in objects/ whose name isn't a marked or open object's hash is removed, .part files left by a crash
 * among them.
 *
 * @param service The store's state: the boot root, pins/ and objects are read, and objects/ files removed, through its
 *     directory; its objects' used slots are kept, and what Read keeps is forgotten, so a removed object isn't read.
 * @return How many files were removed from objects/; 0 when the collection stopped.
 */
collect :: fn(service : ptr[mut Store]) -> u64 {
    forget_kept(service)
    marked : bundle.Hash[..]
    defer runtime.array_free(&marked)
    // Anything not marked through is collected, so a root or a pin that can't be read through stops the collection
    match marked_from(service, "root") {
        case Ok(found) => {
            match found {
                case Some(root) => {
                    if !mark(service, root, &marked, 0) {
                        return 0
                    }
                }
                case None => {}
            }
        }
        case Error(error) => return 0
    }
    match os.list_directory_in(service.directory, "pins") {
        case Ok(pins) => {
            whole := true
            for pin in pins {
                if ends_with(pin.name, ".part") {
                    continue
                }
                path_storage : u8[80]
                // A pin gone since the listing keeps nothing; one that can't be read might, so nothing's collected
                match marked_from(service, path_in("pins/", pin.name, &path_storage)) {
                    case Ok(found) => {
                        match found {
                            case Some(hash) => whole = whole && mark(service, hash, &marked, 0)
                            case None => {}
                        }
                    }
                    case Error(error) => whole = false
                }
            }
            os.free_directory_listing(pins)
            if !whole {
                return 0
            }
        }
        case Error(error) => {
            if error != .NotFound {
                return 0
            }
        }
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

/**
 * Mark a hash, and what it refers to, if it's a root or a bundle; no deeper than a root's bundles' objects.
 *
 * A hash with no object behind it is marked, and nothing more.
 *
 * @param service The store's state, only read: objects are read from objects/ through its directory.
 * @param hash The hash to mark, added to marked unless it's there already; its object, if kept, is read for what it
 *     refers to. The object's bytes aren't checked against it.
 * @param marked The hashes marked so far, which grows, from the context's allocator.
 * @param depth How deep hash is: 0 for a root or a pin, 1 for a root's entry; past 2 nothing's marked.
 * @return False if it couldn't be read through, for want of memory or a failed read: then what it refers to isn't
 *     known, and nothing may be collected (decisions/0104). True otherwise.
 */
mark :: fn(service : ptr[Store], hash : bundle.Hash, marked : ptr[mut bundle.Hash[..]], depth : int) -> bool {
    if is_marked(marked, hash) || depth > 2 {
        return true
    }
    if runtime.array_try_add(marked, hash) != null {
        return false
    }
    hex_storage : u8[64]
    path_storage : u8[80]
    record :: match os.read_entire_file_in(
        service.directory,
        path_in("objects/", bundle.hex(hash, &hex_storage), &path_storage)
    ) {
        case Ok(read) => read
        case Error(error) => return error == .NotFound
    }
    defer runtime.free_array(bit_cast[u8[]](record))
    bytes :: bit_cast[u8[]](record)
    referred : bundle.Hash[..]
    defer runtime.array_free(&referred)
    names : string[..]
    defer runtime.array_free(&names)
    match bundle.bundle_refers(bytes, &referred) {
        case Ok(is_bundle) => {
            if is_bundle {
                for each in referred {
                    if !is_marked(marked, each) && runtime.array_try_add(marked, each) != null {
                        return false
                    }
                }
                return true
            }
        }
        case Error(error) => return false
    }
    runtime.array_reset(&referred)
    is_root :: match bundle.root_entries(bytes, &names, &referred) {
        case Ok(found) => found
        case Error(error) => return false
    }
    if is_root {
        for each in referred {
            if !mark(service, each, marked, depth + 1) {
                return false
            }
        }
    }
    return true
}

/**
 * Tell whether a hash is marked.
 *
 * @param marked The hashes marked so far by a collection, read and not changed; empty marks nothing.
 * @param hash The hash looked for, compared whole.
 * @return Whether it's among them.
 */
is_marked :: fn(marked : ptr[bundle.Hash[..]], hash : bundle.Hash) -> bool {
    for each in marked^ {
        if bundle.same(each, hash) {
            return true
        }
    }
    return false
}

/**
 * Tell whether an object is open, given out by Get, and so kept by Collect.
 *
 * @param service The store's state, only read: its objects' used slots are searched.
 * @param hash The hash looked for, compared whole with each used slot's.
 * @return Whether a used slot holds it.
 */
is_open :: fn(service : ptr[Store], hash : bundle.Hash) -> bool {
    for open in service.objects {
        if open.used && bundle.same(open.hash, hash) {
            return true
        }
    }
    return false
}

/**
 * Tell whether a name may be a pin's, and so a file's in pins/.
 *
 * @param name The name to check, from a client's request, as given; it's only read.
 * @return Whether it's 1 to 32 bytes, each a lowercase ASCII letter, a digit or an underscore.
 */
valid_name :: fn(name : string) -> bool {
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

/**
 * Send a request on the store's own connection to its directory, and wait for the answer.
 *
 * @param service The store's state, only read: the request goes on raw, and the answer is waited for on raw_port, until
 *     it comes or the connection fails.
 * @param out The request; its handles are moved out when it's sent.
 * @param into Where the answer is read into.
 * @return The answer, a view into into; Unsupported if it couldn't be sent or the connection failed, as when the
 *     volume's server has gone.
 */
ask_dir :: fn(service : ptr[Store], out : ptr[mut os.Outgoing], into : ptr[mut os.Incoming]) -> dir.Response {
    if dir.send_request(service.raw, service.raw_port, out) is_some {
        return .Unsupported
    }
    loop {
        match dir.receive_response(service.raw, service.raw_port, into, true) {
            case Received => break
            case Failed(error) => return .Unsupported
            case _ => return .Unsupported
        }
    }
    return os.message_of[dir.Response](into)^
}

/**
 * Send a request on an object's file's connection, and wait for the answer.
 *
 * @param entry The open file whose connection and port the request goes on; neither is changed, nor closed if it's
 *     failed.
 * @param out The request; its handles are moved out when it's sent.
 * @param into Where the answer is read into.
 * @return The answer, a view into into; Unsupported if it couldn't be sent or the connection failed, as when the
 *     server it was on has gone.
 */
ask_file :: fn(
    entry : ptr[FileOpen],
    out : ptr[mut os.Outgoing],
    into : ptr[mut os.Incoming]
) -> read_only_file.Response {
    if read_only_file.send_request(entry.file, entry.file_port, out) is_some {
        return .Unsupported
    }
    loop {
        match read_only_file.receive_response(entry.file, entry.file_port, into, true) {
            case Received => break
            case Failed(error) => return .Unsupported
            case _ => return .Unsupported
        }
    }
    return os.message_of[read_only_file.Response](into)^
}

/**
 * Make a path of a prefix and a name; what doesn't fit is cut off.
 *
 * @param prefix What goes first, as "pins/".
 * @param name What follows it.
 * @param storage Where it's made.
 * @return A view of storage's bytes, good while storage is unchanged; "" for nothing.
 */
path_in :: fn(prefix : string, name : string, storage : ptr[mut u8[80]]) -> string {
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

/**
 * Join three pieces of text; what doesn't fit is cut off.
 *
 * @param a What goes first.
 * @param b What goes second.
 * @param c What goes last, "" for nothing.
 * @param storage Where they're joined.
 * @return A view of storage's bytes, good while storage is unchanged; "" for nothing.
 */
joined :: fn(a : string, b : string, c : string, storage : ptr[mut u8[80]]) -> string {
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

/**
 * Tell whether text ends with something.
 *
 * @param text The text looked in; it's only read.
 * @param end What it may end with.
 * @return Whether its last bytes are end's; true for an empty end.
 */
ends_with :: fn(text : string, end : string) -> bool {
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

/**
 * Give bytes as text, without checking they're UTF-8.
 *
 * @param bytes The bytes, kept by the caller; the view points into them, so they must outlive it.
 * @return A view of them, good while they are; "" for none.
 */
as_text :: fn(bytes : u8[]) -> string {
    return if bytes.count > 0 { string_of(&bytes[0], bytes.count) } else { "" }
}
