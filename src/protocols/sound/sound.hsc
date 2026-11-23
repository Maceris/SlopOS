package sound

import os from "std:os"
import slop_os from "std:os/slop_os"

/*
 * What programs play through the audio service (decisions/0196, 17d): each connection one stream, in a format of its
 * own (Open): a rate, 1 to MAX_CHANNELS channels, and how its samples are stored, as std/audio's SampleFormat. Its frames
 * go through a ring of PERIODS periods, each period_frames(rate) frames, about 5 ms, in memory the client reaches
 * through a window (GetBuffer). The client fills a period and gives it with Play, answered with Played once the
 * service has mixed it in, when it's the client's again; answers come in the order periods were given.
 *
 * The service mixes every stream's frames, converted, resampled and remixed to the device's, each scaled by its
 * volume, and plays them. A stream that runs out is played as silence, its own underrun, never another's.
 */

/**
 * The sound protocol, for the channels between the audio service and the programs that play through it, and its
 * listener: the programs send the requests, and the service answers them.
 */
Sound :: struct {}

/**
 * What the protocol says of itself: its name, which its channels' tag is made from, its major version, and that the
 * client's budget is lent for each of its connections.
 */
PROTOCOL :: slop_os.Protocol.{name = "sound", major_version = 1, lending = .PerConnection}

/** How many periods a stream's ring has. */
PERIODS : u32 : 8
/** The most channels a stream has. */
MAX_CHANNELS : u32 : 8
/** The lowest rate a stream has, in frames a second. */
MIN_RATE : u32 : 8000
/** The highest. */
MAX_RATE : u32 : 192000
/** The most bytes a stream's ring takes: PERIODS periods at the highest rate, channels and sample size, in pages. */
MAX_BUFFER_BYTES : u64 : (cast[u64](PERIODS) * ((cast[u64](MAX_RATE) + 199) / 200) * cast[u64](MAX_CHANNELS) * 4 + 4095) / 4096 * 4096
/** The bytes of a connection's channel's ring: every period given and answered at once fits. */
RING_BYTES : u32 : 4096
/** Full volume, as SetVolume takes it: a gain of 1. */
FULL_VOLUME : u16 : 1000

/** A stream's format. */
Format :: struct {
    /** How its samples are stored, as std/audio's SampleFormat: 1 16-bit, 2 24-bit, 3 32-bit integers, 4 floats. */
    sample : u8,
    /** Its frames a second, MIN_RATE to MAX_RATE. */
    rate : u32,
    /** Its channels, 1 to MAX_CHANNELS, interleaved in each frame. */
    channels : u32,
}

/** Open's answer: how the stream's ring is laid out. */
Opened :: struct {
    /** The frames of each period. */
    period_frames : u32,
    /** The bytes of each period, the periods one after another from the ring's start. */
    period_bytes : u32,
    /** How many periods. */
    periods : u32,
}

/** Why a request was refused. */
Refused :: enum #backed_by(u8) {
    /** Open's format isn't one: a rate, channel count or sample size outside what's taken. */
    BadFormat = 1,
    /** The stream isn't open yet: Open first. */
    NotOpen = 2,
    /** The stream has no buffer yet: GetBuffer first. */
    NoBuffer = 3,
    /** A period past PERIODS, or one given and not yet answered. */
    BadPeriod = 4,
    /** It was given, then Stop dropped it. */
    Dropped = 5,
    /** The service has no sound device. */
    NoDevice = 6,
    /** No memory for the stream. */
    NoMemory = 7,
}

/** A period mixed in: which, and how often the stream had run out by then. */
Played :: struct {
    /** The period's index in the ring. */
    period : u32,
    /** How many periods the stream was played as silence for, having run out, since it opened. */
    underruns : u32,
}

/** A Play refused: its period, and why. */
PlayRefused :: struct {
    /** The period's index, as given. */
    period : u32,
    /** Why. */
    why : Refused,
}

/** What the audio service is asked. */
Request :: union {
    /** Open the connection's stream in a format. Answered with Opened, or Refused; a second Open is refused. */
    Open(Format),
    /** Make the stream's ring and give a window onto it. Answered with Buffer, or Refused. */
    GetBuffer,
    /** Give a period, its frames written. Answered with Played once it's mixed in, or with PlayRefused. */
    Play(u32),
    /** Set the stream's volume, 0 silent to FULL_VOLUME as it is. Answered with VolumeSet. */
    SetVolume(u16),
    /** Drop the periods given and not yet mixed in, each answered PlayRefused(Dropped) first. Answered with Stopped. */
    Stop,
    /**
     * Have the service serve another client, on the end given, which moves to the service. Sent on the listener, and
     * answered with nothing.
     */
    Connect(os.Channel[Sound]),
}

/** What the audio service answers. */
Response :: union {
    /** Open's answer. */
    Opened(Opened),
    /** GetBuffer's answer: a window onto the stream's ring, which moves to the client. */
    Buffer(slop_os.Memory),
    /** Play's answer once the period's mixed in. */
    Played(Played),
    /** Play's answer when it's refused. */
    PlayRefused(PlayRefused),
    /** Open's or GetBuffer's answer when they're refused. */
    Refused(Refused),
    /** SetVolume's answer. */
    VolumeSet,
    /** Stop's answer. */
    Stopped,
    /** The answer to a request the service doesn't know, as from a newer client; every protocol has it. */
    Unsupported,
}

/**
 * How many frames each period of a stream of a rate has: 5 ms of them, rounded up.
 *
 * @param rate The stream's rate.
 * @return Its period's frames.
 */
period_frames :: fn(rate : u32) -> u32 {
    return (rate + 199) / 200
}

/**
 * Tell whether a request may be sent again, after a reconnect, without doing more than sending it once did.
 *
 * @param request The request, which isn't changed.
 * @return False for Play, whose period would be mixed in twice, and Open; true for the rest.
 */
is_idempotent :: fn(request : ptr[Request]) -> bool {
    return match request^ {
        case Open(_) => false
        case GetBuffer => true
        case Play(_) => false
        case SetVolume(_) => true
        case Stop => true
        case Connect(_) => true
    }
}

#insert os.protocol_code(Request, Response)

/**
 * Make a new connection to the audio service: a channel for the protocol, one end sent to it in a Connect.
 *
 * @param end The service's listener, or any connection to it, kept by the caller.
 * @param port A port bound to end, waited on while end's ring is full.
 * @param budget The memory budget that pays for the new channel.
 * @return The caller's end of the new connection; null if it couldn't be made, both ends closed.
 */
connect :: fn(end : slop_os.Channel, port : slop_os.Port, budget : slop_os.MemoryBudget) -> os.Channel[Sound]? {
    pair :: os.channel_for[Sound](budget, RING_BYTES) or_return null
    out := os.Outgoing.{}
    request :: os.begin[Request](&out)
    request^ = .Connect(os.Channel[Sound].{end = pair.a})
    match send_request(end, port, &out) {
        case Some(error) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.a))
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
            return null
        }
        case None => return os.Channel[Sound].{end = pair.b}
    }
}
