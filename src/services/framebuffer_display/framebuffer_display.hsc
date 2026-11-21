/**
 * The framebuffer display (decisions/0192, 15g; design/display.md §2): the display protocol over the framebuffer the
 * firmware left, for a machine with no GPU the system drives, so the compositor runs there too. The screen is the
 * console's as well: the terminal service lends the framebuffer while the seat's lent to the compositor, and takes it
 * back on the secure attention key (the screen protocol).
 *
 * It has two scanout buffers of its own memory, which its client draws into through windows, and no cursor plane, so
 * the compositor draws the pointer. A frame presented while the framebuffer's lent has its damage copied onto it; one
 * presented while it isn't is only kept, and the last frame's drawn whole when it's lent again. Either way Present is
 * answered at once, as a screen no one's looking at is still shown.
 *
 * It says what it does in its debug log: "serving <width> by <height>", "drawing on the framebuffer" when it's lent,
 * "gave the framebuffer back", and why a lend was refused.
 */
package framebuffer_display

import runtime from "base:runtime"
import os from "std:os"
import slop_os from "std:os/slop_os"
import service_kit from "../../libraries/service_kit"
import display from "../../protocols/display"
import screen from "../../protocols/screen"

/** How many scanout buffers it has. */
BUFFERS : u32 : 2
/** A page's size in bytes. */
PAGE : u64 : 4096
/** The most pixels a side of the framebuffer it takes, so its sizes in bytes stay well within their integers. */
MOST_SIDE : u32 : 16384

/** The framebuffer display's state, made once in main, on the heap. */
Display :: struct {
    /** The port its clients' ends are bound to, waited on in main. */
    port : slop_os.Port,
    /** Its display clients: the listener, and the compositor once it connects. */
    clients : service_kit.Clients,
    /** Which of clients is the compositor; null before it connects, and once it's gone. */
    client : usize?,
    /** Its screen clients: the listener, and the terminal service once it connects. */
    lenders : service_kit.Clients,
    /** What the display is, from the framebuffer's layout. */
    info : display.Info,
    /** Each scanout buffer's bytes, a multiple of PAGE. */
    frame_bytes : u64,
    /** The scanout buffers, one after the other, its own memory, which the windows it gives are onto. */
    frames : slop_os.Memory,
    /** Where frames is mapped, readable, in its address space. */
    frames_at : u64,
    /** Which buffers have been presented at least once, a bit each. */
    presented : u32,
    /** The buffer presented last; BUFFERS for none yet. */
    shown : u32,
    /** Whether the framebuffer's lent, and mapped at pixels_at. */
    lent : bool,
    /** The framebuffer's pixels, while it's lent; its handle the display's, closed when it's given back. */
    pixels : slop_os.Memory,
    /** Where pixels is mapped, readable and writable, while it's lent; 0 when it isn't. */
    pixels_at : u64,
    /** The framebuffer's bytes from one row to the next, from its layout. */
    pitch : u64,
    /** The framebuffer's layout page, while it's lent; its handle the display's. */
    layout : slop_os.Memory,
}

/**
 * Serve the display protocol over the firmware's framebuffer, until the system stops.
 *
 * @param log Its debug log; its lines go through base's logger otherwise.
 * @param layout The framebuffer's layout page (slop_os.FramebufferLayout), read once for the screen's size; its pixels
 *     come later, lent. Its handle's closed once it's read.
 * @param clients The listener the compositor's Connect arrives on.
 * @param lenders Its end of the terminal service's connection, which lends it the framebuffer.
 * @return It doesn't return while it serves; 0 once it's asked to stop. 99 if its state couldn't be had
 *     (decisions/0104),
 *     2 if the layout couldn't be read or isn't 32 bits a pixel, 3 if no port could be made, 4 if its buffers couldn't
 *     be made or mapped, 5 if a listener couldn't be bound.
 */
main :: fn(
    log : slop_os.DebugLog?,
    layout : slop_os.Memory,
    clients : os.Listener[display.Display],
    lenders : os.Listener[screen.Screen]
) -> int {
    startup :: slop_os.startup_block()
    made, error :: runtime.new_aligned(Display, align_of(Display))
    if error != null {
        return 99
    }
    shown :: made
    shown.shown = BUFFERS
    read : u8[64]
    if slop_os.memory_read(layout, 0, read[0..<read.count]) is_error {
        return 2
    }
    _ = slop_os.handle_close(cast[slop_os.Handle](layout))
    given :: cast[ptr[slop_os.FramebufferLayout]](&read[0])^
    if given.bits_per_pixel != 32 || given.width == 0 || given.height == 0 {
        runtime.log_info("the framebuffer isn't 32 bits a pixel: % bits", given.bits_per_pixel)
        return 2
    }
    // A row's pixels within its pitch, and sizes whose bytes can't wrap, or the last row's written past the mapping
    if given.width > MOST_SIDE || given.height > MOST_SIDE || cast[u64](given.pitch) < 4 * cast[u64](given.width) {
        runtime.log_info(
            "the framebuffer's layout doesn't add up: % by %, % bytes a row",
            given.width,
            given.height,
            given.pitch
        )
        return 2
    }
    stride :: 4 * given.width
    shown.frame_bytes = (cast[u64](stride) * cast[u64](given.height) + PAGE - 1) / PAGE * PAGE
    shown.info = display.Info.{
        width = given.width,
        height = given.height,
        stride = stride,
        format = display.FORMAT_XRGB8888,
        buffers = BUFFERS,
    }
    shown.port = slop_os.port_create(startup.budget) or_return 3
    _ = service_kit.watch_stop(shown.port)
    total :: cast[u64](BUFFERS) * shown.frame_bytes
    shown.frames = slop_os.memory_create(startup.budget, total) or_return 4
    shown.frames_at = runtime.reserve_addresses(cast[usize](total)) or_return 4
    slop_os.memory_map(shown.frames, startup.space, shown.frames_at, 0, total, slop_os.PROTECTION_READ) or_return 4
    if !service_kit.add_client(&shown.clients, shown.port, clients.end)
        || !service_kit.add_client(&shown.lenders, shown.port, lenders.end) {
        return 5
    }
    runtime.log_info("serving % by %", given.width, given.height)
    into := os.Incoming.{}
    loop {
        for i in cast[usize](0)..<shown.clients.count {
            serve(shown, i, &into)
        }
        for i in cast[usize](0)..<shown.lenders.count {
            serve_lender(shown, i, &into)
        }
        if service_kit.stopping() {
            return 0
        }
        packets : slop_os.Packet[8]
        _ = slop_os.port_wait(shown.port, packets, slop_os.NO_DEADLINE)
    }
}

/**
 * Answer every request waiting from one display client: the listener's Connect makes the compositor its client,
 * closing the end when there's one already; Describe, GetBuffer and Present are answered; the cursor's requests are
 * nothing, as there's no cursor plane.
 *
 * @param shown The display.
 * @param index Which of its clients; one past them, or a freed place, is nothing to serve.
 * @param into Where each request is received, reused for each.
 */
serve :: fn(shown : ptr[mut Display], index : usize, into : ptr[mut os.Incoming]) {
    if index >= shown.clients.ends.count {
        return void
    }
    end :: shown.clients.ends[index]
    if cast[slop_os.Handle](end) == slop_os.NO_HANDLE {
        return void
    }
    is_client :: (shown.client or_else shown.clients.ends.count) == index
    loop {
        match display.receive_request(end, shown.port, into, false) {
            case Received => {}
            case Empty => return void
            case Unsupported => {
                _ = display.answer_unsupported(end, shown.port)
                continue
            }
            case _ => {
                service_kit.drop_client(&shown.clients, index)
                if is_client {
                    shown.client = null
                }
                return void
            }
        }
        out := os.Outgoing.{}
        response :: os.begin[display.Response](&out)
        answered := true
        match os.message_of[display.Request](into)^ {
            case Connect(connection) => {
                answered = false
                if shown.client is_some {
                    _ = slop_os.handle_close(cast[slop_os.Handle](connection.end))
                }
                else {
                    match service_kit.add_client_index(&shown.clients, shown.port, connection.end) {
                        case Some(added) => shown.client = added
                        case None => _ = slop_os.handle_close(cast[slop_os.Handle](connection.end))
                    }
                }
            }
            case Describe => response^ = .Described(shown.info)
            case GetBuffer(buffer) => response^ = buffer_window(shown, buffer)
            case Present(frame) => response^ = present(shown, frame)
            case SetCursor(_) => answered = false
            case MoveCursor(_) => answered = false
        }
        if answered && is_client {
            _ = display.send_response(end, shown.port, &out)
        }
    }
}

/**
 * Make a window onto a scanout buffer, for GetBuffer.
 *
 * @return Buffer with the window; Refused NoSuchBuffer for the cursor's, or past the buffers, or NoMemory.
 */
buffer_window :: fn(shown : ptr[mut Display], buffer : u32) -> display.Response {
    if buffer >= BUFFERS {
        return .Refused(.NoSuchBuffer)
    }
    budget :: slop_os.startup_block().budget
    match slop_os.memory_create_window(shown.frames, budget, cast[u64](buffer) * shown.frame_bytes, shown.frame_bytes) {
        case Ok(window) => return .Buffer(window)
        case Error(error) => return .Refused(.NoMemory)
    }
}

/**
 * Show a frame, for Present: its damage copied onto the framebuffer while it's lent, all of it the first time the
 * buffer's presented; kept to draw whole when it's lent again otherwise.
 *
 * @return Presented with the buffer; Refused NoSuchBuffer for one that isn't the display's.
 */
present :: fn(shown : ptr[mut Display], frame : display.Frame) -> display.Response {
    if frame.buffer >= BUFFERS {
        return .Refused(.NoSuchBuffer)
    }
    whole :: display.Rect.{width = shown.info.width, height = shown.info.height}
    bit :: cast[u32](1) << frame.buffer
    rect :: if shown.presented & bit == 0 { whole } else { clipped(frame.damage, whole) }
    shown.presented = shown.presented | bit
    shown.shown = frame.buffer
    if shown.lent {
        copy_to_framebuffer(shown, frame.buffer, rect)
    }
    return .Presented(frame.buffer)
}

/** A rectangle cut to the screen's; empty when they don't meet. */
clipped :: fn(rect : display.Rect, whole : display.Rect) -> display.Rect {
    if rect.x >= whole.width || rect.y >= whole.height {
        return display.Rect.{}
    }
    width :: if rect.width < whole.width - rect.x { rect.width } else { whole.width - rect.x }
    height :: if rect.height < whole.height - rect.y { rect.height } else { whole.height - rect.y }
    return display.Rect.{x = rect.x, y = rect.y, width = width, height = height}
}

/**
 * Copy a rectangle of a scanout buffer onto the framebuffer, a row at a time.
 *
 * @param shown The display, its framebuffer lent and mapped.
 * @param buffer The scanout buffer, below BUFFERS.
 * @param rect What's copied, within the screen.
 */
copy_to_framebuffer :: fn(shown : ptr[Display], buffer : u32, rect : display.Rect) {
    if !shown.lent || shown.pixels_at == 0 || rect.width == 0 || rect.height == 0 {
        return void
    }
    stride :: cast[u64](shown.info.stride)
    from :: shown.frames_at + cast[u64](buffer) * shown.frame_bytes
    row_bytes :: cast[usize](rect.width) * 4
    for y in rect.y..<(rect.y + rect.height) {
        source :: view_of(cast[ptr[u8]](from + cast[u64](y) * stride + cast[u64](rect.x) * 4), row_bytes)
        target :: view_of(
            cast[ptr[mut u8]](shown.pixels_at + cast[u64](y) * shown.pitch + cast[u64](rect.x) * 4),
            row_bytes
        )
        for i in cast[usize](0)..<target.count {
            if i < source.count {
                target[i] = source[i]
            }
        }
    }
}

/**
 * Answer every request waiting from one screen client: the listener's Connect makes the terminal service a client;
 * Lend maps the framebuffer and draws the last frame whole on it; TakeBack unmaps it.
 *
 * @param shown The display.
 * @param index Which of its lenders; one past them, or a freed place, is nothing to serve.
 * @param into Where each request is received, reused for each.
 */
serve_lender :: fn(shown : ptr[mut Display], index : usize, into : ptr[mut os.Incoming]) {
    if index >= shown.lenders.ends.count {
        return void
    }
    end :: shown.lenders.ends[index]
    if cast[slop_os.Handle](end) == slop_os.NO_HANDLE {
        return void
    }
    loop {
        match screen.receive_request(end, shown.port, into, false) {
            case Received => {}
            case Empty => return void
            case Unsupported => {
                _ = screen.answer_unsupported(end, shown.port)
                continue
            }
            case _ => {
                service_kit.drop_client(&shown.lenders, index)
                // The terminal service gone, the framebuffer's its next one's: nothing more's drawn on it
                take_back(shown)
                return void
            }
        }
        out := os.Outgoing.{}
        response :: os.begin[screen.Response](&out)
        match os.message_of[screen.Request](into)^ {
            case Lend(given) => response^ = if lend(shown, given) { .Done } else { .Refused }
            case TakeBack => {
                take_back(shown)
                response^ = .Done
            }
        }
        _ = screen.send_response(end, shown.port, &out)
    }
}

/**
 * Take the framebuffer lent: its layout checked against the screen's, its pixels mapped, and the last frame drawn on
 * it whole. One lent already is given back first.
 *
 * @return Whether it's drawn on from now on; false, its handles closed, if its layout doesn't match or it couldn't be
 *     mapped.
 */
lend :: fn(shown : ptr[mut Display], given : screen.Lent) -> bool {
    take_back(shown)
    startup :: slop_os.startup_block()
    read : u8[64]
    if slop_os.memory_read(given.layout, 0, read[0..<read.count]) is_error {
        return refuse(given, "its layout couldn't be read")
    }
    layout :: cast[ptr[slop_os.FramebufferLayout]](&read[0])^
    if layout.width != shown.info.width || layout.height != shown.info.height || layout.bits_per_pixel != 32 {
        return refuse(given, "it isn't the screen it was")
    }
    bytes :: (cast[u64](layout.pitch) * cast[u64](layout.height) + PAGE - 1) / PAGE * PAGE
    at :: runtime.reserve_addresses(cast[usize](bytes)) or_else 0
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    if at == 0 || (slop_os.memory_map(given.pixels, startup.space, at, 0, bytes, read_write) is_error) {
        return refuse(given, "it couldn't be mapped")
    }
    shown.pixels = given.pixels
    shown.layout = given.layout
    shown.pixels_at = at
    shown.pitch = cast[u64](layout.pitch)
    shown.lent = true
    runtime.log_info("drawing on the framebuffer")
    if shown.shown < BUFFERS {
        copy_to_framebuffer(shown, shown.shown, display.Rect.{width = shown.info.width, height = shown.info.height})
    }
    return true
}

/** Refuse a framebuffer lent, saying why: its handles closed. Gives false, for lend to give. */
refuse :: fn(given : screen.Lent, why : string) -> bool {
    runtime.log_info("refused the framebuffer: %", why)
    _ = slop_os.handle_close(cast[slop_os.Handle](given.pixels))
    _ = slop_os.handle_close(cast[slop_os.Handle](given.layout))
    return false
}

/** Give the framebuffer back, if it's lent: unmapped, and its handles closed; nothing's drawn on it after. */
take_back :: fn(shown : ptr[mut Display]) {
    if !shown.lent {
        return void
    }
    _ = slop_os.memory_unmap(slop_os.startup_block().space, shown.pixels_at)
    _ = slop_os.handle_close(cast[slop_os.Handle](shown.pixels))
    _ = slop_os.handle_close(cast[slop_os.Handle](shown.layout))
    shown.lent = false
    shown.pixels_at = 0
    runtime.log_info("gave the framebuffer back")
}
#assert size_of(slop_os.FramebufferLayout) <= 64
