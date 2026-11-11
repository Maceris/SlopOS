package net_stack

import crypto from "std"

/*
 * IPv6 (RFC 8200), ICMPv6's echo (RFC 4443), neighbour discovery (RFC 4861) and SLAAC (RFC 4862). The interface takes a
 * link-local address at start, and one for each prefix a router advertises for autonomous configuration, each with an
 * interface identifier made from the prefix, the MAC address and a secret (RFC 7217), so it's stable on a network but
 * says nothing of the interface elsewhere. Every address is checked for duplicates first, by one solicitation and a
 * second's wait (RFC 4862 §5.4). Packets with extension headers other than hop-by-hop options are dropped; multicast
 * listener discovery isn't spoken, so a switch that snoops it may not pass the solicited-node groups.
 */

/** The bytes of an IPv6 header. */
IPV6_HEADER :: 40
/** IPv6's next header for hop-by-hop options. */
NEXT_HOP_BY_HOP : u8 : 0
/** ICMPv6's type for an echo request. */
ICMPV6_ECHO_REQUEST : u8 : 128
/** ICMPv6's type for an echo reply. */
ICMPV6_ECHO_REPLY : u8 : 129
/** ICMPv6's type for a router solicitation. */
ROUTER_SOLICITATION : u8 : 133
/** ICMPv6's type for a router advertisement. */
ROUTER_ADVERTISEMENT : u8 : 134
/** ICMPv6's type for a neighbour solicitation. */
NEIGHBOUR_SOLICITATION : u8 : 135
/** ICMPv6's type for a neighbour advertisement. */
NEIGHBOUR_ADVERTISEMENT : u8 : 136
/** Neighbour discovery's option for the sender's link-layer address. */
OPTION_SOURCE_LINK : u8 : 1
/** Neighbour discovery's option for the target's link-layer address. */
OPTION_TARGET_LINK : u8 : 2
/** Neighbour discovery's option for a prefix. */
OPTION_PREFIX : u8 : 3
/** Neighbour discovery's option for the link's MTU. */
OPTION_MTU : u8 : 5
/** The hop limit neighbour discovery's messages are sent and checked with. */
DISCOVERY_HOP_LIMIT : u8 : 255
/** How long duplicate address detection waits for an answer: 1 s. */
DAD_WAIT : u64 : SECOND
/** How many router solicitations are sent before giving up on routers: 3 (RFC 4861 §10). */
SOLICITATIONS :: 3
/** The wait between router solicitations: 4 s. */
SOLICITATION_INTERVAL : u64 : 4 * SECOND
/** The all-nodes group, ff02::1. */
ALL_NODES :: Ipv6.{bytes = u8.[0xff, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]}
/** The all-routers group, ff02::2. */
ALL_ROUTERS :: Ipv6.{bytes = u8.[0xff, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2]}
/** The link-local prefix, fe80::/64. */
LINK_LOCAL_PREFIX :: Ipv6.{bytes = u8.[0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]}

/**
 * Start IPv6: the link-local address, checked for duplicates, after which routers are solicited.
 *
 * @param stack The stack.
 */
start_ipv6 :: fn(stack: ptr[mut Stack]) {
    stack.link_local = Address6.{state = .Tentative, address = stable_address(stack, LINK_LOCAL_PREFIX, 0), prefix_length = 64,
        deadline = stack.now + DAD_WAIT}
    send_solicitation(stack, stack.link_local.address, true)
}

/**
 * Make an address from a /64 prefix and a stable interface identifier: the first 64 bits of SHA-256 over the prefix,
 * the MAC address, a counter and the stack's secret (RFC 7217 §5).
 *
 * @param stack The stack, whose MAC address and secret are used.
 * @param prefix The prefix, its first 8 bytes.
 * @param counter How many times this prefix's address was found a duplicate, so each try differs.
 * @return The address.
 */
stable_address :: fn(stack: ptr[Stack], prefix: Ipv6, counter: u8) -> Ipv6 {
    input : u8[8 + 6 + 1 + 32]
    for i in cast[usize](0)..<8 {
        if i < input.count && i < prefix.bytes.count {
            input[i] = prefix.bytes[i]
        }
    }
    for byte, i in stack.mac.bytes {
        if 8 + i < input.count {
            input[8 + i] = byte
        }
    }
    if 14 < input.count {
        input[14] = counter
    }
    for byte, i in stack.secret {
        if 15 + i < input.count {
            input[15 + i] = byte
        }
    }
    digest :: crypto.sha256(view_of(&input[0], input.count))
    address := prefix
    for i in cast[usize](8)..<16 {
        if i < address.bytes.count && i - 8 < digest.count {
            address.bytes[i] = digest[i - 8]
        }
    }
    return address
}

/**
 * Do what IPv6 has due: duplicate detection's ends, addresses' and routers' lifetimes, and router solicitations.
 *
 * @param stack The stack.
 */
tick_ipv6 :: fn(stack: ptr[mut Stack]) {
    now :: stack.now
    if stack.link_local.state == .Tentative && now >= stack.link_local.deadline {
        stack.link_local.state = .Assigned
        stack.link_local.deadline = 0
        event(stack, .AddressReady(Assigned.{address = stack.link_local.address, prefix_length = 64, link_local = true}))
        stack.solicitations = 0
        solicit_routers(stack)
    }
    for &each in stack.globals {
        if each.state == .Tentative && now >= each.deadline {
            each.state = .Assigned
            each.deadline = 0
            event(stack, .AddressReady(Assigned.{address = each.address, prefix_length = each.prefix_length}))
        }
    }
    for &router in stack.routers {
        if !is_zero_ipv6(router.address) && now >= router.expires {
            router^ = Router6.{}
        }
    }
    if stack.next_solicitation != 0 && now >= stack.next_solicitation {
        solicit_routers(stack)
    }
}

/**
 * Send a router solicitation from the link-local address, if fewer than SOLICITATIONS have gone and no router's known.
 *
 * @param stack The stack, whose next_solicitation is set, or cleared once they're done.
 */
solicit_routers :: fn(stack: ptr[mut Stack]) {
    if stack.solicitations >= SOLICITATIONS || has_router(stack) {
        stack.next_solicitation = 0
        return void
    }
    stack.solicitations += 1
    stack.next_solicitation = stack.now + SOLICITATION_INTERVAL
    message : u8[16]
    bytes :: view_of(&message[0], message.count)
    put_u8(bytes, 0, ROUTER_SOLICITATION)
    put_u8(bytes, 8, OPTION_SOURCE_LINK)
    put_u8(bytes, 9, 1)
    put_mac(bytes, 10, stack.mac)
    send_icmpv6(stack, stack.link_local.address, ALL_ROUTERS, bytes, DISCOVERY_HOP_LIMIT)
}

/**
 * Tell whether a default router is known.
 *
 * @param stack The stack.
 * @return True if one is.
 */
has_router :: fn(stack: ptr[Stack]) -> bool {
    for router in stack.routers {
        if !is_zero_ipv6(router.address) {
            return true
        }
    }
    return false
}

/**
 * Give an address's solicited-node group: ff02::1:ff and its last three bytes.
 *
 * @param address The address.
 * @return The group.
 */
solicited_node :: fn(address: Ipv6) -> Ipv6 {
    group := Ipv6.{bytes = u8.[0xff, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0xff, 0, 0, 0]}
    for i in cast[usize](13)..<16 {
        if i < group.bytes.count && i < address.bytes.count {
            group.bytes[i] = address.bytes[i]
        }
    }
    return group
}

/**
 * Give the MAC address an IPv6 multicast group is sent to: 33:33 and its last four bytes (RFC 2464 §7).
 *
 * @param group The group.
 * @return The MAC address.
 */
multicast_mac :: fn(group: Ipv6) -> Mac {
    mac := Mac.{bytes = u8.[0x33, 0x33, 0, 0, 0, 0]}
    for i in cast[usize](2)..<6 {
        if i < mac.bytes.count && 10 + i < group.bytes.count {
            mac.bytes[i] = group.bytes[10 + i]
        }
    }
    return mac
}

/**
 * Tell whether an address is the interface's, assigned or, with tentative, still being checked.
 *
 * @param stack The stack.
 * @param address The address.
 * @param tentative Whether a tentative address counts.
 * @return True if it's one of the interface's.
 */
is_ours_v6 :: fn(stack: ptr[Stack], address: Ipv6, tentative: bool) -> bool {
    if counts(stack.link_local, tentative) && same_ipv6(stack.link_local.address, address) {
        return true
    }
    for each in stack.globals {
        if counts(each, tentative) && same_ipv6(each.address, address) {
            return true
        }
    }
    return false
}

/**
 * Tell whether an address of the interface's counts: assigned, or tentative if those count.
 *
 * @param each The address.
 * @param tentative Whether a tentative address counts.
 * @return True if it does.
 */
counts :: fn(each: Address6, tentative: bool) -> bool {
    return each.state == .Assigned || (tentative && each.state == .Tentative)
}

/**
 * Tell whether a packet's destination is for the interface: one of its addresses, all nodes, or the solicited-node
 * group of one of its addresses, tentative ones included.
 *
 * @param stack The stack.
 * @param destination The destination.
 * @return True if it is.
 */
is_for_us_v6 :: fn(stack: ptr[Stack], destination: Ipv6) -> bool {
    if is_ours_v6(stack, destination, false) || same_ipv6(destination, ALL_NODES) {
        return true
    }
    if stack.link_local.state != .Free && same_ipv6(destination, solicited_node(stack.link_local.address)) {
        return true
    }
    for each in stack.globals {
        if each.state != .Free && same_ipv6(destination, solicited_node(each.address)) {
            return true
        }
    }
    return false
}

/**
 * Take an IPv6 packet: past a hop-by-hop header, an ICMPv6 message for the interface is read.
 *
 * @param stack The stack.
 * @param from_mac Its Ethernet source.
 * @param packet The packet, after the Ethernet header, maybe padded past its payload's length.
 */
receive_ipv6 :: fn(stack: ptr[mut Stack], from_mac: Mac, packet: u8[]) {
    if packet.count < IPV6_HEADER || byte_at(packet, 0) >> 4 != 6 {
        return void
    }
    total :: IPV6_HEADER + cast[usize](u16_at(packet, 4))
    if total > packet.count {
        return void
    }
    source :: ipv6_at(packet, 8)
    destination :: ipv6_at(packet, 24)
    if !is_for_us_v6(stack, destination) {
        return void
    }
    next := byte_at(packet, 6)
    at := cast[usize](IPV6_HEADER)
    if next == NEXT_HOP_BY_HOP {
        next = byte_at(packet, at)
        at += (cast[usize](byte_at(packet, at + 1)) + 1) * 8
        if at > total {
            return void
        }
    }
    if next == PROTOCOL_TCP || next == PROTOCOL_UDP {
        // Only to an address of the interface's, not a group
        if !is_ours_v6(stack, destination, false) {
            return void
        }
        payload :: part(packet, at, total)
        if next == PROTOCOL_TCP {
            receive_tcp(stack, .V6(source), pseudo_sum_v6(source, destination, PROTOCOL_TCP, payload.count), payload)
        }
        else {
            receive_udp6(stack, source, destination, payload)
        }
        return void
    }
    if next != PROTOCOL_ICMPV6 {
        return void
    }
    message :: part(packet, at, total)
    if message.count < 4 || checksum_finish(pseudo_sum_v6(source, destination, PROTOCOL_ICMPV6, message.count) + checksum_add(0, message)) != 0 {
        return void
    }
    receive_icmpv6(stack, from_mac, source, destination, byte_at(packet, 7), message)
}

/**
 * Take an ICMPv6 message for the interface.
 *
 * @param stack The stack.
 * @param from_mac Its Ethernet source.
 * @param source Its IPv6 source.
 * @param destination Its IPv6 destination.
 * @param hop_limit The hop limit it arrived with, 255 for neighbour discovery's, which can't have come from off the
 *     link.
 * @param message The message, its checksum checked.
 */
receive_icmpv6 :: fn(stack: ptr[mut Stack], from_mac: Mac, source: Ipv6, destination: Ipv6, hop_limit: u8, message: u8[]) {
    kind :: byte_at(message, 0)
    if kind == ICMPV6_ECHO_REQUEST && is_ours_v6(stack, destination, false) {
        reply : u8[MAX_FRAME]
        most :: reply.count - IPV6_HEADER - ETHERNET_HEADER
        bytes :: view_of(&reply[0], if message.count < most { message.count } else { most })
        put_bytes(bytes, 0, message)
        put_u8(bytes, 0, ICMPV6_ECHO_REPLY)
        send_icmpv6(stack, destination, source, bytes, stack.hop_limit)
        return void
    }
    if kind == ICMPV6_ECHO_REPLY {
        echo_answered(stack, .V6(source), u16_at(message, 4), u16_at(message, 6))
        return void
    }
    if hop_limit != DISCOVERY_HOP_LIMIT || byte_at(message, 1) != 0 {
        return void
    }
    if kind == ROUTER_ADVERTISEMENT {
        receive_advertisement(stack, source, message)
    }
    else if kind == NEIGHBOUR_SOLICITATION {
        receive_solicitation(stack, source, message)
    }
    else if kind == NEIGHBOUR_ADVERTISEMENT {
        receive_neighbour_advertisement(stack, from_mac, message)
    }
}

/**
 * Find a link-layer address option among neighbour discovery's options.
 *
 * @param options The options.
 * @param kind OPTION_SOURCE_LINK or OPTION_TARGET_LINK.
 * @return The address; null if there's no such option, or the options are malformed.
 */
link_option :: fn(options: u8[], kind: u8) -> Mac? {
    at := cast[usize](0)
    loop {
        if at + 2 > options.count {
            return null
        }
        length :: cast[usize](byte_at(options, at + 1)) * 8
        if length == 0 || at + length > options.count {
            return null
        }
        if byte_at(options, at) == kind && length >= 8 {
            return mac_at(options, at + 2)
        }
        at += length
    }
    while true
    return null
}

/**
 * Take a router advertisement: its source becomes a default router while its lifetime lasts, its hop limit is taken,
 * and each prefix for autonomous configuration gives the interface an address.
 *
 * @param stack The stack.
 * @param source The router's address, which has to be link-local.
 * @param message The advertisement.
 */
receive_advertisement :: fn(stack: ptr[mut Stack], source: Ipv6, message: u8[]) {
    if message.count < 16 || !prefix_matches(view_of(&source.bytes[0], source.bytes.count), view_of(&LINK_LOCAL_PREFIX.bytes[0], 16), 10) {
        return void
    }
    if byte_at(message, 4) != 0 {
        stack.hop_limit = byte_at(message, 4)
    }
    options :: message[16..<message.count]
    match link_option(options, OPTION_SOURCE_LINK) {
        case Some(mac) => learn_neighbour(stack, false, source, mac, true)
        case None => {}
    }
    lifetime :: cast[u64](u16_at(message, 6)) * SECOND
    if lifetime > 0 {
        add_router(stack, source, lifetime)
    }
    at := cast[usize](0)
    loop {
        if at + 2 > options.count {
            break
        }
        length :: cast[usize](byte_at(options, at + 1)) * 8
        if length == 0 || at + length > options.count {
            break
        }
        if byte_at(options, at) == OPTION_PREFIX && length == 32 {
            take_prefix(stack, part(options, at, at + length))
        }
        at += length
    }
    while true
}

/**
 * Keep a default router, or renew one kept, telling the caller of a new one.
 *
 * @param stack The stack.
 * @param address Its link-local address.
 * @param lifetime How long it's a default router, in nanoseconds.
 */
add_router :: fn(stack: ptr[mut Stack], address: Ipv6, lifetime: u64) {
    for &router in stack.routers {
        if same_ipv6(router.address, address) {
            router.expires = stack.now + lifetime
            return void
        }
    }
    for &router in stack.routers {
        if is_zero_ipv6(router.address) {
            router^ = Router6.{address = address, expires = stack.now + lifetime}
            stack.next_solicitation = 0
            event(stack, .RouterFound(address))
            return void
        }
    }
}

/**
 * Take a prefix information option: with the autonomous flag, a /64 that isn't link-local gives the interface an
 * address, checked for duplicates first, or renews the one it gave (RFC 4862 §5.5.3).
 *
 * @param stack The stack.
 * @param option The option, 32 bytes.
 */
take_prefix :: fn(stack: ptr[mut Stack], option: u8[]) {
    prefix_length :: byte_at(option, 2)
    autonomous :: byte_at(option, 3) & 0x40 != 0
    valid :: u32_at(option, 4)
    preferred :: u32_at(option, 8)
    prefix :: ipv6_at(option, 16)
    if !autonomous || prefix_length != 64 || preferred > valid || valid == 0
        || prefix_matches(view_of(&prefix.bytes[0], 16), view_of(&LINK_LOCAL_PREFIX.bytes[0], 16), 10) {
        return void
    }
    ends :: if valid == 0xffffffff { cast[u64](0) } else { stack.now + cast[u64](valid) * SECOND }
    for &each in stack.globals {
        if each.state != .Free && prefix_matches(view_of(&each.address.bytes[0], 16), view_of(&prefix.bytes[0], 16), 64) {
            if each.state == .Assigned {
                // The two-hour rule: a short lifetime advertised only shortens one longer than two hours to two hours
                two_hours :: stack.now + 7200 * SECOND
                if ends == 0 || ends > two_hours || (each.deadline != 0 && ends > each.deadline) {
                    each.deadline = ends
                }
                else if each.deadline == 0 || each.deadline > two_hours {
                    each.deadline = two_hours
                }
            }
            return void
        }
    }
    for &each in stack.globals {
        if each.state == .Free {
            each^ = Address6.{state = .Tentative, address = stable_address(stack, prefix, 0), prefix_length = 64,
                deadline = stack.now + DAD_WAIT}
            send_solicitation(stack, each.address, true)
            return void
        }
    }
}

/**
 * Take a neighbour solicitation: one for an address the interface is checking, from ::, means another wants it too;
 * one for an assigned address is answered.
 *
 * @param stack The stack.
 * @param source Who sent it: :: for duplicate address detection.
 * @param message The solicitation.
 */
receive_solicitation :: fn(stack: ptr[mut Stack], source: Ipv6, message: u8[]) {
    if message.count < 24 {
        return void
    }
    target :: ipv6_at(message, 8)
    options :: message[24..<message.count]
    from_nobody :: is_zero_ipv6(source)
    if from_nobody && is_ours_v6(stack, target, true) && !is_ours_v6(stack, target, false) {
        conflict_v6(stack, target)
        return void
    }
    if !is_ours_v6(stack, target, false) {
        return void
    }
    if !from_nobody {
        match link_option(options, OPTION_SOURCE_LINK) {
            case Some(mac) => learn_neighbour(stack, false, source, mac, true)
            case None => {}
        }
    }
    answer : u8[32]
    bytes :: view_of(&answer[0], answer.count)
    put_u8(bytes, 0, NEIGHBOUR_ADVERTISEMENT)
    // Solicited and override, unless it answers duplicate detection, which is told by all nodes
    put_u8(bytes, 4, if from_nobody { cast[u8](0x20) } else { cast[u8](0x60) })
    put_bytes(bytes, 8, view_of(&target.bytes[0], target.bytes.count))
    put_u8(bytes, 24, OPTION_TARGET_LINK)
    put_u8(bytes, 25, 1)
    put_mac(bytes, 26, stack.mac)
    send_icmpv6(stack, target, if from_nobody { ALL_NODES } else { source }, bytes, DISCOVERY_HOP_LIMIT)
}

/**
 * Take a neighbour advertisement: one for an address the interface is checking means it's taken; one for a neighbour
 * being resolved resolves it.
 *
 * @param stack The stack.
 * @param from_mac Its Ethernet source, the target's MAC address without a target link-layer option.
 * @param message The advertisement.
 */
receive_neighbour_advertisement :: fn(stack: ptr[mut Stack], from_mac: Mac, message: u8[]) {
    if message.count < 24 {
        return void
    }
    target :: ipv6_at(message, 8)
    if is_ours_v6(stack, target, true) {
        if !is_ours_v6(stack, target, false) {
            conflict_v6(stack, target)
        }
        return void
    }
    mac :: link_option(message[24..<message.count], OPTION_TARGET_LINK) or_else from_mac
    learn_neighbour(stack, false, target, mac, false)
}

/**
 * Give up an address found a duplicate while being checked, telling the caller. The link-local one isn't tried again;
 * without it, routers aren't solicited (RFC 4862 §5.4.5).
 *
 * @param stack The stack.
 * @param address The address.
 */
conflict_v6 :: fn(stack: ptr[mut Stack], address: Ipv6) {
    if stack.link_local.state == .Tentative && same_ipv6(stack.link_local.address, address) {
        stack.link_local = Address6.{}
    }
    for &each in stack.globals {
        if each.state == .Tentative && same_ipv6(each.address, address) {
            each^ = Address6.{}
        }
    }
    event(stack, .AddressConflict(.V6(address)))
}

/**
 * Send a neighbour solicitation for a target, to its solicited-node group: for duplicate address detection, from ::
 * without a link-layer option; else from the interface's best address, with its MAC address.
 *
 * @param stack The stack.
 * @param target The address asked for.
 * @param dad Whether it checks for a duplicate of the interface's own.
 */
send_solicitation :: fn(stack: ptr[mut Stack], target: Ipv6, dad: bool) {
    message : u8[32]
    bytes :: view_of(&message[0], if dad { cast[usize](24) } else { cast[usize](32) })
    put_u8(bytes, 0, NEIGHBOUR_SOLICITATION)
    put_bytes(bytes, 8, view_of(&target.bytes[0], target.bytes.count))
    if !dad {
        put_u8(bytes, 24, OPTION_SOURCE_LINK)
        put_u8(bytes, 25, 1)
        put_mac(bytes, 26, stack.mac)
    }
    from :: if dad { Ipv6.{} } else { source_for(stack, target) }
    send_icmpv6(stack, from, solicited_node(target), bytes, DISCOVERY_HOP_LIMIT)
}

/**
 * Choose the source address for a destination: the link-local address for link-local and multicast destinations, else
 * an assigned global one, the one sharing its /64 first.
 *
 * @param stack The stack.
 * @param to The destination.
 * @return The address; :: if the interface has none assigned.
 */
source_for :: fn(stack: ptr[Stack], to: Ipv6) -> Ipv6 {
    link_scoped :: byte_at(view_of(&to.bytes[0], 16), 0) == 0xff
        || prefix_matches(view_of(&to.bytes[0], 16), view_of(&LINK_LOCAL_PREFIX.bytes[0], 16), 10)
    if !link_scoped {
        for each in stack.globals {
            if each.state == .Assigned && prefix_matches(view_of(&each.address.bytes[0], 16), view_of(&to.bytes[0], 16), 64) {
                return each.address
            }
        }
        for each in stack.globals {
            if each.state == .Assigned {
                return each.address
            }
        }
    }
    return if stack.link_local.state == .Assigned { stack.link_local.address } else { Ipv6.{} }
}

/**
 * Send an ICMPv6 echo request, from the best source for its destination.
 *
 * @param stack The stack.
 * @param to Who's pinged.
 * @param sequence Its sequence number.
 * @return True once it's queued or waiting for its hop; false without an address or a route.
 */
send_echo_v6 :: fn(stack: ptr[mut Stack], to: Ipv6, sequence: u16) -> bool {
    from :: source_for(stack, to)
    if is_zero_ipv6(from) {
        return false
    }
    request : u8[16]
    bytes :: view_of(&request[0], request.count)
    put_u8(bytes, 0, ICMPV6_ECHO_REQUEST)
    put_u16(bytes, 4, ECHO_IDENTIFIER)
    put_u16(bytes, 6, sequence)
    put_u32(bytes, 8, 0x536c6f70)
    return send_icmpv6(stack, from, to, bytes, stack.hop_limit)
}

/**
 * Give the sum of an IPv6 pseudo-header, for an ICMPv6, UDP or TCP checksum.
 *
 * @param source The source address.
 * @param destination The destination address.
 * @param next The next header: the payload's protocol.
 * @param length The payload's length.
 * @return The sum, not folded.
 */
pseudo_sum_v6 :: fn(source: Ipv6, destination: Ipv6, next: u8, length: usize) -> u64 {
    sum := checksum_add(0, view_of(&source.bytes[0], source.bytes.count))
    sum = checksum_add(sum, view_of(&destination.bytes[0], destination.bytes.count))
    return sum + cast[u64](length >> 16) + cast[u64](length & 0xffff) + cast[u64](next)
}

/**
 * Send an ICMPv6 message, its checksum made: to a multicast group straight to its MAC address, else to its next hop.
 *
 * @param stack The stack.
 * @param from The source address.
 * @param to The destination.
 * @param message The message, its checksum field written here.
 * @param hop_limit The hop limit.
 * @return True once it's queued or waiting for its hop; false if there's no route.
 */
send_icmpv6 :: fn(stack: ptr[mut Stack], from: Ipv6, to: Ipv6, message: mut u8[], hop_limit: u8) -> bool {
    put_u16(message, 2, 0)
    put_u16(message, 2, checksum_finish(pseudo_sum_v6(from, to, PROTOCOL_ICMPV6, message.count) + checksum_add(0, message)))
    return send_ipv6(stack, from, to, PROTOCOL_ICMPV6, message, hop_limit)
}

/**
 * Send an IPv6 packet: to a multicast group straight to its MAC address; to an address on the link, or link-local,
 * through its neighbour entry; else through the first default router.
 *
 * @param stack The stack.
 * @param from The source address.
 * @param to The destination.
 * @param next What the payload is.
 * @param payload The payload, at most the MTU less the header; more is cut off.
 * @param hop_limit The hop limit.
 * @return True once it's queued or waiting for its hop; false if it's off the link without a router.
 */
send_ipv6 :: fn(stack: ptr[mut Stack], from: Ipv6, to: Ipv6, next: u8, payload: u8[], hop_limit: u8) -> bool {
    packet : u8[MAX_FRAME]
    most :: if cast[usize](stack.mtu) < packet.count - ETHERNET_HEADER { cast[usize](stack.mtu) } else { packet.count - ETHERNET_HEADER }
    total :: if IPV6_HEADER + payload.count < most { IPV6_HEADER + payload.count } else { most }
    bytes :: view_of(&packet[0], total)
    put_u8(bytes, 0, 0x60)
    put_u16(bytes, 4, cast[u16](total - IPV6_HEADER))
    put_u8(bytes, 6, next)
    put_u8(bytes, 7, hop_limit)
    put_bytes(bytes, 8, view_of(&from.bytes[0], from.bytes.count))
    put_bytes(bytes, 24, view_of(&to.bytes[0], to.bytes.count))
    put_bytes(bytes, IPV6_HEADER, payload)
    if byte_at(view_of(&to.bytes[0], 16), 0) == 0xff {
        queue_frame(stack, multicast_mac(to), ETHER_IPV6, bytes)
        return true
    }
    if prefix_matches(view_of(&to.bytes[0], 16), view_of(&LINK_LOCAL_PREFIX.bytes[0], 16), 10) || on_link_v6(stack, to) {
        return send_to_hop(stack, false, to, bytes)
    }
    for router in stack.routers {
        if !is_zero_ipv6(router.address) {
            return send_to_hop(stack, false, router.address, bytes)
        }
    }
    return false
}

/**
 * Tell whether an address is on the link: in the /64 of one of the interface's global addresses.
 *
 * @param stack The stack.
 * @param address The address.
 * @return True if it is.
 */
on_link_v6 :: fn(stack: ptr[Stack], address: Ipv6) -> bool {
    for each in stack.globals {
        if each.state != .Free && prefix_matches(view_of(&each.address.bytes[0], 16), view_of(&address.bytes[0], 16), 64) {
            return true
        }
    }
    return false
}

/**
 * Write an IPv6 address as text, as RFC 5952 recommends: groups in lowercase hexadecimal without leading zeros, the
 * longest run of two or more zero groups, the first if there's a tie, as ::.
 *
 * @param address The address.
 * @param into Where it's written: 39 bytes is room for any address.
 * @return How many bytes were written; what doesn't fit is left out.
 */
format_ipv6 :: fn(address: Ipv6, into: mut u8[]) -> usize {
    bytes :: view_of(&address.bytes[0], address.bytes.count)
    // The longest run of zero groups
    best_start := cast[usize](8)
    best_length := cast[usize](0)
    run_start := cast[usize](0)
    run_length := cast[usize](0)
    for group in cast[usize](0)..<8 {
        if u16_at(bytes, group * 2) == 0 {
            if run_length == 0 {
                run_start = group
            }
            run_length += 1
            if run_length > best_length {
                best_start = run_start
                best_length = run_length
            }
        }
        else {
            run_length = 0
        }
    }
    if best_length < 2 {
        best_start = 8
        best_length = 0
    }
    digits :: "0123456789abcdef"
    written := cast[usize](0)
    with {
        group : usize = 0
    }
    loop {
        if group >= 8 {
            break
        }
        if group == best_start {
            put_u8(into, written, cast[u8](':'))
            put_u8(into, written + 1, cast[u8](':'))
            written += 2
            group += best_length
            continue
        }
        if group > 0 && group != best_start + best_length {
            put_u8(into, written, cast[u8](':'))
            written += 1
        }
        value :: u16_at(bytes, group * 2)
        started := false
        for shift in cast[u16](0)..<4 {
            nibble :: (value >> (12 - shift * 4)) & 0xf
            if nibble != 0 || started || shift == 3 {
                started = true
                put_u8(into, written, cast[u8](digits[cast[usize](nibble)]))
                written += 1
            }
        }
        group += 1
    }
    while true
    return if written < into.count { written } else { into.count }
}
