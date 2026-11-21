/**
 * A window on the compositor for a program drawn with std/ui (decisions/0192, 15e): the surface protocol's connection,
 * a window and its two buffers, the compositor's events turned into std/ui's input, and each frame painted into the
 * buffer the compositor isn't reading, over the damage that buffer missed, and submitted.
 *
 * A program opens a window, then loops: wait for something to happen, take what the compositor sent (take), and if
 * anything did, run a frame (begin, its widgets, finish). What a frame copies is offered to the compositor to paste.
 */
package gui_kit

import runtime from "base:runtime"
import canvas from "std:canvas"
import os from "std:os"
import slop_os from "std:os/slop_os"
import terminal from "std:os/slop_os/terminal"
import ui from "std:ui"
import log_line from "../log_line"
import connector from "../protocols/connector"
import surface from "../protocols/surface"

/** How long a frame waits for the compositor to release a buffer, in nanoseconds: 200 milliseconds. */
WAIT_FOR_BUFFER : u64 : 200_000_000
/**
 * How long wait waits, in nanoseconds, while a Read for the window's events couldn't be sent, before it's tried again:
 * 10 ms.
 */
READ_RETRY : u64 : 10_000_000

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

/** A key or text typed, waiting for a frame. */
Queued :: struct {
    /** Whether it's a key std/ui reads; text typed otherwise. */
    is_key : bool,
    /** For a key, which. */
    key : ui.Key,
    /** For a key, whether Shift was held. */
    shift : bool,
    /** For text, where its bytes start in the window's typed. */
    text_start : u32,
    /** For text, how many bytes. */
    text_bytes : u32,
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
    /**
     * The keys and typed text waiting for a frame, in the order they came; a frame takes them up to a key that follows
     * text, as std/ui applies a frame's keys before its text.
     */
    queued : Queued[..],
    /** The queued text's bytes, which each Queued's text_start indexes. */
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
    /**
     * Whether a Read is held at the compositor, for its events: false once one's answered, or when sending one failed,
     * as when its ring was full, so it's sent again (read_more) rather than the window hearing nothing more.
     */
    reading : bool,
    /** The buffer given to the compositor longest ago, drawn into when neither's been released. */
    oldest : usize,
    /**
     * For the input-to-photon latency: the earliest time a key taken since the last frame submitted was taken from its
     * device, in the monotonic clock's nanoseconds; 0 for none, or none that said.
     */
    input_since : u64,
    /** The same, of the frame submitted with it, until that frame's Presented; 0 for none. */
    presenting_since : u64,
    /**
     * The latency last measured, from a key taken from its device to the frame that showed it presented, in
     * nanoseconds; 0 before any.
     */
    latency_ns : u64,
    /** How many latencies have been measured, so a program sees when there's a new one. */
    latencies : u64,
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
open :: fn(dialer : os.Channel[connector.Connector], title : string, width : u32, height : u32) -> ptr[mut Window]? {
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
 * @param activation The activation token for the user's gesture that asked for it, as the program was given it, which
 *     it presents to take focus when it's first shown; 0 for none, when it takes focus only if nothing has it.
 * @return The window, on the heap, its first frame due; null if anything failed.
 */
open_on :: fn(
    channel : os.Channel[surface.Surface],
    title : string,
    width : u32,
    height : u32,
    activation : u64 = 0
) -> ptr[mut Window]? {
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
    request^ = .CreateWindow(
        surface.WindowSpec.{
            width = width,
            height = height,
            scale = surface.SCALE_ONE,
            color = .Srgb,
            title = os.append(&out, string_bytes(title)),
            activation = activation,
        }
    )
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
ask :: fn(window : ptr[mut Window], out : ptr[mut os.Outgoing]) -> surface.Response {
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
                window.reading = false
                take_input(window, &into, given)
                read_more(window)
            }
            case _ => return response
        }
    }
}

/** Make a buffer of the window's size in memory of its own, map it, and give it to the compositor. */
add_buffer :: fn(window : ptr[mut Window], index : u32) -> bool {
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
    window.buffers[index].image = canvas.Image.{
        pixels = view_of(cast[ptr[mut u8]](address), cast[usize](bytes)),
        width = cast[usize](window.width),
        height = cast[usize](window.height),
        stride = cast[usize](stride),
    }
    window.buffers[index].stale = canvas.Rect.{x1 = cast[i32](window.width), y1 = cast[i32](window.height)}
    out := os.Outgoing.{}
    request :: os.begin[surface.Request](&out)
    request^ = .AddBuffer(
        surface.NewBuffer.{
            id = index + 1,
            memory = memory,
            description = surface.BufferDescription.{
                format = surface.FORMAT_XRGB8888,
                modifier = surface.MODIFIER_LINEAR,
                width = window.width,
                height = window.height,
                plane_count = 1,
                planes = surface.Plane.[surface.Plane.{stride = stride}, surface.Plane.{}, surface.Plane.{}],
            },
        }
    )
    match ask(window, &out) {
        case Added(_) => return true
        case _ => return false
    }
}

/** Hold a Read for the window's events, unless one's held already; reading says whether it went. */
read_more :: fn(window : ptr[mut Window]) {
    if window.reading {
        return void
    }
    out := os.Outgoing.{}
    request :: os.begin[surface.Request](&out)
    request^ = .Read(surface.MAX_EVENTS)
    window.reading = surface.send_request(window.end, window.port, &out) is_none
}

/**
 * Take what the compositor sent since the last take, without waiting.
 *
 * @param window The window: its input gathers it, and due says whether a frame's needed.
 * @return False once its connection's gone, the compositor with it.
 */
take :: fn(window : ptr[mut Window]) -> bool {
    into := os.Incoming.{}
    loop {
        match surface.receive_response(window.end, window.port, &into, false) {
            case Received => {}
            case Empty => {
                // A Read that couldn't be sent before, tried again
                read_more(window)
                return true
            }
            case _ => return false
        }
        match os.message_of[surface.Response](&into)^ {
            case Input(given) => {
                window.reading = false
                take_input(window, &into, given)
                read_more(window)
            }
            case _ => {}
        }
    }
}

/**
 * Wait until the compositor sends something, or a deadline in the monotonic clock's nanoseconds passes; not at all
 * while a frame's due, as when input's left queued for the next (begin) or what was done in a frame changed what's
 * shown, so it's drawn without waiting for more. A program that leaves due set without drawing, as for a window it
 * keeps hidden, clears it before it waits.
 */
wait :: fn(window : ptr[mut Window], deadline : u64 = slop_os.NO_DEADLINE) {
    /*
     * What came while the port was waited on for something else is taken first: a request sent while the ring was
     * full waits on this port and drops its packets, a message's wake among them, which no packet would bring again.
     * Finding the end empty arms it, so the next message wakes the port.
     */
    _ = take(window)
    if window.due || window.queued.count > 0 {
        return void
    }
    // Without a Read held nothing would come: one's sent again, and while it can't be, it's tried again soon
    read_more(window)
    until := deadline
    if !window.reading {
        soon :: (slop_os.clock_monotonic() or_else 0) + READ_RETRY
        until = if soon < deadline { soon } else { deadline }
    }
    packets : slop_os.Packet[4]
    _ = slop_os.port_wait(window.port, packets, until)
}

/** HID usages of the keys std/ui reads, and what each is. */
KEYS :: KeyUsage.[
    KeyUsage.{usage = 0x50, key = .Left},
    KeyUsage.{usage = 0x4f, key = .Right},
    KeyUsage.{usage = 0x52, key = .Up},
    KeyUsage.{usage = 0x51, key = .Down},
    KeyUsage.{usage = 0x4a, key = .Home},
    KeyUsage.{usage = 0x4d, key = .End},
    KeyUsage.{usage = 0x2a, key = .Backspace},
    KeyUsage.{usage = 0x4c, key = .Delete},
    KeyUsage.{usage = 0x28, key = .Enter},
    KeyUsage.{usage = 0x2b, key = .Tab},
    KeyUsage.{usage = 0x29, key = .Escape},
    KeyUsage.{usage = 0x4b, key = .PageUp},
    KeyUsage.{usage = 0x4e, key = .PageDown}
]

/** With Ctrl held: the HID usages of the keys std/ui reads, and what each is. */
CONTROL_KEYS :: KeyUsage.[
    KeyUsage.{usage = 0x04, key = .SelectAll},
    KeyUsage.{usage = 0x06, key = .Copy},
    KeyUsage.{usage = 0x1b, key = .Cut},
    KeyUsage.{usage = 0x1d, key = .Undo},
    KeyUsage.{usage = 0x1c, key = .Redo}
]

/** A key's HID usage and the key std/ui knows it as. */
KeyUsage :: struct {
    /** Its HID usage. */
    usage : u32,
    /** What std/ui calls it. */
    key : ui.Key,
}

/** Gather the compositor's events into the window's input. */
take_input :: fn(window : ptr[mut Window], into : ptr[os.Incoming], given : surface.Events) {
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
            case .Presented => {
                if window.presenting_since != 0 && event.time_ns >= window.presenting_since {
                    window.latency_ns = event.time_ns - window.presenting_since
                    window.latencies += 1
                }
                window.presenting_since = 0
            }
            case _ => {}
        }
    }
}

/** A key: kept as it came, and one std/ui reads as a key, or its text typed. */
take_key :: fn(window : ptr[mut Window], event : surface.Event, text : u8[]) {
    if event.time_ns != 0 && (window.input_since == 0 || event.time_ns < window.input_since) {
        window.input_since = event.time_ns
    }
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
            runtime.array_add(&window.queued, Queued.{is_key = true, key = known.key, shift = shift})
            return void
        }
    }
    if !control && text.count > 0 {
        runtime.array_add(
            &window.queued,
            Queued.{text_start = cast[u32](window.typed.count), text_bytes = cast[u32](text.count)}
        )
        for byte in text {
            runtime.array_add(&window.typed, byte)
        }
    }
}

/**
 * Begin a frame with what was gathered since the last.
 *
 * The keys and text queued are taken in order, keys then text, up to a key that follows text: std/ui applies a frame's
 * keys before its text, so text typed before a Tab goes in the field it was typed in; and up to and including a Tab or
 * Enter, as std/ui moves focus for all of a frame's Tabs before it acts on Enter. What's left waits for the next frame,
 * which is then due.
 *
 * @param window The window.
 * @return Its UI, for the frame's widgets; finish ends the frame.
 */
begin :: fn(window : ptr[mut Window]) -> ptr[mut ui.Ui] {
    input := window.input
    input.key_count = 0
    text : u8[..]
    defer runtime.array_free(&text)
    typed :: window.typed[0..<window.typed.count]
    taken := cast[usize](0)
    for each in window.queued {
        if each.is_key {
            if text.count > 0 || input.key_count >= ui.MAX_KEYS {
                break
            }
            ui.press_key(&input, each.key, each.shift)
            /*
             * A Tab or Enter ends the frame's keys: std/ui moves focus for every Tab first, then acts on Enter wherever
             * focus ended, so Tab, Enter, Tab in one frame would lose the first Enter. What comes after waits for the
             * next frame, which is due.
             */
            if each.key == .Tab || each.key == .Enter {
                taken += 1
                break
            }
        }
        else {
            start :: cast[usize](each.text_start)
            end :: start + cast[usize](each.text_bytes)
            if start <= end && end <= typed.count {
                for byte in typed[start..<end] {
                    runtime.array_add(&text, byte)
                }
            }
        }
        taken += 1
    }
    input.text = text[0..<text.count]
    input.pasted = window.pasted[0..<window.pasted.count]
    ui.begin(&window.ui, input, cast[f32](window.width), cast[f32](window.height))
    // What happened is the frame's now: transitions and what was taken; the pointer and button kept
    window.input.pressed = false
    window.input.released = false
    window.input.wheel = 0
    for i in cast[usize](0)..<taken {
        if window.queued.count > 0 {
            runtime.array_remove(&window.queued, 0)
        }
    }
    if window.queued.count == 0 {
        runtime.array_reset(&window.typed)
    }
    runtime.array_reset(&window.pasted)
    window.due = window.queued.count > 0
    return &window.ui
}

/**
 * Finish a frame: laid out, painted into a buffer the compositor isn't reading over what it missed, and submitted with
 * its damage; text it copied offered to be pasted.
 *
 * Painting waits a little for a buffer to be released, if both are busy, then paints the one given longest ago. A
 * frame that changes nothing isn't painted or submitted, and doesn't wait.
 *
 * @param window The window.
 * @return The frame's events, until the next begin.
 */
finish :: fn(window : ptr[mut Window]) -> ui.Event[] {
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
    /*
     * Nothing changed: what's on the screen, the buffer submitted last, is the frame already. What the other missed
     * waits for the next frame that changes something, so a frame of a pointer's motion or a Presented doesn't wait
     * for a buffer to paint nothing new
     */
    if canvas.is_empty(frame.damage) {
        // Input that changed nothing shows nothing, so no latency is measured for it
        window.input_since = 0
        return ui.events_of(&window.ui)
    }
    /*
     * A buffer the compositor's done with; waited for a little, then the one given it longest ago drawn into anyway: at
     * worst what's on the screen shows part of a frame a moment, never a window that stops. The buffers are looked at
     * after each wait, the last one's too
     */
    free := cast[usize](2)
    deadline :: (slop_os.clock_monotonic() or_else 0) + WAIT_FOR_BUFFER
    for step in cast[usize](0)..<100 {
        for buffer, i in window.buffers {
            if !buffer.busy && free == 2 {
                free = i
            }
        }
        if free < 2 || (slop_os.clock_monotonic() or_else 0) >= deadline || !take(window) {
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
    request^ = .Submit(
        surface.Submission.{
            surface = window.surface,
            buffer = cast[u32](free) + 1,
            mode = .Fifo,
            damage = surface.Rect.{
                x = region.x0,
                y = region.y0,
                width = cast[u32](region.x1 - region.x0),
                height = cast[u32](region.y1 - region.y0),
            },
        }
    )
    /*
     * Its input's latency is measured at its Presented; input while an earlier frame's still to be presented waits for
     * the frame after that one
     */
    if surface.send_request(window.end, window.port, &out) == null
        && window.input_since != 0
        && window.presenting_since == 0 {
        window.presenting_since = window.input_since
        window.input_since = 0
    }
    return ui.events_of(&window.ui)
}

/**
 * Ask the compositor for an activation token for the user's gesture in the window a moment ago, as a program does
 * that's about to start another, or open a window, the user asked for (the surface protocol's Activation).
 *
 * @param window The window, whose connection asks.
 * @return The token, to give with what's started; 0 when there's been no gesture, or its token was given already.
 */
token :: fn(window : ptr[mut Window]) -> u64 {
    out := os.Outgoing.{}
    os.begin[surface.Request](&out)^ = .Activation
    return match ask(window, &out) {
        case Token(value) => value
        case _ => cast[u64](0)
    }
}

/** A rectangle grown to take in another. */
grown :: fn(a : canvas.Rect, b : canvas.Rect) -> canvas.Rect {
    if canvas.is_empty(b) {
        return a
    }
    return if canvas.is_empty(a) { b } else { canvas.union_of(a, b) }
}

/** Offer text to be pasted, as plain text, with no typed data. */
offer :: fn(window : ptr[mut Window], text : u8[]) {
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
hide :: fn(window : ptr[mut Window]) {
    out := os.Outgoing.{}
    request :: os.begin[surface.Request](&out)
    request^ = .Submit(surface.Submission.{surface = window.surface, buffer = 0, mode = .Fifo})
    _ = surface.send_request(window.end, window.port, &out)
    for &buffer in window.buffers {
        buffer.stale = canvas.Rect.{x1 = cast[i32](window.width), y1 = cast[i32](window.height)}
    }
}

/** Empty the raw keys, once a program's taken them. */
take_keys :: fn(window : ptr[mut Window]) {
    runtime.array_reset(&window.raw_keys)
    runtime.array_reset(&window.raw_text)
}

/**
 * Write a line in the kernel's log through a GUI program's log grant, as the first services' lines are (log_line). A
 * program the launcher starts has no events ring, so base's logger's lines go nowhere; these reach the serial log.
 *
 * @param log The program's log grant, which it keeps; null writes nothing.
 * @param format The line, its program's name first ("viewer: ..."), each % replaced by the next of values.
 * @param values The values for format's placeholders, in order.
 */
log_to :: fn(log : slop_os.DebugLog?, format : string, values : any...) {
    match log {
        case Some(given) => log_line.write(given, format, values)
        case None => {}
    }
}

/** The most bytes of the text label_of and button_of join; past them, it's cut. */
JOINED_BYTES :: 512

/**
 * A label of several pieces of text, one after the other, joined on the stack, as std/ui copies a label's text into
 * its frame: nothing's left on the heap, however many frames are drawn.
 *
 * @param u The UI.
 * @param parts The pieces, in order; what's past JOINED_BYTES is cut.
 * @param style The label's style.
 * @return The label's ID.
 */
label_of :: fn(u : ptr[mut ui.Ui], parts : string[], style : ui.TextStyle = ui.TextStyle.{}) -> ui.ID {
    storage : u8[JOINED_BYTES]
    count :: join_into(&storage, parts)
    return ui.label(u, if count > 0 { string_of(&storage[0], count) } else { "" }, style)
}

/**
 * A button of several pieces of text, joined as label_of joins them.
 *
 * @param u The UI.
 * @param parts The pieces, in order; what's past JOINED_BYTES is cut.
 * @param key Mixed into its ID, to tell apart buttons of one text under one parent.
 * @return Whether it was clicked this frame (std/ui's button).
 */
button_of :: fn(u : ptr[mut ui.Ui], parts : string[], key : u64 = 0) -> bool {
    storage : u8[JOINED_BYTES]
    count :: join_into(&storage, parts)
    return ui.button(u, if count > 0 { string_of(&storage[0], count) } else { "" }, key = key)
}

/** Join text into storage, cut at its end, but never inside a character; how many bytes it holds. */
join_into :: fn(storage : ptr[mut u8[JOINED_BYTES]], parts : string[]) -> usize {
    count := cast[usize](0)
    cut := false
    for part in parts {
        for byte in string_bytes(part) {
            if count < storage.count {
                storage[count] = byte
                count += 1
            }
            else {
                cut = true
            }
        }
    }
    if !cut {
        return count
    }
    // Back to the start of the last character, and past it only if it's whole
    start := count
    loop {
        if start == 0 || count - start >= 4 {
            break
        }
        start -= 1
        if start < storage.count && storage[start] & 0xc0 != 0x80 {
            break
        }
    }
    if start >= storage.count {
        return count
    }
    lead :: storage[start]
    length :: if lead < 0x80 {
        cast[usize](1)
    }
    else if lead >= 0xf0 { cast[usize](4) } else if lead >= 0xe0 { cast[usize](3) } else { cast[usize](2) }
    return if start + length <= count { count } else { start }
}
