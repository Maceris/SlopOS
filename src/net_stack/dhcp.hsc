package net_stack

/*
 * DHCPv4 (RFC 2131, options RFC 2132), the client: DISCOVER, OFFER, REQUEST and ACK, retried with backoff; renewed at
 * T1 with the server that leased it, rebound at T2 with any, and lost at the lease's end. An ACK's address is announced
 * by a gratuitous ARP; an offered address someone answers ARP for is declined. Its UDP (RFC 768) is only this.
 */

/** The bytes of a UDP header. */
UDP_HEADER :: 8
/** DHCP's server port. */
DHCP_SERVER_PORT : u16 : 67
/** DHCP's client port. */
DHCP_CLIENT_PORT : u16 : 68
/** Where a DHCP message's options start: after its fixed fields and the magic cookie. */
DHCP_OPTIONS_AT :: 240
/**
 * The bytes of the DHCP messages it sends: 548, so with their UDP and IP headers they're the 576 bytes every host takes
 * (RFC 2131 §2), the options padded out. Some servers, QEMU's user-mode network's among them, read only messages that
 * long, which BOOTP's 300 isn't.
 */
DHCP_MESSAGE :: 548
/** The first retry's wait, 4 s, doubled for each after it up to DHCP_MOST_WAIT (RFC 2131 §4.1). */
DHCP_FIRST_WAIT : u64 : 4 * SECOND
/** The longest wait between retries: 64 s. */
DHCP_MOST_WAIT : u64 : 64 * SECOND
/** How long after a decline before starting again: 10 s (RFC 2131 §3.1). */
DHCP_DECLINE_WAIT : u64 : 10 * SECOND

// DHCP's message types (option 53)
DHCP_DISCOVER : u8 : 1
DHCP_OFFER : u8 : 2
DHCP_REQUEST : u8 : 3
DHCP_DECLINE : u8 : 4
DHCP_ACK : u8 : 5
DHCP_NAK : u8 : 6

// DHCP's options
OPTION_PAD : u8 : 0
OPTION_SUBNET_MASK : u8 : 1
OPTION_ROUTER : u8 : 3
OPTION_DNS : u8 : 6
OPTION_REQUESTED_ADDRESS : u8 : 50
OPTION_LEASE_TIME : u8 : 51
OPTION_MESSAGE_TYPE : u8 : 53
OPTION_SERVER : u8 : 54
OPTION_PARAMETERS : u8 : 55
OPTION_T1 : u8 : 58
OPTION_T2 : u8 : 59
OPTION_END : u8 : 255

/** What a DHCP message from a server says, as read from its options. */
DhcpAnswer :: struct {
    kind : u8,
    address : Ipv4,
    server : Ipv4,
    prefix_length : u8,
    router : Ipv4,
    dns : Ipv4,
    lease : u32,
    t1 : u32,
    t2 : u32,
}

/**
 * Start DHCP afresh: no address, a new transaction, and a DISCOVER.
 *
 * @param stack The stack.
 */
start_dhcp :: fn(stack: ptr[mut Stack]) {
    stack.ipv4 = Ipv4.{}
    stack.prefix_length = 0
    stack.router = Ipv4.{}
    stack.dhcp = .Selecting
    stack.xid = cast[u32](next_random(stack))
    stack.dhcp_tries = 0
    stack.dhcp_started = stack.now
    send_dhcp(stack, DHCP_DISCOVER)
}

/**
 * Do what DHCP has due: retries, renewal, rebinding, and the lease's end.
 *
 * @param stack The stack.
 */
tick_dhcp :: fn(stack: ptr[mut Stack]) {
    if stack.dhcp == .Off || stack.now < stack.dhcp_deadline {
        return void
    }
    match stack.dhcp {
        case .Selecting => {
            // A decline's wait over, or a retry
            if stack.dhcp_tries == 0 && is_zero_ipv4(stack.offered) && stack.xid == 0 {
                start_dhcp(stack)
            }
            else {
                send_dhcp(stack, DHCP_DISCOVER)
            }
        }
        case .Requesting => {
            if stack.dhcp_tries >= 4 {
                start_dhcp(stack)
            }
            else {
                send_dhcp(stack, DHCP_REQUEST)
            }
        }
        case .Bound => {
            stack.dhcp = .Renewing
            stack.dhcp_tries = 0
            stack.xid = cast[u32](next_random(stack))
            send_dhcp(stack, DHCP_REQUEST)
        }
        case .Renewing => {
            if stack.now >= stack.lease_t2 {
                stack.dhcp = .Rebinding
                stack.dhcp_tries = 0
            }
            if stack.now >= stack.lease_end {
                lose_lease(stack)
                return void
            }
            send_dhcp(stack, DHCP_REQUEST)
        }
        case .Rebinding => {
            if stack.now >= stack.lease_end {
                lose_lease(stack)
                return void
            }
            send_dhcp(stack, DHCP_REQUEST)
        }
        case .Off => {}
    }
}

/**
 * End a lease that wasn't renewed: the address goes, the caller's told, and DHCP starts again.
 *
 * @param stack The stack.
 */
lose_lease :: fn(stack: ptr[mut Stack]) {
    event(stack, .LeaseLost)
    start_dhcp(stack)
}

/**
 * Decline an offered address someone else answers for (DHCPDECLINE), and start again after DHCP_DECLINE_WAIT.
 *
 * @param stack The stack, requesting an offered address.
 */
decline :: fn(stack: ptr[mut Stack]) {
    event(stack, .AddressConflict(.V4(stack.offered)))
    send_dhcp(stack, DHCP_DECLINE)
    stack.offered = Ipv4.{}
    stack.dhcp = .Selecting
    stack.xid = 0
    stack.dhcp_tries = 0
    stack.dhcp_deadline = stack.now + DHCP_DECLINE_WAIT
}

/**
 * Send a DHCP message of a kind, as the state has it: broadcast, except a renewal's REQUEST, which goes to the server
 * that leased the address; and set when it's tried again.
 *
 * @param stack The stack.
 * @param kind DHCP_DISCOVER, DHCP_REQUEST or DHCP_DECLINE.
 */
send_dhcp :: fn(stack: ptr[mut Stack], kind: u8) {
    message : u8[DHCP_MESSAGE]
    bytes :: view_of(&message[0], message.count)
    put_u8(bytes, 0, 1)
    put_u8(bytes, 1, 1)
    put_u8(bytes, 2, 6)
    put_u32(bytes, 4, stack.xid)
    seconds :: (stack.now - stack.dhcp_started) / SECOND
    put_u16(bytes, 8, if seconds > 0xffff { cast[u16](0xffff) } else { cast[u16](seconds) })
    renewing :: stack.dhcp == .Renewing || stack.dhcp == .Rebinding
    if renewing {
        put_bytes(bytes, 12, view_of(&stack.ipv4.bytes[0], stack.ipv4.bytes.count))
    }
    put_mac(bytes, 28, stack.mac)
    put_u32(bytes, 236, 0x63825363)
    at := cast[usize](DHCP_OPTIONS_AT)
    put_u8(bytes, at, OPTION_MESSAGE_TYPE)
    put_u8(bytes, at + 1, 1)
    put_u8(bytes, at + 2, kind)
    at += 3
    if (kind == DHCP_REQUEST && stack.dhcp == .Requesting) || kind == DHCP_DECLINE {
        put_u8(bytes, at, OPTION_REQUESTED_ADDRESS)
        put_u8(bytes, at + 1, 4)
        put_bytes(bytes, at + 2, view_of(&stack.offered.bytes[0], stack.offered.bytes.count))
        put_u8(bytes, at + 6, OPTION_SERVER)
        put_u8(bytes, at + 7, 4)
        put_bytes(bytes, at + 8, view_of(&stack.dhcp_server.bytes[0], stack.dhcp_server.bytes.count))
        at += 12
    }
    if kind != DHCP_DECLINE {
        put_u8(bytes, at, OPTION_PARAMETERS)
        put_u8(bytes, at + 1, 3)
        put_u8(bytes, at + 2, OPTION_SUBNET_MASK)
        put_u8(bytes, at + 3, OPTION_ROUTER)
        put_u8(bytes, at + 4, OPTION_DNS)
        at += 5
    }
    put_u8(bytes, at, OPTION_END)
    to :: if stack.dhcp == .Renewing { stack.dhcp_server } else { LIMITED_BROADCAST }
    _ = send_udp4(stack, to, DHCP_CLIENT_PORT, DHCP_SERVER_PORT, bytes)
    // The next try's wait: doubling from DHCP_FIRST_WAIT to DHCP_MOST_WAIT, give or take a second (RFC 2131 §4.1)
    wait := DHCP_FIRST_WAIT
    for i in 0..<stack.dhcp_tries {
        if wait >= DHCP_MOST_WAIT {
            break
        }
        wait *= 2
    }
    if wait > DHCP_MOST_WAIT {
        wait = DHCP_MOST_WAIT
    }
    if renewing {
        // Half the time left to T2, or to the lease's end, but at least 60 s (RFC 2131 §4.4.5)
        until :: if stack.dhcp == .Renewing { stack.lease_t2 } else { stack.lease_end }
        half :: if until > stack.now { (until - stack.now) / 2 } else { cast[u64](0) }
        wait = if half > 60 * SECOND { half } else { 60 * SECOND }
        if stack.now + wait > until {
            wait = if until > stack.now { until - stack.now } else { cast[u64](0) }
        }
    }
    stack.dhcp_tries += 1
    stack.dhcp_deadline = stack.now + wait - SECOND + next_random(stack) % (2 * SECOND)
}

/**
 * Take a UDP datagram to IPv4: a DHCP server's answer is DHCP's; anything else is dropped.
 *
 * @param stack The stack.
 * @param source Who sent it.
 * @param destination Who it's for.
 * @param datagram The datagram, from its UDP header.
 */
receive_udp4 :: fn(stack: ptr[mut Stack], source: Ipv4, destination: Ipv4, datagram: u8[]) {
    if datagram.count < UDP_HEADER {
        return void
    }
    length :: cast[usize](u16_at(datagram, 4))
    if length < UDP_HEADER || length > datagram.count {
        return void
    }
    whole :: datagram[0..<length]
    if u16_at(whole, 6) != 0 && checksum_finish(pseudo_sum_v4(source, destination, PROTOCOL_UDP, length) + checksum_add(0, whole)) != 0 {
        return void
    }
    if u16_at(whole, 0) == DHCP_SERVER_PORT && u16_at(whole, 2) == DHCP_CLIENT_PORT {
        receive_dhcp(stack, part(whole, UDP_HEADER, length))
    }
    else if !is_zero_ipv4(stack.ipv4) && same_ipv4(destination, stack.ipv4) {
        deliver_datagram(stack, .V4(source), u16_at(whole, 0), u16_at(whole, 2), part(whole, UDP_HEADER, length))
    }
}

/**
 * Give the sum of an IPv4 pseudo-header, for a UDP or TCP checksum.
 *
 * @param source The source address.
 * @param destination The destination address.
 * @param protocol The protocol.
 * @param length The UDP or TCP length, header and payload.
 * @return The sum, not folded.
 */
pseudo_sum_v4 :: fn(source: Ipv4, destination: Ipv4, protocol: u8, length: usize) -> u64 {
    sum := checksum_add(0, view_of(&source.bytes[0], source.bytes.count))
    sum = checksum_add(sum, view_of(&destination.bytes[0], destination.bytes.count))
    return sum + cast[u64](protocol) + cast[u64](length)
}

/**
 * Send a UDP datagram over IPv4, its checksum made.
 *
 * @param stack The stack.
 * @param to Its destination.
 * @param from_port Its source port.
 * @param to_port Its destination port.
 * @param payload What it carries.
 * @return True once it's queued or waiting; false if there's no route.
 */
send_udp4 :: fn(stack: ptr[mut Stack], to: Ipv4, from_port: u16, to_port: u16, payload: u8[]) -> bool {
    datagram : u8[MAX_FRAME]
    length :: if UDP_HEADER + payload.count < datagram.count - IPV4_HEADER - ETHERNET_HEADER { UDP_HEADER + payload.count }
        else { datagram.count - IPV4_HEADER - ETHERNET_HEADER }
    bytes :: view_of(&datagram[0], length)
    put_u16(bytes, 0, from_port)
    put_u16(bytes, 2, to_port)
    put_u16(bytes, 4, cast[u16](length))
    put_bytes(bytes, UDP_HEADER, payload)
    checksum := checksum_finish(pseudo_sum_v4(stack.ipv4, to, PROTOCOL_UDP, length) + checksum_add(0, bytes))
    if checksum == 0 {
        checksum = 0xffff
    }
    put_u16(bytes, 6, checksum)
    return send_ipv4(stack, to, PROTOCOL_UDP, bytes)
}

/**
 * Read a DHCP server's message.
 *
 * @param message The message, after the UDP header.
 * @return What it says; kind 0 if it isn't a server's reply with the magic cookie and a message type.
 */
read_dhcp :: fn(message: u8[]) -> DhcpAnswer {
    answer := DhcpAnswer.{}
    if message.count < DHCP_OPTIONS_AT || byte_at(message, 0) != 2 || u32_at(message, 236) != 0x63825363 {
        return answer
    }
    answer.address = ipv4_at(message, 16)
    at := cast[usize](DHCP_OPTIONS_AT)
    loop {
        if at >= message.count {
            break
        }
        code :: byte_at(message, at)
        if code == OPTION_END {
            break
        }
        if code == OPTION_PAD {
            at += 1
            continue
        }
        length :: cast[usize](byte_at(message, at + 1))
        value :: at + 2
        if value + length > message.count {
            break
        }
        if code == OPTION_MESSAGE_TYPE && length >= 1 {
            answer.kind = byte_at(message, value)
        }
        else if code == OPTION_SUBNET_MASK && length >= 4 {
            answer.prefix_length = prefix_of_mask(u32_at(message, value))
        }
        else if code == OPTION_ROUTER && length >= 4 {
            answer.router = ipv4_at(message, value)
        }
        else if code == OPTION_DNS && length >= 4 {
            answer.dns = ipv4_at(message, value)
        }
        else if code == OPTION_LEASE_TIME && length >= 4 {
            answer.lease = u32_at(message, value)
        }
        else if code == OPTION_SERVER && length >= 4 {
            answer.server = ipv4_at(message, value)
        }
        else if code == OPTION_T1 && length >= 4 {
            answer.t1 = u32_at(message, value)
        }
        else if code == OPTION_T2 && length >= 4 {
            answer.t2 = u32_at(message, value)
        }
        at = value + length
    }
    return answer
}

/**
 * Give a subnet mask's prefix length: how many ones it starts with.
 *
 * @param mask The mask.
 * @return 0 to 32.
 */
prefix_of_mask :: fn(mask: u32) -> u8 {
    length := cast[u8](0)
    bit := cast[u32](0x80000000)
    loop {
        if bit == 0 || mask & bit == 0 {
            break
        }
        length += 1
        bit >>= 1
    }
    while true
    return length
}

/**
 * Take a DHCP server's message: an OFFER while selecting, an ACK or NAK while requesting, renewing or rebinding.
 *
 * @param stack The stack.
 * @param message The message, after the UDP header.
 */
receive_dhcp :: fn(stack: ptr[mut Stack], message: u8[]) {
    if stack.dhcp == .Off || stack.dhcp == .Bound || u32_at(message, 4) != stack.xid || !same_mac(mac_at(message, 28), stack.mac) {
        return void
    }
    answer :: read_dhcp(message)
    if answer.kind == DHCP_OFFER && stack.dhcp == .Selecting && stack.xid != 0 && !is_zero_ipv4(answer.address) {
        stack.offered = answer.address
        stack.dhcp_server = answer.server
        stack.dhcp = .Requesting
        stack.dhcp_tries = 0
        send_dhcp(stack, DHCP_REQUEST)
    }
    else if answer.kind == DHCP_ACK && stack.dhcp != .Selecting && !is_zero_ipv4(answer.address) {
        bind(stack, answer)
    }
    else if answer.kind == DHCP_NAK && stack.dhcp != .Selecting {
        if stack.dhcp != .Requesting {
            event(stack, .LeaseLost)
        }
        start_dhcp(stack)
    }
}

/**
 * Take an ACK's lease: the address, its network and router, and when to renew, rebind and give it up.
 *
 * @param stack The stack.
 * @param answer The ACK.
 */
bind :: fn(stack: ptr[mut Stack], answer: DhcpAnswer) {
    stack.ipv4 = answer.address
    stack.prefix_length = if answer.prefix_length != 0 { answer.prefix_length } else { cast[u8](24) }
    stack.router = answer.router
    stack.dns = answer.dns
    if !is_zero_ipv4(answer.server) {
        stack.dhcp_server = answer.server
    }
    stack.offered = Ipv4.{}
    lease :: if answer.lease == 0 { cast[u32](3600) } else { answer.lease }
    stack.dhcp = .Bound
    stack.dhcp_tries = 0
    if lease == 0xffffffff {
        stack.lease_t1 = ~cast[u64](0)
        stack.lease_t2 = ~cast[u64](0)
        stack.lease_end = ~cast[u64](0)
    }
    else {
        // T1 and T2 at half and seven eighths of the lease unless the server says (RFC 2131 §4.4.5)
        t1 :: if answer.t1 != 0 && answer.t1 < lease { answer.t1 } else { lease / 2 }
        t2 :: if answer.t2 != 0 && answer.t2 < lease && answer.t2 > t1 { answer.t2 } else { lease / 8 * 7 }
        stack.lease_t1 = stack.now + cast[u64](t1) * SECOND
        stack.lease_t2 = stack.now + cast[u64](t2) * SECOND
        stack.lease_end = stack.now + cast[u64](lease) * SECOND
    }
    stack.dhcp_deadline = stack.lease_t1
    // Announced (RFC 5227 §2.3), so the link's caches have it
    gratuitous : u8[ARP_PACKET]
    bytes :: view_of(&gratuitous[0], gratuitous.count)
    put_arp(bytes, ARP_REQUEST, stack.mac, stack.ipv4, Mac.{}, stack.ipv4)
    queue_frame(stack, BROADCAST_MAC, ETHER_ARP, bytes)
    event(stack, .Leased(Lease.{address = stack.ipv4, prefix_length = stack.prefix_length, router = stack.router,
        dns = stack.dns, server = stack.dhcp_server, seconds = lease}))
}
