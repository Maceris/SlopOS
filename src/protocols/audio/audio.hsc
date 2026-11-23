package audio

import os from "std:os"
import slop_os from "std:os/slop_os"

/*
 * The device class of sound devices (decisions/0196, 17c): a stream played between a sound device's driver and its
 * client, the audio service. The stream's format is the system's, whatever the device's: RATE frames a second,
 * CHANNELS channels, each sample a 32-bit float at full scale 1 (std/audio), which the driver converts to the device's
 * own. Frames go through a ring of PERIODS periods of PERIOD_FRAMES frames each, in memory the client reaches through a
 * window (GetBuffer), which the device never sees: the driver copies each period from it as it's given.
 *
 * The client fills a period and gives it with Play, answered with Played once the device has taken it, when the period
 * is the client's again. Answers come in the order periods were given. The device plays the first once a few are given
 * (START_PERIODS), and plays silence when it runs out, which the driver counts. A driver serves one client at a time; a
 * new connection's client takes over, the periods the last gave dropped.
 *
 * Capture (17f) is the same the other way, from the device's first input stream that takes the system's format, through
 * a ring of its own (GetCaptureBuffer): the client gives a period to be filled with Record, answered with Recorded once
 * the device has filled it, when its frames are in the ring and the period is the client's again. The device starts
 * once START_PERIODS are given, and drops what it hears when it has none to fill, which the driver counts. One client
 * records at a time, which needn't be the one that plays.
 */

/**
 * The audio protocol, for the channels between a sound device's driver and its client, and its listener: the client
 * sends the requests, and the driver answers them.
 */
Audio :: struct {}

/**
 * What the protocol says of itself: its name, which its channels' tag is made from, its major version, and that the
 * client's budget is lent for each of its connections, which pays for the driver's work on it.
 */
PROTOCOL :: slop_os.Protocol.{name = "audio", major_version = 1, lending = .PerConnection}

/** The stream's rate: 48 kHz. */
RATE : u32 : 48000
/** Its channels: stereo, left then right in each frame. */
CHANNELS : u32 : 2
/** The bytes of a frame: a 32-bit float for each channel. */
FRAME_BYTES : u32 : 4 * CHANNELS
/** The frames of a period: 5 ms of them. */
PERIOD_FRAMES : u32 : 240
/** The bytes of a period. */
PERIOD_BYTES : u32 : PERIOD_FRAMES * FRAME_BYTES
/** How many periods the ring has: 40 ms of sound, at most, between the client and the device. */
PERIODS : u32 : 8
/**
 * The bytes of a connection's buffer, the ring: PERIODS periods, 15 KiB, from its start, in whole pages, 16 KiB, as
 * memory is made and windowed.
 */
BUFFER_BYTES : u64 : (cast[u64](PERIODS) * cast[u64](PERIOD_BYTES) + 4095) / 4096 * 4096
/** How many periods given before the device starts playing: half the ring. */
START_PERIODS : u32 : PERIODS / 2
/** The bytes of a connection's channel's ring: every period given and answered at once fits. */
RING_BYTES : u32 : 4096

/** What the driver says of the device. */
Info :: struct {
    /** How the device stores samples it plays, as virtio-sound's format numbers do: 19 floats, 5 16-bit integers. */
    device_format : u8,
    /** How it stores those it captures, the same way; 0 if it has no input stream that takes the system's format. */
    capture_format : u8,
    /** How many streams the device has, output and input; the driver uses the first of each that takes the format. */
    streams : u32,
}

/** Why a request was refused. */
Refused :: enum #backed_by(u8) {
    /** The connection has no buffer yet: GetBuffer first. */
    NoBuffer = 1,
    /** A period past PERIODS, or one given and not yet answered. */
    BadPeriod = 2,
    /** The device failed to take the period, or to start. */
    DeviceFailed = 3,
    /** Another connection's client is the driver's now. */
    Replaced = 4,
    /** The device has no input stream that takes the system's format: nothing to record from. */
    NoInput = 5,
}

/** A period the device took: which, how far behind the device was playing, and how often it's run out so far. */
Played :: struct {
    /** The period's index in the ring. */
    period : u32,
    /** How many frames the device had yet to play when it took it, as it said. */
    latency_frames : u32,
    /** How many times the device has run out of periods since playing started, playing silence. */
    underruns : u32,
}

/** A period the device filled: which, and how often it's had none to fill so far. */
Recorded :: struct {
    /** The period's index in the capture ring. */
    period : u32,
    /** How many times the device has had no period to fill since recording started, what it heard dropped. */
    overruns : u32,
}

/** What a sound device's driver is asked. */
Request :: union {
    /** Say what the device is. Answered with Described. */
    Describe,
    /** Make the connection's buffer, the ring, if it has none, and give a window onto it. Answered with Buffer. */
    GetBuffer,
    /**
     * Give a period, its frames written in the ring; the client leaves it alone until it's answered. Answered with
     * Played once the device has taken it, or with Refused.
     */
    Play(u32),
    /**
     * Stop playing: the periods given and not yet taken are dropped, each answered with Refused(Replaced) first.
     * Answered with Stopped; a Play after it starts again.
     */
    Stop,
    /**
     * Make the capture ring, CAPTURE periods' worth as the playing ring is, if there's none, give a window onto it, and
     * make the connection's client the one that records: another that did has its periods dropped. Answered with
     * CaptureBuffer, or with RecordRefused(NoInput) with period 0.
     */
    GetCaptureBuffer,
    /**
     * Give a period of the capture ring to be filled; the client leaves it alone until it's answered. Answered with
     * Recorded once the device has filled it, or with RecordRefused.
     */
    Record(u32),
    /**
     * Stop recording: the periods given and not yet filled are answered first, Recorded with what the device had
     * filled of them, or RecordRefused.
     * Answered with RecordingStopped; a Record after it starts again.
     */
    StopRecording,
    /**
     * Have the driver serve another client, on the end given, which moves to the driver; the client before, if any,
     * is closed. Sent on the listener, and answered with nothing.
     */
    Connect(os.Channel[Audio]),
}

/** What a sound device's driver answers. */
Response :: union {
    /** Describe's answer. */
    Described(Info),
    /** GetBuffer's answer: a window onto the connection's buffer, BUFFER_BYTES of it, which moves to the client. */
    Buffer(slop_os.Memory),
    /** Play's answer: the device has taken the period. */
    Played(Played),
    /** Play's answer when it's refused, by its period, and why. */
    Refused(PlayRefused),
    /** Stop's answer. */
    Stopped,
    /** GetCaptureBuffer's answer: a window onto the capture ring, BUFFER_BYTES of it, which moves to the client. */
    CaptureBuffer(slop_os.Memory),
    /** Record's answer: the device has filled the period. */
    Recorded(Recorded),
    /**
     * Record's or GetCaptureBuffer's answer when it's refused, apart from Refused so neither is taken for the other's
     * period.
     */
    RecordRefused(PlayRefused),
    /** StopRecording's answer. */
    RecordingStopped,
    /** The answer to a request the driver doesn't know, as from a newer client; every protocol has it. */
    Unsupported,
}

/** A Play refused: its period, and why. */
PlayRefused :: struct {
    /** The period's index, as given. */
    period : u32,
    /** Why. */
    why : Refused,
}

/**
 * Tell whether a request may be sent again, after a reconnect, without doing more than sending it once did.
 *
 * @param request The request, which isn't changed.
 * @return False for Play and Record, whose period would be played or filled twice; true for the rest.
 */
is_idempotent :: fn(request : ptr[Request]) -> bool {
    return match request^ {
        case Describe => true
        case GetBuffer => true
        case Play(_) => false
        case Stop => true
        case GetCaptureBuffer => true
        case Record(_) => false
        case StopRecording => true
        case Connect(_) => true
    }
}

#insert os.protocol_code(Request, Response)

/**
 * Make a new connection to a sound device's driver: a channel for the protocol, one end sent to it in a Connect, as
 * net.connect does.
 *
 * It doesn't wait: the driver takes the end when it next serves its listener. The channel's ring is RING_BYTES.
 *
 * @param end The driver's listener, or any connection to it, kept by the caller.
 * @param port A port bound to end, waited on while end's ring is full.
 * @param budget The memory budget that pays for the new channel.
 * @return The caller's end of the new connection, its own to keep and close; null if the channel couldn't be made, or
 *     the Connect couldn't be sent, in which case both its ends are closed.
 */
connect :: fn(end : slop_os.Channel, port : slop_os.Port, budget : slop_os.MemoryBudget) -> os.Channel[Audio]? {
    pair :: os.channel_for[Audio](budget, RING_BYTES) or_return null
    out := os.Outgoing.{}
    request :: os.begin[Request](&out)
    request^ = .Connect(os.Channel[Audio].{end = pair.a})
    match send_request(end, port, &out) {
        case Some(error) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.a))
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
            return null
        }
        case None => return os.Channel[Audio].{end = pair.b}
    }
}
