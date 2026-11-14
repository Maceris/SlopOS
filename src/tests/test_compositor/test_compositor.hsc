/**
 * The compositor's test client (decisions/0192, 15c): started by the supervisor with test_compositor on the kernel's
 * command line, it connects to the compositor twice, as two clients, A and B, each with a window of its own colour,
 * and logs what each is given, for boot.py to drive and check:
 *
 * - "windows shown" once both are on the screen, A red and B blue, B over A and focused;
 * - "<A or B> typed <text>" for each key its window is given, which only the focused window's should be;
 * - "<A or B> pressed at <x>, <y>" for a button pressed in its window, in its units;
 * - A copies "from A" the first time it's focused; "<A or B> pasted <text>" for what Ctrl+Shift+V pastes into it.
 *
 * Neither client holds anything of the other's: their buffers are memory each made, given only to the compositor.
 * It runs until the system stops.
 */
package test_compositor

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import connector from "../../protocols/connector"
import surface from "../../protocols/surface"
import service_kit from "../../libraries/service_kit"

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
main :: fn(log: slop_os.DebugLog?, compositor: os.Channel[connector.Connector]?) -> int {
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
    // A's second frame, from a second buffer: its first comes back once it's shown
    if give_buffer(a, BUFFER + 1, 0, 0, 255) {
        out := os.Outgoing.{}
        request :: os.begin[surface.Request](&out)
        request^ = .Submit(surface.Submission.{surface = a.window, buffer = BUFFER + 1, damage = surface.Rect.{width = WIDTH, height = HEIGHT},
            mode = .Fifo})
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
 * Connect a client, and make and show its window, filled with a colour.
 *
 * @param dialing The connector to the compositor.
 * @param first Whether it's A, the first; B otherwise. Its name is its window's title.
 * @param blue The colour's blue, 0 to 255.
 * @param green Its green.
 * @param red Its red.
 * @return The client, on the heap, its window submitted and a Read held; null if any of it failed.
 */
open :: fn(dialing: os.Channel[connector.Connector], first: bool, blue: u8, green: u8, red: u8) -> ptr[mut Client]? {
    startup :: slop_os.startup_block()
    dial_port :: os.port_for(startup.budget, dialing.end) or_return null
    defer slop_os.handle_close(cast[slop_os.Handle](dial_port))
    channel :: connector.dial[surface.Surface](dialing.end, dial_port) or_return null
    client :: runtime.new(Client)
    client.name = if first { "A" } else { "B" }
    client.end = channel.end
    client.port = os.port_for(startup.budget, channel.end) or_return null

    out := os.Outgoing.{}
    request :: os.begin[surface.Request](&out)
    request^ = .CreateWindow(surface.WindowSpec.{width = WIDTH, height = HEIGHT, scale = surface.SCALE_ONE, color = .Srgb,
        title = os.append(&out, string_bytes(client.name))})
    match ask(client, &out) {
        case Created(id) => client.window = id
        case _ => return null
    }

    if !give_buffer(client, BUFFER, blue, green, red) {
        return null
    }
    submitted := os.Outgoing.{}
    submitting :: os.begin[surface.Request](&submitted)
    submitting^ = .Submit(surface.Submission.{surface = client.window, buffer = BUFFER,
        damage = surface.Rect.{width = WIDTH, height = HEIGHT}, mode = .Fifo})
    if surface.send_request(client.end, client.port, &submitted) is_some {
        return null
    }
    read_more(client)
    return client
}

/** Make a buffer of the window's size filled with a colour, and give it to the compositor by an id. */
give_buffer :: fn(client: ptr[mut Client], id: u32, blue: u8, green: u8, red: u8) -> bool {
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
        pixels[at] = if channel == 0 { blue } else if channel == 1 { green } else if channel == 2 { red } else { cast[u8](255) }
    }
    added := os.Outgoing.{}
    adding :: os.begin[surface.Request](&added)
    adding^ = .AddBuffer(surface.NewBuffer.{id = id, memory = memory, description = surface.BufferDescription.{
        format = surface.FORMAT_XRGB8888, modifier = surface.MODIFIER_LINEAR, width = WIDTH, height = HEIGHT, plane_count = 1,
        planes = surface.Plane.[surface.Plane.{stride = 4 * WIDTH}, surface.Plane.{}, surface.Plane.{}]}})
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
ask :: fn(client: ptr[mut Client], out: ptr[mut os.Outgoing]) -> surface.Response {
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

/** Hold a Read. */
read_more :: fn(client: ptr[mut Client]) {
    out := os.Outgoing.{}
    request :: os.begin[surface.Request](&out)
    request^ = .Read(surface.MAX_EVENTS)
    _ = surface.send_request(client.end, client.port, &out)
}

/** Take the events a client's been given, logging each, and hold another Read. */
take :: fn(client: ptr[mut Client]) {
    into := os.Incoming.{}
    loop {
        match surface.receive_response(client.end, client.port, &into, false) {
            case Received => {}
            case _ => return void
        }
        match os.message_of[surface.Response](&into)^ {
            case Input(given) => {
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

/** Take one event: logged, A copying the first time it's focused. */
take_event :: fn(client: ptr[mut Client], event: surface.Event, text: string) {
    kind :: surface.kind_of(event) or_return void
    match kind {
        case .Presented => client.shown = true
        case .Released => runtime.log_info("% released buffer %", client.name, event.code)
        case .FocusIn => {
            if client.name == "A" && !client.copied {
                client.copied = true
                out := os.Outgoing.{}
                request :: os.begin[surface.Request](&out)
                request^ = .Copy(surface.Offer.{data = slop_os.memory_create(slop_os.startup_block().budget, 4096)
                    or_else cast[slop_os.Memory](slop_os.NO_HANDLE), text = os.append(&out, string_bytes("from A"))})
                _ = surface.send_request(client.end, client.port, &out)
            }
        }
        case .Key => runtime.log_info("% typed %", client.name, text)
        case .Button => {
            if event.pressed != 0 {
                runtime.log_info("% pressed at %, %", client.name, event.x, event.y)
            }
        }
        case .Paste => runtime.log_info("% pasted %", client.name, text)
        case _ => {}
    }
}
