/**
 * The audio service (decisions/0196, 17d): mixes the streams programs play through it (the sound protocol), each in a
 * format of its own, into the sound device's, and plays the mix through the device's driver (the audio protocol).
 *
 * Each stream's periods are decoded, remixed to stereo, resampled to 48 kHz (std/audio) and kept until mixed; every
 * 5 ms, by the system's clock, one period of the mix is made, each stream's frames scaled by its volume and added,
 * clipped once, and given to the driver, its ring kept as full as the device takes. A stream that's run out is mixed as
 * silence, counted as its own underrun. A period mixed more than a period after its time is counted as missed: the
 * soft real-time goal is that none is, the service on a high-priority budget of a 5 ms period (system_config's
 * AUDIO_CPU). When the device takes periods slower than the clock, the mix waits for room rather than counting.
 *
 * The microphone (17f): the trusted path's connections, on a listener of their own (the microphone protocol), make
 * grants, each a sound connection that records, and take them back by closing the service's end of it. While any grant
 * records, the device's input is captured, the driver's capture ring given whole, and each period it fills is resampled,
 * remixed and encoded into every recording stream's format, filling the periods it gave. A grant's stream with none
 * given drops what's heard, its own overrun. The device's capture stops once none records.
 */
package audio_service

import intrinsics from "base:intrinsics"
import runtime from "base:runtime"
import os from "std:os"
import slop_os from "std:os/slop_os"
import audio as pcm from "std:audio"
import service_kit from "../../libraries/service_kit"
import audio from "../../protocols/audio"
import connector from "../../protocols/connector"
import microphone from "../../protocols/microphone"
import sound from "../../protocols/sound"

/** The port key the driver's answers come under; clients come under their indexes, below it. */
DRIVER_KEY : u64 : 1000
/** The most clients, the listener among them. */
MAX_CLIENTS : usize : 16
/** A period of the mix, in nanoseconds: the device's period, 240 frames at 48 kHz. */
PERIOD_NS : u64 : 5_000_000
/** The frames of a period of the mix. */
MIX_FRAMES : usize : 240
/** The mix's channels. */
MIX_CHANNELS : usize : 2
/**
 * The frames a stream keeps converted: ahead of the mix, at 48 kHz, or for a recording stream, at its own rate until
 * its client gives a period, two of its periods at the highest rate.
 */
CARRY_FRAMES : usize : 2048
/** The most samples of a stream's period: the highest rate's frames times the most channels. */
MAX_PERIOD_SAMPLES : usize : 960 * 8
/** How many periods of the mix with nothing to mix before the device is stopped: 100 ms. */
IDLE_PERIODS : u32 : 20

/** A stream, a connection's. */
Stream :: struct {
    /** Whether it's open, its format and ring laid out. */
    open : bool,
    /** Whether it records, a microphone grant's, rather than plays. */
    records : bool,
    /** Its format, as Open gave it, and how its samples are stored. */
    format : sound.Format,
    sample : pcm.SampleFormat,
    /** Its periods' frames and bytes. */
    period_frames : u32,
    period_bytes : u32,
    /** Its ring, mapped here; NO_HANDLE until GetBuffer. */
    ring : slop_os.Memory,
    ring_at : u64,
    ring_bytes : u64,
    /** The periods given, oldest first: queued of them from first. */
    queue : u32[sound.PERIODS],
    first : u32,
    queued : u32,
    /** Its resampler, when its rate isn't 48 kHz, to it or for recording from it; null when it is. */
    resampler : ptr[mut pcm.Resampler]?,
    /** Its frames converted, stereo: at 48 kHz ahead of the mix, or recorded at its rate: carried of them. */
    carry : f32[CARRY_FRAMES * MIX_CHANNELS],
    carried : usize,
    /** Its volume, as a gain. */
    gain : f32,
    /** Whether it's playing: given a period since it opened or last stopped. */
    playing : bool,
    /** How many periods of the mix it was silence for, having run out while playing. */
    underruns : u32,
    /** Whether it's recording: given a period to fill since it opened or last stopped. */
    recording : bool,
    /** How many of the device's periods it dropped, recording with no room to keep them. */
    overruns : u32,
}

/** What a client's connection is. */
Kind :: enum {
    /** No client: the place is free. */
    None,
    /** The listener programs' sound connections arrive on. */
    Listener,
    /** The listener the trusted path's microphone connections arrive on. */
    MicrophoneListener,
    /** A sound connection that plays. */
    Player,
    /** A sound connection a microphone grant made, which records. */
    Recorder,
    /** A trusted path's microphone connection, which makes grants and takes them back. */
    Control,
}

/** A client's place: what it is, and its stream. */
Slot :: struct {
    /** Its stream; null for none. */
    stream : ptr[mut Stream]?,
    /** What it is. */
    kind : Kind,
    /** For a Recorder: its grant's id, and the index of the Control that made it. */
    grant : u32,
    granted_by : usize,
    /** For a Recorder: how many WaitReleased for it are waiting, each answered Released once it's gone. */
    watches : u32,
}

/** Whether the device's input is captured. */
Capture :: enum {
    /** It isn't. */
    Off,
    /** The driver's been asked for its capture ring. */
    Asking,
    /** It is: the capture ring's periods given to the driver, as each is taken. */
    On,
    /** The device has nothing to record from: every Record is refused. */
    NoInput,
}

/** The service's state. */
Service :: struct {
    /** Its port: its clients and the driver. */
    port : slop_os.Port,
    /** Its listener and clients. */
    clients : service_kit.Clients,
    /** Each client's stream, by its index. */
    streams : Slot[MAX_CLIENTS],
    /** Its connection to the sound device's driver; NO_HANDLE without one. */
    driver : slop_os.Channel,
    /** The driver's ring, mapped here; 0 until it's asked for. */
    driver_ring_at : u64,
    /** Whether each of the driver's periods is given to it, not yet answered. */
    driver_given : bool[audio.PERIODS],
    /** Whether it's mixing: some stream has played since the device was last stopped. */
    mixing : bool,
    /** When the next period of the mix is due, by the monotonic clock. */
    due : u64,
    /** How many periods of the mix in a row had nothing to mix. */
    idle : u32,
    /** Whether the device's input is captured. */
    capture : Capture,
    /** The driver's capture ring, mapped here; 0 until it's asked for. */
    capture_ring_at : u64,
    /** Whether each of its periods is given to the driver, not yet answered. */
    capture_given : bool[audio.PERIODS],
    /** Since capture started: the device's periods taken, and how often it had none given to fill. */
    captured : u64,
    capture_overruns : u32,
    /** The next grant's id. */
    next_grant : u32,
    /** Since mixing started: periods mixed, periods mixed late (missed), the worst lateness, the device's underruns. */
    mixed : u64,
    missed : u64,
    worst_late : u64,
    /** How long mixing a period took, at most and in all, in nanoseconds. */
    worst_mix : u64,
    total_mix : u64,
    device_underruns : u32,
    /** The mix, and room to convert a stream's period in. */
    mix : f32[MIX_FRAMES * MIX_CHANNELS],
    decoded : f32[MAX_PERIOD_SAMPLES],
    stereo : f32[MAX_PERIOD_SAMPLES / 4],
    resampled : f32[(CARRY_FRAMES / 2) * MIX_CHANNELS],
}

/**
 * Serve the sound protocol: mix the streams programs play into the sound device's, until asked to stop.
 *
 * @param log The debug log, where what it played is said.
 * @param device A connector to the sound device's driver; without one, streams open but Play is refused NoDevice.
 * @param clients The listener programs' connections arrive on.
 * @param microphones The listener the trusted path's microphone connections arrive on, which the supervisor makes for
 *     it; without it, nothing records.
 * @return 99 without memory for its state, 2 without a port, 3 if a listener couldn't be served; 0 once asked to stop.
 */
main :: fn(
    log : slop_os.DebugLog?,
    device : os.Channel[connector.Connector]?,
    clients : os.Listener[sound.Sound],
    microphones : os.Listener[microphone.Microphone]?
) -> int {
    startup :: slop_os.startup_block()
    made, error :: runtime.new_aligned(Service, align_of(Service))
    if error != null {
        return 99
    }
    service :: made
    service.port = slop_os.port_create(startup.budget) or_return 2
    service.driver = cast[slop_os.Channel](slop_os.NO_HANDLE)
    _ = service_kit.watch_stop(service.port)
    match device {
        case Some(dialing) => match os.port_for(startup.budget, dialing.end) {
            case Some(dial_port) => match connector.dial[audio.Audio](dialing.end, dial_port) {
                case Some(found) => {
                    service.driver = found.end
                    signals :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
                    _ = slop_os.port_bind(service.port, cast[slop_os.Handle](found.end), signals, DRIVER_KEY, .Persistent)
                }
                case None => runtime.log_info("no sound device's driver answered")
            }
            case None => {}
        }
        case None => {}
    }
    service.next_grant = 1
    if !add(service, clients.end, .Listener) {
        return 3
    }
    match microphones {
        case Some(listener) => if !add(service, listener.end, .MicrophoneListener) {
            return 3
        }
        case None => {}
    }
    runtime.log_info(if service.driver != cast[slop_os.Channel](slop_os.NO_HANDLE) { "serving" } else { "serving, with no sound device" })
    into := os.Incoming.{}
    loop {
        with {
            i : usize = 0
        }
        loop {
            serve(service, i, &into)
            i += 1
        }
        while i < service.clients.count
        take_driver_answers(service, &into)
        mix_due(service)
        if service_kit.stopping() {
            return 0
        }
        packets : slop_os.Packet[8]
        _ = slop_os.port_wait(service.port, packets, if service.mixing { service.due } else { slop_os.NO_DEADLINE })
    }
}

/**
 * Take every request a client has sent, until there are none left, or it's gone, its stream closed with it.
 *
 * @param service The service.
 * @param index Which client, by its index.
 * @param into Where each request is received.
 */
serve :: fn(service : ptr[mut Service], index : usize, into : ptr[mut os.Incoming]) {
    if index >= service.clients.ends.count || index >= service.streams.count {
        return void
    }
    end :: service.clients.ends[index]
    if cast[slop_os.Handle](end) == slop_os.NO_HANDLE {
        return void
    }
    kind :: service.streams[index].kind
    if kind == .MicrophoneListener || kind == .Control {
        serve_control(service, index, into)
        return void
    }
    loop {
        match sound.receive_request(end, service.port, into, false) {
            case Received => {}
            case Empty => return void
            case Unsupported => {
                _ = sound.answer_unsupported(end, service.port)
                continue
            }
            case _ => {
                gone(service, index)
                return void
            }
        }
        out := os.Outgoing.{}
        response :: os.begin[sound.Response](&out)
        match os.message_of[sound.Request](into)^ {
            case Open(format) => response^ = open_stream(service, index, format)
            case GetBuffer => response^ = buffer_for(service, index)
            case Play(period) => match queue_period(service, index, period) {
                // Answered once it's mixed in
                case None => continue
                case Some(why) => response^ = .PlayRefused(sound.PlayRefused.{period = period, why = why})
            }
            case Record(period) => match queue_record(service, index, period) {
                // Answered once it's filled
                case None => continue
                case Some(why) => response^ = .PlayRefused(sound.PlayRefused.{period = period, why = why})
            }
            case SetVolume(volume) => {
                match stream_of(service, index) {
                    case Some(stream) => {
                        kept :: if volume > sound.FULL_VOLUME { sound.FULL_VOLUME } else { volume }
                        stream.gain = cast[f32](kept) / 1000.0
                    }
                    case None => {}
                }
                response^ = .VolumeSet
            }
            case Stop => {
                drop_queued(service, index, .Dropped)
                stop_capture_if_unused(service)
                response^ = .Stopped
            }
            case Connect(connection) => {
                if !add(service, connection.end, .Player) {
                    _ = slop_os.handle_close(cast[slop_os.Handle](connection.end))
                }
                continue
            }
        }
        _ = sound.send_response(end, service.port, &out)
    }
}

/**
 * Add a client, of a kind.
 *
 * @param service The service, whose clients and slots it's added to.
 * @param end Its end, which the service keeps once it's added; not closed when it isn't.
 * @param kind What it is.
 * @return Whether it's added: false with no room for it.
 */
add :: fn(service : ptr[mut Service], end : slop_os.Channel, kind : Kind) -> bool {
    index :: service_kit.add_client_index(&service.clients, service.port, end) or_return false
    if index < service.streams.count {
        service.streams[index] = Slot.{stream = null, kind = kind}
    }
    return true
}

/**
 * Let a client go, as its connection's gone or its grant's taken back: its stream closed, its end closed, so its peer
 * sees it gone, and its place freed. A grant's WaitReleased are answered first; a trusted path's connection takes its
 * grants with it, as nothing could show them or take them back.
 *
 * @param service The service.
 * @param index The client's index.
 */
gone :: fn(service : ptr[mut Service], index : usize) {
    if index >= service.streams.count {
        return void
    }
    slot :: service.streams[index]
    if slot.kind == .Recorder {
        released(service, slot)
    }
    close_stream(service, index)
    service_kit.drop_client(&service.clients, index)
    service.streams[index] = Slot.{stream = null, kind = .None}
    if slot.kind == .Control {
        for other, i in service.streams {
            if other.kind == .Recorder && other.granted_by == index {
                runtime.log_info("took back grant %, its trusted path gone", other.grant)
                gone(service, i)
            }
        }
    }
    if slot.kind == .Recorder {
        stop_capture_if_unused(service)
    }
}

/**
 * Answer each WaitReleased for a grant that's gone, on the connection that made it, if that's still there.
 *
 * @param service The service.
 * @param slot The grant's place, as it was.
 */
released :: fn(service : ptr[mut Service], slot : Slot) {
    if slot.granted_by >= service.clients.ends.count {
        return void
    }
    end :: service.clients.ends[slot.granted_by]
    if cast[slop_os.Handle](end) == slop_os.NO_HANDLE {
        return void
    }
    for i in 0..<slot.watches {
        out := os.Outgoing.{}
        os.begin[microphone.Response](&out)^ = .Released(slot.grant)
        _ = microphone.send_response(end, service.port, &out)
    }
}

/**
 * Take every request a trusted path's microphone connection, or their listener, has sent, until there are none left,
 * or it's gone, its grants taken back with it.
 *
 * @param service The service.
 * @param index Which client, by its index, a MicrophoneListener or a Control.
 * @param into Where each request is received.
 */
serve_control :: fn(service : ptr[mut Service], index : usize, into : ptr[mut os.Incoming]) {
    if index >= service.clients.ends.count {
        return void
    }
    end :: service.clients.ends[index]
    loop {
        match microphone.receive_request(end, service.port, into, false) {
            case Received => {}
            case Empty => return void
            case Unsupported => {
                _ = microphone.answer_unsupported(end, service.port)
                continue
            }
            case _ => {
                gone(service, index)
                return void
            }
        }
        out := os.Outgoing.{}
        response :: os.begin[microphone.Response](&out)
        match os.message_of[microphone.Request](into)^ {
            case Grant => response^ = grant(service, index)
            case Revoke(id) => match recorder_of(service, index, id) {
                case Some(at) => {
                    runtime.log_info("took back grant %", id)
                    gone(service, at)
                    response^ = .Revoked
                }
                case None => response^ = .Refused(.NoGrant)
            }
            case WaitReleased(id) => match recorder_of(service, index, id) {
                case Some(at) => {
                    if at < service.streams.count {
                        service.streams[at].watches += 1
                    }
                    // Answered once it's gone
                    continue
                }
                case None => response^ = .Released(id)
            }
            case Connect(connection) => {
                if !add(service, connection.end, .Control) {
                    _ = slop_os.handle_close(cast[slop_os.Handle](connection.end))
                }
                continue
            }
        }
        _ = microphone.send_response(end, service.port, &out)
    }
}

/**
 * Make a grant for a trusted path's connection: a sound connection that records, its server end a new client.
 *
 * @param service The service.
 * @param control The trusted path's connection's index.
 * @return Granted with the grant's id and the client end; Refused NoInput without a sound device, Full without room.
 */
grant :: fn(service : ptr[mut Service], control : usize) -> microphone.Response {
    if service.driver == cast[slop_os.Channel](slop_os.NO_HANDLE) || service.capture == .NoInput {
        return .Refused(.NoInput)
    }
    pair :: os.channel_for[sound.Sound](slop_os.startup_block().budget, sound.RING_BYTES)
        or_return microphone.Response.Refused(.Full)
    at :: service_kit.add_client_index(&service.clients, service.port, pair.a) or_else service.streams.count
    if at >= service.streams.count {
        _ = slop_os.handle_close(cast[slop_os.Handle](pair.a))
        _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
        return .Refused(.Full)
    }
    id :: service.next_grant
    service.next_grant += 1
    service.streams[at] = Slot.{stream = null, kind = .Recorder, grant = id, granted_by = control}
    runtime.log_info("granted the microphone: grant %", id)
    return .Granted(microphone.Granted.{id = id, end = os.Channel[sound.Sound].{end = pair.b}})
}

/**
 * Find a grant a trusted path's connection made, by its id.
 *
 * @param service The service.
 * @param control The connection's index.
 * @param id The grant's id.
 * @return Its client's index; null if that connection made none with that id, or it's gone.
 */
recorder_of :: fn(service : ptr[mut Service], control : usize, id : u32) -> usize? {
    for slot, i in service.streams {
        if slot.kind == .Recorder && slot.grant == id && slot.granted_by == control {
            return i
        }
    }
    return null
}

/**
 * The first samples of a view, as many as it has of them.
 *
 * @param samples The view.
 * @param count How many.
 * @return Its first count, or all of it if it's shorter.
 */
first :: fn(samples : mut f32[], count : usize) -> mut f32[] {
    if count <= samples.count {
        return samples[0..<count]
    }
    return samples
}

/** A client's stream, if it has one. */
stream_of :: fn(service : ptr[mut Service], index : usize) -> ptr[mut Stream]? {
    if index >= service.streams.count {
        return null
    }
    return service.streams[index].stream
}

/**
 * Open a client's stream in a format: its state made, its resampler too if its rate isn't 48 kHz.
 *
 * @param service The service.
 * @param index The client's index.
 * @param format The stream's format.
 * @return Opened with its ring's layout; Refused BadFormat for a format that isn't taken or a second Open, NoMemory.
 */
open_stream :: fn(service : ptr[mut Service], index : usize, format : sound.Format) -> sound.Response {
    if index >= service.streams.count || service.streams[index].stream is_some {
        return .Refused(.BadFormat)
    }
    if format.rate < sound.MIN_RATE || format.rate > sound.MAX_RATE || format.channels == 0
        || format.channels > sound.MAX_CHANNELS || format.sample == 0 || format.sample > 4 {
        return .Refused(.BadFormat)
    }
    made, error :: runtime.new_aligned(Stream, align_of(Stream))
    if error != null {
        return .Refused(.NoMemory)
    }
    stream :: made
    stream.open = true
    stream.records = service.streams[index].kind == .Recorder
    stream.recording = false
    stream.overruns = 0
    stream.format = format
    stream.sample = cast[pcm.SampleFormat](format.sample)
    stream.period_frames = sound.period_frames(format.rate)
    stream.period_bytes = stream.period_frames * format.channels * cast[u32](pcm.sample_bytes(stream.sample))
    stream.ring = cast[slop_os.Memory](slop_os.NO_HANDLE)
    stream.ring_bytes = (cast[u64](sound.PERIODS) * cast[u64](stream.period_bytes) + 4095) / 4096 * 4096
    stream.gain = 1.0
    stream.first = 0
    stream.queued = 0
    stream.carried = 0
    stream.playing = false
    stream.underruns = 0
    stream.resampler = null
    if format.rate != audio.RATE {
        resampler, failed :: runtime.new_aligned(pcm.Resampler, align_of(pcm.Resampler))
        if failed != null {
            runtime.free(stream)
            return .Refused(.NoMemory)
        }
        if stream.records {
            _ = pcm.resampler_for(resampler, audio.RATE, format.rate, cast[u32](MIX_CHANNELS))
        }
        else {
            _ = pcm.resampler_for(resampler, format.rate, audio.RATE, cast[u32](MIX_CHANNELS))
        }
        stream.resampler = resampler
    }
    service.streams[index].stream = stream
    return .Opened(sound.Opened.{period_frames = stream.period_frames, period_bytes = stream.period_bytes, periods = sound.PERIODS})
}

/**
 * Give a client a window onto its stream's ring, made the first time; or for a recording stream, the ring itself, read
 * only, which outlives the grant, so a client reading a period it was answered isn't faulted by the grant's being
 * taken back.
 *
 * @param service The service.
 * @param index The client's index.
 * @return Buffer with the window or the ring; Refused NotOpen or NoMemory.
 */
buffer_for :: fn(service : ptr[mut Service], index : usize) -> sound.Response {
    stream :: stream_of(service, index) or_return sound.Response.Refused(.NotOpen)
    startup :: slop_os.startup_block()
    if cast[slop_os.Handle](stream.ring) == slop_os.NO_HANDLE {
        memory :: slop_os.memory_create(startup.budget, stream.ring_bytes) or_return sound.Response.Refused(.NoMemory)
        at :: runtime.reserve_addresses(cast[usize](stream.ring_bytes)) or_return sound.Response.Refused(.NoMemory)
        read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
        if slop_os.memory_map(memory, startup.space, cast[u64](at), 0, stream.ring_bytes, read_write) is_error {
            _ = slop_os.handle_close(cast[slop_os.Handle](memory))
            return sound.Response.Refused(.NoMemory)
        }
        stream.ring = memory
        stream.ring_at = cast[u64](at)
    }
    if stream.records {
        read_only :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_READ) | cast[u32](slop_os.RIGHT_TRANSFER))
        copy :: slop_os.handle_duplicate(cast[slop_os.Handle](stream.ring), read_only)
            or_return sound.Response.Refused(.NoMemory)
        return sound.Response.Buffer(cast[slop_os.Memory](copy))
    }
    window :: slop_os.memory_create_window(stream.ring, startup.budget, 0, stream.ring_bytes)
        or_return sound.Response.Refused(.NoMemory)
    return sound.Response.Buffer(window)
}

/**
 * Take a period a client gave into its stream's queue, starting the mix if it isn't going.
 *
 * @param service The service.
 * @param index The client's index.
 * @param period The period's index in its ring.
 * @return Null once it's queued; why not otherwise.
 */
queue_period :: fn(service : ptr[mut Service], index : usize, period : u32) -> sound.Refused? {
    if index < service.streams.count && service.streams[index].kind == .Recorder {
        return sound.Refused.NotAllowed
    }
    stream :: stream_of(service, index) or_return sound.Refused.NotOpen
    match can_queue(service, stream, period) {
        case Some(why) => return why
        case None => {}
    }
    enqueue(stream, period)
    stream.playing = true
    if !service.mixing {
        start_mixing(service)
    }
    return null
}

/**
 * Tell whether a stream may be given a period.
 *
 * @param service The service.
 * @param stream The stream.
 * @param period The period's index in its ring.
 * @return Null if it may; NoBuffer before GetBuffer, BadPeriod for one past the ring or given already, NoDevice
 *     without a sound device.
 */
can_queue :: fn(service : ptr[mut Service], stream : ptr[mut Stream], period : u32) -> sound.Refused? {
    if cast[slop_os.Handle](stream.ring) == slop_os.NO_HANDLE {
        return sound.Refused.NoBuffer
    }
    if period >= sound.PERIODS || stream.queued >= sound.PERIODS {
        return sound.Refused.BadPeriod
    }
    for i in 0..<stream.queued {
        at :: cast[usize]((stream.first + i) % sound.PERIODS)
        if at < stream.queue.count && stream.queue[at] == period {
            return sound.Refused.BadPeriod
        }
    }
    if service.driver == cast[slop_os.Channel](slop_os.NO_HANDLE) {
        return sound.Refused.NoDevice
    }
    return null
}

/**
 * Put a period at the end of a stream's queue, can_queue having said it may.
 *
 * @param stream The stream.
 * @param period The period.
 */
enqueue :: fn(stream : ptr[mut Stream], period : u32) {
    at :: cast[usize]((stream.first + stream.queued) % sound.PERIODS)
    if at < stream.queue.count {
        stream.queue[at] = period
    }
    stream.queued += 1
}

/**
 * Take a period a recording stream's client gave to be filled, starting the device's capture if it isn't going.
 *
 * @param service The service.
 * @param index The client's index, a grant's.
 * @param period The period's index in its ring.
 * @return Null once it's queued; why not otherwise: NotAllowed on a connection that plays, NoInput once the device's
 *     been found to have nothing to record from, or what can_queue says.
 */
queue_record :: fn(service : ptr[mut Service], index : usize, period : u32) -> sound.Refused? {
    if index >= service.streams.count || service.streams[index].kind != .Recorder {
        return sound.Refused.NotAllowed
    }
    stream :: stream_of(service, index) or_return sound.Refused.NotOpen
    if service.capture == .NoInput {
        return sound.Refused.NoInput
    }
    match can_queue(service, stream, period) {
        case Some(why) => return why
        case None => {}
    }
    enqueue(stream, period)
    if !stream.recording {
        stream.recording = true
        stream.carried = 0
    }
    if service.capture == .Off {
        start_capture(service)
    }
    return null
}

/**
 * Answer a stream's period: Played, or PlayRefused for one dropped.
 *
 * @param service The service.
 * @param index The client's index.
 * @param period The period.
 * @param refused Why it's refused, as when Stop or its stream's close dropped it; null once it's mixed in.
 */
answer :: fn(service : ptr[mut Service], index : usize, period : u32, refused : sound.Refused?) {
    if index >= service.clients.ends.count {
        return void
    }
    end :: service.clients.ends[index]
    if cast[slop_os.Handle](end) == slop_os.NO_HANDLE {
        return void
    }
    underruns := cast[u32](0)
    match stream_of(service, index) {
        case Some(stream) => underruns = stream.underruns
        case None => {}
    }
    out := os.Outgoing.{}
    response :: os.begin[sound.Response](&out)
    match refused {
        case Some(why) => response^ = sound.Response.PlayRefused(sound.PlayRefused.{period = period, why = why})
        case None => response^ = sound.Response.Played(sound.Played.{period = period, underruns = underruns})
    }
    _ = sound.send_response(end, service.port, &out)
}

/**
 * Answer a recording stream's period, filled.
 *
 * @param service The service.
 * @param index The client's index.
 * @param stream Its stream.
 * @param period The period.
 */
answer_recorded :: fn(service : ptr[mut Service], index : usize, stream : ptr[Stream], period : u32) {
    if index >= service.clients.ends.count {
        return void
    }
    end :: service.clients.ends[index]
    out := os.Outgoing.{}
    os.begin[sound.Response](&out)^ = .Recorded(sound.Recorded.{period = period, overruns = stream.overruns})
    _ = sound.send_response(end, service.port, &out)
}

/**
 * Drop a stream's periods not yet mixed in or filled, each answered, and what it had converted; it stops playing and
 * recording.
 *
 * @param service The service.
 * @param index The client's index.
 * @param why What each is answered with.
 */
drop_queued :: fn(service : ptr[mut Service], index : usize, why : sound.Refused) {
    stream :: stream_of(service, index) or_return void
    loop {
        if stream.queued == 0 {
            break
        }
        at :: cast[usize](stream.first % sound.PERIODS)
        period :: if at < stream.queue.count { stream.queue[at] } else { 0 }
        stream.first = (stream.first + 1) % sound.PERIODS
        stream.queued -= 1
        answer(service, index, period, why)
    }
    stream.carried = 0
    stream.playing = false
    stream.recording = false
}

/**
 * Close a client's stream, as its connection's gone: its ring unmapped and closed, which destroys a player's window
 * onto it, and its resampler freed.
 *
 * @param service The service.
 * @param index The client's index.
 */
close_stream :: fn(service : ptr[mut Service], index : usize) {
    stream :: stream_of(service, index) or_return void
    if cast[slop_os.Handle](stream.ring) != slop_os.NO_HANDLE {
        _ = slop_os.memory_unmap(slop_os.startup_block().space, stream.ring_at)
        _ = slop_os.handle_close(cast[slop_os.Handle](stream.ring))
    }
    match stream.resampler {
        case Some(resampler) => runtime.free(resampler)
        case None => {}
    }
    runtime.free(stream)
    if index < service.streams.count {
        service.streams[index].stream = null
    }
}

/**
 * Start mixing: the driver's ring had, half of it given at once, mixed from what's there, and the next period due a
 * period from now.
 *
 * @param service The service, mixing from now.
 */
start_mixing :: fn(service : ptr[mut Service]) {
    if service.driver_ring_at == 0 && !driver_ring(service) {
        return void
    }
    service.mixing = true
    service.idle = 0
    service.mixed = 0
    service.missed = 0
    service.worst_late = 0
    service.worst_mix = 0
    service.total_mix = 0
    now :: slop_os.clock_monotonic() or_else 0
    for i in 0..<audio.START_PERIODS {
        mix_one(service)
    }
    service.due = now + PERIOD_NS
}

/**
 * Ask the driver for its ring and map it.
 *
 * @param service The service, whose driver_ring_at is set.
 * @return Whether it's mapped.
 */
driver_ring :: fn(service : ptr[mut Service]) -> bool {
    startup :: slop_os.startup_block()
    out := os.Outgoing.{}
    os.begin[audio.Request](&out)^ = .GetBuffer
    if audio.send_request(service.driver, service.port, &out) is_some {
        return false
    }
    into := os.Incoming.{}
    match audio.receive_response(service.driver, service.port, &into, true) {
        case Received => {}
        case _ => return false
    }
    window :: match os.message_of[audio.Response](&into)^ {
        case Buffer(memory) => memory
        case _ => return false
    }
    service.driver_ring_at = mapped(window) or_return false
    return true
}

/**
 * Map a window onto one of the driver's rings.
 *
 * @param window The window, BUFFER_BYTES of it, which stays mapped for the service's life.
 * @return Where it's mapped; null if it couldn't be, the window closed.
 */
mapped :: fn(window : slop_os.Memory) -> u64? {
    startup :: slop_os.startup_block()
    at :: runtime.reserve_addresses(cast[usize](audio.BUFFER_BYTES)) or_else 0
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    if at == 0 || slop_os.memory_map(window, startup.space, cast[u64](at), 0, audio.BUFFER_BYTES, read_write) is_error {
        _ = slop_os.handle_close(cast[slop_os.Handle](window))
        return null
    }
    return cast[u64](at)
}

/**
 * Take the driver's answers: each period it played is free again, and its underruns kept.
 *
 * @param service The service.
 * @param into Where each answer is received.
 */
take_driver_answers :: fn(service : ptr[mut Service], into : ptr[mut os.Incoming]) {
    if service.driver == cast[slop_os.Channel](slop_os.NO_HANDLE) {
        return void
    }
    loop {
        match audio.receive_response(service.driver, service.port, into, false) {
            case Received => {}
            case _ => return void
        }
        match os.message_of[audio.Response](into)^ {
            case Played(done) => {
                if cast[usize](done.period) < service.driver_given.count {
                    service.driver_given[cast[usize](done.period)] = false
                }
                service.device_underruns = done.underruns
            }
            case Refused(refused) => {
                if cast[usize](refused.period) < service.driver_given.count {
                    service.driver_given[cast[usize](refused.period)] = false
                }
            }
            case CaptureBuffer(window) => match mapped(window) {
                case Some(at) => {
                    service.capture_ring_at = at
                    service.capture = .Off
                    if somebody_records(service) {
                        start_capture(service)
                    }
                }
                case None => no_input(service)
            }
            case Recorded(done) => {
                period :: cast[usize](done.period)
                if period < service.capture_given.count {
                    service.capture_given[period] = false
                }
                service.capture_overruns = done.overruns
                if service.capture == .On && period < service.capture_given.count {
                    service.captured += 1
                    take_captured(service, done.period)
                    give_capture(service, done.period)
                }
            }
            case RecordRefused(refused) => {
                if refused.why == .NoInput {
                    no_input(service)
                }
                else if cast[usize](refused.period) < service.capture_given.count {
                    service.capture_given[cast[usize](refused.period)] = false
                }
            }
            case _ => {}
        }
    }
}

/**
 * Tell whether any stream's recording.
 *
 * @param service The service.
 * @return True if a grant's stream has a period given since it last stopped.
 */
somebody_records :: fn(service : ptr[mut Service]) -> bool {
    for slot in service.streams {
        match slot.stream {
            case Some(stream) => if stream.records && stream.recording {
                return true
            }
            case None => {}
        }
    }
    return false
}

/**
 * Start capturing the device's input: the driver asked for its capture ring the first time, its periods given once
 * it's mapped.
 *
 * @param service The service, its capture Asking or On.
 */
start_capture :: fn(service : ptr[mut Service]) {
    if service.capture_ring_at == 0 {
        out := os.Outgoing.{}
        os.begin[audio.Request](&out)^ = .GetCaptureBuffer
        if audio.send_request(service.driver, service.port, &out) is_none {
            service.capture = .Asking
        }
        return void
    }
    service.capture = .On
    service.captured = 0
    runtime.log_info("recording")
    for given, i in service.capture_given {
        if !given {
            give_capture(service, cast[u32](i))
        }
    }
}

/**
 * Give the driver a period of the capture ring to fill.
 *
 * @param service The service.
 * @param period The period.
 */
give_capture :: fn(service : ptr[mut Service], period : u32) {
    out := os.Outgoing.{}
    os.begin[audio.Request](&out)^ = .Record(period)
    if audio.send_request(service.driver, service.port, &out) is_none && cast[usize](period) < service.capture_given.count {
        service.capture_given[cast[usize](period)] = true
    }
}

/**
 * Stop capturing once no stream records, and say what was captured. The periods the driver held come back answered,
 * and aren't taken.
 *
 * @param service The service.
 */
stop_capture_if_unused :: fn(service : ptr[mut Service]) {
    if service.capture != .On || somebody_records(service) {
        return void
    }
    service.capture = .Off
    out := os.Outgoing.{}
    os.begin[audio.Request](&out)^ = .StopRecording
    _ = audio.send_request(service.driver, service.port, &out)
    runtime.log_info("recorded % periods; the device had none to fill % times", service.captured, service.capture_overruns)
}

/**
 * The device has nothing to record from: every recording stream's periods refused NoInput, and every Record after.
 *
 * @param service The service.
 */
no_input :: fn(service : ptr[mut Service]) {
    service.capture = .NoInput
    runtime.log_info("the sound device has nothing to record from")
    for slot, i in service.streams {
        match slot.stream {
            case Some(stream) => if stream.records {
                drop_queued(service, i, .NoInput)
            }
            case None => {}
        }
    }
}

/**
 * Take a period the device filled into every recording stream: resampled to its rate, kept until its client's given
 * a period, then remixed to its channels, scaled by its volume and encoded into it. A stream with no room left for
 * the period drops it, an overrun.
 *
 * @param service The service, whose room to convert in is used.
 * @param period The period's index in the capture ring.
 */
take_captured :: fn(service : ptr[mut Service], period : u32) {
    samples :: cast[usize](audio.PERIOD_FRAMES * audio.CHANNELS)
    heard :: view_of(cast[ptr[mut f32]](service.capture_ring_at + cast[u64](period) * cast[u64](audio.PERIOD_BYTES)), samples)
    for i in 0..<service.streams.count {
        match stream_of(service, i) {
            case Some(stream) => if stream.records && stream.recording {
                keep_heard(service, i, stream, heard)
            }
            case None => {}
        }
    }
}

/**
 * Keep a period the device filled for a recording stream, as take_captured says, and fill what periods it can.
 *
 * @param service The service, whose room to convert in is used.
 * @param index The stream's client's index.
 * @param stream The stream, recording.
 * @param heard The period, 48 kHz stereo.
 */
keep_heard :: fn(service : ptr[mut Service], index : usize, stream : ptr[mut Stream], heard : mut f32[]) {
    converted := heard
    match stream.resampler {
        case Some(resampler) => {
            resampled_all :: service.resampled[0..<service.resampled.count]
            made :: pcm.resample(resampler, heard, resampled_all)
            converted = first(resampled_all, made * MIX_CHANNELS)
        }
        case None => {}
    }
    frames :: converted.count / MIX_CHANNELS
    if stream.carried + frames > CARRY_FRAMES {
        stream.overruns += 1
    }
    else {
        stored := stream.carried * MIX_CHANNELS
        for value in converted {
            if stored < stream.carry.count {
                stream.carry[stored] = value
            }
            stored += 1
        }
        stream.carried += frames
    }
    deliver(service, index, stream)
}

/**
 * Fill a recording stream's periods given, oldest first, while it has a period's frames kept, each answered Recorded.
 *
 * @param service The service, whose room to convert in is used.
 * @param index The stream's client's index.
 * @param stream The stream.
 */
deliver :: fn(service : ptr[mut Service], index : usize, stream : ptr[mut Stream]) {
    channels :: cast[usize](stream.format.channels)
    frames :: cast[usize](stream.period_frames)
    loop {
        if stream.queued == 0 || stream.carried < frames || frames * channels > service.decoded.count {
            return void
        }
        at :: cast[usize](stream.first % sound.PERIODS)
        period :: if at < stream.queue.count { stream.queue[at] } else { 0 }
        decoded_all :: service.decoded[0..<service.decoded.count]
        made :: pcm.remix(first(stream.carry[0..<stream.carry.count], frames * MIX_CHANNELS), cast[u32](MIX_CHANNELS),
            first(decoded_all, frames * channels), cast[u32](channels))
        out :: first(decoded_all, made * channels)
        if stream.gain != 1.0 {
            pcm.scale(out, stream.gain)
        }
        bytes :: view_of(cast[ptr[mut u8]](stream.ring_at + cast[u64](period) * cast[u64](stream.period_bytes)),
            cast[usize](stream.period_bytes))
        _ = pcm.encode(out, stream.sample, bytes)
        // What's left moved to the front
        rest :: (stream.carried - frames) * MIX_CHANNELS
        taken :: frames * MIX_CHANNELS
        for k in 0..<rest {
            from :: k + taken
            if k < stream.carry.count && from < stream.carry.count {
                stream.carry[k] = stream.carry[from]
            }
        }
        stream.carried -= frames
        stream.first = (stream.first + 1) % sound.PERIODS
        stream.queued -= 1
        answer_recorded(service, index, stream, period)
    }
}

/**
 * Mix each period that's come due, while the driver has room; one mixed more than a period after its time is missed.
 * With nothing to mix for IDLE_PERIODS in a row, the device is stopped and what was played said.
 *
 * @param service The service.
 */
mix_due :: fn(service : ptr[mut Service]) {
    if !service.mixing {
        return void
    }
    loop {
        now :: slop_os.clock_monotonic() or_else 0
        if now < service.due {
            return void
        }
        late :: now - service.due
        if !mix_one(service) {
            // The device hasn't taken the last: it's behind the clock, so the mix waits, its time moved on
            service.due = now + PERIOD_NS
            return void
        }
        if late > service.worst_late {
            service.worst_late = late
        }
        if late > PERIOD_NS {
            service.missed += 1
        }
        service.due += PERIOD_NS
        if service.idle >= IDLE_PERIODS {
            stop_mixing(service)
            return void
        }
    }
}

/**
 * Stop mixing, the device stopped, and say what was played.
 *
 * @param service The service.
 */
stop_mixing :: fn(service : ptr[mut Service]) {
    service.mixing = false
    out := os.Outgoing.{}
    os.begin[audio.Request](&out)^ = .Stop
    _ = audio.send_request(service.driver, service.port, &out)
    runtime.log_info(
        "mixed % periods, the latest % us late, each in at most % us, % us on average",
        service.mixed,
        service.worst_late / 1000,
        service.worst_mix / 1000,
        if service.mixed > 0 { service.total_mix / service.mixed / 1000 } else { 0 }
    )
    // Each on a line of its own, for a test to hold to (decisions/0196, 17e)
    runtime.log_info("missed % of % periods mixed", service.missed, service.mixed)
    runtime.log_info("the device ran out % times", service.device_underruns)
}

/**
 * Mix one period of every stream into a free period of the driver's ring and give it to the driver.
 *
 * @param service The service.
 * @return False, nothing mixed, when every period of the driver's ring is given.
 */
mix_one :: fn(service : ptr[mut Service]) -> bool {
    began :: slop_os.clock_monotonic() or_else 0
    mixed :: mix_into_driver(service)
    took :: (slop_os.clock_monotonic() or_else began) - began
    if mixed {
        service.total_mix += took
        service.worst_mix = if took > service.worst_mix { took } else { service.worst_mix }
    }
    return mixed
}

/**
 * Mix one period, as mix_one says, without timing it.
 *
 * @param service The service.
 * @return False, nothing mixed, when every period of the driver's ring is given.
 */
mix_into_driver :: fn(service : ptr[mut Service]) -> bool {
    free := audio.PERIODS
    for given, i in service.driver_given {
        if !given && free == audio.PERIODS {
            free = cast[u32](i)
        }
    }
    if free >= audio.PERIODS {
        return false
    }
    for &sample in service.mix {
        sample^ = 0.0
    }
    anything := false
    for i in 0..<service.streams.count {
        match stream_of(service, i) {
            case Some(stream) => if stream.playing {
                fill(service, i, stream)
                frames :: if stream.carried < MIX_FRAMES { stream.carried } else { MIX_FRAMES }
                if stream.carried < MIX_FRAMES {
                    stream.underruns += 1
                }
                if frames > 0 {
                    anything = true
                    _ = pcm.mix(first(service.mix[0..<service.mix.count], frames * MIX_CHANNELS),
                        first(stream.carry[0..<stream.carry.count], frames * MIX_CHANNELS), stream.gain)
                    // What's left moved to the front
                    rest :: (stream.carried - frames) * MIX_CHANNELS
                    taken :: frames * MIX_CHANNELS
                    for k in 0..<rest {
                        from :: k + taken
                        if k < stream.carry.count && from < stream.carry.count {
                            stream.carry[k] = stream.carry[from]
                        }
                    }
                    stream.carried -= frames
                }
                // Played out, and nothing more given: it's stopped
                if stream.carried == 0 && stream.queued == 0 && frames < MIX_FRAMES {
                    stream.playing = false
                }
            }
            case None => {}
        }
    }
    service.idle = if anything { 0 } else { service.idle + 1 }
    _ = pcm.clip(service.mix[0..<service.mix.count])
    samples :: cast[usize](audio.PERIOD_FRAMES * audio.CHANNELS)
    into :: view_of(cast[ptr[mut f32]](service.driver_ring_at + cast[u64](free) * cast[u64](audio.PERIOD_BYTES)), samples)
    for value, k in service.mix {
        if k < into.count {
            into[k] = value
        }
    }
    out := os.Outgoing.{}
    os.begin[audio.Request](&out)^ = .Play(free)
    if audio.send_request(service.driver, service.port, &out) is_none {
        if cast[usize](free) < service.driver_given.count {
            service.driver_given[cast[usize](free)] = true
        }
    }
    service.mixed += 1
    return true
}

/**
 * Convert a stream's queued periods, oldest first, until it has a period of the mix's frames carried, each answered
 * Played as it's taken: decoded, remixed to stereo, and resampled to 48 kHz.
 *
 * @param service The service, whose room to convert in is used.
 * @param index The stream's client's index.
 * @param stream The stream.
 */
fill :: fn(service : ptr[mut Service], index : usize, stream : ptr[mut Stream]) {
    channels :: cast[usize](stream.format.channels)
    frames :: cast[usize](stream.period_frames)
    loop {
        if stream.carried >= MIX_FRAMES || stream.queued == 0 {
            return void
        }
        at :: cast[usize](stream.first % sound.PERIODS)
        period :: if at < stream.queue.count { stream.queue[at] } else { 0 }
        start :: cast[u64](period) * cast[u64](stream.period_bytes)
        bytes :: view_of(cast[ptr[u8]](stream.ring_at + start), cast[usize](stream.period_bytes))
        samples :: frames * channels
        if samples > service.decoded.count || frames * MIX_CHANNELS > service.stereo.count {
            return void
        }
        decoded_all :: service.decoded[0..<service.decoded.count]
        stereo_all :: service.stereo[0..<service.stereo.count]
        decoded :: pcm.decode(stream.sample, bytes, first(decoded_all, samples))
        made :: pcm.remix(first(decoded_all, decoded), cast[u32](channels), first(stereo_all, frames * MIX_CHANNELS),
            cast[u32](MIX_CHANNELS))
        converted := first(stereo_all, made * MIX_CHANNELS)
        match stream.resampler {
            case Some(resampler) => {
                resampled_all :: service.resampled[0..<service.resampled.count]
                out_frames :: pcm.resample(resampler, converted, resampled_all)
                converted = first(resampled_all, out_frames * MIX_CHANNELS)
            }
            case None => {}
        }
        stored := stream.carried * MIX_CHANNELS
        for value in converted {
            if stored >= stream.carry.count {
                break
            }
            stream.carry[stored] = value
            stored += 1
        }
        stream.carried = stored / MIX_CHANNELS
        stream.first = (stream.first + 1) % sound.PERIODS
        stream.queued -= 1
        answer(service, index, period, null)
    }
}
