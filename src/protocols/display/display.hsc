package display

import os from "std"
import slop_os from "std/os"

/*
 * The device class of displays (decisions/0192, 15b; design/display.md §2): a screen of one mode, its scanout buffers
 * in DMA memory a client reaches through windows (GetBuffer) and draws into, presented with the rectangle that
 * changed; and a cursor plane, for a pointer that moves without the screen being drawn again. One client at a time,
 * the compositor; a Connect while there's one is closed. Connections arrive on the driver's listener as Connects.
 *
 * A buffer's pixels are rows of stride bytes, top first, each pixel 4 bytes in the format Info says. Buffers take
 * turns: a client draws into one that isn't shown, presents it, and draws into another while it's shown; the buffer
 * shown before it is free again once Presented answers. What a Present copies may be only its damage, so a buffer's
 * damage is everything that differs from what that buffer held when it was last presented: with two buffers, the
 * damage of the frame before as well as this one's.
 */

/**
 * The display protocol, for the channels between a display's driver and its client, and its listener: the client
 * sends the requests, and the driver answers them.
 */
Display :: struct {}

/**
 * What the protocol says of itself: its name, which its channels' tag is made from, its major version, and that the
 * server, here the driver, pays for its work, and its buffers, from its own budget.
 */
PROTOCOL :: slop_os.Protocol.{name = "display", major_version = 1, lending = .Server}

/**
 * The format of 32-bit pixels of blue, green, red then a byte not shown, in memory order: DRM's XRGB8888, its
 * four-character code "XR24".
 */
FORMAT_XRGB8888 : u32 : 0x34325258
/**
 * The format of 32-bit pixels of blue, green, red then alpha, in memory order, not premultiplied: DRM's ARGB8888, its
 * four-character code "AR24". The cursor's.
 */
FORMAT_ARGB8888 : u32 : 0x34325241

/** GetBuffer's index of the cursor's buffer, past any scanout buffer's. */
CURSOR_BUFFER : u32 : 0xffff_ffff

/** What the display is. */
Info :: struct {
    /** Its width in pixels, at least 1. */
    width : u32,
    /** Its height in pixels, at least 1. */
    height : u32,
    /** The bytes from one row of a scanout buffer to the next, at least 4 times width. */
    stride : u32,
    /** Its scanout buffers' format: FORMAT_XRGB8888. */
    format : u32,
    /** How many scanout buffers it has, numbered from 0: 1 or more. */
    buffers : u32,
    /**
     * The cursor plane's width and height in pixels, its buffer cursor_size rows of 4 times cursor_size bytes in
     * FORMAT_ARGB8888; 0 for a display without one, whose client draws the pointer itself.
     */
    cursor_size : u32,
    /** How often it refreshes, in thousandths of a hertz; 0 when it doesn't say. */
    refresh_millihertz : u32,
}

/** A rectangle of the screen, in pixels from its top left. */
Rect :: struct {
    /** Its left edge. */
    x : u32,
    /** Its top edge. */
    y : u32,
    /** Its width; 0 for none. */
    width : u32,
    /** Its height; 0 for none. */
    height : u32,
}

/** A frame to show: which buffer, and what in it changed. */
Frame :: struct {
    /** The scanout buffer, below Info's buffers. */
    buffer : u32,
    /**
     * Everything in it that differs from what it held when it was last presented, cut to the screen; the whole of it
     * the first time it's presented, whatever this says.
     */
    damage : Rect,
}

/** The cursor's image and where its hot spot is. */
Cursor :: struct {
    /** The hot spot's column in the cursor's image, below Info's cursor_size: the pixel at the pointer's position. */
    hot_x : u32,
    /** The hot spot's row in the cursor's image, below Info's cursor_size. */
    hot_y : u32,
    /** Whether it's shown; false hides it. */
    visible : bool,
}

/** Where the pointer is on the screen, in pixels from its top left; the cursor's hot spot goes there. */
Position :: struct {
    /** Across, which may be past the screen's edges, the cursor then partly or wholly off it. */
    x : i32,
    /** Down, as x. */
    y : i32,
}

/** Why a request wasn't done. */
Refusal :: enum #backed_by(u32) {
    /** A buffer that isn't one of the display's. */
    NoSuchBuffer = 1,
    /** The device said it failed. */
    DeviceError = 2,
    /** Its window couldn't be made, as when the driver's budget is spent. */
    NoMemory = 3,
}

/** What the display's client asks its driver. */
Request :: union {
    /** Ask what the display is. Answered with Described. */
    Describe,
    /**
     * Ask for a window onto a buffer, read-write: a scanout buffer by its index, or the cursor's by CURSOR_BUFFER. Its
     * pixels are black, the cursor's transparent, until drawn. Answered with Buffer, or Refused.
     */
    GetBuffer(u32),
    /**
     * Show a buffer, drawn first and then left alone until it's answered. Answered with Presented, once it's shown,
     * or Refused, the buffer shown before still shown.
     */
    Present(Frame),
    /**
     * Take the cursor's image from its buffer, drawn first, with its hot spot, or hide it. Not answered; nothing on a
     * display without a cursor plane.
     */
    SetCursor(Cursor),
    /** Move the cursor's hot spot. Not answered; nothing on a display without a cursor plane. */
    MoveCursor(Position),
    /**
     * Have the driver serve another client, on the end given, which moves to the driver; it's closed if the driver
     * already has its client. Sent on the listener, and answered with nothing.
     */
    Connect(os.Channel[Display]),
}

/** What a display's driver answers. */
Response :: union {
    /** Describe's answer: what the display is. */
    Described(Info),
    /** GetBuffer's answer: the window, which moves to the client. The buffer goes when the driver does. */
    Buffer(slop_os.Memory),
    /**
     * Present's answer: the buffer presented is shown, and the one shown before it, if another, can be drawn into
     * again.
     */
    Presented(u32),
    /** GetBuffer's or Present's answer when it wasn't done, and why. */
    Refused(Refusal),
    /** The answer to a request the driver doesn't know, as from a newer client; every protocol has it. */
    Unsupported,
}

/**
 * Tell whether a request may be sent again, after a reconnect, without doing more than sending it once did.
 *
 * @param request The request, which isn't changed.
 * @return True for every request: a buffer shown again shows the same, and the cursor set again is as it was.
 */
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return match request^ {
        case Describe => true
        case GetBuffer(_) => true
        case Present(_) => true
        case SetCursor(_) => true
        case MoveCursor(_) => true
        case Connect(_) => true
    }
}

#insert os.protocol_code(Request, Response)

/**
 * Make a new connection to a display's driver: a channel for the protocol, one end sent to it in a Connect, as
 * input.connect does.
 *
 * It doesn't wait: the driver takes the end when it next serves its listener, or closes it when it already has its
 * client, which the caller learns of as its end's peer gone.
 *
 * @param end The driver's listener, or any connection to it, kept by the caller.
 * @param port A port bound to end, waited on while end's ring is full.
 * @param budget The memory budget that pays for the new channel.
 * @return The caller's end of the new connection, its own to keep and close; null if the channel couldn't be made, or
 *     the Connect couldn't be sent, in which case both its ends are closed.
 */
connect :: fn(end: slop_os.Channel, port: slop_os.Port, budget: slop_os.MemoryBudget) -> os.Channel[Display]? {
    pair :: os.channel_for[Display](budget, 0) or_return null
    out := os.Outgoing.{}
    request :: os.begin[Request](&out)
    request^ = .Connect(os.Channel[Display].{end = pair.a})
    match send_request(end, port, &out) {
        case Some(error) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.a))
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
            return null
        }
        case None => return os.Channel[Display].{end = pair.b}
    }
}
