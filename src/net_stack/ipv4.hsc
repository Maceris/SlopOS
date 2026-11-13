package net_stack

/*
 * IPv4: ARP (RFC 826), IPv4 (RFC 791) without fragments, which are dropped, and ICMP's echo (RFC 792). A packet goes to
 * its destination on the link when it shares the interface's prefix, and through the router otherwise; a limited
 * broadcast goes to every MAC address.
 */

/** The bytes of an IPv4 header without options. */
IPV4_HEADER :: 20
/** The bytes of an ARP packet for IPv4 over Ethernet. */
ARP_PACKET :: 28
/** ARP's operation for a request. */
ARP_REQUEST : u16 : 1
/** ARP's operation for a reply. */
ARP_REPLY : u16 : 2
/** ICMP's type for an echo reply. */
ICMP_ECHO_REPLY : u8 : 0
/** ICMP's type for an echo request. */
ICMP_ECHO_REQUEST : u8 : 8
/** The time to live its packets start with. */
IPV4_TTL : u8 : 64
/** The limited broadcast address, 255.255.255.255. */
LIMITED_BROADCAST :: Ipv4.{bytes = u8.[255, 255, 255, 255]}

/**
 * Take an ARP packet: learn its sender, and answer a request for the interface's address.
 *
 * @param stack The stack.
 * @param packet The packet, after the Ethernet header.
 */
receive_arp :: fn(stack: ptr[mut Stack], packet: u8[]) {
    if packet.count < ARP_PACKET || u16_at(packet, 0) != 1 || u16_at(packet, 2) != ETHER_IPV4 || byte_at(packet, 4) != 6
        || byte_at(packet, 5) != 4 {
        return void
    }
    operation :: u16_at(packet, 6)
    sender_mac :: mac_at(packet, 8)
    sender :: ipv4_at(packet, 14)
    target :: ipv4_at(packet, 24)
    // Someone answering for the address DHCP offered, or one already ours: it's in use (RFC 2131 §4.4.1, RFC 5227)
    if !is_zero_ipv4(sender) && !same_mac(sender_mac, stack.mac) {
        if stack.dhcp == .Requesting && same_ipv4(sender, stack.offered) {
            decline(stack)
            return void
        }
    }
    ours :: !is_zero_ipv4(stack.ipv4) && same_ipv4(target, stack.ipv4)
    // A sender is learned if it's known already, or it's asking us (RFC 826's merge)
    if !is_zero_ipv4(sender) {
        learn_neighbour(stack, true, ipv6_of4(sender), sender_mac, ours)
    }
    if operation == ARP_REQUEST && ours {
        reply : u8[ARP_PACKET]
        bytes :: view_of(&reply[0], reply.count)
        put_arp(bytes, ARP_REPLY, stack.mac, stack.ipv4, sender_mac, sender)
        queue_frame(stack, sender_mac, ETHER_ARP, bytes)
    }
}

/**
 * Write an ARP packet for IPv4 over Ethernet.
 *
 * @param bytes Where, ARP_PACKET bytes.
 * @param operation ARP_REQUEST or ARP_REPLY.
 * @param sender_mac The sender's MAC address.
 * @param sender The sender's IPv4 address.
 * @param target_mac The target's MAC address, zeroes for a request.
 * @param target The target's IPv4 address.
 */
put_arp :: fn(bytes: mut u8[], operation: u16, sender_mac: Mac, sender: Ipv4, target_mac: Mac, target: Ipv4) {
    put_u16(bytes, 0, 1)
    put_u16(bytes, 2, ETHER_IPV4)
    put_u8(bytes, 4, 6)
    put_u8(bytes, 5, 4)
    put_u16(bytes, 6, operation)
    put_mac(bytes, 8, sender_mac)
    put_bytes(bytes, 14, view_of(&sender.bytes[0], sender.bytes.count))
    put_mac(bytes, 18, target_mac)
    put_bytes(bytes, 24, view_of(&target.bytes[0], target.bytes.count))
}

/**
 * Broadcast an ARP request for an address, from the interface's address, or 0.0.0.0 without one, as a probe is.
 *
 * @param stack The stack.
 * @param target The address asked for.
 */
send_arp_request :: fn(stack: ptr[mut Stack], target: Ipv4) {
    request : u8[ARP_PACKET]
    bytes :: view_of(&request[0], request.count)
    put_arp(bytes, ARP_REQUEST, stack.mac, stack.ipv4, Mac.{}, target)
    queue_frame(stack, BROADCAST_MAC, ETHER_ARP, bytes)
}

/**
 * Take an IPv4 packet: check its header, and pass what it carries on, if it's for the interface.
 *
 * @param stack The stack.
 * @param from_mac Its Ethernet source.
 * @param packet The packet, after the Ethernet header, maybe padded past its total length.
 */
receive_ipv4 :: fn(stack: ptr[mut Stack], from_mac: Mac, packet: u8[]) {
    if packet.count < IPV4_HEADER || byte_at(packet, 0) >> 4 != 4 {
        return void
    }
    header_length :: cast[usize](byte_at(packet, 0) & 0xf) * 4
    total :: cast[usize](u16_at(packet, 2))
    if header_length < IPV4_HEADER || total < header_length || total > packet.count {
        return void
    }
    if checksum_finish(checksum_add(0, packet[0..<header_length])) != 0 {
        return void
    }
    // Fragments aren't put back together: a later fragment, or a first with more to come, is dropped
    flags_and_offset :: u16_at(packet, 6)
    if flags_and_offset & 0x3fff != 0 {
        return void
    }
    protocol :: byte_at(packet, 9)
    source :: ipv4_at(packet, 12)
    destination :: ipv4_at(packet, 16)
    /*
     * A source no host sends from, broadcast, multicast, loopback or the interface's own, is dropped, as an answer to
     * it would go to every host or back to this one (RFC 1122 §3.2.1.3); 0.0.0.0 only comes with UDP, from DHCP
     */
    if same_ipv4(source, LIMITED_BROADCAST) || source.bytes[0] >= 224 || source.bytes[0] == 127 || is_subnet_broadcast(stack, source)
        || (!is_zero_ipv4(stack.ipv4) && same_ipv4(source, stack.ipv4)) || (is_zero_ipv4(source) && protocol != PROTOCOL_UDP) {
        return void
    }
    to_us :: !is_zero_ipv4(stack.ipv4) && same_ipv4(destination, stack.ipv4)
    broadcast :: same_ipv4(destination, LIMITED_BROADCAST) || is_subnet_broadcast(stack, destination)
    // Before an address is leased, DHCP's answers may come to the address offered
    if !to_us && !broadcast && stack.dhcp == .Off {
        return void
    }
    payload :: packet[header_length..<total]
    if protocol == PROTOCOL_ICMP && to_us {
        receive_icmp(stack, source, payload)
    }
    else if protocol == PROTOCOL_TCP && to_us {
        receive_tcp(stack, .V4(source), pseudo_sum_v4(source, destination, PROTOCOL_TCP, payload.count), payload)
    }
    else if protocol == PROTOCOL_UDP {
        receive_udp4(stack, source, destination, payload)
    }
}

/**
 * Tell whether an address is the broadcast address of the interface's network.
 *
 * @param stack The stack, whose address and prefix length say its network.
 * @param address The address.
 * @return True if it's in the network, its host bits all ones; false without an address.
 */
is_subnet_broadcast :: fn(stack: ptr[Stack], address: Ipv4) -> bool {
    if is_zero_ipv4(stack.ipv4) || stack.prefix_length >= 31 || !same_prefix_v4(address, stack.ipv4, stack.prefix_length) {
        return false
    }
    host_bits :: 32 - cast[u32](stack.prefix_length)
    host_mask :: (cast[u32](1) << host_bits) - 1
    return u32_of(address) & host_mask == host_mask
}

/**
 * Read an IPv4 address as a u32, its first byte highest.
 *
 * @param address The address.
 * @return Its value.
 */
u32_of :: fn(address: Ipv4) -> u32 {
    return u32_at(view_of(&address.bytes[0], address.bytes.count), 0)
}

/**
 * Make an IPv4 address of a u32, its highest byte first.
 *
 * @param value The value.
 * @return The address.
 */
ipv4_of_u32 :: fn(value: u32) -> Ipv4 {
    address := Ipv4.{}
    put_u32(view_of(&address.bytes[0], address.bytes.count), 0, value)
    return address
}

/**
 * Take an ICMP message to the interface: answer an echo request, and note an echo reply.
 *
 * @param stack The stack.
 * @param source Who sent it.
 * @param message The message, after the IP header.
 */
receive_icmp :: fn(stack: ptr[mut Stack], source: Ipv4, message: u8[]) {
    if message.count < 8 || checksum_finish(checksum_add(0, message)) != 0 {
        return void
    }
    kind :: byte_at(message, 0)
    if kind == ICMP_ECHO_REQUEST {
        reply : u8[MAX_FRAME]
        length :: if message.count < reply.count - IPV4_HEADER - ETHERNET_HEADER { message.count } else { reply.count - IPV4_HEADER - ETHERNET_HEADER }
        bytes :: view_of(&reply[0], length)
        put_bytes(bytes, 0, message)
        put_u8(bytes, 0, ICMP_ECHO_REPLY)
        put_u16(bytes, 2, 0)
        put_u16(bytes, 2, checksum_finish(checksum_add(0, bytes)))
        _ = send_ipv4(stack, source, PROTOCOL_ICMP, bytes)
    }
    else if kind == ICMP_ECHO_REPLY {
        echo_answered(stack, .V4(source), u16_at(message, 4), u16_at(message, 6))
    }
}

/**
 * Send an ICMP echo request.
 *
 * @param stack The stack, which needs an IPv4 address.
 * @param to Who's pinged.
 * @param sequence Its sequence number.
 * @return True once it's queued or waiting for its hop; false without an address or a route.
 */
send_echo_v4 :: fn(stack: ptr[mut Stack], to: Ipv4, sequence: u16) -> bool {
    request : u8[16]
    bytes :: view_of(&request[0], request.count)
    put_u8(bytes, 0, ICMP_ECHO_REQUEST)
    put_u16(bytes, 4, ECHO_IDENTIFIER)
    put_u16(bytes, 6, sequence)
    put_u32(bytes, 8, 0x536c6f70)
    put_u16(bytes, 2, checksum_finish(checksum_add(0, bytes)))
    return send_ipv4(stack, to, PROTOCOL_ICMP, bytes)
}

/**
 * Send an IPv4 packet from the interface's address, or 0.0.0.0 without one, to its next hop: the destination if it's
 * on the link or a broadcast, else the router.
 *
 * @param stack The stack.
 * @param to The destination.
 * @param protocol What the payload is: PROTOCOL_ICMP, PROTOCOL_UDP.
 * @param payload The payload, at most the MTU less the header; more is cut off.
 * @return True once it's queued or waiting for its hop; false if there's no route: no address and not a broadcast, or
 *     off the link without a router.
 */
send_ipv4 :: fn(stack: ptr[mut Stack], to: Ipv4, protocol: u8, payload: u8[]) -> bool {
    packet : u8[MAX_FRAME]
    most :: cast[usize](stack.mtu)
    total :: if IPV4_HEADER + payload.count < most { IPV4_HEADER + payload.count } else { most }
    bytes :: view_of(&packet[0], if total < packet.count { total } else { packet.count })
    put_u8(bytes, 0, 0x45)
    put_u16(bytes, 2, cast[u16](bytes.count))
    stack.ip_identification += 1
    put_u16(bytes, 4, stack.ip_identification)
    // Don't fragment
    put_u16(bytes, 6, 0x4000)
    put_u8(bytes, 8, IPV4_TTL)
    put_u8(bytes, 9, protocol)
    put_bytes(bytes, 12, view_of(&stack.ipv4.bytes[0], stack.ipv4.bytes.count))
    put_bytes(bytes, 16, view_of(&to.bytes[0], to.bytes.count))
    put_u16(bytes, 10, checksum_finish(checksum_add(0, part(bytes, 0, IPV4_HEADER))))
    put_bytes(bytes, IPV4_HEADER, payload)
    if same_ipv4(to, LIMITED_BROADCAST) || is_subnet_broadcast(stack, to) {
        queue_frame(stack, BROADCAST_MAC, ETHER_IPV4, bytes)
        return true
    }
    if is_zero_ipv4(stack.ipv4) {
        return false
    }
    hop := to
    if !same_prefix_v4(to, stack.ipv4, stack.prefix_length) {
        if is_zero_ipv4(stack.router) {
            return false
        }
        hop = stack.router
    }
    return send_to_hop(stack, true, ipv6_of4(hop), bytes)
}

/**
 * Set the interface's IPv4 address by hand, DHCP stopped.
 *
 * @param stack The stack.
 * @param address The address; 0.0.0.0 for none.
 * @param prefix_length Its network's prefix length, 0 to 32.
 * @param router The default router; 0.0.0.0 for none.
 */
set_ipv4 :: fn(stack: ptr[mut Stack], address: Ipv4, prefix_length: u8, router: Ipv4) {
    stack.dhcp = .Off
    stack.ipv4 = address
    stack.prefix_length = if prefix_length > 32 { cast[u8](32) } else { prefix_length }
    stack.router = router
}
