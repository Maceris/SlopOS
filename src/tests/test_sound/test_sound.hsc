/**
 * test_sound (decisions/0196, 17c to 17e): two streams played at once through the audio service, a second each: a
 * 1 kHz tone at 48 kHz stereo floats, and a 1.5 kHz tone at 44.1 kHz mono 16-bit integers, each at a quarter of full
 * scale, every period of their rings kept given. The service mixes them, the second converted, remixed and resampled;
 * boot.py's --audio-tone reads what QEMU played. Started by the supervisor with test_sound on the kernel's command
 * line; with test_sound_load too, three seconds each, while test_spinner keeps every CPU busy in the background
 * band, for the soft real-time goal: every period mixed in time, and none run out.
 *
 * With test_sound_record instead (17f), it records: given a microphone connection, as the trusted path is, it grants
 * itself the microphone, records a second at 16 kHz mono 16-bit integers, and takes the grant back, which closes the
 * grant's connection, heard as released first.
 */
package test_sound

import runtime from "base:runtime"
import os from "std:os"
import slop_os from "std:os/slop_os"
import audio as pcm from "std:audio"
import math from "std:math"
import connector from "../../protocols/connector"
import service_kit from "../../libraries/service_kit"
import microphone from "../../protocols/microphone"
import sound from "../../protocols/sound"

/** Each tone's level: a quarter of full scale, so the two mixed stay under it. */
LEVEL : f64 : 0.25
/** The most samples of a period here: 48 kHz's 240 frames of 2 channels. */
MOST_SAMPLES : usize : 480

/** A stream being played: its connection, format, ring, and how far through its seconds it is. */
Playing :: struct {
    end : slop_os.Channel,
    format : sound.Format,
    tone : f64,
    opened : sound.Opened,
    ring : u64,
    /** Frames written so far, of format.rate. */
    frame : u64,
    /** Periods given and played. */
    given : u32,
    played : u32,
    /** The periods it takes to play its seconds. */
    periods : u32,
    underruns : u32,
}

/**
 * Send a request and wait for its answer.
 *
 * @return Whether it came, in into.
 */
call :: fn(end : slop_os.Channel, port : slop_os.Port, out : ptr[mut os.Outgoing], into : ptr[mut os.Incoming]) -> bool {
    if sound.send_request(end, port, out) is_some {
        return false
    }
    return match sound.receive_response(end, port, into, true) {
        case Received => true
        case _ => false
    }
}

/**
 * Open a stream on a new connection to the service, and map its ring.
 *
 * @return The stream; null if the connection, the Open or the ring failed.
 */
open :: fn(dialing : slop_os.Channel, format : sound.Format, tone : f64, seconds : u32) -> Playing? {
    startup :: slop_os.startup_block()
    dial_port :: os.port_for(startup.budget, dialing) or_return null
    defer slop_os.handle_close(cast[slop_os.Handle](dial_port))
    connection :: connector.dial[sound.Sound](dialing, dial_port) or_return null
    port :: os.port_for(startup.budget, connection.end) or_return null
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    into := os.Incoming.{}
    out := os.Outgoing.{}
    os.begin[sound.Request](&out)^ = .Open(format)
    if !call(connection.end, port, &out, &into) {
        return null
    }
    opened :: match os.message_of[sound.Response](&into)^ {
        case Opened(layout) => layout
        case _ => return null
    }
    asking := os.Outgoing.{}
    os.begin[sound.Request](&asking)^ = .GetBuffer
    if !call(connection.end, port, &asking, &into) {
        return null
    }
    window :: match os.message_of[sound.Response](&into)^ {
        case Buffer(memory) => memory
        case _ => return null
    }
    bytes :: (cast[u64](opened.periods) * cast[u64](opened.period_bytes) + 4095) / 4096 * 4096
    ring :: runtime.reserve_addresses(cast[usize](bytes)) or_return null
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    if slop_os.memory_map(window, startup.space, cast[u64](ring), 0, bytes, read_write) is_error {
        return null
    }
    periods :: (format.rate * seconds + opened.period_frames - 1) / opened.period_frames
    return Playing.{end = connection.end, format = format, tone = tone, opened = opened, ring = cast[u64](ring), periods = periods}
}

/**
 * Write a stream's next period of its tone into a place in its ring, encoded in its format, and give it.
 *
 * @return Whether it was given.
 */
give_next :: fn(playing : ptr[mut Playing], port : slop_os.Port, period : u32) -> bool {
    channels :: cast[usize](playing.format.channels)
    frames :: cast[usize](playing.opened.period_frames)
    samples : f32[MOST_SAMPLES]
    count :: if frames * channels < samples.count { frames * channels } else { samples.count }
    for i in 0..<count {
        at :: playing.frame + cast[u64](i / channels)
        if i < samples.count {
            samples[i] = cast[f32](LEVEL * math.sin(2.0 * math.PI * playing.tone * cast[f64](at) / cast[f64](playing.format.rate)))
        }
    }
    playing.frame += cast[u64](frames)
    bytes :: view_of(
        cast[ptr[mut u8]](playing.ring + cast[u64](period) * cast[u64](playing.opened.period_bytes)),
        cast[usize](playing.opened.period_bytes)
    )
    _ = pcm.encode(samples[0..<samples.count], cast[pcm.SampleFormat](playing.format.sample), bytes)
    out := os.Outgoing.{}
    os.begin[sound.Request](&out)^ = .Play(period)
    if sound.send_request(playing.end, port, &out) is_some {
        return false
    }
    playing.given += 1
    return true
}

/**
 * Take a stream's answers that have come: each period played given again with the tone's next, until a second's given.
 *
 * @return False if its connection failed or a period was refused.
 */
take_answers :: fn(playing : ptr[mut Playing], port : slop_os.Port) -> bool {
    into := os.Incoming.{}
    loop {
        match sound.receive_response(playing.end, port, &into, false) {
            case Received => {}
            case Empty => return true
            case _ => return false
        }
        match os.message_of[sound.Response](&into)^ {
            case Played(done) => {
                playing.played += 1
                playing.underruns = done.underruns
                if playing.given < playing.periods && !give_next(playing, port, done.period) {
                    return false
                }
            }
            case PlayRefused(refused) => {
                runtime.log_info("period % refused: %", refused.period, refused.why)
                return false
            }
            case _ => return false
        }
    }
}

/**
 * Send a microphone request and wait for its answer.
 *
 * @return Whether it came, in into.
 */
ask_microphone :: fn(end : slop_os.Channel, port : slop_os.Port, out : ptr[mut os.Outgoing], into : ptr[mut os.Incoming]) -> bool {
    if microphone.send_request(end, port, out) is_some {
        return false
    }
    return match microphone.receive_response(end, port, into, true) {
        case Received => true
        case _ => false
    }
}

/**
 * Record a second through a microphone grant, then take it back.
 *
 * @param control A microphone connection to the audio service.
 * @return 0 once it's recorded and taken back; 5 if the grant, 6 if the stream, 7 if recording, 8 if taking it back
 *     failed, or the grant's connection outlived it.
 */
record :: fn(control : os.Channel[microphone.Microphone]) -> int {
    startup :: slop_os.startup_block()
    control_port :: os.port_for(startup.budget, control.end) or_return 5
    into := os.Incoming.{}
    asking := os.Outgoing.{}
    os.begin[microphone.Request](&asking)^ = .Grant
    if !ask_microphone(control.end, control_port, &asking, &into) {
        return 5
    }
    granted :: match os.message_of[microphone.Response](&into)^ {
        case Granted(made) => made
        case _ => return 5
    }
    watching := os.Outgoing.{}
    os.begin[microphone.Request](&watching)^ = .WaitReleased(granted.id)
    if microphone.send_request(control.end, control_port, &watching) is_some {
        return 5
    }
    end :: granted.end.end
    port :: os.port_for(startup.budget, end) or_return 6
    format :: sound.Format.{sample = 1, rate = 16000, channels = 1}
    out := os.Outgoing.{}
    os.begin[sound.Request](&out)^ = .Play(0)
    // Its connection records: Play is refused, before it's even open
    if !call(end, port, &out, &into) {
        return 6
    }
    match os.message_of[sound.Response](&into)^ {
        case PlayRefused(refused) => if refused.why != .NotAllowed {
            return 6
        }
        case _ => return 6
    }
    os.begin[sound.Request](&out)^ = .Open(format)
    if !call(end, port, &out, &into) {
        return 6
    }
    opened :: match os.message_of[sound.Response](&into)^ {
        case Opened(layout) => layout
        case _ => return 6
    }
    os.begin[sound.Request](&out)^ = .GetBuffer
    if !call(end, port, &out, &into) {
        return 6
    }
    window :: match os.message_of[sound.Response](&into)^ {
        case Buffer(memory) => memory
        case _ => return 6
    }
    bytes :: (cast[u64](opened.periods) * cast[u64](opened.period_bytes) + 4095) / 4096 * 4096
    ring :: runtime.reserve_addresses(cast[usize](bytes)) or_return 6
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    if slop_os.memory_map(window, startup.space, cast[u64](ring), 0, bytes, read_write) is_error {
        return 6
    }
    for period in 0..<opened.periods {
        os.begin[sound.Request](&out)^ = .Record(period)
        if sound.send_request(end, port, &out) is_some {
            return 7
        }
    }
    wanted :: (format.rate + opened.period_frames - 1) / opened.period_frames
    recorded := cast[u32](0)
    overruns := cast[u32](0)
    loudest := cast[f32](0.0)
    samples : f32[MOST_SAMPLES]
    loop {
        if recorded >= wanted {
            break
        }
        match sound.receive_response(end, port, &into, true) {
            case Received => {}
            case _ => return 7
        }
        done :: match os.message_of[sound.Response](&into)^ {
            case Recorded(filled) => filled
            case PlayRefused(refused) => {
                runtime.log_info("record: period % refused: %", refused.period, refused.why)
                return 7
            }
            case _ => return 7
        }
        recorded += 1
        overruns = done.overruns
        heard :: view_of(
            cast[ptr[u8]](cast[u64](ring) + cast[u64](done.period) * cast[u64](opened.period_bytes)),
            cast[usize](opened.period_bytes)
        )
        count :: pcm.decode(pcm.SampleFormat.S16, heard, samples[0..<samples.count])
        for sample, i in samples {
            if i < count {
                size :: if sample < 0.0 { -sample } else { sample }
                loudest = if size > loudest { size } else { loudest }
            }
        }
        if recorded + opened.periods <= wanted {
            os.begin[sound.Request](&out)^ = .Record(done.period)
            if sound.send_request(end, port, &out) is_some {
                return 7
            }
        }
    }
    runtime.log_info(
        "recorded % periods of 16 kHz mono 16-bit integers, the loudest sample % thousandths, % overruns",
        recorded,
        cast[u32](loudest * 1000.0),
        overruns
    )
    taking := os.Outgoing.{}
    os.begin[microphone.Request](&taking)^ = .Revoke(granted.id)
    if microphone.send_request(control.end, control_port, &taking) is_some {
        return 8
    }
    heard_released := false
    loop {
        match microphone.receive_response(control.end, control_port, &into, true) {
            case Received => {}
            case _ => return 8
        }
        match os.message_of[microphone.Response](&into)^ {
            case Released(id) => heard_released = id == granted.id
            case Revoked => break
            case _ => return 8
        }
    }
    // The grant's connection is gone: its peer's closed
    os.begin[sound.Request](&out)^ = .Stop
    gone :: !call(end, port, &out, &into)
    if !heard_released || !gone {
        return 8
    }
    runtime.log_info("took back grant %: released, and its connection gone", granted.id)
    return 0
}

/**
 * Play the two streams through the audio service, a second each, or three with test_sound_load on the command line;
 * or with test_sound_record, record a second through a microphone grant instead.
 *
 * @param log The debug log it says what it played in.
 * @param sound_service A connector to the audio service.
 * @param command_line The kernel's command line, for test_sound_load.
 * @param microphones A microphone connection to the audio service, given only with test_sound_record on it.
 * @return 0 once both have played, or it's recorded; 2 without the service, 3 if a stream couldn't be opened, 4 if one
 *     failed; record's codes.
 */
main :: fn(
    log : slop_os.DebugLog?,
    sound_service : os.Channel[connector.Connector]?,
    command_line : slop_os.Memory?,
    microphones : os.Channel[microphone.Microphone]?
) -> int {
    startup :: slop_os.startup_block()
    match microphones {
        case Some(control) => return record(control)
        case None => {}
    }
    dialing :: sound_service or_return 2
    loaded := false
    match command_line {
        case Some(memory) => loaded = service_kit.has_word(service_kit.text_of(startup, memory) or_else "", "test_sound_load")
        case None => {}
    }
    seconds :: if loaded { cast[u32](3) } else { cast[u32](1) }
    first := open(dialing.end, sound.Format.{sample = 4, rate = 48000, channels = 2}, 1000.0, seconds) or_return 3
    second := open(dialing.end, sound.Format.{sample = 1, rate = 44100, channels = 1}, 1500.0, seconds) or_return 3
    port :: slop_os.port_create(startup.budget) or_return 2
    signals :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    slop_os.port_bind(port, cast[slop_os.Handle](first.end), signals, 1, .Persistent) or_return 2
    slop_os.port_bind(port, cast[slop_os.Handle](second.end), signals, 2, .Persistent) or_return 2
    for period in 0..<sound.PERIODS {
        if !give_next(&first, port, period) || !give_next(&second, port, period) {
            return 4
        }
    }
    loop {
        if first.played >= first.periods && second.played >= second.periods {
            break
        }
        if !take_answers(&first, port) || !take_answers(&second, port) {
            return 4
        }
        // Done once the last answers are taken, not waiting for more
        if first.played >= first.periods && second.played >= second.periods {
            break
        }
        packets : slop_os.Packet[4]
        _ = slop_os.port_wait(port, packets, slop_os.NO_DEADLINE)
    }
    runtime.log_info(
        "played % s of 1 kHz at 48 kHz stereo floats and of 1.5 kHz at 44.1 kHz mono 16-bit integers, % and % underruns",
        seconds,
        first.underruns,
        second.underruns
    )
    return 0
}
