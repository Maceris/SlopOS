/*
 * The network layer (decisions/0188, 13b): Ethernet, ARP, IPv4 and ICMP, DHCPv4, IPv6, ICMPv6, neighbour discovery and
 * SLAAC, for one interface, as the network service runs it. A package of its own, with no system calls, so hosted
 * tests drive it against a simulated link.
 *
 * It's a state machine its caller drives: receive gives it a frame that arrived, tick the time, and it answers by
 * queueing frames to send, which take_frame gives, and events, which take_event gives. Time is the caller's, in
 * nanoseconds from any start; next_deadline says when tick is next wanted. Nothing in it waits or allocates: its tables
 * are fixed, and a frame for a neighbour not yet resolved waits in that neighbour's entry, one at a time, the last
 * sent winning (RFC 1122 §2.3.2.2).
 *
 * Every frame is read through bounds-checked helpers, so a short or malformed one reads zeroes past its end, and is
 * dropped by the checks that follow, never read past.
 */
/**
 * The network layer for one Ethernet interface: addresses by DHCPv4 and SLAAC, neighbours by ARP and neighbour
 * discovery, and pings, as a state machine driven by frames, time and its caller's requests.
 *
 * SPEC: RFC 826 (ARP), RFC 791 (IPv4), RFC 792 (ICMP), RFC 1122 (hosts), RFC 2131 and 2132 (DHCP), RFC 8200 (IPv6),
 *     RFC 4443 (ICMPv6), RFC 4861 (neighbour discovery), RFC 4862 (SLAAC), RFC 7217 (stable interface identifiers),
 *     RFC 4291 (IPv6 addressing), RFC 1071 (the Internet checksum)
 */
package net_stack

import crypto from "std"

// ---- Sizes

/** The longest frame it sends or takes, without the frame check sequence: 14 bytes of header and 1500 of payload. */
MAX_FRAME :: 1514
/** The bytes of an Ethernet header: two addresses and a type. */
ETHERNET_HEADER :: 14
/**
 * How many frames wait to be sent at most: 64, as many as a NIC's send slots. Past them, the newest is dropped, but
 * TCP sends nothing while there's no room (outbox_full), and goes on as there is (tcp_resume).
 */
OUTBOX :: 64
/** How many events wait to be taken at most; past them, the newest is dropped. */
EVENTS :: 128
/** How many IPv4 neighbours it knows at once. */
ARP_ENTRIES :: 16
/** How many IPv6 neighbours it knows at once. */
NEIGHBOURS :: 16
/** How many global IPv6 addresses it keeps at once, from routers' prefixes. */
GLOBAL_ADDRESSES :: 4
/** How many IPv6 routers it keeps at once. */
ROUTERS :: 2
/** How many pings wait for their answers at once. */
PINGS :: 8

// ---- Times, in nanoseconds

/** A second. */
SECOND : u64 : 1_000_000_000
/** How long a neighbour, IPv4 or IPv6, is kept once resolved: 60 s, then asked again when next used. */
NEIGHBOUR_LIFE : u64 : 60 * SECOND
/** How long between asks for a neighbour not yet resolved: 1 s (RFC 4861's RETRANS_TIMER). */
RESOLVE_INTERVAL : u64 : SECOND
/** How many asks for a neighbour before it's given up, and the frame waiting for it dropped: 3. */
RESOLVE_TRIES :: 3
/** How long a ping waits for its answer before it's forgotten: 10 s. */
PING_LIFE : u64 : 10 * SECOND

// ---- Ethernet types and IP protocols

/** Ethernet's type for IPv4. */
ETHER_IPV4 : u16 : 0x0800
/** Ethernet's type for ARP. */
ETHER_ARP : u16 : 0x0806
/** Ethernet's type for IPv6. */
ETHER_IPV6 : u16 : 0x86dd
/** IP's protocol number for ICMP. */
PROTOCOL_ICMP : u8 : 1
/** IP's protocol number for TCP. */
PROTOCOL_TCP : u8 : 6
/** IP's protocol number for UDP. */
PROTOCOL_UDP : u8 : 17
/** IP's protocol number for ICMPv6. */
PROTOCOL_ICMPV6 : u8 : 58

// ---- Addresses

/** A MAC address, in the order it's sent. */
Mac :: struct {
    bytes : u8[6],
}

/** An IPv4 address, in the order it's sent. */
Ipv4 :: struct {
    bytes : u8[4],
}

/** An IPv6 address, in the order it's sent. */
Ipv6 :: struct {
    bytes : u8[16],
}

/** An IP address of either family. */
IpAddress :: union {
    V4(Ipv4),
    V6(Ipv6),
}

/** The broadcast MAC address. */
BROADCAST_MAC :: Mac.{bytes = u8.[0xff, 0xff, 0xff, 0xff, 0xff, 0xff]}

// ---- What it tells its caller

/** An IPv4 address leased by DHCP, and what came with it. */
Lease :: struct {
    /** The address. */
    address : Ipv4,
    /** Its network's prefix length, 0 to 32. */
    prefix_length : u8,
    /** The default router; 0.0.0.0 for none. */
    router : Ipv4,
    /** The first DNS server; 0.0.0.0 for none. */
    dns : Ipv4,
    /** The DHCP server it came from. */
    server : Ipv4,
    /** How long it's leased for, in seconds; 0xffffffff for ever. */
    seconds : u32,
}

/** An IPv6 address that's become the interface's, past duplicate address detection. */
Assigned :: struct {
    /** The address. */
    address : Ipv6,
    /** Its prefix's length, 0 to 128: 64 for SLAAC's and the link-local one. */
    prefix_length : u8,
    /** Whether it's the link-local address, fe80::/64, rather than one from a router's prefix. */
    link_local : bool,
}

/** A ping answered. */
Echo :: struct {
    /** Who answered. */
    from : IpAddress,
    /** The ping's sequence number, as ping gave it. */
    sequence : u16,
    /** How long it took, in nanoseconds. */
    nanoseconds : u64,
}

/** Something its caller is told of. */
Event :: union {
    /** An IPv4 address was leased, or its lease renewed. */
    Leased(Lease),
    /** The IPv4 lease ended without being renewed; the interface has no IPv4 address now. */
    LeaseLost,
    /** An IPv6 address became the interface's. */
    AddressReady(Assigned),
    /** An address wanted was found in use by another, and isn't taken. */
    AddressConflict(IpAddress),
    /** An IPv6 router advertised itself, by its link-local address, and is a default router now. */
    RouterFound(Ipv6),
    /** A ping was answered. */
    EchoReplied(Echo),
    /** A TCP connection arrived at a listener, and waits for tcp_accept. */
    Incoming(TcpIncoming),
    /** A TCP connection ended: its number's no longer good, or, closed, in TIME-WAIT. */
    Ended(TcpEnded),
}

// ---- Its state

/** A frame waiting to be sent. */
Outgoing :: struct {
    bytes : u8[MAX_FRAME],
    length : usize,
}

/** Where a neighbour's resolution is. */
NeighbourState :: enum {
    /** The entry isn't in use. */
    Free,
    /** Asked for, not yet answered. */
    Resolving,
    /** Answered: its MAC address is known until expires. */
    Resolved,
}

/** A neighbour, IPv4 or IPv6: its address, its MAC address once known, and a frame waiting for it. */
Neighbour :: struct {
    state : NeighbourState,
    /** Its address: an IPv4 address in the first four bytes, for ARP's table. */
    address : Ipv6,
    mac : Mac,
    /** Resolving: when it's next asked for. Resolved: when it's forgotten. */
    deadline : u64,
    /** How many times it's been asked for. */
    tries : u32,
    /** An IP packet waiting for its MAC address, without its Ethernet header; length 0 for none. */
    waiting : u8[MAX_FRAME],
    waiting_length : usize,
}

/** Where DHCP is (RFC 2131 §4.4). */
DhcpState :: enum {
    /** Not running: an address set by hand, or none wanted. */
    Off,
    /** DISCOVER sent, waiting for an OFFER. */
    Selecting,
    /** REQUEST sent for an OFFER, waiting for an ACK. */
    Requesting,
    /** Leased; renewing at t1. */
    Bound,
    /** Renewing with the server that leased it, until t2. */
    Renewing,
    /** Renewing with any server, until the lease ends. */
    Rebinding,
}

/** An IPv6 address's state. */
AddressState :: enum {
    /** Not in use. */
    Free,
    /** Being checked for duplicates: not used until deadline passes without an answer (RFC 4862 §5.4). */
    Tentative,
    /** The interface's. */
    Assigned,
}

/** An IPv6 address of the interface's. */
Address6 :: struct {
    state : AddressState,
    address : Ipv6,
    prefix_length : u8,
    /** Tentative: when its check ends. Assigned: when it's no longer valid, 0 for never. */
    deadline : u64,
}

/** An IPv6 default router. */
Router6 :: struct {
    /** Its link-local address; all zeroes for none. */
    address : Ipv6,
    /** When its lifetime ends. */
    expires : u64,
}

/** A ping waiting for its answer. */
Ping :: struct {
    active : bool,
    to : IpAddress,
    sequence : u16,
    sent : u64,
}

/** The stack's state for one interface, the caller's, set up by start. */
Stack :: struct {
    mac : Mac,
    /** The largest IP packet the link carries, in bytes. */
    mtu : u16,
    /** The time as the caller last gave it. */
    now : u64,
    /** The random generator's state, from the caller's seed. */
    random : u64,
    /** A secret for stable IPv6 interface identifiers (RFC 7217), from the seed. */
    secret : u8[32],

    outbox : Outgoing[OUTBOX],
    outbox_first : usize,
    outbox_count : usize,
    events : Event[EVENTS],
    events_first : usize,
    events_count : usize,
    /** Frames dropped as the outbox was full. */
    dropped_frames : u64,

    // IPv4
    ipv4 : Ipv4,
    prefix_length : u8,
    router : Ipv4,
    dns : Ipv4,
    arp : Neighbour[ARP_ENTRIES],
    ip_identification : u16,

    // DHCPv4
    dhcp : DhcpState,
    xid : u32,
    dhcp_server : Ipv4,
    offered : Ipv4,
    dhcp_deadline : u64,
    dhcp_tries : u32,
    dhcp_started : u64,
    lease_t1 : u64,
    lease_t2 : u64,
    lease_end : u64,

    // IPv6
    link_local : Address6,
    globals : Address6[GLOBAL_ADDRESSES],
    routers : Router6[ROUTERS],
    neighbours : Neighbour[NEIGHBOURS],
    hop_limit : u8,
    solicitations : u32,
    next_solicitation : u64,

    pings : Ping[PINGS],
    ping_sequence : u16,

    // TCP and UDP
    tcbs : Tcb[TCP_CONNECTIONS],
    listeners : TcpListener[TCP_LISTENERS],
    sockets : UdpSocket[UDP_SOCKETS],
    inbox : Datagram[UDP_INBOX],
    /** Datagrams dropped as the inbox was full. */
    dropped_datagrams : u64,
    /** How many times TCP's retransmitted on duplicate acknowledgements or SACK, and on its timer, for tests. */
    fast_retransmits : u64,
    timeouts : u64,
}

/** How the stack is set up. */
Setup :: struct {
    /** The interface's MAC address. */
    mac : Mac,
    /** The largest IP packet the link carries, in bytes, at least 1280 for IPv6; 1500 for Ethernet. */
    mtu : u16 = 1500,
    /** The random generator's seed: different for each boot, so DHCP's transaction IDs and the IPv6 secret are. */
    seed : u64,
    /** Whether to ask DHCP for an IPv4 address; without it, set_ipv4 sets one by hand. */
    dhcp : bool = true,
    /** Whether to take IPv6 addresses: the link-local one, and SLAAC's from routers. */
    ipv6 : bool = true,
}

/**
 * Set up a stack and start it: DHCP's DISCOVER and IPv6's link-local address and router solicitation are queued, as
 * Setup asks.
 *
 * @param stack The stack, zeroed, as runtime.new gives it: some 100 KiB, too much to build on a stack and copy in.
 * @param setup How it's set up.
 * @param now The time, in nanoseconds.
 */
start :: fn(stack: ptr[mut Stack], setup: Setup, now: u64) {
    stack.mac = setup.mac
    stack.mtu = setup.mtu
    stack.now = now
    stack.random = setup.seed | 1
    stack.hop_limit = 64
    for &byte in stack.secret {
        byte^ = cast[u8](next_random(stack))
    }
    stack.ip_identification = cast[u16](next_random(stack))
    if setup.dhcp {
        start_dhcp(stack)
    }
    if setup.ipv6 {
        start_ipv6(stack)
    }
}

/**
 * Take a frame that arrived: answer it, learn from it, or drop it.
 *
 * @param stack The stack.
 * @param frame The frame, from its Ethernet header to its payload's end, without its frame check sequence; it isn't
 *     kept.
 * @param now The time, in nanoseconds.
 */
receive :: fn(stack: ptr[mut Stack], frame: u8[], now: u64) {
    stack.now = now
    if frame.count < ETHERNET_HEADER {
        return void
    }
    destination :: mac_at(frame, 0)
    // Ours, broadcast, or multicast (the group bit), which neighbour discovery's are
    if !same_mac(destination, stack.mac) && byte_at(frame, 0) & 1 == 0 {
        return void
    }
    payload :: frame[ETHERNET_HEADER..<frame.count]
    match u16_at(frame, 12) {
        case ETHER_ARP => receive_arp(stack, payload)
        case ETHER_IPV4 => receive_ipv4(stack, mac_at(frame, 6), payload)
        case ETHER_IPV6 => receive_ipv6(stack, mac_at(frame, 6), payload)
        case _ => {}
    }
}

/**
 * Do what's due by a time: DHCP's and neighbour discovery's retries, renewals, expiries, and duplicate address
 * detection's ends.
 *
 * @param stack The stack.
 * @param now The time, in nanoseconds, no earlier than any given before.
 */
tick :: fn(stack: ptr[mut Stack], now: u64) {
    stack.now = now
    tick_dhcp(stack)
    tick_neighbours(stack, true)
    tick_neighbours(stack, false)
    tick_ipv6(stack)
    tick_tcp(stack)
    for &ping in stack.pings {
        if ping.active && now >= ping.sent + PING_LIFE {
            ping.active = false
        }
    }
}

/**
 * Say when tick is next wanted.
 *
 * @param stack The stack.
 * @return The earliest time something's due, in nanoseconds; 0xffffffffffffffff for nothing.
 */
next_deadline :: fn(stack: ptr[Stack]) -> u64 {
    soonest := ~cast[u64](0)
    if stack.dhcp != .Off && stack.dhcp_deadline < soonest {
        soonest = stack.dhcp_deadline
    }
    for each in stack.arp {
        if each.state != .Free && each.deadline < soonest {
            soonest = each.deadline
        }
    }
    for each in stack.neighbours {
        if each.state != .Free && each.deadline < soonest {
            soonest = each.deadline
        }
    }
    if stack.link_local.state == .Tentative && stack.link_local.deadline < soonest {
        soonest = stack.link_local.deadline
    }
    for each in stack.globals {
        if each.state != .Free && each.deadline != 0 && each.deadline < soonest {
            soonest = each.deadline
        }
    }
    if stack.next_solicitation != 0 && stack.next_solicitation < soonest {
        soonest = stack.next_solicitation
    }
    for each in stack.pings {
        if each.active && each.sent + PING_LIFE < soonest {
            soonest = each.sent + PING_LIFE
        }
    }
    return tcp_deadline(stack, soonest)
}

/**
 * Take the oldest frame waiting to be sent.
 *
 * @param stack The stack, whose outbox gives it up.
 * @param into Where it's copied, MAX_FRAME bytes at least, as a send slot is.
 * @return Its length in bytes; null if none is waiting, or into is too short, when it's dropped.
 */
take_frame :: fn(stack: ptr[mut Stack], into: mut u8[]) -> usize? {
    if stack.outbox_count == 0 {
        return null
    }
    at :: stack.outbox_first % OUTBOX
    stack.outbox_first = (stack.outbox_first + 1) % OUTBOX
    stack.outbox_count -= 1
    if at >= stack.outbox.count {
        return null
    }
    frame :: &stack.outbox[at]
    if frame.length > into.count || frame.length > frame.bytes.count {
        return null
    }
    for i in 0..<frame.length {
        if i < into.count && i < frame.bytes.count {
            into[i] = frame.bytes[i]
        }
    }
    return frame.length
}

/**
 * Tell whether the outbox has room for fewer than a few more frames, so TCP holds back what it would send.
 *
 * @param stack The stack.
 * @return True if fewer than 4 frames' room is left: room kept for acknowledgements, ARP and the like.
 */
outbox_full :: fn(stack: ptr[Stack]) -> bool {
    return stack.outbox_count + 4 >= OUTBOX
}

/**
 * Take the oldest event waiting.
 *
 * @param stack The stack, whose events give it up.
 * @return It; null if none is waiting.
 */
take_event :: fn(stack: ptr[mut Stack]) -> Event? {
    if stack.events_count == 0 {
        return null
    }
    at :: stack.events_first % EVENTS
    stack.events_first = (stack.events_first + 1) % EVENTS
    stack.events_count -= 1
    return if at < stack.events.count { stack.events[at] } else { null }
}

/**
 * Ping an address: an ICMP or ICMPv6 echo request, sent once its neighbour or router is resolved; its answer comes as
 * EchoReplied.
 *
 * @param stack The stack.
 * @param to Who's pinged.
 * @return The ping's sequence number; null if no address of the family can send it, or PINGS are waiting already.
 */
ping :: fn(stack: ptr[mut Stack], to: IpAddress) -> u16? {
    slot := cast[usize](PINGS)
    for each, i in stack.pings {
        if !each.active {
            slot = i
            break
        }
    }
    if slot >= stack.pings.count {
        return null
    }
    stack.ping_sequence += 1
    sequence :: stack.ping_sequence
    sent :: match to {
        case V4(address) => send_echo_v4(stack, address, sequence)
        case V6(address) => send_echo_v6(stack, address, sequence)
    }
    if !sent {
        return null
    }
    stack.pings[slot] = Ping.{active = true, to = to, sequence = sequence, sent = stack.now}
    return sequence
}

/**
 * Note a ping's answer, if one's waiting for it, as EchoReplied.
 *
 * @param stack The stack.
 * @param from Who answered.
 * @param identifier The answer's identifier, which has to be ECHO_IDENTIFIER.
 * @param sequence The answer's sequence number.
 */
echo_answered :: fn(stack: ptr[mut Stack], from: IpAddress, identifier: u16, sequence: u16) {
    if identifier != ECHO_IDENTIFIER {
        return void
    }
    for &each in stack.pings {
        if each.active && each.sequence == sequence && same_address(each.to, from) {
            each.active = false
            event(stack, .EchoReplied(Echo.{from = from, sequence = sequence, nanoseconds = stack.now - each.sent}))
            return void
        }
    }
}

/** The identifier its echo requests carry, which their answers have to. */
ECHO_IDENTIFIER : u16 : 0x5105

// ---- Queues

/**
 * Queue a frame to send, its Ethernet header made here.
 *
 * @param stack The stack, whose outbox takes it; it's dropped, and counted, if the outbox is full.
 * @param to Its destination MAC address.
 * @param kind Its Ethernet type.
 * @param payload What follows the header, at most MAX_FRAME - ETHERNET_HEADER bytes; more is cut off.
 */
queue_frame :: fn(stack: ptr[mut Stack], to: Mac, kind: u16, payload: u8[]) {
    if stack.outbox_count >= OUTBOX {
        stack.dropped_frames += 1
        return void
    }
    at :: (stack.outbox_first + stack.outbox_count) % OUTBOX
    if at >= stack.outbox.count {
        return void
    }
    stack.outbox_count += 1
    frame :: &stack.outbox[at]
    bytes :: view_of(&frame.bytes[0], frame.bytes.count)
    put_mac(bytes, 0, to)
    put_mac(bytes, 6, stack.mac)
    put_u16(bytes, 12, kind)
    length := cast[usize](ETHERNET_HEADER)
    for byte in payload {
        if length >= bytes.count {
            break
        }
        bytes[length] = byte
        length += 1
    }
    frame.length = length
}

/**
 * Queue an event for the caller.
 *
 * @param stack The stack, whose events take it; it's dropped if they're full.
 * @param happened The event.
 */
event :: fn(stack: ptr[mut Stack], happened: Event) {
    if stack.events_count >= EVENTS {
        return void
    }
    at :: (stack.events_first + stack.events_count) % EVENTS
    if at < stack.events.count {
        stack.events[at] = happened
        stack.events_count += 1
    }
}

/**
 * Draw the random generator's next value (xorshift64*).
 *
 * @param stack The stack, whose generator moves on.
 * @return The value.
 */
next_random :: fn(stack: ptr[mut Stack]) -> u64 {
    x := stack.random
    x = x ~ (x >> 12)
    x = x ~ (x << 25)
    x = x ~ (x >> 27)
    stack.random = x
    return x * 0x2545f4914f6cdd1d
}

// ---- Neighbours, for both families

/**
 * Find a neighbour's entry by address.
 *
 * @param table The table: stack.arp, or stack.neighbours.
 * @param address The address, an IPv4 one in its first four bytes for ARP's table.
 * @return Its index; null if it isn't there.
 */
find_neighbour :: fn(table: Neighbour[], address: Ipv6) -> usize? {
    for each, i in table {
        if each.state != .Free && same_ipv6(each.address, address) {
            return i
        }
    }
    return null
}

/**
 * Find an entry for a new neighbour: a free one, or else the one resolved that expires soonest.
 *
 * @param table The table.
 * @return Its index; null if every one is still resolving.
 */
free_neighbour :: fn(table: Neighbour[]) -> usize? {
    oldest : usize? = null
    for each, i in table {
        if each.state == .Free {
            return i
        }
        if each.state == .Resolved {
            match oldest {
                case Some(found) => if found < table.count && each.deadline < table[found].deadline {
                    oldest = i
                }
                case None => oldest = i
            }
        }
    }
    return oldest
}

/**
 * Learn a neighbour's MAC address, as an answer, or a frame from it, says it: its entry is resolved, and a frame
 * waiting for it is sent.
 *
 * @param stack The stack.
 * @param v4 True for ARP's table, false for IPv6's.
 * @param address Its address.
 * @param mac Its MAC address.
 * @param create Whether to make an entry for it if there's none; otherwise only one there is updated.
 */
learn_neighbour :: fn(stack: ptr[mut Stack], v4: bool, address: Ipv6, mac: Mac, create: bool) {
    table :: if v4 { view_of(&stack.arp[0], stack.arp.count) } else { view_of(&stack.neighbours[0], stack.neighbours.count) }
    index := find_neighbour(table, address)
    if index is_none {
        if !create {
            return void
        }
        index = free_neighbour(table)
    }
    at :: index or_return void
    if at >= table.count {
        return void
    }
    entry :: &table[at]
    entry.address = address
    entry.mac = mac
    entry.state = .Resolved
    entry.deadline = stack.now + NEIGHBOUR_LIFE
    entry.tries = 0
    if entry.waiting_length > 0 {
        length :: entry.waiting_length
        entry.waiting_length = 0
        queue_frame(stack, mac, if v4 { ETHER_IPV4 } else { ETHER_IPV6 }, view_of(&entry.waiting[0], length))
    }
}

/**
 * Send an IP packet to its next hop, resolving the hop's MAC address first if it isn't known: the packet waits in the
 * hop's entry meanwhile, replacing any waiting before it.
 *
 * @param stack The stack.
 * @param v4 True for an IPv4 packet and hop, false for IPv6.
 * @param hop The next hop's address: the destination on the link, or a router.
 * @param packet The packet, from its IP header, MAX_FRAME - ETHERNET_HEADER bytes at most.
 * @return True once it's queued or waiting; false if no entry could be had for the hop.
 */
send_to_hop :: fn(stack: ptr[mut Stack], v4: bool, hop: Ipv6, packet: u8[]) -> bool {
    table :: if v4 { view_of(&stack.arp[0], stack.arp.count) } else { view_of(&stack.neighbours[0], stack.neighbours.count) }
    kind :: if v4 { ETHER_IPV4 } else { ETHER_IPV6 }
    match find_neighbour(table, hop) {
        case Some(found) => if found < table.count && table[found].state == .Resolved {
            queue_frame(stack, table[found].mac, kind, packet)
            return true
        }
        case None => {}
    }
    index := find_neighbour(table, hop)
    if index is_none {
        index = free_neighbour(table)
        match index {
            case Some(made) => if made < table.count {
                table[made] = Neighbour.{state = .Resolving, address = hop, deadline = stack.now}
            }
            case None => {}
        }
    }
    at :: index or_return false
    if at >= table.count {
        return false
    }
    entry :: &table[at]
    length := cast[usize](0)
    for byte in packet {
        if length >= entry.waiting.count {
            break
        }
        entry.waiting[length] = byte
        length += 1
    }
    entry.waiting_length = length
    if entry.state == .Resolving && entry.tries == 0 {
        ask_neighbour(stack, v4, entry)
    }
    return true
}

/**
 * Ask for a neighbour's MAC address: an ARP request, or a neighbour solicitation to its solicited-node group.
 *
 * @param stack The stack.
 * @param v4 True for ARP, false for IPv6.
 * @param entry The neighbour's entry, resolving, whose tries count up and deadline moves on.
 */
ask_neighbour :: fn(stack: ptr[mut Stack], v4: bool, entry: ptr[mut Neighbour]) {
    entry.tries += 1
    entry.deadline = stack.now + RESOLVE_INTERVAL
    if v4 {
        send_arp_request(stack, ipv4_of6(entry.address))
    }
    else {
        send_solicitation(stack, entry.address, false)
    }
}

/**
 * Ask again for neighbours not yet resolved, give up on those asked RESOLVE_TRIES times, and forget those expired.
 *
 * @param stack The stack.
 * @param v4 True for ARP's table, false for IPv6's.
 */
tick_neighbours :: fn(stack: ptr[mut Stack], v4: bool) {
    table :: if v4 { view_of(&stack.arp[0], stack.arp.count) } else { view_of(&stack.neighbours[0], stack.neighbours.count) }
    for &entry in table {
        if entry.state == .Free || stack.now < entry.deadline {
            continue
        }
        if entry.state == .Resolved || entry.tries >= RESOLVE_TRIES {
            entry^ = Neighbour.{}
            continue
        }
        ask_neighbour(stack, v4, entry)
    }
}

// ---- Bytes

/**
 * Give part of some bytes, by a range checked against them.
 *
 * @param bytes The bytes.
 * @param from Where the part starts.
 * @param to Where it ends, past its last byte.
 * @return bytes[from..<to]; empty if the range isn't within them.
 */
part :: fn(bytes: u8[], from: usize, to: usize) -> u8[] {
    if to > bytes.count || from > to {
        return bytes[0..<0]
    }
    return bytes[from..<to]
}

/**
 * Read a byte.
 *
 * @param bytes The bytes.
 * @param at Its index.
 * @return It; 0 past bytes' end.
 */
byte_at :: fn(bytes: u8[], at: usize) -> u8 {
    return if at < bytes.count { bytes[at] } else { cast[u8](0) }
}

/**
 * Read a big-endian u16.
 *
 * @param bytes The bytes.
 * @param at Where it starts.
 * @return It; its bytes past bytes' end read as 0.
 */
u16_at :: fn(bytes: u8[], at: usize) -> u16 {
    return (cast[u16](byte_at(bytes, at)) << 8) | cast[u16](byte_at(bytes, at + 1))
}

/**
 * Read a big-endian u32.
 *
 * @param bytes The bytes.
 * @param at Where it starts.
 * @return It; its bytes past bytes' end read as 0.
 */
u32_at :: fn(bytes: u8[], at: usize) -> u32 {
    return (cast[u32](u16_at(bytes, at)) << 16) | cast[u32](u16_at(bytes, at + 2))
}

/**
 * Read a MAC address.
 *
 * @param bytes The bytes.
 * @param at Where it starts.
 * @return It; its bytes past bytes' end read as 0.
 */
mac_at :: fn(bytes: u8[], at: usize) -> Mac {
    mac := Mac.{}
    for &byte, i in mac.bytes {
        byte^ = byte_at(bytes, at + i)
    }
    return mac
}

/**
 * Read an IPv4 address.
 *
 * @param bytes The bytes.
 * @param at Where it starts.
 * @return It; its bytes past bytes' end read as 0.
 */
ipv4_at :: fn(bytes: u8[], at: usize) -> Ipv4 {
    address := Ipv4.{}
    for &byte, i in address.bytes {
        byte^ = byte_at(bytes, at + i)
    }
    return address
}

/**
 * Read an IPv6 address.
 *
 * @param bytes The bytes.
 * @param at Where it starts.
 * @return It; its bytes past bytes' end read as 0.
 */
ipv6_at :: fn(bytes: u8[], at: usize) -> Ipv6 {
    address := Ipv6.{}
    for &byte, i in address.bytes {
        byte^ = byte_at(bytes, at + i)
    }
    return address
}

/**
 * Write a byte.
 *
 * @param bytes The bytes.
 * @param at Its index; past bytes' end, nothing's written.
 * @param value The byte.
 */
put_u8 :: fn(bytes: mut u8[], at: usize, value: u8) {
    if at < bytes.count {
        bytes[at] = value
    }
}

/**
 * Write a big-endian u16.
 *
 * @param bytes The bytes.
 * @param at Where it starts; bytes past bytes' end aren't written.
 * @param value The value.
 */
put_u16 :: fn(bytes: mut u8[], at: usize, value: u16) {
    put_u8(bytes, at, cast[u8](value >> 8))
    put_u8(bytes, at + 1, cast[u8](value))
}

/**
 * Write a big-endian u32.
 *
 * @param bytes The bytes.
 * @param at Where it starts; bytes past bytes' end aren't written.
 * @param value The value.
 */
put_u32 :: fn(bytes: mut u8[], at: usize, value: u32) {
    put_u16(bytes, at, cast[u16](value >> 16))
    put_u16(bytes, at + 2, cast[u16](value))
}

/**
 * Write bytes.
 *
 * @param bytes Where they go.
 * @param at Where they start; those past bytes' end aren't written.
 * @param from What's written.
 */
put_bytes :: fn(bytes: mut u8[], at: usize, from: u8[]) {
    for byte, i in from {
        put_u8(bytes, at + i, byte)
    }
}

/**
 * Write a MAC address.
 *
 * @param bytes The bytes.
 * @param at Where it starts.
 * @param mac The address.
 */
put_mac :: fn(bytes: mut u8[], at: usize, mac: Mac) {
    for byte, i in mac.bytes {
        put_u8(bytes, at + i, byte)
    }
}

/**
 * Add bytes to an Internet checksum's running sum (RFC 1071), as big-endian u16s, an odd last byte padded with 0.
 *
 * @param sum The sum so far.
 * @param bytes The bytes, from an even offset in what's checksummed.
 * @return The sum with them, not yet folded.
 */
checksum_add :: fn(sum: u64, bytes: u8[]) -> u64 {
    total := sum
    with {
        at : usize = 0
    }
    loop {
        if at >= bytes.count {
            break
        }
        total += cast[u64](u16_at(bytes, at))
        at += 2
    }
    while true
    return total
}

/**
 * Finish an Internet checksum: fold the sum to 16 bits and complement it.
 *
 * @param sum The running sum.
 * @return The checksum, as it's written; checking a whole header or packet with its checksum in it gives 0.
 */
checksum_finish :: fn(sum: u64) -> u16 {
    folded := sum
    loop {
        folded = (folded & 0xffff) + (folded >> 16)
    }
    while folded > 0xffff
    return ~cast[u16](folded)
}

// ---- Addresses

/**
 * Compare two MAC addresses.
 *
 * @return True if they're the same.
 */
same_mac :: fn(a: Mac, b: Mac) -> bool {
    for byte, i in a.bytes {
        if i < b.bytes.count && byte != b.bytes[i] {
            return false
        }
    }
    return true
}

/**
 * Compare two IPv4 addresses.
 *
 * @return True if they're the same.
 */
same_ipv4 :: fn(a: Ipv4, b: Ipv4) -> bool {
    for byte, i in a.bytes {
        if i < b.bytes.count && byte != b.bytes[i] {
            return false
        }
    }
    return true
}

/**
 * Compare two IPv6 addresses.
 *
 * @return True if they're the same.
 */
same_ipv6 :: fn(a: Ipv6, b: Ipv6) -> bool {
    for byte, i in a.bytes {
        if i < b.bytes.count && byte != b.bytes[i] {
            return false
        }
    }
    return true
}

/**
 * Compare two IP addresses.
 *
 * @return True if they're of the same family and the same.
 */
same_address :: fn(a: IpAddress, b: IpAddress) -> bool {
    return match a {
        case V4(x) => match b {
            case V4(y) => same_ipv4(x, y)
            case V6(_) => false
        }
        case V6(x) => match b {
            case V4(_) => false
            case V6(y) => same_ipv6(x, y)
        }
    }
}

/**
 * Hold an IPv4 address in an IPv6 one's first four bytes, as ARP's table keeps it.
 *
 * @param address The IPv4 address.
 * @return It, the rest zeroes.
 */
ipv6_of4 :: fn(address: Ipv4) -> Ipv6 {
    held := Ipv6.{}
    for byte, i in address.bytes {
        if i < held.bytes.count {
            held.bytes[i] = byte
        }
    }
    return held
}

/**
 * Take back an IPv4 address held by ipv6_of4.
 *
 * @param held The IPv6 address holding it.
 * @return Its first four bytes.
 */
ipv4_of6 :: fn(held: Ipv6) -> Ipv4 {
    address := Ipv4.{}
    for &byte, i in address.bytes {
        if i < held.bytes.count {
            byte^ = held.bytes[i]
        }
    }
    return address
}

/**
 * Tell whether an IPv4 address is 0.0.0.0.
 *
 * @return True if every byte is 0.
 */
is_zero_ipv4 :: fn(address: Ipv4) -> bool {
    return same_ipv4(address, Ipv4.{})
}

/**
 * Tell whether an IPv6 address is ::.
 *
 * @return True if every byte is 0.
 */
is_zero_ipv6 :: fn(address: Ipv6) -> bool {
    return same_ipv6(address, Ipv6.{})
}

/**
 * Tell whether two IPv4 addresses share a prefix.
 *
 * @param a One.
 * @param b The other.
 * @param length The prefix's length in bits, 0 to 32.
 * @return True if their first length bits are the same.
 */
same_prefix_v4 :: fn(a: Ipv4, b: Ipv4, length: u8) -> bool {
    return prefix_matches(view_of(&a.bytes[0], a.bytes.count), view_of(&b.bytes[0], b.bytes.count), cast[usize](length))
}

/**
 * Tell whether two addresses' bytes share a prefix.
 *
 * @param a One's bytes.
 * @param b The other's, as many.
 * @param bits The prefix's length in bits; past their bits, all of them.
 * @return True if their first bits are the same.
 */
prefix_matches :: fn(a: u8[], b: u8[], bits: usize) -> bool {
    for byte, i in a {
        if i * 8 >= bits {
            return true
        }
        other :: byte_at(b, i)
        remaining :: bits - i * 8
        mask :: if remaining >= 8 { cast[u8](0xff) } else { cast[u8](0xff) << cast[u8](8 - remaining) }
        if byte & mask != other & mask {
            return false
        }
    }
    return true
}
