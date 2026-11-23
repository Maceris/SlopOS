/**
 * play (decisions/0196, 17g): play a WAV file beneath the shell's directory through the session's sound, at the
 * session's volume: 16, 24 or 32-bit integers or 32-bit floats, 1 to 8 channels, 8 to 192 kHz, which the audio service
 * converts to the device's. It ends once it's all been played.
 *
 *     play note.wav
 */
package play

import runtime from "base:runtime"
import os from "std:os"
import slop_os from "std:os/slop_os"
import dir from "std:os/slop_os/dir"
import audio as pcm from "std:audio"
import sound as sound_protocol from "../../protocols/sound"

/** What was played. */
Played :: struct {
    /** The file, as given, beneath the shell's directory. */
    file : string,
    /** How long it is, in milliseconds. */
    milliseconds : u64,
    /** How many of the audio service's periods it ran out for, played as silence, as it couldn't keep up. */
    underruns : u32,
}

/** A parameter that's wrong. */
Problem :: struct {
    parameter : os.ParameterName,
}

/** Why it couldn't play. */
PlayError :: union {
    /** The file couldn't be read. */
    Unreadable(Problem),
    /** The file isn't a WAV file of a format it plays. */
    NotWav(Problem),
    /** The audio service refused it, as without a sound device, or its connection failed. */
    Failed,
}

/** The stream being played: its connection and port, its ring's layout, and where the ring's mapped. */
Stream :: struct {
    end : slop_os.Channel,
    port : slop_os.Port,
    opened : sound_protocol.Opened,
    ring : u64,
}

/**
 * Play a WAV file.
 *
 * @param file The file, beneath here.
 * @param here The shell's directory, given without asking.
 * @param sound A sound connection of the session's, given without asking.
 * @return What was played: the file, how long, and how often the service ran out of it.
 * @error Unreadable The file couldn't be read.
 * @error NotWav The file isn't a WAV file, or is one of a format it doesn't play.
 * @error Failed The audio service refused the stream, as without a sound device, or its connection failed.
 */
main :: fn(file : string, here : os.Channel[dir.Dir], sound : os.Channel[sound_protocol.Sound]) -> Result[Played, PlayError] {
    problem :: Problem.{parameter = os.ParameterName.{name = "file"}}
    directory, opened :: os.directory_on(here.end)
    if opened != null {
        return .Error(.Unreadable(problem))
    }
    text :: match os.read_entire_file_in(directory, file) {
        case Ok(read) => read
        case Error(error) => return .Error(.Unreadable(problem))
    }
    wav :: match pcm.read_wav(string_bytes(text)) {
        case Ok(read) => read
        case Error(error) => return .Error(.NotWav(problem))
    }
    format :: sound_protocol.Format.{sample = cast[u8](wav.format.sample), rate = wav.format.rate, channels = wav.format.channels}
    if format.rate < sound_protocol.MIN_RATE || format.rate > sound_protocol.MAX_RATE || format.channels > sound_protocol.MAX_CHANNELS {
        return .Error(.NotWav(problem))
    }
    stream := open(sound.end, format) or_return .Error(.Failed)
    underruns :: play_all(&stream, wav.data) or_return .Error(.Failed)
    milliseconds :: cast[u64](wav.frames) * 1000 / cast[u64](format.rate)
    return .Ok(Played.{file = file, milliseconds = milliseconds, underruns = underruns})
}

/**
 * Send a request on the stream's connection and wait for its answer.
 *
 * @return Whether it came, in into.
 */
call :: fn(end : slop_os.Channel, port : slop_os.Port, out : ptr[mut os.Outgoing], into : ptr[mut os.Incoming]) -> bool {
    if sound_protocol.send_request(end, port, out) is_some {
        return false
    }
    return match sound_protocol.receive_response(end, port, into, true) {
        case Received => true
        case _ => false
    }
}

/**
 * Open the stream in a format and map its ring.
 *
 * @param end The sound connection, which the stream keeps.
 * @param format The file's format.
 * @return The stream; null if the port, the Open or the ring failed.
 */
open :: fn(end : slop_os.Channel, format : sound_protocol.Format) -> Stream? {
    startup :: slop_os.startup_block()
    port :: os.port_for(startup.budget, end) or_return null
    into := os.Incoming.{}
    out := os.Outgoing.{}
    os.begin[sound_protocol.Request](&out)^ = .Open(format)
    if !call(end, port, &out, &into) {
        return null
    }
    opened :: match os.message_of[sound_protocol.Response](&into)^ {
        case Opened(layout) => layout
        case _ => return null
    }
    os.begin[sound_protocol.Request](&out)^ = .GetBuffer
    if !call(end, port, &out, &into) {
        return null
    }
    window :: match os.message_of[sound_protocol.Response](&into)^ {
        case Buffer(memory) => memory
        case _ => return null
    }
    bytes :: (cast[u64](opened.periods) * cast[u64](opened.period_bytes) + 4095) / 4096 * 4096
    ring :: runtime.reserve_addresses(cast[usize](bytes)) or_return null
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    if slop_os.memory_map(window, startup.space, cast[u64](ring), 0, bytes, read_write) is_error {
        return null
    }
    return Stream.{end = end, port = port, opened = opened, ring = cast[u64](ring)}
}

/**
 * Play every frame, every period of the ring kept given, the last padded with silence, and wait for the last to be
 * played.
 *
 * @param stream The stream.
 * @param data The frames, as its format stores them.
 * @return How many periods the service ran out for; null if a period was refused, or the connection failed.
 */
play_all :: fn(stream : ptr[mut Stream], data : u8[]) -> u32? {
    period_bytes :: cast[usize](stream.opened.period_bytes)
    if period_bytes == 0 {
        return null
    }
    periods :: (data.count + period_bytes - 1) / period_bytes
    given := cast[usize](0)
    played := cast[usize](0)
    underruns := cast[u32](0)
    for period in 0..<stream.opened.periods {
        if given >= periods {
            break
        }
        if !give_period(stream, period, data, given) {
            return null
        }
        given += 1
    }
    into := os.Incoming.{}
    loop {
        if played >= given {
            break
        }
        match sound_protocol.receive_response(stream.end, stream.port, &into, true) {
            case Received => {}
            case _ => return null
        }
        done :: match os.message_of[sound_protocol.Response](&into)^ {
            case Played(answer) => answer
            case _ => return null
        }
        played += 1
        underruns = done.underruns
        if given < periods {
            if !give_period(stream, done.period, data, given) {
                return null
            }
            given += 1
        }
    }
    return underruns
}

/**
 * Copy one period of the frames into a place in the ring, padded with silence past their end, and give it.
 *
 * @param stream The stream.
 * @param period The place in the ring.
 * @param data The frames.
 * @param which Which period of them.
 * @return Whether it was given.
 */
give_period :: fn(stream : ptr[mut Stream], period : u32, data : u8[], which : usize) -> bool {
    period_bytes :: cast[usize](stream.opened.period_bytes)
    into :: view_of(cast[ptr[mut u8]](stream.ring + cast[u64](period) * cast[u64](period_bytes)), period_bytes)
    start :: which * period_bytes
    for &byte, i in into {
        at :: start + i
        byte^ = if at < data.count { data[at] } else { 0 }
    }
    out := os.Outgoing.{}
    os.begin[sound_protocol.Request](&out)^ = .Play(period)
    return sound_protocol.send_request(stream.end, stream.port, &out) is_none
}
