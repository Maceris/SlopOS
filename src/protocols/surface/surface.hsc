package surface

import os from "std"
import slop_os from "std/os"

/*
 * The compositor's protocol (decisions/0192, 15c; design/display.md §3): a client's windows, each a surface the client
 * draws into buffers of its own memory and submits with what changed, and the input the compositor gives it while one
 * of its surfaces has focus or the pointer.
 *
 * From the first version it has what other systems added later (display.md §1), though M15 uses only the simplest
 * case of each: buffers described by a format, a layout modifier and up to MAX_PLANES planes (linear, one plane, in
 * M15); a colour space (sRGB); a scale; FIFO and mailbox presenting, with a target time; subsurfaces; and explicit
 * sync, a submission's acquire fence and its buffer's release, where M15's buffers are always ready when submitted.
 *
 * A surface's size is in logical units, its buffer's in pixels: scale pixels to the unit, in 120ths (120 is 1:1). The
 * client draws into a buffer, submits it, and leaves it alone until Released says the compositor is done with it; a
 * Presented says when the frame was shown, for pacing. Events come in order through a held Read.
 */

/**
 * The surface protocol, for the channels between the compositor and its clients, and its listener: the clients send
 * the requests, and the compositor answers them.
 */
Surface :: struct {}

/**
 * What the protocol says of itself: its name, which its channels' tag is made from, its major version, and that the
 * client's budget is lent for each of its connections, which pays for the compositor's work on its surfaces.
 */
PROTOCOL :: slop_os.Protocol.{name = "surface", major_version = 1, lending = .PerConnection}

/** Pixels of blue, green, red then a byte not shown, in memory order: DRM's XRGB8888, "XR24". */
FORMAT_XRGB8888 : u32 : 0x34325258
/** Pixels of blue, green, red then alpha, in memory order, premultiplied: DRM's ARGB8888, "AR24". */
FORMAT_ARGB8888 : u32 : 0x34325241
/** The layout modifier of rows one after another, DRM's DRM_FORMAT_MOD_LINEAR. */
MODIFIER_LINEAR : u64 : 0
/** The most planes a buffer has: 3, as YUV's. */
MAX_PLANES :: 3
/** A scale of 1, a pixel to the logical unit, in 120ths. */
SCALE_ONE : u32 : 120
/** The most events one Events has. */
MAX_EVENTS :: 32
/** The most bytes of text one Events has, for all its events. */
MAX_TEXT :: 256

/** One plane of a buffer: where it starts in the buffer's memory, and how far apart its rows are. */
Plane :: struct {
    /** Where its first row starts, in bytes from the memory's start. */
    offset : u64,
    /** The bytes from one row to the next. */
    stride : u32,
}

/** What a buffer holds and how it's laid out. */
BufferDescription :: struct {
    /** Its format, a FORMAT_ value; the compositor takes those Described lists. */
    format : u32,
    /** Its layout modifier: MODIFIER_LINEAR in M15. */
    modifier : u64,
    /** Its width in pixels, at least 1. */
    width : u32,
    /** Its height in pixels, at least 1. */
    height : u32,
    /** How many of planes it has, 1 to MAX_PLANES; one for the FORMAT_ values here. */
    plane_count : u32,
    /** Its planes, the first plane_count of them, each within the buffer's memory. */
    planes : Plane[MAX_PLANES],
}

/** The colours a surface's pixels are in. */
ColorSpace :: enum #backed_by(u8) {
    /** sRGB's primaries and transfer function: M15's only one. */
    Srgb = 1,
}

/** How a surface's submissions are shown. */
PresentMode :: enum #backed_by(u8) {
    /** Each submission shown, one a refresh, in order: the default. */
    Fifo = 1,
    /** The newest submission shown at the next refresh, those before it that weren't shown released unshown. */
    Mailbox = 2,
}

/** A rectangle, in a buffer's pixels or a surface's units as its use says. */
Rect :: struct {
    /** Its left edge. */
    x : i32,
    /** Its top edge. */
    y : i32,
    /** Its width; 0 for none. */
    width : u32,
    /** Its height; 0 for none. */
    height : u32,
}

/** The screen, as the compositor shows it. */
Output :: struct {
    /** Its width in logical units. */
    width : u32,
    /** Its height in logical units. */
    height : u32,
    /** Its pixels to the logical unit, in 120ths. */
    scale : u32,
    /** How often it refreshes, in thousandths of a hertz; 0 when it doesn't say. */
    refresh_millihertz : u32,
    /** The formats the compositor takes, a bit each: 1 for FORMAT_XRGB8888, 2 for FORMAT_ARGB8888. */
    formats : u32,
}

/** A new window. */
WindowSpec :: struct {
    /** Its width in logical units, at least 1; the compositor may give it another with a Configure. */
    width : u32,
    /** Its height in logical units, at least 1. */
    height : u32,
    /** Its buffers' pixels to its logical unit, in 120ths: SCALE_ONE, or the Output's for sharp text. */
    scale : u32,
    /** Its pixels' colours. */
    color : ColorSpace,
    /** Its title, UTF-8, shown in its identity band after the program's name; at most 128 bytes are kept. */
    title : slop_os.Relative[u8],
}

/** A new subsurface: a surface drawn over its parent, at an offset, moving with it. */
SubsurfaceSpec :: struct {
    /** The parent, one of the client's surfaces. */
    parent : u32,
    /** Its left edge in the parent's units. */
    x : i32,
    /** Its top edge in the parent's units. */
    y : i32,
    /** Its width in logical units, at least 1. */
    width : u32,
    /** Its height in logical units, at least 1. */
    height : u32,
    /** Its buffers' pixels to its logical unit, in 120ths. */
    scale : u32,
}

/** A buffer the client gives, in memory of its own. */
NewBuffer :: struct {
    /** The client's number for it, not 0, nor one of its buffers'. */
    id : u32,
    /** Its memory, which moves to the compositor, mapped read-only; every plane has to lie within it. */
    memory : slop_os.Memory,
    /** What it holds. */
    description : BufferDescription,
}

/** A frame of a surface. */
Submission :: struct {
    /** The surface. */
    surface : u32,
    /** The buffer, one of the client's, its pixels the surface's size times its scale; 0 hides the surface. */
    buffer : u32,
    /** What changed since the buffer was last submitted, in its pixels; the whole of it, the first time. */
    damage : Rect,
    /** How it's shown. */
    mode : PresentMode,
    /** When it's wanted on the screen, in the monotonic clock's nanoseconds; 0 for as soon as it can be. */
    target_ns : u64,
}

/** A surface's title. */
Title :: struct {
    /** The window. */
    surface : u32,
    /** The title, UTF-8; at most 128 bytes are kept. */
    text : slop_os.Relative[u8],
}

/** What a client offers to be pasted: typed data, in up to a few representations. */
Offer :: struct {
    /** The data's schema's hash (decisions/0040), what it is. */
    schema : u8[32],
    /** The data, in its schema's encoding, as memory that moves to the compositor. */
    data : slop_os.Memory,
    /** How many bytes of data there are. */
    bytes : u64,
    /** The same as plain text, UTF-8, for clients that don't know the schema; empty for none. */
    text : slop_os.Relative[u8],
}

/** Why a request wasn't done. */
Refusal :: enum #backed_by(u32) {
    /** A surface or buffer the client doesn't have. */
    NoSuchThing = 1,
    /** A size, scale, format, modifier or plane the compositor doesn't take, or a plane outside its memory. */
    Unsupported = 2,
    /** The client has as many surfaces or buffers as it may. */
    TooMany = 3,
    /** The memory couldn't be mapped, or the client's budget is spent. */
    NoMemory = 4,
}

/** What an event is, as Event's kind holds it. */
EventKind :: enum #backed_by(u8) {
    /** A window's size is now width by height logical units; its next buffer should be. */
    Configure = 1,
    /** The user asked to close a window. */
    CloseRequested = 2,
    /** A window has the keyboard's focus. */
    FocusIn = 3,
    /** A window lost it. */
    FocusOut = 4,
    /** The pointer came over a surface, at x and y in its units. */
    PointerEnter = 5,
    /** The pointer left a surface. */
    PointerLeave = 6,
    /** The pointer moved over a surface, to x and y in its units. */
    PointerMotion = 7,
    /** A button, code from 0 (left), pressed or let go, over a surface at x and y. */
    Button = 8,
    /** A wheel turned y notches, positive away from the user, over a surface. */
    Wheel = 9,
    /** A key pressed or let go in the focused window: code its HID usage, modifiers held, its text in the Events'. */
    Key = 10,
    /** A buffer, code its id, is the client's again. */
    Released = 11,
    /** A surface's frame was shown, at time_ns. */
    Presented = 12,
    /** Text pasted into the focused window on the user's gesture, in the Events' text. */
    Paste = 13,
}

/** One event, plain data; kind_of tells its kind. */
Event :: struct {
    /** An EventKind's value; one this version doesn't know is null from kind_of, which a client skips. */
    kind : u8,
    /** For a Key or a Button, 1 if it's down, 0 if it was let go; 0 otherwise. */
    pressed : u8,
    /** For a Key, the modifier bits held, as std/os/slop_os's terminal names them; 0 otherwise. */
    modifiers : u8,
    /** The surface it's for, or 0 for a Released. */
    surface : u32,
    /** For a Key, its HID usage; for a Button, which; for a Released, the buffer's id; 0 otherwise. */
    code : u32,
    /** For a Configure, the width; for the pointer's, where across in the surface's units; 0 otherwise. */
    x : i32,
    /** For a Configure, the height; for the pointer's, where down; for a Wheel, how far it turned; 0 otherwise. */
    y : i32,
    /** For a Presented, when, in the monotonic clock's nanoseconds; 0 otherwise. */
    time_ns : u64,
    /** Where its text starts in its Events' text, in bytes. */
    text_start : u32,
    /** How many bytes of text it has, as UTF-8; 0 for none. */
    text_bytes : u32,
}

/** Events, oldest first, and their text. */
Events :: struct {
    /** The events, 1 to MAX_EVENTS of them. */
    events : slop_os.Relative[Event],
    /** The events' text, each one's at its text_start, as UTF-8. */
    text : slop_os.Relative[u8],
}

/** What a client asks the compositor. */
Request :: union {
    /** Ask what the screen is. Answered with Described. */
    Describe,
    /** Make a window, shown once it's first submitted, given focus then. Answered with Created, or Refused. */
    CreateWindow(WindowSpec),
    /** Make a subsurface of one of the client's surfaces. Answered with Created, or Refused. */
    CreateSubsurface(SubsurfaceSpec),
    /** Give the compositor a buffer. Answered with Added, or Refused. */
    AddBuffer(NewBuffer),
    /** Take a buffer back, its memory unmapped once no surface shows it. Not answered. */
    RemoveBuffer(u32),
    /** Show a frame. Answered with a Released event for the buffer it replaces, and a Presented once it's shown; Refused if not. */
    Submit(Submission),
    /** Change a window's title. Not answered. */
    SetTitle(Title),
    /** End a surface, and its subsurfaces. Not answered. */
    Destroy(u32),
    /** Ask for up to this many events, 0 taken as 1; held until there's at least one. Answered with Input. */
    Read(u32),
    /** Offer data to be pasted, replacing the client's offer before. Not answered. */
    Copy(Offer),
    /**
     * Have the compositor serve another client, on the end given, which moves to it; it's closed if the compositor
     * has as many clients as it takes. Sent on the listener, and answered with nothing.
     */
    Connect(os.Channel[Surface]),
}

/** What the compositor answers. */
Response :: union {
    /** Describe's answer. */
    Described(Output),
    /** CreateWindow's or CreateSubsurface's answer: the new surface's number, from 1. */
    Created(u32),
    /** AddBuffer's answer: the buffer's id. */
    Added(u32),
    /** Read's answer: the events waiting, at most MAX_EVENTS and as many as fit MAX_TEXT bytes, at least one. */
    Input(Events),
    /** A request that wasn't done, and why. */
    Refused(Refusal),
    /** The answer to a request the compositor doesn't know, as from a newer client; every protocol has it. */
    Unsupported,
}

/**
 * Tell what an event is.
 *
 * @param event The event, as it came.
 * @return Its kind; null for a kind value this version doesn't have.
 */
kind_of :: fn(event: Event) -> EventKind? {
    return match event.kind {
        case 1 => EventKind.Configure
        case 2 => EventKind.CloseRequested
        case 3 => EventKind.FocusIn
        case 4 => EventKind.FocusOut
        case 5 => EventKind.PointerEnter
        case 6 => EventKind.PointerLeave
        case 7 => EventKind.PointerMotion
        case 8 => EventKind.Button
        case 9 => EventKind.Wheel
        case 10 => EventKind.Key
        case 11 => EventKind.Released
        case 12 => EventKind.Presented
        case 13 => EventKind.Paste
        case _ => null
    }
}

/** Make an event of a kind for a surface, its other fields 0. */
event_of :: fn(kind: EventKind, surface: u32) -> Event {
    return Event.{kind = cast[u8](kind), surface = surface}
}

/**
 * Tell whether a request may be sent again, after a reconnect, without doing more than sending it once did.
 *
 * @param request The request, which isn't changed.
 * @return False for those that make something or take events: CreateWindow, CreateSubsurface, AddBuffer, Submit and
 *     Read; true for the rest.
 */
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return match request^ {
        case Describe => true
        case CreateWindow(_) => false
        case CreateSubsurface(_) => false
        case AddBuffer(_) => false
        case RemoveBuffer(_) => true
        case Submit(_) => false
        case SetTitle(_) => true
        case Destroy(_) => true
        case Read(_) => false
        case Copy(_) => true
        case Connect(_) => true
    }
}

#insert os.protocol_code(Request, Response)

/**
 * Make a new connection to the compositor: a channel for the protocol, one end sent to it in a Connect, as
 * input.connect does.
 *
 * @param end The compositor's listener, or any connection to it, kept by the caller.
 * @param port A port bound to end, waited on while end's ring is full.
 * @param budget The memory budget that pays for the new channel.
 * @return The caller's end of the new connection; null if it couldn't be made or sent, both its ends then closed.
 */
connect :: fn(end: slop_os.Channel, port: slop_os.Port, budget: slop_os.MemoryBudget) -> os.Channel[Surface]? {
    pair :: os.channel_for[Surface](budget, 0) or_return null
    out := os.Outgoing.{}
    request :: os.begin[Request](&out)
    request^ = .Connect(os.Channel[Surface].{end = pair.a})
    match send_request(end, port, &out) {
        case Some(error) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.a))
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
            return null
        }
        case None => return os.Channel[Surface].{end = pair.b}
    }
}
