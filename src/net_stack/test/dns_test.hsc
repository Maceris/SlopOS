package net_stack_test

import runtime from "base"
import testing from "std"
import net_stack from ".."

/*
 * The resolver's tests (decisions/0188, 13e): the host's stack asks the router's, where the test serves DNS on port 53
 * from a few names: peer.example.test with an address of each family, alias.example.test a CNAME for it, v4only with
 * only an IPv4 address, missing that doesn't exist, and broken whose server fails. Names come back IPv6 first, from the
 * cache while their TTL lasts; a forged answer is ignored; a server that doesn't answer is passed over; and names in
 * messages made at random are read without harm.
 */

/** peer.example.test's addresses. */
PEER_V4 :: net_stack.Ipv4.{bytes = u8.[10, 0, 2, 2]}
PEER_V6 :: net_stack.Ipv6.{bytes = u8.[0xfd, 0, 0x51, 0x05, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2]}
/** v4only.example.test's address. */
ONLY_V4 :: net_stack.Ipv4.{bytes = u8.[192, 0, 2, 7]}
/** The TTL the test's server gives, in seconds. */
TTL : u32 : 300
/** A forged answer's address. */
FORGED_V4 :: net_stack.Ipv4.{bytes = u8.[6, 6, 6, 6]}

/**
 * Answer each query the router's DNS server has waiting, from the test's names.
 *
 * @param world The world; its router serves only once dns_socket is opened.
 */
serve_dns :: fn(world: ptr[mut World]) {
    if world.dns_socket == 0 {
        return void
    }
    query : u8[512]
    loop {
        got :: net_stack.take_datagram(&world.router, world.dns_socket, view_of(&query[0], query.count)) or_break
        world.dns_queries += 1
        asked :: net_stack.part(view_of(&query[0], query.count), 0, got.length)
        if world.dns_spoof {
            forged : u8[512]
            length :: answer_query(asked, view_of(&forged[0], forged.count), true)
            _ = net_stack.udp_send(&world.router, world.dns_socket, got.from, got.from_port, net_stack.part(view_of(&forged[0], forged.count), 0, length))
        }
        answer : u8[512]
        length :: answer_query(asked, view_of(&answer[0], answer.count), false)
        if length > 0 {
            _ = net_stack.udp_send(&world.router, world.dns_socket, got.from, got.from_port, net_stack.part(view_of(&answer[0], answer.count), 0, length))
        }
    }
}

/**
 * Make the answer to a query: its question copied, then the name's records, each owner a pointer to the question's
 * name, or, past a CNAME, to the CNAME's target.
 *
 * @param query The query.
 * @param into Where the answer goes.
 * @param forged Whether to forge it: its ID one off, and FORGED_V4 for any name.
 * @return The answer's length; 0 for a query that isn't read.
 */
answer_query :: fn(query: u8[], into: mut u8[], forged: bool) -> usize {
    name : u8[net_stack.MAX_NAME]
    name_length :: net_stack.read_name(query, 12, view_of(&name[0], name.count)) or_return 0
    question_end :: net_stack.skip_name(query, 12) or_return 0
    kind :: net_stack.u16_at(query, question_end)
    asked :: string_of(&name[0], name_length)
    code := cast[u16](0)
    if asked == "missing.example.test" {
        code = 3
    }
    else if asked == "broken.example.test" {
        code = 2
    }
    id :: net_stack.u16_at(query, 0) + (if forged { cast[u16](1) } else { cast[u16](0) })
    net_stack.put_u16(into, 0, id)
    net_stack.put_u16(into, 2, 0x8180 | code)
    net_stack.put_u16(into, 4, 1)
    net_stack.put_u16(into, 8, 0)
    net_stack.put_u16(into, 10, 0)
    net_stack.put_bytes(into, 12, net_stack.part(query, 12, question_end + 4))
    at := question_end + 4
    count := cast[u16](0)
    // Where the names the addresses are under starts: the question's, or a CNAME's target
    owner := cast[u16](0xc00c)
    if code == 0 && !forged && asked == "alias.example.test" {
        net_stack.put_u16(into, at, owner)
        net_stack.put_u16(into, at + 2, net_stack.TYPE_CNAME)
        net_stack.put_u16(into, at + 4, net_stack.CLASS_IN)
        net_stack.put_u32(into, at + 6, TTL)
        // The target's name as a query's question writes it: 19 bytes, past its 12-byte header
        encoded : u8[64]
        _ = net_stack.build_query(view_of(&encoded[0], encoded.count), 0, string_bytes("peer.example.test"), 0)
        target :: net_stack.part(view_of(&encoded[0], encoded.count), 12, 12 + 19)
        net_stack.put_u16(into, at + 10, cast[u16](target.count))
        owner = 0xc000 | cast[u16](at + 12)
        net_stack.put_bytes(into, at + 12, target)
        at += 12 + target.count
        count += 1
    }
    peer :: asked == "peer.example.test" || asked == "alias.example.test"
    if code == 0 && (forged || peer || (asked == "v4only.example.test" && kind == net_stack.TYPE_A)) {
        v4 :: kind == net_stack.TYPE_A
        if v4 || !forged {
            net_stack.put_u16(into, at, owner)
            net_stack.put_u16(into, at + 2, kind)
            net_stack.put_u16(into, at + 4, net_stack.CLASS_IN)
            net_stack.put_u32(into, at + 6, TTL)
            net_stack.put_u16(into, at + 10, if v4 { cast[u16](4) } else { cast[u16](16) })
            if forged {
                net_stack.put_bytes(into, at + 12, view_of(&FORGED_V4.bytes[0], 4))
            }
            else if v4 {
                address :: if peer { PEER_V4 } else { ONLY_V4 }
                net_stack.put_bytes(into, at + 12, view_of(&address.bytes[0], 4))
            }
            else {
                net_stack.put_bytes(into, at + 12, view_of(&PEER_V6.bytes[0], 16))
            }
            at += 12 + (if v4 { cast[usize](4) } else { cast[usize](16) })
            count += 1
        }
    }
    net_stack.put_u16(into, 6, count)
    return at
}

/**
 * Make a world whose host has its lease, with the router serving DNS, the host's only server.
 *
 * @param seed The seed.
 * @param faults How the link misbehaves.
 * @return The world, the caller's to free.
 */
dns_world :: fn(seed: u64, faults: Faults) -> ptr[mut World] {
    world :: make_world(seed, faults)
    world.dns_socket = net_stack.udp_open(&world.router, net_stack.DNS_PORT) or_else 0
    take_frames(world)
    for second in 0..<60 {
        if world.leased {
            break
        }
        run(world, net_stack.SECOND)
    }
    _ = net_stack.set_dns_server(&world.host, .V4(ROUTER_V4), net_stack.DNS_PORT)
    return world
}

/**
 * Look a name up, running the world until it's done.
 *
 * @param world The world.
 * @param name The name.
 * @param v4 Whether its IPv4 addresses are wanted.
 * @param v6 Whether its IPv6 addresses are wanted.
 * @return Its result; Failed with no addresses if it wasn't done in a minute, or couldn't start.
 */
look_up :: fn(world: ptr[mut World], name: string, v4: bool, v6: bool) -> net_stack.Resolution {
    lookup :: net_stack.resolve(&world.host, string_bytes(name), v4, v6) or_return net_stack.Resolution.{outcome = .Failed}
    for step in 0..<600 {
        match net_stack.take_resolution(&world.host, lookup) {
            case Some(result) => return result
            case None => {}
        }
        run(world, 100 * MILLISECOND)
    }
    return net_stack.Resolution.{outcome = .Failed}
}

/** Tell whether a result's address at an index is an IPv4 address. */
is_v4 :: fn(result: ptr[net_stack.Resolution], index: usize, address: net_stack.Ipv4) -> bool {
    return index < result.count && index < result.addresses.count && net_stack.same_address(result.addresses[index], .V4(address))
}

/** Tell whether a result's address at an index is an IPv6 address. */
is_v6 :: fn(result: ptr[net_stack.Resolution], index: usize, address: net_stack.Ipv6) -> bool {
    return index < result.count && index < result.addresses.count && net_stack.same_address(result.addresses[index], .V6(address))
}

resolves_names #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    world :: dns_world(11, Faults.{})
    defer runtime.free(world)
    testing.require(t, world.leased, "leased")?
    peer := look_up(world, "peer.example.test", true, true)
    testing.expect(t, peer.outcome == .Found && peer.count == 2, "both of a name's addresses")
    testing.expect(t, is_v6(&peer, 0, PEER_V6) && is_v4(&peer, 1, PEER_V4), "IPv6 first, then IPv4")
    alias := look_up(world, "ALIAS.Example.Test.", true, true)
    testing.expect(t, alias.outcome == .Found && is_v6(&alias, 0, PEER_V6) && is_v4(&alias, 1, PEER_V4),
        "a CNAME followed, the name's case and final dot aside")
    only := look_up(world, "v4only.example.test", true, true)
    testing.expect(t, only.outcome == .Found && only.count == 1 && is_v4(&only, 0, ONLY_V4), "a name with IPv4 only")
    v6 := look_up(world, "v4only.example.test", false, true)
    testing.expect(t, v6.outcome == .NoAddress && v6.count == 0, "no IPv6 address for it: NoAddress")
    missing := look_up(world, "missing.example.test", true, true)
    testing.expect(t, missing.outcome == .NoSuchName, "a name that doesn't exist")
    broken := look_up(world, "broken.example.test", true, false)
    testing.expect(t, broken.outcome == .Failed, "a server that fails, every try")
    bad := look_up(world, "bad..name", true, true)
    testing.expect(t, bad.outcome == .BadName, "an empty label isn't a name")
    long_label := look_up(world, "a234567890123456789012345678901234567890123456789012345678901234.test", true, true)
    testing.expect(t, long_label.outcome == .BadName, "nor is a label of 64 bytes")
    return .Ok
}

caches_answers_for_their_ttl #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    world :: dns_world(12, Faults.{})
    defer runtime.free(world)
    first := look_up(world, "peer.example.test", true, true)
    asked :: world.dns_queries
    testing.expect(t, first.outcome == .Found && asked == 2, "a query of each kind")
    again := look_up(world, "peer.example.test", true, true)
    testing.expect(t, again.outcome == .Found && again.count == 2 && world.dns_queries == asked, "answered from the cache")
    missing := look_up(world, "missing.example.test", true, true)
    missed :: world.dns_queries
    _ = look_up(world, "missing.example.test", true, true)
    testing.expect(t, missing.outcome == .NoSuchName && world.dns_queries == missed, "a name that doesn't exist is remembered")
    run(world, cast[u64](TTL + 1) * net_stack.SECOND)
    later := look_up(world, "peer.example.test", true, true)
    testing.expect(t, later.outcome == .Found && world.dns_queries > missed, "asked again once its TTL's passed")
    return .Ok
}

ignores_forged_answers #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    world :: dns_world(13, Faults.{})
    defer runtime.free(world)
    world.dns_spoof = true
    peer := look_up(world, "peer.example.test", true, false)
    testing.expect(t, peer.outcome == .Found && peer.count == 1 && is_v4(&peer, 0, PEER_V4), "the forged ID's answer ignored")
    return .Ok
}

passes_over_a_silent_server #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    world :: dns_world(14, Faults.{})
    defer runtime.free(world)
    // A server no one answers for, configured first, then the router
    _ = net_stack.set_dns_server(&world.host, .V4(net_stack.Ipv4.{bytes = u8.[10, 0, 2, 9]}), net_stack.DNS_PORT)
    servers : net_stack.DnsServer[net_stack.DNS_SERVERS]
    count :: net_stack.dns_servers(&world.host, view_of(&servers[0], servers.count))
    testing.expect(t, count == 2, "both configured")
    peer := look_up(world, "peer.example.test", true, false)
    testing.expect(t, peer.outcome == .Found && is_v4(&peer, 0, PEER_V4), "answered by the next server")
    return .Ok
}

learns_servers_from_dhcp_and_routers #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    world :: make_world(15, Faults.{})
    defer runtime.free(world)
    take_frames(world)
    for second in 0..<60 {
        if world.leased && world.global {
            break
        }
        run(world, net_stack.SECOND)
    }
    servers : net_stack.DnsServer[net_stack.DNS_SERVERS]
    count :: net_stack.dns_servers(&world.host, view_of(&servers[0], servers.count))
    v4 := false
    v6 := false
    for i in 0..<count {
        if i < servers.count {
            v4 = v4 || net_stack.same_address(servers[i].address, .V4(net_stack.Ipv4.{bytes = u8.[10, 0, 2, 3]}))
            v6 = v6 || net_stack.same_address(servers[i].address, .V6(RDNSS_V6))
        }
    }
    testing.expect(t, v4, "DHCP's server, 10.0.2.3")
    testing.expect(t, v6, "the router's RDNSS server")
    _ = net_stack.set_dns_server(&world.host, .V4(ROUTER_V4), 5353)
    configured :: net_stack.dns_servers(&world.host, view_of(&servers[0], servers.count))
    testing.expect(t, configured == 1 && servers[0].port == 5353, "a configured server in their place")
    return .Ok
}

resolves_over_a_lossy_link #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    for seed in cast[u64](1)..<11 {
        world :: dns_world(seed, Faults.{drop = 20, duplicate = 10, most_delay = 50 * MILLISECOND})
        peer := look_up(world, "peer.example.test", true, true)
        check(t, peer.outcome == .Found && peer.count == 2, "both addresses, past lost and repeated datagrams", seed)
        runtime.free(world)
    }
    return .Ok
}

/** Names in messages made at random are read, skipped and compared without harm, and never past MAX_NAME. */
reads_any_name #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    return testing.check_property(t, any_name)
}

any_name : testing.Property : fn(t: ptr[mut testing.T], source: ptr[mut testing.Source]) -> testing.Outcome {
    message :: testing.draw_bytes(source, 600)
    at :: cast[usize](testing.draw_between(source, 0, 600))
    name : u8[net_stack.MAX_NAME]
    match net_stack.read_name(message, at, view_of(&name[0], name.count)) {
        case Some(length) => testing.expect(t, length > 0 && length <= net_stack.MAX_NAME, "a name read fits")
        case None => {}
    }
    match net_stack.skip_name(message, at) {
        case Some(end) => testing.expect(t, end > at && end <= message.count, "a name ends within the message")
        case None => {}
    }
    _ = net_stack.name_equals(message, at, string_bytes("peer.example.test"))
    return .Ok
}
