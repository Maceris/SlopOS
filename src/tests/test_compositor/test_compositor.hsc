/**
 * The compositor's test client (decisions/0192, 15c): started by the supervisor with test_compositor on the kernel's
 * command line, it connects to the compositor twice, as two clients, A and B, each with a window of its own colour,
 * and logs what each is given, for boot.py to drive and check:
 *
 * - "windows shown" once both are on the screen, A red and B blue, B over A and focused;
 * - "<A or B> typed <text>" for each key its window is given, which only the focused window's should be;
 * - "<A or B> pressed at <x>, <y>" for a button pressed in its window, in its units;
 * - A copies "from A" the first time it's pressed, while it's focused, with typed data, "typed from A" (16f);
 *   "<A or B> pasted <text>" for what Ctrl+Shift+V pastes into it, then "<A or B> took typed data: <it>" once it's
 *   taken it (TakePaste), and "<A or B> took it once" when taking it again is refused.
 * - Once both are shown, A says who holds the microphone, which the compositor refuses, as A isn't trusted; then the
 *   trusted connection the supervisor gave it says A does, and then that none does (decisions/0197, N1); the
 *   compositor logs how many windows each marks. Without it, "no trusted connection".
 *
 * Neither client holds anything of the other's: their buffers are memory each made, given only to the compositor.
 * It runs until the system stops.
 */
package test_compositor

import runtime from "base:runtime"
import os from "std:os"
import slop_os from "std:os/slop_os"
import service_kit from "../../libraries/service_kit"
import connector from "../../protocols/connector"
import surface from "../../protocols/surface"

/** Each window's width, in pixels. */
WIDTH : u32 : 300
/** Each window's height, in pixels. */
HEIGHT : u32 : 200
/** The buffer's number, each client's own. */
BUFFER : u32 : 1

/** One of the two clients. */
Client :: struct {
    /** Its name: "A" or "B". */
    name : string,
    /** Its connection to the compositor. */
    end : slop_os.Channel,
    /** The port its connection is bound to. */
    port : slop_os.Port,
    /** Its window's number. */
    window : u32,
    /** Whether a Read is held at the compositor; false once one's answered, or when one couldn't be sent. */
    reading : bool,
    /** Whether its first frame's been shown. */
    shown : bool,
    /** Whether it's copied, which A does when it's first focused. */
    copied : bool,
}

/**
 * Make two clients' windows and log what each is given.
 *
 * @param log The debug log its lines go to.
 * @param compositor A connector to the compositor.
 * @return 2 without the compositor, or when a window can't be made or shown. It doesn't return otherwise.
 */
main :: fn(
    log : slop_os.DebugLog?,
    compositor : os.Channel[connector.Connector]?,
    trusted : os.Channel[surface.Surface]?
) -> int {
    dialing :: compositor or_return 2
    a :: open(dialing, true, 0, 0, 255) or_return 2
    b :: open(dialing, false, 255, 0, 0) or_return 2
    // Shown once each has had its Presented
    loop {
        take(a)
        take(b)
        if a.shown && b.shown {
            break
        }
        packets : slop_os.Packet[4]
        _ = slop_os.port_wait(a.port, packets, (slop_os.clock_monotonic() or_else 0) + 10_000_000)
    }
    runtime.log_info("windows shown")
    /*
     * Who holds the microphone (decisions/0197, N1): said by A, which isn't trusted, it's refused; said on the trusted
     * connection, A's window is marked, and B's, never named, isn't; then nothing's held, and nothing marked
     */
    say_held(a.end, a.port, "B\n")
    match trusted {
        case Some(connection) => {
            match os.port_for(slop_os.startup_block().budget, connection.end) {
                case Some(port) => {
                    say_held(connection.end, port, "A\n")
                    say_held(connection.end, port, "")
                }
                case None => runtime.log_info("no port for the trusted connection")
            }
        }
        case None => runtime.log_info("no trusted connection")
    }
    /*
     * A asks for four more connections: with its own, one past what a client and those it makes hold (16d), so the
     * last is refused, its end closed
     */
    for i in 0..<4 {
        _ = surface.connect(a.end, a.port, slop_os.startup_block().budget)
    }
    // A's second frame, from a second buffer: its first comes back once it's shown
    if give_buffer(a, BUFFER + 1, 0, 0, 255) {
        out := os.Outgoing.{}
        request :: os.begin[surface.Request](&out)
        request^ = .Submit(
            surface.Submission.{
                surface = a.window,
                buffer = BUFFER + 1,
                damage = surface.Rect.{width = WIDTH, height = HEIGHT},
                mode = .Fifo,
            }
        )
        _ = surface.send_request(a.end, a.port, &out)
    }
    loop {
        take(a)
        take(b)
        if service_kit.stopping() {
            return 0
        }
        packets : slop_os.Packet[4]
        _ = slop_os.port_wait(a.port, packets, (slop_os.clock_monotonic() or_else 0) + 10_000_000)
    }
}

/**
 * Say who holds the microphone (MicrophoneHeld), which isn't answered.
 *
 * @param end The connection it's said on.
 * @param port A port bound to end.
 * @param names The holders' names, each ended by a line break; empty for none.
 */
say_held :: fn(end : slop_os.Channel, port : slop_os.Port, names : string) {
    out := os.Outgoing.{}
    request :: os.begin[surface.Request](&out)
    request^ = .MicrophoneHeld(os.append(&out, string_bytes(names)))
    _ = surface.send_request(end, port, &out)
}

/** Send a Name, which isn't answered. */
name_connection :: fn(client : ptr[mut Client], name : string) {
    out := os.Outgoing.{}
    request :: os.begin[surface.Request](&out)
    request^ = .Name(os.append(&out, string_bytes(name)))
    _ = surface.send_request(client.end, client.port, &out)
}

/**
 * Connect a client, and make and show its window, filled with a colour.
 *
 * @param dialing The connector to the compositor.
 * @param first Whether it's A, the first; B otherwise. Its name is its window's title, and A's connection is named
 *     "A" too, then named again, which is refused.
 * @param blue The colour's blue, 0 to 255.
 * @param green Its green.
 * @param red Its red.
 * @return The client, on the heap, its window submitted and a Read held; null if any of it failed.
 */
open :: fn(
    dialing : os.Channel[connector.Connector],
    first : bool,
    blue : u8,
    green : u8,
    red : u8
) -> ptr[mut Client]? {
    startup :: slop_os.startup_block()
    dial_port :: os.port_for(startup.budget, dialing.end) or_return null
    defer slop_os.handle_close(cast[slop_os.Handle](dial_port))
    channel :: connector.dial[surface.Surface](dialing.end, dial_port) or_return null
    client :: runtime.new(Client)
    client.name = if first { "A" } else { "B" }
    client.end = channel.end
    client.port = os.port_for(startup.budget, channel.end) or_return null
    /*
     * A names its connection, as whoever dials does for the program it's for, by its first request; then tries to
     * name it again, which is refused. B names it nothing, so its band has its title alone.
     */
    if first {
        name_connection(client, "A")
        name_connection(client, "spoofed")
    }

    out := os.Outgoing.{}
    request :: os.begin[surface.Request](&out)
    request^ = .CreateWindow(
        surface.WindowSpec.{
            width = WIDTH,
            height = HEIGHT,
            scale = surface.SCALE_ONE,
            color = .Srgb,
            title = os.append(&out, string_bytes(client.name)),
        }
    )
    match ask(client, &out) {
        case Created(id) => client.window = id
        case _ => return null
    }

    if !give_buffer(client, BUFFER, blue, green, red) {
        return null
    }
    submitted := os.Outgoing.{}
    submitting :: os.begin[surface.Request](&submitted)
    submitting^ = .Submit(
        surface.Submission.{
            surface = client.window,
            buffer = BUFFER,
            damage = surface.Rect.{width = WIDTH, height = HEIGHT},
            mode = .Fifo,
        }
    )
    if surface.send_request(client.end, client.port, &submitted) is_some {
        return null
    }
    read_more(client)
    return client
}

/** Make a buffer of the window's size filled with a colour, and give it to the compositor by an id. */
give_buffer :: fn(client : ptr[mut Client], id : u32, blue : u8, green : u8, red : u8) -> bool {
    startup :: slop_os.startup_block()
    bytes :: cast[u64](4 * WIDTH * HEIGHT)
    size :: (bytes + 4095) / 4096 * 4096
    memory :: slop_os.memory_create(startup.budget, size) or_return false
    address :: runtime.reserve_addresses(cast[usize](size)) or_return false
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    if slop_os.memory_map(memory, startup.space, address, 0, size, read_write) is_error {
        return false
    }
    pixels :: view_of(cast[ptr[mut u8]](address), cast[usize](bytes))
    for at in cast[usize](0)..<pixels.count {
        channel :: at % 4
        pixels[at] = if channel == 0 {
            blue
        }
        else if channel == 1 { green } else if channel == 2 { red } else { cast[u8](255) }
    }
    added := os.Outgoing.{}
    adding :: os.begin[surface.Request](&added)
    adding^ = .AddBuffer(
        surface.NewBuffer.{
            id = id,
            memory = memory,
            description = surface.BufferDescription.{
                format = surface.FORMAT_XRGB8888,
                modifier = surface.MODIFIER_LINEAR,
                width = WIDTH,
                height = HEIGHT,
                plane_count = 1,
                planes = surface.Plane.[surface.Plane.{stride = 4 * WIDTH}, surface.Plane.{}, surface.Plane.{}],
            },
        }
    )
    match ask(client, &added) {
        case Added(_) => return true
        case _ => return false
    }
}

/**
 * Send a request and wait for its answer, events that come first taken as they would be.
 *
 * @return The answer; Unsupported if it couldn't be sent, or the connection failed.
 */
ask :: fn(client : ptr[mut Client], out : ptr[mut os.Outgoing]) -> surface.Response {
    if surface.send_request(client.end, client.port, out) is_some {
        return .Unsupported
    }
    into := os.Incoming.{}
    match surface.receive_response(client.end, client.port, &into, true) {
        case Received => {}
        case _ => return .Unsupported
    }
    return os.message_of[surface.Response](&into)^
}

/** Hold a Read, unless one's held; reading says whether it went, so one that couldn't be sent is sent again. */
read_more :: fn(client : ptr[mut Client]) {
    if client.reading {
        return void
    }
    out := os.Outgoing.{}
    request :: os.begin[surface.Request](&out)
    request^ = .Read(surface.MAX_EVENTS)
    client.reading = surface.send_request(client.end, client.port, &out) is_none
}

/** Take the events a client's been given, logging each, and hold another Read. */
take :: fn(client : ptr[mut Client]) {
    into := os.Incoming.{}
    loop {
        match surface.receive_response(client.end, client.port, &into, false) {
            case Received => {}
            case _ => {
                // A Read that couldn't be sent, as when the ring was full, sent again
                read_more(client)
                return void
            }
        }
        match os.message_of[surface.Response](&into)^ {
            case Input(given) => {
                client.reading = false
                text :: os.items(&into, given.text)
                for event in os.items(&into, given.events) {
                    start :: cast[usize](event.text_start)
                    end :: start + cast[usize](event.text_bytes)
                    typed :: if start < end && end <= text.count { string_of(&text[start], end - start) } else { "" }
                    take_event(client, event, typed)
                }
                read_more(client)
            }
            case _ => {}
        }
    }
}

/**
 * Take one event: logged, A copying the first time it's pressed, as a program copies on the user's gesture, while
 * it's focused, the only time the compositor takes a copy.
 */
take_event :: fn(client : ptr[mut Client], event : surface.Event, text : string) {
    kind :: surface.kind_of(event) or_return void
    match kind {
        case .Presented => client.shown = true
        case .Released => runtime.log_info("% released buffer %", client.name, event.code)
        case .Button => {
            if event.pressed != 0 {
                runtime.log_info("% pressed at %, %", client.name, event.x, event.y)
            }
            if event.pressed != 0 && client.name == "A" && !client.copied {
                client.copied = true
                typed :: string_bytes("typed from A")
                data :: slop_os.memory_create(slop_os.startup_block().budget, 4096)
                    or_else cast[slop_os.Memory](slop_os.NO_HANDLE)
                _ = slop_os.memory_write(data, 0, typed)
                schema : u8[32]
                for &byte in schema {
                    byte^ = 0x5a
                }
                out := os.Outgoing.{}
                request :: os.begin[surface.Request](&out)
                request^ = .Copy(
                    surface.Offer.{
                        schema = schema,
                        data = data,
                        bytes = cast[u64](typed.count),
                        text = os.append(&out, string_bytes("from A")),
                    }
                )
                _ = surface.send_request(client.end, client.port, &out)
            }
        }
        case .Key => runtime.log_info("% typed %", client.name, text)
        case .Paste => {
            runtime.log_info("% pasted %", client.name, text)
            if event.code == 1 {
                take_typed(client)
            }
        }
        case _ => {}
    }
}

/**
 * Take a paste's typed data (TakePaste), and log it; then ask again, which is refused, as it's given once. No Read's
 * held meanwhile: the events are taken, the answer to the last.
 */
take_typed :: fn(client : ptr[mut Client]) {
    out := os.Outgoing.{}
    os.begin[surface.Request](&out)^ = .TakePaste
    match ask(client, &out) {
        case Pasted(given) => {
            defer slop_os.handle_close(cast[slop_os.Handle](given.data))
            storage : u8[64]
            if given.bytes > 0 && given.bytes <= cast[u64](storage.count) && given.schema[0] == 0x5a {
                kept :: storage[0..<cast[usize](given.bytes)]
                if slop_os.memory_read(given.data, 0, kept) is_ok {
                    runtime.log_info("% took typed data: %", client.name, string_of(&kept[0], kept.count))
                }
            }
        }
        case _ => runtime.log_info("% couldn't take typed data", client.name)
    }
    again := os.Outgoing.{}
    os.begin[surface.Request](&again)^ = .TakePaste
    match ask(client, &again) {
        case Refused(_) => runtime.log_info("% took it once", client.name)
        case _ => runtime.log_info("% took it twice", client.name)
    }
}
