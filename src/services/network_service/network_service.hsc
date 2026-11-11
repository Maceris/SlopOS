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
 * data is in the program's memory, mapped here at an address slot of the connection's, MAX_MEMORY each, so addresses
 * are reused as connections come and go.
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
    match command_line {
        case Some(memory) => service.test_ping = service_kit.has_word(service_kit.text_of(startup, memory) or_else "", "test_ping")
        case None => {}
    }
    if !start_serving(service, clients) {
        return 3
    }
    match nic {
        case Some(dialing) => take_nic(service, dialing)
        case None => runtime.log_info("no network interface")
    }
    into := os.Incoming.{}
    loop {
        take_answers(service, &into)
        serve_programs(service, &into)
        match service.stack {
            case Some(stack) => {
                net_stack.tick(stack, now())
                pump(service, stack)
            }
            case None => {}
        }
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
    net_stack.start(stack, net_stack.Setup.{mac = net_stack.Mac.{bytes = mac}, mtu = service.info.mtu, seed = random.next_u64()}, now())
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
    }
    deadline :: net_stack.next_deadline(stack)
    if deadline != ~cast[u64](0) {
        _ = slop_os.port_set_timer(service.port, TIMER_KEY, deadline)
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
/** The largest memory a connection's rings take: 1 MiB, two rings of 512 KiB; each stream's address slot is this. */
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
    /** Each stream's address slot, MAX_MEMORY apart, from slots on; 0 if they couldn't be reserved. */
    slots : u64,
}

/**
 * Set up serving: the address slots for streams' memory, and the listener for programs' connections.
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
    serving.slots = runtime.reserve_addresses(cast[usize](cast[u64](STREAMS) * MAX_MEMORY)) or_else 0
    return serving.slots != 0 && add_network_client(service, clients.end, network.everything())
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
                _ = network.answer_unsupported(end, service.port)
                continue
            }
            case _ => {
                service_kit.drop_client(&serving.clients, index)
                return void
            }
        }
        if index >= serving.policies.count {
            return void
        }
        policy :: &serving.policies[index]
        match os.message_of[network.Request](into)^ {
            case Open(open) => {
                if network.allows_connect(policy, network.TRANSPORT_TCP, open.to) {
                    answer_network(service, end, open_stream(service, open))
                }
                else {
                    _ = slop_os.handle_close(cast[slop_os.Handle](open.memory))
                    answer_network(service, end, .Refused(.NotAllowed))
                }
            }
            case Listen(port) => answer_network(service, end, if network.allows_listen(policy, network.TRANSPORT_TCP, port) {
                open_listener(service, port) } else { network.Response.Refused(.NotAllowed) })
            case Udp(port) => answer_network(service, end, if port == 0 || network.allows_listen(policy, network.TRANSPORT_UDP, port) {
                open_socket(service, port, policy) } else { network.Response.Refused(.NotAllowed) })
            case Narrow(narrowing) => {
                wanted := network.policy_of(os.items(into, narrowing.connect), os.items(into, narrowing.listen))
                    or_else network.Policy.{connect_count = network.MAX_RULES + 1}
                // One with too many rules is refused, as it's no policy at all
                allowed :: wanted.connect_count <= network.MAX_RULES && network.within(policy, &wanted)
                answer_network(service, end, if allowed { another_connection(service, wanted) } else { network.Response.Refused(.NotAllowed) })
            }
            case Copy => answer_network(service, end, another_connection(service, policy^))
            case Connect(connection) => {
                /*
                 * Through the listener, the first client: everything allowed, as the supervisor gives the listener only
                 * to who holds the network. Through any other connection, that connection's policy, so a Connect is
                 * no way around a Narrow
                 */
                given :: if index == 0 { network.everything() } else { policy^ }
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
 * @return True once it's served; false if there's no room, when end isn't taken.
 */
add_network_client :: fn(service: ptr[mut Service], end: slop_os.Channel, policy: network.Policy) -> bool {
    serving :: &service.serving
    index :: service_kit.add_client_index(&serving.clients, service.port, end) or_return false
    if index < serving.policies.count {
        serving.policies[index] = policy
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
 * Send an answer on a network channel; one that can't be sent is dropped, and what it carried closed.
 *
 * @param service The service.
 * @param end The channel.
 * @param response The answer.
 */
answer_network :: fn(service: ptr[mut Service], end: slop_os.Channel, response: network.Response) {
    out := os.Outgoing.{}
    made :: os.begin[network.Response](&out)
    made^ = response
    _ = network.send_response(end, service.port, &out)
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
 * Take a program's memory for a stream: check its size and map it at the stream's slot.
 *
 * @param service The service.
 * @param index The stream's index.
 * @param memory The memory, the service's now; closed if it won't do.
 * @return Its size; null if it isn't MIN_MEMORY to MAX_MEMORY, a whole number of pairs of pages, or couldn't be mapped.
 */
take_memory :: fn(service: ptr[mut Service], index: usize, memory: slop_os.Memory) -> u64? {
    startup :: slop_os.startup_block()
    size :: slop_os.memory_size(memory) or_else 0
    if size < MIN_MEMORY || size > MAX_MEMORY || size % (2 * PAGE) != 0 || service.serving.slots == 0 {
        _ = slop_os.handle_close(cast[slop_os.Handle](memory))
        return null
    }
    at :: service.serving.slots + cast[u64](index) * MAX_MEMORY
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    if slop_os.memory_map(memory, startup.space, at, 0, size, read_write) is_error {
        _ = slop_os.handle_close(cast[slop_os.Handle](memory))
        return null
    }
    return size
}

/**
 * Give a stream's rings, in its slot.
 *
 * @param service The service.
 * @param index The stream's index.
 * @param bytes Its memory's size.
 * @return The rings: the first half the program writes, the second what arrives.
 */
rings_at :: fn(service: ptr[Service], index: usize, bytes: u64) -> net_stack.TcpRings {
    at :: service.serving.slots + cast[u64](index) * MAX_MEMORY
    return net_stack.TcpRings.{send = net_stack.Ring.{at = at, bytes = bytes / 2}, receive = net_stack.Ring.{at = at + bytes / 2, bytes = bytes / 2}}
}

/**
 * Find a free stream entry.
 *
 * @param service The service.
 * @return Its index; null if all are taken.
 */
free_stream :: fn(service: ptr[Service]) -> usize? {
    for each, i in service.serving.streams {
        if cast[slop_os.Handle](each.end) == slop_os.NO_HANDLE {
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
 * @return Opened with the connection's channel; or Refused.
 */
open_stream :: fn(service: ptr[mut Service], open: network.OpenTo) -> network.Response {
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
    index :: match free_stream(service) {
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
    bytes :: take_memory(service, index, open.memory) or_return .Refused(.BadMemory)
    connection :: match net_stack.tcp_connect(stack, to, open.to.port, rings_at(service, index, bytes)) {
        case Some(found) => found
        case None => {
            release_memory(service, index, open.memory)
            return .Refused(if net_stack.has_source(stack, to) { network.Refusal.NoRoom } else { network.Refusal.NoRoute })
        }
    }
    channel :: match make_stream_channel(service, index) {
        case Some(found) => found
        case None => {
            net_stack.tcp_abort(stack, connection)
            release_memory(service, index, open.memory)
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
 * Give back a stream's memory: unmapped from its slot and closed.
 *
 * @param service The service.
 * @param index The stream's index.
 * @param memory The memory.
 */
release_memory :: fn(service: ptr[mut Service], index: usize, memory: slop_os.Memory) {
    _ = slop_os.memory_unmap(slop_os.startup_block().space, service.serving.slots + cast[u64](index) * MAX_MEMORY)
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
    _ = tcp_stream.send_response(stream.end, service.port, &out)
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
                _ = tcp_stream.answer_unsupported(end, service.port)
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
                net_stack.tcp_abort(stack, stream.connection)
            }
            case Describe => {
                out := os.Outgoing.{}
                made :: os.begin[tcp_stream.Response](&out)
                index :: cast[usize](stream.connection & 0xffff)
                port :: if index < stack.tcbs.count { stack.tcbs[index].local_port } else { cast[u16](0) }
                local :: match stream.remote.address.family {
                    case .V4 => endpoint_of(.V4(stack.ipv4), port)
                    case _ => net_address.Endpoint.{port = port}
                }
                made^ = .Described(tcp_stream.StreamInfo.{local = local, remote = stream.remote, ring_bytes = stream.bytes / 2})
                _ = tcp_stream.send_response(end, service.port, &out)
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
            case Some(stack) => net_stack.tcp_abort(stack, stream.connection)
            case None => {}
        }
    }
    _ = slop_os.port_unbind(service.port, STREAM_KEY + cast[u64](index))
    _ = slop_os.handle_close(cast[slop_os.Handle](stream.end))
    stream.end = cast[slop_os.Channel](slop_os.NO_HANDLE)
    if cast[slop_os.Handle](stream.memory) != slop_os.NO_HANDLE {
        release_memory(service, index, stream.memory)
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
    for each, i in service.serving.streams {
        if cast[slop_os.Handle](each.end) != slop_os.NO_HANDLE && !each.ended && each.connection == connection {
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
            case Some(index) => answer_watch(service, index)
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
    index :: stream_of(service, ended.connection) or_return void
    if index >= service.serving.streams.count {
        return void
    }
    stream :: &service.serving.streams[index]
    connected :: ended.why == .Closed || ended.why == .Reset || ended.why == .Aborted
    stream.final = tcp_stream.Progress.{delivered = ended.delivered, acknowledged = ended.acknowledged, connected = connected,
        peer_finished = ended.why == .Closed, ending = ending_of(ended.why)}
    stream.ended = true
    answer_watch(service, index)
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
 * @return Listening with the listener's channel; or Refused.
 */
open_listener :: fn(service: ptr[mut Service], port: u16) -> network.Response {
    startup :: slop_os.startup_block()
    stack :: service.stack or_return .Refused(.NoRoute)
    if port == 0 {
        return .Refused(.BadEndpoint)
    }
    index := cast[usize](LISTENERS)
    for each, i in service.serving.listeners {
        if cast[slop_os.Handle](each.end) == slop_os.NO_HANDLE {
            index = i
            break
        }
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
    service.serving.listeners[index] = ListenerSlot.{end = pair.b, listener = listener}
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
                _ = tcp_listener.answer_unsupported(end, service.port)
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
    _ = tcp_listener.send_response(end, service.port, &out)
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
        stream_index :: match free_stream(service) {
            case Some(found) => found
            case None => {
                net_stack.tcp_abort(stack, connection)
                _ = slop_os.handle_close(cast[slop_os.Handle](memory))
                answer_listener(service, end, .Refused(.TooMany))
                continue
            }
        }
        bytes :: match take_memory(service, stream_index, memory) {
            case Some(found) => found
            case None => {
                net_stack.tcp_abort(stack, connection)
                answer_listener(service, end, .Refused(.BadMemory))
                continue
            }
        }
        if !net_stack.tcp_accept(stack, connection, rings_at(service, stream_index, bytes)) {
            // It went before it was taken: the Accept's memory waits for the next
            release_memory(service, stream_index, memory)
            continue
        }
        channel :: match make_stream_channel(service, stream_index) {
            case Some(found) => found
            case None => {
                net_stack.tcp_abort(stack, connection)
                release_memory(service, stream_index, memory)
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
 * @return Bound with the socket's channel; or Refused.
 */
open_socket :: fn(service: ptr[mut Service], port: u16, policy: ptr[network.Policy]) -> network.Response {
    startup :: slop_os.startup_block()
    stack :: service.stack or_return .Refused(.NoRoute)
    index := cast[usize](SOCKETS)
    for each, i in service.serving.sockets {
        if cast[slop_os.Handle](each.end) == slop_os.NO_HANDLE {
            index = i
            break
        }
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
    service.serving.sockets[index] = SocketSlot.{end = pair.b, socket = socket, policy = policy^}
    return .Bound(os.Channel[datagrams.Datagrams].{end = pair.a})
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
                _ = datagrams.answer_unsupported(end, service.port)
                continue
            }
            case _ => {
                net_stack.udp_close(stack, slot.socket)
                _ = slop_os.port_unbind(service.port, SOCKET_KEY + cast[u64](index))
                _ = slop_os.handle_close(cast[slop_os.Handle](end))
                slot^ = SocketSlot.{end = cast[slop_os.Channel](slop_os.NO_HANDLE)}
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
                _ = datagrams.send_response(end, service.port, &out)
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
    _ = datagrams.send_response(slot.end, service.port, &out)
}
