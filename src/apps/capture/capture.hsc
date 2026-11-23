/**
 * capture (decisions/0196, 17f): record from the microphone into a WAV file beneath the shell's directory, at 16 kHz mono
 * 16-bit integers, for some seconds, or until the user takes the microphone back on the trusted path, when what was
 * recorded so far is kept. It asks the session's powerbox for the microphone, which the user allows, or doesn't, there;
 * while it holds it, the trusted path says so. (The shell's own record runs a program with its calls kept for replay.)
 *
 *     capture 5 note.wav
 */
package capture

import runtime from "base:runtime"
import os from "std:os"
import slop_os from "std:os/slop_os"
import dir from "std:os/slop_os/dir"
import audio as pcm from "std:audio"
import powerbox as powerbox_protocol from "../../protocols/powerbox"
import sound from "../../protocols/sound"

/** The rate recorded at, in frames a second. */
RATE : u32 : 16000
/** The most seconds a recording has: a minute, about 1.9 MB of samples. */
MOST_SECONDS : u32 : 60
/** How the samples are stored: 16-bit integers, one channel. */
FORMAT :: sound.Format.{sample = 1, rate = RATE, channels = 1}

/** What was recorded. */
Recorded :: struct {
    /** The file it's in, as given, beneath the shell's directory. */
    file : string,
    /** How long it is, in milliseconds. */
    milliseconds : u64,
    /** Whether the user took the microphone back before the seconds asked for were recorded. */
    taken_back : bool,
    /** How many of the device's periods were dropped, capture having none given to fill. */
    overruns : u32,
}

/** A parameter that's wrong. */
Problem :: struct {
    parameter : os.ParameterName,
}

/** Why it couldn't record. */
RecordError :: union {
    /** The seconds aren't 1 to MOST_SECONDS. */
    BadSeconds(Problem),
    /** The user didn't allow the microphone, or there was no powerbox to ask. */
    NotAllowed,
    /** The audio service refused, as with no sound device or nothing to record from, or its connection failed. */
    Failed,
    /** There wasn't the memory for the recording. */
    NoMemory,
    /** The file couldn't be written. */
    Unwritable(Problem),
}

/** The microphone's stream, open: its connection and port, its ring's layout, and where the ring's mapped. */
Stream :: struct {
    end : slop_os.Channel,
    port : slop_os.Port,
    opened : sound.Opened,
    ring : u64,
}

/**
 * Record from the microphone into a WAV file.
 *
 * @param seconds How long to record, 1 to MOST_SECONDS.
 * @param file The file to record into, beneath here, made or written over.
 * @param here The shell's directory, given without asking.
 * @param powerbox The session's powerbox, asked for the microphone; without it, that's NotAllowed.
 * @return What was recorded: the file, how long, and whether the user took the microphone back first.
 * @error BadSeconds The seconds aren't 1 to MOST_SECONDS.
 * @error NotAllowed The user didn't allow the microphone, or there's no powerbox.
 * @error Failed The audio service refused, or the stream failed before anything was recorded.
 * @error NoMemory There wasn't the memory for the recording.
 * @error Unwritable The file couldn't be written.
 */
main :: fn(
    seconds : u32,
    file : string,
    here : os.Channel[dir.Dir],
    powerbox : os.Channel[powerbox_protocol.Powerbox]?
) -> Result[Recorded, RecordError] {
    if seconds == 0 || seconds > MOST_SECONDS {
        return .Error(.BadSeconds(Problem.{parameter = os.ParameterName.{name = "seconds"}}))
    }
    unwritable :: RecordError.Unwritable(Problem.{parameter = os.ParameterName.{name = "file"}})
    directory, opened :: os.directory_on(here.end)
    if opened != null {
        return .Error(unwritable)
    }
    format :: pcm.Format.{sample = .S16, rate = RATE, channels = 1}
    frames :: cast[usize](RATE) * cast[usize](seconds)
    samples, failed :: runtime.new_array(u8, frames * pcm.frame_bytes(format))
    if failed != null {
        return .Error(.NoMemory)
    }
    defer runtime.free_array(samples)
    granted :: ask(powerbox, seconds) or_return .Error(.NotAllowed)
    stream := open(granted) or_return .Error(.Failed)
    taken_back := false
    overruns := cast[u32](0)
    kept :: record_into(&stream, samples, &taken_back, &overruns)
    _ = slop_os.handle_close(cast[slop_os.Handle](stream.end))
    if kept == 0 && taken_back {
        return .Error(.Failed)
    }
    bytes_count :: pcm.wav_bytes(format, kept / pcm.frame_bytes(format)) or_return .Error(.NoMemory)
    wav, made :: runtime.new_array(u8, bytes_count)
    if made != null {
        return .Error(.NoMemory)
    }
    defer runtime.free_array(wav)
    if kept > samples.count || wav.count == 0 {
        return .Error(.NoMemory)
    }
    written :: pcm.write_wav(format, samples[0..<kept], wav) or_return .Error(unwritable)
    if written == 0 || written > wav.count || os.write_entire_file_in(directory, file, string_of(&wav[0], written)) is_some {
        return .Error(unwritable)
    }
    milliseconds :: cast[u64](kept / pcm.frame_bytes(format)) * 1000 / cast[u64](RATE)
    runtime.log_info("recorded % ms into %; the microphone % taken back", milliseconds, file, if taken_back { "was" } else { "wasn't" })
    return .Ok(Recorded.{file = file, milliseconds = milliseconds, taken_back = taken_back, overruns = overruns})
}

/**
 * Ask the powerbox for the microphone, and wait for the user's answer.
 *
 * @param powerbox The session's powerbox, if there is one.
 * @param seconds How long it's to record, said to the user.
 * @return The grant's sound connection; null if the user didn't allow it, or there's no powerbox.
 */
ask :: fn(powerbox : os.Channel[powerbox_protocol.Powerbox]?, seconds : u32) -> os.Channel[sound.Sound]? {
    box :: powerbox or_return null
    port :: os.port_for(slop_os.startup_block().budget, box.end) or_return null
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    out := os.Outgoing.{}
    request :: os.begin[powerbox_protocol.Request](&out)
    request^ = .RequestMicrophone(os.append(&out, string_bytes("to record into a file")))
    if powerbox_protocol.send_request(box.end, port, &out) is_some {
        return null
    }
    into := os.Incoming.{}
    match powerbox_protocol.receive_response(box.end, port, &into, true) {
        case Received => {}
        case _ => return null
    }
    return match os.message_of[powerbox_protocol.Response](&into)^ {
        case MicrophoneGranted(given) => given
        case _ => null
    }
}

/**
 * Send a request on the microphone's connection and wait for its answer.
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
 * Open the microphone's stream in FORMAT and map its ring.
 *
 * @param granted The grant's sound connection, which the stream keeps.
 * @return The stream; null if the Open or the ring failed, the connection closed.
 */
open :: fn(granted : os.Channel[sound.Sound]) -> Stream? {
    startup :: slop_os.startup_block()
    end :: granted.end
    port :: os.port_for(startup.budget, end) or_else cast[slop_os.Port](slop_os.NO_HANDLE)
    if cast[slop_os.Handle](port) == slop_os.NO_HANDLE {
        _ = slop_os.handle_close(cast[slop_os.Handle](end))
        return null
    }
    stream :: open_on(end, port)
    if stream is_none {
        _ = slop_os.handle_close(cast[slop_os.Handle](port))
        _ = slop_os.handle_close(cast[slop_os.Handle](end))
    }
    return stream
}

/**
 * Open the stream on a connection, as open says.
 *
 * @param end The connection.
 * @param port A port bound to it.
 * @return The stream; null if the Open or the ring failed.
 */
open_on :: fn(end : slop_os.Channel, port : slop_os.Port) -> Stream? {
    startup :: slop_os.startup_block()
    into := os.Incoming.{}
    out := os.Outgoing.{}
    os.begin[sound.Request](&out)^ = .Open(FORMAT)
    if !call(end, port, &out, &into) {
        return null
    }
    opened :: match os.message_of[sound.Response](&into)^ {
        case Opened(layout) => layout
        case _ => return null
    }
    os.begin[sound.Request](&out)^ = .GetBuffer
    if !call(end, port, &out, &into) {
        return null
    }
    window :: match os.message_of[sound.Response](&into)^ {
        case Buffer(memory) => memory
        case _ => return null
    }
    bytes :: (cast[u64](opened.periods) * cast[u64](opened.period_bytes) + 4095) / 4096 * 4096
    ring :: runtime.reserve_addresses(cast[usize](bytes)) or_return null
    // A recording stream's ring is the client's to read only
    if slop_os.memory_map(window, startup.space, cast[u64](ring), 0, bytes, slop_os.PROTECTION_READ) is_error {
        return null
    }
    return Stream.{end = end, port = port, opened = opened, ring = cast[u64](ring)}
}

/**
 * Record into samples until they're full, or the microphone's taken back, every period of the ring kept given.
 *
 * @param stream The microphone's stream.
 * @param samples Where what's heard goes, as FORMAT stores it.
 * @param taken_back Set if the microphone was taken back, or its connection failed, before samples were full.
 * @param overruns Set to the periods the service dropped, with none given to fill.
 * @return How many bytes of samples were recorded.
 */
record_into :: fn(stream : ptr[mut Stream], samples : mut u8[], taken_back : ptr[mut bool], overruns : ptr[mut u32]) -> usize {
    out := os.Outgoing.{}
    into := os.Incoming.{}
    for period in 0..<stream.opened.periods {
        os.begin[sound.Request](&out)^ = .Record(period)
        if sound.send_request(stream.end, stream.port, &out) is_some {
            taken_back^ = true
            return 0
        }
    }
    kept := cast[usize](0)
    period_bytes :: cast[usize](stream.opened.period_bytes)
    loop {
        if kept >= samples.count {
            break
        }
        match sound.receive_response(stream.end, stream.port, &into, true) {
            case Received => {}
            case _ => {
                // Taken back: the service closed its end
                taken_back^ = true
                break
            }
        }
        done :: match os.message_of[sound.Response](&into)^ {
            case Recorded(filled) => filled
            case _ => {
                taken_back^ = true
                break
            }
        }
        overruns^ = done.overruns
        from :: cast[u64](done.period) * cast[u64](stream.opened.period_bytes)
        heard :: view_of(cast[ptr[u8]](stream.ring + from), period_bytes)
        for byte in heard {
            if kept >= samples.count {
                break
            }
            samples[kept] = byte
            kept += 1
        }
        os.begin[sound.Request](&out)^ = .Record(done.period)
        _ = sound.send_request(stream.end, stream.port, &out)
    }
    return kept
}
