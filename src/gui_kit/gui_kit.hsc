/**
 * A window on the compositor for a program drawn with std/ui (decisions/0192, 15e): the surface protocol's connection,
 * a window and its two buffers, the compositor's events turned into std/ui's input, and each frame painted into the
 * buffer the compositor isn't reading, over the damage that buffer missed, and submitted.
 *
 * A program opens a window, then loops: wait for something to happen, take what the compositor sent (take), and if
 * anything did, run a frame (begin, its widgets, finish). What a frame copies is offered to the compositor to paste.
 */
package gui_kit

import runtime from "base"
import canvas from "std"
import os from "std"
import ui from "std"
import slop_os from "std/os"
import terminal from "std/os/slop_os"
import connector from "../protocols/connector"
import surface from "../protocols/surface"

/** How long a frame waits for the compositor to release a buffer, in nanoseconds: 200 milliseconds. */
WAIT_FOR_BUFFER : u64 : 200_000_000

/** The typefaces windows are drawn with, Noto Sans and Noto Sans Mono (SIL Open Font License, assets/fonts/OFL.txt). */
SANS :: #file_data("../../assets/fonts/NotoSans-Regular.ttf")
MONO :: #file_data("../../assets/fonts/NotoSansMono-Regular.ttf")

/** One of a window's buffers: its pixels, mapped, and whether the compositor has it. */
Buffer :: struct {
    /** Its pixels, the window's size, XRGB8888. */
    image : canvas.Image,
    /** Whether the compositor has it, until it's Released. */
    busy : bool,
    /** What of it is stale: what changed in the frames since it was last drawn. */
    stale : canvas.Rect,
}

/** A window and what's drawn in it. */
Window :: struct {
    /** Its connection to the compositor. */
    end : slop_os.Channel,
    /** The port its connection is bound to. */
    port : slop_os.Port,
    /** Its surface's number. */
    surface : u32,
    /** Its width, in pixels. */
    width : u32,
    /** Its height, in pixels. */
    height : u32,
    /** Its two buffers, ids 1 and 2. */
    buffers : Buffer[2],
    /** The canvas a frame's painted with. */
    painter : canvas.Canvas,
    /** Its UI. */
    ui : ui.Ui,
    /** The input gathered since the last frame. */
    input : ui.Input,
    /** The text typed since the last frame. */
    typed : u8[..],
    /** The text pasted since the last frame. */
    pasted : u8[..],
    /**
     * Every key since they were last taken, as the compositor gave it, for a program that reads keys itself, as a
     * terminal does: its text_start into raw_text. take_keys empties them; a frame doesn't.
     */
    raw_keys : surface.Event[..],
    /** The raw keys' text. */
    raw_text : u8[..],
    /** Whether something happened since the last frame, so another's due. */
    due : bool,
    /** Whether the user asked to close it. */
    closing : bool,
    /** Whether it has the keyboard's focus. */
    focused : bool,
    /** The buffer given to the compositor longest ago, drawn into when neither's been released. */
    oldest : usize,
}

/**
 * Open a window: a connection dialed through the compositor's connector, a window made, its buffers given, and a Read
 * held for its events.
 *
 * @param dialer A connector to the compositor, kept by the caller.
 * @param title Its title, in its identity band after the program's name.
 * @param width Its width, in pixels.
 * @param height Its height, in pixels.
 * @return The window, on the heap, its first frame due; null if anything failed.
 */
open :: fn(dialer: os.Channel[connector.Connector], title: string, width: u32, height: u32) -> ptr[mut Window]? {
    startup :: slop_os.startup_block()
    dial_port :: os.port_for(startup.budget, dialer.end) or_return null
    defer slop_os.handle_close(cast[slop_os.Handle](dial_port))
    channel :: connector.dial[surface.Surface](dialer.end, dial_port) or_return null
    return open_on(channel, title, width, height)
}

/**
 * Open a window on a connection to the compositor, as a GUI program's given (src/gui_programs).
 *
 * @param channel The connection, which the window keeps.
 * @param title Its title.
 * @param width Its width, in pixels.
 * @param height Its height, in pixels.
 * @return The window, on the heap, its first frame due; null if anything failed.
 */
open_on :: fn(channel: os.Channel[surface.Surface], title: string, width: u32, height: u32) -> ptr[mut Window]? {
    startup :: slop_os.startup_block()
    window :: runtime.new(Window)
    window.end = channel.end
    window.port = os.port_for(startup.budget, channel.end) or_return null
    window.width = width
    window.height = height
    window.ui = ui.make(SANS[0..<SANS.count], MONO[0..<MONO.count])
    window.input = ui.Input.{}
    window.due = true
    out := os.Outgoing.{}
    request :: os.begin[surface.Request](&out)
    request^ = .CreateWindow(surface.WindowSpec.{width = width, height = height, scale = surface.SCALE_ONE, color = .Srgb,
        title = os.append(&out, string_bytes(title))})
    match ask(window, &out) {
        case Created(id) => window.surface = id
        case _ => return null
    }
    for i in cast[u32](0)..<2 {
        if !add_buffer(window, i) {
            return null
        }
    }
    read_more(window)
    return window
}

/** Send a request and wait for its answer, events before it kept for take. */
ask :: fn(window: ptr[mut Window], out: ptr[mut os.Outgoing]) -> surface.Response {
    if surface.send_request(window.end, window.port, out) is_some {
        return .Unsupported
    }
    into := os.Incoming.{}
    loop {
        match surface.receive_response(window.end, window.port, &into, true) {
            case Received => {}
            case _ => return .Unsupported
        }
        response :: os.message_of[surface.Response](&into)^
        match response {
            // An answer to the held Read comes first: taken now, and another held
            case Input(given) => {
                take_input(window, &into, given)
                read_more(window)
            }
            case _ => return response
        }
    }
}

/** Make a buffer of the window's size in memory of its own, map it, and give it to the compositor. */
add_buffer :: fn(window: ptr[mut Window], index: u32) -> bool {
    startup :: slop_os.startup_block()
    stride :: 4 * window.width
    bytes :: cast[u64](stride) * cast[u64](window.height)
    size :: (bytes + 4095) / 4096 * 4096
    memory :: slop_os.memory_create(startup.budget, size) or_return false
    address :: runtime.reserve_addresses(cast[usize](size)) or_return false
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    if slop_os.memory_map(memory, startup.space, address, 0, size, read_write) is_error {
        return false
    }
    if index >= 2 {
        return false
    }
    window.buffers[index].image = canvas.Image.{pixels = view_of(cast[ptr[mut u8]](address), cast[usize](bytes)),
        width = cast[usize](window.width), height = cast[usize](window.height), stride = cast[usize](stride)}
    window.buffers[index].stale = canvas.Rect.{x1 = cast[i32](window.width), y1 = cast[i32](window.height)}
    out := os.Outgoing.{}
    request :: os.begin[surface.Request](&out)
    request^ = .AddBuffer(surface.NewBuffer.{id = index + 1, memory = memory, description = surface.BufferDescription.{
        format = surface.FORMAT_XRGB8888, modifier = surface.MODIFIER_LINEAR, width = window.width, height = window.height,
        plane_count = 1, planes = surface.Plane.[surface.Plane.{stride = stride}, surface.Plane.{}, surface.Plane.{}]}})
    match ask(window, &out) {
        case Added(_) => return true
        case _ => return false
    }
}

/** Hold a Read for the window's events. */
read_more :: fn(window: ptr[mut Window]) {
    out := os.Outgoing.{}
    request :: os.begin[surface.Request](&out)
    request^ = .Read(surface.MAX_EVENTS)
    _ = surface.send_request(window.end, window.port, &out)
}

/**
 * Take what the compositor sent since the last take, without waiting.
 *
 * @param window The window: its input gathers it, and due says whether a frame's needed.
 * @return False once its connection's gone, the compositor with it.
 */
take :: fn(window: ptr[mut Window]) -> bool {
    into := os.Incoming.{}
    loop {
        match surface.receive_response(window.end, window.port, &into, false) {
            case Received => {}
            case Empty => return true
            case _ => return false
        }
        match os.message_of[surface.Response](&into)^ {
            case Input(given) => {
                take_input(window, &into, given)
                read_more(window)
            }
            case _ => {}
        }
    }
}

/** Wait until the compositor sends something, or a deadline in the monotonic clock's nanoseconds passes. */
wait :: fn(window: ptr[mut Window], deadline: u64 = slop_os.NO_DEADLINE) {
    packets : slop_os.Packet[4]
    _ = slop_os.port_wait(window.port, packets, deadline)
}

/** HID usages of the keys std/ui reads, and what each is. */
KEYS :: KeyUsage.[
    KeyUsage.{usage = 0x50, key = .Left}, KeyUsage.{usage = 0x4f, key = .Right}, KeyUsage.{usage = 0x52, key = .Up},
    KeyUsage.{usage = 0x51, key = .Down}, KeyUsage.{usage = 0x4a, key = .Home}, KeyUsage.{usage = 0x4d, key = .End},
    KeyUsage.{usage = 0x2a, key = .Backspace}, KeyUsage.{usage = 0x4c, key = .Delete}, KeyUsage.{usage = 0x28, key = .Enter},
    KeyUsage.{usage = 0x2b, key = .Tab}, KeyUsage.{usage = 0x29, key = .Escape}, KeyUsage.{usage = 0x4b, key = .PageUp},
    KeyUsage.{usage = 0x4e, key = .PageDown},
]

/** With Ctrl held: the HID usages of the keys std/ui reads, and what each is. */
CONTROL_KEYS :: KeyUsage.[
    KeyUsage.{usage = 0x04, key = .SelectAll}, KeyUsage.{usage = 0x06, key = .Copy}, KeyUsage.{usage = 0x1b, key = .Cut},
    KeyUsage.{usage = 0x1d, key = .Undo}, KeyUsage.{usage = 0x1c, key = .Redo},
]

/** A key's HID usage and the key std/ui knows it as. */
KeyUsage :: struct {
    /** Its HID usage. */
    usage : u32,
    /** What std/ui calls it. */
    key : ui.Key,
}

/** Gather the compositor's events into the window's input. */
take_input :: fn(window: ptr[mut Window], into: ptr[os.Incoming], given: surface.Events) {
    text :: os.items(into, given.text)
    for event in os.items(into, given.events) {
        kind :: surface.kind_of(event) or_else surface.EventKind.Released
        start :: cast[usize](event.text_start)
        end :: start + cast[usize](event.text_bytes)
        bytes :: if start <= end && end <= text.count { text[start..<end] } else { text[0..<0] }
        match kind {
            case .Configure => window.due = true
            case .CloseRequested => window.closing = true
            case .FocusIn => {
                window.focused = true
                window.due = true
            }
            case .FocusOut => {
                window.focused = false
                window.due = true
            }
            case .PointerEnter => {
                window.input.pointer_x = cast[f32](event.x)
                window.input.pointer_y = cast[f32](event.y)
                window.due = true
            }
            case .PointerMotion => {
                window.input.pointer_x = cast[f32](event.x)
                window.input.pointer_y = cast[f32](event.y)
                window.due = true
            }
            case .PointerLeave => {
                window.input.pointer_x = -1
                window.input.pointer_y = -1
                window.due = true
            }
            case .Button => {
                if event.code == 0 {
                    window.input.pointer_x = cast[f32](event.x)
                    window.input.pointer_y = cast[f32](event.y)
                    if event.pressed != 0 {
                        window.input.pressed = true
                        window.input.down = true
                    }
                    else {
                        window.input.released = true
                        window.input.down = false
                    }
                    window.due = true
                }
            }
            case .Wheel => {
                window.input.wheel += cast[f32](event.y)
                window.due = true
            }
            case .Key => {
                take_key(window, event, bytes)
                window.due = true
            }
            case .Paste => {
                for byte in bytes {
                    runtime.array_add(&window.pasted, byte)
                }
                window.due = true
            }
            case .Released => {
                index :: event.code - 1
                if index < 2 {
                    window.buffers[index].busy = false
                }
            }
            case _ => {}
        }
    }
}

/** A key: kept as it came, and one std/ui reads as a key, or its text typed. */
take_key :: fn(window: ptr[mut Window], event: surface.Event, text: u8[]) {
    raw := event
    raw.text_start = cast[u32](window.raw_text.count)
    raw.text_bytes = cast[u32](text.count)
    for byte in text {
        runtime.array_add(&window.raw_text, byte)
    }
    runtime.array_add(&window.raw_keys, raw)
    control :: event.modifiers & terminal.CONTROL != 0
    shift :: event.modifiers & terminal.SHIFT != 0
    for known in (if control { CONTROL_KEYS[0..<CONTROL_KEYS.count] } else { KEYS[0..<KEYS.count] }) {
        if known.usage == event.code {
            ui.press_key(&window.input, known.key, shift)
            return void
        }
    }
    if !control {
        for byte in text {
            runtime.array_add(&window.typed, byte)
        }
    }
}

/**
 * Begin a frame with what was gathered since the last.
 *
 * @param window The window.
 * @return Its UI, for the frame's widgets; finish ends the frame.
 */
begin :: fn(window: ptr[mut Window]) -> ptr[mut ui.Ui] {
    input := window.input
    input.text = window.typed[0..<window.typed.count]
    input.pasted = window.pasted[0..<window.pasted.count]
    ui.begin(&window.ui, input, cast[f32](window.width), cast[f32](window.height))
    // What happened is the frame's now: transitions and keys taken, the pointer and button kept
    window.input.pressed = false
    window.input.released = false
    window.input.wheel = 0
    window.input.key_count = 0
    runtime.array_reset(&window.typed)
    runtime.array_reset(&window.pasted)
    window.due = false
    return &window.ui
}

/**
 * Finish a frame: laid out, painted into a buffer the compositor isn't reading over what it missed, and submitted with
 * its damage; text it copied offered to be pasted.
 *
 * Painting waits a little for a buffer to be released, if both are busy, then paints the one given longest ago.
 *
 * @param window The window.
 * @return The frame's events, until the next begin.
 */
finish :: fn(window: ptr[mut Window]) -> ui.Event[] {
    frame :: ui.end(&window.ui)
    for event in ui.events_of(&window.ui) {
        if event.kind == .Copied {
            offer(window, ui.event_text(&window.ui, event))
        }
    }
    // Both buffers miss this frame's damage until each is drawn
    for &buffer in window.buffers {
        buffer.stale = grown(buffer.stale, frame.damage)
    }
    // A buffer the compositor's done with; waited for a little, then the one given it longest ago drawn into anyway: at
    // worst what's on the screen shows part of a frame a moment, never a window that stops
    free := cast[usize](2)
    deadline :: (slop_os.clock_monotonic() or_else 0) + WAIT_FOR_BUFFER
    for step in cast[usize](0)..<100 {
        for buffer, i in window.buffers {
            if !buffer.busy && free == 2 {
                free = i
            }
        }
        if free < 2 || !take(window) || (slop_os.clock_monotonic() or_else 0) >= deadline {
            break
        }
        wait(window, deadline)
    }
    if free >= 2 {
        free = window.oldest
    }
    window.oldest = 1 - free
    buffer :: &window.buffers[free % 2]
    region :: buffer.stale
    if canvas.is_empty(region) {
        return ui.events_of(&window.ui)
    }
    canvas.free_canvas(&window.painter)
    window.painter = canvas.make(buffer.image)
    ui.paint(&window.ui, &window.painter, region)
    buffer.stale = canvas.Rect.{}
    buffer.busy = true
    out := os.Outgoing.{}
    request :: os.begin[surface.Request](&out)
    request^ = .Submit(surface.Submission.{surface = window.surface, buffer = cast[u32](free) + 1, mode = .Fifo,
        damage = surface.Rect.{x = region.x0, y = region.y0, width = cast[u32](region.x1 - region.x0), height = cast[u32](region.y1 - region.y0)}})
    _ = surface.send_request(window.end, window.port, &out)
    return ui.events_of(&window.ui)
}

/** A rectangle grown to take in another. */
grown :: fn(a: canvas.Rect, b: canvas.Rect) -> canvas.Rect {
    if canvas.is_empty(b) {
        return a
    }
    return if canvas.is_empty(a) { b } else { canvas.union_of(a, b) }
}

/** Offer text to be pasted, as plain text, with no typed data. */
offer :: fn(window: ptr[mut Window], text: u8[]) {
    data :: slop_os.memory_create(slop_os.startup_block().budget, 4096) or_return void
    out := os.Outgoing.{}
    request :: os.begin[surface.Request](&out)
    request^ = .Copy(surface.Offer.{data = data, text = os.append(&out, text)})
    _ = surface.send_request(window.end, window.port, &out)
}

/**
 * Hide the window: a submission of no buffer, which takes it off the screen until its next frame's submitted. Its
 * next frame's due, drawn whole.
 *
 * @param window The window.
 */
hide :: fn(window: ptr[mut Window]) {
    out := os.Outgoing.{}
    request :: os.begin[surface.Request](&out)
    request^ = .Submit(surface.Submission.{surface = window.surface, buffer = 0, mode = .Fifo})
    _ = surface.send_request(window.end, window.port, &out)
    for &buffer in window.buffers {
        buffer.stale = canvas.Rect.{x1 = cast[i32](window.width), y1 = cast[i32](window.height)}
    }
}

/** Empty the raw keys, once a program's taken them. */
take_keys :: fn(window: ptr[mut Window]) {
    runtime.array_reset(&window.raw_keys)
    runtime.array_reset(&window.raw_text)
}
