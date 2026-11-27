/**
 * The virtio-sound driver (decisions/0196, 17c; virtio's device ID 25): a stream played to the device's first output
 * stream that takes 48 kHz stereo, as floats if it can or else 16-bit integers, served to one client at a time as the
 * audio protocol. The client's periods are in a ring the device never sees; each one given is encoded into the
 * device's format, clipped, in a buffer the device reads, and sent on the transmit queue with its header and status.
 * Playing starts once START_PERIODS are given; each period's answered once the device returns it.
 *
 * Capture (17f) is the same the other way, from the first input stream that takes 48 kHz stereo, if the device has
 * one: each period of the capture ring given is a buffer the device writes, sent on the receive queue; once it's
 * returned, its frames are decoded into the ring and the period answered. One client records at a time.
 */
package virtio_sound

import runtime from "base:runtime"
import os from "std:os"
import slop_os from "std:os/slop_os"
import audio as pcm from "std:audio"
import driver_kit from "../../driver_kit"
import service_kit from "../../libraries/service_kit"
import pci from "../../pci"
import audio from "../../protocols/audio"
import virtio from "../../virtio"

/** A page. */
PAGE : u64 : 4096
/** The port key the device's interrupts come under; clients come under their indexes, below it. */
IRQ_KEY : u64 : 1000
/** The control queue's index (VIRTIO_SND_VQ_CONTROL). */
CONTROL_QUEUE : u16 : 0
/** The event queue's (VIRTIO_SND_VQ_EVENT). */
EVENT_QUEUE : u16 : 1
/** The transmit queue's (VIRTIO_SND_VQ_TX). */
TX_QUEUE : u16 : 2
/** The receive queue's (VIRTIO_SND_VQ_RX). */
RX_QUEUE : u16 : 3
/** The device-specific configuration: its jacks, streams and channel maps, each a le32. */
CONFIG_STREAMS : u64 : 4
/** virtio-sound's request codes. */
R_PCM_INFO : u32 : 0x0100
R_PCM_SET_PARAMS : u32 : 0x0101
R_PCM_PREPARE : u32 : 0x0102
R_PCM_RELEASE : u32 : 0x0103
R_PCM_START : u32 : 0x0104
R_PCM_STOP : u32 : 0x0105
/** Its status that a request or a transfer went as asked (VIRTIO_SND_S_OK). */
S_OK : u32 : 0x8000
/** Its events of a stream running out (VIRTIO_SND_EVT_PCM_XRUN). */
EVT_PCM_XRUN : u32 : 0x1101
/** An output stream (VIRTIO_SND_D_OUTPUT). */
D_OUTPUT : u8 : 0
/** An input stream (VIRTIO_SND_D_INPUT). */
D_INPUT : u8 : 1
/** Its format numbers: 32-bit floats and 16-bit integers (VIRTIO_SND_PCM_FMT_FLOAT, _S16). */
FMT_FLOAT : u8 : 19
FMT_S16 : u8 : 5
/** Its rate number for 48 kHz (VIRTIO_SND_PCM_RATE_48000). */
RATE_48000 : u8 : 7
/** The bytes of a stream's information (struct virtio_snd_pcm_info). */
PCM_INFO_BYTES : u64 : 32
/** The most streams asked about. */
MAX_STREAMS : u64 : 16
/** How many event buffers the device is given, 8 bytes each (struct virtio_snd_event). */
EVENT_BUFFERS : usize : 8
/** How long a control request is waited for, in nanoseconds: 2 s. */
CONTROL_WAIT : u64 : 2_000_000_000
/** No client: none owns the playing, or the recording. */
NOBODY : usize : ~cast[usize](0)
/** No stream: the device has none that takes the system's format in that direction. */
NO_STREAM : u32 : ~cast[u32](0)

// The device memory's pages: the queues, the control messages and events, the transfers' headers, the frames, each way
/** The control queue's page. */
CONTROL_PAGE : u64 : 0
/** The event queue's. */
EVENT_PAGE : u64 : 1
/** The transmit queue's. */
TX_PAGE : u64 : 2
/** The control requests', from its start, their answers' from its middle, the event buffers' at its end. */
MESSAGE_PAGE : u64 : 3
/** Each period's transfer header, at 16 bytes each, its status 8 bytes after it. */
TRANSFER_PAGE : u64 : 4
/** The frames, each period's in the device's format, from here: four pages hold every period's as floats. */
FRAMES_PAGE : u64 : 5
/** The receive queue's. */
RX_PAGE : u64 : 9
/** Each capture period's transfer header and status, as TRANSFER_PAGE's. */
CAPTURE_TRANSFER_PAGE : u64 : 10
/** The captured frames, each period's in the device's format, from here, four pages as FRAMES_PAGE's. */
CAPTURE_FRAMES_PAGE : u64 : 11
/** The device memory's pages in all. */
DEVICE_PAGES : u64 : 15
/** Where a control request's answer goes in the message page. */
ANSWER_AT : u64 : 1024
/** Where the event buffers go in it. */
EVENTS_AT : u64 : 3072

/** The driver's state. */
Driver :: struct {
    /** Its debug log; NO_HANDLE without one. */
    log : slop_os.DebugLog,
    /** The device's registers, as virtio found them. */
    transport : virtio.Transport,
    /** The control, event, transmit and receive queues. */
    control : virtio.Queue,
    events : virtio.Queue,
    tx : virtio.Queue,
    rx : virtio.Queue,
    /** The device memory, mapped here, and where the device sees it. */
    memory_at : u64,
    memory_device : u64,
    /** The port it waits on: the device's interrupts and its clients. */
    port : slop_os.Port,
    /** Its listener and clients. */
    clients : service_kit.Clients,
    /** The output stream it plays, by its ID. */
    stream : u32,
    /** How the device stores samples: FMT_FLOAT or FMT_S16. */
    format : u8,
    /** How many output streams the device has. */
    streams : u32,
    /** The client ring, memory the device never sees, mapped here; NO_HANDLE until a client asks for it. */
    ring : slop_os.Memory,
    ring_at : u64,
    /** The client that plays, by index among clients; NOBODY before any asks. */
    owner : usize,
    /** Each period's transmit chain's first descriptor while it's given; NO_DESCRIPTOR while it isn't. */
    heads : u16[audio.PERIODS],
    /** How many periods are given. */
    given : u32,
    /** Whether the device is playing (PCM_START sent). */
    playing : bool,
    /** How many times it ran out of periods while playing. */
    underruns : u32,
    /** Each event buffer's descriptor, while the device has it. */
    event_heads : u16[EVENT_BUFFERS],
    /** The input stream it records from, by its ID; NO_STREAM if the device has none that takes 48 kHz stereo. */
    capture_stream : u32,
    /** How the device stores samples it captures: FMT_FLOAT or FMT_S16; 0 without an input stream. */
    capture_format : u8,
    /** The capture ring, mapped here; NO_HANDLE until a client asks for it. */
    capture_ring : slop_os.Memory,
    capture_ring_at : u64,
    /** The client that records, by index among clients; NOBODY before any asks. */
    recorder : usize,
    /** Each capture period's receive chain's first descriptor while it's given; NO_DESCRIPTOR while it isn't. */
    capture_heads : u16[audio.PERIODS],
    /** How many capture periods are given. */
    capture_given : u32,
    /** Whether the device is recording (PCM_START sent for the input stream). */
    recording : bool,
    /** How many times it had no period to fill while recording. */
    overruns : u32,
}

/** A stream found for a direction: its ID and how the device stores its samples. */
Found :: struct {
    stream : u32,
    format : u8,
}

/**
 * Drive a virtio-sound device: set it up, set its first output stream that takes 48 kHz stereo up, and serve the audio
 * protocol to the clients that connect through the listener, until asked to stop.
 *
 * @param log The debug log it says what it's doing in.
 * @param device The device, for its MSI.
 * @param config Its PCI configuration space.
 * @param bar0 Its BARs, those it has.
 * @param bar1 See bar0.
 * @param bar2 See bar0.
 * @param bar3 See bar0.
 * @param bar4 See bar0.
 * @param bar5 See bar0.
 * @param domain The DMA domain its memory is made in.
 * @param clients The listener its clients connect through.
 * @return 99 without memory for its state; 2 to 9 when the device couldn't be set up, by step; 10 when it has no output
 *     stream that takes 48 kHz stereo floats or 16-bit integers, 11 when that stream couldn't be set up, 12 if the
 *     listener couldn't be served; 0 once asked to stop.
 */
main :: fn(
    log : slop_os.DebugLog?,
    device : slop_os.Device,
    config : slop_os.Memory,
    bar0 : slop_os.Memory?,
    bar1 : slop_os.Memory?,
    bar2 : slop_os.Memory?,
    bar3 : slop_os.Memory?,
    bar4 : slop_os.Memory?,
    bar5 : slop_os.Memory?,
    domain : slop_os.DmaDomain,
    clients : os.Listener[audio.Audio]
) -> int {
    startup :: slop_os.startup_block()
    // Its state; without the memory for it, it ends with 99 (decisions/0104)
    driver_made, driver_error :: runtime.new_aligned(Driver, align_of(Driver))
    if driver_error != null {
        return 99
    }
    driver :: driver_made
    driver^ = Driver.{
        log = log or_else cast[slop_os.DebugLog](slop_os.NO_HANDLE),
        owner = NOBODY,
        recorder = NOBODY,
        capture_stream = NO_STREAM,
    }
    driver.ring = cast[slop_os.Memory](slop_os.NO_HANDLE)
    driver.capture_ring = cast[slop_os.Memory](slop_os.NO_HANDLE)
    for &head in driver.heads {
        head^ = virtio.NO_DESCRIPTOR
    }
    for &head in driver.capture_heads {
        head^ = virtio.NO_DESCRIPTOR
    }
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
    slop_os.port_bind(driver.port, IRQ_KEY, cast[slop_os.Handle](irq), cast[slop_os.Signals](0), .Persistent)
        or_return 6

    bytes :: DEVICE_PAGES * PAGE
    memory :: slop_os.dma_memory_create(domain, startup.budget, bytes, 0) or_return 7
    driver.memory_at = cast[u64](runtime.reserve_addresses(cast[usize](bytes)) or_return 7)
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    slop_os.memory_map(memory, startup.space, driver.memory_at, 0, bytes, read_write) or_return 7
    driver.memory_device = slop_os.memory_device_address(memory) or_return 7
    driver.control = queue_at(driver, CONTROL_QUEUE, CONTROL_PAGE) or_return 8
    driver.events = queue_at(driver, EVENT_QUEUE, EVENT_PAGE) or_return 8
    driver.tx = queue_at(driver, TX_QUEUE, TX_PAGE) or_return 8
    driver.rx = queue_at(driver, RX_QUEUE, RX_PAGE) or_return 8
    virtio.ready(&driver.transport)
    pci.write_u16(config_at, pci.COMMAND, pci.read_u16(config_at, pci.COMMAND) | pci.COMMAND_BUS_MASTER)
    for i in 0..<EVENT_BUFFERS {
        offer_event(driver, cast[u64](i))
    }
    driver.streams = virtio.read_u32(driver.transport.device, CONFIG_STREAMS)
    output :: choose_stream(driver, D_OUTPUT) or_else Found.{stream = NO_STREAM}
    if output.stream == NO_STREAM {
        runtime.log_info("no output stream takes 48 kHz stereo of floats or 16-bit integers")
        return 10
    }
    driver.stream = output.stream
    driver.format = output.format
    if !set_up_stream(driver, driver.stream, driver.format) {
        return 11
    }
    runtime.log_info(
        "serving stream % of %, 48 kHz stereo, as %",
        driver.stream,
        driver.streams,
        format_name(driver.format)
    )
    // Capture, if there's an input stream that takes the format and it can be set up; playing doesn't need it
    match choose_stream(driver, D_INPUT) {
        case Some(input) => {
            if set_up_stream(driver, input.stream, input.format) {
                driver.capture_stream = input.stream
                driver.capture_format = input.format
                runtime.log_info("capturing from stream %, 48 kHz stereo, as %", input.stream, format_name(input.format))
            }
        }
        case None => runtime.log_info("no input stream takes 48 kHz stereo: nothing to capture")
    }
    if !service_kit.add_client(&driver.clients, driver.port, clients.end) {
        return 12
    }
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
        take_played(driver)
        take_recorded(driver)
        take_events(driver)
        // Asked to stop, as the system shuts down (decisions/0182): what it was doing is done
        if service_kit.stopping() {
            return 0
        }
        packets : slop_os.Packet[8]
        _ = slop_os.port_wait(driver.port, packets, slop_os.NO_DEADLINE)
    }
}

/**
 * Set a queue up in a page of the device memory, its interrupts on vector 0.
 *
 * @param driver The driver, whose device memory and transport are used.
 * @param index The queue's index.
 * @param page Which of the device memory's pages it goes in.
 * @return The queue; null if the device refused it.
 */
queue_at :: fn(driver : ptr[mut Driver], index : u16, page : u64) -> virtio.Queue? {
    return virtio.setup_queue(
        &driver.transport,
        index,
        driver.memory_at + page * PAGE,
        driver.memory_device + page * PAGE,
        virtio.QUEUE_PAGE,
        0
    )
}

/** What a format number says, for the log. */
format_name :: fn(format : u8) -> string {
    return if format == FMT_FLOAT { "floats" } else { "16-bit integers" }
}

/** How a format number's samples are stored, as std/audio says it. */
sample_format :: fn(format : u8) -> pcm.SampleFormat {
    return if format == FMT_FLOAT { pcm.SampleFormat.F32 } else { pcm.SampleFormat.S16 }
}

/** The address in the device memory, here, of a byte of a page. */
here :: fn(driver : ptr[Driver], page : u64, offset : u64) -> u64 {
    return driver.memory_at + page * PAGE + offset
}

/** Where the device sees a byte of a page of the device memory. */
there :: fn(driver : ptr[Driver], page : u64, offset : u64) -> u64 {
    return driver.memory_device + page * PAGE + offset
}

/**
 * Give the device an event buffer to fill, 8 bytes at its place at the message page's end.
 *
 * @param driver The driver, its event queue offered the buffer.
 * @param index Which buffer, below EVENT_BUFFERS.
 */
offer_event :: fn(driver : ptr[mut Driver], index : u64) {
    head :: virtio.offer(&driver.events, there(driver, MESSAGE_PAGE, EVENTS_AT + index * 8), 8, true)
    if cast[usize](index) < driver.event_heads.count {
        driver.event_heads[cast[usize](index)] = head
    }
}

/**
 * Take the events the device has sent: the output stream running out is counted as an underrun, the input stream
 * having nowhere to put what it heard as an overrun; each buffer's offered again.
 *
 * @param driver The driver, whose underruns and overruns may grow.
 */
take_events :: fn(driver : ptr[mut Driver]) {
    loop {
        used :: virtio.take_used(&driver.events) or_return void
        // Which buffer, by its descriptor
        for head, i in driver.event_heads {
            if head != used.id {
                continue
            }
            // struct virtio_snd_event: its code, and for a stream's events, the stream
            code :: virtio.read_u32(here(driver, MESSAGE_PAGE, EVENTS_AT + cast[u64](i) * 8), 0)
            stream :: virtio.read_u32(here(driver, MESSAGE_PAGE, EVENTS_AT + cast[u64](i) * 8), 4)
            if code == EVT_PCM_XRUN && stream == driver.capture_stream {
                driver.overruns += 1
            }
            else if code == EVT_PCM_XRUN {
                driver.underruns += 1
            }
            offer_event(driver, cast[u64](i))
            break
        }
    }
}

/**
 * Send a control request, the bytes already written at the message page's start, and wait for its answer.
 *
 * @param driver The driver, its control queue used; the device's other queues' answers that come meanwhile wait.
 * @param request_bytes How many bytes the request is.
 * @param answer_bytes How many the answer has room for, from ANSWER_AT; at least its 4-byte status.
 * @return The answer's status, S_OK if it went as asked; 0 if no answer came within CONTROL_WAIT.
 */
control :: fn(driver : ptr[mut Driver], request_bytes : u64, answer_bytes : u64) -> u32 {
    virtio.write_u32(here(driver, MESSAGE_PAGE, ANSWER_AT), 0, 0)
    parts :: virtio.Part.[
        virtio.Part.{address = there(driver, MESSAGE_PAGE, 0), length = cast[u32](request_bytes), device_writes = false},
        virtio.Part.{address = there(driver, MESSAGE_PAGE, ANSWER_AT), length = cast[u32](answer_bytes), device_writes = true},
    ]
    _ = virtio.offer_chain(&driver.control, parts[0..<parts.count])
    deadline :: (slop_os.clock_monotonic() or_else 0) + CONTROL_WAIT
    loop {
        match virtio.take_used(&driver.control) {
            case Some(used) => return virtio.read_u32(here(driver, MESSAGE_PAGE, ANSWER_AT), 0)
            case None => {}
        }
        now :: slop_os.clock_monotonic() or_else deadline
        if now >= deadline {
            return 0
        }
        packets : slop_os.Packet[4]
        _ = slop_os.port_wait(driver.port, packets, deadline)
    }
}

/**
 * Send a request about a stream alone, a code and the stream's ID (struct virtio_snd_pcm_hdr), and wait for it.
 *
 * @param driver The driver.
 * @param stream The stream's ID: the one it plays or the one it records from.
 * @param code The request: PCM_PREPARE, PCM_START, PCM_STOP or PCM_RELEASE.
 * @return Whether it went as asked.
 */
stream_request :: fn(driver : ptr[mut Driver], stream : u32, code : u32) -> bool {
    at :: here(driver, MESSAGE_PAGE, 0)
    virtio.write_u32(at, 0, code)
    virtio.write_u32(at, 4, stream)
    status :: control(driver, 8, 4)
    if status != S_OK {
        runtime.log_info("the device answered request % with %", code, status)
    }
    return status == S_OK
}

/**
 * Find the first stream of a direction that takes 48 kHz stereo, as floats if it can or else 16-bit integers.
 *
 * @param driver The driver, whose streams are asked about.
 * @param direction D_OUTPUT or D_INPUT.
 * @return The stream and its format; null if none does, or the device didn't say.
 */
choose_stream :: fn(driver : ptr[mut Driver], direction : u8) -> Found? {
    count :: if cast[u64](driver.streams) < MAX_STREAMS { cast[u64](driver.streams) } else { MAX_STREAMS }
    if count == 0 {
        return null
    }
    at :: here(driver, MESSAGE_PAGE, 0)
    // struct virtio_snd_query_info: the code, the first stream, how many, and each one's size
    virtio.write_u32(at, 0, R_PCM_INFO)
    virtio.write_u32(at, 4, 0)
    virtio.write_u32(at, 8, cast[u32](count))
    virtio.write_u32(at, 12, cast[u32](PCM_INFO_BYTES))
    if control(driver, 16, 4 + count * PCM_INFO_BYTES) != S_OK {
        return null
    }
    for stream in 0..<count {
        info :: here(driver, MESSAGE_PAGE, ANSWER_AT + 4 + stream * PCM_INFO_BYTES)
        // struct virtio_snd_pcm_info: hda_fn_nid, features, formats (le64), rates (le64), direction, channels
        formats :: cast[u64](virtio.read_u32(info, 8)) | cast[u64](virtio.read_u32(info, 12)) << 32
        rates :: cast[u64](virtio.read_u32(info, 16)) | cast[u64](virtio.read_u32(info, 20)) << 32
        its_direction :: virtio.read_u8(info, 24)
        least :: virtio.read_u8(info, 25)
        most :: virtio.read_u8(info, 26)
        if its_direction != direction || least > 2 || most < 2 || rates & (cast[u64](1) << RATE_48000) == 0 {
            continue
        }
        if formats & (cast[u64](1) << FMT_FLOAT) != 0 {
            return Found.{stream = cast[u32](stream), format = FMT_FLOAT}
        }
        if formats & (cast[u64](1) << FMT_S16) != 0 {
            return Found.{stream = cast[u32](stream), format = FMT_S16}
        }
    }
    return null
}

/** The bytes of a period in the device's format for the stream it plays. */
device_period_bytes :: fn(driver : ptr[Driver]) -> u64 {
    return period_bytes(driver.format)
}

/** The bytes of a period in a format: PERIOD_FRAMES frames of stereo. */
period_bytes :: fn(format : u8) -> u64 {
    sample :: if format == FMT_FLOAT { cast[u64](4) } else { cast[u64](2) }
    return cast[u64](audio.PERIOD_FRAMES) * cast[u64](audio.CHANNELS) * sample
}

/**
 * Set a stream up for a ring's periods and prepare it (struct virtio_snd_pcm_set_params, then PCM_PREPARE).
 *
 * @param driver The driver.
 * @param stream The stream's ID.
 * @param format How the device is to store its samples, as it said it can.
 * @return Whether the device took both.
 */
set_up_stream :: fn(driver : ptr[mut Driver], stream : u32, format : u8) -> bool {
    period :: period_bytes(format)
    at :: here(driver, MESSAGE_PAGE, 0)
    virtio.write_u32(at, 0, R_PCM_SET_PARAMS)
    virtio.write_u32(at, 4, stream)
    virtio.write_u32(at, 8, cast[u32](period * cast[u64](audio.PERIODS)))
    virtio.write_u32(at, 12, cast[u32](period))
    virtio.write_u32(at, 16, 0)
    virtio.write_u8(at, 20, cast[u8](audio.CHANNELS))
    virtio.write_u8(at, 21, format)
    virtio.write_u8(at, 22, RATE_48000)
    virtio.write_u8(at, 23, 0)
    status :: control(driver, 24, 4)
    if status != S_OK {
        runtime.log_info("the device refused stream %'s parameters: %", stream, status)
        return false
    }
    return stream_request(driver, stream, R_PCM_PREPARE)
}

/**
 * Take every request a client has sent, until there are none left, or it's gone.
 *
 * @param driver The driver.
 * @param index Which client, by its index; a freed place is nothing to serve. One whose end failed is dropped, and
 *     if it played or recorded, the periods it gave are dropped with it.
 * @param into Where each request is received, reused.
 */
serve :: fn(driver : ptr[mut Driver], index : usize, into : ptr[mut os.Incoming]) {
    if index >= driver.clients.ends.count {
        return void
    }
    end :: driver.clients.ends[index]
    if cast[slop_os.Handle](end) == slop_os.NO_HANDLE {
        return void
    }
    loop {
        match audio.receive_request(end, driver.port, into, false) {
            case Received => {}
            case Empty => return void
            case Unsupported => {
                _ = audio.answer_unsupported(end, driver.port)
                continue
            }
            case _ => {
                if driver.owner == index {
                    stop(driver)
                    driver.owner = NOBODY
                }
                if driver.recorder == index {
                    stop_recording(driver)
                    driver.recorder = NOBODY
                }
                service_kit.drop_client(&driver.clients, index)
                return void
            }
        }
        out := os.Outgoing.{}
        response :: os.begin[audio.Response](&out)
        match os.message_of[audio.Request](into)^ {
            case Describe => response^ = .Described(
                audio.Info.{device_format = driver.format, capture_format = driver.capture_format, streams = driver.streams}
            )
            case GetBuffer => response^ = buffer_for(driver, index)
            case Play(period) => match play(driver, index, period) {
                // Answered once the device returns it
                case None => continue
                case Some(why) => response^ = .Refused(audio.PlayRefused.{period = period, why = why})
            }
            case Stop => {
                if driver.owner == index {
                    stop(driver)
                }
                response^ = .Stopped
            }
            case GetCaptureBuffer => response^ = capture_buffer_for(driver, index)
            case Record(period) => match record(driver, index, period) {
                // Answered once the device has filled it
                case None => continue
                case Some(why) => response^ = .RecordRefused(audio.PlayRefused.{period = period, why = why})
            }
            case StopRecording => {
                if driver.recorder == index {
                    stop_recording(driver)
                }
                response^ = .RecordingStopped
            }
            case Connect(connection) => {
                _ = service_kit.add_client_index(&driver.clients, driver.port, connection.end)
                continue
            }
        }
        _ = audio.send_response(end, driver.port, &out)
    }
}

/**
 * Give a client a window onto the ring, made the first time, and make it the one that plays: another that played has
 * its periods dropped.
 *
 * @param driver The driver.
 * @param index The client's index.
 * @return Buffer with the window; Unsupported if the ring or the window couldn't be made.
 */
buffer_for :: fn(driver : ptr[mut Driver], index : usize) -> audio.Response {
    startup :: slop_os.startup_block()
    if cast[slop_os.Handle](driver.ring) == slop_os.NO_HANDLE {
        memory :: slop_os.memory_create(startup.budget, audio.BUFFER_BYTES) or_return audio.Response.Unsupported
        at :: runtime.reserve_addresses(cast[usize](audio.BUFFER_BYTES)) or_return audio.Response.Unsupported
        read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
        if slop_os.memory_map(memory, startup.space, cast[u64](at), 0, audio.BUFFER_BYTES, read_write) is_error {
            _ = slop_os.handle_close(cast[slop_os.Handle](memory))
            return audio.Response.Unsupported
        }
        driver.ring = memory
        driver.ring_at = cast[u64](at)
    }
    if driver.owner != index && driver.owner != NOBODY {
        stop(driver)
    }
    driver.owner = index
    window :: slop_os.memory_create_window(driver.ring, startup.budget, 0, audio.BUFFER_BYTES)
        or_return audio.Response.Unsupported
    return audio.Response.Buffer(window)
}

/**
 * Play a period a client gave: its frames encoded into the device's format and sent on the transmit queue, with its
 * header and status (struct virtio_snd_pcm_xfer, the frames, struct virtio_snd_pcm_status); and once START_PERIODS are
 * given, the stream started.
 *
 * @param driver The driver.
 * @param index The client's index.
 * @param period The period's index in the ring.
 * @return Null once it's sent, to be answered when the device returns it; why not otherwise.
 */
play :: fn(driver : ptr[mut Driver], index : usize, period : u32) -> audio.Refused? {
    if driver.owner != index || cast[slop_os.Handle](driver.ring) == slop_os.NO_HANDLE {
        return audio.Refused.NoBuffer
    }
    slot :: cast[usize](period)
    if slot >= driver.heads.count || driver.heads[slot] != virtio.NO_DESCRIPTOR {
        return audio.Refused.BadPeriod
    }
    // The period's floats, from the ring, encoded into its place among the device's frames
    samples :: cast[usize](audio.PERIOD_FRAMES * audio.CHANNELS)
    from :: view_of(cast[ptr[f32]](driver.ring_at + cast[u64](period) * cast[u64](audio.PERIOD_BYTES)), samples)
    frames_at :: cast[u64](period) * device_period_bytes(driver)
    into :: view_of(cast[ptr[mut u8]](here(driver, FRAMES_PAGE, frames_at)), cast[usize](device_period_bytes(driver)))
    _ = pcm.encode(from, sample_format(driver.format), into)
    header :: cast[u64](period) * 16
    virtio.write_u32(here(driver, TRANSFER_PAGE, header), 0, driver.stream)
    virtio.write_u32(here(driver, TRANSFER_PAGE, header), 8, 0)
    parts :: virtio.Part.[
        virtio.Part.{address = there(driver, TRANSFER_PAGE, header), length = 4, device_writes = false},
        virtio.Part.{
            address = there(driver, FRAMES_PAGE, frames_at),
            length = cast[u32](device_period_bytes(driver)),
            device_writes = false,
        },
        virtio.Part.{address = there(driver, TRANSFER_PAGE, header + 8), length = 8, device_writes = true},
    ]
    head :: virtio.offer_chain(&driver.tx, parts[0..<parts.count])
    if head == virtio.NO_DESCRIPTOR {
        return audio.Refused.DeviceFailed
    }
    driver.heads[slot] = head
    driver.given += 1
    if !driver.playing && driver.given >= audio.START_PERIODS {
        if !stream_request(driver, driver.stream, R_PCM_START) {
            return null
        }
        driver.playing = true
    }
    return null
}

/**
 * Answer each period the device has returned: Played to the client that plays, with the device's latency and the
 * underruns so far. Running out of periods while playing counts as an underrun.
 *
 * @param driver The driver.
 */
take_played :: fn(driver : ptr[mut Driver]) {
    loop {
        used :: virtio.take_used(&driver.tx) or_return void
        for &head, slot in driver.heads {
            if head^ != used.id {
                continue
            }
            head^ = virtio.NO_DESCRIPTOR
            driver.given -= 1
            status_at :: here(driver, TRANSFER_PAGE, cast[u64](slot) * 16 + 8)
            status :: virtio.read_u32(status_at, 0)
            latency :: virtio.read_u32(status_at, 4) / (cast[u32](device_period_bytes(driver)) / audio.PERIOD_FRAMES)
            if driver.given == 0 && driver.playing {
                driver.underruns += 1
            }
            answer(driver, cast[u32](slot), status, latency)
            break
        }
    }
}

/**
 * Answer a period the device returned to the client that plays.
 *
 * @param driver The driver.
 * @param period The period.
 * @param status The device's status for it.
 * @param latency The device's latency when it took it, in frames.
 */
answer :: fn(driver : ptr[mut Driver], period : u32, status : u32, latency : u32) {
    if driver.owner >= driver.clients.ends.count {
        return void
    }
    end :: driver.clients.ends[driver.owner]
    out := os.Outgoing.{}
    response :: os.begin[audio.Response](&out)
    response^ = if status == S_OK {
        audio.Response.Played(audio.Played.{period = period, latency_frames = latency, underruns = driver.underruns})
    }
    else {
        audio.Response.Refused(audio.PlayRefused.{period = period, why = .DeviceFailed})
    }
    _ = audio.send_response(end, driver.port, &out)
}

/**
 * Stop playing: the stream stopped and released, which returns the periods it held, each answered, and prepared
 * again for the next Play.
 *
 * @param driver The driver, its periods and playing cleared.
 */
stop :: fn(driver : ptr[mut Driver]) {
    if driver.playing {
        _ = stream_request(driver, driver.stream, R_PCM_STOP)
        driver.playing = false
    }
    _ = stream_request(driver, driver.stream, R_PCM_RELEASE)
    take_played(driver)
    // Any the device kept, forgotten: it's released them
    for &head in driver.heads {
        head^ = virtio.NO_DESCRIPTOR
    }
    driver.given = 0
    _ = stream_request(driver, driver.stream, R_PCM_PREPARE)
}

/**
 * Give a client a window onto the capture ring, made the first time, and make it the one that records: another that
 * did has its periods dropped.
 *
 * @param driver The driver.
 * @param index The client's index.
 * @return CaptureBuffer with the window; RecordRefused(NoInput) without an input stream; Unsupported if the ring or the
 *     window couldn't be made.
 */
capture_buffer_for :: fn(driver : ptr[mut Driver], index : usize) -> audio.Response {
    startup :: slop_os.startup_block()
    if driver.capture_stream == NO_STREAM {
        return audio.Response.RecordRefused(audio.PlayRefused.{period = 0, why = .NoInput})
    }
    if cast[slop_os.Handle](driver.capture_ring) == slop_os.NO_HANDLE {
        memory :: slop_os.memory_create(startup.budget, audio.BUFFER_BYTES) or_return audio.Response.Unsupported
        at :: runtime.reserve_addresses(cast[usize](audio.BUFFER_BYTES)) or_return audio.Response.Unsupported
        read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
        if slop_os.memory_map(memory, startup.space, cast[u64](at), 0, audio.BUFFER_BYTES, read_write) is_error {
            _ = slop_os.handle_close(cast[slop_os.Handle](memory))
            return audio.Response.Unsupported
        }
        driver.capture_ring = memory
        driver.capture_ring_at = cast[u64](at)
    }
    if driver.recorder != index && driver.recorder != NOBODY {
        stop_recording(driver)
    }
    driver.recorder = index
    window :: slop_os.memory_create_window(driver.capture_ring, startup.budget, 0, audio.BUFFER_BYTES)
        or_return audio.Response.Unsupported
    return audio.Response.CaptureBuffer(window)
}

/**
 * Give the device a capture period to fill: its place among the captured frames sent on the receive queue, with its
 * header and status (struct virtio_snd_pcm_xfer, the frames, struct virtio_snd_pcm_status); and once START_PERIODS are
 * given, the input stream started.
 *
 * @param driver The driver.
 * @param index The client's index.
 * @param period The period's index in the capture ring.
 * @return Null once it's sent, to be answered when the device has filled it; why not otherwise.
 */
record :: fn(driver : ptr[mut Driver], index : usize, period : u32) -> audio.Refused? {
    if driver.capture_stream == NO_STREAM {
        return audio.Refused.NoInput
    }
    if driver.recorder != index || cast[slop_os.Handle](driver.capture_ring) == slop_os.NO_HANDLE {
        return audio.Refused.NoBuffer
    }
    slot :: cast[usize](period)
    if slot >= driver.capture_heads.count || driver.capture_heads[slot] != virtio.NO_DESCRIPTOR {
        return audio.Refused.BadPeriod
    }
    bytes :: period_bytes(driver.capture_format)
    frames_at :: cast[u64](period) * bytes
    header :: cast[u64](period) * 16
    virtio.write_u32(here(driver, CAPTURE_TRANSFER_PAGE, header), 0, driver.capture_stream)
    virtio.write_u32(here(driver, CAPTURE_TRANSFER_PAGE, header), 8, 0)
    parts :: virtio.Part.[
        virtio.Part.{address = there(driver, CAPTURE_TRANSFER_PAGE, header), length = 4, device_writes = false},
        virtio.Part.{address = there(driver, CAPTURE_FRAMES_PAGE, frames_at), length = cast[u32](bytes), device_writes = true},
        virtio.Part.{address = there(driver, CAPTURE_TRANSFER_PAGE, header + 8), length = 8, device_writes = true},
    ]
    head :: virtio.offer_chain(&driver.rx, parts[0..<parts.count])
    if head == virtio.NO_DESCRIPTOR {
        return audio.Refused.DeviceFailed
    }
    driver.capture_heads[slot] = head
    driver.capture_given += 1
    if !driver.recording && driver.capture_given >= audio.START_PERIODS {
        if !stream_request(driver, driver.capture_stream, R_PCM_START) {
            return null
        }
        driver.recording = true
    }
    return null
}

/**
 * Answer each capture period the device has filled: its frames decoded into the capture ring, and Recorded to the
 * client that records, with the overruns so far. Having none left to fill while recording counts as an overrun.
 *
 * @param driver The driver.
 */
take_recorded :: fn(driver : ptr[mut Driver]) {
    loop {
        used :: virtio.take_used(&driver.rx) or_return void
        for &head, slot in driver.capture_heads {
            if head^ != used.id {
                continue
            }
            head^ = virtio.NO_DESCRIPTOR
            driver.capture_given -= 1
            bytes :: period_bytes(driver.capture_format)
            status :: virtio.read_u32(here(driver, CAPTURE_TRANSFER_PAGE, cast[u64](slot) * 16 + 8), 0)
            if status == S_OK && cast[slop_os.Handle](driver.capture_ring) != slop_os.NO_HANDLE {
                /*
                 * Only what the device says it wrote, its status's 8 bytes after the frames, and silence past it, so a
                 * short write doesn't hand on what an earlier one left
                 */
                written :: if cast[u64](used.length) >= 8 { cast[u64](used.length) - 8 } else { cast[u64](0) }
                heard :: if written < bytes { written } else { bytes }
                from :: view_of(cast[ptr[u8]](here(driver, CAPTURE_FRAMES_PAGE, cast[u64](slot) * bytes)), cast[usize](heard))
                samples :: cast[usize](audio.PERIOD_FRAMES * audio.CHANNELS)
                into :: view_of(
                    cast[ptr[mut f32]](driver.capture_ring_at + cast[u64](slot) * cast[u64](audio.PERIOD_BYTES)),
                    samples
                )
                decoded :: pcm.decode(sample_format(driver.capture_format), from, into)
                for &sample, k in into {
                    if k >= decoded {
                        sample^ = 0.0
                    }
                }
            }
            if driver.capture_given == 0 && driver.recording {
                driver.overruns += 1
            }
            answer_recorded(driver, cast[u32](slot), status)
            break
        }
    }
}

/**
 * Answer a capture period the device filled to the client that records.
 *
 * @param driver The driver.
 * @param period The period.
 * @param status The device's status for it.
 */
answer_recorded :: fn(driver : ptr[mut Driver], period : u32, status : u32) {
    if driver.recorder >= driver.clients.ends.count {
        return void
    }
    end :: driver.clients.ends[driver.recorder]
    out := os.Outgoing.{}
    response :: os.begin[audio.Response](&out)
    response^ = if status == S_OK {
        audio.Response.Recorded(audio.Recorded.{period = period, overruns = driver.overruns})
    }
    else {
        audio.Response.RecordRefused(audio.PlayRefused.{period = period, why = .DeviceFailed})
    }
    _ = audio.send_response(end, driver.port, &out)
}

/**
 * Stop recording: the input stream stopped and released, which returns the periods it held, each answered, and
 * prepared again for the next Record. A period the device hasn't returned yet stays given, its descriptors freed and
 * it answered when it does, so none is lost; a Record of it meanwhile is refused BadPeriod.
 *
 * @param driver The driver, its recording cleared.
 */
stop_recording :: fn(driver : ptr[mut Driver]) {
    if driver.capture_stream == NO_STREAM {
        return void
    }
    if driver.recording {
        _ = stream_request(driver, driver.capture_stream, R_PCM_STOP)
        driver.recording = false
    }
    _ = stream_request(driver, driver.capture_stream, R_PCM_RELEASE)
    take_recorded(driver)
    _ = stream_request(driver, driver.capture_stream, R_PCM_PREPARE)
}
