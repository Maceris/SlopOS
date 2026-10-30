/*
 * The events service (roadmap 9a, decisions/0093, design/observability.md §2): the log records of every program the
 * supervisor starts. Whoever starts a program asks for a ring for it (the events protocol's Open), named for its
 * source, and gives it to the program as its grants "events" (std's os.LaunchEvents); base's logger writes the
 * program's records there (base's runtime.SlopOsEventsRing), with each format string's text and each type's schema
 * the first time the program uses it, and rings the ring's doorbell when the service waits for it. A program can't
 * write to another's source: the service labels what's in a ring with the name its ring was opened for.
 *
 * Each record is shown on the debug log as it's read, rendered (std's schema.render) after its source's name, so
 * serial shows what it did before. Records are kept in memory, as they'd be stored, until Store gives a directory;
 * from then on each source's are in its file there, "<source>.events", and what memory had is written first. A file
 * past FILE_BYTES is moved to "<source>.old", replacing the one there, and a new one started. What's stored is entries
 * as they are in the ring, each batch after a StoredInstance saying which of the source's rings it's from, and each
 * boot's after a StoredStart; a new file starts with every format string and schema its records could need.
 *
 * A query gives a source's records from this boot one at a time, rendered: from its .old file, its file, then what's
 * in memory. One that waits is answered when the source has a record for it.
 */
package events_service

import intrinsics from "base"
import runtime from "base"
import os from "std"
import random from "std"
import schema from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import log_line from "../../log_line"
import service_kit from "../../service_kit"
import events from "../../protocols/events"

MAX_SOURCES :: 32
MAX_RINGS :: 48
MAX_WAITING :: 8
NAME_BYTES :: 32
// The keys rings' doorbells are bound to the port with, after the clients'
DOORBELL_KEY : u64 : 1000
RING_BYTES : u64 : runtime.SLOP_OS_EVENTS_RING_BYTES
// The most memory keeps of a source's records before there's a directory to store them in; records past it are dropped
PENDING_BYTES :: 32768
// The most a source's file holds before it's moved to its .old file
FILE_BYTES : u64 : 256 * 1024
// The most of a record's text a query gives
TEXT_LIMIT :: 1024
NOWHERE : usize : 0xffffffffffffffff

// What's stored beside the ring's entries: where a boot's records start, numbering them, and which ring they're from
STORED_START : u16 : 16
STORED_INSTANCE : u16 : 17

StoredStart :: struct {
    entry : runtime.SlopOsEventsEntry,
    // This boot's, a random number
    boot : u64,
    // The number of the first record after it
    first : u64,
}

StoredInstance :: struct {
    entry : runtime.SlopOsEventsEntry,
    instance : u32,
    reserved : u32,
}

// A format string's text, of one of a source's rings, by its offset in that program's image: count bytes at `at`.
FormatText :: struct {
    instance : u32,
    offset : u64,
    at : usize,
    count : usize,
}

// A type's schema, by its hash: count bytes at `at` in the service's schema_bytes.
KnownSchema :: struct {
    hash : u8[32],
    at : usize,
    count : usize,
}

SchemaHash :: struct {
    hash : u8[32],
}

Source :: struct {
    name : u8[NAME_BYTES],
    name_count : usize,
    // Rings opened for it so far: each is an instance, from 1
    instances : u32,
    // Its records so far, which numbers the next, and those dropped
    count : u64,
    dropped : u64,
    // Its rings' format strings, their text in texts
    formats : FormatText[..],
    texts : u8[..],
    // The schemas its records have used, which a new file is given first
    used : SchemaHash[..],
    // What's to be stored and isn't yet, from a StoredStart
    pending : u8[..],
    // How much its file holds, and whether one's started this boot, or the next write starts one
    file_bytes : u64,
    filed : bool,
}

/*
 * A ring a program writes to; its source NOWHERE when it's free. Its launcher owns it, and the service reads and writes
 * it through the kernel (memory_read, memory_write) with a handle that doesn't own it, never mapping it: so the service
 * ending leaves its programs' rings to them, and a ring retired (Retire) is ObjectGone to it once its last records are
 * read (decisions/0098).
 */
Ring :: struct {
    source : usize,
    instance : u32,
    memory : slop_os.Memory,
    doorbell : slop_os.Channel,
}

// A query waiting for a record: its client NOWHERE when it's free.
Waiting :: struct {
    client : usize,
    name : u8[NAME_BYTES],
    name_count : usize,
    from : u64,
    level : u8,
}

Service :: struct {
    log : slop_os.DebugLog,
    block : ptr[slop_os.StartupBlock],
    port : slop_os.Port,
    boot : u64,
    sources : Source[MAX_SOURCES],
    source_count : usize,
    rings : Ring[MAX_RINGS],
    waiting : Waiting[MAX_WAITING],
    schemas : KnownSchema[..],
    schema_bytes : u8[..],
    // Where records are stored, once Store has given it
    store : os.Directory,
    storing : bool,
    connected : service_kit.Clients,
}

// A record found by a query: where its entry is in bytes, its number, and the format strings found before it.
Scan :: struct {
    boot_matches : bool,
    number : u64,
    instance : u32,
    formats : FormatText[..],
}

main :: fn(log: slop_os.DebugLog?, clients: os.Listener[events.Events]) -> int {
    service :: runtime.new(Service)
    service.log = log or_else cast[slop_os.DebugLog](slop_os.NO_HANDLE)
    service.block = slop_os.startup_block()
    service.boot = random.next_u64()
    for i in cast[usize](0)..<MAX_RINGS {
        service.rings[i].source = NOWHERE
    }
    for i in cast[usize](0)..<MAX_WAITING {
        service.waiting[i].client = NOWHERE
    }
    service.port = slop_os.port_create(service.block.budget) or_return 1
    if !service_kit.add_client(&service.connected, service.port, clients.end) {
        return 2
    }
    log_line.write(service.log, "events: serving")
    into := os.Incoming.{}
    loop {
        for i in cast[usize](0)..<service.connected.count {
            serve(service, i, &into)
        }
        for i in cast[usize](0)..<MAX_RINGS {
            drain(service, i)
        }
        answer_waiting(service)
        // Waiting from here: each ring's writer rings its doorbell once it's written, unless it already has
        written := false
        for i in cast[usize](0)..<MAX_RINGS {
            ring :: &service.rings[i]
            if ring.source != NOWHERE {
                waiting : u32 = 1
                _ = slop_os.memory_write(ring.memory, cast[u64](offset_of(runtime.SlopOsEventsRing, waiting)),
                    view_of(cast[ptr[u8]](cast[rawptr](&waiting)), size_of(u32)))
                match read_header(ring.memory) {
                    case Some(header) => written = written || header.written != header.read
                    case None => release(service, i)
                }
            }
        }
        if written {
            continue
        }
        packets : slop_os.Packet[8]
        taken :: slop_os.port_wait(service.port, packets, slop_os.NO_DEADLINE) or_else 0
        for packet, i in packets {
            if i >= cast[usize](taken) {
                break
            }
            if packet.key >= DOORBELL_KEY {
                ring_doorbell(service, cast[usize](packet.key - DOORBELL_KEY))
            }
        }
    }
}

// Every request client index has sent, until there are none left, or it's gone.
serve :: fn(service: ptr[mut Service], index: usize, into: ptr[mut os.Incoming]) {
    if index >= service.connected.ends.count {
        return void
    }
    end :: service.connected.ends[index]
    if cast[slop_os.Handle](end) == slop_os.NO_HANDLE {
        return void
    }
    loop {
        match events.receive_request(end, service.port, into, false) {
            case Received => {}
            case Empty => return void
            case Unsupported => {
                _ = events.answer_unsupported(end, service.port)
                continue
            }
            case Invalid => continue
            case WrongProtocol => continue
            case Failed(error) => {
                service_kit.drop_client(&service.connected, index)
                for i in cast[usize](0)..<MAX_WAITING {
                    if service.waiting[i].client == index {
                        service.waiting[i].client = NOWHERE
                    }
                }
                return void
            }
        }
        match os.message_of[events.Request](into)^ {
            case Open(name) => {
                out := os.Outgoing.{}
                response :: os.begin[events.Response](&out)
                match open(service, os.items(into, name)) {
                    case Some(source) => response^ = .Opened(source)
                    case None => response^ = .Refused
                }
                _ = events.send_response(end, service.port, &out)
            }
            case Store(directory) => {
                store(service, directory.end)
                out := os.Outgoing.{}
                response :: os.begin[events.Response](&out)
                response^ = .Done
                _ = events.send_response(end, service.port, &out)
            }
            case Query(query) => {
                name :: os.items(into, query.source)
                if !answer(service, end, name, query.from, query.level) {
                    if !query.wait || !hold(service, index, name, query.from, query.level) {
                        out := os.Outgoing.{}
                        response :: os.begin[events.Response](&out)
                        response^ = .End
                        _ = events.send_response(end, service.port, &out)
                    }
                }
            }
            case Connect(connection) => {
                if !service_kit.add_client(&service.connected, service.port, connection.end) {
                    _ = slop_os.handle_close(cast[slop_os.Handle](connection.end))
                }
            }
            case Retire(ring) => {
                // Whichever ring it is, every ring's records read first, so its last ones are kept
                for i in cast[usize](0)..<MAX_RINGS {
                    drain(service, i)
                }
                _ = slop_os.handle_close(cast[slop_os.Handle](ring))
                out := os.Outgoing.{}
                response :: os.begin[events.Response](&out)
                response^ = .Done
                _ = events.send_response(end, service.port, &out)
            }
        }
    }
}

/*
 * A ring for a program whose records are the source named name, made a source if it isn't one: what to give the
 * program, or null if there's no room, or the name isn't one (1 to NAME_BYTES letters, digits and underscores).
 */
open :: fn(service: ptr[mut Service], name: u8[]) -> events.Source? {
    if name.count == 0 || name.count > NAME_BYTES {
        return null
    }
    for byte in name {
        if !((byte >= cast[u8]('a') && byte <= cast[u8]('z')) || (byte >= cast[u8]('0') && byte <= cast[u8]('9')) || byte == cast[u8]('_')) {
            return null
        }
    }
    index := find_source(service, name)
    if index == NOWHERE {
        if service.source_count >= MAX_SOURCES {
            return null
        }
        index = service.source_count
        service.source_count += 1
        source :: &service.sources[index % MAX_SOURCES]
        for byte, i in name {
            source.name[i % NAME_BYTES] = byte
        }
        source.name_count = name.count
        start_pending(service, source, 0)
    }
    slot := NOWHERE
    for i in cast[usize](0)..<MAX_RINGS {
        if service.rings[i].source == NOWHERE {
            slot = i
            break
        }
    }
    if slot == NOWHERE {
        return null
    }
    block :: service.block
    // Made here, and its owning handle given away with the doorbell, to whoever launches the program, and on to it
    memory :: slop_os.memory_create(block.budget, RING_BYTES) or_return null
    header := runtime.SlopOsEventsRing.{magic = runtime.SLOP_OS_EVENTS_MAGIC, version = runtime.SLOP_OS_EVENTS_VERSION,
        size = RING_BYTES - cast[u64](size_of(runtime.SlopOsEventsRing))}
    if slop_os.memory_write(memory, 0, view_of(cast[ptr[u8]](cast[rawptr](&header)), size_of(runtime.SlopOsEventsRing))) is_error {
        _ = slop_os.handle_close(cast[slop_os.Handle](memory))
        return null
    }
    // The service's own: to read and write it, not to own it
    rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_READ) | cast[u32](slop_os.RIGHT_MEMORY_WRITE))
    kept := slop_os.NO_HANDLE
    match slop_os.handle_duplicate(cast[slop_os.Handle](memory), rights) {
        case Ok(copy) => kept = copy
        case Error(error) => {}
    }
    given :: cast[slop_os.Handle](memory)
    pair_made := false
    pair := slop_os.ChannelPair.{}
    match slop_os.channel_create(block.budget, 0, 0) {
        case Ok(made) => {
            pair = made
            pair_made = true
        }
        case Error(error) => {}
    }
    signals :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    if kept == slop_os.NO_HANDLE || !pair_made
        || (slop_os.port_bind(service.port, cast[slop_os.Handle](pair.a), signals, DOORBELL_KEY + cast[u64](slot), .Persistent) is_error) {
        if kept != slop_os.NO_HANDLE {
            _ = slop_os.handle_close(kept)
        }
        if pair_made {
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.a))
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
        }
        _ = slop_os.handle_close(cast[slop_os.Handle](memory))
        return null
    }
    source :: &service.sources[index % MAX_SOURCES]
    source.instances += 1
    service.rings[slot % MAX_RINGS] = Ring.{source = index, instance = source.instances, memory = cast[slop_os.Memory](kept), doorbell = pair.a}
    // A read that finds nothing, so the doorbell's next message wakes the port
    ring_doorbell(service, slot)
    return events.Source.{ring = cast[slop_os.Memory](given), doorbell = pair.b}
}

find_source :: fn(service: ptr[Service], name: u8[]) -> usize {
    for i in cast[usize](0)..<service.source_count {
        if i < MAX_SOURCES && same_name(&service.sources[i], name) {
            return i
        }
    }
    return NOWHERE
}

same_name :: fn(source: ptr[Source], name: u8[]) -> bool {
    if source.name_count != name.count {
        return false
    }
    for byte, i in name {
        if source.name[i % NAME_BYTES] != byte {
            return false
        }
    }
    return true
}

name_of :: fn(source: ptr[Source]) -> string {
    count :: if source.name_count < NAME_BYTES { source.name_count } else { NAME_BYTES }
    return string_of(&source.name[0], count)
}

// A source's pending entries begun again, as a file is, for records from first on.
start_pending :: fn(service: ptr[Service], source: ptr[mut Source], first: u64) {
    runtime.array_reset(&source.pending)
    file_header(service, source, first, &source.pending)
}

add_start :: fn(service: ptr[Service], into: ptr[mut u8[..]], first: u64) {
    start := StoredStart.{boot = service.boot, first = first}
    start.entry = runtime.SlopOsEventsEntry.{size = cast[u32](size_of(StoredStart)), kind = STORED_START}
    add_bytes(into, cast[rawptr](&start), size_of(StoredStart))
}

add_instance :: fn(into: ptr[mut u8[..]], instance: u32) {
    marker := StoredInstance.{instance = instance}
    marker.entry = runtime.SlopOsEventsEntry.{size = cast[u32](size_of(StoredInstance)), kind = STORED_INSTANCE}
    add_bytes(into, cast[rawptr](&marker), size_of(StoredInstance))
}

add_bytes :: fn(into: ptr[mut u8[..]], data: rawptr, count: usize) {
    for byte in view_of(cast[ptr[u8]](data), count) {
        runtime.array_add(into, byte)
    }
}

// A ring's header, read through the kernel; null once its program, which owns it, has ended.
read_header :: fn(memory: slop_os.Memory) -> runtime.SlopOsEventsRing? {
    header := runtime.SlopOsEventsRing.{}
    if slop_os.memory_read(memory, 0, view_of(cast[ptr[mut u8]](cast[rawptr](&header)), size_of(runtime.SlopOsEventsRing))) is_error {
        return null
    }
    return header
}

// What a ring's doorbell says: messages read until there are none, and the ring let go once its writer's gone.
ring_doorbell :: fn(service: ptr[mut Service], slot: usize) {
    if slot >= MAX_RINGS || service.rings[slot].source == NOWHERE {
        return void
    }
    buffer : u8[16]
    loop {
        size : u32 = 0
        match slop_os.channel_read(service.rings[slot].doorbell, buffer, &size) {
            case Ok(info) => continue
            case Error(error) => {
                if error == .PeerClosed || error == .ObjectGone {
                    drain(service, slot)
                    release(service, slot)
                }
                return void
            }
        }
    }
}

release :: fn(service: ptr[mut Service], slot: usize) {
    ring :: &service.rings[slot % MAX_RINGS]
    _ = slop_os.port_unbind(service.port, DOORBELL_KEY + cast[u64](slot))
    _ = slop_os.handle_close(cast[slop_os.Handle](ring.memory))
    _ = slop_os.handle_close(cast[slop_os.Handle](ring.doorbell))
    ring.source = NOWHERE
}

/*
 * What a ring's writer has published, read: each format string and schema learned, each record numbered and shown on
 * the debug log, and all of it kept, after a StoredInstance. A ring that doesn't hold entries is read no further.
 */
drain :: fn(service: ptr[mut Service], slot: usize) {
    if slot >= MAX_RINGS || service.rings[slot].source == NOWHERE {
        return void
    }
    ring :: service.rings[slot]
    source :: &service.sources[ring.source % MAX_SOURCES]
    header :: match read_header(ring.memory) {
        case Some(found) => found
        case None => {
            release(service, slot)
            return void
        }
    }
    size :: header.size
    read := header.read
    written :: header.written
    if read == written {
        return void
    }
    // Its entries, copied out whole: what's published, and nothing past it, as written is read first
    if size == 0 || size + cast[u64](size_of(runtime.SlopOsEventsRing)) > RING_BYTES {
        return void
    }
    copied : u8[..]
    defer runtime.array_free(&copied)
    runtime.array_reserve(&copied, cast[usize](size))
    for i in cast[u64](0)..<size {
        runtime.array_add(&copied, cast[u8](0))
    }
    if slop_os.memory_read(ring.memory, cast[u64](size_of(runtime.SlopOsEventsRing)), copied) is_error {
        release(service, slot)
        return void
    }
    data :: cast[u64](cast[uintptr](copied.data))
    fresh : u8[..]
    defer runtime.array_free(&fresh)
    add_instance(&fresh, ring.instance)
    first :: source.count
    if written - read > size || size + cast[u64](size_of(runtime.SlopOsEventsRing)) > RING_BYTES {
        read = written
    }
    loop {
        if read >= written {
            break
        }
        at :: read % size
        entry :: cast[ptr[runtime.SlopOsEventsEntry]](cast[rawptr](data + at))
        entry_size :: cast[u64](entry.size)
        if entry_size < 8 || (entry_size & 7) != 0 || entry_size > size - at {
            read = written
            break
        }
        bytes :: view_of(cast[ptr[u8]](cast[rawptr](data + at)), cast[usize](entry_size))
        kind :: entry.kind
        if kind == runtime.SLOP_OS_EVENTS_FORMAT && bytes.count >= size_of(runtime.SlopOsEventsFormat) {
            format :: cast[ptr[runtime.SlopOsEventsFormat]](cast[rawptr](entry))
            count :: cast[usize](format.count)
            if count <= bytes.count - size_of(runtime.SlopOsEventsFormat) {
                text_at :: source.texts.count
                add_bytes(&source.texts, cast[rawptr](data + at + cast[u64](size_of(runtime.SlopOsEventsFormat))), count)
                runtime.array_add(&source.formats, FormatText.{instance = ring.instance, offset = format.offset, at = text_at, count = count})
                add_bytes(&fresh, cast[rawptr](entry), bytes.count)
            }
        }
        else if kind == runtime.SLOP_OS_EVENTS_SCHEMA && bytes.count >= size_of(runtime.SlopOsEventsSchema) {
            given :: cast[ptr[runtime.SlopOsEventsSchema]](cast[rawptr](entry))
            count :: cast[usize](given.count)
            if count <= bytes.count - size_of(runtime.SlopOsEventsSchema) {
                learn_schema(service, given.hash, view_of(cast[ptr[u8]](cast[rawptr](data + at + cast[u64](size_of(runtime.SlopOsEventsSchema)))), count))
                note_used(source, given.hash)
                add_bytes(&fresh, cast[rawptr](entry), bytes.count)
            }
        }
        else if kind == runtime.SLOP_OS_EVENTS_RECORD && bytes.count >= size_of(runtime.SlopOsEventsRecord) {
            source.count += 1
            add_bytes(&fresh, cast[rawptr](entry), bytes.count)
        }
        else if kind == runtime.SLOP_OS_EVENTS_DROPPED && bytes.count >= size_of(runtime.SlopOsEventsDropped) {
            dropped :: cast[ptr[runtime.SlopOsEventsDropped]](cast[rawptr](entry)).count
            source.dropped += dropped
            log_line.write(service.log, "events: % dropped % records while its ring was full", name_of(source), dropped)
            add_bytes(&fresh, cast[rawptr](entry), bytes.count)
        }
        read += entry_size
    }
    _ = slop_os.memory_write(ring.memory, cast[u64](offset_of(runtime.SlopOsEventsRing, read)),
        view_of(cast[ptr[u8]](cast[rawptr](&read)), size_of(u64)))
    show(service, source, fresh)
    keep(service, source, fresh, first)
}

// Each record in entries shown on the debug log, after its source's name, and its level if it isn't info.
show :: fn(service: ptr[mut Service], source: ptr[Source], entries #escaping : u8[]) {
    instance : u32 = 0
    at : usize = 0
    text : u8[..]
    defer runtime.array_free(&text)
    loop {
        size :: entry_size_at(entries, at)
        if size == 0 {
            break
        }
        kind :: kind_at(entries, at)
        if kind == STORED_INSTANCE && size >= size_of(StoredInstance) {
            instance = cast[ptr[StoredInstance]](address_in(entries, at)).instance
        }
        else if kind == runtime.SLOP_OS_EVENTS_RECORD {
            runtime.array_reset(&text)
            level :: render(service, entries, at, &source.formats, source.texts, instance, &text)
            shown :: text_of(text)
            if level == cast[u8](runtime.LogLevel.INFO) {
                log_line.write(service.log, "%: %", name_of(source), shown)
            }
            else {
                log_line.write(service.log, "%: %: %", name_of(source), level_name(level), shown)
            }
        }
        at += size
    }
}

level_name :: fn(level: u8) -> string {
    return if level < 10 { "trace" } else if level < 20 { "debug" } else if level < 30 { "info" } else if level < 40 { "warn" }
        else if level < 50 { "error" } else { "fatal" }
}

/*
 * Entries of a source kept: in its file, if there's a directory to store them in, after what memory still has, or in
 * memory, while there's room; records that don't fit are dropped. first is the number of their first record.
 */
keep :: fn(service: ptr[mut Service], source: ptr[mut Source], entries: u8[], first: u64) {
    if service.storing {
        // What memory has first, then these
        if source.pending.count > 0 {
            if !write_file(service, source, source.pending) {
                add_pending(source, entries, first)
                return void
            }
            runtime.array_reset(&source.pending)
        }
        if !source.filed {
            // A new file: from a StoredStart, with every format string and schema its records could need
            header : u8[..]
            defer runtime.array_free(&header)
            file_header(service, source, first, &header)
            if !write_file(service, source, header) {
                start_pending(service, source, first)
                add_pending(source, entries, first)
                return void
            }
        }
        if !write_file(service, source, entries) {
            start_pending(service, source, first)
            add_pending(source, entries, first)
        }
        return void
    }
    add_pending(source, entries, first)
}

add_pending :: fn(source: ptr[mut Source], entries: u8[], first: u64) {
    if source.pending.count + entries.count > PENDING_BYTES {
        source.dropped += source.count - first
        return void
    }
    for byte in entries {
        runtime.array_add(&source.pending, byte)
    }
}

// A new file's start: a StoredStart, then each of the source's rings' format strings, then each schema it's used.
file_header :: fn(service: ptr[Service], source: ptr[Source], first: u64, into: ptr[mut u8[..]]) {
    add_start(service, into, first)
    last :: source.instances + 1
    for instance in cast[u32](1)..<last {
        add_instance(into, instance)
        for format in source.formats {
            if format.instance == instance && format.at + format.count <= source.texts.count {
                entry := runtime.SlopOsEventsFormat.{offset = format.offset, count = cast[u32](format.count)}
                entry.entry = runtime.SlopOsEventsEntry.{size = cast[u32](padded(size_of(runtime.SlopOsEventsFormat) + format.count)),
                    kind = runtime.SLOP_OS_EVENTS_FORMAT}
                add_bytes(into, cast[rawptr](&entry), size_of(runtime.SlopOsEventsFormat))
                for byte in part(source.texts, format.at, format.count) {
                    runtime.array_add(into, byte)
                }
                pad(into)
            }
        }
    }
    for used in source.used {
        known :: match schema_of(service, used.hash) {
            case Some(found) => found
            case None => continue
        }
        entry := runtime.SlopOsEventsSchema.{hash = used.hash, count = cast[u32](known.count)}
        entry.entry = runtime.SlopOsEventsEntry.{size = cast[u32](padded(size_of(runtime.SlopOsEventsSchema) + known.count)),
            kind = runtime.SLOP_OS_EVENTS_SCHEMA}
        add_bytes(into, cast[rawptr](&entry), size_of(runtime.SlopOsEventsSchema))
        for byte in known {
            runtime.array_add(into, byte)
        }
        pad(into)
    }
}

padded :: fn(count: usize) -> usize {
    return (count + 7) & ~cast[usize](7)
}

pad :: fn(into: ptr[mut u8[..]]) {
    loop {
        if (into.count & 7) == 0 {
            break
        }
        runtime.array_add(into, cast[u8](0))
    }
}

/*
 * bytes added to the end of a source's file, which they start if it isn't started yet; once it holds FILE_BYTES, it's
 * moved to its .old file, and the next write starts another. False if the directory couldn't take them.
 */
write_file :: fn(service: ptr[mut Service], source: ptr[mut Source], bytes: u8[]) -> bool {
    path_storage : u8[64]
    path :: path_of(source, ".events", &path_storage)
    file :: match os.open_in(service.store, path, .APPEND) {
        case Ok(opened) => opened
        case Error(error) => return false
    }
    written :: os.write(file, text_of(bytes))
    os.close(file)
    if written != null {
        return false
    }
    source.filed = true
    source.file_bytes += cast[u64](bytes.count)
    if source.file_bytes >= FILE_BYTES {
        old_storage : u8[64]
        if os.rename_in(service.store, path, path_of(source, ".old", &old_storage)) == null {
            source.filed = false
            source.file_bytes = 0
        }
    }
    return true
}

// A source's file's name, with its extension, in storage.
path_of :: fn(source: ptr[Source], extension: string, storage: ptr[mut u8[64]]) -> string {
    count : usize = 0
    for byte in source.name {
        if count < source.name_count && count < storage.count {
            storage[count] = byte
            count += 1
        }
    }
    for character in extension {
        if count < storage.count {
            storage[count] = cast[u8](character)
            count += 1
        }
    }
    return text_of(part(storage^, 0, count))
}

// count bytes of bytes from at, or none if they aren't all there.
part :: fn(bytes: u8[], at: usize, count: usize) -> u8[] {
    none : u8[]
    if count == 0 || at >= bytes.count || count > bytes.count - at {
        return none
    }
    return view_of(&bytes[at], count)
}

none_bytes :: fn() -> u8[] {
    none : u8[]
    return none
}

text_of :: fn(bytes: u8[]) -> string {
    return if bytes.count > 0 { string_of(&bytes[0], bytes.count) } else { "" }
}

// Records kept in directory end from now on: what each source has in memory written there first.
store :: fn(service: ptr[mut Service], end: slop_os.Channel) {
    directory, error :: os.directory_on(end)
    if error != null {
        return void
    }
    if service.storing {
        os.close_directory(service.store)
    }
    service.store = directory
    service.storing = true
    stored := 0
    for i in cast[usize](0)..<service.source_count {
        source :: &service.sources[i % MAX_SOURCES]
        source.filed = false
        source.file_bytes = 0
        if write_file(service, source, source.pending) {
            runtime.array_reset(&source.pending)
            stored += 1
        }
    }
    log_line.write(service.log, "events: keeping records in the directory given, % sources' so far", stored)
}

learn_schema :: fn(service: ptr[mut Service], hash: u8[32], bytes: u8[]) {
    if schema_of(service, hash) is_some {
        return void
    }
    at :: service.schema_bytes.count
    for byte in bytes {
        runtime.array_add(&service.schema_bytes, byte)
    }
    runtime.array_add(&service.schemas, KnownSchema.{hash = hash, at = at, count = bytes.count})
}

schema_of :: fn(service: ptr[Service], hash: u8[32]) -> u8[]? {
    for known in service.schemas {
        if same_hash(known.hash, hash) && known.at + known.count <= service.schema_bytes.count {
            return part(service.schema_bytes, known.at, known.count)
        }
    }
    return null
}

same_hash :: fn(a: u8[32], b: u8[32]) -> bool {
    for byte, i in a {
        if byte != b[i] {
            return false
        }
    }
    return true
}

note_used :: fn(source: ptr[mut Source], hash: u8[32]) {
    for used in source.used {
        if same_hash(used.hash, hash) {
            return void
        }
    }
    runtime.array_add(&source.used, SchemaHash.{hash = hash})
}

/*
 * The record at `at` in entries rendered into into, by the format strings in formats (their text in texts) of its
 * ring, instance, and the schemas the service knows: its level.
 */
render :: fn(service: ptr[Service], entries #escaping : u8[], at: usize, formats: ptr[FormatText[..]], texts: u8[], instance: u32,
    into: ptr[mut u8[..]]) -> u8 {
    size :: entry_size_at(entries, at)
    if size < size_of(runtime.SlopOsEventsRecord) {
        return 0
    }
    record :: cast[ptr[runtime.SlopOsEventsRecord]](address_in(entries, at))
    // On the heap: a view of them is given to render
    arguments : schema.Argument[..]
    defer runtime.array_free(&arguments)
    count : usize = 0
    cursor := at + size_of(runtime.SlopOsEventsRecord)
    end :: at + size
    for i in cast[usize](0)..<cast[usize](record.argument_count) {
        if cursor + size_of(runtime.SlopOsEventsArgument) > end || count >= runtime.SLOP_OS_EVENTS_MAX_ARGUMENTS {
            break
        }
        argument :: cast[ptr[runtime.SlopOsEventsArgument]](address_in(entries, cursor))
        value_at :: cursor + size_of(runtime.SlopOsEventsArgument)
        value_count :: cast[usize](argument.count)
        if value_at + value_count > end {
            break
        }
        none : u8[]
        value :: part(entries, value_at, value_count)
        runtime.array_add(&arguments, schema.Argument.{schema = schema_of(service, argument.hash) or_else none, value = value})
        count += 1
        cursor = value_at + padded(value_count)
    }
    format_string := ""
    start : usize = 0
    if record.named != 0 {
        for format in formats^ {
            if format.instance == instance && format.offset == record.format && format.at + format.count <= texts.count && format.count > 0 {
                format_string = text_of(part(texts, format.at, format.count))
                break
            }
        }
    }
    else if count > 0 {
        // Not a literal: the first argument, a string
        value :: if arguments.count > 0 { arguments[0].value } else { none_bytes() }
        text_count :: cast[usize](word_of(value, 0))
        distance :: cast[usize](word_of(value, 8))
        format_string = text_of(part(value, distance, text_count))
        start = 1
    }
    if start <= arguments.count {
        given : schema.Argument[] = arguments
        schema.render(format_string, given[start..<given.count], into)
    }
    return record.level
}

word_of :: fn(bytes: u8[], at: usize) -> u64 {
    result : u64 = 0
    for i in cast[usize](0)..<8 {
        if at + i < bytes.count {
            result |= cast[u64](bytes[at + i]) << (8 * cast[u64](i))
        }
    }
    return result
}

// The size of the entry at `at` in entries, or 0 if there isn't a whole one there.
entry_size_at :: fn(entries: u8[], at: usize) -> usize {
    if at + size_of(runtime.SlopOsEventsEntry) > entries.count {
        return 0
    }
    size :: cast[usize](cast[ptr[runtime.SlopOsEventsEntry]](address_in(entries, at)).size)
    if size < size_of(runtime.SlopOsEventsEntry) || (size & 7) != 0 || size > entries.count - at {
        return 0
    }
    return size
}

kind_at :: fn(entries: u8[], at: usize) -> u16 {
    return cast[ptr[runtime.SlopOsEventsEntry]](address_in(entries, at)).kind
}

address_in :: fn(entries: u8[], at: usize) -> rawptr {
    return cast[rawptr](cast[uintptr](entries.data) + cast[uintptr](at))
}

/*
 * The first record of the source named name at or after from, at level or above, sent through end: from its .old
 * file, its file, then memory. False if there's none yet.
 */
answer :: fn(service: ptr[mut Service], end: slop_os.Channel, name: u8[], from: u64, level: u8) -> bool {
    index :: find_source(service, name)
    if index == NOWHERE {
        return false
    }
    source :: &service.sources[index % MAX_SOURCES]
    scan := Scan.{}
    defer runtime.array_free(&scan.formats)
    if service.storing {
        for extension in string.[".old", ".events"] {
            bytes : u8[..]
            defer runtime.array_free(&bytes)
            if read_file(service, source, extension, &bytes) {
                at :: find(service, bytes, &scan, from, level)
                if at != NOWHERE {
                    send_found(service, end, bytes, at, &scan, true)
                    return true
                }
            }
        }
    }
    at :: find(service, source.pending, &scan, from, level)
    if at != NOWHERE {
        send_found(service, end, source.pending, at, &scan, false)
        return true
    }
    return false
}

// A query held until there's a record for it: false if there's no room to hold another.
hold :: fn(service: ptr[mut Service], client: usize, name: u8[], from: u64, level: u8) -> bool {
    if name.count > NAME_BYTES {
        return false
    }
    for i in cast[usize](0)..<MAX_WAITING {
        waiting :: &service.waiting[i]
        if waiting.client == NOWHERE {
            waiting.client = client
            for byte, j in name {
                waiting.name[j % NAME_BYTES] = byte
            }
            waiting.name_count = name.count
            waiting.from = from
            waiting.level = level
            return true
        }
    }
    return false
}

// Each held query answered, if there's a record for it now.
answer_waiting :: fn(service: ptr[mut Service]) {
    for i in cast[usize](0)..<MAX_WAITING {
        waiting :: service.waiting[i]
        if waiting.client == NOWHERE || waiting.client >= service.connected.ends.count {
            continue
        }
        end :: service.connected.ends[waiting.client]
        count :: if waiting.name_count < NAME_BYTES { waiting.name_count } else { NAME_BYTES }
        if answer(service, end, view_of(&waiting.name[0], count), waiting.from, waiting.level) {
            service.waiting[i].client = NOWHERE
        }
    }
}

// Where the first record of this boot at or after from, at level or above, is in bytes, read after what scan has; or NOWHERE.
find :: fn(service: ptr[mut Service], bytes: u8[], scan: ptr[mut Scan], from: u64, level: u8) -> usize {
    at : usize = 0
    loop {
        size :: entry_size_at(bytes, at)
        if size == 0 {
            return NOWHERE
        }
        kind :: kind_at(bytes, at)
        if kind == STORED_START && size >= size_of(StoredStart) {
            start :: cast[ptr[StoredStart]](address_in(bytes, at))
            scan.boot_matches = start.boot == service.boot
            scan.number = start.first
            runtime.array_reset(&scan.formats)
        }
        else if kind == STORED_INSTANCE && size >= size_of(StoredInstance) {
            scan.instance = cast[ptr[StoredInstance]](address_in(bytes, at)).instance
        }
        else if kind == runtime.SLOP_OS_EVENTS_FORMAT && size >= size_of(runtime.SlopOsEventsFormat) {
            format :: cast[ptr[runtime.SlopOsEventsFormat]](address_in(bytes, at))
            if cast[usize](format.count) <= size - size_of(runtime.SlopOsEventsFormat) {
                runtime.array_add(&scan.formats, FormatText.{instance = scan.instance, offset = format.offset,
                    at = at + size_of(runtime.SlopOsEventsFormat), count = cast[usize](format.count)})
            }
        }
        else if kind == runtime.SLOP_OS_EVENTS_SCHEMA && size >= size_of(runtime.SlopOsEventsSchema) {
            given :: cast[ptr[runtime.SlopOsEventsSchema]](address_in(bytes, at))
            count :: cast[usize](given.count)
            if count <= size - size_of(runtime.SlopOsEventsSchema) && count > 0 {
                learn_schema(service, given.hash, view_of(cast[ptr[u8]](address_in(bytes, at + size_of(runtime.SlopOsEventsSchema))), count))
            }
        }
        else if kind == runtime.SLOP_OS_EVENTS_RECORD && size >= size_of(runtime.SlopOsEventsRecord) && scan.boot_matches {
            number :: scan.number
            scan.number += 1
            if number >= from && cast[ptr[runtime.SlopOsEventsRecord]](address_in(bytes, at)).level >= level {
                return at
            }
        }
        at += size
    }
}

// A found record, rendered, sent through end.
send_found :: fn(service: ptr[mut Service], end: slop_os.Channel, bytes #escaping : u8[], at: usize, scan: ptr[mut Scan], stored: bool) {
    text : u8[..]
    defer runtime.array_free(&text)
    level :: render(service, bytes, at, &scan.formats, bytes, scan.instance, &text)
    record :: cast[ptr[runtime.SlopOsEventsRecord]](address_in(bytes, at))
    count :: if text.count < TEXT_LIMIT { text.count } else { TEXT_LIMIT }
    out := os.Outgoing.{}
    response :: os.begin[events.Response](&out)
    shown :: part(text, 0, count)
    response^ = .Found(events.Found.{number = scan.number - 1, time = record.time, level = level, stored = stored,
        text = os.append(&out, shown)})
    _ = events.send_response(end, service.port, &out)
}

// A source's file with this extension read whole into into: false if it isn't there.
read_file :: fn(service: ptr[mut Service], source: ptr[Source], extension: string, into: ptr[mut u8[..]]) -> bool {
    path_storage : u8[64]
    file :: match os.open_in(service.store, path_of(source, extension, &path_storage), .READ) {
        case Ok(opened) => opened
        case Error(error) => return false
    }
    defer os.close(file)
    buffer : u8[4096]
    loop {
        count :: match os.read(file, buffer) {
            case Ok(got) => got
            case Error(error) => return false
        }
        if count == 0 {
            return true
        }
        for i in cast[usize](0)..<count {
            if i < buffer.count {
                runtime.array_add(into, buffer[i])
            }
        }
    }
}
