/**
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
 *
 * A service started again is given the rings of programs still running (Adopt). Their doorbells went with the service
 * before, so they're read every ADOPTED_POLL instead; and their reader is moved on, so their writers give their format
 * strings and schemas again.
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
import service_kit from "../../libraries/service_kit"
import events from "../../protocols/events"

/** The most sources the service keeps records of; Open and Adopt for a new name past it are refused. */
MAX_SOURCES :: 32
/** The most rings read at once, opened or adopted; Open and Adopt are refused while they're all in use. */
MAX_RINGS :: 48
/** The most queries held waiting for a record at once; a query that would wait past it is answered End. */
MAX_WAITING :: 8
/** The most bytes a source's name has. */
NAME_BYTES :: 32
/** The key a ring's doorbell is bound to the port with, plus its slot: above the clients' keys. */
DOORBELL_KEY : u64 : 1000
/** A ring's whole size in bytes, its header included, as base's logger expects it. */
RING_BYTES : u64 : runtime.SLOP_OS_EVENTS_RING_BYTES
/**
 * The most bytes memory keeps of a source's records before there's a directory to store them in, its file header
 * aside; records past it are dropped, and counted as dropped.
 */
PENDING_BYTES :: 32768
/** The bytes a source's file holds before it's moved to its .old file and a new one started. */
FILE_BYTES : u64 : 256 * 1024
/** The most bytes of a record's rendered text a query gives; the rest is cut off. */
TEXT_LIMIT :: 1024
/** No index: a free ring's source, a free waiting query's client, or a source or record not found. */
NOWHERE : usize : 0xffffffffffffffff
/** How often adopted rings, without doorbells, are read, in nanoseconds: 20 ms. */
ADOPTED_POLL : u64 : 20_000_000

// What's stored beside the ring's entries: where a boot's records start, numbering them, and which ring they're from
/** A stored entry's kind: a StoredStart, past the ring's own kinds. */
STORED_START : u16 : 16
/** A stored entry's kind: a StoredInstance, past the ring's own kinds. */
STORED_INSTANCE : u16 : 17

/** A stored entry where a boot's records start, in a file or in memory: what follows is that boot's. */
StoredStart :: struct {
    /** Its entry's header, kind STORED_START, its size this struct's. */
    entry : runtime.SlopOsEventsEntry,
    /** The boot the records after it are from: a random number the service picked when it started. */
    boot : u64,
    /** The number, among the source's records this boot, of the first record after it. */
    first : u64,
}

/** A stored entry saying which of the source's rings the entries after it are from, for their format strings. */
StoredInstance :: struct {
    /** Its entry's header, kind STORED_INSTANCE, its size this struct's. */
    entry : runtime.SlopOsEventsEntry,
    /** The ring, by its instance among the source's, from 1. */
    instance : u32,
    /** Unused, zero, padding the entry to 8 bytes. */
    reserved : u32,
}

/** A format string's text, of one of a source's rings, by its offset in that program's image: count bytes at `at`. */
FormatText :: struct {
    /** The ring it was given in, by its instance among the source's, from 1. */
    instance : u32,
    /** Its offset in the program's image, which records name it by. */
    offset : u64,
    /** Where its text starts, in bytes: in the source's texts, or for a query, in the file or memory being read. */
    at : usize,
    /** Its text's length in bytes. */
    count : usize,
}

/** A type's schema, by its hash: count bytes at `at` in the service's schema_bytes. */
KnownSchema :: struct {
    /** The type's schema hash, as base's runtime.schema_hash gives it. */
    hash : u8[32],
    /** Where the schema starts in schema_bytes, in bytes. */
    at : usize,
    /** The schema's length in bytes. */
    count : usize,
}

/** A schema's hash, one a source's records have used. */
SchemaHash :: struct {
    /** The type's schema hash. */
    hash : u8[32],
}

/** A source of records: a name programs' rings are opened for, and what's kept of them. */
Source :: struct {
    /** Its name, its first name_count bytes: letters, digits and underscores. */
    name : u8[NAME_BYTES],
    /** How many bytes of name are used, 1 to NAME_BYTES. */
    name_count : usize,
    /** Rings opened for it so far: each is an instance, from 1. */
    instances : u32,
    /** Its records so far this boot, which numbers the next, dropped ones counted. */
    count : u64,
    /** How many of its records were dropped: by its rings, while they were full, or by memory, while it was full. */
    dropped : u64,
    /** Its rings' format strings, their text in texts, kept for its service's life. */
    formats : FormatText[..],
    /** The text of its rings' format strings, each at its FormatText's at. */
    texts : u8[..],
    /** The schemas its records have used, which a new file is given first. */
    used : SchemaHash[..],
    /** What's to be stored and isn't yet, from a StoredStart, at most PENDING_BYTES of records. */
    pending : u8[..],
    /** How many bytes its file holds, as the service has written it. */
    file_bytes : u64,
    /** Whether its file's started this boot; false, the next write starts one, with a file header. */
    filed : bool,
}

/**
 * A ring a program writes to; its source NOWHERE when it's free. Its launcher owns it, and the service reads and writes
 * it through the kernel (memory_read, memory_write) with a handle that doesn't own it, never mapping it: so the service
 * ending leaves its programs' rings to them, and a ring retired (Retire) is ObjectGone to it once its last records are
 * read (decisions/0098).
 */
Ring :: struct {
    /** Its source, by its index in sources; NOWHERE when the slot is free. */
    source : usize,
    /** Which of its source's rings it is, from 1, as its StoredInstance says. */
    instance : u32,
    /** The service's handle to the ring, to read and write it, not owning it; closed when the ring's let go. */
    memory : slop_os.Memory,
    /** The service's end of its doorbell, bound to the port; NO_HANDLE for an adopted ring, which is polled. */
    doorbell : slop_os.Channel,
}

/** A query waiting for a record: its client NOWHERE when it's free. */
Waiting :: struct {
    /** The client that asked, by its index in connected; NOWHERE when the slot is free. */
    client : usize,
    /** The source's name, its first name_count bytes. */
    name : u8[NAME_BYTES],
    /** How many bytes of name are used. */
    name_count : usize,
    /** The number of the first record it wants, among the source's this boot. */
    from : u64,
    /** The lowest level it wants, a LogLevel. */
    level : u8,
}

/** The events service's state, one for its life, from the heap. */
Service :: struct {
    /** Where records are shown as they're read, and the service's own lines written; NO_HANDLE for nowhere. */
    log : slop_os.DebugLog,
    /** The service's startup block, for its budget. */
    block : ptr[slop_os.StartupBlock],
    /** The port the clients' ends and the rings' doorbells are bound to. */
    port : slop_os.Port,
    /** This boot, a random number picked at the start, so a query tells this boot's stored records from another's. */
    boot : u64,
    /** The sources, the first source_count used, in the order they were first named. */
    sources : Source[MAX_SOURCES],
    /** How many of sources are used, at most MAX_SOURCES. */
    source_count : usize,
    /** The rings being read, by slot; a free one's source is NOWHERE. */
    rings : Ring[MAX_RINGS],
    /** The queries held for a record; a free one's client is NOWHERE. */
    waiting : Waiting[MAX_WAITING],
    /** Every schema learned, from any source or file, its bytes in schema_bytes. */
    schemas : KnownSchema[..],
    /** The bytes of every schema learned. */
    schema_bytes : u8[..],
    /** Where records are stored, once Store has given it; a directory before that is meaningless. */
    store : os.Directory,
    /** Whether Store has given a directory, so store is open. */
    storing : bool,
    /** The clients, from the first, given at the start, and those from Connect. */
    connected : service_kit.Clients,
}

/** A query's place in what it reads: where it is in a boot's records, and the format strings found before it. */
Scan :: struct {
    /** Whether the last StoredStart read was this boot's, so the records after it count. */
    boot_matches : bool,
    /** The number of the next record read, among the source's this boot; one past the found record's once found. */
    number : u64,
    /** The ring the entries being read are from, as the last StoredInstance said. */
    instance : u32,
    /** The format strings read since the last StoredStart, their text in the bytes being read. */
    formats : FormatText[..],
}

/**
 * Keep the log records of every program the supervisor starts: read each program's ring, show its records on the debug
 * log, store them once given a directory, and answer queries for them.
 *
 * It serves for good, reading each ring when its doorbell rings, and adopted rings, which have none, every
 * ADOPTED_POLL.
 *
 * @param log The debug log records are shown on as they're read, each after its source's name; without one they're
 *     only kept.
 * @param clients The listener its first client, the supervisor, connects on; further clients come as Connect
 *     requests.
 * @return Only on failing to start: 99 without memory for its state, 1 without a port, and 2 if its first client can't
 *     be added. Serving, it doesn't return.
 */
main :: fn(log: slop_os.DebugLog?, clients: os.Listener[events.Events]) -> int {
    // Its state; without the memory for it, it ends with 99 (decisions/0104)
    service_made, service_error :: runtime.new_aligned(Service, align_of(Service))
    if service_error != null {
        return 99
    }
    service :: service_made
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
                    view_of(cast[ptr[u8]](&waiting), size_of(u32)))
                match read_header(ring.memory) {
                    case Some(header) => written = written || header.written != header.read
                    case None => release(service, i)
                }
            }
        }
        if written {
            continue
        }
        deadline := slop_os.NO_DEADLINE
        for i in cast[usize](0)..<MAX_RINGS {
            if service.rings[i].source != NOWHERE && cast[slop_os.Handle](service.rings[i].doorbell) == slop_os.NO_HANDLE {
                deadline = (slop_os.clock_monotonic() or_else 0) + ADOPTED_POLL
            }
        }
        packets : slop_os.Packet[8]
        taken :: slop_os.port_wait(service.port, packets, deadline) or_else 0
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

/**
 * Answer every request a client has sent, until there are none left, or it's gone.
 *
 * Open is answered Opened or Refused; Store and Retire, Done; Adopt, Done or Refused; Query, Found, or End if there's
 * no record for it and it doesn't wait or can't be held; a held query is answered later, by answer_waiting. Connect
 * adds the client whose end it brings, closing that end if there's no room. A client whose channel fails is dropped,
 * with its held queries.
 *
 * @param service The events service's state.
 * @param index The client to serve, by its index in connected; one past them, or a dropped one, does nothing.
 * @param into Where each request is received; overwritten by each, so names read from it are good only until the next.
 */
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
            case Adopt(adopted) => {
                out := os.Outgoing.{}
                response :: os.begin[events.Response](&out)
                response^ = if adopt(service, os.items(into, adopted.source), adopted.ring) { .Done } else { .Refused }
                _ = events.send_response(end, service.port, &out)
            }
        }
    }
}

/**
 * Make a ring for a program whose records are the source named name, made a source if it isn't one.
 *
 * The ring is made and its header written here; the service keeps a duplicate handle that can read and write it but
 * not own it, and its end of the doorbell, bound to the port. The doorbell is read once, so its next message wakes the
 * port.
 *
 * @param service The events service's state.
 * @param name The source's name, 1 to NAME_BYTES lowercase letters, digits and underscores.
 * @return What to give the program: the ring's owning handle and the doorbell's other end, both moving to the caller,
 *     who launches the program, and on to it. Null, with nothing made kept, if the name isn't one, there's no room for
 *     a source or a ring, or the ring, its handle or the doorbell can't be made.
 */
open :: fn(service: ptr[mut Service], name: u8[]) -> events.Source? {
    index :: source_named(service, name)
    if index == NOWHERE {
        return null
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
    if slop_os.memory_write(memory, 0, view_of(cast[ptr[u8]](&header), size_of(runtime.SlopOsEventsRing))) is_error {
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

/**
 * Take over a ring another events service opened, read from here on as the source named name's.
 *
 * Its reader is moved on, so its writer gives every format string and schema again, for a reader that knows nothing of
 * it. It has no doorbell, so it's polled every ADOPTED_POLL.
 *
 * @param service The events service's state.
 * @param name The source's name, 1 to NAME_BYTES lowercase letters, digits and underscores.
 * @param memory A handle to the ring that can read and write it, which moves to the service: kept if it's taken, and
 *     closed if not.
 * @return True if it's taken; false, the handle closed, if the name isn't one, there's no room for a source or a ring,
 *     or the ring can't be read.
 */
adopt :: fn(service: ptr[mut Service], name: u8[], memory: slop_os.Memory) -> bool {
    index :: source_named(service, name)
    slot := NOWHERE
    for i in cast[usize](0)..<MAX_RINGS {
        if service.rings[i].source == NOWHERE {
            slot = i
            break
        }
    }
    header :: read_header(memory)
    if index == NOWHERE || slot == NOWHERE || (header is_none) {
        _ = slop_os.handle_close(cast[slop_os.Handle](memory))
        return false
    }
    // Its writer gives everything again, for a reader that knows nothing of it
    reader :: (header or_else runtime.SlopOsEventsRing.{}).reader + 1
    _ = slop_os.memory_write(memory, cast[u64](offset_of(runtime.SlopOsEventsRing, reader)),
        view_of(cast[ptr[u8]](&reader), size_of(u32)))
    source :: &service.sources[index % MAX_SOURCES]
    source.instances += 1
    service.rings[slot % MAX_RINGS] = Ring.{source = index, instance = source.instances, memory = memory,
        doorbell = cast[slop_os.Channel](slop_os.NO_HANDLE)}
    return true
}

/**
 * Find the source named name, made one if it isn't.
 *
 * @param service The events service's state; a new source starts its pending records with a file header.
 * @param name The name: 1 to NAME_BYTES lowercase letters, digits and underscores.
 * @return The source's index in sources, or NOWHERE if the name isn't one, or there's no room for another source.
 */
source_named :: fn(service: ptr[mut Service], name: u8[]) -> usize {
    if name.count == 0 || name.count > NAME_BYTES {
        return NOWHERE
    }
    for byte in name {
        if !((byte >= cast[u8]('a') && byte <= cast[u8]('z')) || (byte >= cast[u8]('0') && byte <= cast[u8]('9')) || byte == cast[u8]('_')) {
            return NOWHERE
        }
    }
    index := find_source(service, name)
    if index == NOWHERE {
        if service.source_count >= MAX_SOURCES {
            return NOWHERE
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
    return index
}

/**
 * Find the source named name, without making one.
 *
 * @param service The events service's state.
 * @param name The name, compared byte for byte.
 * @return The source's index in sources, or NOWHERE if there's none of that name.
 */
find_source :: fn(service: ptr[Service], name: u8[]) -> usize {
    for i in cast[usize](0)..<service.source_count {
        if i < MAX_SOURCES && same_name(&service.sources[i], name) {
            return i
        }
    }
    return NOWHERE
}

/**
 * Tell whether a source has a name.
 *
 * @param source The source whose name is compared: its first name_count bytes; only read.
 * @param name The name, compared byte for byte.
 * @return True if they're the same bytes.
 */
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

/**
 * Get a source's name, for showing it.
 *
 * @param source The source whose name is wanted; it has to outlive the view returned, which is of its own bytes.
 * @return Its name, a view of the source's own bytes, good while the source is.
 */
name_of :: fn(source: ptr[Source]) -> string {
    count :: if source.name_count < NAME_BYTES { source.name_count } else { NAME_BYTES }
    return string_of(&source.name[0], count)
}

/**
 * Begin a source's pending entries again, as a file is: with a file header, for records from first on.
 *
 * @param service The events service's state, for this boot and the schemas.
 * @param source The source, whose pending entries are thrown away first.
 * @param first The number of the first record that will follow.
 */
start_pending :: fn(service: ptr[Service], source: ptr[mut Source], first: u64) {
    runtime.array_reset(&source.pending)
    file_header(service, source, first, &source.pending)
}

/**
 * Add a StoredStart for this boot.
 *
 * @param service The events service's state, for this boot.
 * @param into Where it's added, at the end.
 * @param first The number of the first record after it.
 */
add_start :: fn(service: ptr[Service], into: ptr[mut u8[..]], first: u64) {
    start := StoredStart.{boot = service.boot, first = first}
    start.entry = runtime.SlopOsEventsEntry.{size = cast[u32](size_of(StoredStart)), kind = STORED_START}
    add_bytes(into, view_of(cast[ptr[u8]](&start), size_of(StoredStart)))
}

/**
 * Add a StoredInstance, saying which ring the entries after it are from.
 *
 * @param into Where it's added, at the end.
 * @param instance The ring, by its instance among the source's, from 1.
 */
add_instance :: fn(into: ptr[mut u8[..]], instance: u32) {
    marker := StoredInstance.{instance = instance}
    marker.entry = runtime.SlopOsEventsEntry.{size = cast[u32](size_of(StoredInstance)), kind = STORED_INSTANCE}
    add_bytes(into, view_of(cast[ptr[u8]](&marker), size_of(StoredInstance)))
}

/**
 * Add bytes to the end of a list.
 *
 * @param into The list, grown with context's allocator.
 * @param bytes The bytes, copied.
 */
add_bytes :: fn(into: ptr[mut u8[..]], bytes: u8[]) {
    for byte in bytes {
        runtime.array_add(into, byte)
    }
}

/**
 * Read a ring's header, through the kernel.
 *
 * @param memory The service's handle to the ring.
 * @return The header, a copy; null once its program, which owns it, has ended, or the ring's been retired.
 */
read_header :: fn(memory: slop_os.Memory) -> runtime.SlopOsEventsRing? {
    header := runtime.SlopOsEventsRing.{}
    if slop_os.memory_read(memory, 0, view_of(cast[ptr[mut u8]](&header), size_of(runtime.SlopOsEventsRing))) is_error {
        return null
    }
    return header
}

/**
 * Answer a ring's doorbell: its messages read until there are none, and the ring let go, its last records read first,
 * once its writer's gone.
 *
 * @param service The events service's state.
 * @param slot The ring, by its slot in rings; one past them, or a free one, does nothing.
 */
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

/**
 * Let go of a ring: its doorbell unbound and closed, its handle closed, and its slot freed.
 *
 * @param service The events service's state.
 * @param slot The ring, by its slot in rings.
 */
release :: fn(service: ptr[mut Service], slot: usize) {
    ring :: &service.rings[slot % MAX_RINGS]
    _ = slop_os.port_unbind(service.port, DOORBELL_KEY + cast[u64](slot))
    _ = slop_os.handle_close(cast[slop_os.Handle](ring.memory))
    if cast[slop_os.Handle](ring.doorbell) != slop_os.NO_HANDLE {
        _ = slop_os.handle_close(cast[slop_os.Handle](ring.doorbell))
    }
    ring.source = NOWHERE
}

/**
 * Read what a ring's writer has published: each format string and schema learned, each record numbered and shown on the
 * debug log, and all of it kept, after a StoredInstance.
 *
 * Nothing's read without the memory for everything it can add (room_to_drain): the entries stay in the ring for a later
 * drain. A ring whose header or entries don't hold together is read no further: its reader's moved to its writer. A
 * ring that can't be read anymore is let go.
 *
 * @param service The events service's state.
 * @param slot The ring, by its slot in rings; one past them, or a free one, does nothing.
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
    fresh : u8[..]
    defer runtime.array_free(&fresh)
    /*
     * Room for everything these entries can add, before any's read (decisions/0104): without it, they're left in the
     * ring for a later drain, and a ring that fills says what it dropped, so nothing goes missing unsaid
     */
    if !room_to_drain(service, source, cast[usize](size), &copied, &fresh) {
        return void
    }
    for i in cast[u64](0)..<size {
        runtime.array_add(&copied, cast[u8](0))
    }
    if slop_os.memory_read(ring.memory, cast[u64](size_of(runtime.SlopOsEventsRing)), copied) is_error {
        release(service, slot)
        return void
    }
    data :: cast[u64](cast[uintptr](copied.data))
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
        entry :: cast[ptr[runtime.SlopOsEventsEntry]](data + at)
        entry_size :: cast[u64](entry.size)
        if entry_size < 8 || (entry_size & 7) != 0 || entry_size > size - at {
            read = written
            break
        }
        bytes :: view_of(cast[ptr[u8]](data + at), cast[usize](entry_size))
        kind :: entry.kind
        if kind == runtime.SLOP_OS_EVENTS_FORMAT && bytes.count >= size_of(runtime.SlopOsEventsFormat) {
            format :: cast[ptr[runtime.SlopOsEventsFormat]](entry)
            count :: cast[usize](format.count)
            if count <= bytes.count - size_of(runtime.SlopOsEventsFormat) {
                text_at :: source.texts.count
                add_bytes(&source.texts, view_of(cast[ptr[u8]](data + at + cast[u64](size_of(runtime.SlopOsEventsFormat))), count))
                runtime.array_add(&source.formats, FormatText.{instance = ring.instance, offset = format.offset, at = text_at, count = count})
                add_bytes(&fresh, bytes)
            }
        }
        else if kind == runtime.SLOP_OS_EVENTS_SCHEMA && bytes.count >= size_of(runtime.SlopOsEventsSchema) {
            given :: cast[ptr[runtime.SlopOsEventsSchema]](entry)
            count :: cast[usize](given.count)
            if count <= bytes.count - size_of(runtime.SlopOsEventsSchema) {
                learn_schema(service, given.hash, view_of(cast[ptr[u8]](data + at + cast[u64](size_of(runtime.SlopOsEventsSchema))), count))
                note_used(source, given.hash)
                add_bytes(&fresh, bytes)
            }
        }
        else if kind == runtime.SLOP_OS_EVENTS_RECORD && bytes.count >= size_of(runtime.SlopOsEventsRecord) {
            source.count += 1
            add_bytes(&fresh, bytes)
        }
        else if kind == runtime.SLOP_OS_EVENTS_DROPPED && bytes.count >= size_of(runtime.SlopOsEventsDropped) {
            dropped :: cast[ptr[runtime.SlopOsEventsDropped]](entry).count
            source.dropped += dropped
            log_line.write(service.log, "events: % dropped % records while its ring was full", name_of(source), dropped)
            add_bytes(&fresh, bytes)
        }
        read += entry_size
    }
    _ = slop_os.memory_write(ring.memory, cast[u64](offset_of(runtime.SlopOsEventsRing, read)),
        view_of(cast[ptr[u8]](&read), size_of(u64)))
    show(service, source, fresh)
    keep(service, source, fresh, first)
}

/**
 * Show each record in entries on the debug log, after its source's name, and its level if it isn't info.
 *
 * @param service The events service's state, for the debug log and the schemas.
 * @param source The entries' source, for its name and its format strings.
 * @param entries Entries as they're stored, a StoredInstance before each ring's.
 */
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

/**
 * Name a log level, for showing it.
 *
 * @param level A LogLevel, as a number.
 * @return The name of the level it's at or above: "trace" below 10, then "debug", "info", "warn", "error", and "fatal"
 *     from 50.
 */
level_name :: fn(level: u8) -> string {
    return if level < 10 { "trace" } else if level < 20 { "debug" } else if level < 30 { "info" } else if level < 40 { "warn" }
        else if level < 50 { "error" } else { "fatal" }
}

/**
 * Keep entries of a source: in its file, if there's a directory to store them in, after what memory still has, or in
 * memory, while there's room; records that don't fit are dropped, and counted.
 *
 * A file write that fails leaves the entries in memory instead, after a new file header, so the next write starts a
 * file.
 *
 * @param service The events service's state: whether Store has given a directory decides where the entries go, and a
 *     new file's header takes its schemas.
 * @param source The source the entries are of: its pending entries are written out or added to, its file noted as
 *     started and its size counted, and records that don't fit added to its dropped.
 * @param entries The entries, as they're stored, a StoredInstance first.
 * @param first The number of their first record, among the source's this boot.
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
            if runtime.array_try_reserve(&header, header_bound(service, source)) != null {
                add_pending(source, entries, first)
                return void
            }
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

/**
 * Reserve room in everything draining a ring of size bytes may grow, copied and fresh among them, so it can't run out
 * of memory partway (decisions/0104).
 *
 * Each list gets as much as entries that size could add to it, and the pending bytes all they may hold.
 *
 * @param service The events service's state, whose schemas may grow.
 * @param source The ring's source, whose format strings, schemas used and pending entries may grow.
 * @param size The ring's entries' size in bytes.
 * @param copied The list the ring's entries are copied into.
 * @param fresh The list the entries to keep are gathered into.
 * @return True if everything's reserved; false, with nothing to be read, without the memory. What was reserved stays.
 */
room_to_drain :: fn(service: ptr[mut Service], source: ptr[mut Source], size: usize, copied: ptr[mut u8[..]], fresh: ptr[mut u8[..]])
    -> bool {
    entries :: size / 8 + 1
    return runtime.array_try_reserve(copied, size) == null
        && runtime.array_try_reserve(fresh, size + size_of(StoredInstance) + 8) == null
        && runtime.array_try_reserve(&source.texts, source.texts.count + size) == null
        && runtime.array_try_reserve(&source.formats, source.formats.count + entries) == null
        && runtime.array_try_reserve(&source.used, source.used.count + entries) == null
        && runtime.array_try_reserve(&service.schema_bytes, service.schema_bytes.count + size) == null
        && runtime.array_try_reserve(&service.schemas, service.schemas.count + entries) == null
        && runtime.array_try_reserve(&source.pending, PENDING_BYTES + header_bound(service, source) + size) == null
}

/**
 * Bound what file_header writes for a source, with what draining a ring's entries could add to it.
 *
 * @param service The events service's state, for the schemas' bytes.
 * @param source The source whose rings, format strings, texts and schemas used are bounded; only read.
 * @return The most bytes it could write, counted from the lists' capacities, not their counts.
 */
header_bound :: fn(service: ptr[Service], source: ptr[Source]) -> usize {
    return size_of(StoredStart) + cast[usize](source.instances + 2) * (size_of(StoredInstance) + 8)
        + source.formats.capacity * (size_of(runtime.SlopOsEventsFormat) + 8) + source.texts.capacity
        + source.used.capacity * (size_of(runtime.SlopOsEventsSchema) + 8) + service.schema_bytes.capacity
}

/**
 * Add entries to what memory keeps of a source, or drop them if they'd take it past PENDING_BYTES.
 *
 * @param source The source; dropped records are added to its dropped.
 * @param entries The entries, as they're stored.
 * @param first The number of their first record, so how many are dropped is the source's count less it.
 */
add_pending :: fn(source: ptr[mut Source], entries: u8[], first: u64) {
    if source.pending.count + entries.count > PENDING_BYTES {
        source.dropped += source.count - first
        return void
    }
    for byte in entries {
        runtime.array_add(&source.pending, byte)
    }
}

/**
 * Write a new file's start: a StoredStart, then each of the source's rings' format strings, after its StoredInstance,
 * then each schema it's used.
 *
 * @param service The events service's state, for this boot and the schemas.
 * @param source The source whose rings' format strings and used schemas are written; only read.
 * @param first The number of the first record after it.
 * @param into Where it's written, at the end.
 */
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
                add_bytes(into, view_of(cast[ptr[u8]](&entry), size_of(runtime.SlopOsEventsFormat)))
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
        add_bytes(into, view_of(cast[ptr[u8]](&entry), size_of(runtime.SlopOsEventsSchema)))
        for byte in known {
            runtime.array_add(into, byte)
        }
        pad(into)
    }
}

/**
 * Round a byte count up to a whole number of 8 bytes, as entries are.
 *
 * @param count A size in bytes; 0 gives 0, and one already a multiple of 8 is given back as it is.
 * @return count rounded up to a multiple of 8.
 */
padded :: fn(count: usize) -> usize {
    return (count + 7) & ~cast[usize](7)
}

/**
 * Pad a list with zeros to a multiple of 8 bytes, the end of an entry.
 *
 * @param into The list padded, grown with context's allocator; nothing's added if its count's already a multiple of
 *     8.
 */
pad :: fn(into: ptr[mut u8[..]]) {
    loop {
        if (into.count & 7) == 0 {
            break
        }
        runtime.array_add(into, cast[u8](0))
    }
}

/**
 * Add bytes to the end of a source's file, which they start if there's none.
 *
 * Once the file holds FILE_BYTES, it's moved to its .old file, replacing the one there, and the next write starts
 * another; if the move fails, the file grows on.
 *
 * @param service The events service's state, its directory given by Store.
 * @param source The source; its file's size is counted, and the file noted as started.
 * @param bytes The entries, as they're stored.
 * @return True if they're written; false if the file couldn't be opened or written, which may leave part of them in it.
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

/**
 * Name a source's file: its name and an extension.
 *
 * @param source The source whose name, its first name_count bytes, starts the file's name.
 * @param extension The extension, its dot included: ".events" or ".old".
 * @param storage Where the name's written, cut off at 64 bytes.
 * @return The name, a view of storage, good while it is.
 */
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

/**
 * Get part of some bytes.
 *
 * @param bytes The bytes the part is of, not copied.
 * @param at Where the part starts, in bytes.
 * @param count The part's length in bytes.
 * @return A view of the part, good while bytes are; empty if count is 0 or they aren't all there.
 */
part :: fn(bytes: u8[], at: usize, count: usize) -> u8[] {
    none : u8[]
    if count == 0 || at >= bytes.count || count > bytes.count - at {
        return none
    }
    return view_of(&bytes[at], count)
}

/**
 * Get no bytes.
 *
 * @return An empty view.
 */
none_bytes :: fn() -> u8[] {
    none : u8[]
    return none
}

/**
 * View bytes as a string, without copying or checking them.
 *
 * @param bytes The bytes viewed, taken as text whatever they hold; not copied.
 * @return A string of them, good while they are; "" for none.
 */
text_of :: fn(bytes: u8[]) -> string {
    return if bytes.count > 0 { string_of(&bytes[0], bytes.count) } else { "" }
}

/**
 * Keep records in a directory from now on, writing what each source has in memory there first.
 *
 * A directory given before is closed and replaced. Each source starts a new file in it at its next write.
 *
 * @param service The events service's state.
 * @param end The directory's channel end, which moves to the service; if it can't be opened as a directory, nothing
 *     changes.
 */
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

/**
 * Learn a type's schema, if it isn't known already.
 *
 * @param service The events service's state; the schema is kept for its life.
 * @param hash The type's schema hash.
 * @param bytes The schema, copied.
 */
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

/**
 * Find a type's schema among those learned.
 *
 * @param service The events service's state.
 * @param hash The type's schema hash.
 * @return The schema, a view of schema_bytes, good until the next schema's learned; null if it isn't known.
 */
schema_of :: fn(service: ptr[Service], hash: u8[32]) -> u8[]? {
    for known in service.schemas {
        if same_hash(known.hash, hash) && known.at + known.count <= service.schema_bytes.count {
            return part(service.schema_bytes, known.at, known.count)
        }
    }
    return null
}

/**
 * Tell whether two schema hashes are the same.
 *
 * @param a A hash.
 * @param b Another.
 * @return True if every byte is.
 */
same_hash :: fn(a: u8[32], b: u8[32]) -> bool {
    for byte, i in a {
        if byte != b[i] {
            return false
        }
    }
    return true
}

/**
 * Note that a source's records have used a schema, so its new files are given it.
 *
 * @param source The source whose schemas used gain the hash, grown with context's allocator, unless it's there.
 * @param hash The type's schema hash; noted once.
 */
note_used :: fn(source: ptr[mut Source], hash: u8[32]) {
    for used in source.used {
        if same_hash(used.hash, hash) {
            return void
        }
    }
    runtime.array_add(&source.used, SchemaHash.{hash = hash})
}

/**
 * Render a record by the format strings of its ring and the schemas the service knows.
 *
 * Arguments are read while they're whole, and while there's memory for them; a format string that isn't named is the
 * first argument. A named format string that isn't known renders as an empty one.
 *
 * @param service The events service's state, for the schemas.
 * @param entries The entries the record is in.
 * @param at Where the record's entry starts in entries, in bytes.
 * @param formats The format strings of the record's source, or of what's being read.
 * @param texts The bytes the format strings' text is in.
 * @param instance The record's ring, by its instance, whose format strings it names.
 * @param into Where the text's written, at the end.
 * @return The record's level, a LogLevel; 0 if it isn't a whole record.
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
        // Without the memory for more, what's read so far is shown
        if runtime.array_try_add(&arguments, schema.Argument.{schema = schema_of(service, argument.hash) or_else none, value = value}) != null {
            break
        }
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

/**
 * Read a little-endian u64 from bytes.
 *
 * @param bytes The bytes read from, a record argument's value; any length, only read.
 * @param at Where it starts, in bytes.
 * @return Its value, bytes past the end taken as 0.
 */
word_of :: fn(bytes: u8[], at: usize) -> u64 {
    result : u64 = 0
    for i in cast[usize](0)..<8 {
        if at + i < bytes.count {
            result |= cast[u64](bytes[at + i]) << (8 * cast[u64](i))
        }
    }
    return result
}

/**
 * Get the size of the entry at `at` in entries.
 *
 * @param entries Entries as a ring or a file holds them, each a header then its body, padded to 8 bytes; only read.
 * @param at Where the entry starts, in bytes.
 * @return Its size in bytes, a multiple of 8, header included; 0 if there isn't a whole one there.
 */
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

/**
 * Get the kind of the entry at `at` in entries.
 *
 * @param entries Entries as a ring or a file holds them; there has to be a whole entry at at (entry_size_at).
 * @param at Where the entry starts, in bytes.
 * @return Its kind: one of the ring's SLOP_OS_EVENTS_ kinds, or STORED_START or STORED_INSTANCE.
 */
kind_at :: fn(entries: u8[], at: usize) -> u16 {
    return cast[ptr[runtime.SlopOsEventsEntry]](address_in(entries, at)).kind
}

/**
 * Get the address of a byte in entries.
 *
 * @param entries The entries the byte is in; only their start is used, none of them read.
 * @param at The byte's offset, not checked.
 * @return Its address, good while entries are.
 */
address_in :: fn(entries: u8[], at: usize) -> uintptr {
    return cast[uintptr](entries.data) + cast[uintptr](at)
}

/**
 * Send the first record of a source at or after a number, at a level or above, if there is one: from its .old file,
 * its file, then memory.
 *
 * @param service The events service's state.
 * @param end The asking client's end, which Found is sent through.
 * @param name The source's name, compared byte for byte with each known source's; read only. None by that name sends
 *     nothing and gives false.
 * @param from The number of the first record wanted, among the source's this boot.
 * @param level The lowest level wanted, a LogLevel.
 * @return True if a record was found and sent; false if there's none yet, or no source of that name, with nothing sent.
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

/**
 * Hold a query until there's a record for it.
 *
 * @param service The events service's state.
 * @param client The asking client, by its index in connected.
 * @param name The source's name, copied; a source of that name needn't exist yet.
 * @param from The number of the first record wanted.
 * @param level The lowest level wanted, a LogLevel.
 * @return True if it's held; false if the name is too long, or there's no room to hold another.
 */
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

/**
 * Answer each held query there's a record for now, and let it go.
 *
 * @param service The events service's state.
 */
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

/**
 * Find the first record of this boot at or after a number, at a level or above, in stored entries.
 *
 * Format strings and schemas are learned on the way, and each StoredStart moves the scan on to its boot and number.
 *
 * @param service The events service's state, which learns the schemas read.
 * @param bytes Entries as they're stored, from a file or memory.
 * @param scan Where the scan is, carried on from what was read before; left at the found record, numbered one past it.
 * @param from The number of the first record wanted.
 * @param level The lowest level wanted, a LogLevel.
 * @return Where the record's entry starts in bytes, or NOWHERE if there's none.
 */
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
                // Without the memory to keep it, its records are shown without their format string
                _ = runtime.array_try_add(&scan.formats, FormatText.{instance = scan.instance, offset = format.offset,
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

/**
 * Send a found record, rendered, its text cut to TEXT_LIMIT bytes.
 *
 * @param service The events service's state.
 * @param end The asking client's end, which Found is sent through.
 * @param bytes The entries the record is in, which the scan's format strings' text is in too.
 * @param at Where the record's entry starts in bytes.
 * @param scan The scan that found it, numbered one past it.
 * @param stored Whether it was read from a file, rather than memory.
 */
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

/**
 * Read a source's file whole.
 *
 * @param service The events service's state, its directory given by Store.
 * @param source The source whose file is read, named by its name and the extension; only read.
 * @param extension The file's extension: ".events" or ".old".
 * @param into Where its bytes are added, at the end; part of them may be there when it fails.
 * @return True if it was read whole; false if it isn't there, a read failed, or there's no memory for it.
 */
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
        if runtime.array_try_reserve(into, into.count + cast[usize](count)) != null {
            return false
        }
        for i in cast[usize](0)..<count {
            if i < buffer.count {
                runtime.array_add(into, buffer[i])
            }
        }
    }
}
