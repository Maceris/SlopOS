package net_stack_test

/*
 * TCP's tests: two stacks on a simulated link, each with an application that writes a pattern into its connection's
 * send ring as room allows, and checks every byte it reads from its receive ring against the pattern its peer writes.
 */

import runtime from "base"
import testing from "std"
import net_stack from ".."

/** Each ring's size: 64 KiB. */
RING_BYTES :: 65536
/** The port the second stack listens on. */
LISTEN_PORT : u16 : 7000
/** The two stacks' IPv4 addresses. */
FIRST_V4 :: net_stack.Ipv4.{bytes = u8.[10, 0, 0, 1]}
SECOND_V4 :: net_stack.Ipv4.{bytes = u8.[10, 0, 0, 2]}
FIRST_MAC :: net_stack.Mac.{bytes = u8.[2, 0, 0, 0, 0, 1]}
SECOND_MAC :: net_stack.Mac.{bytes = u8.[2, 0, 0, 0, 0, 2]}

/** An application's end of a connection. */
App :: struct {
    connection : u32,
    open : bool,
    send : u8[RING_BYTES],
    receive : u8[RING_BYTES],
    /** How many bytes it writes in all, then finishes. */
    to_send : u64,
    written : u64,
    finished : bool,
    read : u64,
    /** The seed of the pattern it writes, and of the one it expects. */
    sends_seed : u64,
    expects_seed : u64,
    /** Bytes read that weren't the pattern. */
    wrong : u64,
    /** Whether, and why, its connection ended, and what it had delivered. */
    ended : bool,
    final_delivered : u64,
    why : net_stack.TcpEnding,
    peer_finished : bool,
    /** Whether it reads at all; a stalled one tests the zero window. */
    reading : bool,
}

/** Two stacks on a link, and an application each. */
Pair :: struct {
    a : net_stack.Stack,
    b : net_stack.Stack,
    apps : App[2],
    flying : Flying[IN_FLIGHT],
    now : u64,
    random : u64,
    faults : Faults,
    listener : u32,
}

/**
 * Give the pattern's byte at an offset.
 *
 * @param seed The pattern's seed.
 * @param offset The offset.
 * @return The byte.
 */
pattern :: fn(seed: u64, offset: u64) -> u8 {
    return cast[u8]((offset * 131 + seed * 7 + (offset >> 8)) & 0xff)
}

/**
 * Give an address's value, for a ring.
 *
 * @param bytes The ring's first byte.
 * @return Its address.
 */
address_of :: fn(bytes: ptr[mut u8]) -> u64 {
    return cast[u64](cast[uintptr](bytes))
}

/**
 * Give an application's rings.
 *
 * @param app The application.
 * @return Its rings, by address.
 */
rings_of :: fn(app: ptr[mut App]) -> net_stack.TcpRings {
    return net_stack.TcpRings.{send = net_stack.Ring.{at = address_of(&app.send[0]), bytes = RING_BYTES},
        receive = net_stack.Ring.{at = address_of(&app.receive[0]), bytes = RING_BYTES}}
}

/**
 * Make a pair: both stacks with addresses set by hand, and IPv6's link-local ones, the second listening.
 *
 * @param seed The seed.
 * @param faults How the link misbehaves.
 * @return The pair, on the heap, the caller's to free.
 */
make_pair :: fn(seed: u64, faults: Faults) -> ptr[mut Pair] {
    pair :: runtime.new(Pair)
    pair.random = seed | 1
    pair.faults = faults
    net_stack.start(&pair.a, net_stack.Setup.{mac = FIRST_MAC, seed = seed * 3 + 1, dhcp = false}, 0)
    net_stack.start(&pair.b, net_stack.Setup.{mac = SECOND_MAC, seed = seed * 5 + 2, dhcp = false}, 0)
    net_stack.set_ipv4(&pair.a, FIRST_V4, 24, net_stack.Ipv4.{})
    net_stack.set_ipv4(&pair.b, SECOND_V4, 24, net_stack.Ipv4.{})
    pair.listener = net_stack.tcp_listen(&pair.b, LISTEN_PORT) or_else 0
    for &app, i in pair.apps {
        app.reading = true
        app.sends_seed = cast[u64](i) + seed * 10
        app.expects_seed = cast[u64](1 - i) + seed * 10
    }
    return pair
}

/**
 * Draw a number from the pair's generator.
 *
 * @param pair The pair.
 * @return The number.
 */
draw_pair :: fn(pair: ptr[mut Pair]) -> u64 {
    x := pair.random
    x = x ~ (x >> 12)
    x = x ~ (x << 25)
    x = x ~ (x >> 27)
    pair.random = x
    return x * 0x2545f4914f6cdd1d
}

/**
 * Put a frame on the link, as the faults have it.
 *
 * @param pair The pair.
 * @param bytes The frame.
 * @param to 0 for the first stack, 1 for the second.
 */
send_pair :: fn(pair: ptr[mut Pair], bytes: u8[], to: u32) {
    if draw_pair(pair) % 100 < pair.faults.drop {
        return void
    }
    copies :: if draw_pair(pair) % 100 < pair.faults.duplicate { 2 } else { 1 }
    for copy in 0..<copies {
        for &slot in pair.flying {
            if slot.length == 0 {
                delay :: if pair.faults.most_delay == 0 { cast[u64](0) } else { draw_pair(pair) % pair.faults.most_delay }
                slot.length = bytes.count
                slot.to = to
                slot.arrives = pair.now + delay
                net_stack.put_bytes(view_of(&slot.bytes[0], slot.bytes.count), 0, bytes)
                break
            }
        }
    }
}

/**
 * Move both stacks' frames onto the link.
 *
 * @param pair The pair.
 */
pair_frames :: fn(pair: ptr[mut Pair]) {
    frame : u8[net_stack.MAX_FRAME]
    into :: view_of(&frame[0], frame.count)
    loop {
        length :: net_stack.take_frame(&pair.a, into) or_break
        send_pair(pair, net_stack.part(into, 0, length), 1)
    }
    loop {
        length :: net_stack.take_frame(&pair.b, into) or_break
        send_pair(pair, net_stack.part(into, 0, length), 0)
    }
}

/**
 * Deliver every frame due.
 *
 * @param pair The pair.
 */
pair_deliver :: fn(pair: ptr[mut Pair]) {
    loop {
        soonest := cast[usize](IN_FLIGHT)
        for slot, i in pair.flying {
            if slot.length > 0 && slot.arrives <= pair.now && (soonest >= pair.flying.count || slot.arrives < pair.flying[soonest].arrives) {
                soonest = i
            }
        }
        if soonest >= pair.flying.count {
            return void
        }
        slot :: &pair.flying[soonest]
        length :: slot.length
        slot.length = 0
        frame :: view_of(&slot.bytes[0], length)
        if slot.to == 0 {
            net_stack.receive(&pair.a, frame, pair.now)
        }
        else {
            net_stack.receive(&pair.b, frame, pair.now)
        }
        pair_frames(pair)
    }
}

/**
 * Run an application: take its stack's events, read what's arrived, and write what there's room for.
 *
 * @param stack Its stack.
 * @param app The application.
 * @param accepting Whether it accepts incoming connections.
 */
run_app :: fn(stack: ptr[mut net_stack.Stack], app: ptr[mut App], accepting: bool) {
    loop {
        happened :: net_stack.take_event(stack) or_break
        match happened {
            case Incoming(incoming) => {
                if accepting && !app.open && net_stack.tcp_accept(stack, incoming.connection, rings_of(app)) {
                    app.connection = incoming.connection
                    app.open = true
                }
            }
            case Ended(ended) => {
                if app.open && ended.connection == app.connection {
                    app.ended = true
                    app.why = ended.why
                    app.final_delivered = ended.delivered
                }
            }
            case _ => {}
        }
    }
    loop {
        _ = net_stack.take_changed(stack) or_break
    }
    if !app.open {
        return void
    }
    status :: net_stack.tcp_status(stack, app.connection)
    // An ended connection's last bytes are still in the ring
    delivered :: if app.ended { app.final_delivered } else { status.delivered }
    if app.reading && delivered > app.read {
        for offset in app.read..<delivered {
            got :: app.receive[cast[usize](offset % RING_BYTES)]
            if got != pattern(app.expects_seed, offset) {
                app.wrong += 1
            }
        }
        app.read = delivered
        net_stack.tcp_read(stack, app.connection, app.read)
    }
    if app.ended {
        return void
    }
    app.peer_finished = status.peer_finished
    if status.state == .Established || status.state == .CloseWait {
        room :: RING_BYTES - (app.written - status.acknowledged)
        wanted :: app.to_send - app.written
        count :: if wanted < room { wanted } else { room }
        if count > 0 {
            for offset in app.written..<app.written + count {
                app.send[cast[usize](offset % RING_BYTES)] = pattern(app.sends_seed, offset)
            }
            app.written += count
            net_stack.tcp_wrote(stack, app.connection, app.written)
        }
        if app.written == app.to_send && !app.finished {
            app.finished = true
            net_stack.tcp_finish(stack, app.connection)
        }
    }
}

/**
 * Run the pair for a while, a millisecond at a time.
 *
 * @param pair The pair.
 * @param nanoseconds How long.
 * @param until_ended Whether to stop once both applications' connections have ended.
 */
run_pair :: fn(pair: ptr[mut Pair], nanoseconds: u64, until_ended: bool) {
    end :: pair.now + nanoseconds
    loop {
        pair.now += MILLISECOND
        pair_deliver(pair)
        net_stack.tick(&pair.a, pair.now)
        net_stack.tick(&pair.b, pair.now)
        run_app(&pair.a, &pair.apps[0], false)
        run_app(&pair.b, &pair.apps[1], true)
        pair_frames(pair)
        if until_ended && pair.apps[0].ended && pair.apps[1].ended {
            break
        }
    }
    while pair.now < end
}

/**
 * Connect the first stack's application to the second's, exchange bytes each way, and check them, and that both
 * close.
 *
 * @param t The test's state.
 * @param seed The seed.
 * @param faults How the link misbehaves.
 * @param bytes How many bytes each way.
 * @param v6 Whether over IPv6, between link-local addresses; else IPv4.
 */
exchange :: fn(t: ptr[mut testing.T], seed: u64, faults: Faults, bytes: u64, v6: bool) {
    pair :: make_pair(seed, faults)
    defer runtime.free(pair)
    // IPv6's link-local addresses, past their duplicate checks
    run_pair(pair, 2 * net_stack.SECOND, false)
    to :: if v6 { net_stack.IpAddress.V6(pair.b.link_local.address) } else { net_stack.IpAddress.V4(SECOND_V4) }
    for &app in pair.apps {
        app.to_send = bytes
    }
    first :: &pair.apps[0]
    match net_stack.tcp_connect(&pair.a, to, LISTEN_PORT, rings_of(first)) {
        case Some(connection) => {
            first.connection = connection
            first.open = true
        }
        case None => {
            check(t, false, "a connection is made", seed)
            return void
        }
    }
    run_pair(pair, 600 * net_stack.SECOND, true)
    for app, i in pair.apps {
        if app.why != .Closed || app.read != bytes {
            testing.note(t, "seed % app %: ended %, why %, read %, written %, open %", seed, i, app.ended, app.why, app.read, app.written, app.open)
        }
        check(t, app.ended, "each connection ends", seed)
        check(t, app.why == .Closed, "each closes, rather than failing", seed)
        check(t, app.read == bytes, "each reads every byte", seed)
        check(t, app.wrong == 0, "each reads the bytes written", seed)
        check(t, app.peer_finished || app.why == .Closed, "each sees its peer finish", seed)
    }
}

exchanges_bytes_on_a_clean_link #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    exchange(t, 1, Faults.{}, 200_000, false)
    exchange(t, 2, Faults.{}, 200_000, true)
    return .Ok
}

exchanges_bytes_on_a_lossy_link #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    for seed in cast[u64](1)..<11 {
        exchange(t, seed, Faults.{drop = 5, duplicate = 5, most_delay = 20 * MILLISECOND}, 200_000, seed % 2 == 0)
    }
    return .Ok
}

/** A connection to a port nobody listens on is refused. */
refuses_a_closed_port #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    pair :: make_pair(3, Faults.{})
    defer runtime.free(pair)
    first :: &pair.apps[0]
    first.connection = net_stack.tcp_connect(&pair.a, .V4(SECOND_V4), LISTEN_PORT + 1, rings_of(first)) or_else 0
    first.open = true
    run_pair(pair, 5 * net_stack.SECOND, false)
    testing.expect(t, first.ended, "it ends")
    testing.expect(t, first.why == .Refused, "refused")
    return .Ok
}

/** A connection to a peer that answers nothing times out, after its SYN's tries. */
times_out_without_answers #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    pair :: make_pair(4, Faults.{drop = 100})
    defer runtime.free(pair)
    first :: &pair.apps[0]
    first.connection = net_stack.tcp_connect(&pair.a, .V4(SECOND_V4), LISTEN_PORT, rings_of(first)) or_else 0
    first.open = true
    run_pair(pair, 300 * net_stack.SECOND, false)
    testing.expect(t, first.ended, "it ends")
    testing.expect(t, first.why == .TimedOut, "timed out")
    return .Ok
}

/** A connection aborted is reset at its peer. */
resets_the_peer_on_abort #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    pair :: make_pair(5, Faults.{})
    defer runtime.free(pair)
    // Each with more to send than a second takes, so neither has closed when it's aborted
    pair.apps[0].to_send = 1 << 40
    pair.apps[1].to_send = 1 << 40
    first :: &pair.apps[0]
    first.connection = net_stack.tcp_connect(&pair.a, .V4(SECOND_V4), LISTEN_PORT, rings_of(first)) or_else 0
    first.open = true
    run_pair(pair, net_stack.SECOND, false)
    testing.expect(t, pair.apps[1].open, "accepted")
    net_stack.tcp_abort(&pair.a, first.connection)
    run_pair(pair, net_stack.SECOND, false)
    testing.expect(t, pair.apps[1].ended, "the peer's ends")
    testing.expect(t, pair.apps[1].why == .Reset, "reset")
    return .Ok
}

/** A reader that stops reading closes its window; the writer waits, probing, and goes on once it reads again. */
waits_on_a_closed_window #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    pair :: make_pair(6, Faults.{})
    defer runtime.free(pair)
    pair.apps[0].to_send = 300_000
    pair.apps[1].to_send = 0
    pair.apps[1].reading = false
    first :: &pair.apps[0]
    first.connection = net_stack.tcp_connect(&pair.a, .V4(SECOND_V4), LISTEN_PORT, rings_of(first)) or_else 0
    first.open = true
    run_pair(pair, 30 * net_stack.SECOND, false)
    status :: net_stack.tcp_status(&pair.b, pair.apps[1].connection)
    testing.expect_eq(t, status.delivered, cast[u64](RING_BYTES), "the receiver's ring fills, and no more arrives")
    testing.expect(t, !first.ended, "the writer waits")
    pair.apps[1].reading = true
    run_pair(pair, 600 * net_stack.SECOND, true)
    testing.expect_eq(t, pair.apps[1].read, 300_000, "every byte arrives once it reads")
    testing.expect_eq(t, pair.apps[1].wrong, 0, "as written")
    return .Ok
}

/** A listener's SYN-ACK carries the MSS, SACK permitted, timestamps and a window scale, as the SYN offered them. */
answers_a_syn_with_its_options #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    pair :: make_pair(7, Faults.{})
    defer runtime.free(pair)
    first :: &pair.apps[0]
    // The second's MAC address known first, so the first frame is the SYN
    _ = net_stack.ping(&pair.a, .V4(SECOND_V4))
    run_pair(pair, net_stack.SECOND, false)
    first.connection = net_stack.tcp_connect(&pair.a, .V4(SECOND_V4), LISTEN_PORT, rings_of(first)) or_else 0
    first.open = true
    // The SYN, straight to the second stack, and its answer read back
    frame : u8[net_stack.MAX_FRAME]
    into :: view_of(&frame[0], frame.count)
    syn_length :: net_stack.take_frame(&pair.a, into) or_else 0
    net_stack.receive(&pair.b, net_stack.part(into, 0, syn_length), 1)
    run_app(&pair.b, &pair.apps[1], true)
    answer_length :: net_stack.take_frame(&pair.b, into) or_else 0
    answer :: net_stack.part(into, net_stack.ETHERNET_HEADER + net_stack.IPV4_HEADER, answer_length)
    segment :: net_stack.read_segment(answer) or_else net_stack.Segment.{}
    testing.expect_eq(t, segment.flags, net_stack.TCP_SYN | net_stack.TCP_ACK, "a SYN-ACK")
    testing.expect_eq(t, segment.mss, 1460, "its MSS")
    testing.expect(t, segment.sack_permitted, "SACK permitted")
    testing.expect(t, segment.has_timestamps, "timestamps")
    testing.expect_eq(t, segment.window_scale, 1, "a window scale, 1 for a 64 KiB ring")
    return .Ok
}

/** Datagrams go between sockets over both families, and an answer finds its way back to the sender's port. */
exchanges_datagrams #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    pair :: make_pair(8, Faults.{})
    defer runtime.free(pair)
    run_pair(pair, 2 * net_stack.SECOND, false)
    server :: net_stack.udp_open(&pair.b, 9000) or_else 0
    client :: net_stack.udp_open(&pair.a, 0) or_else 0
    testing.expect(t, server != 0 && client != 0, "the sockets open")
    testing.expect(t, net_stack.udp_open(&pair.b, 9000) is_none, "a port has one socket")
    message :: "a datagram"
    for family in 0..<2 {
        to :: if family == 0 { net_stack.IpAddress.V4(SECOND_V4) } else { net_stack.IpAddress.V6(pair.b.link_local.address) }
        testing.expect(t, net_stack.udp_send(&pair.a, client, to, 9000, string_bytes(message)), "sent")
        run_pair(pair, 100 * MILLISECOND, false)
        testing.expect_eq(t, net_stack.take_ready(&pair.b) or_else 0, server, "the server's socket is ready")
        into : u8[net_stack.MAX_DATAGRAM]
        got :: net_stack.take_datagram(&pair.b, server, view_of(&into[0], into.count)) or_else net_stack.DatagramFrom.{}
        testing.expect_eq(t, string_of(&into[0], got.length), message, "the datagram arrives whole")
        testing.expect_eq(t, got.from_port, net_stack.udp_port(&pair.a, client), "from the client's port")
        // Answered to where it came from
        testing.expect(t, net_stack.udp_send(&pair.b, server, got.from, got.from_port, string_bytes("an answer")), "answered")
        run_pair(pair, 100 * MILLISECOND, false)
        answer :: net_stack.take_datagram(&pair.a, client, view_of(&into[0], into.count)) or_else net_stack.DatagramFrom.{}
        testing.expect_eq(t, string_of(&into[0], answer.length), "an answer", "the answer arrives")
    }
    return .Ok
}
