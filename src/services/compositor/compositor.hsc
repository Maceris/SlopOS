/**
 * The compositor (decisions/0192, 15c; design/display.md §2, §3, §5): it draws its clients' windows on the first
 * display, in software, and gives them input from the seat the terminal service lends it.
 *
 * Windows float: each has the identity band above it, which the compositor draws and the client can't draw over,
 * holding its title and a close box. A press on a window raises it and gives it focus; a drag of its band moves it.
 * Keys go to the focused window, and the pointer to the window it's over, in that window's units. Ctrl+Shift+V pastes
 * what was last copied into the focused window: paste is a gesture the compositor sees, never a client's to take.
 *
 * Each frame is drawn into the display's buffer that isn't shown, over the damage of this frame and the one before,
 * which is what that buffer missed, and presented with it. A client's buffer is read while it's shown, and released
 * once another replaces it and the frame without it is on the screen. The pointer is the display's cursor plane.
 *
 * The trusted layer (display.md §5): clients that connect through the trusted listener, which only trusted services
 * are given, as login's, have windows above every other client's, centred, without a band. While one is shown it has
 * the keyboard and the pointer: nothing below it is given input.
 */
package compositor

import intrinsics from "base:intrinsics"
import runtime from "base:runtime"
import canvas from "std:canvas"
import fonts from "std:fonts"
import memory from "std:memory"
import os from "std:os"
import slop_os from "std:os/slop_os"
import terminal from "std:os/slop_os/terminal"
import random from "std:random"
import service_kit from "../../libraries/service_kit"
import connector from "../../protocols/connector"
import display from "../../protocols/display"
import seat from "../../protocols/seat"
import surface from "../../protocols/surface"

/** The band's typeface, Noto Sans (SIL Open Font License, assets/fonts/OFL.txt). */
SANS :: #file_data("../../../assets/fonts/NotoSans-Regular.ttf")

/** The identity band's height above each window, in pixels. */
BAND :: 28
/** How far a passive window, an indicator, is from the screen's top and right edges, in pixels. */
PASSIVE_MARGIN : i32 : 16
/** The band's text's size, in pixels to the em. */
BAND_TEXT : f32 : 14
/** The mark on the band of a program holding the microphone, after its name. */
MICROPHONE_MARK :: "Microphone"
/** The close box's side, at the band's right. */
CLOSE :: 16
/** The most windows, of every client together. */
MAX_WINDOWS :: 16
/** The most requests taken from a client in one pass of the main loop, before the others and a frame. */
REQUESTS_PER_PASS :: 32
/** The most connections a client and those it makes hold together, so one can't take every place (16d). */
CONNECTIONS_PER_CLIENT :: 4
/** The most windows a client and its connections hold together. */
WINDOWS_PER_CLIENT :: 8
/** The client places and the windows kept for the trusted listener's clients, the login and the prompts. */
KEPT_FOR_TRUSTED :: 4
/** How long after a gesture its client may ask for its activation token, in nanoseconds: 2 s. */
GESTURE_LIFE : u64 : 2_000_000_000
/** How long a token stays good for a window to present, in nanoseconds: 5 s. */
TOKEN_LIFE : u64 : 5_000_000_000
/** How many tokens are kept at once; the oldest is forgotten for a new one. */
MAX_TOKENS :: 8
/** The most buffers a client has at once. */
MAX_BUFFERS :: 8
/** The most events waiting for a client; past them, the oldest are dropped. */
QUEUED :: 64
/** The most bytes of text waiting for a client. */
QUEUED_TEXT :: 1024
/** The most bytes of a title, or of what's copied, that are kept. */
TITLE_BYTES :: 128
/** The widest or tallest window or buffer, in pixels. */
MOST_PIXELS : u32 : 4096
/** No window: an index past every window's. */
NO_WINDOW : usize : MAX_WINDOWS
/** The port key the seat's channel is bound at, past every client's index. */
SEAT_KEY : u64 : 1000
/** The HID usage of V. */
USAGE_V : u16 : 0x19

/** A buffer a client gave, mapped read-only. */
ClientBuffer :: struct {
    /** The client's number for it; 0 for a free place. */
    id : u32,
    /** Its memory, the compositor's since AddBuffer. */
    memory : slop_os.Memory,
    /** Where it's mapped. */
    address : u64,
    /** How many bytes are mapped there. */
    bytes : u64,
    /** Addresses kept for a buffer here, reused by the next that fits: where they start. */
    reserved : u64,
    /** How many bytes are kept at reserved. */
    reserved_bytes : u64,
    /** Its format, surface.FORMAT_XRGB8888 or FORMAT_ARGB8888. */
    format : u32,
    /** Its width in pixels. */
    width : u32,
    /** Its height in pixels. */
    height : u32,
    /** The bytes from one row to the next. */
    stride : u32,
    /** Where its first row is in its memory. */
    offset : u64,
}

/** What the compositor keeps for each client. */
ClientState :: struct {
    /** Its buffers. */
    buffers : ClientBuffer[MAX_BUFFERS],
    /** Its events waiting, the first count of them, oldest first. */
    events : surface.Event[QUEUED],
    /** How many of events are waiting. */
    count #at_most(events.count) : usize,
    /** The waiting events' text. */
    text : u8[QUEUED_TEXT],
    /** How many of text's bytes are in use. */
    text_count #at_most(text.count) : usize,
    /** How many events its held Read asks for; 0 for none held. */
    held : u32,
    /** The number its next surface gets, from 1. */
    next_surface : u32,
    /** Whether it connected through the trusted listener, its windows then the trusted layer's. */
    trusted : bool,
    /**
     * Whether it's one of the listeners a dialer reaches the compositor through, whose Connects make unnamed
     * connections for the dialer to name; a client's Connects make connections with its own name.
     */
    listener : bool,
    /**
     * Whether its name is settled: once its first request's been taken, a Name or anything else, or from its maker's
     * for one made by Connect. A Name after that is refused, so a program can't name itself what it isn't.
     */
    named : bool,
    /**
     * The client its places are counted against: the connection its dialer made, which the connections it makes
     * share (CONNECTIONS_PER_CLIENT, WINDOWS_PER_CLIENT).
     */
    root : usize,
    /** Its program's name, as its dialer named it (Name), the first name_count bytes; none when it wasn't. */
    name : u8[surface.NAME_BYTES],
    /** How many of name's bytes are used. */
    name_count #at_most(name.count) : usize,
}

/** An activation token given for a gesture, until a window presents it or it's too old. */
ActivationToken :: struct {
    /** Its value, never 0; 0 for a place not in use. */
    value : u64,
    /** When it was given, in the monotonic clock's nanoseconds. */
    at : u64,
}

/** A window. */
Window :: struct {
    /** Whether the place is in use. */
    used : bool,
    /** Its client, by index. */
    client : usize,
    /** The client's number for it. */
    surface : u32,
    /** Its content's left edge on the screen; its band is above it. */
    x : i32,
    /** Its content's top edge on the screen. */
    y : i32,
    /** Its width in pixels. */
    width : u32,
    /** Its height in pixels, below its band. */
    height : u32,
    /** The buffer it shows, the client's number for it; 0 for none yet. */
    buffer : u32,
    /** A buffer it showed before, released once a frame without it is shown; 0 for none. */
    replaced : u32,
    /** Whether a frame of it waits to be shown, for its Presented. */
    submitted : bool,
    /** Whether it's in the trusted layer, above every other client's, without a band. */
    trusted : bool,
    /**
     * Whether it's a trusted window that's passive, an indicator: never focused, and not keeping other windows from
     * input while it's shown (WindowSpec's passive).
     */
    passive : bool,
    /**
     * Whether it's been shown before, so showing it again doesn't take focus: hidden and shown again, a client's
     * window could otherwise take the keyboard, and what the user types elsewhere, whenever it liked.
     */
    shown_before : bool,
    /**
     * When the activation token it presented was given, in the monotonic clock's nanoseconds, if it was good; 0 for
     * none. It takes focus when it's first shown only while that's within TOKEN_LIFE, so a window made with a token
     * and shown long after can't take the keys then (16g).
     */
    activated_at : u64,
    /** Whether it's waiting for the user: shown without focus when it asked for it, its band marked, until chosen. */
    attention : bool,
    /** Its title, the first title_count bytes. */
    title : u8[TITLE_BYTES],
    /** How many of title's bytes it has. */
    title_count #at_most(title.count) : usize,
}

/** The compositor's state, on the heap. */
Compositor :: struct {
    /** The port its clients and the seat are bound to. */
    port : slop_os.Port,
    /** Whether a client was cut short at REQUESTS_PER_PASS this pass, so every client's served again before a wait. */
    cut_short : bool,
    /** The client the user's last gesture (a key or a button pressed) went to, for its activation token. */
    gesture_client : usize,
    /** When it was, in the monotonic clock's nanoseconds; 0 for none. */
    gesture_at : u64,
    /** Whether its token's been given already: one a gesture. */
    gesture_given : bool,
    /** The tokens given, for windows to present (WindowSpec.activation). */
    tokens : ActivationToken[MAX_TOKENS],
    /** The display's channel. */
    display_end : slop_os.Channel,
    /** The port the display's answers come to. */
    display_port : slop_os.Port,
    /** What the display is. */
    info : display.Info,
    /** The display's scanout buffers, mapped. */
    frames : canvas.Image[2],
    /** The buffer shown. */
    shown : u32,
    /** The cursor's buffer, mapped; empty without a cursor plane. */
    cursor : canvas.Image,
    /** The canvas the frame's drawn with. */
    painter : canvas.Canvas,
    /** The seat's channel, as the input service lends it; NO_HANDLE without one. */
    seat_end : slop_os.Channel,
    /** Its clients, the listener among them. */
    clients : service_kit.Clients,
    /** Each client's state, by index. */
    states : ClientState[service_kit.MAX_CLIENTS],
    /** The windows. */
    windows : Window[MAX_WINDOWS],
    /** The windows in use from the bottom up, by index, the first order_count of them. */
    order : usize[MAX_WINDOWS],
    /** How many windows are in order. */
    order_count #at_most(order.count) : usize,
    /** The focused window, or NO_WINDOW. */
    focus : usize,
    /** The window the pointer's over, or NO_WINDOW. */
    hover : usize,
    /** The window a button went down in, which gets it coming up, or NO_WINDOW. */
    grab : usize,
    /** The pointer, across, in pixels. */
    pointer_x : i32,
    /** The pointer, down, in pixels. */
    pointer_y : i32,
    /** The window whose band is being dragged, or NO_WINDOW. */
    dragging : usize,
    /** Where in the dragged window's band the pointer went down, across from its left. */
    drag_x : i32,
    /** Where in the dragged window's band it went down, from the content's top (negative, in the band). */
    drag_y : i32,
    /**
     * The programs holding the microphone, as the trusted path last said (MicrophoneHeld): names each ended by a line
     * break, the first held_count bytes. Their windows' bands are marked.
     */
    held : u8[surface.MAX_HELD_BYTES],
    /** How many of held's bytes are in use. */
    held_count #at_most(held.count) : usize,
    /** What changed since the last frame, on the screen. */
    damage : canvas.Rect,
    /** What changed for the last frame. */
    last_damage : canvas.Rect,
    /** What was copied last, as text, the first clipboard_count bytes. */
    clipboard : u8[TITLE_BYTES],
    /** How many bytes of clipboard there are. */
    clipboard_count #at_most(clipboard.count) : usize,
    /**
     * What was copied last as typed data (decisions/0193, 16f): the compositor's own copy, paste_bytes of it, its
     * schema's hash paste_schema; nothing while paste_bytes is 0.
     */
    paste_data : slop_os.Memory,
    /** How many bytes of paste_data are the data's; 0 for none. */
    paste_bytes : u64,
    /** The typed data's schema's hash. */
    paste_schema : u8[32],
    /** The client last given a Paste with typed data, which may take it (TakePaste). */
    paste_client : usize,
    /** When, in the monotonic clock's nanoseconds; 0 when there's none to take, or it's been taken. */
    paste_at : u64,
}

/**
 * Composite the clients' windows on the display, and give them the seat's input.
 *
 * @param log The debug log; its lines go through base's logger instead.
 * @param display_connector A connector to the first display's driver.
 * @param seat_connector A connector to the input service, read as the seat's borrower.
 * @param clients Where the clients' connections arrive.
 * @param trusted Where the trusted layer's clients' connections arrive, only trusted services' (display.md §5); null
 *     for none.
 * @return 2 without a display, or when it can't be dialed, described or its buffers mapped; 3 when the font can't be
 *     read; 99 when its state can't be had. It doesn't return otherwise.
 */
main :: fn(
    log : slop_os.DebugLog?,
    display_connector : os.Channel[connector.Connector]?,
    seat_connector : os.Channel[connector.Connector]?,
    clients : os.Listener[surface.Surface],
    trusted : os.Listener[surface.Surface]?
) -> int {
    startup :: slop_os.startup_block()
    made, error :: runtime.new_aligned(Compositor, align_of(Compositor))
    if error != null {
        return 99
    }
    compositor :: made
    compositor.focus = NO_WINDOW
    compositor.hover = NO_WINDOW
    compositor.grab = NO_WINDOW
    compositor.dragging = NO_WINDOW
    compositor.seat_end = cast[slop_os.Channel](slop_os.NO_HANDLE)
    if fonts.open(SANS[0..<SANS.count]) is_none {
        return 3
    }
    compositor.port = slop_os.port_create(startup.budget) or_return 2
    _ = service_kit.watch_stop(compositor.port)

    // The display: described, its buffers mapped
    dialing :: display_connector or_return 2
    dial_port :: os.port_for(startup.budget, dialing.end) or_return 2
    channel :: connector.dial[display.Display](dialing.end, dial_port) or_return 2
    compositor.display_end = channel.end
    compositor.display_port = os.port_for(startup.budget, channel.end) or_return 2
    match ask(compositor, .Describe) {
        case Described(info) => compositor.info = info
        case _ => return 2
    }
    if compositor.info.buffers < 2 {
        return 2
    }
    for i in cast[u32](0)..<2 {
        compositor.frames[i] = map_frame(compositor, i) or_return 2
    }
    compositor.shown = 0
    compositor.pointer_x = cast[i32](compositor.info.width / 2)
    compositor.pointer_y = cast[i32](compositor.info.height / 2)
    show_pointer(compositor)
    compositor.damage = screen(compositor)

    // The seat, as its borrower
    match seat_connector {
        case Some(dialer) => connect_seat(compositor, dialer)
        case None => {}
    }
    listening :: service_kit.add_client_index(&compositor.clients, compositor.port, clients.end) or_return 2
    if listening < compositor.states.count {
        compositor.states[listening] = ClientState.{next_surface = 1, listener = true}
    }
    match trusted {
        case Some(listener) => {
            match service_kit.add_client_index(&compositor.clients, compositor.port, listener.end) {
                case Some(added) => {
                    if added < compositor.states.count {
                        compositor.states[added] = ClientState.{next_surface = 1, trusted = true, listener = true}
                    }
                }
                case None => {}
            }
        }
        case None => {}
    }
    runtime.log_info("serving % by %", compositor.info.width, compositor.info.height)
    into := os.Incoming.{}
    loop {
        for i in cast[usize](0)..<compositor.clients.count {
            serve(compositor, i, &into)
        }
        take_seat(compositor, &into)
        if !canvas.is_empty(compositor.damage) || any_submitted(compositor) {
            composite(compositor)
        }
        for i in cast[usize](0)..<compositor.clients.count {
            deliver(compositor, i)
        }
        if service_kit.stopping() {
            return 0
        }
        // A client cut short has requests left, with nothing on the port to say so: every client's served again first
        if compositor.cut_short {
            compositor.cut_short = false
            continue
        }
        packets : slop_os.Packet[8]
        _ = slop_os.port_wait(compositor.port, packets, slop_os.NO_DEADLINE)
    }
}

/** The whole screen, as a rectangle. */
screen :: fn(compositor : ptr[Compositor]) -> canvas.Rect {
    return canvas.Rect.{x1 = cast[i32](compositor.info.width), y1 = cast[i32](compositor.info.height)}
}

/**
 * Send the display a request and wait for its answer.
 *
 * @return The answer; Unsupported if it couldn't be sent, or the channel failed.
 */
ask :: fn(compositor : ptr[mut Compositor], request : display.Request) -> display.Response {
    out := os.Outgoing.{}
    begun :: os.begin[display.Request](&out)
    begun^ = request
    if display.send_request(compositor.display_end, compositor.display_port, &out) is_some {
        return .Unsupported
    }
    into := os.Incoming.{}
    match display.receive_response(compositor.display_end, compositor.display_port, &into, true) {
        case Received => {}
        case _ => return .Unsupported
    }
    return os.message_of[display.Response](&into)^
}

/** Send the display a request that isn't answered. */
tell :: fn(compositor : ptr[mut Compositor], request : display.Request) {
    out := os.Outgoing.{}
    begun :: os.begin[display.Request](&out)
    begun^ = request
    _ = display.send_request(compositor.display_end, compositor.display_port, &out)
}

/**
 * Map one of the display's buffers.
 *
 * @return It as an image; null if its window couldn't be had or mapped.
 */
map_frame :: fn(compositor : ptr[mut Compositor], buffer : u32) -> canvas.Image? {
    window :: match ask(compositor, .GetBuffer(buffer)) {
        case Buffer(memory) => memory
        case _ => return null
    }
    info :: compositor.info
    bytes :: cast[u64](info.stride) * cast[u64](info.height)
    mapped :: (bytes + 4095) / 4096 * 4096
    address :: runtime.reserve_addresses(cast[usize](mapped)) or_return null
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    if slop_os.memory_map(window, slop_os.startup_block().space, address, 0, mapped, read_write) is_error {
        return null
    }
    return canvas.Image.{
        pixels = view_of(cast[ptr[mut u8]](address), cast[usize](bytes)),
        width = cast[usize](info.width),
        height = cast[usize](info.height),
        stride = cast[usize](info.stride),
    }
}

/**
 * Draw the pointer's arrow on the cursor plane and show it where the pointer is; without a cursor plane, nothing, the
 * pointer then unseen (a framebuffer's display, 15c's As Built).
 */
show_pointer :: fn(compositor : ptr[mut Compositor]) {
    size :: compositor.info.cursor_size
    if size == 0 {
        return void
    }
    window :: match ask(compositor, .GetBuffer(display.CURSOR_BUFFER)) {
        case Buffer(memory) => memory
        case _ => return void
    }
    bytes :: cast[u64](4 * size * size)
    mapped :: (bytes + 4095) / 4096 * 4096
    address :: runtime.reserve_addresses(cast[usize](mapped)) or_return void
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    if slop_os.memory_map(window, slop_os.startup_block().space, address, 0, mapped, read_write) is_error {
        return void
    }
    compositor.cursor = canvas.Image.{
        pixels = view_of(cast[ptr[mut u8]](address), cast[usize](bytes)),
        width = cast[usize](size),
        height = cast[usize](size),
        stride = cast[usize](4 * size),
    }
    draw_arrow(compositor)
    tell(compositor, .SetCursor(display.Cursor.{hot_x = 1, hot_y = 1, visible = true}))
    tell(compositor, .MoveCursor(display.Position.{x = compositor.pointer_x, y = compositor.pointer_y}))
}

/** Dial the input service for the seat and hold a Read on it. */
connect_seat :: fn(compositor : ptr[mut Compositor], dialer : os.Channel[connector.Connector]) {
    port :: os.port_for(slop_os.startup_block().budget, dialer.end) or_return void
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    channel :: connector.dial[seat.Seat](dialer.end, port) or_return void
    signals :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    if slop_os.port_bind(compositor.port, cast[slop_os.Handle](channel.end), signals, SEAT_KEY, .Persistent) is_error {
        _ = slop_os.handle_close(cast[slop_os.Handle](channel.end))
        return void
    }
    compositor.seat_end = channel.end
    // The borrower, before it reads, so it's never taken for the reader
    out := os.Outgoing.{}
    request :: os.begin[seat.Request](&out)
    request^ = .Borrow
    _ = seat.send_request(compositor.seat_end, compositor.port, &out)
    read_seat(compositor)
}

/** Hold a Read on the seat. */
read_seat :: fn(compositor : ptr[mut Compositor]) {
    out := os.Outgoing.{}
    request :: os.begin[seat.Request](&out)
    request^ = .Read(seat.MAX_EVENTS)
    _ = seat.send_request(compositor.seat_end, compositor.port, &out)
}

/** Whether a window has a frame waiting to be shown. */
any_submitted :: fn(compositor : ptr[Compositor]) -> bool {
    for window in compositor.windows {
        if window.used && window.submitted {
            return true
        }
    }
    return false
}

// ---- Clients' requests

/**
 * Take the requests a client has sent, up to REQUESTS_PER_PASS, until there are none left, or it's gone, which ends its
 * windows. One that has more is cut short (cut_short), so it can't keep the compositor from the others, or from
 * drawing, by sending as fast as it's answered.
 *
 * @param compositor The compositor.
 * @param index The client's index; a freed place is passed over.
 * @param into Where each request is received.
 */
serve :: fn(compositor : ptr[mut Compositor], index : usize, into : ptr[mut os.Incoming]) {
    if index >= compositor.clients.ends.count || index >= compositor.states.count {
        return void
    }
    end :: compositor.clients.ends[index]
    if cast[slop_os.Handle](end) == slop_os.NO_HANDLE {
        return void
    }
    taken := cast[usize](0)
    loop {
        if taken >= REQUESTS_PER_PASS {
            compositor.cut_short = true
            return void
        }
        taken += 1
        match surface.receive_request(end, compositor.port, into, false) {
            case Received => {}
            case Empty => return void
            case Unsupported => {
                _ = surface.answer_unsupported(end, compositor.port)
                continue
            }
            case _ => {
                service_kit.drop_client(&compositor.clients, index)
                forget_client(compositor, index)
                return void
            }
        }
        out := os.Outgoing.{}
        response :: os.begin[surface.Response](&out)
        answered := true
        // A connection's name is settled by its first request, whatever it is: only a Name then names it
        first_request :: !compositor.states[index].named
        compositor.states[index].named = true
        match os.message_of[surface.Request](into)^ {
            case Activation => response^ = .Token(token_for(compositor, index))
            case Name(given) => {
                answered = false
                if first_request && !compositor.states[index].listener {
                    state :: &compositor.states[index]
                    text :: os.items(into, given)
                    kept :: if text.count < state.name.count { text.count } else { state.name.count }
                    for byte, i in text {
                        if i < kept {
                            state.name[i] = byte
                        }
                    }
                    state.name_count = kept
                    if kept <= state.name.count {
                        runtime.log_info("a client named '%'", string_of_bytes(state.name[0..<kept]))
                    }
                }
                else {
                    runtime.log_info("refused a client's name: a connection's named only by its first request")
                }
            }
            case Connect(connection) => {
                answered = false
                if !may_connect(compositor, index) {
                    runtime.log_info("refused a connection: its client has as many as it may")
                    _ = slop_os.handle_close(cast[slop_os.Handle](connection.end))
                    continue
                }
                match service_kit.add_client_index(&compositor.clients, compositor.port, connection.end) {
                    case Some(added) => {
                        /*
                         * A trusted client's connections are trusted too; a client's have its name, settled, while a
                         * listener's are its dialer's to name
                         */
                        if added < compositor.states.count {
                            maker :: compositor.states[index]
                            compositor.states[added] = ClientState.{
                                next_surface = 1,
                                trusted = maker.trusted,
                                named = !maker.listener,
                                name = maker.name,
                                name_count = maker.name_count,
                                root = if maker.listener { added } else { maker.root },
                            }
                        }
                    }
                    case None => _ = slop_os.handle_close(cast[slop_os.Handle](connection.end))
                }
            }
            case Describe => response^ = .Described(
                surface.Output.{
                    width = compositor.info.width,
                    height = compositor.info.height,
                    scale = surface.SCALE_ONE,
                    refresh_millihertz = compositor.info.refresh_millihertz,
                    formats = 3,
                }
            )
            case CreateWindow(spec) => response^ = create_window(compositor, index, spec, os.items(into, spec.title))
            case CreateSubsurface(_) => response^ = .Refused(.Unsupported)
            case AddBuffer(given) => response^ = add_buffer(compositor, index, given)
            case RemoveBuffer(id) => {
                answered = false
                remove_buffer(compositor, index, id)
            }
            case Submit(submission) => {
                match submit(compositor, index, submission) {
                    case Some(refusal) => response^ = .Refused(refusal)
                    case None => answered = false
                }
            }
            case SetTitle(title) => {
                answered = false
                set_title(compositor, index, title.surface, os.items(into, title.text))
            }
            case Destroy(id) => {
                answered = false
                destroy(compositor, window_of(compositor, index, id))
            }
            case Read(most) => {
                answered = false
                compositor.states[index].held = if most == 0 { cast[u32](1) } else { most }
            }
            case TakePaste => response^ = take_paste(compositor, index)
            case MicrophoneHeld(names) => {
                answered = false
                if index < compositor.states.count && compositor.states[index].trusted {
                    microphone_held(compositor, os.items(into, names))
                }
                else {
                    runtime.log_info("refused who holds the microphone from a client that isn't trusted")
                }
            }
            case Copy(offer) => {
                answered = false
                /*
                 * Only the focused window's client, as only the user copies: a program in the background can't swap
                 * what was copied before it's pasted
                 */
                focused :: compositor.focus < MAX_WINDOWS
                    && compositor.windows[compositor.focus % MAX_WINDOWS].used
                    && compositor.windows[compositor.focus % MAX_WINDOWS].client == index
                if !focused {
                    _ = slop_os.handle_close(cast[slop_os.Handle](offer.data))
                    continue
                }
                keep_typed(compositor, offer)
                text :: os.items(into, offer.text)
                compositor.clipboard_count = 0
                for byte in text {
                    if compositor.clipboard_count < compositor.clipboard.count {
                        compositor.clipboard[compositor.clipboard_count] = byte
                        compositor.clipboard_count += 1
                    }
                }
            }
        }
        if answered {
            _ = surface.send_response(end, compositor.port, &out)
        }
    }
}

/**
 * Keep a copy's typed data, in place of what was kept: its first bytes copied to memory of the compositor's own, so
 * what's pasted can't change after, whatever its client does with what it gave.
 *
 * @param compositor The compositor, whose paste_ fields are replaced; none kept for data that isn't anonymous memory
 *     its handle owns (owned_anonymous), as reading paged memory would wait on its pager, its client; for none, or past
 *     MAX_PASTE_BYTES; or if it can't be copied.
 * @param offer The copy; its data's closed here.
 */
keep_typed :: fn(compositor : ptr[mut Compositor], offer : surface.Offer) {
    drop_typed(compositor)
    defer {
        if cast[slop_os.Handle](offer.data) != slop_os.NO_HANDLE {
            _ = slop_os.handle_close(cast[slop_os.Handle](offer.data))
        }
    }
    if offer.bytes == 0
        || offer.bytes > surface.MAX_PASTE_BYTES
        || cast[slop_os.Handle](offer.data) == slop_os.NO_HANDLE
        || !owned_anonymous(offer.data) {
        return void
    }
    size :: (offer.bytes + 4095) / 4096 * 4096
    copy :: slop_os.memory_create(slop_os.startup_block().budget, size) or_return void
    chunk : u8[4096]
    at := cast[u64](0)
    loop {
        if at >= offer.bytes {
            break
        }
        left :: offer.bytes - at
        count :: if left >= 4096 { cast[usize](4096) } else { cast[usize](left) }
        if count > chunk.count {
            _ = slop_os.handle_close(cast[slop_os.Handle](copy))
            return void
        }
        piece :: chunk[0..<count]
        read :: slop_os.memory_read(offer.data, at, piece) is_ok
        written :: read && (slop_os.memory_write(copy, at, piece) is_ok)
        if !written {
            _ = slop_os.handle_close(cast[slop_os.Handle](copy))
            return void
        }
        at += cast[u64](count)
    }
    compositor.paste_data = copy
    compositor.paste_bytes = offer.bytes
    compositor.paste_schema = offer.schema
}

/** Let go of the typed data kept, and of any paste of it still to take. */
drop_typed :: fn(compositor : ptr[mut Compositor]) {
    if compositor.paste_bytes > 0 {
        _ = slop_os.handle_close(cast[slop_os.Handle](compositor.paste_data))
    }
    compositor.paste_bytes = 0
    compositor.paste_at = 0
}

/**
 * Give a client the typed data of the paste it was just given (TakePaste): once, within PASTE_LIFE.
 *
 * @param compositor The compositor, whose paste's taken.
 * @param client The client asking.
 * @return Pasted with a read-only handle to the compositor's copy; Refused(NoSuchThing) if this client wasn't the last
 *     given a paste with typed data, it's past PASTE_LIFE, it's taken already, or the handle can't be made.
 */
take_paste :: fn(compositor : ptr[mut Compositor], client : usize) -> surface.Response {
    now :: slop_os.clock_monotonic() or_else 0
    if compositor.paste_at == 0
        || compositor.paste_bytes == 0
        || compositor.paste_client != client
        || now - compositor.paste_at > surface.PASTE_LIFE {
        return .Refused(.NoSuchThing)
    }
    compositor.paste_at = 0
    rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_READ) | cast[u32](slop_os.RIGHT_TRANSFER))
    given :: slop_os.handle_duplicate(cast[slop_os.Handle](compositor.paste_data), rights)
        or_return .Refused(.NoSuchThing)
    runtime.log_info("gave a paste's typed data, % bytes", compositor.paste_bytes)
    return .Pasted(
        surface.Offer.{
            schema = compositor.paste_schema,
            data = cast[slop_os.Memory](given),
            bytes = compositor.paste_bytes,
        }
    )
}

/** End a client's windows and give back its buffers, as it's gone. */
forget_client :: fn(compositor : ptr[mut Compositor], index : usize) {
    // A paste it was given, or its gesture's token, can't be taken by whoever has its place next
    if compositor.paste_client == index {
        compositor.paste_at = 0
    }
    if compositor.gesture_client == index {
        compositor.gesture_at = 0
    }
    // The connections it made are their own roots now, so they don't count against whoever has its place next
    for &state, i in compositor.states {
        if i != index && state.root == index {
            state.root = i
        }
    }
    for i in cast[usize](0)..<MAX_WINDOWS {
        if compositor.windows[i].used && compositor.windows[i].client == index {
            destroy(compositor, i)
        }
    }
    if index >= compositor.states.count {
        return void
    }
    for &buffer in compositor.states[index].buffers {
        if buffer.id != 0 {
            unmap(buffer)
        }
    }
    compositor.states[index] = ClientState.{}
}

/** A client's window by its number, or NO_WINDOW. */
window_of :: fn(compositor : ptr[Compositor], client : usize, id : u32) -> usize {
    for window, i in compositor.windows {
        if window.used && window.client == client && window.surface == id {
            return i
        }
    }
    return NO_WINDOW
}

/**
 * Make a window, placed down and right of the last, with a Configure for its size.
 *
 * @return Created with its number; Refused for a size or scale it doesn't take, or with every place taken.
 */
create_window :: fn(
    compositor : ptr[mut Compositor],
    client : usize,
    spec : surface.WindowSpec,
    title : u8[]
) -> surface.Response {
    if spec.width == 0
        || spec.height == 0
        || spec.width > MOST_PIXELS
        || spec.height > MOST_PIXELS
        || spec.scale != surface.SCALE_ONE {
        return .Refused(.Unsupported)
    }
    free := NO_WINDOW
    for window, i in compositor.windows {
        if !window.used {
            free = i
            break
        }
    }
    if free >= MAX_WINDOWS || client >= compositor.states.count || !may_make_window(compositor, client) {
        return .Refused(.TooMany)
    }
    state :: &compositor.states[client]
    id :: state.next_surface
    state.next_surface += 1
    step :: cast[i32](compositor.order_count) * 30
    made := Window.{
        used = true,
        client = client,
        surface = id,
        x = 60 + step,
        y = 60 + BAND + step,
        width = spec.width,
        height = spec.height,
        trusted = state.trusted,
        passive = state.trusted && spec.passive,
        activated_at = took_token(compositor, spec.activation),
    }
    if made.passive {
        // In the top right corner, out of the way, above everything
        made.x = cast[i32](compositor.info.width) - cast[i32](spec.width) - PASSIVE_MARGIN
        made.y = PASSIVE_MARGIN
    }
    else if made.trusted {
        // Centred, above everything
        made.x = (cast[i32](compositor.info.width) - cast[i32](spec.width)) / 2
        made.y = (cast[i32](compositor.info.height) - cast[i32](spec.height)) / 2
    }
    for byte in title {
        if made.title_count < made.title.count {
            made.title[made.title_count] = byte
            made.title_count += 1
        }
    }
    compositor.windows[free] = made
    if compositor.order_count < compositor.order.count {
        compositor.order[compositor.order_count] = free
        compositor.order_count += 1
    }
    configure := surface.event_of(.Configure, id)
    configure.x = cast[i32](spec.width)
    configure.y = cast[i32](spec.height)
    queue(compositor, client, configure, "")
    return .Created(id)
}

/**
 * Tell whether memory a client gave for a buffer is anonymous memory, given by its owning handle: what the compositor
 * reads of it then is there while it's mapped. Paged memory would wait on its pager, the client, whenever a page isn't
 * there, stopping every window; a window onto memory has its parent's pages, which may be paged; and memory the client
 * still owns can be destroyed under the mapping, a fault the compositor can't catch.
 *
 * @param memory The memory, as it came.
 * @return True if it's anonymous and the handle owns it.
 */
owned_anonymous :: fn(memory : slop_os.Memory) -> bool {
    kind :: slop_os.memory_kind(memory) or_return false
    return kind == .Anonymous && (slop_os.memory_holders(memory) is_ok)
}

/**
 * Take a client's buffer: its description checked, its memory mapped read-only, only as far as the image reaches.
 *
 * @return Added with its id; Refused for an id in use or 0, a description it doesn't take, a plane outside its memory,
 *     memory that isn't anonymous and owned by the handle given (owned_anonymous), every place taken, or memory that
 *     couldn't be mapped. The memory's closed when it's refused.
 */
add_buffer :: fn(compositor : ptr[mut Compositor], client : usize, given : surface.NewBuffer) -> surface.Response {
    refusal := surface.Refusal.NoSuchThing
    if client < compositor.states.count && given.id != 0 {
        state :: &compositor.states[client]
        description :: given.description
        place := cast[usize](MAX_BUFFERS)
        taken := false
        for buffer, i in state.buffers {
            if buffer.id == given.id {
                taken = true
            }
            if buffer.id == 0 && place == MAX_BUFFERS {
                place = i
            }
        }
        plane :: description.planes[0]
        size :: slop_os.memory_size(given.memory) or_else 0
        rows :: cast[u64](plane.stride) * cast[u64](description.height)
        fits :: (description.format == surface.FORMAT_XRGB8888 || description.format == surface.FORMAT_ARGB8888)
            && description.modifier == surface.MODIFIER_LINEAR
            && description.plane_count == 1
            && description.width > 0
            && description.height > 0
            && description.width <= MOST_PIXELS
            && description.height <= MOST_PIXELS
            && plane.stride >= 4 * description.width
            && plane.offset <= size
            && rows <= size - plane.offset
            && owned_anonymous(given.memory)
        refusal = if taken {
            surface.Refusal.NoSuchThing
        }
        else if !fits { surface.Refusal.Unsupported } else { surface.Refusal.TooMany }
        if !taken && fits && place < MAX_BUFFERS {
            buffer :: &state.buffers[place]
            /*
             * Only what the image uses is mapped, not all the memory, which may be far bigger: addresses reserved for
             * a place are kept for the next buffer there, so a place's grow only to the largest image allowed
             */
            mapped :: (plane.offset + rows + 4095) / 4096 * 4096
            if buffer.reserved_bytes < mapped {
                buffer.reserved = runtime.reserve_addresses(cast[usize](mapped)) or_else 0
                buffer.reserved_bytes = if buffer.reserved == 0 { cast[u64](0) } else { mapped }
            }
            if buffer.reserved != 0
                && (slop_os.memory_map(
                    given.memory,
                    slop_os.startup_block().space,
                    buffer.reserved,
                    0,
                    mapped,
                    slop_os.PROTECTION_READ
                ) is_ok) {
                buffer.id = given.id
                buffer.memory = given.memory
                buffer.address = buffer.reserved
                buffer.bytes = mapped
                buffer.format = description.format
                buffer.width = description.width
                buffer.height = description.height
                buffer.stride = plane.stride
                buffer.offset = plane.offset
                return .Added(given.id)
            }
            refusal = .NoMemory
        }
    }
    _ = slop_os.handle_close(cast[slop_os.Handle](given.memory))
    return .Refused(refusal)
}

/** Unmap a buffer and close its memory, keeping its addresses for the next. */
unmap :: fn(buffer : ptr[mut ClientBuffer]) {
    _ = slop_os.memory_unmap(slop_os.startup_block().space, buffer.address)
    _ = slop_os.handle_close(cast[slop_os.Handle](buffer.memory))
    buffer.id = 0
}

/** A client's buffer by id, or null. */
buffer_of :: fn(compositor : ptr[mut Compositor], client : usize, id : u32) -> ptr[mut ClientBuffer]? {
    if client >= compositor.states.count || id == 0 {
        return null
    }
    for &buffer in compositor.states[client].buffers {
        if buffer.id == id {
            return buffer
        }
    }
    return null
}

/** Take a buffer back, once no window shows it: one that's shown stays until it's replaced. */
remove_buffer :: fn(compositor : ptr[mut Compositor], client : usize, id : u32) {
    for window in compositor.windows {
        if window.used && window.client == client && (window.buffer == id || window.replaced == id) {
            return void
        }
    }
    match buffer_of(compositor, client, id) {
        case Some(buffer) => unmap(buffer)
        case None => {}
    }
}

/**
 * Show a frame of a window, from the next composite on.
 *
 * @return null once it's taken; why it's refused otherwise: a surface or buffer the client hasn't, or a buffer that
 *     isn't the window's size.
 */
submit :: fn(compositor : ptr[mut Compositor], client : usize, submission : surface.Submission) -> surface.Refusal? {
    index :: window_of(compositor, client, submission.surface)
    if index >= MAX_WINDOWS {
        return .NoSuchThing
    }
    window :: &compositor.windows[index]
    if submission.buffer != 0 {
        buffer :: buffer_of(compositor, client, submission.buffer) or_return .NoSuchThing
        if buffer.width != window.width || buffer.height != window.height {
            return .Unsupported
        }
    }
    first :: window.buffer == 0
    hidden :: submission.buffer == 0 && window.buffer != 0
    if window.buffer != submission.buffer {
        // The one it replaces is released once a frame without it is shown
        if window.replaced != 0 {
            release(compositor, window.client, window.replaced)
        }
        window.replaced = window.buffer
        window.buffer = submission.buffer
    }
    window.submitted = true
    content :: content_of(window)
    damaged :: if first {
        frame_of(window)
    }
    else {
        canvas.intersect(
            content,
            canvas.Rect.{
                x0 = window.x + submission.damage.x,
                y0 = window.y + submission.damage.y,
                x1 = window.x + submission.damage.x + cast[i32](submission.damage.width),
                y1 = window.y + submission.damage.y + cast[i32](submission.damage.height),
            }
        )
    }
    add_damage(compositor, damaged)
    if hidden {
        // Off the screen until it's shown again; its keys go to the topmost window still shown
        add_damage(compositor, frame_of(window))
        runtime.log_info("window '%' hidden", title_of(window))
        if compositor.focus == index {
            compositor.focus = NO_WINDOW
            focus_top_shown(compositor)
        }
    }
    else if first && submission.buffer != 0 {
        runtime.log_info("window '%' shown", title_of(window))
        /*
         * Focused the first time it's shown with an activation token from the user's gesture, or when no other window
         * has focus, whose keys it could take; the trusted layer's always. Otherwise it's shown waiting, its band
         * marked, until the user chooses it. Shown again, it's never focused but by the user's gesture.
         */
        nothing_focused :: compositor.focus >= MAX_WINDOWS
            || !compositor.windows[compositor.focus].used
            || compositor.windows[compositor.focus].buffer == 0
        now :: slop_os.clock_monotonic() or_else 0
        activated :: window.activated_at != 0 && now - window.activated_at <= TOKEN_LIFE
        if window.passive {
            // An indicator: shown, never focused
        }
        else if window.trusted || (!window.shown_before && (activated || nothing_focused)) {
            focus_window(compositor, index)
        }
        else if !window.shown_before {
            window.attention = true
            runtime.log_info("window '%' wants attention", title_of(window))
        }
        window.shown_before = true
    }
    return null
}

/** Focus the topmost window that's shown, if there's one: a window hidden or gone had focus. */
focus_top_shown :: fn(compositor : ptr[mut Compositor]) {
    at := compositor.order_count
    loop {
        if at == 0 {
            break
        }
        at -= 1
        if at >= compositor.order.count {
            continue
        }
        candidate :: compositor.order[at]
        if candidate < MAX_WINDOWS
            && compositor.windows[candidate].used
            && compositor.windows[candidate].buffer != 0
            && !compositor.windows[candidate].passive {
            focus_window(compositor, candidate)
            return void
        }
    }
}

/** A window's title as text. */
title_of :: fn(window : ptr[Window]) -> string {
    return if window.title_count > 0 { string_of(&window.title[0], window.title_count) } else { "" }
}

/**
 * Take who holds the microphone, as the trusted path says (MicrophoneHeld): every window's band is drawn again, its mark
 * then shown or taken away.
 *
 * @param compositor The compositor, whose held names are replaced.
 * @param names The holders' names, each ended by a line break; past surface.MAX_HELD_BYTES, cut at the last whole one.
 */
microphone_held :: fn(compositor : ptr[mut Compositor], names : u8[]) {
    compositor.held_count = 0
    holders := cast[usize](0)
    for byte, i in names {
        if i < compositor.held.count {
            compositor.held[i] = byte
            if byte == cast[u8]('\n') {
                compositor.held_count = i + 1
                holders += 1
            }
        }
    }
    marked := cast[usize](0)
    for &window in compositor.windows {
        if window.used {
            add_damage(compositor, band_of(window))
            if !window.trusted && holds_microphone(compositor, window.client) {
                marked += 1
            }
        }
    }
    runtime.log_info("programs holding the microphone: %, their windows marked: %", holders, marked)
}

/**
 * Tell whether a client's program holds the microphone: its name's among those the trusted path last said.
 *
 * @param compositor The compositor.
 * @param client The client, by index.
 * @return False for a client never named, or past the clients.
 */
holds_microphone :: fn(compositor : ptr[Compositor], client : usize) -> bool {
    if client >= compositor.states.count {
        return false
    }
    state :: &compositor.states[client]
    if state.name_count == 0 {
        return false
    }
    name :: state.name[0..<state.name_count]
    start := cast[usize](0)
    for byte, i in compositor.held[0..<compositor.held_count] {
        if byte != cast[u8]('\n') {
            continue
        }
        if i >= start && i - start == name.count {
            same := true
            for wanted, k in name {
                at :: start + k
                if at >= compositor.held.count || compositor.held[at] != wanted {
                    same = false
                    break
                }
            }
            if same {
                return true
            }
        }
        start = i + 1
    }
    return false
}

/** Change a window's title, its band drawn again. */
set_title :: fn(compositor : ptr[mut Compositor], client : usize, id : u32, text : u8[]) {
    index :: window_of(compositor, client, id)
    if index >= MAX_WINDOWS {
        return void
    }
    window :: &compositor.windows[index]
    window.title_count = 0
    for byte in text {
        if window.title_count < window.title.count {
            window.title[window.title_count] = byte
            window.title_count += 1
        }
    }
    add_damage(compositor, band_of(window))
}

/** End a window: taken off the screen, its buffers released, focus to the window below. */
destroy :: fn(compositor : ptr[mut Compositor], index : usize) {
    if index >= MAX_WINDOWS || !compositor.windows[index].used {
        return void
    }
    window :: &compositor.windows[index]
    add_damage(compositor, frame_of(window))
    if window.buffer != 0 {
        release(compositor, window.client, window.buffer)
    }
    if window.replaced != 0 {
        release(compositor, window.client, window.replaced)
    }
    window.used = false
    remove_from_order(compositor, index)
    // Nothing points at it any more
    compositor.hover = if compositor.hover == index { NO_WINDOW } else { compositor.hover }
    compositor.grab = if compositor.grab == index { NO_WINDOW } else { compositor.grab }
    compositor.dragging = if compositor.dragging == index { NO_WINDOW } else { compositor.dragging }
    if compositor.focus == index {
        compositor.focus = NO_WINDOW
        focus_top_shown(compositor)
    }
}

/** Take a window out of the stacking order. */
remove_from_order :: fn(compositor : ptr[mut Compositor], index : usize) {
    kept : usize = 0
    for i in cast[usize](0)..<MAX_WINDOWS {
        if i < compositor.order_count && compositor.order[i] != index && kept < compositor.order.count {
            compositor.order[kept] = compositor.order[i]
            kept += 1
        }
    }
    compositor.order_count = kept
}

/** Queue a Released for a client's buffer. */
release :: fn(compositor : ptr[mut Compositor], client : usize, id : u32) {
    released := surface.event_of(.Released, 0)
    released.code = id
    queue(compositor, client, released, "")
}

// ---- Geometry

/** A window's content on the screen. */
content_of :: fn(window : ptr[Window]) -> canvas.Rect {
    return canvas.Rect.{
        x0 = window.x,
        y0 = window.y,
        x1 = window.x + cast[i32](window.width),
        y1 = window.y + cast[i32](window.height),
    }
}

/** A window's band on the screen; none for the trusted layer's. */
band_of :: fn(window : ptr[Window]) -> canvas.Rect {
    if window.trusted {
        return canvas.Rect.{}
    }
    return canvas.Rect.{x0 = window.x, y0 = window.y - BAND, x1 = window.x + cast[i32](window.width), y1 = window.y}
}

/** A window and its band on the screen. */
frame_of :: fn(window : ptr[Window]) -> canvas.Rect {
    band :: band_of(window)
    return if canvas.is_empty(band) { content_of(window) } else { canvas.union_of(band, content_of(window)) }
}

/** The trusted layer's topmost window shown that isn't passive, or NO_WINDOW when it shows none. */
trusted_top :: fn(compositor : ptr[Compositor]) -> usize {
    found := NO_WINDOW
    for i in cast[usize](0)..<MAX_WINDOWS {
        if i < compositor.order_count {
            index :: compositor.order[i]
            if index < MAX_WINDOWS
                && compositor.windows[index].used
                && compositor.windows[index].trusted
                && !compositor.windows[index].passive
                && compositor.windows[index].buffer != 0 {
                found = index
            }
        }
    }
    return found
}

/** A window's close box on the screen. */
close_of :: fn(window : ptr[Window]) -> canvas.Rect {
    right :: window.x + cast[i32](window.width) - 6
    top :: window.y - BAND + (BAND - CLOSE) / 2
    return canvas.Rect.{x0 = right - CLOSE, y0 = top, x1 = right, y1 = top + CLOSE}
}

/** Whether a point's in a rectangle. */
inside :: fn(rect : canvas.Rect, x : i32, y : i32) -> bool {
    return x >= rect.x0 && x < rect.x1 && y >= rect.y0 && y < rect.y1
}

/** Add to what changed, cut to the screen. */
add_damage :: fn(compositor : ptr[mut Compositor], rect : canvas.Rect) {
    cut :: canvas.intersect(rect, screen(compositor))
    if canvas.is_empty(cut) {
        return void
    }
    compositor.damage = if canvas.is_empty(compositor.damage) { cut } else { canvas.union_of(compositor.damage, cut) }
}

/** The topmost window at a point, or NO_WINDOW; while the trusted layer shows a window, only its windows. */
window_at :: fn(compositor : ptr[Compositor], x : i32, y : i32) -> usize {
    layer :: trusted_top(compositor) < MAX_WINDOWS
    for pass in cast[usize](0)..<2 {
        // The trusted layer first, as it's drawn above
        found :: window_in(compositor, x, y, pass == 0)
        if found < MAX_WINDOWS || layer {
            return found
        }
    }
    return NO_WINDOW
}

/** The topmost window at a point of one layer, or NO_WINDOW. */
window_in :: fn(compositor : ptr[Compositor], x : i32, y : i32, trusted : bool) -> usize {
    for i in cast[usize](0)..<MAX_WINDOWS {
        if i < compositor.order_count {
            at :: compositor.order_count - 1 - i
            index :: if at < compositor.order.count { compositor.order[at] } else { NO_WINDOW }
            if index < MAX_WINDOWS
                && compositor.windows[index].buffer != 0
                && compositor.windows[index].trusted == trusted
                && inside(frame_of(&compositor.windows[index]), x, y) {
                return index
            }
        }
    }
    return NO_WINDOW
}

// ---- Focus, stacking and the seat

/** Raise a window to the top and give it focus, telling the windows that lose and gain it. */
focus_window :: fn(compositor : ptr[mut Compositor], index : usize) {
    if index >= MAX_WINDOWS || !compositor.windows[index].used {
        return void
    }
    remove_from_order(compositor, index)
    if compositor.order_count < compositor.order.count {
        compositor.order[compositor.order_count] = index
        compositor.order_count += 1
    }
    add_damage(compositor, frame_of(&compositor.windows[index]))
    if compositor.focus == index {
        return void
    }
    if compositor.focus < MAX_WINDOWS {
        old :: &compositor.windows[compositor.focus]
        queue(compositor, old.client, surface.event_of(.FocusOut, old.surface), "")
        add_damage(compositor, band_of(old))
    }
    compositor.focus = index
    window :: &compositor.windows[index]
    window.attention = false
    queue(compositor, window.client, surface.event_of(.FocusIn, window.surface), "")
    runtime.log_info("focused '%'", title_of(window))
}

/**
 * Take what the seat sent: keys to the focused window, Ctrl+Shift+V pasting into it; the pointer moved, its windows
 * told, a press raising its window, a drag of a band moving it, a press on the close box asking to close. Another Read
 * is held after each answer.
 */
take_seat :: fn(compositor : ptr[mut Compositor], into : ptr[mut os.Incoming]) {
    if cast[slop_os.Handle](compositor.seat_end) == slop_os.NO_HANDLE {
        return void
    }
    loop {
        match seat.receive_response(compositor.seat_end, compositor.port, into, false) {
            case Received => {}
            case Empty => return void
            case _ => {
                _ = slop_os.handle_close(cast[slop_os.Handle](compositor.seat_end))
                compositor.seat_end = cast[slop_os.Channel](slop_os.NO_HANDLE)
                return void
            }
        }
        match os.message_of[seat.Response](into)^ {
            case Input(given) => {
                text :: os.items(into, given.text)
                for event in os.items(into, given.events) {
                    take_event(compositor, event, text)
                }
                read_seat(compositor)
            }
            case _ => {}
        }
    }
}

/** Take one of the seat's events. */
take_event :: fn(compositor : ptr[mut Compositor], event : seat.Event, text : u8[]) {
    kind :: seat.kind_of(event) or_return void
    match kind {
        case .Key => {
            start :: cast[usize](event.text_start)
            end :: start + cast[usize](event.text_bytes)
            typed :: if start <= end && end <= text.count { text[start..<end] } else { text[0..<0] }
            layer :: trusted_top(compositor)
            target :: if layer < MAX_WINDOWS { layer } else { compositor.focus }
            if target >= MAX_WINDOWS {
                return void
            }
            window :: &compositor.windows[target]
            paste :: terminal.CONTROL | terminal.SHIFT
            if event.code == USAGE_V && event.modifiers & paste == paste && !window.trusted {
                kept :: compositor.clipboard[0..<TITLE_BYTES]
                pasted :: if compositor.clipboard_count <= kept.count {
                    kept[0..<compositor.clipboard_count]
                }
                else {
                    kept
                }
                given := surface.event_of(.Paste, window.surface)
                // Typed data too, which the window's client may take once, for a while (TakePaste)
                if compositor.paste_bytes > 0 {
                    given.code = 1
                    compositor.paste_client = window.client
                    compositor.paste_at = slop_os.clock_monotonic() or_else 0
                }
                queue(compositor, window.client, given, string_of_bytes(pasted))
                runtime.log_info("pasted into '%'", title_of(window))
                return void
            }
            gestured(compositor, window.client)
            key := surface.event_of(.Key, window.surface)
            key.code = cast[u32](event.code)
            key.modifiers = event.modifiers
            key.pressed = 1
            key.time_ns = event.time_ns
            queue(compositor, window.client, key, string_of_bytes(typed))
        }
        case .PointerMotion => move_pointer(compositor, compositor.pointer_x + event.x, compositor.pointer_y + event.y)
        case .PointerPosition => move_pointer(
            compositor,
            scaled(event.x, compositor.info.width),
            scaled(event.y, compositor.info.height)
        )
        case .Button => press(compositor, event.code, event.pressed != 0)
        case .Wheel => {
            if compositor.hover < MAX_WINDOWS {
                window :: &compositor.windows[compositor.hover]
                wheel := surface.event_of(.Wheel, window.surface)
                wheel.y = event.y
                queue(compositor, window.client, wheel, "")
            }
        }
        case _ => {}
    }
}

/** Bytes as text, for an event's. */
string_of_bytes :: fn(bytes : u8[]) -> string {
    return if bytes.count > 0 { string_of(&bytes[0], bytes.count) } else { "" }
}

/** A seat position, 0 to seat.POSITION_MAX, as a pixel on a screen of a size. */
scaled :: fn(value : i32, size : u32) -> i32 {
    return cast[i32](cast[i64](value) * cast[i64](size) / (cast[i64](seat.POSITION_MAX) + 1))
}

/** Move the pointer: the cursor, a dragged window, and the windows it leaves, enters and moves over told. */
move_pointer :: fn(compositor : ptr[mut Compositor], x : i32, y : i32) {
    top :: cast[i32](compositor.info.width) - 1
    bottom :: cast[i32](compositor.info.height) - 1
    compositor.pointer_x = if x < 0 { 0 } else if x > top { top } else { x }
    compositor.pointer_y = if y < 0 { 0 } else if y > bottom { bottom } else { y }
    tell(compositor, .MoveCursor(display.Position.{x = compositor.pointer_x, y = compositor.pointer_y}))
    if compositor.dragging < MAX_WINDOWS {
        window :: &compositor.windows[compositor.dragging]
        add_damage(compositor, frame_of(window))
        window.x = compositor.pointer_x - compositor.drag_x
        window.y = compositor.pointer_y - compositor.drag_y
        add_damage(compositor, frame_of(window))
        return void
    }
    over :: window_at(compositor, compositor.pointer_x, compositor.pointer_y)
    if over != compositor.hover {
        if compositor.hover < MAX_WINDOWS {
            left :: &compositor.windows[compositor.hover]
            queue(compositor, left.client, surface.event_of(.PointerLeave, left.surface), "")
        }
        compositor.hover = over
        if over < MAX_WINDOWS {
            pointer_event(compositor, .PointerEnter, over)
        }
    }
    else if over < MAX_WINDOWS
        && inside(content_of(&compositor.windows[over]), compositor.pointer_x, compositor.pointer_y) {
        pointer_event(compositor, .PointerMotion, over)
    }
}

/** Tell a window where the pointer is in its units. */
pointer_event :: fn(compositor : ptr[mut Compositor], kind : surface.EventKind, index : usize) {
    window :: &compositor.windows[index % MAX_WINDOWS]
    made := surface.event_of(kind, window.surface)
    made.x = compositor.pointer_x - window.x
    made.y = compositor.pointer_y - window.y
    queue(compositor, window.client, made, "")
}

/**
 * A button pressed or let go: a press raises and focuses the window under the pointer, and starts a drag on its band,
 * asks it to close on its close box, or goes to it on its content; a release ends a drag, or goes to the window the
 * press went to.
 */
press :: fn(compositor : ptr[mut Compositor], button : u16, pressed : bool) {
    if !pressed {
        if compositor.dragging < MAX_WINDOWS {
            moved :: &compositor.windows[compositor.dragging]
            runtime.log_info("moved '%' to %, %", title_of(moved), moved.x, moved.y)
            compositor.dragging = NO_WINDOW
            return void
        }
        if compositor.grab < MAX_WINDOWS {
            button_event(compositor, compositor.grab, button, false)
        }
        compositor.grab = NO_WINDOW
        return void
    }
    index :: window_at(compositor, compositor.pointer_x, compositor.pointer_y)
    if index >= MAX_WINDOWS {
        return void
    }
    // A passive window takes the click, but not the focus, which stays where the user's typing
    if !compositor.windows[index].passive {
        focus_window(compositor, index)
    }
    window :: &compositor.windows[index]
    if inside(close_of(window), compositor.pointer_x, compositor.pointer_y) {
        queue(compositor, window.client, surface.event_of(.CloseRequested, window.surface), "")
        return void
    }
    if inside(band_of(window), compositor.pointer_x, compositor.pointer_y) {
        if button == 0 {
            compositor.dragging = index
            compositor.drag_x = compositor.pointer_x - window.x
            compositor.drag_y = compositor.pointer_y - window.y
        }
        return void
    }
    compositor.grab = index
    gestured(compositor, window.client)
    button_event(compositor, index, button, true)
}

/** Note the user's gesture, a key or a button pressed, in a client's window: its token may be asked for, once. */
gestured :: fn(compositor : ptr[mut Compositor], client : usize) {
    compositor.gesture_client = client
    compositor.gesture_at = slop_os.clock_monotonic() or_else 0
    compositor.gesture_given = false
}

/**
 * Give a client an activation token for the user's gesture in its window a moment ago (GESTURE_LIFE), once.
 *
 * @param compositor The compositor, whose tokens keep the one given, the oldest forgotten for it.
 * @param client The client asking.
 * @return The token, never 0; 0 when the client's had no such gesture, or its token was given already.
 */
token_for :: fn(compositor : ptr[mut Compositor], client : usize) -> u64 {
    now :: slop_os.clock_monotonic() or_else 0
    if compositor.gesture_at == 0
        || compositor.gesture_client != client
        || compositor.gesture_given
        || now - compositor.gesture_at > GESTURE_LIFE {
        return 0
    }
    compositor.gesture_given = true
    value := random.next_u64() | 1
    oldest := cast[usize](0)
    for token, i in compositor.tokens {
        if token.at < compositor.tokens[oldest].at {
            oldest = i
        }
    }
    if oldest < compositor.tokens.count {
        compositor.tokens[oldest] = ActivationToken.{value = value, at = now}
    }
    return value
}

/**
 * Take a token a new window presents: good once, if it was given and isn't too old (TOKEN_LIFE).
 *
 * @param compositor The compositor, whose token's forgotten once it's taken.
 * @param value The token, 0 for none.
 * @return When it was given, in the monotonic clock's nanoseconds, if it was good; 0 if it wasn't.
 */
took_token :: fn(compositor : ptr[mut Compositor], value : u64) -> u64 {
    if value == 0 {
        return 0
    }
    now :: slop_os.clock_monotonic() or_else 0
    for &token in compositor.tokens {
        if token.value == value {
            token.value = 0
            return if now - token.at <= TOKEN_LIFE && token.at != 0 { token.at } else { cast[u64](0) }
        }
    }
    return 0
}

/** How many client places are in use by untrusted clients, and by those counted against a root. */
places_in_use :: fn(compositor : ptr[mut Compositor], root : usize) -> (usize, usize) {
    untrusted := cast[usize](0)
    of_root := cast[usize](0)
    for state, i in compositor.states {
        if i >= compositor.clients.ends.count || cast[slop_os.Handle](compositor.clients.ends[i]) == slop_os.NO_HANDLE {
            continue
        }
        // A listener's place is taken too, so it's counted against what's kept for the trusted (16g)
        if state.listener {
            untrusted += 1
            continue
        }
        if !state.trusted {
            untrusted += 1
        }
        if state.root == root {
            of_root += 1
        }
    }
    return untrusted, of_root
}

/**
 * Tell whether a client may make another connection: a listener's for a dialer, unless what isn't trusted would take
 * the places kept for the trusted; a client's, up to CONNECTIONS_PER_CLIENT with those it made.
 */
may_connect :: fn(compositor : ptr[mut Compositor], index : usize) -> bool {
    if index >= compositor.states.count {
        return false
    }
    maker :: compositor.states[index]
    if maker.trusted {
        return true
    }
    untrusted, of_root :: places_in_use(compositor, maker.root)
    if untrusted + KEPT_FOR_TRUSTED >= service_kit.MAX_CLIENTS {
        return false
    }
    return maker.listener || of_root < CONNECTIONS_PER_CLIENT
}

/** Tell whether a client may make another window: up to WINDOWS_PER_CLIENT with its connections', some kept. */
may_make_window :: fn(compositor : ptr[mut Compositor], client : usize) -> bool {
    if client >= compositor.states.count || compositor.states[client].trusted {
        return true
    }
    root :: compositor.states[client].root
    untrusted := cast[usize](0)
    of_root := cast[usize](0)
    for window in compositor.windows {
        if !window.used || window.trusted {
            continue
        }
        untrusted += 1
        if window.client < compositor.states.count && compositor.states[window.client].root == root {
            of_root += 1
        }
    }
    return of_root < WINDOWS_PER_CLIENT && untrusted + KEPT_FOR_TRUSTED < MAX_WINDOWS
}

/** Tell a window a button went down or came up, where the pointer is in its units. */
button_event :: fn(compositor : ptr[mut Compositor], index : usize, button : u16, pressed : bool) {
    window :: &compositor.windows[index % MAX_WINDOWS]
    made := surface.event_of(.Button, window.surface)
    made.code = cast[u32](button)
    made.pressed = if pressed { cast[u8](1) } else { cast[u8](0) }
    made.x = compositor.pointer_x - window.x
    made.y = compositor.pointer_y - window.y
    queue(compositor, window.client, made, "")
}

// ---- Events for clients

/** Queue an event for a client, with its text; past what's kept, the oldest are dropped. */
queue :: fn(compositor : ptr[mut Compositor], client : usize, made : surface.Event, text : string) {
    if client >= compositor.states.count {
        return void
    }
    state :: &compositor.states[client]
    bytes :: string_bytes(text)
    if state.count >= state.events.count || bytes.count > state.text.count - state.text_count {
        // A client that doesn't read loses what's oldest, and its text
        runtime.log_warn("client % isn't reading: % events dropped", client, state.count)
        forget_text(state, 0)
        state.count = 0
    }
    if bytes.count > state.text.count {
        return void
    }
    event := made
    event.text_start = cast[u32](state.text_count)
    event.text_bytes = cast[u32](bytes.count)
    for byte in bytes {
        if state.text_count < state.text.count {
            state.text[state.text_count] = byte
            state.text_count += 1
        }
    }
    if state.count < state.events.count {
        state.events[state.count] = event
        state.count += 1
    }
}

/** Answer a client's held Read with what's waiting, if there's anything. */
deliver :: fn(compositor : ptr[mut Compositor], client : usize) {
    if client >= compositor.states.count || client >= compositor.clients.ends.count {
        return void
    }
    state :: &compositor.states[client]
    if state.count == 0 || state.held == 0 {
        return void
    }
    most := if state.count < cast[usize](state.held) { state.count } else { cast[usize](state.held) }
    if most > surface.MAX_EVENTS {
        most = surface.MAX_EVENTS
    }
    count := most
    text_end := state.text_count
    // What's queued as the Read's answered, which what's left is worked out from once it's sent
    queued :: state.count
    queued_text :: state.text_count
    sent := false
    // Halved while they're too big for the client's ring, as one made with the default ring is
    for attempt in cast[usize](0)..<8 {
        count = most
        // The text of those given, which are first, up to where the next's starts; fewer given while it's past MAX_TEXT
        loop {
            text_end = if count < state.count && count < state.events.count {
                cast[usize](state.events[count].text_start)
            }
            else {
                state.text_count
            }
            if count <= 1 || text_end <= surface.MAX_TEXT {
                break
            }
            count -= 1
        }
        if count > state.events.count || text_end > state.text.count || text_end > surface.MAX_TEXT {
            // One event with more text than an Input holds: dropped
            runtime.log_warn(
                "client %: an event's text is past what an Input holds: % events dropped",
                client,
                state.count
            )
            state.count = 0
            forget_text(state, 0)
            return void
        }
        out := os.Outgoing.{}
        response :: os.begin[surface.Response](&out)
        response^ = .Input(
            surface.Events.{
                events = os.append(&out, state.events[0..<count]),
                text = os.append(&out, state.text[0..<text_end]),
            }
        )
        sending :: surface.send_response(compositor.clients.ends[client], compositor.port, &out)
        // Its copy of the text, typed keys among it, zeroed once it's sent or not (decisions/0197, N3)
        intrinsics.secure_zero(cast[ptr[mut u8]](&out), size_of(os.Outgoing))
        match sending {
            case Some(error) => {
                if error != .TooBig || most <= 1 {
                    // Tried again at the next deliver
                    return void
                }
                most /= 2
            }
            case None => {
                sent = true
                break
            }
        }
    }
    // Halving loses how count stands to what's queued, and the next event's text_start is what it was given as
    if !sent || count > queued || text_end > queued_text {
        return void
    }
    state.held = 0
    left :: queued - count
    for i in 0..<left {
        from :: i + count
        if from < state.events.count && i < state.events.count {
            moved := state.events[from]
            moved.text_start = if cast[usize](moved.text_start) >= text_end {
                moved.text_start - cast[u32](text_end)
            }
            else {
                0
            }
            state.events[i] = moved
        }
    }
    text_left :: queued_text - text_end
    for i in 0..<text_left {
        if i + text_end < state.text.count {
            state.text[i] = state.text[i + text_end]
        }
    }
    state.count = left
    forget_text(state, text_left)
}

/**
 * Keep only a client's first queued text bytes, the rest zeroed (decisions/0197, N3): what was typed, as a password
 * into the trusted layer, isn't left in the compositor once it's given or dropped.
 *
 * @param state The client's state, whose text_count becomes kept.
 * @param kept How many of its text's bytes stay, at most text_count.
 */
forget_text :: fn(state : ptr[mut ClientState], kept : usize) {
    if kept < state.text_count {
        intrinsics.secure_zero(&state.text[kept], state.text_count - kept)
    }
    state.text_count = if kept < state.text_count { kept } else { state.text_count }
}

// ---- Drawing

/**
 * Draw the frame into the buffer that isn't shown, over this frame's damage and the last's, and present it; then the
 * buffers replaced are released and the windows submitted told they're shown.
 */
composite :: fn(compositor : ptr[mut Compositor]) {
    region :: canvas.intersect(
        if canvas.is_empty(compositor.last_damage) {
            compositor.damage
        }
        else if canvas.is_empty(compositor.damage) {
            compositor.last_damage
        }
        else {
            canvas.union_of(compositor.damage, compositor.last_damage)
        },
        screen(compositor)
    )
    next :: 1 - (compositor.shown % 2)
    if !canvas.is_empty(region) {
        draw(compositor, next, region)
    }
    frame :: display.Frame.{
        buffer = next,
        damage = display.Rect.{
            x = cast[u32](region.x0),
            y = cast[u32](region.y0),
            width = cast[u32](region.x1 - region.x0),
            height = cast[u32](region.y1 - region.y0),
        },
    }
    presented := false
    match ask(compositor, .Present(frame)) {
        case Presented(_) => {
            compositor.shown = next
            presented = true
        }
        case _ => runtime.log_info("the display didn't present a frame; it's drawn again with the next")
    }
    // Drawn either way: what was replaced isn't read again, and is released; an unpresented frame's damage stays
    if presented {
        compositor.last_damage = compositor.damage
        compositor.damage = canvas.Rect.{}
    }
    now :: slop_os.clock_monotonic() or_else 0
    for &window in compositor.windows {
        if !window.used {
            continue
        }
        if window.replaced != 0 {
            release(compositor, window.client, window.replaced)
            window.replaced = 0
        }
        if window.submitted && presented {
            window.submitted = false
            shown := surface.event_of(.Presented, window.surface)
            shown.time_ns = now
            queue(compositor, window.client, shown, "")
        }
    }
}

/** Draw a region of the frame into a display buffer: the background, then each window from the bottom up. */
draw :: fn(compositor : ptr[mut Compositor], buffer : u32, region : canvas.Rect) {
    canvas.free_canvas(&compositor.painter)
    compositor.painter = canvas.make(compositor.frames[buffer % 2])
    painter :: &compositor.painter
    canvas.clip_rect(
        painter,
        cast[f32](region.x0),
        cast[f32](region.y0),
        cast[f32](region.x1 - region.x0),
        cast[f32](region.y1 - region.y0)
    )
    canvas.fill_rect(
        painter,
        cast[f32](region.x0),
        cast[f32](region.y0),
        cast[f32](region.x1 - region.x0),
        cast[f32](region.y1 - region.y0),
        canvas.Paint.Solid(canvas.rgb(38, 50, 56))
    )
    for pass in cast[usize](0)..<2 {
        // Clients' windows, then the trusted layer's above them
        for i in cast[usize](0)..<MAX_WINDOWS {
            if i < compositor.order_count {
                index :: compositor.order[i]
                if index < MAX_WINDOWS
                    && compositor.windows[index].used
                    && compositor.windows[index].buffer != 0
                    && compositor.windows[index].trusted == (pass == 1) {
                    draw_window(compositor, buffer, index, region)
                }
            }
        }
    }
}

/** Draw a window within a region: its band, its title and close box, then its buffer's pixels. */
draw_window :: fn(compositor : ptr[mut Compositor], buffer : u32, index : usize, region : canvas.Rect) {
    window :: &compositor.windows[index % MAX_WINDOWS]
    painter :: &compositor.painter
    band :: band_of(window)
    if !canvas.is_empty(canvas.intersect(band, region)) {
        focused :: compositor.focus == index
        colour :: if focused {
            canvas.rgb(25, 118, 210)
        }
        else if window.attention { canvas.rgb(255, 160, 0) } else { canvas.rgb(96, 125, 139) }
        canvas.fill_rect(
            painter,
            cast[f32](band.x0),
            cast[f32](band.y0),
            cast[f32](band.x1 - band.x0),
            cast[f32](BAND),
            canvas.Paint.Solid(colour)
        )
        canvas.save(painter)
        close :: close_of(window)
        canvas.clip_rect(
            painter,
            cast[f32](band.x0),
            cast[f32](band.y0),
            cast[f32](close.x0 - 4 - band.x0),
            cast[f32](BAND)
        )
        // Opened where it's used, as a font holds a view of its bytes; the glyph cache keeps its glyphs between frames
        font :: fonts.open(SANS[0..<SANS.count]) or_else fonts.Font.{}
        /*
         * The program's name first, as its dialer named it (Name), dark on a light box no title can draw, since a
         * title is only text on the band's colour; then the title the program chose
         */
        title_at := cast[f32](band.x0 + 8)
        if window.client < compositor.states.count {
            state :: &compositor.states[window.client]
            if state.name_count > 0 {
                name :: state.name[0..<state.name_count]
                wide :: fonts.measure(&font, BAND_TEXT, name)
                canvas.fill_rect(
                    painter,
                    cast[f32](band.x0 + 4),
                    cast[f32](band.y0 + 4),
                    wide + 10,
                    cast[f32](BAND - 8),
                    canvas.Paint.Solid(canvas.rgb(236, 239, 241))
                )
                _ = canvas.draw_text(
                    painter,
                    &font,
                    BAND_TEXT,
                    cast[f32](band.x0 + 9),
                    cast[f32](band.y0 + 19),
                    name,
                    canvas.Paint.Solid(canvas.rgb(33, 33, 33))
                )
                title_at = cast[f32](band.x0 + 4) + wide + 10 + 8
            }
            /*
             * While the program holds the microphone, as the trusted path says, a mark after its name, white on red in a
             * box no title can draw either (decisions/0197, N1)
             */
            if holds_microphone(compositor, window.client) {
                mark :: string_bytes(MICROPHONE_MARK)
                wide :: fonts.measure(&font, BAND_TEXT, mark)
                canvas.fill_rect(
                    painter,
                    title_at - 4,
                    cast[f32](band.y0 + 4),
                    wide + 10,
                    cast[f32](BAND - 8),
                    canvas.Paint.Solid(canvas.rgb(198, 40, 40))
                )
                _ = canvas.draw_text(
                    painter,
                    &font,
                    BAND_TEXT,
                    title_at + 1,
                    cast[f32](band.y0 + 19),
                    mark,
                    canvas.Paint.Solid(canvas.rgb(255, 255, 255))
                )
                title_at = title_at + wide + 10 + 4
            }
        }
        _ = canvas.draw_text(
            painter,
            &font,
            BAND_TEXT,
            title_at,
            cast[f32](band.y0 + 19),
            string_bytes(title_of(window)),
            canvas.Paint.Solid(canvas.rgb(255, 255, 255))
        )
        canvas.restore(painter)
        canvas.fill_rect(
            painter,
            cast[f32](close.x0),
            cast[f32](close.y0),
            cast[f32](CLOSE),
            cast[f32](CLOSE),
            canvas.Paint.Solid(canvas.rgb(229, 57, 53))
        )
    }
    content :: canvas.intersect(canvas.intersect(content_of(window), region), screen(compositor))
    if canvas.is_empty(content) {
        return void
    }
    from :: buffer_of(compositor, window.client, window.buffer) or_return void
    blit(compositor.frames[buffer % 2], from, content, window.x, window.y)
}

/**
 * Copy a client buffer's pixels into a display buffer, within a rectangle of the screen: as they are for XRGB8888,
 * blended over what's there for premultiplied ARGB8888.
 *
 * @param target The display buffer.
 * @param from The client's buffer, the window's size.
 * @param rect Where, on the screen, within the window's content and the screen.
 * @param left The window content's left edge.
 * @param top Its top edge.
 */
blit :: fn(target : canvas.Image, from : ptr[ClientBuffer], rect : canvas.Rect, left : i32, top : i32) {
    source :: view_of(cast[ptr[u8]](from.address), cast[usize](from.bytes))
    blending :: from.format == surface.FORMAT_ARGB8888
    width :: cast[usize](rect.x1 - rect.x0)
    for y in rect.y0..<rect.y1 {
        row :: cast[usize](y - top)
        column :: cast[usize](rect.x0 - left)
        read :: span_of(source, cast[usize](from.offset) + row * cast[usize](from.stride) + 4 * column, 4 * width)
        written :: span(target.pixels, cast[usize](y) * target.stride + 4 * cast[usize](rect.x0), 4 * width)
        if read.count < 4 * width || written.count < 4 * width {
            continue
        }
        // Both are 4 * width bytes, checked above
        if !blending {
            _ = memory.copy(written, read)
            continue
        }
        for pixel in cast[usize](0)..<width {
            over :: span_of(read, 4 * pixel, 4)
            under :: span(written, 4 * pixel, 4)
            if over.count == 4 && under.count == 4 {
                // Opaque pixels copied, and clear ones left, as blending them would
                if over[3] == 255 {
                    under[0] = over[0]
                    under[1] = over[1]
                    under[2] = over[2]
                    continue
                }
                if over[3] == 0 && over[0] == 0 && over[1] == 0 && over[2] == 0 {
                    continue
                }
                keep :: 255 - cast[u32](over[3])
                for channel in cast[usize](0)..<3 {
                    under[channel] = cast[u8](cast[u32](over[channel]) + (cast[u32](under[channel]) * keep + 127) / 255)
                }
            }
        }
    }
}

/** Bytes at an offset, count of them; none past the end. */
span :: fn(bytes : mut u8[], at : usize, count : usize) -> mut u8[] {
    if at <= bytes.count {
        rest :: bytes[at..<bytes.count]
        if count <= rest.count {
            return rest[0..<count]
        }
    }
    return bytes[0..<0]
}

/** Bytes at an offset, count of them, read only; none past the end. */
span_of :: fn(bytes : u8[], at : usize, count : usize) -> u8[] {
    if at <= bytes.count {
        rest :: bytes[at..<bytes.count]
        if count <= rest.count {
            return rest[0..<count]
        }
    }
    return bytes[0..<0]
}

/** Draw the pointer's arrow into the cursor's buffer: white with a black edge, not premultiplied. */
draw_arrow :: fn(compositor : ptr[mut Compositor]) {
    canvas.free_canvas(&compositor.painter)
    compositor.painter = canvas.make(compositor.cursor)
    painter :: &compositor.painter
    canvas.clear(painter, canvas.rgba(0, 0, 0, 0))
    arrow := canvas.Path.{}
    defer canvas.free_path(&arrow)
    canvas.move_to(&arrow, 1, 1)
    canvas.line_to(&arrow, 1, 22)
    canvas.line_to(&arrow, 6.5, 17)
    canvas.line_to(&arrow, 10, 25)
    canvas.line_to(&arrow, 13.5, 23.5)
    canvas.line_to(&arrow, 10, 16)
    canvas.line_to(&arrow, 17, 16)
    canvas.close(&arrow)
    canvas.fill(painter, &arrow, canvas.Paint.Solid(canvas.rgb(255, 255, 255)))
    canvas.stroke(
        painter,
        &arrow,
        canvas.Paint.Solid(canvas.rgb(0, 0, 0)),
        canvas.Stroke.{width = 1.2, join = .Miter, miter_limit = 4}
    )
    pixels :: compositor.cursor.pixels
    for at in cast[usize](0)..<pixels.count / 4 {
        pixel :: span(pixels, 4 * at, 4)
        if pixel.count < 4 {
            continue
        }
        alpha :: cast[u32](pixel[3])
        if alpha == 0 || alpha == 255 {
            continue
        }
        for channel in cast[usize](0)..<3 {
            value :: cast[u32](pixel[channel]) * 255 / alpha
            pixel[channel] = cast[u8](if value > 255 { cast[u32](255) } else { value })
        }
    }
}
