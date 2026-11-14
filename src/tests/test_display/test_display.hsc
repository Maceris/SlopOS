/**
 * The display's test client (decisions/0192, 15b): started by the supervisor with test_display on the kernel's command
 * line, it draws on the first display through the display protocol and moves its cursor with the pointer, and logs
 * what it does, for boot.py to check against the screen it takes:
 *
 * - the display described, as "the display is <width> by <height>";
 * - a frame drawn with std/canvas into the buffer that isn't shown, and presented: a dark blue screen with a white
 *   square SQUARE pixels a side at SQUARE_AT, and an orange disc in its middle, as "presented a frame";
 * - an arrow drawn into the cursor's buffer and shown, its tip the hot spot, at the screen's middle;
 * - every input device it's given read: a tablet's positions, scaled from its axes to the screen, and a mouse's
 *   motions move the cursor; a press of the first button draws a green square MARK pixels a side where the pointer is,
 *   presented in the other buffer, as "clicked at <x>, <y>".
 *
 * It runs until the system stops.
 */
package test_display

import runtime from "base"
import canvas from "std"
import os from "std"
import slop_os from "std/os"
import connector from "../../protocols/connector"
import display from "../../protocols/display"
import input from "../../protocols/input"
import service_kit from "../../libraries/service_kit"

/** Where the white square's top left is, in pixels across and down. */
SQUARE_AT : f32 : 100
/** The white square's side, in pixels. */
SQUARE : f32 : 200
/** The side of the green square a click draws, in pixels. */
MARK : f32 : 20
/** The most input devices it reads. */
MAX_INPUTS :: 4
/** No channel: an input's place once it's gone. */
NO_INPUT : slop_os.Channel : cast[slop_os.Channel](slop_os.NO_HANDLE)

/** A scanout buffer, mapped. */
Buffer :: struct {
    /** Its pixels through the client's mapping. */
    image : canvas.Image,
}

/** The test client's state, on the heap. */
Client :: struct {
    /** The display's channel. */
    display_end : slop_os.Channel,
    /** The port its display channel's answers come to. */
    display_port : slop_os.Port,
    /** What the display is. */
    info : display.Info,
    /** Its scanout buffers, mapped; the first BUFFERS of them. */
    buffers : Buffer[2],
    /** The buffer shown. */
    shown : u32,
    /** The cursor's buffer, mapped; empty on a display without a cursor plane. */
    cursor : canvas.Image,
    /** The canvas, drawn on whichever buffer's next. */
    canvas : canvas.Canvas,
    /** The input devices, bound to inputs_port under their indexes. */
    inputs : service_kit.Clients,
    /** The port the input devices' answers come to. */
    inputs_port : slop_os.Port,
    /** Each input device's absolute axes, by index among inputs. */
    axes : input.Axes[service_kit.MAX_CLIENTS],
    /** Where the pointer is, in pixels. */
    x : i32,
    /** Where the pointer is, in pixels. */
    y : i32,
    /** Where the last click drew, to draw it again in the other buffer: -1 across when there's been none. */
    marked_x : i32,
    /** Where the last click drew. */
    marked_y : i32,
}

/**
 * Draw on the display, show a cursor, and move it with the pointer.
 *
 * @param log The debug log its lines go to.
 * @param display_connector A connector to the first display's driver.
 * @param input0 A connector to the first input device's driver; without one, the cursor doesn't move.
 * @param input1 A connector to the second's.
 * @param input2 A connector to the third's.
 * @param input3 A connector to the fourth's.
 * @return 2 without a display, or when it can't be dialed or described; 3 when its buffers can't be had or mapped; 4
 *     when a frame isn't presented. It doesn't return otherwise.
 */
main :: fn(log: slop_os.DebugLog?, display_connector: os.Channel[connector.Connector]?, input0: os.Channel[connector.Connector]?,
    input1: os.Channel[connector.Connector]?, input2: os.Channel[connector.Connector]?, input3: os.Channel[connector.Connector]?) -> int {
    startup :: slop_os.startup_block()
    dialing :: display_connector or_return 2
    client := runtime.new(Client)
    client.marked_x = -1
    dial_port :: os.port_for(startup.budget, dialing.end) or_return 2
    channel :: connector.dial[display.Display](dialing.end, dial_port) or_return 2
    client.display_end = channel.end
    client.display_port = os.port_for(startup.budget, client.display_end) or_return 2
    match ask(client, .Describe) {
        case Described(info) => client.info = info
        case _ => return 2
    }
    runtime.log_info("the display is % by %", client.info.width, client.info.height)

    for i in cast[u32](0)..<2 {
        if i < client.info.buffers {
            client.buffers[i].image = map_buffer(client, i, client.info.width, client.info.height, client.info.stride) or_return 3
        }
    }
    // The first frame, in the buffer that isn't shown, the driver showing buffer 0 black as it starts
    client.shown = 0
    next :: if client.info.buffers > 1 { cast[u32](1) } else { cast[u32](0) }
    draw_scene(client, next)
    if !present(client, next) {
        return 4
    }
    runtime.log_info("presented a frame")

    client.x = cast[i32](client.info.width / 2)
    client.y = cast[i32](client.info.height / 2)
    if client.info.cursor_size > 0 {
        client.cursor = map_buffer(client, display.CURSOR_BUFFER, client.info.cursor_size, client.info.cursor_size, 4 * client.info.cursor_size)
            or_return 3
        draw_arrow(client)
        tell(client, .SetCursor(display.Cursor.{hot_x = 1, hot_y = 1, visible = true}))
        tell(client, .MoveCursor(display.Position.{x = client.x, y = client.y}))
    }

    client.inputs_port = slop_os.port_create(startup.budget) or_return 2
    connect_input(client, input0)
    connect_input(client, input1)
    connect_input(client, input2)
    connect_input(client, input3)
    // Said once the pointer's read, so what boot.py clicks is seen
    if client.info.cursor_size > 0 {
        runtime.log_info("showed the cursor")
    }
    into := os.Incoming.{}
    loop {
        for i in cast[usize](0)..<client.inputs.count {
            take_input(client, i, &into)
        }
        if service_kit.stopping() {
            return 0
        }
        packets : slop_os.Packet[8]
        _ = slop_os.port_wait(client.inputs_port, packets, slop_os.NO_DEADLINE)
    }
}

/**
 * Send the display a request and wait for its answer.
 *
 * @param client The client, whose display channel it's sent on.
 * @param request The request.
 * @return The answer; Unsupported if it couldn't be sent, or the channel failed.
 */
ask :: fn(client: ptr[mut Client], request: display.Request) -> display.Response {
    out := os.Outgoing.{}
    begun :: os.begin[display.Request](&out)
    begun^ = request
    if display.send_request(client.display_end, client.display_port, &out) is_some {
        return .Unsupported
    }
    into := os.Incoming.{}
    match display.receive_response(client.display_end, client.display_port, &into, true) {
        case Received => {}
        case _ => return .Unsupported
    }
    return os.message_of[display.Response](&into)^
}

/** Send the display a request that isn't answered. */
tell :: fn(client: ptr[mut Client], request: display.Request) {
    out := os.Outgoing.{}
    begun :: os.begin[display.Request](&out)
    begun^ = request
    _ = display.send_request(client.display_end, client.display_port, &out)
}

/**
 * Get a window onto one of the display's buffers and map it.
 *
 * @param client The client.
 * @param buffer The buffer's index, or display.CURSOR_BUFFER.
 * @param width Its width in pixels.
 * @param height Its height in pixels.
 * @param stride The bytes from one of its rows to the next.
 * @return The buffer as an image; null if it couldn't be had or mapped.
 */
map_buffer :: fn(client: ptr[mut Client], buffer: u32, width: u32, height: u32, stride: u32) -> canvas.Image? {
    window :: match ask(client, .GetBuffer(buffer)) {
        case Buffer(memory) => memory
        case _ => return null
    }
    bytes :: cast[u64](stride) * cast[u64](height)
    mapped :: (bytes + 4095) / 4096 * 4096
    address :: runtime.reserve_addresses(cast[usize](mapped)) or_return null
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    if slop_os.memory_map(window, slop_os.startup_block().space, address, 0, mapped, read_write) is_error {
        return null
    }
    pixels :: view_of(cast[ptr[mut u8]](address), cast[usize](bytes))
    return canvas.Image.{pixels = pixels, width = cast[usize](width), height = cast[usize](height), stride = cast[usize](stride)}
}

/**
 * Draw the scene into a buffer: dark blue, a white square at SQUARE_AT, an orange disc in its middle, and the last
 * click's mark if there's been one.
 *
 * @param client The client, whose canvas draws on the buffer.
 * @param buffer The buffer, below Info's buffers.
 */
draw_scene :: fn(client: ptr[mut Client], buffer: u32) {
    target :: if cast[usize](buffer) < client.buffers.count { client.buffers[buffer].image } else { canvas.Image.{} }
    canvas.free_canvas(&client.canvas)
    client.canvas = canvas.make(target)
    painter :: &client.canvas
    canvas.clear(painter, canvas.rgb(26, 51, 115))
    canvas.fill_rect(painter, SQUARE_AT, SQUARE_AT, SQUARE, SQUARE, canvas.Paint.Solid(canvas.rgb(255, 255, 255)))
    disc := canvas.Path.{}
    defer canvas.free_path(&disc)
    canvas.circle(&disc, SQUARE_AT + SQUARE / 2, SQUARE_AT + SQUARE / 2, SQUARE / 4)
    canvas.fill(painter, &disc, canvas.Paint.Solid(canvas.rgb(255, 128, 0)))
    if client.marked_x >= 0 {
        canvas.fill_rect(painter, cast[f32](client.marked_x) - MARK / 2, cast[f32](client.marked_y) - MARK / 2, MARK, MARK,
            canvas.Paint.Solid(canvas.rgb(0, 255, 0)))
    }
}

/**
 * Present a buffer, all of it, and wait for it to be shown.
 *
 * @param client The client, whose shown buffer becomes buffer.
 * @param buffer The buffer.
 * @return Whether it was presented.
 */
present :: fn(client: ptr[mut Client], buffer: u32) -> bool {
    whole :: display.Rect.{width = client.info.width, height = client.info.height}
    match ask(client, .Present(display.Frame.{buffer = buffer, damage = whole})) {
        case Presented(_) => {
            client.shown = buffer
            return true
        }
        case _ => return false
    }
}

/**
 * Draw an arrow into the cursor's buffer: white with a black edge, its tip at (1, 1), the rest transparent, not
 * premultiplied as the cursor's format has it.
 *
 * @param client The client, whose canvas draws on its cursor's buffer.
 */
draw_arrow :: fn(client: ptr[mut Client]) {
    canvas.free_canvas(&client.canvas)
    client.canvas = canvas.make(client.cursor)
    painter :: &client.canvas
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
    canvas.stroke(painter, &arrow, canvas.Paint.Solid(canvas.rgb(0, 0, 0)), canvas.Stroke.{width = 1.2, join = .Miter, miter_limit = 4})
    // Premultiplied as the canvas draws, divided back out
    pixels :: client.cursor.pixels
    for at in cast[usize](0)..<pixels.count / 4 {
        pixel :: four(pixels, 4 * at)
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

/**
 * Dial an input device, ask its axes, and hold a Read on it.
 *
 * @param client The client, whose inputs gain it; one that can't be dialed or added is passed over.
 * @param given The connector to its driver; none, nothing's done.
 */
connect_input :: fn(client: ptr[mut Client], given: os.Channel[connector.Connector]?) {
    dialer :: given or_return void
    port :: os.port_for(slop_os.startup_block().budget, dialer.end) or_return void
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    channel :: connector.dial[input.Input](dialer.end, port) or_return void
    // Its axes, asked on a port of its own before it's bound with the others
    asking :: os.port_for(slop_os.startup_block().budget, channel.end) or_return void
    defer slop_os.handle_close(cast[slop_os.Handle](asking))
    out := os.Outgoing.{}
    request :: os.begin[input.Request](&out)
    request^ = .Describe
    axes := input.Axes.{}
    if input.send_request(channel.end, asking, &out) is_none {
        into := os.Incoming.{}
        if input.receive_response(channel.end, asking, &into, true) == .Received {
            match os.message_of[input.Response](&into)^ {
                case Described(given) => axes = given
                case _ => {}
            }
        }
    }
    added :: service_kit.add_client_index(&client.inputs, client.inputs_port, channel.end) or_return void
    if added < client.axes.count {
        client.axes[added] = axes
    }
    read_more(client, channel.end)
}

/** Hold a Read on an input device. */
read_more :: fn(client: ptr[mut Client], end: slop_os.Channel) {
    out := os.Outgoing.{}
    request :: os.begin[input.Request](&out)
    request^ = .Read(input.MAX_EVENTS)
    _ = input.send_request(end, client.inputs_port, &out)
}

/**
 * Take what an input device sent, moving the cursor with its pointer and marking its clicks, and hold another Read.
 *
 * @param client The client.
 * @param index The device's index among inputs; a freed place is passed over, and a device whose channel fails dropped.
 * @param into Where each answer is received.
 */
take_input :: fn(client: ptr[mut Client], index: usize, into: ptr[mut os.Incoming]) {
    if index >= client.inputs.ends.count {
        return void
    }
    end :: client.inputs.ends[index]
    if end == NO_INPUT {
        return void
    }
    axes :: if index < client.axes.count { client.axes[index] } else { input.Axes.{} }
    loop {
        match input.receive_response(end, client.inputs_port, into, false) {
            case Received => {}
            case Empty => return void
            case _ => {
                service_kit.drop_client(&client.inputs, index)
                return void
            }
        }
        moved := false
        match os.message_of[input.Response](into)^ {
            case Events(given) => {
                for event in os.items(into, given) {
                    kind :: input.kind_of(event) or_else input.EventKind.Key
                    if kind == .Position {
                        client.x = scaled(event.x, axes.x_min, axes.x_max, client.info.width)
                        client.y = scaled(event.y, axes.y_min, axes.y_max, client.info.height)
                        moved = true
                    }
                    else if kind == .Motion {
                        client.x = clamped(client.x + event.x, client.info.width)
                        client.y = clamped(client.y + event.y, client.info.height)
                        moved = true
                    }
                    else if kind == .Button && event.code == 0 && input.is_pressed(event) {
                        click(client)
                    }
                }
                read_more(client, end)
            }
            case _ => {}
        }
        if moved && client.info.cursor_size > 0 {
            tell(client, .MoveCursor(display.Position.{x = client.x, y = client.y}))
        }
    }
}

/** An absolute axis's value as a pixel across a screen size, its range spread over it. */
scaled :: fn(value: i32, low: i32, high: i32, size: u32) -> i32 {
    if high <= low {
        return clamped(value, size)
    }
    spread :: (cast[i64](value) - cast[i64](low)) * cast[i64](size) / (cast[i64](high) - cast[i64](low) + 1)
    return clamped(cast[i32](spread), size)
}

/** A pixel kept on a screen of a size. */
clamped :: fn(value: i32, size: u32) -> i32 {
    top :: cast[i32](size) - 1
    return if value < 0 { 0 } else if value > top { top } else { value }
}

/**
 * Mark a click where the pointer is: the scene drawn again into the buffer not shown, with the mark, and presented.
 *
 * @param client The client, whose mark moves to the pointer.
 */
click :: fn(client: ptr[mut Client]) {
    client.marked_x = client.x
    client.marked_y = client.y
    next :: if client.info.buffers > 1 { 1 - client.shown } else { client.shown }
    draw_scene(client, next)
    if present(client, next) {
        runtime.log_info("clicked at %, %", client.x, client.y)
    }
}

/** A pixel's four bytes, at an offset; none past the end. */
four :: fn(pixels: mut u8[], at: usize) -> mut u8[] {
    if at > pixels.count || pixels.count - at < 4 {
        return pixels[0..<0]
    }
    return pixels[at..<at + 4]
}
