/**
 * The virtio-gpu driver (decisions/0192, 15b): a virtio GPU device in 2D mode, through the virtio-pci transport
 * (src/virtio), as the display protocol for its one client, the compositor, who arrives on its listener.
 *
 * The device's first scanout is shown at the size it prefers, up to MAX_WIDTH by MAX_HEIGHT. Each scanout buffer is a
 * 2D resource of the device's, backed by the driver's DMA memory, which the client draws into through a window; a
 * Present copies what changed to the device's resource (TRANSFER_TO_HOST_2D), makes it the scanout's if it isn't, and
 * flushes it to the screen. The cursor is a resource of its own, CURSOR_SIZE square, moved through the device's cursor
 * queue, so the pointer moves without the screen being copied. Commands on the control queue are sent one at a time,
 * each waited for, as there's one client and the device answers in well under a frame.
 */
package virtio_gpu

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import driver_kit from "../../driver_kit"
import pci from "../../pci"
import display from "../../protocols/display"
import service_kit from "../../libraries/service_kit"
import virtio from "../../virtio"

/** The bytes of a page: 4096. */
PAGE : u64 : 4096
/** The index of the device's control queue, controlq (virtio 1.2 §5.7.2). */
CONTROL_QUEUE : u16 : 0
/** The index of the device's cursor queue, cursorq. */
CURSOR_QUEUE : u16 : 1
/** The port key the device's interrupt is bound with; clients are bound under their indexes, below it. */
IRQ_KEY : u64 : 1000
/** The widest screen it shows, in pixels; a device that prefers wider shows this much of its scanout. */
MAX_WIDTH : u32 : 1920
/** The tallest screen it shows, in pixels, as MAX_WIDTH. */
MAX_HEIGHT : u32 : 1200
/** The screen it shows when the device prefers none: its width. */
DEFAULT_WIDTH : u32 : 1024
/** The screen it shows when the device prefers none: its height. */
DEFAULT_HEIGHT : u32 : 768
/** How many scanout buffers it gives its client: 2, one shown while the other's drawn. */
BUFFERS :: 2
/** The cursor's width and height in pixels, as the device's cursor resource has to be: 64. */
CURSOR_SIZE : u32 : 64
/** The cursor resource's ID; the scanout buffers' are 1 to BUFFERS. */
CURSOR_RESOURCE : u32 : 100
/**
 * How long a control command is waited for before it's taken as failed: 10 seconds, in nanoseconds, as an emulated
 * device under load can take seconds.
 */
COMMAND_TIMEOUT : u64 : 10_000_000_000

// ---- The command page: the control command and its response, then the cursor commands' slots

/** Where the control command is in the command page. */
CONTROL_AT : u64 : 0
/** Where the control command's response is in the command page, after room for the largest command. */
RESPONSE_AT : u64 : 512
/** Where the cursor commands' slots start in the command page. */
CURSOR_AT : u64 : 1024
/** The bytes of each cursor command's slot. */
CURSOR_SLOT_BYTES : u64 : 64
/** How many cursor commands can be in flight at once. */
CURSOR_SLOTS :: 16

// ---- Command and response types (virtio 1.2 §5.7.6.7)

/** VIRTIO_GPU_CMD_GET_DISPLAY_INFO. */
CMD_GET_DISPLAY_INFO : u32 : 0x0100
/** VIRTIO_GPU_CMD_RESOURCE_CREATE_2D. */
CMD_RESOURCE_CREATE_2D : u32 : 0x0101
/** VIRTIO_GPU_CMD_SET_SCANOUT. */
CMD_SET_SCANOUT : u32 : 0x0103
/** VIRTIO_GPU_CMD_RESOURCE_FLUSH. */
CMD_RESOURCE_FLUSH : u32 : 0x0104
/** VIRTIO_GPU_CMD_TRANSFER_TO_HOST_2D. */
CMD_TRANSFER_TO_HOST_2D : u32 : 0x0105
/** VIRTIO_GPU_CMD_RESOURCE_ATTACH_BACKING. */
CMD_RESOURCE_ATTACH_BACKING : u32 : 0x0106
/** VIRTIO_GPU_CMD_UPDATE_CURSOR. */
CMD_UPDATE_CURSOR : u32 : 0x0300
/** VIRTIO_GPU_CMD_MOVE_CURSOR. */
CMD_MOVE_CURSOR : u32 : 0x0301
/** VIRTIO_GPU_RESP_OK_NODATA: done, nothing to say. */
RESP_OK_NODATA : u32 : 0x1100
/** VIRTIO_GPU_RESP_OK_DISPLAY_INFO: the scanouts' sizes follow. */
RESP_OK_DISPLAY_INFO : u32 : 0x1101

/** VIRTIO_GPU_FORMAT_B8G8R8A8_UNORM: blue, green, red, alpha in memory, the cursor's. */
FORMAT_B8G8R8A8 : u32 : 1
/** VIRTIO_GPU_FORMAT_B8G8R8X8_UNORM: blue, green, red and a byte not shown in memory, the scanout buffers'. */
FORMAT_B8G8R8X8 : u32 : 2

/** How many scanouts GET_DISPLAY_INFO's response gives, VIRTIO_GPU_MAX_SCANOUTS. */
MAX_SCANOUTS :: 16

/** Every command's and response's header, virtio_gpu_ctrl_hdr. */
Header :: struct #packed {
    /** The command's or response's type. */
    kind : u32le,
    /** VIRTIO_GPU_FLAG_FENCE and the rest; 0 here. */
    flags : u32le,
    /** A fence's ID, with VIRTIO_GPU_FLAG_FENCE; 0 here. */
    fence : u64le,
    /** The 3D context's ID; 0 in 2D. */
    context : u32le,
    /** The ring's index, with VIRTIO_GPU_FLAG_INFO_RING_IDX; 0 here. */
    ring : u8,
    /** Reserved. */
    padding : u8[3],
}

#assert size_of(Header) == 24

/** A rectangle, virtio_gpu_rect. */
DeviceRect :: struct #packed {
    /** Its left edge, in pixels. */
    x : u32le,
    /** Its top edge, in pixels. */
    y : u32le,
    /** Its width in pixels. */
    width : u32le,
    /** Its height in pixels. */
    height : u32le,
}

#assert size_of(DeviceRect) == 16

/** One scanout in GET_DISPLAY_INFO's response, virtio_gpu_display_one. */
DisplayOne :: struct #packed {
    /** Its preferred position and size. */
    rect : DeviceRect,
    /** 1 when it's enabled, a screen attached. */
    enabled : u32le,
    /** Its flags; none defined. */
    flags : u32le,
}

#assert size_of(DisplayOne) == 24

/** GET_DISPLAY_INFO's response, virtio_resp_display_info. */
DisplayInfo :: struct #packed {
    /** Its header, of type RESP_OK_DISPLAY_INFO. */
    header : Header,
    /** Each scanout's, from the first; those past the device's num_scanouts are zero. */
    scanouts : DisplayOne[MAX_SCANOUTS],
}

#assert size_of(DisplayInfo) == 408

/** RESOURCE_CREATE_2D, virtio_gpu_resource_create_2d. */
ResourceCreate2d :: struct #packed {
    /** Its header, of type CMD_RESOURCE_CREATE_2D. */
    header : Header,
    /** The new resource's ID, not 0, nor one in use. */
    resource : u32le,
    /** Its format, a FORMAT_ value. */
    format : u32le,
    /** Its width in pixels. */
    width : u32le,
    /** Its height in pixels. */
    height : u32le,
}

#assert size_of(ResourceCreate2d) == 40

/** RESOURCE_ATTACH_BACKING with its one entry, virtio_gpu_resource_attach_backing then virtio_gpu_mem_entry. */
AttachBacking :: struct #packed {
    /** Its header, of type CMD_RESOURCE_ATTACH_BACKING. */
    header : Header,
    /** The resource backed. */
    resource : u32le,
    /** How many entries follow: 1. */
    entries : u32le,
    /** The entry's start, a device address. */
    address : u64le,
    /** The entry's bytes. */
    length : u32le,
    /** Reserved. */
    padding : u32le,
}

#assert size_of(AttachBacking) == 48

/** SET_SCANOUT, virtio_gpu_set_scanout. */
SetScanout :: struct #packed {
    /** Its header, of type CMD_SET_SCANOUT. */
    header : Header,
    /** What of the resource the scanout shows. */
    rect : DeviceRect,
    /** The scanout, from 0. */
    scanout : u32le,
    /** The resource shown; 0 turns the scanout off. */
    resource : u32le,
}

#assert size_of(SetScanout) == 48

/** RESOURCE_FLUSH, virtio_gpu_resource_flush. */
ResourceFlush :: struct #packed {
    /** Its header, of type CMD_RESOURCE_FLUSH. */
    header : Header,
    /** What of the resource is put on the screen. */
    rect : DeviceRect,
    /** The resource, a scanout's. */
    resource : u32le,
    /** Reserved. */
    padding : u32le,
}

#assert size_of(ResourceFlush) == 48

/** TRANSFER_TO_HOST_2D, virtio_gpu_transfer_to_host_2d. */
TransferToHost2d :: struct #packed {
    /** Its header, of type CMD_TRANSFER_TO_HOST_2D. */
    header : Header,
    /** What of the resource is copied from its backing. */
    rect : DeviceRect,
    /** Where the rectangle's first pixel is in the resource's backing, in bytes. */
    offset : u64le,
    /** The resource. */
    resource : u32le,
    /** Reserved. */
    padding : u32le,
}

#assert size_of(TransferToHost2d) == 56

/** UPDATE_CURSOR and MOVE_CURSOR, virtio_gpu_update_cursor with its virtio_gpu_cursor_pos. */
UpdateCursor :: struct #packed {
    /** Its header, of type CMD_UPDATE_CURSOR or CMD_MOVE_CURSOR. */
    header : Header,
    /** The scanout the cursor's on, from 0. */
    scanout : u32le,
    /** Where its hot spot goes across, in pixels, signed. */
    x : u32le,
    /** Where its hot spot goes down, in pixels, signed. */
    y : u32le,
    /** Reserved. */
    pos_padding : u32le,
    /** For an update, its image's resource, CURSOR_SIZE square; 0 hides it. A move ignores it. */
    resource : u32le,
    /** For an update, the hot spot's column in the image. */
    hot_x : u32le,
    /** For an update, the hot spot's row in the image. */
    hot_y : u32le,
    /** Reserved. */
    padding : u32le,
}

#assert size_of(UpdateCursor) == 56

/** The driver's state, on the heap, main's for its life. */
Driver :: struct {
    /** Where its lines go, or NO_HANDLE when it wasn't given a log. */
    log : slop_os.DebugLog,
    /** The device's registers. */
    transport : virtio.Transport,
    /** The control queue. */
    control : virtio.Queue,
    /** The cursor queue. */
    cursor_queue : virtio.Queue,
    /** Where the command page is, through the driver's mapping. */
    commands : u64,
    /** Where the command page is to the device. */
    commands_device : u64,
    /** Which cursor slots are in flight, by descriptor index: the slot's index plus 1, or 0 for none. */
    cursor_slot_of : u8[virtio.MAX_QUEUE_SIZE],
    /** Which cursor slots are in flight, a bit each. */
    cursor_busy : u32,
    /** A cursor move that found every slot in flight, sent once one's free. */
    move_waiting : bool,
    /** The one port its interrupt and its clients are bound to. */
    port : slop_os.Port,
    /** The screen's mode, as the client's told. */
    info : display.Info,
    /** The buffers' DMA memory: the scanout buffers one after another, then the cursor's. */
    frames : slop_os.Memory,
    /** Where the buffers' memory is to the device. */
    frames_device : u64,
    /** The bytes of each scanout buffer, rounded up to pages. */
    frame_bytes : u64,
    /** The scanout buffer shown. */
    shown : u32,
    /** Which scanout buffers have been presented since the driver started, a bit each. */
    presented : u32,
    /** Where the cursor's hot spot goes, as MoveCursor last said. */
    cursor : display.Position,
    /** The cursor's hot spot in its image. */
    hot_x : u32,
    /** The cursor's hot spot in its image. */
    hot_y : u32,
    /** Whether the cursor's shown. */
    cursor_visible : bool,
    /** Its listener and its client. */
    clients : service_kit.Clients,
    /** The client's index among clients; null while it has none. */
    client : usize?,
}

/**
 * Drive a virtio GPU device as the display protocol, for its client.
 *
 * It sets the device up, shows its first scanout black at the size the device prefers, and serves its client until
 * the system stops. It's started by the supervisor, for a device the platform service gave it, with what its driver
 * holds of it.
 *
 * @param log The debug log its lines go to; without one, it writes nothing there.
 * @param device The device, for its MSI.
 * @param config The device's 4 KiB of configuration space, mapped to find its capabilities and turn bus mastering on.
 * @param bar0 BAR 0's memory, if the device has it; each BAR given is mapped, for the virtio structures in it.
 * @param bar1 BAR 1's memory, if the device has it.
 * @param bar2 BAR 2's memory, if the device has it.
 * @param bar3 BAR 3's memory, if the device has it.
 * @param bar4 BAR 4's memory, if the device has it.
 * @param bar5 BAR 5's memory, if the device has it.
 * @param domain The DMA domain the device is attached to, which its queues and buffers are made in.
 * @param clients The listener its client's Connect arrives on, served as a client itself.
 * @return It doesn't return while it serves; 99 if its state couldn't be had (decisions/0104), 2 if config couldn't
 *     be mapped, 3 if the device isn't a virtio one it can drive, 4 if it refused its features, 5 if no port could be
 *     made, 6 if its MSI couldn't be set up, 7 if its DMA memory couldn't be made or mapped, 8 if its queues couldn't
 *     be set up, 9 if the listener couldn't be bound, 10 if the device refused a command setting the screen up.
 */
main :: fn(log: slop_os.DebugLog?, device: slop_os.Device, config: slop_os.Memory, bar0: slop_os.Memory?, bar1: slop_os.Memory?,
    bar2: slop_os.Memory?, bar3: slop_os.Memory?, bar4: slop_os.Memory?, bar5: slop_os.Memory?, domain: slop_os.DmaDomain,
    clients: os.Listener[display.Display]) -> int {
    startup :: slop_os.startup_block()
    driver_made, driver_error :: runtime.new_aligned(Driver, align_of(Driver))
    if driver_error != null {
        return 99
    }
    driver :: driver_made
    driver.log = log or_else cast[slop_os.DebugLog](slop_os.NO_HANDLE)
    config_at :: driver_kit.map_device(config) or_return 2
    bars := driver_kit.map_bars(bar0, bar1, bar2, bar3, bar4, bar5)
    driver.transport = virtio.open(config_at, bars) or_return 3
    _ = virtio.start(&driver.transport, 0) or_return 4

    driver.port = slop_os.port_create(startup.budget) or_return 5
    _ = service_kit.watch_stop(driver.port)
    irq :: slop_os.irq_create_msi(device, startup.budget) or_return 6
    message :: slop_os.irq_message(irq) or_return 6
    if !virtio.set_vector(&driver.transport, 0, message.address, message.data) {
        return 6
    }
    slop_os.port_bind(driver.port, cast[slop_os.Handle](irq), cast[slop_os.Signals](0), IRQ_KEY, .Persistent) or_return 6

    // The queues' pages, then the command page
    memory :: slop_os.dma_memory_create(domain, startup.budget, 3 * PAGE, 0) or_return 7
    pages :: runtime.reserve_addresses(cast[usize](3 * PAGE)) or_return 7
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    slop_os.memory_map(memory, startup.space, pages, 0, 3 * PAGE, read_write) or_return 7
    device_address :: slop_os.memory_device_address(memory) or_return 7
    driver.control = virtio.setup_queue(&driver.transport, CONTROL_QUEUE, pages, device_address, virtio.QUEUE_PAGE, 0) or_return 8
    driver.cursor_queue = virtio.setup_queue(&driver.transport, CURSOR_QUEUE, pages + PAGE, device_address + PAGE, virtio.QUEUE_PAGE, 0)
        or_return 8
    driver.commands = pages + 2 * PAGE
    driver.commands_device = device_address + 2 * PAGE
    virtio.ready(&driver.transport)
    pci.write_u16(config_at, pci.COMMAND, pci.read_u16(config_at, pci.COMMAND) | pci.COMMAND_BUS_MASTER)

    // The screen: the device's preferred size, its buffers made and backed, the first shown black
    width, height :: preferred_size(driver)
    stride :: 4 * width
    driver.frame_bytes = round_to_page(cast[u64](stride) * cast[u64](height))
    cursor_bytes :: round_to_page(cast[u64](4 * CURSOR_SIZE * CURSOR_SIZE))
    driver.frames = slop_os.dma_memory_create(domain, startup.budget, BUFFERS * driver.frame_bytes + cursor_bytes, 0) or_return 7
    driver.frames_device = slop_os.memory_device_address(driver.frames) or_return 7
    driver.info = display.Info.{width = width, height = height, stride = stride, format = display.FORMAT_XRGB8888, buffers = BUFFERS,
        cursor_size = CURSOR_SIZE}
    for buffer in cast[u32](0)..<BUFFERS {
        if !create_resource(driver, buffer + 1, FORMAT_B8G8R8X8, width, height, driver.frames_device + cast[u64](buffer) * driver.frame_bytes,
            driver.frame_bytes) {
            return 10
        }
    }
    if !create_resource(driver, CURSOR_RESOURCE, FORMAT_B8G8R8A8, CURSOR_SIZE, CURSOR_SIZE, driver.frames_device + BUFFERS * driver.frame_bytes,
        cursor_bytes) {
        return 10
    }
    whole :: display.Rect.{width = width, height = height}
    if !set_scanout(driver, 1, whole) || !show(driver, 0, whole) {
        return 10
    }
    driver.presented = 1

    if !service_kit.add_client(&driver.clients, driver.port, clients.end) {
        return 9
    }
    runtime.log_info("serving % by %", width, height)
    into := os.Incoming.{}
    loop {
        with {
            i : usize = 0
        }
        loop {
            serve(driver, i, &into)
            i += 1
        }
        while i < driver.clients.count
        reclaim_cursor(driver)
        if service_kit.stopping() {
            return 0
        }
        packets : slop_os.Packet[8]
        _ = slop_os.port_wait(driver.port, packets, slop_os.NO_DEADLINE)
    }
}

/** A size in bytes rounded up to whole pages. */
round_to_page :: fn(bytes: u64) -> u64 {
    return (bytes + PAGE - 1) / PAGE * PAGE
}

/**
 * Ask the device the size its first scanout prefers.
 *
 * @param driver The driver, its control queue set up.
 * @return The width and height to show: the first scanout's, if it's enabled with a size, each cut to MAX_WIDTH and
 *     MAX_HEIGHT; DEFAULT_WIDTH by DEFAULT_HEIGHT otherwise.
 */
preferred_size :: fn(driver: ptr[mut Driver]) -> (u32, u32) {
    request :: cast[ptr[mut Header]](driver.commands + CONTROL_AT)
    request^ = header_of(CMD_GET_DISPLAY_INFO)
    if command(driver, cast[u32](size_of(Header)), cast[u32](size_of(DisplayInfo))) != RESP_OK_DISPLAY_INFO {
        return DEFAULT_WIDTH, DEFAULT_HEIGHT
    }
    info :: cast[ptr[DisplayInfo]](driver.commands + RESPONSE_AT)
    first :: info.scanouts[0]
    enabled : u32 = first.enabled
    width : u32 = first.rect.width
    height : u32 = first.rect.height
    if enabled == 0 || width == 0 || height == 0 {
        return DEFAULT_WIDTH, DEFAULT_HEIGHT
    }
    return (if width < MAX_WIDTH { width } else { MAX_WIDTH }), (if height < MAX_HEIGHT { height } else { MAX_HEIGHT })
}

/** A command's header, of its type, its other fields 0. */
header_of :: fn(kind: u32) -> Header {
    return Header.{kind = le32(kind)}
}

/** A value as the device has it, little-endian. */
le32 :: fn(value: u32) -> u32le {
    return cast[u32le](value)
}

/** A protocol's rectangle as the device's. */
device_rect :: fn(rect: display.Rect) -> DeviceRect {
    return DeviceRect.{x = le32(rect.x), y = le32(rect.y), width = le32(rect.width), height = le32(rect.height)}
}

/**
 * Make a 2D resource and back it with DMA memory.
 *
 * @param driver The driver.
 * @param resource Its ID, not 0.
 * @param format Its format, FORMAT_B8G8R8X8 or FORMAT_B8G8R8A8.
 * @param width Its width in pixels.
 * @param height Its height in pixels.
 * @param address Where its backing is to the device, rows of 4 times width bytes.
 * @param bytes Its backing's bytes, at least width times height times 4.
 * @return Whether the device made and backed it.
 */
create_resource :: fn(driver: ptr[mut Driver], resource: u32, format: u32, width: u32, height: u32, address: u64, bytes: u64) -> bool {
    create :: cast[ptr[mut ResourceCreate2d]](driver.commands + CONTROL_AT)
    create^ = ResourceCreate2d.{header = header_of(CMD_RESOURCE_CREATE_2D), resource = le32(resource), format = le32(format),
        width = le32(width), height = le32(height)}
    if command(driver, cast[u32](size_of(ResourceCreate2d)), cast[u32](size_of(Header))) != RESP_OK_NODATA {
        return false
    }
    attach :: cast[ptr[mut AttachBacking]](driver.commands + CONTROL_AT)
    attach^ = AttachBacking.{header = header_of(CMD_RESOURCE_ATTACH_BACKING), resource = le32(resource), entries = le32(1),
        address = cast[u64le](address), length = le32(cast[u32](bytes))}
    return command(driver, cast[u32](size_of(AttachBacking)), cast[u32](size_of(Header))) == RESP_OK_NODATA
}

/** Make a resource the first scanout's, over the whole screen. */
set_scanout :: fn(driver: ptr[mut Driver], resource: u32, whole: display.Rect) -> bool {
    scanout :: cast[ptr[mut SetScanout]](driver.commands + CONTROL_AT)
    scanout^ = SetScanout.{header = header_of(CMD_SET_SCANOUT), rect = device_rect(whole), scanout = le32(0), resource = le32(resource)}
    return command(driver, cast[u32](size_of(SetScanout)), cast[u32](size_of(Header))) == RESP_OK_NODATA
}

/**
 * Copy a rectangle of a scanout buffer to the device, make it the scanout's if it isn't, and flush it to the screen.
 *
 * @param driver The driver, whose shown buffer becomes buffer.
 * @param buffer The scanout buffer, below BUFFERS.
 * @param rect What's copied and flushed, within the screen.
 * @return Whether the device did each.
 */
show :: fn(driver: ptr[mut Driver], buffer: u32, rect: display.Rect) -> bool {
    resource :: buffer + 1
    if rect.width > 0 && rect.height > 0 {
        transfer :: cast[ptr[mut TransferToHost2d]](driver.commands + CONTROL_AT)
        transfer^ = TransferToHost2d.{header = header_of(CMD_TRANSFER_TO_HOST_2D), rect = device_rect(rect),
            offset = cast[u64le](cast[u64](rect.y) * cast[u64](driver.info.stride) + 4 * cast[u64](rect.x)), resource = le32(resource)}
        if command(driver, cast[u32](size_of(TransferToHost2d)), cast[u32](size_of(Header))) != RESP_OK_NODATA {
            return false
        }
    }
    if buffer != driver.shown {
        if !set_scanout(driver, resource, display.Rect.{width = driver.info.width, height = driver.info.height}) {
            return false
        }
        driver.shown = buffer
    }
    if rect.width > 0 && rect.height > 0 {
        flush :: cast[ptr[mut ResourceFlush]](driver.commands + CONTROL_AT)
        flush^ = ResourceFlush.{header = header_of(CMD_RESOURCE_FLUSH), rect = device_rect(rect), resource = le32(resource)}
        if command(driver, cast[u32](size_of(ResourceFlush)), cast[u32](size_of(Header))) != RESP_OK_NODATA {
            return false
        }
    }
    return true
}

/**
 * Send the control command in the command page and wait for its response.
 *
 * Cursor commands the device finishes meanwhile are taken back as they would be.
 *
 * @param driver The driver, its command page holding the command at CONTROL_AT.
 * @param length The command's bytes.
 * @param response_length The response's bytes, written at RESPONSE_AT.
 * @return The response's type; 0 if it couldn't be sent, or wasn't answered within COMMAND_TIMEOUT.
 */
command :: fn(driver: ptr[mut Driver], length: u32, response_length: u32) -> u32 {
    response :: cast[ptr[mut Header]](driver.commands + RESPONSE_AT)
    response^ = Header.{}
    id :: virtio.offer_chain(&driver.control, virtio.Part.[
        virtio.Part.{address = driver.commands_device + CONTROL_AT, length = length},
        virtio.Part.{address = driver.commands_device + RESPONSE_AT, length = response_length, device_writes = true},
    ])
    if id == virtio.NO_DESCRIPTOR {
        return 0
    }
    deadline :: (slop_os.clock_monotonic() or_else 0) + COMMAND_TIMEOUT
    loop {
        match virtio.take_used(&driver.control) {
            case Some(used) => {
                if used.id == id {
                    kind : u32 = response.kind
                    return kind
                }
            }
            case None => {
                reclaim_cursor(driver)
                packets : slop_os.Packet[8]
                if (slop_os.port_wait(driver.port, packets, deadline) or_else 0) == 0 {
                    runtime.log_error("the device didn't answer a command in time")
                    return 0
                }
            }
        }
    }
}

/**
 * Take back the cursor commands the device has finished, and send a move that was waiting for a slot.
 *
 * @param driver The driver, whose cursor slots free up.
 */
reclaim_cursor :: fn(driver: ptr[mut Driver]) {
    loop {
        used :: virtio.take_used(&driver.cursor_queue) or_break
        if cast[usize](used.id) < driver.cursor_slot_of.count {
            slot :: driver.cursor_slot_of[used.id]
            if slot > 0 {
                driver.cursor_busy = driver.cursor_busy & ~(cast[u32](1) << cast[u32](slot - 1))
                driver.cursor_slot_of[used.id] = 0
            }
        }
    }
    if driver.move_waiting {
        driver.move_waiting = false
        send_cursor(driver, CMD_MOVE_CURSOR)
    }
}

/**
 * Send an UPDATE_CURSOR or a MOVE_CURSOR, from the cursor's state, on the cursor queue; a move waits for a free slot
 * if there's none, an update is dropped.
 *
 * @param driver The driver.
 * @param kind CMD_UPDATE_CURSOR, the image, hot spot and position, or CMD_MOVE_CURSOR, the position only.
 */
send_cursor :: fn(driver: ptr[mut Driver], kind: u32) {
    free := cast[u32](CURSOR_SLOTS)
    for slot in cast[u32](0)..<CURSOR_SLOTS {
        if driver.cursor_busy & (cast[u32](1) << slot) == 0 {
            free = slot
            break
        }
    }
    if free == CURSOR_SLOTS {
        driver.move_waiting = driver.move_waiting || kind == CMD_MOVE_CURSOR
        return void
    }
    at :: CURSOR_AT + cast[u64](free) * CURSOR_SLOT_BYTES
    slot :: cast[ptr[mut UpdateCursor]](driver.commands + at)
    resource :: if driver.cursor_visible { CURSOR_RESOURCE } else { cast[u32](0) }
    slot^ = UpdateCursor.{header = header_of(kind), scanout = le32(0), x = le32(bit_cast[u32](driver.cursor.x)),
        y = le32(bit_cast[u32](driver.cursor.y)), resource = le32(resource), hot_x = le32(driver.hot_x), hot_y = le32(driver.hot_y)}
    id :: virtio.offer(&driver.cursor_queue, driver.commands_device + at, cast[u32](size_of(UpdateCursor)), false)
    if id == virtio.NO_DESCRIPTOR {
        driver.move_waiting = driver.move_waiting || kind == CMD_MOVE_CURSOR
        return void
    }
    driver.cursor_busy = driver.cursor_busy | (cast[u32](1) << free)
    if cast[usize](id) < driver.cursor_slot_of.count {
        driver.cursor_slot_of[id] = cast[u8](free + 1)
    }
}

/**
 * Take every request a client has sent, until there are none left, or it's gone.
 *
 * The listener's Connect makes the client, closing the end when there's one already. A request from the listener
 * that isn't a Connect is skipped, an unknown one answered Unsupported.
 *
 * @param driver The driver, whose client and screen change.
 * @param index Which of its clients, by index; one past them, or a freed place, is nothing to serve. A client whose end
 *     failed is dropped.
 * @param into Where each request is received, reused for each.
 */
serve :: fn(driver: ptr[mut Driver], index: usize, into: ptr[mut os.Incoming]) {
    if index >= driver.clients.ends.count {
        return void
    }
    end :: driver.clients.ends[index]
    if cast[slop_os.Handle](end) == slop_os.NO_HANDLE {
        return void
    }
    is_client :: (driver.client or_else driver.clients.ends.count) == index
    loop {
        match display.receive_request(end, driver.port, into, false) {
            case Received => {}
            case Empty => return void
            case Unsupported => {
                _ = display.answer_unsupported(end, driver.port)
                continue
            }
            case _ => {
                service_kit.drop_client(&driver.clients, index)
                if is_client {
                    driver.client = null
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
                if driver.client is_some {
                    _ = slop_os.handle_close(cast[slop_os.Handle](connection.end))
                }
                else {
                    match service_kit.add_client_index(&driver.clients, driver.port, connection.end) {
                        case Some(added) => driver.client = added
                        case None => _ = slop_os.handle_close(cast[slop_os.Handle](connection.end))
                    }
                }
            }
            case Describe => response^ = .Described(driver.info)
            case GetBuffer(buffer) => response^ = buffer_window(driver, buffer)
            case Present(frame) => response^ = present(driver, frame)
            case SetCursor(cursor) => {
                answered = false
                set_cursor(driver, cursor)
            }
            case MoveCursor(position) => {
                answered = false
                driver.cursor = position
                send_cursor(driver, CMD_MOVE_CURSOR)
            }
        }
        if answered && is_client {
            _ = display.send_response(end, driver.port, &out)
        }
    }
}

/**
 * Make a window onto a buffer, for GetBuffer.
 *
 * @param driver The driver, whose budget pays for the window.
 * @param buffer A scanout buffer's index, or display.CURSOR_BUFFER.
 * @return Buffer with the window; Refused NoSuchBuffer for any other index, or NoMemory if it couldn't be made.
 */
buffer_window :: fn(driver: ptr[mut Driver], buffer: u32) -> display.Response {
    offset := cast[u64](0)
    bytes := driver.frame_bytes
    if buffer == display.CURSOR_BUFFER {
        offset = BUFFERS * driver.frame_bytes
        bytes = round_to_page(cast[u64](4 * CURSOR_SIZE * CURSOR_SIZE))
    }
    else if buffer < BUFFERS {
        offset = cast[u64](buffer) * driver.frame_bytes
    }
    else {
        return .Refused(.NoSuchBuffer)
    }
    startup :: slop_os.startup_block()
    match slop_os.memory_create_window(driver.frames, startup.budget, offset, bytes) {
        case Ok(window) => return .Buffer(window)
        case Error(error) => return .Refused(.NoMemory)
    }
}

/**
 * Show a frame, for Present.
 *
 * @param driver The driver, whose shown buffer becomes the frame's.
 * @param frame The frame: its damage is cut to the screen, and is the whole screen for a buffer never presented.
 * @return Presented with the buffer; Refused NoSuchBuffer for one that isn't the display's, or DeviceError.
 */
present :: fn(driver: ptr[mut Driver], frame: display.Frame) -> display.Response {
    if frame.buffer >= BUFFERS {
        return .Refused(.NoSuchBuffer)
    }
    whole :: display.Rect.{width = driver.info.width, height = driver.info.height}
    bit :: cast[u32](1) << frame.buffer
    rect :: if driver.presented & bit == 0 { whole } else { clipped(frame.damage, whole) }
    if !show(driver, frame.buffer, rect) {
        return .Refused(.DeviceError)
    }
    driver.presented = driver.presented | bit
    return .Presented(frame.buffer)
}

/** A rectangle cut to the screen's; empty when they don't meet. */
clipped :: fn(rect: display.Rect, whole: display.Rect) -> display.Rect {
    if rect.x >= whole.width || rect.y >= whole.height {
        return display.Rect.{}
    }
    width :: if rect.width < whole.width - rect.x { rect.width } else { whole.width - rect.x }
    height :: if rect.height < whole.height - rect.y { rect.height } else { whole.height - rect.y }
    return display.Rect.{x = rect.x, y = rect.y, width = width, height = height}
}

/**
 * Take the cursor's image from its buffer and show it with its hot spot, or hide it, for SetCursor.
 *
 * @param driver The driver, whose cursor changes.
 * @param cursor The hot spot, cut to the image, and whether it's shown.
 */
set_cursor :: fn(driver: ptr[mut Driver], cursor: display.Cursor) {
    driver.hot_x = if cursor.hot_x < CURSOR_SIZE { cursor.hot_x } else { CURSOR_SIZE - 1 }
    driver.hot_y = if cursor.hot_y < CURSOR_SIZE { cursor.hot_y } else { CURSOR_SIZE - 1 }
    driver.cursor_visible = cursor.visible
    if cursor.visible {
        transfer :: cast[ptr[mut TransferToHost2d]](driver.commands + CONTROL_AT)
        transfer^ = TransferToHost2d.{header = header_of(CMD_TRANSFER_TO_HOST_2D), rect = DeviceRect.{width = le32(CURSOR_SIZE),
            height = le32(CURSOR_SIZE)}, resource = le32(CURSOR_RESOURCE)}
        if command(driver, cast[u32](size_of(TransferToHost2d)), cast[u32](size_of(Header))) != RESP_OK_NODATA {
            runtime.log_error("the device refused the cursor's image")
        }
    }
    send_cursor(driver, CMD_UPDATE_CURSOR)
}
