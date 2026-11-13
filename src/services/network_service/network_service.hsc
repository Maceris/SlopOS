/**
 * The network service (decisions/0188): the system's network stack, over the first NIC's driver, through the net
 * protocol. It takes the interface, as 13a built, and runs the network layer (src/net_stack) on it, 13b: an IPv4 address
 * by DHCP, IPv6 addresses by SLAAC, each logged as it's had. Frames received go to the stack, and each slot is given
 * back; frames the stack queues go out through the send slots free, the rest waiting in the stack until one is; its
 * timers are one port timer, at its next deadline.
 *
 * Programs reach the network through it, 13c: its listener's connections speak the network protocol (std/os/slop_os's
 * network), whose Open, Listen and Udp give channels of their own (tcp_stream, tcp_listener, datagrams). A connection
 * made through the listener allows everything, as its holder, the session manager or a test, is given it to narrow;
 * Narrow makes one allowing less, and every Open, Listen, Udp and datagram is checked against its connection's policy. A connection's
 * data is in the program's memory, which isn't mapped here but copied to and from through the kernel (memory_read and
 * memory_write), as the program owns it: a program that destroys it, closing it while data's still to send, ends its own
 * connection rather than faulting the service (13f).
 *
 * Names are resolved by the stack's resolver, 13e (names.hsc): Resolve gives a name's addresses, and OpenName connects
 * to them as Happy Eyeballs does. Its DNS servers are DHCP's and routers', or dns=<address>:<port> on the kernel's
 * command line in their place.
 *
 * With test_ping on the kernel's command line, it pings the IPv4 router once it has a lease, and the IPv6 router once
 * it has a global address, and logs their answers.
 */
package network_service

import runtime from "base"
import os from "std"
import random from "std"
import text_buffer from "std"
import slop_os from "std/os"
import net_address from "std/os/slop_os"
import network from "std/os/slop_os"
import tcp_stream from "std/os/slop_os"
import tcp_listener from "std/os/slop_os"
import datagrams from "std/os/slop_os"
import connector from "../../protocols/connector"
import net from "../../protocols/net"
import net_stack from "../../net_stack"
import service_kit from "../../libraries/service_kit"

/** The port key the NIC's connection is bound with; programs' network channels are bound under their indexes, below it. */
NIC_KEY : u64 : 900
/** The port key the NIC's connector is bound with. */
CONNECTOR_KEY : u64 : 901
/** The port key the stack's timer is bound with. */
TIMER_KEY : u64 : 902
/** A page's size. */
PAGE : u64 : 4096

/** The service's state, on the heap, main's for its life. */
Service :: struct {
    /** The port its NIC's connection and its timer are bound to. */
    port : slop_os.Port,
    /** Its connection to the NIC's driver; NO_HANDLE without one. */
    nic : slop_os.Channel,
    /** What the NIC is. */
    info : net.Info,
    /** Where the connection's buffer is mapped, 0 before it is. */
    buffer : u64,
    /** Whether each send slot has a frame the driver hasn't given back. */
    sending : bool[net.SLOTS],
    /** The network layer, once the NIC is had. */
    stack : ptr[mut net_stack.Stack]?,
    /** Whether test_ping asks for pings. */
    test_ping : bool,
    /** The IPv4 router to ping, once leased; 0.0.0.0 before. */
    router_v4 : net_stack.Ipv4,
    /** Whether the IPv4 router's been pinged. */
    pinged_v4 : bool,
    /** The IPv6 router to ping, once found; :: before. */
    router_v6 : net_stack.Ipv6,
    /** Whether a global IPv6 address is the interface's, which the IPv6 ping waits for. */
    global_v6 : bool,
    /** Whether the IPv6 router's been pinged. */
    pinged_v6 : bool,
    /** The programs served, and what they hold. */
    serving : Serving,
}

/**
 * Run the network service: take the first NIC, and serve it until the system stops.
 *
 * @param log The debug log its lines go to; without one, it writes nothing there.
 * @param nic A connector to the first NIC's driver; without one, there's no network, and every Open, Listen and Udp is
 *     refused NoRoute.
 * @param command_line The kernel's command line, read for test_ping.
 * @param clients The listener programs' connections arrive on, served as a client itself.
 * @return 0 once it's asked to stop; 2 if no port could be made; 3 if programs can't be served.
 */
main :: fn(log: slop_os.DebugLog?, nic: os.Channel[connector.Connector]?, command_line: slop_os.Memory?,
    clients: os.Listener[network.Network]) -> int {
    startup :: slop_os.startup_block()
    service := runtime.new(Service)
    service.nic = cast[slop_os.Channel](slop_os.NO_HANDLE)
    service.port = slop_os.port_create(startup.budget) or_return 2
    _ = service_kit.watch_stop(service.port)
    text := ""
    match command_line {
        case Some(memory) => {
            text = service_kit.text_of(startup, memory) or_else ""
            service.test_ping = service_kit.has_word(text, "test_ping")
        }
        case None => {}
    }
    if !start_serving(service, clients) {
        return 3
    }
    match nic {
        case Some(dialing) => take_nic(service, dialing)
        case None => runtime.log_info("no network interface")
    }
    match service.stack {
        case Some(stack) => configure_dns(stack, text)
        case None => {}
    }
    into := os.Incoming.{}
    loop {
        take_answers(service, &into)
        serve_programs(service, &into)
        match service.stack {
            case Some(stack) => {
                net_stack.tick(stack, now())
                race_on(service, stack)
                pump(service, stack)
            }
            case None => {}
        }
        // What couldn't be answered let go, once nothing's using it
        drop_broken(service)
        if service_kit.stopping() {
            return 0
        }
        packets : slop_os.Packet[8]
        _ = slop_os.port_wait(service.port, packets, slop_os.NO_DEADLINE)
    }
}

/**
 * Give the time, as the stack counts it: the monotonic clock's nanoseconds.
 *
 * @return It; 0 if the clock can't be read.
 */
now :: fn() -> u64 {
    return slop_os.clock_monotonic() or_else 0
}

/**
 * Dial the NIC's driver, say what it is, map the buffer, give every receive slot, and start the stack on it.
 *
 * @param service The service, whose nic, info, buffer and stack are set once each is had; what fails is logged, and the
 *     service runs without a network.
 * @param dialing The connector to the driver.
 */
take_nic :: fn(service: ptr[mut Service], dialing: os.Channel[connector.Connector]) {
    startup :: slop_os.startup_block()
    signals :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    // Its answers are waited for on the port
    if slop_os.port_bind(service.port, cast[slop_os.Handle](dialing.end), signals, CONNECTOR_KEY, .Persistent) is_error {
        runtime.log_info("the network interface's connector couldn't be watched")
        return void
    }
    connection :: match connector.dial[net.Net](dialing.end, service.port) {
        case Some(found) => found
        case None => {
            runtime.log_info("the network interface couldn't be dialed")
            return void
        }
    }
    end :: connection.end
    if slop_os.port_bind(service.port, cast[slop_os.Handle](end), signals, NIC_KEY, .Persistent) is_error {
        runtime.log_info("the network interface's connection couldn't be watched")
        return void
    }
    service.nic = end
    match net.describe(end, service.port) {
        case Some(found) => service.info = found
        case None => {
            runtime.log_info("the network interface didn't say what it is")
            return void
        }
    }
    mac :: service.info.mac
    runtime.log_info("interface %{02x}:%{02x}:%{02x}:%{02x}:%{02x}:%{02x}, its link %, MTU %", mac[0], mac[1], mac[2], mac[3],
        mac[4], mac[5], if service.info.link_up { "up" } else { "down" }, service.info.mtu)
    window :: match net.get_buffer(end, service.port) {
        case Some(found) => found
        case None => {
            runtime.log_info("the network interface gave no buffer")
            return void
        }
    }
    at :: match runtime.reserve_addresses(cast[usize](net.BUFFER_BYTES)) {
        case Some(found) => found
        case None => {
            runtime.log_info("no room for the network interface's buffer")
            return void
        }
    }
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    if slop_os.memory_map(window, startup.space, at, 0, net.BUFFER_BYTES, read_write) is_error {
        runtime.log_info("the network interface's buffer couldn't be mapped")
        return void
    }
    service.buffer = at
    for slot in cast[u32](0)..<net.SLOTS {
        request(service, .Receive(slot))
    }
    stack :: runtime.new(net_stack.Stack)
    // The stack's random generator's key, from the system's generator: what can't be guessed on the network comes of it
    setup := net_stack.Setup.{mac = net_stack.Mac.{bytes = mac}, mtu = service.info.mtu}
    random.fill(setup.key[0..<setup.key.count])
    net_stack.start(stack, setup, now())
    service.stack = stack
    pump(service, stack)
}

/**
 * Send a request to the NIC's driver; one that can't be sent is logged.
 *
 * @param service The service, with a connection to the NIC.
 * @param request The request, which has no variable-size data.
 */
request :: fn(service: ptr[mut Service], request: net.Request) {
    out := os.Outgoing.{}
    made :: os.begin[net.Request](&out)
    made^ = request
    if net.send_request(service.nic, service.port, &out) is_some {
        runtime.log_info("a request to the network interface couldn't be sent")
    }
}

/**
 * Take every answer the NIC's driver has sent: each frame received goes to the stack, and its slot is given again; each
 * send slot given back is free again.
 *
 * @param service The service; its connection to the NIC is closed if it fails.
 * @param into Where each answer is received, reused for each.
 */
take_answers :: fn(service: ptr[mut Service], into: ptr[mut os.Incoming]) {
    if cast[slop_os.Handle](service.nic) == slop_os.NO_HANDLE {
        return void
    }
    loop {
        match net.receive_response(service.nic, service.port, into, false) {
            case Received => {}
            case Empty => return void
            case _ => {
                runtime.log_info("the network interface's connection ended")
                _ = slop_os.handle_close(cast[slop_os.Handle](service.nic))
                service.nic = cast[slop_os.Channel](slop_os.NO_HANDLE)
                return void
            }
        }
        match os.message_of[net.Response](into)^ {
            case Received(frame) => {
                if frame.slot < net.SLOTS && frame.length <= net.SLOT_BYTES {
                    match service.stack {
                        case Some(stack) => net_stack.receive(stack, slot_bytes(service, frame.slot, frame.length), now())
                        case None => {}
                    }
                }
                request(service, .Receive(frame.slot))
            }
            case Sent(slot) => {
                if slot >= net.SLOTS && cast[usize](slot - net.SLOTS) < service.sending.count {
                    service.sending[slot - net.SLOTS] = false
                }
            }
            case Refused(refused) => runtime.log_info("the network interface refused slot %: %", refused.slot, refused.reason)
            case Link(up) => runtime.log_info("the link is %", if up { "up" } else { "down" })
            case _ => {}
        }
    }
}

/**
 * View a slot of the NIC's buffer.
 *
 * @param service The service, with the buffer mapped.
 * @param slot The slot, below 2 * net.SLOTS.
 * @param length How much of it, at most net.SLOT_BYTES.
 * @return Its first length bytes.
 */
slot_bytes :: fn(service: ptr[Service], slot: u32, length: u32) -> mut u8[] {
    return view_of(cast[ptr[mut u8]](service.buffer + cast[u64](slot) * cast[u64](net.SLOT_BYTES)), cast[usize](length))
}

/**
 * Move what the stack has for the world on: each event logged, then each frame it queued into a free send slot, sent,
 * while slots are free; and its timer set to its next deadline. Events go first, as what they start, a ping, queues
 * frames too, which would otherwise wait for the next wake.
 *
 * @param service The service.
 * @param stack The stack.
 */
pump :: fn(service: ptr[mut Service], stack: ptr[mut net_stack.Stack]) {
    loop {
        happened :: net_stack.take_event(stack) or_break
        report(service, stack, happened)
    }
    // An event dropped, the queue full: whatever waits on one looked at again, so none waits for ever
    if net_stack.take_events_lost(stack) {
        catch_up(service, stack)
    }
    take_stack_news(service, stack)
    if service.buffer != 0 && cast[slop_os.Handle](service.nic) != slop_os.NO_HANDLE {
        for &busy, index in service.sending {
            if busy^ {
                continue
            }
            slot :: net.SLOTS + cast[u32](index)
            length :: net_stack.take_frame(stack, slot_bytes(service, slot, net.SLOT_BYTES)) or_break
            busy^ = true
            request(service, .Send(net.Frame.{slot = slot, length = cast[u32](length)}))
        }
        // What TCP held back while the outbox was full, now there's room, into the slots still free
        net_stack.tcp_resume(stack)
        for &busy, index in service.sending {
            if busy^ {
                continue
            }
            slot :: net.SLOTS + cast[u32](index)
            length :: net_stack.take_frame(stack, slot_bytes(service, slot, net.SLOT_BYTES)) or_break
            busy^ = true
            request(service, .Send(net.Frame.{slot = slot, length = cast[u32](length)}))
        }
    }
    stack_deadline :: net_stack.next_deadline(stack)
    racing :: race_deadline(service)
    deadline :: if racing < stack_deadline { racing } else { stack_deadline }
    if deadline != ~cast[u64](0) {
        _ = slop_os.port_set_timer(service.port, TIMER_KEY, deadline)
    }
}

/**
 * Look again at what waits on the stack's events, after some were dropped: each lookup that's done is answered, and
 * each stream whose connection's gone ends, as their Resolved and Ended would have done.
 *
 * @param service The service.
 * @param stack The stack.
 */
catch_up :: fn(service: ptr[mut Service], stack: ptr[mut net_stack.Stack]) {
    for each in service.serving.pending {
        if each.active {
            lookup_done(service, stack, each.lookup)
        }
    }
    for i in cast[usize](0)..<STREAMS {
        if i >= service.serving.streams.count {
            break
        }
        stream :: &service.serving.streams[i]
        if cast[slop_os.Handle](stream.end) == slop_os.NO_HANDLE || stream.ended || stream.race.racing {
            continue
        }
        status :: net_stack.tcp_status(stack, stream.connection)
        if status.ended {
            why :: if status.state == .TimeWait { net_stack.TcpEnding.Closed } else { net_stack.TcpEnding.Aborted }
            connection_ended(service, net_stack.TcpEnded.{connection = stream.connection, why = why,
                delivered = stream.watched.delivered, acknowledged = stream.watched.acknowledged})
        }
    }
}

/**
 * Log an event of the stack's, and with test_ping, ping a router once it's known.
 *
 * @param service The service.
 * @param stack The stack.
 * @param happened The event.
 */
report :: fn(service: ptr[mut Service], stack: ptr[mut net_stack.Stack], happened: net_stack.Event) {
    storage : u8[256]
    line := text_buffer.make(storage)
    match happened {
        case Leased(lease) => {
            text_buffer.append(&line, "leased ")
            append_v4(&line, lease.address)
            text_buffer.append_format(&line, "/% from ", lease.prefix_length)
            append_v4(&line, lease.server)
            text_buffer.append(&line, ", its router ")
            append_v4(&line, lease.router)
            text_buffer.append(&line, ", DNS ")
            append_v4(&line, lease.dns)
            text_buffer.append_format(&line, ", for % s", lease.seconds)
            service.router_v4 = lease.router
        }
        case LeaseLost => text_buffer.append(&line, "the IPv4 lease ended")
        case AddressReady(assigned) => {
            text_buffer.append(&line, if assigned.link_local { "link-local address " } else { "IPv6 address " })
            append_v6(&line, assigned.address)
            text_buffer.append_format(&line, "/%", assigned.prefix_length)
            if !assigned.link_local {
                service.global_v6 = true
            }
        }
        case AddressExpired(address) => {
            text_buffer.append(&line, "IPv6 address ")
            append_v6(&line, address)
            text_buffer.append(&line, " expired")
            service.global_v6 = net_stack.has_global_v6(stack)
        }
        case AddressConflict(address) => {
            text_buffer.append(&line, "another has ")
            append_address(&line, address)
            text_buffer.append(&line, ", so it isn't taken")
        }
        case RouterFound(router) => {
            text_buffer.append(&line, "IPv6 router ")
            append_v6(&line, router)
            service.router_v6 = router
        }
        case Incoming(incoming) => {
            connection_arrived(service, incoming)
            return void
        }
        case Ended(ended) => {
            connection_ended(service, ended)
            return void
        }
        case Resolved(lookup) => {
            lookup_done(service, stack, lookup)
            return void
        }
        case EchoReplied(echo) => {
            append_address(&line, echo.from)
            text_buffer.append(&line, " answered a ping")
        }
    }
    runtime.log_info("%", text_buffer.as_string(&line))
    if !service.test_ping {
        return void
    }
    if !service.pinged_v4 && !net_stack.is_zero_ipv4(service.router_v4) {
        service.pinged_v4 = net_stack.ping(stack, .V4(service.router_v4)) is_some
    }
    if !service.pinged_v6 && service.global_v6 && !net_stack.is_zero_ipv6(service.router_v6) {
        service.pinged_v6 = net_stack.ping(stack, .V6(service.router_v6)) is_some
    }
}

/**
 * Append an IPv4 address in dotted decimal.
 *
 * @param line Where.
 * @param address The address.
 */
append_v4 :: fn(line: ptr[mut text_buffer.TextBuffer], address: net_stack.Ipv4) {
    bytes :: address.bytes
    text_buffer.append_format(line, "%.%.%.%", bytes[0], bytes[1], bytes[2], bytes[3])
}

/**
 * Append an IPv6 address, as RFC 5952 writes it.
 *
 * @param line Where.
 * @param address The address.
 */
append_v6 :: fn(line: ptr[mut text_buffer.TextBuffer], address: net_stack.Ipv6) {
    text : u8[40]
    length :: net_stack.format_ipv6(address, view_of(&text[0], text.count))
    text_buffer.append(line, string_of(&text[0], length))
}

/**
 * Append an address of either family.
 *
 * @param line Where.
 * @param address The address.
 */
append_address :: fn(line: ptr[mut text_buffer.TextBuffer], address: net_stack.IpAddress) {
    match address {
        case V4(v4) => append_v4(line, v4)
        case V6(v6) => append_v6(line, v6)
    }
}

// ---- Serving programs (13c): the network protocol, and the channels it gives

/** The most TCP connections programs hold through the service at once: the stack's. */
STREAMS :: 64
/** The most listeners at once. */
LISTENERS :: 16
/** The most UDP sockets at once. */
SOCKETS :: 16
/** The most Accepts a listener holds at once. */
HELD_ACCEPTS :: 4
/*
 * What one network channel may hold at once (13h), charged to the channel it was asked through (its "root", a number
 * each channel has of its own), so no one channel takes all of what's shared. Charged by channel, not by program: the
 * session manager hands every session and program a Narrow or Copy of one connection, and channels can be passed on,
 * so the service can't tell whose a channel is.
 */
/** TCP connections: streams opened, accepted or by name. */
STREAMS_PER_ROOT :: 16
LISTENERS_PER_ROOT :: 4
SOCKETS_PER_ROOT :: 4
/** Resolves and OpenNames waiting for their lookups. */
LOOKUPS_PER_ROOT :: 2
/** The largest memory a connection's rings take: 1 MiB, two rings of 512 KiB. */
MAX_MEMORY : u64 : 1 << 20
/** The smallest: two pages. */
MIN_MEMORY : u64 : 8192
/** Where streams' channels are bound: STREAM_KEY plus the stream's index. */
STREAM_KEY : u64 : 1000
/** Where listeners' channels are bound. */
LISTENER_KEY : u64 : 2000
/** Where sockets' channels are bound. */
SOCKET_KEY : u64 : 3000

/** A TCP connection a program holds: its channel, its memory, and what it's been told. */
Stream :: struct {
    /** The service's end of its channel; NO_HANDLE for a free entry. */
    end : slop_os.Channel,
    /** Its connection in the stack. */
    connection : u32,
    /** Its memory, mapped at the entry's slot; NO_HANDLE once given back. */
    memory : slop_os.Memory,
    /** Its memory's size in bytes. */
    bytes : u64,
    /** Whether a Watch is held, and the progress it holds. */
    watching : bool,
    watched : tcp_stream.Progress,
    /** Whether the connection's ended in the stack, why, and its last totals. */
    ended : bool,
    ending : tcp_stream.Ending,
    final : tcp_stream.Progress,
    remote : net_address.Endpoint,
    /** For a connection by name, its addresses' race (names.hsc); not racing for any other. */
    race : Race,
    /** The root it's charged to. */
    root : u64,
    /** Whether an answer to it couldn't be sent, so it's let go once its serving's done (drop_broken). */
    broken : bool,
}

/** A listening port a program holds. */
ListenerSlot :: struct {
    /** The service's end of its channel; NO_HANDLE for a free entry. */
    end : slop_os.Channel,
    /** Its listener in the stack. */
    listener : u32,
    /** Memories held by Accepts, oldest first, the first held_count of them. */
    held : slop_os.Memory[HELD_ACCEPTS],
    held_count : usize,
    /** Connections arrived with no Accept held, waiting for one, as the stack's accept wait allows. */
    pending : u32[HELD_ACCEPTS],
    pending_remote : net_address.Endpoint[HELD_ACCEPTS],
    pending_count : usize,
    /** Whether an answer to it couldn't be sent (drop_broken). */
    broken : bool,
    /** The root it's charged to, as are the streams it accepts. */
    root : u64,
}

/** A UDP socket a program holds. */
SocketSlot :: struct {
    /** The service's end of its channel; NO_HANDLE for a free entry. */
    end : slop_os.Channel,
    /** Its socket in the stack. */
    socket : u32,
    /** Whether a Receive is held. */
    receiving : bool,
    /** The policy of the connection it was opened on, which each datagram sent or taken is checked against. */
    policy : network.Policy,
    /** Whether an answer to it couldn't be sent (drop_broken). */
    broken : bool,
    /** The root it's charged to. */
    root : u64,
}

/** What serving programs keeps: their channels and what each holds. */
Serving :: struct {
    /** The network channels, the listener among them. */
    clients : service_kit.Clients,
    /** Each network channel's policy, by its index in clients: everything for one made through the listener. */
    policies : network.Policy[service_kit.MAX_CLIENTS],
    streams : Stream[STREAMS],
    listeners : ListenerSlot[LISTENERS],
    sockets : SocketSlot[SOCKETS],
    /** Resolves and OpenNames waiting for their lookups (names.hsc). */
    pending : Pending[PENDING],
    /** Whether an answer to each network channel couldn't be sent (drop_broken), by its index in clients. */
    client_broken : bool[service_kit.MAX_CLIENTS],
    /** The number each network channel's charged by, its own, by its index in clients (the PER_ROOT shares). */
    client_root : u64[service_kit.MAX_CLIENTS],
    /** Which is the listener, whose Connects are allowed everything, as only the supervisor holds it. */
    client_listener : bool[service_kit.MAX_CLIENTS],
    /** The next channel's number, from 1. */
    next_root : u64,
}

/**
 * Set up serving: the listener for programs' connections.
 *
 * @param service The service.
 * @param clients The listener, served as a client itself.
 * @return True if programs can be served.
 */
start_serving :: fn(service: ptr[mut Service], clients: os.Listener[network.Network]) -> bool {
    serving :: &service.serving
    for &each in serving.streams {
        each.end = cast[slop_os.Channel](slop_os.NO_HANDLE)
        each.memory = cast[slop_os.Memory](slop_os.NO_HANDLE)
    }
    for &each in serving.listeners {
        each.end = cast[slop_os.Channel](slop_os.NO_HANDLE)
    }
    for &each in serving.sockets {
        each.end = cast[slop_os.Channel](slop_os.NO_HANDLE)
    }
    serving.next_root = 1
    return add_network_client(service, clients.end, network.everything(), listener = true)
}

/**
 * Serve every program's channel: their requests, then what the stack has for them.
 *
 * @param service The service.
 * @param into Where each message is received, reused for each.
 */
serve_programs :: fn(service: ptr[mut Service], into: ptr[mut os.Incoming]) {
    serving :: &service.serving
    with {
        i : usize = 0
    }
    loop {
        serve_client(service, i, into)
        i += 1
    }
    while i < serving.clients.count
    for i in cast[usize](0)..<STREAMS {
        serve_stream(service, i, into)
    }
    for i in cast[usize](0)..<LISTENERS {
        serve_listener(service, i, into)
    }
    for i in cast[usize](0)..<SOCKETS {
        serve_socket(service, i, into)
    }
}

/**
 * Answer every request a network channel has sent, until there are none left, or it's gone.
 *
 * @param service The service.
 * @param index Which client.
 * @param into Where each request is received.
 */
serve_client :: fn(service: ptr[mut Service], index: usize, into: ptr[mut os.Incoming]) {
    serving :: &service.serving
    if index >= serving.clients.ends.count {
        return void
    }
    end :: serving.clients.ends[index]
    if cast[slop_os.Handle](end) == slop_os.NO_HANDLE {
        return void
    }
    loop {
        match network.receive_request(end, service.port, into, false) {
            case Received => {}
            case Empty => return void
            case Unsupported => {
                answered(service, end, network.answer_unsupported(end, service.port, wait = false))
                continue
            }
            case _ => {
                drop_lookups(service, index)
                service_kit.drop_client(&serving.clients, index)
                return void
            }
        }
        if index >= serving.policies.count {
            return void
        }
        policy :: &serving.policies[index]
        root :: if index < serving.client_root.count { serving.client_root[index] } else { cast[u64](0) }
        match os.message_of[network.Request](into)^ {
            case Open(open) => {
                if network.allows_connect(policy, network.TRANSPORT_TCP, open.to) {
                    answer_network(service, end, open_stream(service, open, root))
                }
                else {
                    _ = slop_os.handle_close(cast[slop_os.Handle](open.memory))
                    answer_network(service, end, .Refused(.NotAllowed))
                }
            }
            case Listen(port) => answer_network(service, end, if network.allows_listen(policy, network.TRANSPORT_TCP, port) {
                open_listener(service, port, root) } else { network.Response.Refused(.NotAllowed) })
            // An ephemeral port needs a policy that sends UDP somewhere, as the socket is only for sending and answers
            case Udp(port) => answer_network(service, end, if (port == 0 && sends_udp(policy)) || (port != 0 && network.allows_listen(policy, network.TRANSPORT_UDP, port)) {
                open_socket(service, port, policy, root) } else { network.Response.Refused(.NotAllowed) })
            case Narrow(narrowing) => {
                wanted := network.policy_of(os.items(into, narrowing.connect), os.items(into, narrowing.listen))
                    or_else network.Policy.{connect_count = network.MAX_RULES + 1}
                // One with too many rules is refused, as it's no policy at all
                allowed :: wanted.connect_count <= network.MAX_RULES && network.within(policy, &wanted)
                answer_network(service, end, if allowed { another_connection(service, wanted) } else { network.Response.Refused(.NotAllowed) })
            }
            case Copy => answer_network(service, end, another_connection(service, policy^))
            case Resolve(asked) => {
                if !network.allows_resolve(policy, os.items(into, asked.name)) {
                    answer_network(service, end, .Refused(.NotAllowed))
                    continue
                }
                v4 :: cast[u8](asked.kinds) & 1 != 0
                v6 :: cast[u8](asked.kinds) & 2 != 0
                match start_lookup(service, index, end, os.items(into, asked.name), v4, v6, false, 0, cast[slop_os.Memory](slop_os.NO_HANDLE)) {
                    case Some(refusal) => answer_network(service, end, .Refused(refusal))
                    case None => {}
                }
            }
            case OpenName(named) => {
                if !network.allows_resolve(policy, os.items(into, named.name)) {
                    _ = slop_os.handle_close(cast[slop_os.Handle](named.memory))
                    answer_network(service, end, .Refused(.NotAllowed))
                    continue
                }
                match start_lookup(service, index, end, os.items(into, named.name), true, true, true, named.port, named.memory) {
                    case Some(refusal) => answer_network(service, end, .Refused(refusal))
                    case None => {}
                }
            }
            case Connect(connection) => {
                /*
                 * Through the listener: everything allowed, as the supervisor gives the listener only to who holds the
                 * network. Through any other connection, that connection's policy, so a Connect is no way around a
                 * Narrow
                 */
                listener :: index < serving.client_listener.count && serving.client_listener[index]
                given :: if listener { network.everything() } else { policy^ }
                if !add_network_client(service, connection.end, given) {
                    _ = slop_os.handle_close(cast[slop_os.Handle](connection.end))
                }
            }
        }
    }
}

/**
 * Serve another network channel, with a policy.
 *
 * @param service The service.
 * @param end The service's end of it.
 * @param policy What it allows.
 * @param listener Whether it's the listener the supervisor connects programs through.
 * @return True once it's served, with a number of its own to charge what it asks for to; false if there's no room,
 *     when end isn't taken.
 */
add_network_client :: fn(service: ptr[mut Service], end: slop_os.Channel, policy: network.Policy, listener: bool = false) -> bool {
    serving :: &service.serving
    index :: service_kit.add_client_index(&serving.clients, service.port, end) or_return false
    if index < serving.policies.count {
        serving.policies[index] = policy
    }
    if index < serving.client_root.count && index < serving.client_listener.count {
        serving.client_root[index] = serving.next_root
        serving.next_root += 1
        serving.client_listener[index] = listener
    }
    // Its place's last channel may have broken, and gone another way before drop_broken
    if index < serving.client_broken.count {
        serving.client_broken[index] = false
    }
    return true
}

/**
 * Make another network channel, with a policy, for Narrow or Copy.
 *
 * @param service The service.
 * @param policy What it allows.
 * @return Narrowed, with the program's end; or Refused NoRoom.
 */
another_connection :: fn(service: ptr[mut Service], policy: network.Policy) -> network.Response {
    startup :: slop_os.startup_block()
    pair :: match os.channel_for[network.Network](startup.budget, network.RING_BYTES) {
        case Ok(found) => found
        case Error(error) => return .Refused(.NoRoom)
    }
    if !add_network_client(service, pair.b, policy) {
        _ = slop_os.handle_close(cast[slop_os.Handle](pair.a))
        _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
        return .Refused(.NoRoom)
    }
    return .Narrowed(os.Channel[network.Network].{end = pair.a})
}

/**
 * Count a root's streams: live ones charged to it.
 *
 * @param service The service.
 * @param root The root.
 * @return How many it holds.
 */
streams_of :: fn(service: ptr[Service], root: u64) -> usize {
    count := cast[usize](0)
    for each in service.serving.streams {
        if cast[slop_os.Handle](each.end) != slop_os.NO_HANDLE && each.root == root {
            count += 1
        }
    }
    return count
}

/**
 * Tell whether a policy sends UDP anywhere: what an ephemeral socket needs.
 *
 * @param policy The policy.
 * @return True if a connect rule allows UDP.
 */
sends_udp :: fn(policy: ptr[network.Policy]) -> bool {
    for rule, i in policy.connect {
        if cast[u32](i) < policy.connect_count && rule.transports & network.TRANSPORT_UDP != 0 {
            return true
        }
    }
    return false
}

/**
 * Send an answer on a network channel, without waiting; one that can't be sent is dropped, what it carried closed, and
 * the channel let go (answered).
 *
 * @param service The service.
 * @param end The channel.
 * @param response The answer.
 */
answer_network :: fn(service: ptr[mut Service], end: slop_os.Channel, response: network.Response) {
    out := os.Outgoing.{}
    made :: os.begin[network.Response](&out)
    made^ = response
    answered(service, end, network.send_response(end, service.port, &out, wait = false))
}

/**
 * Take what sending an answer gave: one that couldn't be sent, as the program's not reading its answers, or its end's
 * gone, marks the channel it was sent on broken, to be let go once serving's done (drop_broken). The service never
 * waits on a program, which could hold it for as long as it liked.
 *
 * @param service The service.
 * @param end The channel the answer was sent on: a network channel's, a stream's, a listener's or a socket's.
 * @param result What sending gave: null if it was sent.
 */
answered :: fn(service: ptr[mut Service], end: slop_os.Channel, result: slop_os.ChannelError?) {
    if result is_none {
        return void
    }
    serving :: &service.serving
    for each, i in serving.clients.ends {
        if i < serving.clients.count && i < serving.client_broken.count && each == end {
            serving.client_broken[i] = true
            return void
        }
    }
    for &stream in serving.streams {
        if stream.end == end {
            stream.broken = true
            return void
        }
    }
    for &slot in serving.listeners {
        if slot.end == end {
            slot.broken = true
            return void
        }
    }
    for &slot in serving.sockets {
        if slot.end == end {
            slot.broken = true
            return void
        }
    }
}

/**
 * Let go of every channel an answer couldn't be sent on, as each would be if its program had closed it: a network
 * channel's lookups dropped, a stream's connection aborted, a listener's and a socket's closed.
 *
 * @param service The service.
 */
drop_broken :: fn(service: ptr[mut Service]) {
    serving :: &service.serving
    for i in cast[usize](0)..<serving.client_broken.count {
        if serving.client_broken[i] {
            serving.client_broken[i] = false
            if i < serving.clients.count && cast[slop_os.Handle](serving.clients.ends[i]) != slop_os.NO_HANDLE {
                drop_lookups(service, i)
                service_kit.drop_client(&serving.clients, i)
            }
        }
    }
    for i in cast[usize](0)..<STREAMS {
        if i < serving.streams.count && serving.streams[i].broken {
            free_stream_entry(service, i)
        }
    }
    for i in cast[usize](0)..<LISTENERS {
        if i < serving.listeners.count && serving.listeners[i].broken {
            close_listener_slot(service, i)
        }
    }
    for i in cast[usize](0)..<SOCKETS {
        if i < serving.sockets.count && serving.sockets[i].broken {
            close_socket_slot(service, i)
        }
    }
}

/**
 * Give an endpoint's address as the stack's.
 *
 * @param endpoint The endpoint.
 * @return Its address; null if it has none.
 */
stack_address :: fn(endpoint: net_address.Endpoint) -> net_stack.IpAddress? {
    address :: endpoint.address
    return match address.family {
        case .V4 => net_stack.IpAddress.V4(net_stack.Ipv4.{bytes = u8.[address.bytes[0], address.bytes[1], address.bytes[2], address.bytes[3]]})
        case .V6 => net_stack.IpAddress.V6(net_stack.Ipv6.{bytes = address.bytes})
        case .None => null
    }
}

/**
 * Give the stack's address as an endpoint's.
 *
 * @param address The address.
 * @param port The port.
 * @return The endpoint.
 */
endpoint_of :: fn(address: net_stack.IpAddress, port: u16) -> net_address.Endpoint {
    endpoint := net_address.Endpoint.{port = port}
    match address {
        case V4(v4) => {
            endpoint.address.family = .V4
            for byte, i in v4.bytes {
                endpoint.address.bytes[i] = byte
            }
        }
        case V6(v6) => {
            endpoint.address.family = .V6
            endpoint.address.bytes = v6.bytes
        }
    }
    return endpoint
}

/**
 * Take a program's memory for a stream: check its size, and that the stack can copy to and from it without waiting.
 *
 * Paged memory would have the service's one thread wait on the program's pager, for as long as the pager liked, and a
 * boot module or a window that isn't writable can't take what arrives. Writing nothing to it tells: the kernel
 * refuses those kinds (WrongKind) before it copies anything, and copies nothing for the rest.
 *
 * @param memory The memory, the service's now; closed if it won't do.
 * @return Its size; null if it isn't MIN_MEMORY to MAX_MEMORY, or a whole number of pairs of pages, or isn't plain
 *     writable memory.
 */
take_memory :: fn(memory: slop_os.Memory) -> u64? {
    size :: slop_os.memory_size(memory) or_else 0
    nothing : u8[1]
    if size < MIN_MEMORY || size > MAX_MEMORY || size % (2 * PAGE) != 0 || (slop_os.memory_write(memory, 0, nothing[0..<0]) is_error) {
        _ = slop_os.handle_close(cast[slop_os.Handle](memory))
        return null
    }
    return size
}

/**
 * Give a stream's rings in its memory, which the stack copies to and from through the kernel.
 *
 * @param memory The memory, the service's while the connection lasts.
 * @param bytes Its size.
 * @return The rings: the first half the program writes, the second what arrives.
 */
rings_of :: fn(memory: slop_os.Memory, bytes: u64) -> net_stack.TcpRings {
    handle :: cast[u64](cast[u32](memory))
    return net_stack.TcpRings.{send = net_stack.Ring.{at = 0, bytes = bytes / 2, memory = handle},
        receive = net_stack.Ring.{at = bytes / 2, bytes = bytes / 2, memory = handle}}
}

/**
 * Find a free stream entry for a root, charged to it.
 *
 * @param service The service.
 * @param root The root.
 * @return Its index, its root set; null if all are taken, or the root holds STREAMS_PER_ROOT.
 */
free_stream :: fn(service: ptr[mut Service], root: u64) -> usize? {
    if streams_of(service, root) >= STREAMS_PER_ROOT {
        return null
    }
    for &each, i in service.serving.streams {
        if cast[slop_os.Handle](each.end) == slop_os.NO_HANDLE {
            each.root = root
            return i
        }
    }
    return null
}

/**
 * Make a stream's channel, its service end bound to the port.
 *
 * @param service The service.
 * @param index The stream's index.
 * @return The program's end; null if the channel couldn't be made or bound.
 */
make_stream_channel :: fn(service: ptr[mut Service], index: usize) -> os.Channel[tcp_stream.TcpStream]? {
    startup :: slop_os.startup_block()
    pair :: os.channel_for[tcp_stream.TcpStream](startup.budget, 0) or_return null
    signals :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    if slop_os.port_bind(service.port, cast[slop_os.Handle](pair.b), signals, STREAM_KEY + cast[u64](index), .Persistent) is_error {
        _ = slop_os.handle_close(cast[slop_os.Handle](pair.a))
        _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
        return null
    }
    if index < service.serving.streams.count {
        service.serving.streams[index].end = pair.b
    }
    return os.Channel[tcp_stream.TcpStream].{end = pair.a}
}

/**
 * Open a TCP connection for a program.
 *
 * @param service The service.
 * @param open What Open asked.
 * @param root The root it's charged to.
 * @return Opened with the connection's channel; or Refused.
 */
open_stream :: fn(service: ptr[mut Service], open: network.OpenTo, root: u64) -> network.Response {
    stack :: match service.stack {
        case Some(found) => found
        case None => {
            _ = slop_os.handle_close(cast[slop_os.Handle](open.memory))
            return .Refused(.NoRoute)
        }
    }
    to :: match stack_address(open.to) {
        case Some(found) => found
        case None => {
            _ = slop_os.handle_close(cast[slop_os.Handle](open.memory))
            return .Refused(.BadEndpoint)
        }
    }
    if open.to.port == 0 {
        _ = slop_os.handle_close(cast[slop_os.Handle](open.memory))
        return .Refused(.BadEndpoint)
    }
    index :: match free_stream(service, root) {
        case Some(found) => found
        case None => {
            _ = slop_os.handle_close(cast[slop_os.Handle](open.memory))
            return .Refused(.NoRoom)
        }
    }
    if index >= service.serving.streams.count {
        _ = slop_os.handle_close(cast[slop_os.Handle](open.memory))
        return .Refused(.NoRoom)
    }
    bytes :: take_memory(open.memory) or_return .Refused(.BadMemory)
    connection :: match net_stack.tcp_connect(stack, to, open.to.port, rings_of(open.memory, bytes)) {
        case Some(found) => found
        case None => {
            release_memory(open.memory)
            return .Refused(if net_stack.has_source(stack, to) { network.Refusal.NoRoom } else { network.Refusal.NoRoute })
        }
    }
    channel :: match make_stream_channel(service, index) {
        case Some(found) => found
        case None => {
            net_stack.tcp_abort(stack, connection)
            release_memory(open.memory)
            return .Refused(.NoRoom)
        }
    }
    stream :: &service.serving.streams[index]
    stream.connection = connection
    stream.memory = open.memory
    stream.bytes = bytes
    stream.watching = false
    stream.ended = false
    stream.ending = .None
    stream.remote = open.to
    pump(service, stack)
    return .Opened(channel)
}

/**
 * Give back a stream's memory: closed.
 *
 * @param memory The memory.
 */
release_memory :: fn(memory: slop_os.Memory) {
    _ = slop_os.handle_close(cast[slop_os.Handle](memory))
}

/**
 * Give a stream's progress, as the stack has it, or as it ended.
 *
 * @param service The service.
 * @param stream The stream.
 * @return Its progress.
 */
progress_of :: fn(service: ptr[Service], stream: ptr[Stream]) -> tcp_stream.Progress {
    if stream.ended {
        return stream.final
    }
    stack :: match service.stack {
        case Some(found) => found
        case None => return tcp_stream.Progress.{ending = .Aborted}
    }
    status :: net_stack.tcp_status(stack, stream.connection)
    connected :: status.state != .SynSent && status.state != .Incoming && status.state != .SynReceived && status.state != .Free
    return tcp_stream.Progress.{delivered = status.delivered, acknowledged = status.acknowledged, connected = connected,
        peer_finished = status.peer_finished}
}

/**
 * Answer a stream's held Watch, if its progress differs from what it holds.
 *
 * @param service The service.
 * @param index The stream's index.
 */
answer_watch :: fn(service: ptr[mut Service], index: usize) {
    if index >= service.serving.streams.count {
        return void
    }
    stream :: &service.serving.streams[index]
    if !stream.watching || cast[slop_os.Handle](stream.end) == slop_os.NO_HANDLE {
        return void
    }
    progress :: progress_of(service, stream)
    if tcp_stream.same_progress(progress, stream.watched) {
        return void
    }
    stream.watching = false
    out := os.Outgoing.{}
    made :: os.begin[tcp_stream.Response](&out)
    made^ = .Progress(progress)
    answered(service, stream.end, tcp_stream.send_response(stream.end, service.port, &out, wait = false))
}

/**
 * Answer every request a stream's channel has sent, until there are none left, or it's gone, when the connection's
 * aborted if it hasn't ended, and the stream freed.
 *
 * @param service The service.
 * @param index The stream's index.
 * @param into Where each request is received.
 */
serve_stream :: fn(service: ptr[mut Service], index: usize, into: ptr[mut os.Incoming]) {
    if index >= service.serving.streams.count {
        return void
    }
    stream :: &service.serving.streams[index]
    end :: stream.end
    if cast[slop_os.Handle](end) == slop_os.NO_HANDLE {
        return void
    }
    stack :: service.stack or_return void
    loop {
        match tcp_stream.receive_request(end, service.port, into, false) {
            case Received => {}
            case Empty => break
            case Unsupported => {
                answered(service, end, tcp_stream.answer_unsupported(end, service.port, wait = false))
                continue
            }
            case _ => {
                free_stream_entry(service, index)
                return void
            }
        }
        match os.message_of[tcp_stream.Request](into)^ {
            case Watch(known) => {
                stream.watching = true
                stream.watched = known
            }
            case Wrote(written) => if !stream.ended {
                net_stack.tcp_wrote(stack, stream.connection, written)
            }
            case Read(read) => if !stream.ended {
                net_stack.tcp_read(stack, stream.connection, read)
            }
            case Finish => if !stream.ended {
                net_stack.tcp_finish(stack, stream.connection)
            }
            case Abort => if !stream.ended {
                if stream.race.racing {
                    abort_attempts(stack, &stream.race)
                    stream.race.racing = false
                }
                else {
                    net_stack.tcp_abort(stack, stream.connection)
                }
            }
            case Describe => {
                out := os.Outgoing.{}
                made :: os.begin[tcp_stream.Response](&out)
                index :: cast[usize](stream.connection & 0xffff)
                // Its own connection's port only: the entry may be another's since this one ended
                port :: if index < stack.tcbs.count && cast[u32](stack.tcbs[index].generation) == stream.connection >> 16 {
                    stack.tcbs[index].local_port } else { cast[u16](0) }
                local :: match stream.remote.address.family {
                    case .V4 => endpoint_of(.V4(stack.ipv4), port)
                    case _ => net_address.Endpoint.{port = port}
                }
                made^ = .Described(tcp_stream.StreamInfo.{local = local, remote = stream.remote, ring_bytes = stream.bytes / 2})
                answered(service, end, tcp_stream.send_response(end, service.port, &out, wait = false))
            }
        }
    }
    answer_watch(service, index)
}

/**
 * Free a stream whose channel's gone: its connection aborted if it hasn't ended, its memory given back.
 *
 * @param service The service.
 * @param index The stream's index.
 */
free_stream_entry :: fn(service: ptr[mut Service], index: usize) {
    if index >= service.serving.streams.count {
        return void
    }
    stream :: &service.serving.streams[index]
    if !stream.ended {
        match service.stack {
            case Some(stack) => if stream.race.racing { abort_attempts(stack, &stream.race) } else { net_stack.tcp_abort(stack, stream.connection) }
            case None => {}
        }
    }
    stream.race = Race.{}
    stream.broken = false
    _ = slop_os.port_unbind(service.port, STREAM_KEY + cast[u64](index))
    _ = slop_os.handle_close(cast[slop_os.Handle](stream.end))
    stream.end = cast[slop_os.Channel](slop_os.NO_HANDLE)
    if cast[slop_os.Handle](stream.memory) != slop_os.NO_HANDLE {
        release_memory(stream.memory)
        stream.memory = cast[slop_os.Memory](slop_os.NO_HANDLE)
    }
}

/**
 * Find the stream of a connection.
 *
 * @param service The service.
 * @param connection The connection's number.
 * @return The stream's index; null if no stream has it.
 */
stream_of :: fn(service: ptr[Service], connection: u32) -> usize? {
    for &each, i in service.serving.streams {
        if cast[slop_os.Handle](each.end) != slop_os.NO_HANDLE && !each.ended && (each.connection == connection || is_attempt(each, connection)) {
            return i
        }
    }
    return null
}

/**
 * Take what the stack says of connections and sockets: each changed connection's held Watch answered, each ended one
 * noted, each incoming one accepted into an Accept's memory or kept waiting, and each socket's datagram answered.
 *
 * @param service The service.
 * @param stack The stack.
 */
take_stack_news :: fn(service: ptr[mut Service], stack: ptr[mut net_stack.Stack]) {
    loop {
        connection :: net_stack.take_changed(stack) or_break
        match stream_of(service, connection) {
            case Some(index) => {
                if index < service.serving.streams.count && service.serving.streams[index].race.racing {
                    attempt_changed(service, stack, index, connection)
                }
                answer_watch(service, index)
            }
            case None => {}
        }
    }
    for i in cast[usize](0)..<SOCKETS {
        answer_receive(service, i)
    }
    for i in cast[usize](0)..<LISTENERS {
        accept_pending(service, i)
    }
}

/**
 * Note a connection ended, for its stream.
 *
 * @param service The service.
 * @param ended The stack's Ended.
 */
connection_ended :: fn(service: ptr[mut Service], ended: net_stack.TcpEnded) {
    forget_pending(service, ended.connection)
    index :: stream_of(service, ended.connection) or_return void
    if index >= service.serving.streams.count {
        return void
    }
    stream :: &service.serving.streams[index]
    if stream.race.racing {
        stack :: service.stack or_return void
        if !attempt_ended(service, stack, index, ended) {
            answer_watch(service, index)
            return void
        }
    }
    connected :: ended.why == .Closed || ended.why == .Reset || ended.why == .Aborted
    stream.final = tcp_stream.Progress.{delivered = ended.delivered, acknowledged = ended.acknowledged, connected = connected,
        peer_finished = ended.why == .Closed, ending = ending_of(ended.why)}
    stream.ended = true
    answer_watch(service, index)
}

/**
 * Take a connection that's ended off whichever listener's waiting list it's on, so no Accept is spent on it.
 *
 * @param service The service.
 * @param connection The connection.
 */
forget_pending :: fn(service: ptr[mut Service], connection: u32) {
    for &slot in service.serving.listeners {
        with {
            i := cast[usize](0)
        }
        loop {
            if i < slot.pending.count && slot.pending[i] == connection {
                for j in i + 1..<slot.pending_count {
                    if j < slot.pending.count && j < slot.pending_remote.count {
                        slot.pending[j - 1] = slot.pending[j]
                        slot.pending_remote[j - 1] = slot.pending_remote[j]
                    }
                }
                slot.pending_count -= 1
                continue
            }
            i += 1
        }
        while i < slot.pending_count
    }
}

/**
 * Give the protocol's ending for the stack's.
 *
 * @param why The stack's.
 * @return The protocol's.
 */
ending_of :: fn(why: net_stack.TcpEnding) -> tcp_stream.Ending {
    return match why {
        case .Closed => .Closed
        case .Reset => .Reset
        case .Refused => .Refused
        case .TimedOut => .TimedOut
        case .Aborted => .Aborted
        case .NotAccepted => .Aborted
    }
}

/**
 * Listen on a port for a program.
 *
 * @param service The service.
 * @param port The port.
 * @param root The root it's charged to.
 * @return Listening with the listener's channel; or Refused, NoRoom also once the root holds LISTENERS_PER_ROOT.
 */
open_listener :: fn(service: ptr[mut Service], port: u16, root: u64) -> network.Response {
    startup :: slop_os.startup_block()
    stack :: service.stack or_return .Refused(.NoRoute)
    if port == 0 {
        return .Refused(.BadEndpoint)
    }
    index := cast[usize](LISTENERS)
    held := cast[usize](0)
    for each, i in service.serving.listeners {
        if cast[slop_os.Handle](each.end) == slop_os.NO_HANDLE {
            if index == LISTENERS {
                index = i
            }
        }
        else if each.root == root {
            held += 1
        }
    }
    if held >= LISTENERS_PER_ROOT {
        return .Refused(.NoRoom)
    }
    if index >= service.serving.listeners.count {
        return .Refused(.NoRoom)
    }
    listener :: net_stack.tcp_listen(stack, port) or_return .Refused(.PortTaken)
    pair :: match os.channel_for[tcp_listener.TcpListener](startup.budget, 0) {
        case Ok(found) => found
        case Error(error) => {
            net_stack.tcp_unlisten(stack, listener)
            return .Refused(.NoRoom)
        }
    }
    signals :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    if slop_os.port_bind(service.port, cast[slop_os.Handle](pair.b), signals, LISTENER_KEY + cast[u64](index), .Persistent) is_error {
        net_stack.tcp_unlisten(stack, listener)
        _ = slop_os.handle_close(cast[slop_os.Handle](pair.a))
        _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
        return .Refused(.NoRoom)
    }
    service.serving.listeners[index] = ListenerSlot.{end = pair.b, listener = listener, root = root}
    return .Listening(os.Channel[tcp_listener.TcpListener].{end = pair.a})
}

/**
 * Answer every request a listener's channel has sent; once it's gone, stop listening.
 *
 * @param service The service.
 * @param index The listener's index.
 * @param into Where each request is received.
 */
serve_listener :: fn(service: ptr[mut Service], index: usize, into: ptr[mut os.Incoming]) {
    if index >= service.serving.listeners.count {
        return void
    }
    slot :: &service.serving.listeners[index]
    end :: slot.end
    if cast[slop_os.Handle](end) == slop_os.NO_HANDLE {
        return void
    }
    loop {
        match tcp_listener.receive_request(end, service.port, into, false) {
            case Received => {}
            case Empty => break
            case Unsupported => {
                answered(service, end, tcp_listener.answer_unsupported(end, service.port, wait = false))
                continue
            }
            case _ => {
                close_listener_slot(service, index)
                return void
            }
        }
        match os.message_of[tcp_listener.Request](into)^ {
            case Accept(memory) => {
                if slot.held_count >= slot.held.count {
                    _ = slop_os.handle_close(cast[slop_os.Handle](memory))
                    answer_listener(service, end, .Refused(.TooMany))
                }
                else {
                    slot.held[slot.held_count] = memory
                    slot.held_count += 1
                }
            }
        }
    }
    accept_pending(service, index)
}

/**
 * Send an answer on a listener's channel.
 *
 * @param service The service.
 * @param end The channel.
 * @param response The answer.
 */
answer_listener :: fn(service: ptr[mut Service], end: slop_os.Channel, response: tcp_listener.Response) {
    out := os.Outgoing.{}
    made :: os.begin[tcp_listener.Response](&out)
    made^ = response
    answered(service, end, tcp_listener.send_response(end, service.port, &out, wait = false))
}

/**
 * Stop a listener whose channel's gone: unlistened in the stack, its held memories closed, and connections waiting for
 * it aborted.
 *
 * @param service The service.
 * @param index The listener's index.
 */
close_listener_slot :: fn(service: ptr[mut Service], index: usize) {
    slot :: &service.serving.listeners[index % service.serving.listeners.count]
    match service.stack {
        case Some(stack) => {
            net_stack.tcp_unlisten(stack, slot.listener)
            for i in 0..<slot.pending_count {
                if i < slot.pending.count {
                    net_stack.tcp_abort(stack, slot.pending[i])
                }
            }
        }
        case None => {}
    }
    for i in 0..<slot.held_count {
        if i < slot.held.count {
            _ = slop_os.handle_close(cast[slop_os.Handle](slot.held[i]))
        }
    }
    _ = slop_os.port_unbind(service.port, LISTENER_KEY + cast[u64](index))
    _ = slop_os.handle_close(cast[slop_os.Handle](slot.end))
    slot^ = ListenerSlot.{end = cast[slop_os.Channel](slop_os.NO_HANDLE)}
}

/**
 * Keep a connection arrived at a listener: accepted at once into a held Accept's memory, else kept waiting for one.
 *
 * @param service The service.
 * @param incoming The stack's Incoming.
 */
connection_arrived :: fn(service: ptr[mut Service], incoming: net_stack.TcpIncoming) {
    for &slot in service.serving.listeners {
        if cast[slop_os.Handle](slot.end) != slop_os.NO_HANDLE && slot.listener == incoming.listener {
            at :: slot.pending_count
            remote :: endpoint_of(incoming.remote, incoming.remote_port)
            if at < slot.pending.count && at < slot.pending_remote.count {
                slot.pending[at] = incoming.connection
                slot.pending_remote[at] = remote
                slot.pending_count = at + 1
            }
            return void
        }
    }
}

/**
 * Accept a listener's waiting connections into its held Accepts' memory, oldest of each first.
 *
 * @param service The service.
 * @param index The listener's index.
 */
accept_pending :: fn(service: ptr[mut Service], index: usize) {
    if index >= service.serving.listeners.count {
        return void
    }
    stack :: service.stack or_return void
    loop {
        slot :: &service.serving.listeners[index]
        if cast[slop_os.Handle](slot.end) == slop_os.NO_HANDLE || slot.pending_count == 0 || slot.held_count == 0 {
            return void
        }
        connection :: slot.pending[0]
        remote :: slot.pending_remote[0]
        memory :: slot.held[0]
        for i in cast[usize](1)..<slot.pending_count {
            if i < slot.pending.count {
                slot.pending[i - 1] = slot.pending[i]
                slot.pending_remote[i - 1] = slot.pending_remote[i]
            }
        }
        slot.pending_count -= 1
        for i in cast[usize](1)..<slot.held_count {
            if i < slot.held.count {
                slot.held[i - 1] = slot.held[i]
            }
        }
        slot.held_count -= 1
        end :: slot.end
        stream_index :: match free_stream(service, slot.root) {
            case Some(found) => found
            case None => {
                net_stack.tcp_abort(stack, connection)
                _ = slop_os.handle_close(cast[slop_os.Handle](memory))
                answer_listener(service, end, .Refused(.TooMany))
                continue
            }
        }
        bytes :: match take_memory(memory) {
            case Some(found) => found
            case None => {
                net_stack.tcp_abort(stack, connection)
                answer_listener(service, end, .Refused(.BadMemory))
                continue
            }
        }
        if !net_stack.tcp_accept(stack, connection, rings_of(memory, bytes)) {
            // It went before it was taken: the Accept's memory waits for the next, first again
            if slot.held_count < slot.held.count {
                with {
                    i := slot.held_count
                }
                loop {
                    if i < slot.held.count {
                        slot.held[i] = slot.held[i - 1]
                    }
                    i -= 1
                }
                while i > 0
                slot.held[0] = memory
                slot.held_count += 1
            }
            else {
                release_memory(memory)
                answer_listener(service, end, .Refused(.TooMany))
            }
            continue
        }
        channel :: match make_stream_channel(service, stream_index) {
            case Some(found) => found
            case None => {
                net_stack.tcp_abort(stack, connection)
                release_memory(memory)
                answer_listener(service, end, .Refused(.TooMany))
                continue
            }
        }
        if stream_index >= service.serving.streams.count {
            continue
        }
        stream :: &service.serving.streams[stream_index]
        stream.connection = connection
        stream.memory = memory
        stream.bytes = bytes
        stream.watching = false
        stream.ended = false
        stream.ending = .None
        stream.remote = remote
        answer_listener(service, end, .Accepted(tcp_listener.Accepted.{stream = channel, remote = remote}))
    }
}

/**
 * Open a UDP socket for a program.
 *
 * @param service The service.
 * @param port The port, or 0 for an ephemeral one.
 * @param root The root it's charged to.
 * @return Bound with the socket's channel; or Refused, NoRoom also once the root holds SOCKETS_PER_ROOT.
 */
open_socket :: fn(service: ptr[mut Service], port: u16, policy: ptr[network.Policy], root: u64) -> network.Response {
    startup :: slop_os.startup_block()
    stack :: service.stack or_return .Refused(.NoRoute)
    index := cast[usize](SOCKETS)
    held := cast[usize](0)
    for each, i in service.serving.sockets {
        if cast[slop_os.Handle](each.end) == slop_os.NO_HANDLE {
            if index == SOCKETS {
                index = i
            }
        }
        else if each.root == root {
            held += 1
        }
    }
    if held >= SOCKETS_PER_ROOT {
        return .Refused(.NoRoom)
    }
    if index >= service.serving.sockets.count {
        return .Refused(.NoRoom)
    }
    socket :: net_stack.udp_open(stack, port) or_return .Refused(if port != 0 { network.Refusal.PortTaken } else { network.Refusal.NoRoom })
    pair :: match os.channel_for[datagrams.Datagrams](startup.budget, datagrams.RING_BYTES) {
        case Ok(found) => found
        case Error(error) => {
            net_stack.udp_close(stack, socket)
            return .Refused(.NoRoom)
        }
    }
    signals :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    if slop_os.port_bind(service.port, cast[slop_os.Handle](pair.b), signals, SOCKET_KEY + cast[u64](index), .Persistent) is_error {
        net_stack.udp_close(stack, socket)
        _ = slop_os.handle_close(cast[slop_os.Handle](pair.a))
        _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
        return .Refused(.NoRoom)
    }
    service.serving.sockets[index] = SocketSlot.{end = pair.b, socket = socket, policy = policy^, root = root}
    return .Bound(os.Channel[datagrams.Datagrams].{end = pair.a})
}

/**
 * Close a socket whose channel's gone, or broken: the stack's socket closed, the channel closed, the slot freed.
 *
 * @param service The service.
 * @param index The socket's index.
 */
close_socket_slot :: fn(service: ptr[mut Service], index: usize) {
    if index >= service.serving.sockets.count {
        return void
    }
    slot :: &service.serving.sockets[index]
    match service.stack {
        case Some(stack) => net_stack.udp_close(stack, slot.socket)
        case None => {}
    }
    _ = slop_os.port_unbind(service.port, SOCKET_KEY + cast[u64](index))
    _ = slop_os.handle_close(cast[slop_os.Handle](slot.end))
    slot^ = SocketSlot.{end = cast[slop_os.Channel](slop_os.NO_HANDLE)}
}

/**
 * Answer every request a socket's channel has sent; once it's gone, close the socket.
 *
 * @param service The service.
 * @param index The socket's index.
 * @param into Where each request is received.
 */
serve_socket :: fn(service: ptr[mut Service], index: usize, into: ptr[mut os.Incoming]) {
    if index >= service.serving.sockets.count {
        return void
    }
    slot :: &service.serving.sockets[index]
    end :: slot.end
    if cast[slop_os.Handle](end) == slop_os.NO_HANDLE {
        return void
    }
    stack :: service.stack or_return void
    loop {
        match datagrams.receive_request(end, service.port, into, false) {
            case Received => {}
            case Empty => break
            case Unsupported => {
                answered(service, end, datagrams.answer_unsupported(end, service.port, wait = false))
                continue
            }
            case _ => {
                close_socket_slot(service, index)
                return void
            }
        }
        match os.message_of[datagrams.Request](into)^ {
            case Send(send) => {
                // One the policy doesn't allow is dropped, as one lost would be
                match stack_address(send.to) {
                    case Some(to) => if network.allows_connect(&slot.policy, network.TRANSPORT_UDP, send.to) {
                        _ = net_stack.udp_send(stack, slot.socket, to, send.to.port, os.items(into, send.bytes))
                    }
                    case None => {}
                }
            }
            case Receive => slot.receiving = true
            case Describe => {
                out := os.Outgoing.{}
                made :: os.begin[datagrams.Response](&out)
                made^ = .Described(endpoint_of(.V4(stack.ipv4), net_stack.udp_port(stack, slot.socket)))
                answered(service, end, datagrams.send_response(end, service.port, &out, wait = false))
            }
        }
    }
    answer_receive(service, index)
}

/**
 * Answer a socket's held Receive with its oldest waiting datagram, if there is one.
 *
 * @param service The service.
 * @param index The socket's index.
 */
answer_receive :: fn(service: ptr[mut Service], index: usize) {
    if index >= service.serving.sockets.count {
        return void
    }
    slot :: &service.serving.sockets[index]
    if !slot.receiving || cast[slop_os.Handle](slot.end) == slop_os.NO_HANDLE {
        return void
    }
    stack :: service.stack or_return void
    payload : u8[net_stack.MAX_DATAGRAM]
    got := net_stack.DatagramFrom.{}
    // Datagrams from peers the policy doesn't allow are dropped
    loop {
        got = net_stack.take_datagram(stack, slot.socket, view_of(&payload[0], payload.count)) or_return void
        if network.allows_connect(&slot.policy, network.TRANSPORT_UDP, endpoint_of(got.from, got.from_port)) {
            break
        }
    }
    while true
    slot.receiving = false
    count :: if got.length < payload.count { got.length } else { payload.count }
    out := os.Outgoing.{}
    made :: os.begin[datagrams.Response](&out)
    made^ = .Datagram(datagrams.Arrived.{from = endpoint_of(got.from, got.from_port), bytes = os.append(&out, view_of(&payload[0], count))})
    answered(service, slot.end, datagrams.send_response(slot.end, service.port, &out, wait = false))
}
