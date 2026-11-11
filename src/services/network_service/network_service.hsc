/**
 * The network service (decisions/0188): the system's network stack, over the first NIC's driver, through the net
 * protocol. In 13a it takes the interface: it dials the driver, says what it is, maps the connection's buffer and gives
 * the driver every receive slot, giving each again as its frame is read. With test_arp=<address> on the kernel's
 * command line, it asks by ARP who has that IPv4 address, from 0.0.0.0, as a probe does (RFC 5227), and logs the
 * answer.
 *
 * SPEC: RFC 826 (ARP), RFC 5227 (ARP probes)
 */
package network_service

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import connector from "../../protocols/connector"
import net from "../../protocols/net"
import service_kit from "../../libraries/service_kit"

/** The port key the NIC's connector is bound with. */
CONNECTOR_KEY : u64 : 2
/** The port key the NIC's connection is bound with. */
NIC_KEY : u64 : 1
/** Ethernet's type for ARP. */
ETHER_ARP : u16 : 0x0806
/** ARP's operation for a request. */
ARP_REQUEST : u16 : 1
/** ARP's operation for a reply. */
ARP_REPLY : u16 : 2
/** The bytes of an ARP request or reply for IPv4 over Ethernet, with its Ethernet header: 14 and 28. */
ARP_FRAME : u32 : 42

/** The service's state, on the heap, main's for its life. */
Service :: struct {
    /** The port its NIC's connection is bound to. */
    port : slop_os.Port,
    /** Its connection to the NIC's driver; NO_HANDLE without one. */
    nic : slop_os.Channel,
    /** What the NIC is. */
    info : net.Info,
    /** Where the connection's buffer is mapped, 0 before it is. */
    buffer : u64,
    /** The IPv4 address test_arp asks for, as its four bytes in a u32, high first; 0 for none. */
    probed : u32,
}

/**
 * Run the network service: take the first NIC, and serve it until the system stops.
 *
 * @param log The debug log its lines go to; without one, it writes nothing there.
 * @param nic A connector to the first NIC's driver; without one, there's no network, and it only waits to stop.
 * @param command_line The kernel's command line, read for test_arp=<a.b.c.d>.
 * @return 0 once it's asked to stop; 2 if no port could be made.
 */
main :: fn(log: slop_os.DebugLog?, nic: os.Channel[connector.Connector]?, command_line: slop_os.Memory?) -> int {
    startup :: slop_os.startup_block()
    service := runtime.new(Service)
    service.nic = cast[slop_os.Channel](slop_os.NO_HANDLE)
    service.port = slop_os.port_create(startup.budget) or_return 2
    _ = service_kit.watch_stop(service.port)
    match command_line {
        case Some(memory) => {
            text :: service_kit.text_of(startup, memory) or_else ""
            service.probed = ipv4_of(service_kit.word_after(text, "test_arp=") or_else "") or_else 0
        }
        case None => {}
    }
    match nic {
        case Some(dialing) => take_nic(service, dialing)
        case None => runtime.log_info("no network interface")
    }
    into := os.Incoming.{}
    loop {
        take_answers(service, &into)
        if service_kit.stopping() {
            return 0
        }
        packets : slop_os.Packet[8]
        _ = slop_os.port_wait(service.port, packets, slop_os.NO_DEADLINE)
    }
}

/**
 * Dial the NIC's driver, say what it is, map the buffer, give every receive slot, and send test_arp's probe.
 *
 * @param service The service, whose nic, info and buffer are set once each is had; what fails is logged, and the
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
    if service.probed != 0 {
        probe(service, service.probed)
    }
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
 * Ask by ARP who has an IPv4 address, from 0.0.0.0 as a probe does, in the first send slot.
 *
 * @param service The service, with the NIC's buffer mapped.
 * @param address The address, its four bytes high first.
 */
probe :: fn(service: ptr[mut Service], address: u32) {
    slot :: net.SLOTS
    frame :: view_of(cast[ptr[mut u8]](service.buffer + cast[u64](slot) * cast[u64](net.SLOT_BYTES)), cast[usize](ARP_FRAME))
    if frame.count < 42 {
        return void
    }
    for &byte in frame {
        byte^ = 0
    }
    mac :: service.info.mac
    // Ethernet: to everyone, from the interface, ARP
    for i in cast[usize](0)..<6 {
        frame[i] = 0xff
        frame[6 + i] = mac[i]
    }
    put_u16(frame, 12, ETHER_ARP)
    // ARP: Ethernet and IPv4, 6 and 4 bytes, a request, from the interface at 0.0.0.0, for the address
    put_u16(frame, 14, 1)
    put_u16(frame, 16, 0x0800)
    frame[18] = 6
    frame[19] = 4
    put_u16(frame, 20, ARP_REQUEST)
    for i in cast[usize](0)..<6 {
        frame[22 + i] = mac[i]
    }
    for i in cast[usize](0)..<4 {
        frame[38 + i] = cast[u8](address >> cast[u32](24 - 8 * i))
    }
    request(service, .Send(net.Frame.{slot = slot, length = ARP_FRAME}))
}

/**
 * Take every answer the NIC's driver has sent, reading each frame received and giving its slot again.
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
                read_frame(service, frame)
                request(service, .Receive(frame.slot))
            }
            case Refused(refused) => runtime.log_info("the network interface refused slot %: %", refused.slot, refused.reason)
            case Link(up) => runtime.log_info("the link is %", if up { "up" } else { "down" })
            case _ => {}
        }
    }
}

/**
 * Read a frame received: an ARP reply from the address test_arp asks for is logged.
 *
 * @param service The service, with the NIC's buffer mapped.
 * @param frame The frame, in a receive slot.
 */
read_frame :: fn(service: ptr[mut Service], frame: net.Frame) {
    if frame.slot >= net.SLOTS || frame.length < ARP_FRAME || frame.length > net.SLOT_BYTES {
        return void
    }
    bytes :: view_of(cast[ptr[u8]](service.buffer + cast[u64](frame.slot) * cast[u64](net.SLOT_BYTES)), cast[usize](frame.length))
    if bytes.count < 42 || u16_at(bytes, 12) != ETHER_ARP || u16_at(bytes, 20) != ARP_REPLY {
        return void
    }
    sender :: (cast[u32](bytes[28]) << 24) | (cast[u32](bytes[29]) << 16) | (cast[u32](bytes[30]) << 8) | cast[u32](bytes[31])
    if service.probed == 0 || sender != service.probed {
        return void
    }
    runtime.log_info("%.%.%.% is at %{02x}:%{02x}:%{02x}:%{02x}:%{02x}:%{02x}", bytes[28], bytes[29], bytes[30], bytes[31],
        bytes[22], bytes[23], bytes[24], bytes[25], bytes[26], bytes[27])
}

/**
 * Read a big-endian u16 from bytes.
 *
 * @param bytes The bytes.
 * @param at Where it starts; one whose two bytes aren't both within bytes reads as 0.
 * @return The value.
 */
u16_at :: fn(bytes: u8[], at: usize) -> u16 {
    after :: at + 1
    if at >= bytes.count || after >= bytes.count {
        return 0
    }
    return (cast[u16](bytes[at]) << 8) | cast[u16](bytes[after])
}

/**
 * Write a big-endian u16 into bytes.
 *
 * @param bytes The bytes.
 * @param at Where it starts; one whose two bytes aren't both within bytes writes nothing.
 * @param value The value.
 */
put_u16 :: fn(bytes: mut u8[], at: usize, value: u16) {
    after :: at + 1
    if at >= bytes.count || after >= bytes.count {
        return void
    }
    bytes[at] = cast[u8](value >> 8)
    bytes[after] = cast[u8](value)
}

/**
 * Read an IPv4 address in dotted decimal.
 *
 * @param text The address, as four numbers from 0 to 255 with dots between, and nothing else.
 * @return Its four bytes, high first; null if it isn't one.
 */
ipv4_of :: fn(text: string) -> u32? {
    value := cast[u32](0)
    part := cast[u32](0)
    digits := 0
    dots := 0
    for character in text {
        if character == '.' {
            if digits == 0 || dots >= 3 {
                return null
            }
            value = (value << 8) | part
            part = 0
            digits = 0
            dots += 1
        }
        else if character >= '0' && character <= '9' {
            part = part * 10 + (cast[u32](character) - cast[u32]('0'))
            digits += 1
            if part > 255 || digits > 3 {
                return null
            }
        }
        else {
            return null
        }
    }
    if digits == 0 || dots != 3 {
        return null
    }
    return (value << 8) | part
}
