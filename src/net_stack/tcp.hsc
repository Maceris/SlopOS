package net_stack

/*
 * TCP (RFC 9293), with window scaling and timestamps (RFC 7323), selective acknowledgements (RFC 2018) and loss
 * recovery by them (RFC 6675, simplified), retransmission timers (RFC 6298), CUBIC (RFC 9438), and initial sequence
 * numbers from a keyed hash (RFC 6528).
 *
 * A connection's data is in two rings its caller gives, by address: what the application writes, kept until it's
 * acknowledged, and what arrives, kept until the application reads it. The caller says how far the application has
 * written (tcp_wrote) and read (tcp_read), as totals; the stack says how far it has delivered and had acknowledged
 * (tcp_status). A connection whose totals or state change is marked, and take_changed gives each marked once.
 * Connections starting and ending are events too: Incoming, as a listener's SYN arrives, which waits for tcp_accept to
 * give it rings before it's answered, and Ended.
 *
 * Not done: Nagle's algorithm (every write goes out as it's written, in segments of the MSS), urgent data, keepalives,
 * ICMP errors' effect on connections, and protection against wrapped sequence numbers (PAWS) beyond the timestamps'
 * echo.
 */

/** How many TCP connections the stack holds at once. */
TCP_CONNECTIONS :: 64
/** How many TCP listeners it holds at once. */
TCP_LISTENERS :: 16
/** How many SACK blocks each side keeps. */
SACK_BLOCKS :: 4
/** The bytes of a TCP header without options. */
TCP_HEADER :: 20
/** The first ephemeral port, as IANA has them. */
EPHEMERAL_FIRST : u16 : 49152

// Flags
TCP_FIN : u8 : 0x01
TCP_SYN : u8 : 0x02
TCP_RST : u8 : 0x04
TCP_PSH : u8 : 0x08
TCP_ACK : u8 : 0x10

// Options
TCP_OPTION_END : u8 : 0
TCP_OPTION_NOP : u8 : 1
TCP_OPTION_MSS : u8 : 2
TCP_OPTION_WINDOW_SCALE : u8 : 3
TCP_OPTION_SACK_PERMITTED : u8 : 4
TCP_OPTION_SACK : u8 : 5
TCP_OPTION_TIMESTAMPS : u8 : 8

// Times
/** The retransmission timeout before any round trip is measured: 1 s (RFC 6298 §2.1). */
INITIAL_RTO : u64 : SECOND
/** The shortest retransmission timeout: 200 ms, as Linux has it, rather than RFC 6298's 1 s. */
MIN_RTO : u64 : 200_000_000
/** The longest retransmission timeout: 60 s. */
MAX_RTO : u64 : 60 * SECOND
/** How many times a SYN is sent before the connection's given up: 6, about a minute. */
SYN_TRIES :: 6
/** How many times data is retransmitted without progress before the connection's given up: 12. */
DATA_TRIES :: 12
/** The longest an acknowledgement is held, hoping to send it with data or for a second segment: 40 ms. */
DELAYED_ACK : u64 : 40_000_000
/** How long a closed connection stays in TIME-WAIT: 2 MSL, with an MSL of 30 s. */
TIME_WAIT : u64 : 60 * SECOND
/** How long an incoming connection waits for tcp_accept before it's dropped: 5 s. */
ACCEPT_WAIT : u64 : 5 * SECOND

// CUBIC (RFC 9438 §4)
/** CUBIC's C, in thousandths: 0.4. */
CUBIC_C : f64 : 0.4
/** CUBIC's multiplicative decrease, beta: 0.7. */
CUBIC_BETA : f64 : 0.7

/** Where a connection is (RFC 9293 §3.3.2). */
TcpState :: enum {
    Free,
    SynSent,
    /** A listener's SYN arrived; waiting for tcp_accept before the SYN-ACK goes. */
    Incoming,
    SynReceived,
    Established,
    FinWait1,
    FinWait2,
    CloseWait,
    Closing,
    LastAck,
    TimeWait,
}

/** Memory of the caller's, by address, used as a ring of bytes. */
Ring :: struct {
    /** Its address in the caller's address space. */
    at : u64,
    /** Its size in bytes, at least 1. */
    bytes : u64,
}

/** A connection's rings: what the application writes, and what arrives for it. */
TcpRings :: struct {
    send : Ring,
    receive : Ring,
}

/** A range of sequence numbers, from start to end, past its last. */
SackBlock :: struct {
    start : u32,
    end : u32,
}

/** Why a connection ended. */
TcpEnding :: enum {
    /** Both sides closed, and every byte was acknowledged. */
    Closed,
    /** The peer reset it. */
    Reset,
    /** The peer refused it: a reset answered its SYN. */
    Refused,
    /** Nothing answered: retransmissions gave up. */
    TimedOut,
    /** tcp_abort reset it. */
    Aborted,
    /** Accepted too late, or never: a listener's connection tcp_accept didn't take in time. */
    NotAccepted,
}

/** A connection that arrived at a listener, waiting for tcp_accept. */
TcpIncoming :: struct {
    /** The listener, as tcp_listen gave it. */
    listener : u32,
    /** The connection. */
    connection : u32,
    /** Who's connecting. */
    remote : IpAddress,
    remote_port : u16,
}

/**
 * A connection that ended, and why, with its last totals: a connection ended is gone from tcp_status, but what it
 * delivered stays in its receive ring for the application to read.
 */
TcpEnded :: struct {
    connection : u32,
    why : TcpEnding,
    /** The bytes it delivered in order, from the start. */
    delivered : u64,
    /** The bytes the peer acknowledged, from the start. */
    acknowledged : u64,
}

/** How far a connection has got, for its caller. */
TcpStatus :: struct {
    state : TcpState,
    /** The bytes arrived in order, from the start: the receive ring holds those not yet read. */
    delivered : u64,
    /** The bytes the peer has acknowledged, from the start: the send ring's room past them is free. */
    acknowledged : u64,
    /** Whether the peer has finished sending: every byte it'll send is delivered. */
    peer_finished : bool,
    /** Whether it's ended, and won't change again; why is in Ended's event. */
    ended : bool,
}

/** A TCP connection's state. */
Tcb :: struct {
    state : TcpState,
    /** Counts up each time the entry's reused, so a stale connection number is refused. */
    generation : u16,
    /** Its index in the table. */
    index : u16,
    remote : IpAddress,
    local_port : u16,
    remote_port : u16,
    /** The listener it arrived at, plus one; 0 for one connected out. */
    listener : u32,
    rings : TcpRings,
    /** Whether it's marked changed, and in the changed list. */
    changed : bool,
    /** When an Incoming one is dropped, or a TIME-WAIT one freed. */
    deadline : u64,

    // Sending
    iss : u32,
    snd_una : u32,
    snd_nxt : u32,
    /** The highest sequence number sent, past its last, which snd_nxt goes back from on a timeout. */
    snd_max : u32,
    /** The peer's window, in bytes, scaled. */
    snd_wnd : u64,
    snd_wl1 : u32,
    snd_wl2 : u32,
    /** The peer's window scale shift. */
    send_scale : u8,
    /** The bytes the application has written, from the start. */
    written : u64,
    /** The bytes acknowledged, from the start: snd_una's offset once the SYN's acknowledged. */
    acknowledged : u64,
    /** Whether the application has finished writing: a FIN follows its last byte. */
    finishing : bool,
    /** Whether the FIN's been sent, at fin_seq. */
    fin_sent : bool,
    fin_seq : u32,
    /** The largest segment it sends, from the peer's MSS option and the MTU. */
    mss : u32,

    // Receiving
    irs : u32,
    rcv_nxt : u32,
    /** Its own window scale shift. */
    receive_scale : u8,
    /** The bytes delivered in order, from the start. */
    delivered : u64,
    /** The bytes the application has read, from the start. */
    read : u64,
    /** The window last advertised, past rcv_nxt, so a reopening is told. */
    advertised : u64,
    /** Segments past rcv_nxt received, as ranges. */
    out_of_order : SackBlock[SACK_BLOCKS],
    peer_finished : bool,

    // Options
    sack : bool,
    timestamps : bool,
    /** The peer's last timestamp, echoed back. */
    ts_recent : u32,

    // Timers
    /** When the retransmission timer fires; 0 when it's off. */
    rto_deadline : u64,
    rto : u64,
    srtt : u64,
    rttvar : u64,
    /** How many times in a row the timer has fired without progress. */
    retries : u32,
    /** When a held acknowledgement is sent; 0 for none held. */
    ack_deadline : u64,
    /** Whether an acknowledgement is due at once. */
    ack_now : bool,
    /** Full segments received since the last acknowledgement. */
    unacknowledged_segments : u32,
    /** Without timestamps: the sequence number whose acknowledgement times a round trip, and when it was sent. */
    timing_seq : u32,
    timing_sent : u64,
    timing : bool,

    // Congestion
    cwnd : u64,
    ssthresh : u64,
    duplicate_acks : u32,
    in_recovery : bool,
    /** Recovery ends once this is acknowledged. */
    recover : u32,
    /** The next sequence number recovery may retransmit from. */
    rescue : u32,
    /** The peer's SACK blocks, above snd_una. */
    sacked : SackBlock[SACK_BLOCKS],
    /** CUBIC: the window before the last reduction, in segments, and when the epoch started. */
    w_max : f64,
    epoch : u64,
    k : f64,
    /** CUBIC's Reno-friendly estimate, in segments. */
    w_est : f64,
}

/** A listener: a port, and whether it takes IPv4, IPv6 or both. */
TcpListener :: struct {
    port : u16,
    active : bool,
    generation : u16,
}

/** What a segment says. */
Segment :: struct {
    source_port : u16,
    destination_port : u16,
    seq : u32,
    ack : u32,
    flags : u8,
    window : u32,
    /** Where its data is in the segment, and how long. */
    data_at : usize,
    data_length : usize,
    mss : u32,
    window_scale : i32,
    sack_permitted : bool,
    has_timestamps : bool,
    ts_value : u32,
    ts_echo : u32,
    sacks : SackBlock[SACK_BLOCKS],
    sack_count : usize,
}

// ---- Sequence numbers, which wrap

/** a < b, sequence numbers. */
seq_lt :: fn(a: u32, b: u32) -> bool {
    return cast[i32](a - b) < 0
}

/** a <= b, sequence numbers. */
seq_le :: fn(a: u32, b: u32) -> bool {
    return cast[i32](a - b) <= 0
}

// ---- The application's side

/**
 * Open a connection: a SYN to the remote, from an ephemeral port.
 *
 * @param stack The stack.
 * @param remote Who it's to.
 * @param remote_port Their port.
 * @param rings Its rings, the caller's, which stay as they are until it's ended.
 * @return The connection's number; null if every entry's taken, or there's no address of the family to send from.
 */
tcp_connect :: fn(stack: ptr[mut Stack], remote: IpAddress, remote_port: u16, rings: TcpRings) -> u32? {
    if !has_source(stack, remote) || rings.send.bytes == 0 || rings.receive.bytes == 0 {
        return null
    }
    index :: free_tcb(stack) or_return null
    local_port :: ephemeral_port(stack, remote, remote_port) or_return null
    if index >= stack.tcbs.count {
        return null
    }
    tcb :: &stack.tcbs[index]
    open_tcb(stack, tcb, index, remote, local_port, remote_port, rings)
    tcb.state = .SynSent
    send_syn(stack, tcb, false)
    return connection_number(tcb)
}

/**
 * Listen on a port, for both families.
 *
 * @param stack The stack.
 * @param port The port, 1 to 65535.
 * @return The listener's number; null if the port's listened on already, or every listener's taken.
 */
tcp_listen :: fn(stack: ptr[mut Stack], port: u16) -> u32? {
    if port == 0 {
        return null
    }
    for each in stack.listeners {
        if each.active && each.port == port {
            return null
        }
    }
    for &each, i in stack.listeners {
        if !each.active {
            each.active = true
            each.port = port
            each.generation += 1
            return (cast[u32](each.generation) << 16) | cast[u32](i)
        }
    }
    return null
}

/**
 * Stop listening; connections it gave stay.
 *
 * @param stack The stack.
 * @param listener The listener's number.
 */
tcp_unlisten :: fn(stack: ptr[mut Stack], listener: u32) {
    index :: cast[usize](listener & 0xffff)
    if index < stack.listeners.count && cast[u32](stack.listeners[index].generation) == listener >> 16 {
        stack.listeners[index].active = false
    }
}

/**
 * Take a connection that arrived at a listener: its SYN is answered, with these rings.
 *
 * @param stack The stack.
 * @param connection The connection, as Incoming gave it.
 * @param rings Its rings, the caller's, which stay as they are until it's ended.
 * @return True once it's answered; false if it's gone, or isn't waiting.
 */
tcp_accept :: fn(stack: ptr[mut Stack], connection: u32, rings: TcpRings) -> bool {
    tcb :: find_tcb(stack, connection) or_return false
    if tcb.state != .Incoming || rings.send.bytes == 0 || rings.receive.bytes == 0 {
        return false
    }
    tcb.rings = rings
    tcb.receive_scale = scale_for(rings.receive.bytes)
    tcb.state = .SynReceived
    send_syn(stack, tcb, true)
    return true
}

/**
 * Say the application has written more into the send ring: everything up to written, from the start, goes out as the
 * windows let it.
 *
 * @param stack The stack.
 * @param connection The connection.
 * @param written The bytes written, from the start: no less than before, and at most the send ring's size past what's
 *     acknowledged.
 */
tcp_wrote :: fn(stack: ptr[mut Stack], connection: u32, written: u64) {
    tcb :: find_tcb(stack, connection) or_return void
    if tcb.finishing || written < tcb.written || written > tcb.acknowledged + tcb.rings.send.bytes {
        return void
    }
    tcb.written = written
    tcp_output(stack, tcb)
}

/**
 * Say the application has read from the receive ring: its room opens, and the peer's told if it opened by much.
 *
 * @param stack The stack.
 * @param connection The connection.
 * @param read The bytes read, from the start: no less than before, and at most what's delivered.
 */
tcp_read :: fn(stack: ptr[mut Stack], connection: u32, read: u64) {
    tcb :: find_tcb(stack, connection) or_return void
    if read < tcb.read || read > tcb.delivered {
        return void
    }
    tcb.read = read
    // A window update once the window's opened by two segments or half the ring
    window :: receive_window(tcb)
    if window >= tcb.advertised + 2 * cast[u64](tcb.mss) || window >= tcb.advertised + tcb.rings.receive.bytes / 2 {
        tcb.ack_now = true
        tcp_output(stack, tcb)
    }
}

/**
 * Finish writing: a FIN follows the last byte written. The connection ends once the peer's finished too.
 *
 * @param stack The stack.
 * @param connection The connection.
 */
tcp_finish :: fn(stack: ptr[mut Stack], connection: u32) {
    tcb :: find_tcb(stack, connection) or_return void
    if tcb.finishing {
        return void
    }
    tcb.finishing = true
    if tcb.state == .Incoming || tcb.state == .SynSent {
        end_tcb(stack, tcb, .Aborted)
        return void
    }
    tcp_output(stack, tcb)
}

/**
 * Reset a connection: it ends at once, and the peer's told by a reset.
 *
 * @param stack The stack.
 * @param connection The connection.
 */
tcp_abort :: fn(stack: ptr[mut Stack], connection: u32) {
    tcb :: find_tcb(stack, connection) or_return void
    if tcb.state != .Incoming && tcb.state != .SynSent && tcb.state != .TimeWait {
        send_reset(stack, tcb.remote, tcb.local_port, tcb.remote_port, tcb.snd_nxt)
    }
    end_tcb(stack, tcb, .Aborted)
}

/**
 * Say how far a connection has got.
 *
 * @param stack The stack.
 * @param connection The connection.
 * @return Its status; ended, with nothing else, for one that's gone.
 */
tcp_status :: fn(stack: ptr[Stack], connection: u32) -> TcpStatus {
    index :: cast[usize](connection & 0xffff)
    if index >= stack.tcbs.count || cast[u32](stack.tcbs[index].generation) != connection >> 16 || stack.tcbs[index].state == .Free {
        return TcpStatus.{ended = true}
    }
    tcb :: &stack.tcbs[index]
    return TcpStatus.{state = tcb.state, delivered = tcb.delivered, acknowledged = tcb.acknowledged,
        peer_finished = tcb.peer_finished, ended = tcb.state == .TimeWait}
}

/**
 * Take a connection whose status changed since it was last taken.
 *
 * @param stack The stack.
 * @return The connection's number; null if none changed.
 */
take_changed :: fn(stack: ptr[mut Stack]) -> u32? {
    for &tcb, i in stack.tcbs {
        if tcb.changed {
            tcb.changed = false
            return connection_number(tcb)
        }
    }
    return null
}

// ---- Entries

/**
 * Give a connection's number: its entry's generation and index.
 *
 * @param tcb The entry.
 * @return The number.
 */
connection_number :: fn(tcb: ptr[Tcb]) -> u32 {
    return (cast[u32](tcb.generation) << 16) | cast[u32](tcb.index)
}

/**
 * Find a connection by number.
 *
 * @param stack The stack.
 * @param connection The number.
 * @return Its entry; null if it's gone, or never was.
 */
find_tcb :: fn(stack: ptr[mut Stack], connection: u32) -> ptr[mut Tcb]? {
    index :: cast[usize](connection & 0xffff)
    if index >= stack.tcbs.count {
        return null
    }
    tcb :: &stack.tcbs[index]
    if tcb.state == .Free || cast[u32](tcb.generation) != connection >> 16 {
        return null
    }
    return tcb
}

/**
 * Find a free entry.
 *
 * @param stack The stack.
 * @return Its index; null if every one's taken.
 */
free_tcb :: fn(stack: ptr[Stack]) -> usize? {
    for each, i in stack.tcbs {
        if each.state == .Free {
            return i
        }
    }
    return null
}

/**
 * Set a new connection's entry up: its addresses, rings, initial sequence number, and timers.
 *
 * @param stack The stack.
 * @param tcb The entry, free.
 * @param index Its index in the table.
 * @param remote Its peer.
 * @param local_port Its port.
 * @param remote_port Its peer's port.
 * @param rings Its rings; an Incoming connection's are set by tcp_accept.
 */
open_tcb :: fn(stack: ptr[mut Stack], tcb: ptr[mut Tcb], index: usize, remote: IpAddress, local_port: u16, remote_port: u16,
    rings: TcpRings) {
    generation :: tcb.generation + 1
    tcb^ = Tcb.{}
    tcb.generation = if generation == 0 { cast[u16](1) } else { generation }
    tcb.index = cast[u16](index)
    tcb.remote = remote
    tcb.local_port = local_port
    tcb.remote_port = remote_port
    tcb.rings = rings
    tcb.iss = initial_sequence(stack, remote, local_port, remote_port)
    tcb.snd_una = tcb.iss
    tcb.snd_nxt = tcb.iss
    tcb.snd_max = tcb.iss
    tcb.mss = default_mss(stack, remote)
    tcb.rto = INITIAL_RTO
    tcb.receive_scale = scale_for(rings.receive.bytes)
    // RFC 6928's initial window: ten segments
    tcb.cwnd = 10 * cast[u64](tcb.mss)
    tcb.ssthresh = ~cast[u64](0)
}

/**
 * End a connection: it's told as Ended, marked changed, and its entry freed.
 *
 * @param stack The stack.
 * @param tcb The connection.
 * @param why Why.
 */
end_tcb :: fn(stack: ptr[mut Stack], tcb: ptr[mut Tcb], why: TcpEnding) {
    number :: connection_number(tcb)
    tcb.state = .Free
    tcb.changed = false
    tcb.rto_deadline = 0
    tcb.ack_deadline = 0
    event(stack, .Ended(TcpEnded.{connection = number, why = why, delivered = tcb.delivered, acknowledged = tcb.acknowledged}))
}

/**
 * Mark a connection changed, for take_changed.
 *
 * @param tcb The connection.
 */
mark :: fn(tcb: ptr[mut Tcb]) {
    tcb.changed = true
}

/**
 * Give a window scale shift that lets a ring's size be advertised: 0 for up to 64 KiB, at most 14.
 *
 * @param bytes The ring's size.
 * @return The shift.
 */
scale_for :: fn(bytes: u64) -> u8 {
    shift := cast[u8](0)
    loop {
        if (bytes >> cast[u64](shift)) <= 0xffff || shift >= 14 {
            break
        }
        shift += 1
    }
    while true
    return shift
}

/**
 * Give the MSS for a peer before its option says: the MTU less the IP and TCP headers.
 *
 * @param stack The stack.
 * @param remote The peer.
 * @return The MSS.
 */
default_mss :: fn(stack: ptr[Stack], remote: IpAddress) -> u32 {
    header :: match remote {
        case V4(_) => cast[u32](IPV4_HEADER + TCP_HEADER)
        case V6(_) => cast[u32](IPV6_HEADER + TCP_HEADER)
    }
    return cast[u32](stack.mtu) - header
}

/**
 * Tell whether the stack has an address to send to a peer from.
 *
 * @param stack The stack.
 * @param remote The peer.
 * @return True if it has.
 */
has_source :: fn(stack: ptr[Stack], remote: IpAddress) -> bool {
    return match remote {
        case V4(_) => !is_zero_ipv4(stack.ipv4)
        case V6(address) => !is_zero_ipv6(source_for(stack, address))
    }
}

/**
 * Choose an ephemeral port no connection to the same peer and port uses, from a random start.
 *
 * @param stack The stack.
 * @param remote The peer.
 * @param remote_port Its port.
 * @return The port; null if every one's taken.
 */
ephemeral_port :: fn(stack: ptr[mut Stack], remote: IpAddress, remote_port: u16) -> u16? {
    span :: cast[u64](65536) - cast[u64](EPHEMERAL_FIRST)
    start :: next_random(stack) % span
    for i in cast[u64](0)..<span {
        port :: cast[u16](cast[u64](EPHEMERAL_FIRST) + (start + i) % span)
        used := false
        for each in stack.tcbs {
            if each.state != .Free && each.local_port == port && each.remote_port == remote_port && same_address(each.remote, remote) {
                used = true
                break
            }
        }
        if !used {
            return port
        }
    }
    return null
}

/**
 * Make an initial sequence number: a keyed hash of the connection's ports and peer, plus a clock ticking every 4 µs
 * (RFC 6528).
 *
 * @param stack The stack, whose secret keys the hash.
 * @param remote The peer.
 * @param local_port The connection's port.
 * @param remote_port The peer's port.
 * @return The number.
 */
initial_sequence :: fn(stack: ptr[Stack], remote: IpAddress, local_port: u16, remote_port: u16) -> u32 {
    hash := cast[u64](0xcbf29ce484222325)
    for byte in stack.secret {
        hash = (hash ~ cast[u64](byte)) * 0x100000001b3
    }
    address :: match remote {
        case V4(v4) => ipv6_of4(v4)
        case V6(v6) => v6
    }
    for byte in address.bytes {
        hash = (hash ~ cast[u64](byte)) * 0x100000001b3
    }
    hash = (hash ~ cast[u64](local_port)) * 0x100000001b3
    hash = (hash ~ cast[u64](remote_port)) * 0x100000001b3
    return cast[u32](hash) + cast[u32](stack.now / 4000)
}

// ---- Rings

/**
 * View a ring's memory.
 *
 * @param ring The ring.
 * @return Its bytes.
 */
ring_bytes :: fn(ring: Ring) -> mut u8[] {
    return view_of(cast[ptr[mut u8]](ring.at), cast[usize](ring.bytes))
}

/**
 * Copy out of a ring, from a stream offset, wrapping.
 *
 * @param ring The ring.
 * @param offset The stream offset of the first byte.
 * @param into Where they go, all of it filled.
 */
ring_read :: fn(ring: Ring, offset: u64, into: mut u8[]) {
    bytes :: ring_bytes(ring)
    if bytes.count == 0 {
        return void
    }
    for &byte, i in into {
        at :: cast[usize]((offset + cast[u64](i)) % ring.bytes)
        if at < bytes.count {
            byte^ = bytes[at]
        }
    }
}

/**
 * Copy into a ring, at a stream offset, wrapping.
 *
 * @param ring The ring.
 * @param offset The stream offset of the first byte.
 * @param from What's copied.
 */
ring_write :: fn(ring: Ring, offset: u64, from: u8[]) {
    bytes :: ring_bytes(ring)
    if bytes.count == 0 {
        return void
    }
    for byte, i in from {
        at :: cast[usize]((offset + cast[u64](i)) % ring.bytes)
        if at < bytes.count {
            bytes[at] = byte
        }
    }
}

/**
 * Give the room the receive ring has past what's delivered: the window.
 *
 * @param tcb The connection.
 * @return The bytes.
 */
receive_window :: fn(tcb: ptr[Tcb]) -> u64 {
    held :: tcb.delivered - tcb.read
    return if held < tcb.rings.receive.bytes { tcb.rings.receive.bytes - held } else { cast[u64](0) }
}

// ---- Sending

/**
 * Send a SYN, or a SYN-ACK for an incoming connection, with the options: MSS, window scale, SACK permitted and
 * timestamps, the latter three on a SYN-ACK only if the peer's SYN had them.
 *
 * @param stack The stack.
 * @param tcb The connection.
 * @param answering Whether it's a SYN-ACK.
 */
send_syn :: fn(stack: ptr[mut Stack], tcb: ptr[mut Tcb], answering: bool) {
    // At most 40 bytes of options a segment; a SYN's take 24
    options : u8[40]
    o :: view_of(&options[0], options.count)
    length := cast[usize](0)
    put_u8(o, 0, TCP_OPTION_MSS)
    put_u8(o, 1, 4)
    put_u16(o, 2, cast[u16](default_mss(stack, tcb.remote)))
    length = 4
    if !answering || tcb.sack {
        put_u8(o, length, TCP_OPTION_NOP)
        put_u8(o, length + 1, TCP_OPTION_NOP)
        put_u8(o, length + 2, TCP_OPTION_SACK_PERMITTED)
        put_u8(o, length + 3, 2)
        length += 4
    }
    if !answering || tcb.timestamps {
        put_u8(o, length, TCP_OPTION_NOP)
        put_u8(o, length + 1, TCP_OPTION_NOP)
        put_u8(o, length + 2, TCP_OPTION_TIMESTAMPS)
        put_u8(o, length + 3, 10)
        put_u32(o, length + 4, timestamp(stack))
        put_u32(o, length + 8, if answering { tcb.ts_recent } else { cast[u32](0) })
        length += 12
    }
    if !answering || tcb.send_scale != 0xff {
        put_u8(o, length, TCP_OPTION_NOP)
        put_u8(o, length + 1, TCP_OPTION_WINDOW_SCALE)
        put_u8(o, length + 2, 3)
        put_u8(o, length + 3, tcb.receive_scale)
        length += 4
    }
    if answering && tcb.send_scale == 0xff {
        // The peer can't scale, so neither does it
        tcb.send_scale = 0
        tcb.receive_scale = 0
    }
    flags :: if answering { TCP_SYN | TCP_ACK } else { TCP_SYN }
    window :: if receive_window(tcb) > 0xffff { cast[u64](0xffff) } else { receive_window(tcb) }
    send_segment(stack, tcb, tcb.iss, flags, part(view_of(&options[0], options.count), 0, length), window)
    tcb.snd_nxt = tcb.iss + 1
    tcb.snd_max = tcb.snd_nxt
    if tcb.rto_deadline == 0 {
        tcb.rto_deadline = stack.now + tcb.rto
    }
}

/**
 * Give an empty payload.
 *
 * @return No bytes.
 */
nothing :: fn() -> u8[] {
    return string_bytes("")
}

/**
 * Give the timestamp option's clock: milliseconds.
 *
 * @param stack The stack.
 * @return It.
 */
timestamp :: fn(stack: ptr[Stack]) -> u32 {
    return cast[u32](stack.now / 1_000_000)
}

/**
 * Send what a connection can: data and its FIN as the windows let, an acknowledgement if one's due, and start its
 * retransmission timer if something's in flight.
 *
 * @param stack The stack.
 * @param tcb The connection.
 */
tcp_output :: fn(stack: ptr[mut Stack], tcb: ptr[mut Tcb]) {
    if tcb.state != .Established && tcb.state != .CloseWait && tcb.state != .FinWait1 && tcb.state != .Closing
        && tcb.state != .LastAck && tcb.state != .FinWait2 && tcb.state != .TimeWait {
        return void
    }
    sent_any := false
    can_send :: tcb.state == .Established || tcb.state == .CloseWait || tcb.state == .FinWait1 || tcb.state == .Closing
        || tcb.state == .LastAck
    loop {
        // No room to queue it: it waits for tcp_resume, as the outbox drains
        if !can_send || outbox_full(stack) {
            break
        }
        // Holes first in recovery, past what the peer has SACKed
        if tcb.in_recovery {
            match next_hole(tcb) {
                case Some(hole) => {
                    if in_flight(tcb) < tcb.cwnd {
                        length :: hole_length(tcb, hole)
                        if length > 0 {
                            send_data(stack, tcb, hole, length)
                            tcb.rescue = hole + length
                            sent_any = true
                            continue
                        }
                    }
                }
                case None => {}
            }
        }
        data_end :: tcb.snd_una + cast[u32](tcb.written - tcb.acknowledged)
        unsent :: if seq_lt(tcb.snd_nxt, data_end) { cast[u64](data_end - tcb.snd_nxt) } else { cast[u64](0) }
        flight :: in_flight(tcb)
        window :: if tcb.snd_wnd < tcb.cwnd { tcb.snd_wnd } else { tcb.cwnd }
        room :: if window > flight { window - flight } else { cast[u64](0) }
        if unsent > 0 {
            if room == 0 {
                // A zero window: probed with a byte when the timer fires
                if flight == 0 && tcb.rto_deadline == 0 {
                    tcb.rto_deadline = stack.now + tcb.rto
                }
                break
            }
            most :: if room < cast[u64](segment_data(tcb)) { room } else { cast[u64](segment_data(tcb)) }
            length :: if unsent < most { unsent } else { most }
            send_data(stack, tcb, tcb.snd_nxt, cast[u32](length))
            sent_any = true
            continue
        }
        if tcb.finishing && !tcb.fin_sent && unsent == 0 {
            tcb.fin_sent = true
            tcb.fin_seq = tcb.snd_nxt
            send_segment(stack, tcb, tcb.snd_nxt, TCP_FIN | TCP_ACK, nothing(), advertise(tcb))
            tcb.snd_nxt += 1
            if seq_lt(tcb.snd_max, tcb.snd_nxt) {
                tcb.snd_max = tcb.snd_nxt
            }
            if tcb.state == .Established {
                tcb.state = .FinWait1
            }
            else if tcb.state == .CloseWait {
                tcb.state = .LastAck
            }
            sent_any = true
            mark(tcb)
        }
        break
    }
    if !sent_any && (tcb.ack_now || (tcb.ack_deadline != 0 && stack.now >= tcb.ack_deadline)) {
        send_ack(stack, tcb)
    }
    if in_flight(tcb) > 0 && tcb.rto_deadline == 0 {
        tcb.rto_deadline = stack.now + tcb.rto
    }
}

/**
 * Give the bytes of options a segment of a connection's carries: timestamps, and a SACK block for each range of
 * out-of-order data held, at most three.
 *
 * @param tcb The connection.
 * @return The bytes, a multiple of 4.
 */
option_bytes :: fn(tcb: ptr[Tcb]) -> u32 {
    bytes := if tcb.timestamps { cast[u32](12) } else { cast[u32](0) }
    if tcb.sack {
        count := cast[u32](0)
        for block in tcb.out_of_order {
            if seq_lt(block.start, block.end) && count < 3 {
                count += 1
            }
        }
        if count > 0 {
            bytes += 4 + 8 * count
        }
    }
    return bytes
}

/**
 * Give the most data a segment carries: the MSS less its options, as the MSS counts data alone (RFC 6691).
 *
 * @param tcb The connection.
 * @return The bytes, at least 1.
 */
segment_data :: fn(tcb: ptr[Tcb]) -> u32 {
    options :: option_bytes(tcb)
    return if tcb.mss > options { tcb.mss - options } else { cast[u32](1) }
}

/**
 * Give the bytes in flight: sent, not acknowledged, less what the peer's SACKed.
 *
 * @param tcb The connection.
 * @return The bytes.
 */
in_flight :: fn(tcb: ptr[Tcb]) -> u64 {
    total := cast[u64](tcb.snd_nxt - tcb.snd_una)
    for block in tcb.sacked {
        if seq_lt(block.start, block.end) && seq_le(tcb.snd_una, block.start) && seq_le(block.end, tcb.snd_nxt) {
            sacked :: cast[u64](block.end - block.start)
            total = if total > sacked { total - sacked } else { cast[u64](0) }
        }
    }
    return total
}

/**
 * Give a sequence number's offset in the stream sent, past the SYN.
 *
 * @param tcb The connection, its SYN acknowledged.
 * @param seq A sequence number from snd_una on.
 * @return Its offset.
 */
offset_of :: fn(tcb: ptr[Tcb], seq: u32) -> u64 {
    return tcb.acknowledged + cast[u64](seq - tcb.snd_una)
}

/**
 * Send data from the send ring, from a sequence number; snd_nxt moves past it if it's new.
 *
 * @param stack The stack.
 * @param tcb The connection.
 * @param seq Where it starts.
 * @param length How many bytes, at most segment_data.
 */
send_data :: fn(stack: ptr[mut Stack], tcb: ptr[mut Tcb], seq: u32, length: u32) {
    data : u8[MAX_FRAME]
    count :: if cast[usize](length) < data.count { cast[usize](length) } else { data.count }
    bytes :: view_of(&data[0], count)
    ring_read(tcb.rings.send, offset_of(tcb, seq), bytes)
    end :: seq + cast[u32](count)
    flags := TCP_ACK
    if offset_of(tcb, end) == tcb.written {
        flags |= TCP_PSH
    }
    send_segment(stack, tcb, seq, flags, bytes, advertise(tcb))
    if seq_lt(tcb.snd_nxt, end) {
        tcb.snd_nxt = end
    }
    if seq_lt(tcb.snd_max, tcb.snd_nxt) {
        tcb.snd_max = tcb.snd_nxt
    }
    // Without timestamps, one segment at a time is timed, never a retransmitted one (Karn)
    if !tcb.timestamps && !tcb.timing && seq_le(tcb.snd_max, end) {
        tcb.timing = true
        tcb.timing_seq = end
        tcb.timing_sent = stack.now
    }
    tcb.ack_deadline = 0
    tcb.ack_now = false
    tcb.unacknowledged_segments = 0
}

/**
 * Send a bare acknowledgement.
 *
 * @param stack The stack.
 * @param tcb The connection.
 */
send_ack :: fn(stack: ptr[mut Stack], tcb: ptr[mut Tcb]) {
    send_segment(stack, tcb, tcb.snd_nxt, TCP_ACK, nothing(), advertise(tcb))
    tcb.ack_deadline = 0
    tcb.ack_now = false
    tcb.unacknowledged_segments = 0
}

/**
 * Give the window to advertise, and note it.
 *
 * @param tcb The connection.
 * @return The window, in bytes, unscaled.
 */
advertise :: fn(tcb: ptr[mut Tcb]) -> u64 {
    window :: receive_window(tcb)
    tcb.advertised = window
    return window
}

/**
 * Send a segment of a connection's, with timestamps and SACK blocks as it has them.
 *
 * @param stack The stack.
 * @param tcb The connection.
 * @param seq Its sequence number.
 * @param flags Its flags.
 * @param payload Its options for a SYN, or its data.
 * @param window The window to advertise, in bytes, scaled here unless it's a SYN's.
 */
send_segment :: fn(stack: ptr[mut Stack], tcb: ptr[mut Tcb], seq: u32, flags: u8, payload: u8[], window: u64) {
    segment : u8[MAX_FRAME]
    bytes :: view_of(&segment[0], segment.count)
    put_u16(bytes, 0, tcb.local_port)
    put_u16(bytes, 2, tcb.remote_port)
    put_u32(bytes, 4, seq)
    acknowledging :: flags & TCP_ACK != 0
    put_u32(bytes, 8, if acknowledging { tcb.rcv_nxt } else { cast[u32](0) })
    syn :: flags & TCP_SYN != 0
    options := cast[usize](0)
    if syn {
        put_bytes(bytes, TCP_HEADER, payload)
        options = payload.count
    }
    else {
        if tcb.timestamps {
            put_u8(bytes, TCP_HEADER, TCP_OPTION_NOP)
            put_u8(bytes, TCP_HEADER + 1, TCP_OPTION_NOP)
            put_u8(bytes, TCP_HEADER + 2, TCP_OPTION_TIMESTAMPS)
            put_u8(bytes, TCP_HEADER + 3, 10)
            put_u32(bytes, TCP_HEADER + 4, timestamp(stack))
            put_u32(bytes, TCP_HEADER + 8, tcb.ts_recent)
            options = 12
        }
        if tcb.sack {
            count := cast[usize](0)
            for block in tcb.out_of_order {
                if seq_lt(block.start, block.end) && count < 3 {
                    count += 1
                }
            }
            if count > 0 {
                put_u8(bytes, TCP_HEADER + options, TCP_OPTION_NOP)
                put_u8(bytes, TCP_HEADER + options + 1, TCP_OPTION_NOP)
                put_u8(bytes, TCP_HEADER + options + 2, TCP_OPTION_SACK)
                put_u8(bytes, TCP_HEADER + options + 3, cast[u8](2 + 8 * count))
                at := TCP_HEADER + options + 4
                written := cast[usize](0)
                for block in tcb.out_of_order {
                    if seq_lt(block.start, block.end) && written < count {
                        put_u32(bytes, at, block.start)
                        put_u32(bytes, at + 4, block.end)
                        at += 8
                        written += 1
                    }
                }
                options += 4 + 8 * count
            }
        }
    }
    header :: TCP_HEADER + options
    put_u8(bytes, 12, cast[u8]((header / 4) << 4))
    put_u8(bytes, 13, flags)
    scaled :: if syn { window } else { window >> cast[u64](tcb.receive_scale) }
    put_u16(bytes, 14, if scaled > 0xffff { cast[u16](0xffff) } else { cast[u16](scaled) })
    total := header
    if !syn {
        put_bytes(bytes, header, payload)
        total += payload.count
    }
    whole :: view_of(&segment[0], if total < segment.count { total } else { segment.count })
    send_tcp(stack, tcb.remote, whole)
}

/**
 * Send a TCP segment over the peer's family, its checksum made.
 *
 * @param stack The stack.
 * @param remote The peer.
 * @param segment The segment, its checksum field written here.
 */
send_tcp :: fn(stack: ptr[mut Stack], remote: IpAddress, segment: mut u8[]) {
    put_u16(segment, 16, 0)
    match remote {
        case V4(to) => {
            put_u16(segment, 16, checksum_finish(pseudo_sum_v4(stack.ipv4, to, PROTOCOL_TCP, segment.count) + checksum_add(0, segment)))
            _ = send_ipv4(stack, to, PROTOCOL_TCP, segment)
        }
        case V6(to) => {
            from :: source_for(stack, to)
            put_u16(segment, 16, checksum_finish(pseudo_sum_v6(from, to, PROTOCOL_TCP, segment.count) + checksum_add(0, segment)))
            _ = send_ipv6(stack, from, to, PROTOCOL_TCP, segment, stack.hop_limit)
        }
    }
}

/**
 * Send a reset, for a segment no connection takes, or an abort.
 *
 * @param stack The stack.
 * @param remote Who it's to.
 * @param local_port The port it's from.
 * @param remote_port The port it's to.
 * @param seq Its sequence number.
 */
send_reset :: fn(stack: ptr[mut Stack], remote: IpAddress, local_port: u16, remote_port: u16, seq: u32) {
    segment : u8[TCP_HEADER]
    bytes :: view_of(&segment[0], segment.count)
    put_u16(bytes, 0, local_port)
    put_u16(bytes, 2, remote_port)
    put_u32(bytes, 4, seq)
    put_u8(bytes, 12, 0x50)
    put_u8(bytes, 13, TCP_RST)
    send_tcp(stack, remote, bytes)
}

/**
 * Answer a segment no connection takes with a reset (RFC 9293 §3.10.7.1): acknowledging it if it had no ACK.
 *
 * @param stack The stack.
 * @param remote Who sent it.
 * @param segment What it says.
 */
refuse_segment :: fn(stack: ptr[mut Stack], remote: IpAddress, segment: ptr[Segment]) {
    if segment.flags & TCP_RST != 0 {
        return void
    }
    reply : u8[TCP_HEADER]
    bytes :: view_of(&reply[0], reply.count)
    put_u16(bytes, 0, segment.destination_port)
    put_u16(bytes, 2, segment.source_port)
    put_u8(bytes, 12, 0x50)
    if segment.flags & TCP_ACK != 0 {
        put_u32(bytes, 4, segment.ack)
        put_u8(bytes, 13, TCP_RST)
    }
    else {
        length := cast[u32](segment.data_length)
        if segment.flags & TCP_SYN != 0 {
            length += 1
        }
        if segment.flags & TCP_FIN != 0 {
            length += 1
        }
        put_u32(bytes, 8, segment.seq + length)
        put_u8(bytes, 13, TCP_RST | TCP_ACK)
    }
    send_tcp(stack, remote, bytes)
}

// ---- Receiving

/**
 * Read a TCP segment's header and options.
 *
 * @param bytes The segment.
 * @return What it says; null if its header doesn't fit it.
 */
read_segment :: fn(bytes: u8[]) -> Segment? {
    if bytes.count < TCP_HEADER {
        return null
    }
    header :: cast[usize](byte_at(bytes, 12) >> 4) * 4
    if header < TCP_HEADER || header > bytes.count {
        return null
    }
    segment := Segment.{source_port = u16_at(bytes, 0), destination_port = u16_at(bytes, 2), seq = u32_at(bytes, 4),
        ack = u32_at(bytes, 8), flags = byte_at(bytes, 13), window = cast[u32](u16_at(bytes, 14)), data_at = header,
        data_length = bytes.count - header, window_scale = -1}
    at := cast[usize](TCP_HEADER)
    loop {
        if at >= header {
            break
        }
        kind :: byte_at(bytes, at)
        if kind == TCP_OPTION_END {
            break
        }
        if kind == TCP_OPTION_NOP {
            at += 1
            continue
        }
        length :: cast[usize](byte_at(bytes, at + 1))
        if length < 2 || at + length > header {
            break
        }
        if kind == TCP_OPTION_MSS && length == 4 {
            segment.mss = cast[u32](u16_at(bytes, at + 2))
        }
        else if kind == TCP_OPTION_WINDOW_SCALE && length == 3 {
            shift :: byte_at(bytes, at + 2)
            segment.window_scale = if shift > 14 { 14 } else { cast[i32](shift) }
        }
        else if kind == TCP_OPTION_SACK_PERMITTED && length == 2 {
            segment.sack_permitted = true
        }
        else if kind == TCP_OPTION_TIMESTAMPS && length == 10 {
            segment.has_timestamps = true
            segment.ts_value = u32_at(bytes, at + 2)
            segment.ts_echo = u32_at(bytes, at + 6)
        }
        else if kind == TCP_OPTION_SACK && length >= 10 {
            count :: (length - 2) / 8
            for i in cast[usize](0)..<count {
                if segment.sack_count < segment.sacks.count {
                    segment.sacks[segment.sack_count] = SackBlock.{start = u32_at(bytes, at + 2 + i * 8), end = u32_at(bytes, at + 6 + i * 8)}
                    segment.sack_count += 1
                }
            }
        }
        at += length
    }
    while true
    return segment
}

/**
 * Take a TCP segment for the interface: checked, then given to its connection, or a listener, or refused.
 *
 * @param stack The stack.
 * @param source Who sent it.
 * @param pseudo The sum of its pseudo-header, by its family.
 * @param bytes The segment.
 */
receive_tcp :: fn(stack: ptr[mut Stack], source: IpAddress, pseudo: u64, bytes: u8[]) {
    if checksum_finish(pseudo + checksum_add(0, bytes)) != 0 {
        return void
    }
    segment := read_segment(bytes) or_return void
    data :: part(bytes, segment.data_at, bytes.count)
    for &tcb in stack.tcbs {
        if tcb.state != .Free && tcb.local_port == segment.destination_port && tcb.remote_port == segment.source_port
            && same_address(tcb.remote, source) {
            segment_arrives(stack, tcb, &segment, data)
            return void
        }
    }
    // A SYN for a listener makes an incoming connection
    if segment.flags & (TCP_SYN | TCP_ACK | TCP_RST) == TCP_SYN {
        for each, i in stack.listeners {
            if each.active && each.port == segment.destination_port {
                incoming(stack, (cast[u32](each.generation) << 16) | cast[u32](i), source, &segment)
                return void
            }
        }
    }
    refuse_segment(stack, source, &segment)
}

/**
 * Make an incoming connection for a listener's SYN, told as Incoming; its SYN-ACK waits for tcp_accept.
 *
 * @param stack The stack.
 * @param listener The listener.
 * @param source Who's connecting.
 * @param segment The SYN.
 */
incoming :: fn(stack: ptr[mut Stack], listener: u32, source: IpAddress, segment: ptr[Segment]) {
    index :: free_tcb(stack) or_return void
    if index >= stack.tcbs.count {
        return void
    }
    tcb :: &stack.tcbs[index]
    open_tcb(stack, tcb, index, source, segment.destination_port, segment.source_port, TcpRings.{})
    tcb.state = .Incoming
    tcb.listener = listener + 1
    tcb.deadline = stack.now + ACCEPT_WAIT
    take_syn_options(tcb, segment)
    tcb.irs = segment.seq
    tcb.rcv_nxt = segment.seq + 1
    event(stack, .Incoming(TcpIncoming.{listener = listener, connection = connection_number(tcb), remote = source,
        remote_port = segment.source_port}))
}

/**
 * Take a SYN's options: the peer's MSS, window scale, SACK and timestamps.
 *
 * @param tcb The connection.
 * @param segment The SYN.
 */
take_syn_options :: fn(tcb: ptr[mut Tcb], segment: ptr[Segment]) {
    if segment.mss != 0 && segment.mss < tcb.mss {
        tcb.mss = segment.mss
    }
    if tcb.mss < 64 {
        tcb.mss = 64
    }
    tcb.sack = segment.sack_permitted
    tcb.timestamps = segment.has_timestamps
    if segment.has_timestamps {
        tcb.ts_recent = segment.ts_value
    }
    // 0xff until it's known whether the peer scales
    tcb.send_scale = if segment.window_scale >= 0 { cast[u8](segment.window_scale) } else { cast[u8](0xff) }
    tcb.cwnd = 10 * cast[u64](tcb.mss)
}

/**
 * Process a segment for a connection, as RFC 9293 §3.10.7 has it.
 *
 * @param stack The stack.
 * @param tcb The connection.
 * @param segment What the segment says.
 * @param data Its data.
 */
segment_arrives :: fn(stack: ptr[mut Stack], tcb: ptr[mut Tcb], segment: ptr[Segment], data: u8[]) {
    flags :: segment.flags
    if tcb.state == .Incoming {
        // A retransmitted SYN while waiting for tcp_accept
        return void
    }
    if tcb.state == .SynSent {
        syn_sent_arrives(stack, tcb, segment)
        return void
    }
    // The sequence number's check (§3.10.7.4): something of it within the window, or a bare ACK at its edge
    window :: receive_window(tcb)
    length := cast[u32](data.count)
    if flags & TCP_SYN != 0 {
        length += 1
    }
    if flags & TCP_FIN != 0 {
        length += 1
    }
    acceptable :: if length == 0 {
        if window == 0 { segment.seq == tcb.rcv_nxt } else { seq_le(tcb.rcv_nxt, segment.seq) && seq_lt(segment.seq, tcb.rcv_nxt + cast[u32](window)) }
    } else if window == 0 {
        false
    } else {
        last :: segment.seq + length - 1
        (seq_le(tcb.rcv_nxt, segment.seq) && seq_lt(segment.seq, tcb.rcv_nxt + cast[u32](window)))
            || (seq_le(tcb.rcv_nxt, last) && seq_lt(last, tcb.rcv_nxt + cast[u32](window)))
    }
    if !acceptable {
        if flags & TCP_RST == 0 {
            tcb.ack_now = true
            tcp_output(stack, tcb)
        }
        return void
    }
    if flags & TCP_RST != 0 {
        // Exactly at rcv_nxt; else a challenge ACK (RFC 5961 §3.2)
        if segment.seq == tcb.rcv_nxt {
            end_tcb(stack, tcb, .Reset)
        }
        else {
            send_ack(stack, tcb)
        }
        return void
    }
    if flags & TCP_SYN != 0 {
        // A SYN in a synchronized state: a challenge ACK (RFC 5961 §4.2)
        send_ack(stack, tcb)
        return void
    }
    if flags & TCP_ACK == 0 {
        return void
    }
    if tcb.timestamps && segment.has_timestamps && seq_le(segment.seq, tcb.rcv_nxt) {
        tcb.ts_recent = segment.ts_value
    }
    if tcb.state == .SynReceived {
        if seq_lt(tcb.snd_una, segment.ack) && seq_le(segment.ack, tcb.snd_nxt) {
            tcb.state = .Established
            tcb.snd_una = segment.ack
            tcb.snd_wnd = cast[u64](segment.window) << cast[u64](tcb.send_scale)
            tcb.snd_wl1 = segment.seq
            tcb.snd_wl2 = segment.ack
            tcb.rto_deadline = 0
            tcb.retries = 0
            mark(tcb)
        }
        else {
            refuse_segment(stack, tcb.remote, segment)
            return void
        }
    }
    acknowledgement(stack, tcb, segment, data.count)
    if tcb.state == .Free {
        return void
    }
    take_data(stack, tcb, segment, data)
    if tcb.state == .Free {
        return void
    }
    tcp_output(stack, tcb)
}

/**
 * Process the answer to a SYN (RFC 9293 §3.10.7.3).
 *
 * @param stack The stack.
 * @param tcb The connection, SYN-SENT.
 * @param segment What arrived.
 */
syn_sent_arrives :: fn(stack: ptr[mut Stack], tcb: ptr[mut Tcb], segment: ptr[Segment]) {
    flags :: segment.flags
    acks_syn :: flags & TCP_ACK != 0 && seq_lt(tcb.iss, segment.ack) && seq_le(segment.ack, tcb.snd_nxt)
    if flags & TCP_ACK != 0 && !acks_syn {
        if flags & TCP_RST == 0 {
            refuse_segment(stack, tcb.remote, segment)
        }
        return void
    }
    if flags & TCP_RST != 0 {
        if acks_syn {
            end_tcb(stack, tcb, .Refused)
        }
        return void
    }
    if flags & TCP_SYN == 0 {
        return void
    }
    take_syn_options(tcb, segment)
    if tcb.send_scale == 0xff {
        tcb.send_scale = 0
        tcb.receive_scale = 0
    }
    tcb.irs = segment.seq
    tcb.rcv_nxt = segment.seq + 1
    if acks_syn {
        tcb.snd_una = segment.ack
        tcb.state = .Established
        // A SYN-ACK's window isn't scaled
        tcb.snd_wnd = cast[u64](segment.window)
        tcb.snd_wl1 = segment.seq
        tcb.snd_wl2 = segment.ack
        tcb.rto_deadline = 0
        tcb.retries = 0
        if tcb.timestamps && segment.has_timestamps && segment.ts_echo != 0 {
            sample_rtt(tcb, cast[u64](timestamp(stack) - segment.ts_echo) * 1_000_000)
        }
        mark(tcb)
        send_ack(stack, tcb)
        tcp_output(stack, tcb)
    }
    else {
        // A simultaneous open: SYN-RECEIVED, answered with a SYN-ACK
        tcb.state = .SynReceived
        send_syn(stack, tcb, true)
    }
}

/**
 * Process a segment's acknowledgement (RFC 9293 §3.10.7.4, the ACK field): what it acknowledges is freed, the window
 * updated, round trips measured, congestion control moved on, losses found by duplicates and SACK repaired, and the
 * FIN's acknowledgement moves the state on.
 *
 * @param stack The stack.
 * @param tcb The connection.
 * @param segment The segment.
 * @param data_length Its data's length.
 */
acknowledgement :: fn(stack: ptr[mut Stack], tcb: ptr[mut Tcb], segment: ptr[Segment], data_length: usize) {
    ack :: segment.ack
    if seq_lt(tcb.snd_max, ack) {
        // It acknowledges what wasn't sent
        tcb.ack_now = true
        return void
    }
    take_sacks(tcb, segment)
    window :: cast[u64](segment.window) << cast[u64](tcb.send_scale)
    if seq_lt(tcb.snd_una, ack) {
        acked :: ack - tcb.snd_una
        data_acked := cast[u64](acked)
        if tcb.fin_sent && seq_le(tcb.fin_seq + 1, ack) {
            data_acked -= 1
        }
        tcb.acknowledged += data_acked
        tcb.snd_una = ack
        if seq_lt(tcb.snd_nxt, ack) {
            tcb.snd_nxt = ack
        }
        tcb.retries = 0
        tcb.duplicate_acks = 0
        // Round trips: by the echoed timestamp, or the segment timed
        if tcb.timestamps && segment.has_timestamps && segment.ts_echo != 0 {
            sample_rtt(tcb, cast[u64](timestamp(stack) - segment.ts_echo) * 1_000_000)
        }
        else if tcb.timing && seq_le(tcb.timing_seq, ack) {
            tcb.timing = false
            sample_rtt(tcb, stack.now - tcb.timing_sent)
        }
        tcb.rto_deadline = if tcb.snd_una == tcb.snd_max { cast[u64](0) } else { stack.now + tcb.rto }
        if tcb.in_recovery {
            if seq_le(tcb.recover, ack) {
                tcb.in_recovery = false
                tcb.cwnd = tcb.ssthresh
            }
        }
        else {
            grow_window(stack, tcb, data_acked)
        }
        mark(tcb)
    }
    else if ack == tcb.snd_una && data_length == 0 && window == tcb.snd_wnd && tcb.snd_una != tcb.snd_max
        && segment.flags & TCP_FIN == 0 {
        tcb.duplicate_acks += 1
    }
    // Loss: three duplicates, or SACK past three segments (RFC 6675 §5)
    if !tcb.in_recovery && tcb.snd_una != tcb.snd_max && (tcb.duplicate_acks >= 3 || sacked_past(tcb) >= 3 * cast[u64](tcb.mss)) {
        enter_recovery(stack, tcb)
    }
    if seq_lt(tcb.snd_wl1, segment.seq) || (tcb.snd_wl1 == segment.seq && seq_le(tcb.snd_wl2, ack)) {
        tcb.snd_wnd = window
        tcb.snd_wl1 = segment.seq
        tcb.snd_wl2 = ack
    }
    fin_acked :: tcb.fin_sent && seq_le(tcb.fin_seq + 1, ack)
    if fin_acked {
        if tcb.state == .FinWait1 {
            tcb.state = .FinWait2
            mark(tcb)
        }
        else if tcb.state == .Closing {
            enter_time_wait(stack, tcb)
        }
        else if tcb.state == .LastAck {
            end_tcb(stack, tcb, .Closed)
        }
    }
}

/**
 * Take a segment's SACK blocks into the scoreboard: those above snd_una, merged, the newest kept.
 *
 * @param tcb The connection.
 * @param segment The segment.
 */
take_sacks :: fn(tcb: ptr[mut Tcb], segment: ptr[Segment]) {
    for &block in tcb.sacked {
        if seq_le(block.end, tcb.snd_una) || !seq_lt(block.start, block.end) {
            block^ = SackBlock.{}
        }
    }
    if !tcb.sack {
        return void
    }
    for i in cast[usize](0)..<segment.sack_count {
        if i >= segment.sacks.count {
            break
        }
        add_block(view_of(&tcb.sacked[0], tcb.sacked.count), segment.sacks[i], tcb.snd_una, tcb.snd_max)
    }
}

/**
 * Add a range to a list of ranges, merging those it touches; if the list's full, the lowest goes.
 *
 * @param blocks The list, empty ones having start == end.
 * @param block The range.
 * @param low Ranges are kept only above this.
 * @param high And at most this.
 */
add_block :: fn(blocks: mut SackBlock[], block: SackBlock, low: u32, high: u32) {
    start := block.start
    end := block.end
    if !seq_lt(start, end) || seq_le(end, low) || seq_lt(high, end) {
        return void
    }
    if seq_lt(start, low) {
        start = low
    }
    // Merge every block it overlaps or touches
    for &each in blocks {
        if seq_lt(each.start, each.end) && seq_le(each.start, end) && seq_le(start, each.end) {
            if seq_lt(each.start, start) {
                start = each.start
            }
            if seq_lt(end, each.end) {
                end = each.end
            }
            each^ = SackBlock.{}
        }
    }
    for &each in blocks {
        if !seq_lt(each.start, each.end) {
            each^ = SackBlock.{start = start, end = end}
            return void
        }
    }
    // Full: the lowest goes
    lowest := cast[usize](0)
    for each, i in blocks {
        if i < blocks.count && lowest < blocks.count && seq_lt(each.start, blocks[lowest].start) {
            lowest = i
        }
    }
    if lowest < blocks.count {
        blocks[lowest] = SackBlock.{start = start, end = end}
    }
}

/**
 * Give how many bytes the peer has SACKed.
 *
 * @param tcb The connection.
 * @return The bytes.
 */
sacked_past :: fn(tcb: ptr[Tcb]) -> u64 {
    total := cast[u64](0)
    for block in tcb.sacked {
        if seq_lt(block.start, block.end) {
            total += cast[u64](block.end - block.start)
        }
    }
    return total
}

/**
 * Find the next hole to retransmit in recovery: the first sequence number from snd_una, or past what recovery's
 * retransmitted, not SACKed and below the highest SACKed.
 *
 * @param tcb The connection.
 * @return It; null if there's none.
 */
next_hole :: fn(tcb: ptr[Tcb]) -> u32? {
    highest := tcb.snd_una
    for block in tcb.sacked {
        if seq_lt(block.start, block.end) && seq_lt(highest, block.end) {
            highest = block.end
        }
    }
    at := if seq_lt(tcb.rescue, tcb.snd_una) { tcb.snd_una } else { tcb.rescue }
    loop {
        if !seq_lt(at, highest) {
            return null
        }
        covered := false
        for block in tcb.sacked {
            if seq_lt(block.start, block.end) && seq_le(block.start, at) && seq_lt(at, block.end) {
                at = block.end
                covered = true
            }
        }
        if !covered {
            return at
        }
    }
    while true
    return null
}

/**
 * Give how much of a hole to retransmit: to the next SACKed block or the MSS, whichever's less.
 *
 * @param tcb The connection.
 * @param hole Where it starts.
 * @return The bytes; 0 if there's no data there.
 */
hole_length :: fn(tcb: ptr[Tcb], hole: u32) -> u32 {
    end := hole + segment_data(tcb)
    for block in tcb.sacked {
        if seq_lt(block.start, block.end) && seq_lt(hole, block.start) && seq_lt(block.start, end) {
            end = block.start
        }
    }
    data_end :: tcb.snd_una + cast[u32](tcb.written - tcb.acknowledged)
    if seq_lt(data_end, end) {
        end = data_end
    }
    return if seq_lt(hole, end) { end - hole } else { cast[u32](0) }
}

/**
 * Enter loss recovery: the window cut by CUBIC's beta, the first hole retransmitted.
 *
 * @param stack The stack.
 * @param tcb The connection.
 */
enter_recovery :: fn(stack: ptr[mut Stack], tcb: ptr[mut Tcb]) {
    stack.fast_retransmits += 1
    reduce_window(stack, tcb)
    tcb.in_recovery = true
    tcb.recover = tcb.snd_max
    tcb.rescue = tcb.snd_una
    tcb.duplicate_acks = 0
    length :: hole_length(tcb, tcb.snd_una)
    if length > 0 {
        send_data(stack, tcb, tcb.snd_una, length)
        tcb.rescue = tcb.snd_una + length
    }
}

/**
 * Cut the congestion window after a loss, as CUBIC does (RFC 9438 §4.6): to beta of what it was, remembered as W_max.
 *
 * @param stack The stack.
 * @param tcb The connection.
 */
reduce_window :: fn(stack: ptr[mut Stack], tcb: ptr[mut Tcb]) {
    mss :: cast[f64](tcb.mss)
    current :: cast[f64](tcb.cwnd) / mss
    tcb.w_max = current
    reduced :: current * CUBIC_BETA
    tcb.ssthresh = cast[u64](reduced * mss)
    if tcb.ssthresh < 2 * cast[u64](tcb.mss) {
        tcb.ssthresh = 2 * cast[u64](tcb.mss)
    }
    tcb.cwnd = tcb.ssthresh
    tcb.epoch = 0
    tcb.w_est = reduced
}

/**
 * Grow the congestion window for bytes acknowledged: slow start below ssthresh, CUBIC's curve above it (RFC 9438
 * §4.2 to §4.4).
 *
 * @param stack The stack.
 * @param tcb The connection.
 * @param acked The bytes newly acknowledged.
 */
grow_window :: fn(stack: ptr[mut Stack], tcb: ptr[mut Tcb], acked: u64) {
    mss :: cast[u64](tcb.mss)
    if tcb.cwnd < tcb.ssthresh {
        tcb.cwnd += if acked < 2 * mss { acked } else { 2 * mss }
        return void
    }
    segment :: cast[f64](mss)
    current :: cast[f64](tcb.cwnd) / segment
    if tcb.epoch == 0 {
        tcb.epoch = stack.now
        if tcb.w_max < current {
            tcb.w_max = current
        }
        tcb.k = cube_root(tcb.w_max * (1.0 - CUBIC_BETA) / CUBIC_C)
        tcb.w_est = current
    }
    t :: cast[f64](stack.now - tcb.epoch) / 1_000_000_000.0
    rtt :: cast[f64](if tcb.srtt == 0 { INITIAL_RTO } else { tcb.srtt }) / 1_000_000_000.0
    delta :: t + rtt - tcb.k
    target := CUBIC_C * delta * delta * delta + tcb.w_max
    // The Reno-friendly estimate (§4.3)
    tcb.w_est += 3.0 * (1.0 - CUBIC_BETA) / (1.0 + CUBIC_BETA) * cast[f64](acked) / segment / current
    if tcb.w_est > target {
        target = tcb.w_est
    }
    if target > current * 1.5 {
        target = current * 1.5
    }
    if target > current {
        increase :: (target - current) / current * cast[f64](acked)
        tcb.cwnd += cast[u64](increase)
    }
}

/**
 * Give a cube root, by Newton's method.
 *
 * @param x The value, at least 0.
 * @return Its cube root.
 */
cube_root :: fn(x: f64) -> f64 {
    if x <= 0.0 {
        return 0.0
    }
    guess := if x > 1.0 { x / 3.0 } else { 1.0 }
    for i in 0..<60 {
        guess = guess - (guess * guess * guess - x) / (3.0 * guess * guess)
    }
    return guess
}

/**
 * Take a round trip's measurement into the smoothed RTT and the retransmission timeout (RFC 6298 §2).
 *
 * @param tcb The connection.
 * @param rtt The round trip, in nanoseconds.
 */
sample_rtt :: fn(tcb: ptr[mut Tcb], rtt: u64) {
    measured :: if rtt == 0 { cast[u64](1_000_000) } else { rtt }
    if tcb.srtt == 0 {
        tcb.srtt = measured
        tcb.rttvar = measured / 2
    }
    else {
        difference :: if tcb.srtt > measured { tcb.srtt - measured } else { measured - tcb.srtt }
        tcb.rttvar = (3 * tcb.rttvar + difference) / 4
        tcb.srtt = (7 * tcb.srtt + measured) / 8
    }
    rto := tcb.srtt + 4 * tcb.rttvar
    if rto < MIN_RTO {
        rto = MIN_RTO
    }
    if rto > MAX_RTO {
        rto = MAX_RTO
    }
    tcb.rto = rto
}

/**
 * Take a segment's data and FIN: in order into the receive ring, out of order there too, past what's missing, noted
 * for SACK; acknowledged now or soon.
 *
 * @param stack The stack.
 * @param tcb The connection.
 * @param segment The segment.
 * @param data Its data.
 */
take_data :: fn(stack: ptr[mut Stack], tcb: ptr[mut Tcb], segment: ptr[Segment], data: u8[]) {
    receiving :: tcb.state == .Established || tcb.state == .FinWait1 || tcb.state == .FinWait2
    if data.count > 0 && receiving {
        // What fits the window, from rcv_nxt on
        start := segment.seq
        skip := cast[usize](0)
        if seq_lt(start, tcb.rcv_nxt) {
            skip = cast[usize](tcb.rcv_nxt - start)
            start = tcb.rcv_nxt
        }
        window :: receive_window(tcb)
        offset :: cast[u64](start - tcb.rcv_nxt)
        if skip < data.count && offset < window {
            most :: window - offset
            length :: if cast[u64](data.count - skip) < most { data.count - skip } else { cast[usize](most) }
            ring_write(tcb.rings.receive, tcb.delivered + offset, part(data, skip, skip + length))
            end :: start + cast[u32](length)
            if start == tcb.rcv_nxt {
                tcb.rcv_nxt = end
                tcb.delivered += cast[u64](length)
                // Out-of-order data it reaches is in order now
                advance_over_blocks(tcb)
                mark(tcb)
                tcb.unacknowledged_segments += 1
                if tcb.unacknowledged_segments >= 2 || has_blocks(tcb) {
                    tcb.ack_now = true
                }
                else if tcb.ack_deadline == 0 {
                    tcb.ack_deadline = stack.now + DELAYED_ACK
                }
            }
            else {
                add_block(view_of(&tcb.out_of_order[0], tcb.out_of_order.count), SackBlock.{start = start, end = end},
                    tcb.rcv_nxt, tcb.rcv_nxt + cast[u32](window))
                tcb.ack_now = true
            }
        }
        else {
            tcb.ack_now = true
        }
    }
    if segment.flags & TCP_FIN != 0 {
        fin_seq :: segment.seq + cast[u32](data.count)
        if fin_seq == tcb.rcv_nxt && !tcb.peer_finished {
            tcb.rcv_nxt += 1
            tcb.peer_finished = true
            tcb.ack_now = true
            mark(tcb)
            if tcb.state == .SynReceived || tcb.state == .Established {
                tcb.state = .CloseWait
            }
            else if tcb.state == .FinWait1 {
                tcb.state = .Closing
            }
            else if tcb.state == .FinWait2 {
                enter_time_wait(stack, tcb)
            }
        }
        else if tcb.peer_finished {
            tcb.ack_now = true
        }
    }
}

/**
 * Tell whether any out-of-order data is held.
 *
 * @param tcb The connection.
 * @return True if some is.
 */
has_blocks :: fn(tcb: ptr[Tcb]) -> bool {
    for block in tcb.out_of_order {
        if seq_lt(block.start, block.end) {
            return true
        }
    }
    return false
}

/**
 * Move rcv_nxt over out-of-order data it's reached, delivering it.
 *
 * @param tcb The connection.
 */
advance_over_blocks :: fn(tcb: ptr[mut Tcb]) {
    loop {
        moved := false
        for &block in tcb.out_of_order {
            if !seq_lt(block.start, block.end) {
                continue
            }
            if seq_le(block.end, tcb.rcv_nxt) {
                block^ = SackBlock.{}
                continue
            }
            if seq_le(block.start, tcb.rcv_nxt) {
                gained :: block.end - tcb.rcv_nxt
                tcb.rcv_nxt = block.end
                tcb.delivered += cast[u64](gained)
                block^ = SackBlock.{}
                moved = true
            }
        }
        if !moved {
            break
        }
    }
    while true
}

/**
 * Enter TIME-WAIT: the connection's done, told as changed, and freed after TIME_WAIT, acknowledging a FIN sent again
 * meanwhile.
 *
 * @param stack The stack.
 * @param tcb The connection.
 */
enter_time_wait :: fn(stack: ptr[mut Stack], tcb: ptr[mut Tcb]) {
    tcb.state = .TimeWait
    tcb.deadline = stack.now + TIME_WAIT
    tcb.rto_deadline = 0
    mark(tcb)
    event(stack, .Ended(TcpEnded.{connection = connection_number(tcb), why = .Closed, delivered = tcb.delivered,
        acknowledged = tcb.acknowledged}))
}

// ---- Time

/**
 * Do what TCP has due: retransmissions, held acknowledgements, incoming connections never accepted, TIME-WAIT's end.
 *
 * @param stack The stack.
 */
tick_tcp :: fn(stack: ptr[mut Stack]) {
    now :: stack.now
    for &tcb in stack.tcbs {
        if tcb.state == .Free {
            continue
        }
        if tcb.state == .Incoming && now >= tcb.deadline {
            end_tcb(stack, tcb, .NotAccepted)
            continue
        }
        if tcb.state == .TimeWait {
            if now >= tcb.deadline {
                tcb.state = .Free
            }
            continue
        }
        if tcb.ack_deadline != 0 && now >= tcb.ack_deadline {
            tcb.ack_now = true
            tcp_output(stack, tcb)
        }
        if tcb.rto_deadline != 0 && now >= tcb.rto_deadline {
            retransmit(stack, tcb)
        }
    }
}

/**
 * The retransmission timer fired: a SYN sent again, the first unacknowledged segment sent again, or a zero window
 * probed; the timeout doubles, and the window collapses (RFC 6298 §5, RFC 9438 §4.8). Past the tries, it ends.
 *
 * @param stack The stack.
 * @param tcb The connection.
 */
retransmit :: fn(stack: ptr[mut Stack], tcb: ptr[mut Tcb]) {
    tcb.retries += 1
    syn :: tcb.state == .SynSent || tcb.state == .SynReceived
    if tcb.retries > (if syn { cast[u32](SYN_TRIES) } else { cast[u32](DATA_TRIES) }) {
        send_reset(stack, tcb.remote, tcb.local_port, tcb.remote_port, tcb.snd_nxt)
        end_tcb(stack, tcb, .TimedOut)
        return void
    }
    tcb.rto = if tcb.rto * 2 > MAX_RTO { MAX_RTO } else { tcb.rto * 2 }
    tcb.rto_deadline = stack.now + tcb.rto
    tcb.timing = false
    if syn {
        tcb.rto_deadline = 0
        send_syn(stack, tcb, tcb.state == .SynReceived)
        return void
    }
    flight :: tcb.snd_max - tcb.snd_una
    if flight == 0 {
        // A zero window: a byte probes it
        if tcb.written > tcb.acknowledged {
            send_data(stack, tcb, tcb.snd_una, 1)
        }
        return void
    }
    stack.timeouts += 1
    reduce_window(stack, tcb)
    tcb.cwnd = cast[u64](tcb.mss)
    tcb.in_recovery = false
    tcb.duplicate_acks = 0
    for &block in tcb.sacked {
        block^ = SackBlock.{}
    }
    // Go back to the first unacknowledged byte; what follows goes again as the window opens
    tcb.snd_nxt = tcb.snd_una
    // An unacknowledged FIN goes again after the data
    tcb.fin_sent = false
    tcp_output(stack, tcb)
}

/**
 * Go on sending what connections held back while the outbox was full, now that it may have room: its caller calls this
 * once it has taken frames.
 *
 * @param stack The stack.
 */
tcp_resume :: fn(stack: ptr[mut Stack]) {
    for &tcb in stack.tcbs {
        if outbox_full(stack) {
            return void
        }
        if tcb.state == .Established || tcb.state == .CloseWait || tcb.state == .FinWait1 || tcb.state == .Closing
            || tcb.state == .LastAck {
            tcp_output(stack, tcb)
        }
    }
}

/**
 * Give the soonest TCP deadline.
 *
 * @param stack The stack.
 * @param soonest The soonest so far.
 * @return The soonest, with TCP's.
 */
tcp_deadline :: fn(stack: ptr[Stack], soonest: u64) -> u64 {
    result := soonest
    for tcb in stack.tcbs {
        if tcb.state == .Free {
            continue
        }
        if (tcb.state == .Incoming || tcb.state == .TimeWait) && tcb.deadline < result {
            result = tcb.deadline
        }
        if tcb.rto_deadline != 0 && tcb.rto_deadline < result {
            result = tcb.rto_deadline
        }
        if tcb.ack_deadline != 0 && tcb.ack_deadline < result {
            result = tcb.ack_deadline
        }
    }
    return result
}
