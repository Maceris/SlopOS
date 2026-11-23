/**
 * test_sound (decisions/0196, 17c): a client of the sound device's driver, which plays a second of a 1 kHz tone at
 * half of full scale through it, every period of the ring kept given, and says what it played. Started by the
 * supervisor with test_sound on the kernel's command line; boot.py's --audio-wav reads what QEMU played.
 */
package test_sound

import runtime from "base:runtime"
import os from "std:os"
import slop_os from "std:os/slop_os"
import math from "std:math"
import audio from "../../protocols/audio"
import connector from "../../protocols/connector"

/** How many periods it plays: a second of them. */
PERIODS_PLAYED : u32 : audio.RATE / audio.PERIOD_FRAMES
/** The tone's frequency. */
TONE : f64 : 1000.0
/** Its level: half of full scale. */
LEVEL : f64 : 0.5

/**
 * Write the next period of the tone into its place in the ring.
 *
 * @param ring Where the ring is mapped.
 * @param period The period's index in the ring.
 * @param frame The tone's frame the period starts at.
 */
write_period :: fn(ring : u64, period : u32, frame : u64) {
    samples :: view_of(
        cast[ptr[mut f32]](ring + cast[u64](period) * cast[u64](audio.PERIOD_BYTES)),
        cast[usize](audio.PERIOD_FRAMES * audio.CHANNELS)
    )
    for &sample, i in samples {
        at :: frame + cast[u64](i) / cast[u64](audio.CHANNELS)
        sample^ = cast[f32](LEVEL * math.sin(2.0 * math.PI * TONE * cast[f64](at) / cast[f64](audio.RATE)))
    }
}

/**
 * Give a period: the request sent, its answer to come.
 *
 * @return Whether it was sent.
 */
offer_period :: fn(end : slop_os.Channel, port : slop_os.Port, period : u32) -> bool {
    out := os.Outgoing.{}
    request :: os.begin[audio.Request](&out)
    request^ = .Play(period)
    return audio.send_request(end, port, &out) is_none
}

/**
 * Play a second of the tone through the sound device's driver.
 *
 * @param log The debug log it says what it played in.
 * @param sound A connector to the sound device's driver.
 * @return 0 once it's played; 2 without a connector or a driver, 3 if the ring couldn't be had, 4 if a period was
 *     refused or the driver's connection failed.
 */
main :: fn(log : slop_os.DebugLog?, sound : os.Channel[connector.Connector]?) -> int {
    startup :: slop_os.startup_block()
    dialing :: sound or_return 2
    port :: slop_os.port_create(startup.budget) or_return 2
    dial_port :: os.port_for(startup.budget, dialing.end) or_return 2
    driver :: connector.dial[audio.Audio](dialing.end, dial_port) or_return 2
    end :: driver.end
    slop_os.port_bind(port, cast[slop_os.Handle](end), cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE)
        | cast[u32](slop_os.SIGNAL_PEER_CLOSED)), 1, .Persistent) or_return 2
    into := os.Incoming.{}

    // What the device is, and the ring
    out := os.Outgoing.{}
    os.begin[audio.Request](&out)^ = .Describe
    if audio.send_request(end, port, &out) is_some {
        return 2
    }
    format := cast[u8](0)
    match audio.receive_response(end, port, &into, true) {
        case Received => match os.message_of[audio.Response](&into)^ {
            case Described(info) => format = info.device_format
            case _ => return 2
        }
        case _ => return 2
    }
    asking := os.Outgoing.{}
    os.begin[audio.Request](&asking)^ = .GetBuffer
    if audio.send_request(end, port, &asking) is_some {
        return 3
    }
    window := cast[slop_os.Memory](slop_os.NO_HANDLE)
    match audio.receive_response(end, port, &into, true) {
        case Received => match os.message_of[audio.Response](&into)^ {
            case Buffer(memory) => window = memory
            case _ => {
                runtime.log_info("the driver gave no buffer")
                return 3
            }
        }
        case _ => return 3
    }
    ring :: cast[u64](runtime.reserve_addresses(cast[usize](audio.BUFFER_BYTES)) or_return 3)
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    match slop_os.memory_map(window, startup.space, ring, 0, audio.BUFFER_BYTES, read_write) {
        case Ok => {}
        case Error(error) => {
            runtime.log_info("the ring's window didn't map: %", error)
            return 3
        }
    }

    // Every period given, each given again with the tone's next once it's played
    given := cast[u32](0)
    played := cast[u32](0)
    underruns := cast[u32](0)
    latency := cast[u32](0)
    frame := cast[u64](0)
    for period in 0..<audio.PERIODS {
        write_period(ring, period, frame)
        frame += cast[u64](audio.PERIOD_FRAMES)
        if !offer_period(end, port, period) {
            return 4
        }
        given += 1
    }
    loop {
        if played >= PERIODS_PLAYED {
            break
        }
        match audio.receive_response(end, port, &into, true) {
            case Received => {}
            case _ => return 4
        }
        match os.message_of[audio.Response](&into)^ {
            case Played(done) => {
                played += 1
                underruns = done.underruns
                latency = if done.latency_frames > latency { done.latency_frames } else { latency }
                if given < PERIODS_PLAYED {
                    write_period(ring, done.period, frame)
                    frame += cast[u64](audio.PERIOD_FRAMES)
                    if !offer_period(end, port, done.period) {
                        return 4
                    }
                    given += 1
                }
            }
            case Refused(refused) => {
                runtime.log_info("period % refused: %", refused.period, refused.why)
                return 4
            }
            case _ => return 4
        }
    }
    runtime.log_info(
        "played % periods of a 1 kHz tone, the device's format %, % underruns, at most % frames behind",
        played,
        format,
        underruns,
        latency
    )
    stopping := os.Outgoing.{}
    os.begin[audio.Request](&stopping)^ = .Stop
    _ = audio.send_request(end, port, &stopping)
    _ = audio.receive_response(end, port, &into, true)
    return 0
}
