/**
 * The network layer's tests (tools/unit_tests.py, decisions/0175, 0188): stacks on a simulated link that drops,
 * duplicates, delays and so reorders frames, seeded so a failure replays; and frames made at random, which have to be
 * taken without harm.
 *
 * The link joins a host, the stack tested, and a router: another stack, with its addresses set by hand, which answers
 * ARP, neighbour discovery and pings, while the test plays its DHCP server and sends its router advertisements.
 */
package net_stack_test

import runtime from "base"
import testing from "std"
import net_stack from ".."

/** How many frames can be on the link at once; past them, the newest are lost. */
IN_FLIGHT :: 256
/** A millisecond, in nanoseconds. */
MILLISECOND : u64 : 1_000_000

/** The router's addresses. */
ROUTER_MAC :: net_stack.Mac.{bytes = u8.[0x52, 0x55, 10, 0, 2, 2]}
ROUTER_V4 :: net_stack.Ipv4.{bytes = u8.[10, 0, 2, 2]}
/** The host's MAC address. */
HOST_MAC :: net_stack.Mac.{bytes = u8.[0x52, 0x54, 0, 0x12, 0x34, 0x56]}
/** What the test's DHCP server leases. */
LEASED_V4 :: net_stack.Ipv4.{bytes = u8.[10, 0, 2, 15]}
/** The prefix the router advertises: fd00:5105::/64. */
PREFIX :: net_stack.Ipv6.{bytes = u8.[0xfd, 0, 0x51, 0x05, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]}

/** The DNS server the router's advertisements name: fd00:5105::53. */
RDNSS_V6 :: net_stack.Ipv6.{bytes = u8.[0xfd, 0, 0x51, 0x05, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x53]}

/** A frame on its way. */
Flying :: struct {
    bytes : u8[net_stack.MAX_FRAME],
    length : usize,
    /** 0 for the host, 1 for the router. */
    to : u32,
    /** When it arrives. */
    arrives : u64,
}

/** How the link misbehaves, in percent of frames. */
Faults :: struct {
    drop : u64,
    duplicate : u64,
    /** The most a frame is delayed, in nanoseconds; each draws its own delay up to it, so they reorder. */
    most_delay : u64,
}

/** The link, the two stacks on it, and what's been seen. */
World :: struct {
    host : net_stack.Stack,
    router : net_stack.Stack,
    flying : Flying[IN_FLIGHT],
    now : u64,
    random : u64,
    faults : Faults,
    leased : bool,
    lease : net_stack.Lease,
    global : bool,
    global_address : net_stack.Ipv6,
    link_local : bool,
    replies : u32,
    last_reply : u64,
    /** The host's lease losses and conflicts, which shouldn't happen. */
    trouble : u32,
    /** The router's DNS server's socket, 0 while it has none (dns_test.hsc). */
    dns_socket : u32,
    /** How many queries it's answered. */
    dns_queries : u32,
    /** Whether it sends a forged answer, a wrong ID and address, before each true one. */
    dns_spoof : bool,
}

/**
 * Draw a number from the world's generator (xorshift64*).
 *
 * @param world The world.
 * @return The number.
 */
draw :: fn(world: ptr[mut World]) -> u64 {
    x := world.random
    x = x ~ (x >> 12)
    x = x ~ (x << 25)
    x = x ~ (x >> 27)
    world.random = x
    return x * 0x2545f4914f6cdd1d
}

/**
 * Set up a world: the host started with DHCP and IPv6, the router with its addresses set by hand.
 *
 * @param seed The link's and the stacks' seed.
 * @param faults How the link misbehaves.
 * @return The world, on the heap, the caller's to free.
 */
make_world :: fn(seed: u64, faults: Faults) -> ptr[mut World] {
    world :: runtime.new(World)
    world.random = seed | 1
    world.faults = faults
    net_stack.start(&world.host, net_stack.Setup.{mac = HOST_MAC, key = key_of(seed * 3 + 1)}, 0)
    net_stack.start(&world.router, net_stack.Setup.{mac = ROUTER_MAC, key = key_of(seed * 5 + 2), dhcp = false}, 0)
    net_stack.set_ipv4(&world.router, ROUTER_V4, 24, net_stack.Ipv4.{})
    return world
}

/**
 * Put a frame on the link, as the faults have it: maybe lost, maybe twice, each copy delayed.
 *
 * @param world The world.
 * @param bytes The frame.
 * @param to 0 for the host, 1 for the router.
 */
send :: fn(world: ptr[mut World], bytes: u8[], to: u32) {
    if draw(world) % 100 < world.faults.drop {
        return void
    }
    copies :: if draw(world) % 100 < world.faults.duplicate { 2 } else { 1 }
    for copy in 0..<copies {
        for &slot in world.flying {
            if slot.length == 0 {
                delay :: if world.faults.most_delay == 0 { cast[u64](0) } else { draw(world) % world.faults.most_delay }
                slot.length = bytes.count
                slot.to = to
                slot.arrives = world.now + delay
                for byte, i in bytes {
                    if i < slot.bytes.count {
                        slot.bytes[i] = byte
                    }
                }
                break
            }
        }
    }
}

/**
 * Move every frame each stack has queued onto the link, the router's DHCP and router solicitation answered by the test
 * as it goes past.
 *
 * @param world The world.
 */
take_frames :: fn(world: ptr[mut World]) {
    frame : u8[net_stack.MAX_FRAME]
    into :: view_of(&frame[0], frame.count)
    loop {
        length :: net_stack.take_frame(&world.host, into) or_break
        bytes :: net_stack.part(into, 0, length)
        send(world, bytes, 1)
        play_router(world, bytes)
    }
    loop {
        length :: net_stack.take_frame(&world.router, into) or_break
        send(world, net_stack.part(into, 0, length), 0)
    }
}

/**
 * Answer what the router's stack doesn't: DHCP, as a server leasing LEASED_V4, and router solicitations, with an
 * advertisement of PREFIX.
 *
 * @param world The world.
 * @param bytes A frame the host sent.
 */
play_router :: fn(world: ptr[mut World], bytes: u8[]) {
    kind :: net_stack.u16_at(bytes, 12)
    if kind == net_stack.ETHER_IPV4 && net_stack.byte_at(bytes, 23) == net_stack.PROTOCOL_UDP
        && net_stack.u16_at(bytes, 36) == net_stack.DHCP_SERVER_PORT {
        answer_dhcp(world, net_stack.part(bytes, 42, bytes.count))
    }
    else if kind == net_stack.ETHER_IPV6 && net_stack.byte_at(bytes, 20) == net_stack.PROTOCOL_ICMPV6
        && net_stack.byte_at(bytes, 54) == net_stack.ROUTER_SOLICITATION {
        advertise(world)
    }
}

/**
 * Answer a DHCP DISCOVER with an OFFER and a REQUEST with an ACK, each broadcast from the router.
 *
 * @param world The world.
 * @param message The client's message, after the UDP header.
 */
answer_dhcp :: fn(world: ptr[mut World], message: u8[]) {
    kind := cast[u8](0)
    at := cast[usize](net_stack.DHCP_OPTIONS_AT)
    loop {
        code :: net_stack.byte_at(message, at)
        if code == net_stack.OPTION_END || at >= message.count {
            break
        }
        if code == net_stack.OPTION_MESSAGE_TYPE {
            kind = net_stack.byte_at(message, at + 2)
        }
        at += 2 + cast[usize](net_stack.byte_at(message, at + 1))
    }
    while true
    answer_kind :: if kind == net_stack.DHCP_DISCOVER { net_stack.DHCP_OFFER } else if kind == net_stack.DHCP_REQUEST { net_stack.DHCP_ACK } else { cast[u8](0) }
    if answer_kind == 0 {
        return void
    }
    reply : u8[300]
    bytes :: view_of(&reply[0], reply.count)
    net_stack.put_u8(bytes, 0, 2)
    net_stack.put_u8(bytes, 1, 1)
    net_stack.put_u8(bytes, 2, 6)
    net_stack.put_u32(bytes, 4, net_stack.u32_at(message, 4))
    net_stack.put_bytes(bytes, 16, view_of(&LEASED_V4.bytes[0], 4))
    net_stack.put_bytes(bytes, 28, net_stack.part(message, 28, 34))
    net_stack.put_u32(bytes, 236, 0x63825363)
    options :: u8.[53, 1, answer_kind, 54, 4, 10, 0, 2, 2, 1, 4, 255, 255, 255, 0, 3, 4, 10, 0, 2, 2, 6, 4, 10, 0, 2, 3, 51, 4,
        0, 0, 0x0e, 0x10, 255]
    net_stack.put_bytes(bytes, net_stack.DHCP_OPTIONS_AT, view_of(&options[0], options.count))
    _ = net_stack.send_udp4(&world.router, net_stack.LIMITED_BROADCAST, net_stack.DHCP_SERVER_PORT, net_stack.DHCP_CLIENT_PORT, bytes)
}

/**
 * Send a router advertisement from the router's link-local address to all nodes: a default router for 1800 s, with
 * PREFIX for autonomous configuration, its link-layer address, and RDNSS_V6 as a DNS server.
 *
 * @param world The world.
 */
advertise :: fn(world: ptr[mut World]) {
    message : u8[80]
    bytes :: view_of(&message[0], message.count)
    net_stack.put_u8(bytes, 0, net_stack.ROUTER_ADVERTISEMENT)
    net_stack.put_u8(bytes, 4, 64)
    net_stack.put_u16(bytes, 6, 1800)
    net_stack.put_u8(bytes, 16, net_stack.OPTION_SOURCE_LINK)
    net_stack.put_u8(bytes, 17, 1)
    net_stack.put_mac(bytes, 18, ROUTER_MAC)
    net_stack.put_u8(bytes, 24, net_stack.OPTION_PREFIX)
    net_stack.put_u8(bytes, 25, 4)
    net_stack.put_u8(bytes, 26, 64)
    net_stack.put_u8(bytes, 27, 0xc0)
    net_stack.put_u32(bytes, 28, 86400)
    net_stack.put_u32(bytes, 32, 14400)
    net_stack.put_bytes(bytes, 40, view_of(&PREFIX.bytes[0], 16))
    // A recursive DNS server, RDNSS_V6, for an hour
    net_stack.put_u8(bytes, 56, net_stack.OPTION_RDNSS)
    net_stack.put_u8(bytes, 57, 3)
    net_stack.put_u32(bytes, 60, 3600)
    net_stack.put_bytes(bytes, 64, view_of(&RDNSS_V6.bytes[0], 16))
    _ = net_stack.send_icmpv6(&world.router, world.router.link_local.address, net_stack.ALL_NODES, bytes, net_stack.DISCOVERY_HOP_LIMIT)
}

/**
 * Deliver every frame due by now to its stack, oldest arrival first.
 *
 * @param world The world.
 */
deliver :: fn(world: ptr[mut World]) {
    loop {
        soonest := cast[usize](IN_FLIGHT)
        for slot, i in world.flying {
            if slot.length > 0 && slot.arrives <= world.now && (soonest >= world.flying.count || slot.arrives < world.flying[soonest].arrives) {
                soonest = i
            }
        }
        if soonest >= world.flying.count {
            return void
        }
        slot :: &world.flying[soonest]
        length :: slot.length
        slot.length = 0
        frame :: view_of(&slot.bytes[0], length)
        if slot.to == 0 {
            net_stack.receive(&world.host, frame, world.now)
        }
        else {
            net_stack.receive(&world.router, frame, world.now)
        }
        take_frames(world)
    }
}

/**
 * Note what the host's stack says.
 *
 * @param world The world.
 */
take_events :: fn(world: ptr[mut World]) {
    loop {
        happened :: net_stack.take_event(&world.host) or_break
        match happened {
            case Leased(lease) => {
                world.leased = true
                world.lease = lease
            }
            case AddressReady(assigned) => {
                if assigned.link_local {
                    world.link_local = true
                }
                else {
                    world.global = true
                    world.global_address = assigned.address
                }
            }
            case EchoReplied(echo) => {
                world.replies += 1
                world.last_reply = world.now
            }
            case LeaseLost => world.trouble += 1
            case AddressExpired(_) => world.global = false
            case AddressConflict(_) => world.trouble += 1
            case RouterFound(_) => {}
            case Incoming(_) => {}
            case Ended(_) => {}
            case Resolved(_) => {}
        }
    }
    loop {
        _ = net_stack.take_event(&world.router) or_break
    }
}

/**
 * Run the world for a while, a millisecond at a time: frames delivered, both stacks ticked, the host's events noted.
 *
 * @param world The world.
 * @param nanoseconds How long.
 */
run :: fn(world: ptr[mut World], nanoseconds: u64) {
    end :: world.now + nanoseconds
    loop {
        world.now += MILLISECOND
        deliver(world)
        net_stack.tick(&world.host, world.now)
        net_stack.tick(&world.router, world.now)
        take_frames(world)
        serve_dns(world)
        take_frames(world)
        take_events(world)
    }
    while world.now < end
}

/**
 * Make a stack's key from a seed, so a run replays.
 *
 * @param seed The seed.
 * @return The key: the seed's bytes, repeated.
 */
key_of :: fn(seed: u64) -> u8[32] {
    key : u8[32]
    for i in 0..<32 {
        key[i] = cast[u8](seed >> (8 * cast[u64](i % 8)))
    }
    return key
}

/**
 * Check something of a seed's run, failing the test with the seed noted if it isn't so.
 *
 * @param t The test's state.
 * @param holds Whether it is so.
 * @param what What should be.
 * @param seed The run's seed.
 */
check :: fn(t: ptr[mut testing.T], holds: bool, what: string, seed: u64) {
    if !holds {
        testing.note(t, "seed %: %", seed, what)
        testing.fail(t, what)
    }
}

/**
 * Run a world until the host has its lease and its global address, then ping the router over each family until each
 * answers.
 *
 * @param t The test's state.
 * @param seed The seed.
 * @param faults How the link misbehaves.
 */
configure_and_ping :: fn(t: ptr[mut testing.T], seed: u64, faults: Faults) {
    world :: make_world(seed, faults)
    defer runtime.free(world)
    take_frames(world)
    for second in 0..<180 {
        if world.leased && world.global {
            break
        }
        run(world, net_stack.SECOND)
    }
    check(t, world.leased, "DHCP leases an address", seed)
    check(t, net_stack.same_ipv4(world.lease.address, LEASED_V4), "the address leased", seed)
    check(t, world.lease.prefix_length == 24, "its prefix length is 24", seed)
    check(t, net_stack.same_ipv4(world.lease.router, ROUTER_V4), "its router", seed)
    check(t, world.link_local, "a link-local address", seed)
    check(t, world.global, "an address from the router's prefix", seed)
    check(t, net_stack.prefix_matches(view_of(&world.global_address.bytes[0], 16), view_of(&PREFIX.bytes[0], 16), 64),
        "the address is in the prefix", seed)
    for target in 0..<2 {
        to :: if target == 0 { net_stack.IpAddress.V4(ROUTER_V4) } else { net_stack.IpAddress.V6(world.router.link_local.address) }
        before :: world.replies
        for attempt in 0..<30 {
            if world.replies > before {
                break
            }
            _ = net_stack.ping(&world.host, to)
            run(world, net_stack.SECOND)
        }
        check(t, world.replies > before, if target == 0 { "a ping to the router over IPv4 is answered" } else { "a ping to the router over IPv6 is answered" }, seed)
    }
    check(t, world.trouble == 0, "no lease lost, no conflict", seed)
}

configures_and_pings_on_a_clean_link #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    configure_and_ping(t, 1, Faults.{})
    return .Ok
}

configures_and_pings_on_a_lossy_link #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    for seed in cast[u64](1)..<21 {
        configure_and_ping(t, seed, Faults.{drop = 20, duplicate = 10, most_delay = 50 * MILLISECOND})
    }
    return .Ok
}

/** A host's lease, renewed at T1 by its server, outlives its first term with no loss. */
renews_its_lease #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    world :: make_world(7, Faults.{})
    defer runtime.free(world)
    take_frames(world)
    run(world, 10 * net_stack.SECOND)
    testing.expect(t, world.leased, "leased")
    // The test's lease is an hour: past it, renewed at half
    world.leased = false
    run(world, 4000 * net_stack.SECOND)
    testing.expect(t, world.leased, "renewed")
    testing.expect_eq(t, world.trouble, 0, "never lost")
    return .Ok
}

/** Frames made at random, and valid ones damaged, are taken without harm. */
takes_any_frame #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    return testing.check_property(t, any_frame)
}

any_frame : testing.Property : fn(t: ptr[mut testing.T], source: ptr[mut testing.Source]) -> testing.Outcome {
    stack :: runtime.new(net_stack.Stack)
    defer runtime.free(stack)
    net_stack.start(stack, net_stack.Setup.{mac = HOST_MAC, key = key_of(3)}, 0)
    net_stack.set_ipv4(stack, LEASED_V4, 24, ROUTER_V4)
    bytes :: testing.draw_bytes(source, net_stack.MAX_FRAME)
    frame : u8[net_stack.MAX_FRAME]
    for byte, i in bytes {
        if i < frame.count {
            frame[i] = byte
        }
    }
    // Often addressed to it, with a type it reads, so the parsers past Ethernet are reached
    view :: view_of(&frame[0], bytes.count)
    if bytes.count >= 14 && testing.draw_between(source, 0, 3) != 0 {
        net_stack.put_mac(view, 0, HOST_MAC)
        kinds :: u16.[net_stack.ETHER_ARP, net_stack.ETHER_IPV4, net_stack.ETHER_IPV6]
        net_stack.put_u16(view, 12, kinds[cast[usize](testing.draw_between(source, 0, 2)) % kinds.count])
    }
    net_stack.receive(stack, view, 1)
    net_stack.tick(stack, 2 * net_stack.SECOND)
    out : u8[net_stack.MAX_FRAME]
    loop {
        _ = net_stack.take_frame(stack, view_of(&out[0], out.count)) or_break
    }
    return .Ok
}

/** IPv6 addresses are written as RFC 5952 says: the longest run of zero groups, the first of equals, as ::. */
formats_ipv6_addresses #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    expect_text(t, u8.[0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0x12, 0x34, 0, 0, 0, 0, 0xab, 0xcd], "fe80::1234:0:0:abcd")
    expect_text(t, u8.[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1], "::1")
    expect_text(t, u8.[0xfe, 0xc0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], "fec0::")
    expect_text(t, u8.[0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1], "2001:db8:0:1::1")
    expect_text(t, u8.[0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1], "2001:db8::1:0:0:1")
    expect_text(t, u8.[0, 1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0, 7, 0, 8], "1:2:3:4:5:6:7:8")
    return .Ok
}

/**
 * Check an address's text.
 *
 * @param t The test's state.
 * @param bytes The address.
 * @param expected Its text.
 */
expect_text :: fn(t: ptr[mut testing.T], bytes: u8[16], expected: string) {
    text : u8[40]
    length :: net_stack.format_ipv6(net_stack.Ipv6.{bytes = bytes}, view_of(&text[0], text.count))
    testing.expect_eq(t, string_of(&text[0], length), expected, "the address's text")
}
