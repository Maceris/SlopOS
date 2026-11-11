package net_stack

/*
 * UDP sockets (RFC 768): a socket is a port, for both families; a datagram to it waits in the stack's inbox, which the
 * caller empties with take_datagram, until the inbox fills, and then the newest are dropped. A socket with datagrams
 * waiting is marked, and take_ready gives each marked once. A datagram to a port no socket has is dropped, without an
 * ICMP error.
 */

/** How many UDP sockets the stack holds at once. */
UDP_SOCKETS :: 16
/** How many datagrams wait to be taken, all sockets together. */
UDP_INBOX :: 32
/** The longest datagram payload it takes or sends: an Ethernet MTU less IPv4's and UDP's headers. */
MAX_DATAGRAM :: 1472

/** A UDP socket. */
UdpSocket :: struct {
    active : bool,
    generation : u16,
    port : u16,
    /** Whether it's marked as having datagrams waiting. */
    ready : bool,
}

/** A datagram waiting to be taken. */
Datagram :: struct {
    /** The socket it's for, by number; 0 for an empty place. */
    socket : u32,
    from : IpAddress,
    from_port : u16,
    length : usize,
    bytes : u8[MAX_DATAGRAM],
}

/** Who sent a datagram taken, and how long it is. */
DatagramFrom :: struct {
    from : IpAddress,
    from_port : u16,
    /** Its payload's length; past the bytes given, the rest was cut off. */
    length : usize,
}

/**
 * Open a UDP socket on a port.
 *
 * @param stack The stack.
 * @param port The port, or 0 for an ephemeral one.
 * @return The socket's number, never 0; null if the port's taken, or every socket is.
 */
udp_open :: fn(stack: ptr[mut Stack], port: u16) -> u32? {
    chosen := port
    if chosen == 0 {
        span :: cast[u64](65536) - cast[u64](EPHEMERAL_FIRST)
        start :: next_random(stack) % span
        for i in cast[u64](0)..<span {
            candidate :: cast[u16](cast[u64](EPHEMERAL_FIRST) + (start + i) % span)
            if !udp_port_taken(stack, candidate) {
                chosen = candidate
                break
            }
        }
        if chosen == 0 {
            return null
        }
    }
    else if udp_port_taken(stack, chosen) {
        return null
    }
    for &socket, i in stack.sockets {
        if !socket.active {
            socket.generation += 1
            if socket.generation == 0 {
                socket.generation = 1
            }
            socket.active = true
            socket.port = chosen
            socket.ready = false
            return (cast[u32](socket.generation) << 16) | cast[u32](i)
        }
    }
    return null
}

/**
 * Tell whether a UDP port has a socket.
 *
 * @param stack The stack.
 * @param port The port.
 * @return True if it has.
 */
udp_port_taken :: fn(stack: ptr[Stack], port: u16) -> bool {
    for socket in stack.sockets {
        if socket.active && socket.port == port {
            return true
        }
    }
    return false
}

/**
 * Close a UDP socket; its datagrams waiting are dropped.
 *
 * @param stack The stack.
 * @param socket The socket.
 */
udp_close :: fn(stack: ptr[mut Stack], socket: u32) {
    found :: find_socket(stack, socket) or_return void
    found.active = false
    for &datagram in stack.inbox {
        if datagram.socket == socket {
            datagram.socket = 0
        }
    }
}

/**
 * Find a socket by number.
 *
 * @param stack The stack.
 * @param socket The number.
 * @return It; null if it's closed, or never was.
 */
find_socket :: fn(stack: ptr[mut Stack], socket: u32) -> ptr[mut UdpSocket]? {
    index :: cast[usize](socket & 0xffff)
    if index >= stack.sockets.count {
        return null
    }
    found :: &stack.sockets[index]
    if !found.active || cast[u32](found.generation) != socket >> 16 {
        return null
    }
    return found
}

/**
 * Give a socket's port.
 *
 * @param stack The stack.
 * @param socket The socket.
 * @return Its port; 0 if it's closed.
 */
udp_port :: fn(stack: ptr[mut Stack], socket: u32) -> u16 {
    found :: find_socket(stack, socket) or_return 0
    return found.port
}

/**
 * Send a datagram from a socket.
 *
 * @param stack The stack.
 * @param socket The socket.
 * @param to Who it's to.
 * @param to_port Their port.
 * @param payload What it carries, at most MAX_DATAGRAM bytes; more is cut off.
 * @return True once it's queued or waiting for its hop; false if the socket's closed, or there's no route.
 */
udp_send :: fn(stack: ptr[mut Stack], socket: u32, to: IpAddress, to_port: u16, payload: u8[]) -> bool {
    found :: find_socket(stack, socket) or_return false
    port :: found.port
    return match to {
        case V4(address) => send_udp4(stack, address, port, to_port, payload)
        case V6(address) => send_udp6(stack, address, port, to_port, payload)
    }
}

/**
 * Send a UDP datagram over IPv6, its checksum made.
 *
 * @param stack The stack.
 * @param to Its destination.
 * @param from_port Its source port.
 * @param to_port Its destination port.
 * @param payload What it carries.
 * @return True once it's queued or waiting; false if there's no route or source address.
 */
send_udp6 :: fn(stack: ptr[mut Stack], to: Ipv6, from_port: u16, to_port: u16, payload: u8[]) -> bool {
    from :: source_for(stack, to)
    if is_zero_ipv6(from) {
        return false
    }
    datagram : u8[MAX_FRAME]
    most :: datagram.count - IPV6_HEADER - ETHERNET_HEADER
    length :: if UDP_HEADER + payload.count < most { UDP_HEADER + payload.count } else { most }
    bytes :: view_of(&datagram[0], length)
    put_u16(bytes, 0, from_port)
    put_u16(bytes, 2, to_port)
    put_u16(bytes, 4, cast[u16](length))
    put_bytes(bytes, UDP_HEADER, payload)
    checksum := checksum_finish(pseudo_sum_v6(from, to, PROTOCOL_UDP, length) + checksum_add(0, bytes))
    if checksum == 0 {
        checksum = 0xffff
    }
    put_u16(bytes, 6, checksum)
    return send_ipv6(stack, from, to, PROTOCOL_UDP, bytes, stack.hop_limit)
}

/**
 * Deliver a datagram to the socket on its port, if there's one, into the inbox.
 *
 * @param stack The stack.
 * @param from Who sent it.
 * @param from_port Their port.
 * @param to_port The port it's to.
 * @param payload Its payload.
 */
deliver_datagram :: fn(stack: ptr[mut Stack], from: IpAddress, from_port: u16, to_port: u16, payload: u8[]) {
    for &socket, i in stack.sockets {
        if !socket.active || socket.port != to_port {
            continue
        }
        for &datagram in stack.inbox {
            if datagram.socket == 0 {
                datagram.socket = (cast[u32](socket.generation) << 16) | cast[u32](i)
                datagram.from = from
                datagram.from_port = from_port
                datagram.length = if payload.count < datagram.bytes.count { payload.count } else { datagram.bytes.count }
                put_bytes(view_of(&datagram.bytes[0], datagram.bytes.count), 0, payload)
                socket.ready = true
                return void
            }
        }
        stack.dropped_datagrams += 1
        return void
    }
}

/**
 * Take a socket's oldest waiting datagram.
 *
 * @param stack The stack.
 * @param socket The socket.
 * @param into Where its payload goes; what doesn't fit is dropped.
 * @return Who sent it and its length; null if none waits.
 */
take_datagram :: fn(stack: ptr[mut Stack], socket: u32, into: mut u8[]) -> DatagramFrom? {
    for &datagram in stack.inbox {
        if datagram.socket == socket && socket != 0 {
            datagram.socket = 0
            put_bytes(into, 0, view_of(&datagram.bytes[0], if datagram.length < datagram.bytes.count { datagram.length } else { datagram.bytes.count }))
            return DatagramFrom.{from = datagram.from, from_port = datagram.from_port, length = datagram.length}
        }
    }
    return null
}

/**
 * Take a socket marked as having datagrams waiting.
 *
 * @param stack The stack.
 * @return Its number; null if none is marked.
 */
take_ready :: fn(stack: ptr[mut Stack]) -> u32? {
    for &socket, i in stack.sockets {
        if socket.active && socket.ready {
            socket.ready = false
            return (cast[u32](socket.generation) << 16) | cast[u32](i)
        }
    }
    return null
}

/**
 * Take a UDP datagram to an IPv6 address of the interface's.
 *
 * @param stack The stack.
 * @param source Who sent it.
 * @param destination Who it's for.
 * @param datagram The datagram, from its UDP header.
 */
receive_udp6 :: fn(stack: ptr[mut Stack], source: Ipv6, destination: Ipv6, datagram: u8[]) {
    if datagram.count < UDP_HEADER {
        return void
    }
    length :: cast[usize](u16_at(datagram, 4))
    if length < UDP_HEADER || length > datagram.count {
        return void
    }
    whole :: part(datagram, 0, length)
    // The checksum is required over IPv6 (RFC 8200 §8.1)
    if u16_at(whole, 6) == 0 || checksum_finish(pseudo_sum_v6(source, destination, PROTOCOL_UDP, length) + checksum_add(0, whole)) != 0 {
        return void
    }
    deliver_datagram(stack, .V6(source), u16_at(whole, 0), u16_at(whole, 2), part(whole, UDP_HEADER, length))
}
