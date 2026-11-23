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
/** The frames a stream keeps converted, ahead of the mix. */
CARRY_FRAMES : usize : 1024
/** The most samples of a stream's period: the highest rate's frames times the most channels. */
MAX_PERIOD_SAMPLES : usize : 960 * 8
/** How many periods of the mix with nothing to mix before the device is stopped: 100 ms. */
IDLE_PERIODS : u32 : 20

/** A stream, a connection's. */
Stream :: struct {
    /** Whether it's open, its format and ring laid out. */
    open : bool,
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
    /** Its resampler, when its rate isn't 48 kHz; null when it is. */
    resampler : ptr[mut pcm.Resampler]?,
    /** Its frames converted, at 48 kHz stereo, ahead of the mix: carried of them. */
    carry : f32[CARRY_FRAMES * MIX_CHANNELS],
    carried : usize,
    /** Its volume, as a gain. */
    gain : f32,
    /** Whether it's playing: given a period since it opened or last stopped. */
    playing : bool,
    /** How many periods of the mix it was silence for, having run out while playing. */
    underruns : u32,
}

/** A client's place for its stream. */
Slot :: struct {
    /** Its stream; null for none. */
    stream : ptr[mut Stream]?,
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
 * @return 99 without memory for its state, 2 without a port, 3 if the listener couldn't be served; 0 once asked to stop.
 */
main :: fn(log : slop_os.DebugLog?, device : os.Channel[connector.Connector]?, clients : os.Listener[sound.Sound]) -> int {
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
    if !service_kit.add_client(&service.clients, service.port, clients.end) {
        return 3
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
    if index >= service.clients.ends.count {
        return void
    }
    end :: service.clients.ends[index]
    if cast[slop_os.Handle](end) == slop_os.NO_HANDLE {
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
                close_stream(service, index)
                service_kit.drop_client(&service.clients, index)
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
                drop_queued(service, index)
                response^ = .Stopped
            }
            case Connect(connection) => {
                _ = service_kit.add_client_index(&service.clients, service.port, connection.end)
                continue
            }
        }
        _ = sound.send_response(end, service.port, &out)
    }
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
        _ = pcm.resampler_for(resampler, format.rate, audio.RATE, cast[u32](MIX_CHANNELS))
        stream.resampler = resampler
    }
    service.streams[index].stream = stream
    return .Opened(sound.Opened.{period_frames = stream.period_frames, period_bytes = stream.period_bytes, periods = sound.PERIODS})
}

/**
 * Give a client a window onto its stream's ring, made the first time.
 *
 * @param service The service.
 * @param index The client's index.
 * @return Buffer with the window; Refused NotOpen or NoMemory.
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
    stream :: stream_of(service, index) or_return sound.Refused.NotOpen
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
    at :: cast[usize]((stream.first + stream.queued) % sound.PERIODS)
    if at < stream.queue.count {
        stream.queue[at] = period
    }
    stream.queued += 1
    stream.playing = true
    if !service.mixing {
        start_mixing(service)
    }
    return null
}

/**
 * Answer a stream's period: Played, or PlayRefused for one dropped.
 *
 * @param service The service.
 * @param index The client's index.
 * @param period The period.
 * @param dropped Whether Stop or its stream's close dropped it, rather than its being mixed in.
 */
answer :: fn(service : ptr[mut Service], index : usize, period : u32, dropped : bool) {
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
    response^ = if dropped {
        sound.Response.PlayRefused(sound.PlayRefused.{period = period, why = .Dropped})
    }
    else {
        sound.Response.Played(sound.Played.{period = period, underruns = underruns})
    }
    _ = sound.send_response(end, service.port, &out)
}

/**
 * Drop a stream's periods not yet mixed in, each answered, and what it had converted; it stops playing.
 *
 * @param service The service.
 * @param index The client's index.
 */
drop_queued :: fn(service : ptr[mut Service], index : usize) {
    stream :: stream_of(service, index) or_return void
    loop {
        if stream.queued == 0 {
            break
        }
        at :: cast[usize](stream.first % sound.PERIODS)
        period :: if at < stream.queue.count { stream.queue[at] } else { 0 }
        stream.first = (stream.first + 1) % sound.PERIODS
        stream.queued -= 1
        answer(service, index, period, true)
    }
    stream.carried = 0
    stream.playing = false
}

/**
 * Close a client's stream, as its connection's gone: its ring and resampler freed.
 *
 * @param service The service.
 * @param index The client's index.
 */
close_stream :: fn(service : ptr[mut Service], index : usize) {
    stream :: stream_of(service, index) or_return void
    if cast[slop_os.Handle](stream.ring) != slop_os.NO_HANDLE {
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
    at :: runtime.reserve_addresses(cast[usize](audio.BUFFER_BYTES)) or_return false
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    if slop_os.memory_map(window, startup.space, cast[u64](at), 0, audio.BUFFER_BYTES, read_write) is_error {
        return false
    }
    service.driver_ring_at = cast[u64](at)
    return true
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
            case _ => {}
        }
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
        "mixed % periods, % of them missed, the latest % us late, each in at most % us, % us on average; the device ran out % times",
        service.mixed,
        service.missed,
        service.worst_late / 1000,
        service.worst_mix / 1000,
        if service.mixed > 0 { service.total_mix / service.mixed / 1000 } else { 0 },
        service.device_underruns
    )
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
        answer(service, index, period, false)
    }
}
