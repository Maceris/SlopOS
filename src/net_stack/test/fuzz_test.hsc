package net_stack_test

/*
 * The stack's fuzz targets (decisions/0188, 13h), property tests that tools/fuzz.py runs under hemera --fuzz and
 * that run as tests too: frames of each kind the stack reads, their checksums made right so the parsers past them are
 * reached, fed to a stack over hours; a hostile peer's segments into a live TCP connection; and answers to a lookup's
 * queries. None may break the stack, and its next deadline is always ahead of it after a tick, as a deadline left
 * behind has its caller wake for ever.
 */

import runtime from "base"
import testing from "std"
import net_stack from ".."

/** The host's IPv6 router, link-local. */
ROUTER_V6 :: net_stack.Ipv6.{bytes = u8.[0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2]}
/** All nodes, ff02::1. */
ALL_NODES :: net_stack.Ipv6.{bytes = u8.[0xff, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]}

// ---- Frames

/** Frames of every kind the stack reads, each part drawn, their checksums right, over hours: none breaks it. */
takes_any_checksummed_frames #test :: fn(t: ptr[mut testing.T], source: ptr[mut testing.Source]) -> testing.Outcome {
    stack :: runtime.new(net_stack.Stack)
    defer runtime.free(stack)
    net_stack.start(stack, net_stack.Setup.{mac = HOST_MAC, key = key_of(5)}, 0)
    net_stack.set_ipv4(stack, LEASED_V4, 24, ROUTER_V4)
    // Its link-local address past its duplicate check
    now := 2 * net_stack.SECOND
    net_stack.tick(stack, now)
    drain(stack)
    count :: testing.draw_between(source, 1, 16)
    for i in 0..<count {
        frame : u8[net_stack.MAX_FRAME]
        length :: drawn_frame(stack, source, view_of(&frame[0], frame.count))
        net_stack.receive(stack, view_of(&frame[0], length), now)
        // From a moment to hours on: lifetimes, leases and entries run out
        now += if testing.draw_bool(source) { testing.draw_below(source, 2 * net_stack.SECOND) } else {
            testing.draw_below(source, 20_000) * net_stack.SECOND }
        net_stack.tick(stack, now)
        drain(stack)
        if net_stack.next_deadline(stack) <= now {
            note_due(t, stack, now)
        }
        testing.expect(t, net_stack.next_deadline(stack) > now, "after a tick, the next deadline is ahead")
    }
    return .Ok
}

/** Take every frame and event a stack has, as its caller would. */
drain :: fn(stack: ptr[mut net_stack.Stack]) {
    out : u8[net_stack.MAX_FRAME]
    loop {
        _ = net_stack.take_frame(stack, view_of(&out[0], out.count)) or_break
    }
    loop {
        _ = net_stack.take_event(stack) or_break
    }
}

/**
 * Draw a frame to the host: IPv4 with ICMP, UDP (DHCP's among it) or TCP, or IPv6 with ICMPv6 (neighbour discovery's
 * and router advertisements among it), UDP or TCP, from sources real and impossible, each checksum right.
 *
 * @param stack The host's stack, whose transaction ID and addresses are used.
 * @param source The draws.
 * @param into Where the frame goes.
 * @return Its length.
 */
drawn_frame :: fn(stack: ptr[net_stack.Stack], source: ptr[mut testing.Source], into: mut u8[]) -> usize {
    broadcast :: net_stack.Mac.{bytes = u8.[0xff, 0xff, 0xff, 0xff, 0xff, 0xff]}
    net_stack.put_mac(into, 0, if testing.draw_below(source, 4) == 0 { broadcast } else { HOST_MAC })
    net_stack.put_mac(into, 6, ROUTER_MAC)
    body :: testing.draw_bytes(source, 1200)
    if testing.draw_bool(source) {
        return drawn_v4(stack, source, into, body)
    }
    return drawn_v6(stack, source, into, body)
}

drawn_v4 :: fn(stack: ptr[net_stack.Stack], source: ptr[mut testing.Source], into: mut u8[], body: u8[]) -> usize {
    net_stack.put_u16(into, 12, net_stack.ETHER_IPV4)
    sources :: net_stack.Ipv4.[ROUTER_V4, LEASED_V4, net_stack.Ipv4.{bytes = u8.[10, 0, 2, 255]}, net_stack.Ipv4.{bytes = u8.[255, 255, 255, 255]},
        net_stack.Ipv4.{bytes = u8.[224, 0, 0, 1]}, net_stack.Ipv4.{}, net_stack.Ipv4.{bytes = u8.[10, 0, 2, 77]}, net_stack.Ipv4.{bytes = u8.[127, 0, 0, 1]}]
    destinations :: net_stack.Ipv4.[LEASED_V4, net_stack.Ipv4.{bytes = u8.[255, 255, 255, 255]}, net_stack.Ipv4.{bytes = u8.[10, 0, 2, 255]}]
    from :: sources[cast[usize](testing.draw_below(source, cast[u64](sources.count))) % sources.count]
    to :: destinations[cast[usize](testing.draw_below(source, cast[u64](destinations.count))) % destinations.count]
    protocols :: u8.[net_stack.PROTOCOL_ICMP, net_stack.PROTOCOL_UDP, net_stack.PROTOCOL_TCP]
    protocol :: protocols[cast[usize](testing.draw_below(source, 3)) % protocols.count]
    payload :: part_of(into, 34)
    length := fill(payload, body)
    if protocol == net_stack.PROTOCOL_ICMP {
        length = at_least(length, 8)
        net_stack.put_u8(payload, 0, if testing.draw_bool(source) { cast[u8](8) } else { cast[u8](testing.draw_below(source, 256)) })
        net_stack.put_u16(payload, 2, 0)
        net_stack.put_u16(payload, 2, net_stack.checksum_finish(net_stack.checksum_add(0, part(payload, 0, length))))
    }
    else if protocol == net_stack.PROTOCOL_UDP {
        // DHCP's answer to the host, its transaction ID and hardware address right, half the time
        dhcp :: testing.draw_bool(source)
        if dhcp {
            length = at_least(length, 8 + 240)
            net_stack.put_u16(payload, 0, 67)
            net_stack.put_u16(payload, 2, 68)
            net_stack.put_u8(payload, 8, 2)
            net_stack.put_u32(payload, 8 + 4, stack.xid)
            net_stack.put_mac(payload, 8 + 28, HOST_MAC)
            net_stack.put_u32(payload, 8 + 236, 0x63825363)
        }
        length = at_least(length, 8)
        net_stack.put_u16(payload, 4, cast[u16](length))
        net_stack.put_u16(payload, 6, 0)
        net_stack.put_u16(payload, 6, net_stack.checksum_finish(net_stack.pseudo_sum_v4(from, to, protocol, length)
            + net_stack.checksum_add(0, part(payload, 0, length))))
    }
    else {
        length = at_least(length, 20)
        net_stack.put_u8(payload, 12, cast[u8](5 + testing.draw_below(source, 11)) << 4)
        net_stack.put_u16(payload, 16, 0)
        net_stack.put_u16(payload, 16, net_stack.checksum_finish(net_stack.pseudo_sum_v4(from, to, protocol, length)
            + net_stack.checksum_add(0, part(payload, 0, length))))
    }
    header :: part_of(into, 14)
    net_stack.put_u8(header, 0, 0x45)
    net_stack.put_u8(header, 1, 0)
    net_stack.put_u16(header, 2, cast[u16](20 + length))
    net_stack.put_u32(header, 4, 0)
    net_stack.put_u8(header, 8, 64)
    net_stack.put_u8(header, 9, protocol)
    net_stack.put_u16(header, 10, 0)
    net_stack.put_bytes(header, 12, view_of(&from.bytes[0], 4))
    net_stack.put_bytes(header, 16, view_of(&to.bytes[0], 4))
    net_stack.put_u16(header, 10, net_stack.checksum_finish(net_stack.checksum_add(0, part(header, 0, 20))))
    return 34 + length
}

drawn_v6 :: fn(stack: ptr[net_stack.Stack], source: ptr[mut testing.Source], into: mut u8[], body: u8[]) -> usize {
    net_stack.put_u16(into, 12, net_stack.ETHER_IPV6)
    other := ROUTER_V6
    other.bytes[15] = cast[u8](testing.draw_below(source, 256))
    global := net_stack.Ipv6.{}
    global.bytes[0] = 0x20
    global.bytes[1] = 0x01
    global.bytes[2] = 0x0d
    global.bytes[3] = 0xb8
    global.bytes[15] = 9
    sources :: net_stack.Ipv6.[ROUTER_V6, other, ALL_NODES, net_stack.Ipv6.{}, stack.link_local.address, global]
    destinations :: net_stack.Ipv6.[stack.link_local.address, ALL_NODES]
    from :: sources[cast[usize](testing.draw_below(source, cast[u64](sources.count))) % sources.count]
    to :: destinations[cast[usize](testing.draw_below(source, cast[u64](destinations.count))) % destinations.count]
    nexts :: u8.[net_stack.PROTOCOL_ICMPV6, net_stack.PROTOCOL_ICMPV6, net_stack.PROTOCOL_UDP, net_stack.PROTOCOL_TCP]
    next :: nexts[cast[usize](testing.draw_below(source, 4)) % nexts.count]
    payload :: part_of(into, 54)
    length := fill(payload, body)
    checksum_at := cast[usize](16)
    if next == net_stack.PROTOCOL_ICMPV6 {
        length = at_least(length, 16)
        kinds :: u8.[133, 134, 134, 135, 136, 137, 128, 129]
        kind :: kinds[cast[usize](testing.draw_below(source, cast[u64](kinds.count))) % kinds.count]
        net_stack.put_u8(payload, 0, kind)
        net_stack.put_u8(payload, 1, 0)
        // A router advertisement with a prefix to take an address from, a short lifetime, and DNS servers
        if kind == 134 && testing.draw_bool(source) {
            length = at_least(length, 16 + 32 + 40)
            net_stack.put_u16(payload, 6, cast[u16](testing.draw_below(source, 3)) * 600)
            prefix :: part_of(payload, 16)
            net_stack.put_u8(prefix, 0, 3)
            net_stack.put_u8(prefix, 1, 4)
            net_stack.put_u8(prefix, 2, 64)
            net_stack.put_u8(prefix, 3, 0xc0)
            valid :: cast[u32](testing.draw_below(source, 20_000))
            net_stack.put_u32(prefix, 4, valid)
            net_stack.put_u32(prefix, 8, valid / 2)
            net_stack.put_bytes(prefix, 16, view_of(&global.bytes[0], 8))
            dns :: part_of(payload, 48)
            net_stack.put_u8(dns, 0, 25)
            net_stack.put_u8(dns, 1, 5)
            net_stack.put_u32(dns, 4, cast[u32](testing.draw_below(source, 4000)))
        }
        checksum_at = 2
    }
    else if next == net_stack.PROTOCOL_UDP {
        length = at_least(length, 8)
        net_stack.put_u16(payload, 4, cast[u16](length))
        checksum_at = 6
    }
    else {
        length = at_least(length, 20)
        net_stack.put_u8(payload, 12, cast[u8](5 + testing.draw_below(source, 11)) << 4)
    }
    net_stack.put_u16(payload, checksum_at, 0)
    net_stack.put_u16(payload, checksum_at, net_stack.checksum_finish(net_stack.pseudo_sum_v6(from, to, next, length)
        + net_stack.checksum_add(0, part(payload, 0, length))))
    header :: part_of(into, 14)
    net_stack.put_u32(header, 0, 0x6000_0000)
    net_stack.put_u16(header, 4, cast[u16](length))
    net_stack.put_u8(header, 6, next)
    net_stack.put_u8(header, 7, if testing.draw_below(source, 8) != 0 { cast[u8](255) } else { cast[u8](64) })
    net_stack.put_bytes(header, 8, view_of(&from.bytes[0], 16))
    net_stack.put_bytes(header, 24, view_of(&to.bytes[0], 16))
    return 54 + length
}

/** The bytes from an offset on, or none past the end. */
part_of :: fn(bytes: mut u8[], from: usize) -> mut u8[] {
    return if from < bytes.count { bytes[from..<bytes.count] } else { bytes[0..<0] }
}

/** The bytes from one offset to another, cut to fit. */
part :: fn(bytes: u8[], from: usize, to: usize) -> u8[] {
    if to <= bytes.count && from < to {
        return bytes[from..<to]
    }
    return if from < bytes.count { bytes[from..<bytes.count] } else { bytes[0..<0] }
}

/** Copy a body in, as much as fits, and give its length. */
fill :: fn(into: mut u8[], body: u8[]) -> usize {
    count :: if body.count < into.count { body.count } else { into.count }
    for i in 0..<count {
        if i < into.count && i < body.count {
            into[i] = body[i]
        }
    }
    return count
}

/** A length raised to a least, its bytes past what was drawn zeros as the frame was. */
at_least :: fn(length: usize, least: usize) -> usize {
    return if length < least { least } else { length }
}

// ---- TCP

/**
 * A hostile peer's segments into a live connection, its numbers near the connection's own: any flags, options and
 * data. The connection may end, but its totals stay sound, and the stack's next deadline is ahead after each tick.
 */
withstands_a_hostile_peer #test :: fn(t: ptr[mut testing.T], source: ptr[mut testing.Source]) -> testing.Outcome {
    pair :: make_pair(3, Faults.{})
    defer runtime.free(pair)
    for &app in pair.apps {
        app.to_send = testing.draw_below(source, 300_000)
    }
    first :: &pair.apps[0]
    match net_stack.tcp_connect(&pair.a, .V4(SECOND_V4), LISTEN_PORT, rings_of(first)) {
        case Some(connection) => {
            first.connection = connection
            first.open = true
        }
        case None => return .Ok
    }
    run_pair(pair, 20 * MILLISECOND, false)
    steps :: testing.draw_between(source, 1, 40)
    for step in 0..<steps {
        inject(pair, source)
        run_pair(pair, testing.draw_between(source, cast[u64](1), cast[u64](300)) * MILLISECOND, false)
        sound(t, &pair.a, &pair.apps[0], pair.now)
        sound(t, &pair.b, &pair.apps[1], pair.now)
    }
    return .Ok
}

/**
 * Send a drawn segment to the first stack's connection as if from its peer: the second stack sends it, so its
 * checksum's right.
 */
inject :: fn(pair: ptr[mut Pair], source: ptr[mut testing.Source]) {
    connection :: pair.apps[0].connection
    index :: cast[usize](connection & 0xffff)
    if index >= pair.a.tcbs.count {
        return void
    }
    tcb :: &pair.a.tcbs[index]
    segment : u8[1500]
    bytes :: view_of(&segment[0], segment.count)
    options :: cast[usize](testing.draw_below(source, 11)) * 4
    data :: testing.draw_bytes(source, 1000)
    length :: 20 + options + data.count
    net_stack.put_u16(bytes, 0, LISTEN_PORT)
    net_stack.put_u16(bytes, 2, tcb.local_port)
    net_stack.put_u32(bytes, 4, near(source, tcb.rcv_nxt))
    net_stack.put_u32(bytes, 8, near(source, tcb.snd_una))
    net_stack.put_u8(bytes, 12, cast[u8](5 + options / 4) << 4)
    net_stack.put_u8(bytes, 13, cast[u8](testing.draw_below(source, 64)))
    net_stack.put_u16(bytes, 14, cast[u16](testing.draw_below(source, 65536)))
    for i in 0..<options {
        net_stack.put_u8(bytes, 20 + i, cast[u8](testing.draw_below(source, 256)))
    }
    net_stack.put_bytes(bytes, 20 + options, data)
    net_stack.send_tcp(&pair.b, .V4(FIRST_V4), first_of(bytes, length))
}

/** A sequence number near one: at it, a little off, at the window's edges, half the space away, or anything. */
near :: fn(source: ptr[mut testing.Source], number: u32) -> u32 {
    pick :: testing.draw_below(source, 6)
    if pick == 0 {
        return number
    }
    if pick == 1 {
        return number + cast[u32](testing.draw_below(source, 2000))
    }
    if pick == 2 {
        return number - cast[u32](testing.draw_below(source, 2000))
    }
    if pick == 3 {
        return number + cast[u32](testing.draw_below(source, 1 << 20))
    }
    if pick == 4 {
        return number + 0x8000_0000
    }
    return cast[u32](testing.draw_below(source, cast[u64](1) << 32))
}

/** Check what a connection's totals hold, and that the stack's next deadline is ahead once it's ticked. */
sound :: fn(t: ptr[mut testing.T], stack: ptr[mut net_stack.Stack], app: ptr[App], now: u64) {
    net_stack.tick(stack, now)
    testing.expect(t, net_stack.next_deadline(stack) > now, "after a tick, the next deadline is ahead")
    if !app.open || app.ended {
        return void
    }
    status :: net_stack.tcp_status(stack, app.connection)
    if status.ended {
        return void
    }
    testing.expect(t, status.acknowledged <= app.written, "no more acknowledged than written")
    testing.expect(t, status.delivered >= app.read && status.delivered - app.read <= RING_BYTES, "no more delivered than the ring holds")
}

// ---- DNS

/** Answers to a lookup's queries, from its server, of any bytes past a right header: the lookup ends, sound. */
takes_any_answer #test :: fn(t: ptr[mut testing.T], source: ptr[mut testing.Source]) -> testing.Outcome {
    stack :: runtime.new(net_stack.Stack)
    defer runtime.free(stack)
    net_stack.start(stack, net_stack.Setup.{mac = HOST_MAC, key = key_of(7), dhcp = false, ipv6 = false}, 0)
    net_stack.set_ipv4(stack, LEASED_V4, 24, ROUTER_V4)
    _ = net_stack.set_dns_server(stack, .V4(ROUTER_V4), net_stack.DNS_PORT)
    lookup :: net_stack.resolve(stack, string_bytes("peer.example.test"), true, true) or_return .Ok
    net_stack.tick(stack, 1)
    drain(stack)
    index :: cast[usize](lookup & 0xffff)
    count :: testing.draw_between(source, 1, 6)
    for i in 0..<count {
        if index >= stack.resolver.lookups.count {
            break
        }
        which :: cast[usize](testing.draw_below(source, 2)) % stack.resolver.lookups[index].queries.count
        query :: stack.resolver.lookups[index].queries[which]
        if query.state != .Asking {
            continue
        }
        message : u8[600]
        bytes :: view_of(&message[0], message.count)
        drawn :: testing.draw_bytes(source, 500)
        length :: fill(part_of(bytes, 0), drawn)
        // A header and question that pass, the answers after them drawn, as often as not
        if testing.draw_bool(source) {
            net_stack.put_u16(bytes, 0, query.id)
            net_stack.put_u16(bytes, 2, if testing.draw_bool(source) { cast[u16](0x8180) } else { cast[u16](testing.draw_below(source, 65536)) })
            net_stack.put_u16(bytes, 4, 1)
            net_stack.put_u16(bytes, 6, cast[u16](testing.draw_below(source, 12)))
            name := u8.[4, 0x70, 0x65, 0x65, 0x72, 7, 0x65, 0x78, 0x61, 0x6d, 0x70, 0x6c, 0x65, 4, 0x74, 0x65, 0x73, 0x74, 0]
            net_stack.put_bytes(bytes, 12, name[0..<name.count])
            net_stack.put_u16(bytes, 12 + name.count, if which == 0 { cast[u16](1) } else { cast[u16](28) })
            net_stack.put_u16(bytes, 14 + name.count, 1)
        }
        net_stack.dns_received(stack, query.socket, .V4(ROUTER_V4), net_stack.DNS_PORT, part(bytes, 0, at_least(length, 12 + 23)))
    }
    // Answered or not, it's done within its tries' time, and what it found fits
    now := cast[u64](1)
    loop {
        now += 500 * MILLISECOND
        net_stack.tick(stack, now)
        drain(stack)
        match net_stack.take_resolution(stack, lookup) {
            case Some(result) => {
                testing.expect(t, result.count <= result.addresses.count, "what it found fits")
                return .Ok
            }
            case None => {}
        }
    }
    while now < 60 * net_stack.SECOND
    testing.fail(t, "a lookup is done within a minute")
    return .Ok
}

/** The first bytes, as many as there are if fewer. */
first_of :: fn(bytes: mut u8[], count: usize) -> mut u8[] {
    return if count <= bytes.count { bytes[0..<count] } else { bytes }
}

/** Note which of a stack's deadlines aren't ahead of now, so a failed check says which. */
note_due :: fn(t: ptr[mut testing.T], stack: ptr[net_stack.Stack], now: u64) {
    if stack.dhcp != .Off && stack.dhcp_deadline <= now {
        testing.note(t, "dhcp % at %, state %", stack.dhcp_deadline, now, stack.dhcp)
    }
    for each, i in stack.arp {
        if each.state != .Free && each.deadline <= now {
            testing.note(t, "arp % % % tries %", i, each.state, each.deadline, each.tries)
        }
    }
    for each, i in stack.neighbours {
        if each.state != .Free && each.deadline <= now {
            testing.note(t, "neighbour % % % tries %", i, each.state, each.deadline, each.tries)
        }
    }
    if stack.link_local.state == .Tentative && stack.link_local.deadline <= now {
        testing.note(t, "link-local %", stack.link_local.deadline)
    }
    for each, i in stack.globals {
        if each.state != .Free && each.deadline != 0 && each.deadline <= now {
            testing.note(t, "global % % %", i, each.state, each.deadline)
        }
    }
    if stack.next_solicitation != 0 && stack.next_solicitation <= now {
        testing.note(t, "solicitation %", stack.next_solicitation)
    }
    testing.note(t, "dns %, tcp %, now %", net_stack.dns_deadline(stack), net_stack.tcp_deadline(stack, ~cast[u64](0)), now)
}
