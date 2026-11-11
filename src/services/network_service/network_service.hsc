/**
 * The network service (decisions/0188): the system's network stack, over the first NIC's driver, through the net
 * protocol. It takes the interface, as 13a built, and runs the network layer (src/net_stack) on it, 13b: an IPv4 address
 * by DHCP, IPv6 addresses by SLAAC, each logged as it's had. Frames received go to the stack, and each slot is given
 * back; frames the stack queues go out through the send slots free, the rest waiting in the stack until one is; its
 * timers are one port timer, at its next deadline.
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
import connector from "../../protocols/connector"
import net from "../../protocols/net"
import net_stack from "../../net_stack"
import service_kit from "../../libraries/service_kit"

/** The port key the NIC's connection is bound with. */
NIC_KEY : u64 : 1
/** The port key the NIC's connector is bound with. */
CONNECTOR_KEY : u64 : 2
/** The port key the stack's timer is bound with. */
TIMER_KEY : u64 : 3

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
}

/**
 * Run the network service: take the first NIC, and serve it until the system stops.
 *
 * @param log The debug log its lines go to; without one, it writes nothing there.
 * @param nic A connector to the first NIC's driver; without one, there's no network, and it only waits to stop.
 * @param command_line The kernel's command line, read for test_ping.
 * @return 0 once it's asked to stop; 2 if no port could be made.
 */
main :: fn(log: slop_os.DebugLog?, nic: os.Channel[connector.Connector]?, command_line: slop_os.Memory?) -> int {
    startup :: slop_os.startup_block()
    service := runtime.new(Service)
    service.nic = cast[slop_os.Channel](slop_os.NO_HANDLE)
    service.port = slop_os.port_create(startup.budget) or_return 2
    _ = service_kit.watch_stop(service.port)
    match command_line {
        case Some(memory) => service.test_ping = service_kit.has_word(service_kit.text_of(startup, memory) or_else "", "test_ping")
        case None => {}
    }
    match nic {
        case Some(dialing) => take_nic(service, dialing)
        case None => runtime.log_info("no network interface")
    }
    into := os.Incoming.{}
    loop {
        take_answers(service, &into)
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
