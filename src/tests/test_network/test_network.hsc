/**
 * The network's test client (decisions/0188, 13c): started by the supervisor with test_network on the kernel's command
 * line, it reaches the development machine through QEMU's user-mode network, where boot.py serves echo peers
 * (--network-peers), and logs what it finds:
 *
 * - a TCP connection to the echo peer at 10.0.2.2:<tcp_echo>, its echo of every byte written checked;
 * - a datagram to the UDP echo peer at 10.0.2.2:<udp_echo>, its echo checked;
 * - a listener on port 7, which echoes back what the development machine sends through QEMU's forward, once it says
 *   it's listening;
 * - with tcp_sink=<port>, how long SINK_BYTES take to send to the sink there, as "perf: tcp_send_4mib <nanoseconds>",
 *   which tools/perf_tests.py reports;
 * - with dns=<address>:<port>, which the network service asks for names (13e), names: peer.slopos.test resolved to the
 *   development machine's addresses, IPv6's first, and reached by name through a connection allowing QEMU's ranges,
 *   its IPv6 address, which QEMU never connects, passed over for its IPv4 one as Happy Eyeballs does; the same name
 *   refused through a connection allowing public addresses only, as it's answered with a private one; and a name
 *   that doesn't exist.
 *
 * A connection refused isn't among them: QEMU's user-mode network doesn't answer a SYN for a closed port on the
 * development machine at all, so the stack's retries would run a minute to a timeout. net_stack's hosted tests check
 * refusal.
 */
package test_network

import runtime from "base"
import net from "std"
import os from "std"
import text_buffer from "std"
import slop_os from "std/os"
import net_address from "std/os/slop_os"
import network from "std/os/slop_os"
import connector from "../../protocols/connector"
import service_kit from "../../libraries/service_kit"

/** How many bytes the TCP echo exchanges: 64 KiB. */
ECHO_BYTES : usize : 65536
/** How many bytes are written before what's echoed is read back: 8 KiB, so neither side's rings fill. */
CHUNK :: 8192
/** How many bytes the throughput measure sends: 4 MiB. */
SINK_BYTES : usize : 4 << 20
/** How many times an Open is tried while there's no route yet, as the lease is still coming: 60, half a second apart. */
OPEN_TRIES :: 60

/**
 * Run the network's tests.
 *
 * @param log The debug log its lines go to.
 * @param network A connector to the network service.
 * @param command_line The kernel's command line: tcp_echo=<port> and udp_echo=<port>.
 * @return 0, whatever it found, which its lines say; 2 without a network service or its peers' ports.
 */
main :: fn(log: slop_os.DebugLog?, network: os.Channel[connector.Connector]?, command_line: slop_os.Memory?) -> int {
    startup :: slop_os.startup_block()
    dialing :: network or_return 2
    text :: service_kit.text_of(startup, command_line or_return 2) or_else ""
    tcp_echo :: cast[u16](service_kit.number_of(service_kit.word_after(text, "tcp_echo=") or_else "") or_else 0)
    udp_echo :: cast[u16](service_kit.number_of(service_kit.word_after(text, "udp_echo=") or_else "") or_else 0)
    tcp_sink :: cast[u16](service_kit.number_of(service_kit.word_after(text, "tcp_sink=") or_else "") or_else 0)
    if tcp_echo == 0 || udp_echo == 0 {
        runtime.log_info("no peers' ports on the command line")
        return 2
    }
    port :: os.port_for(startup.budget, dialing.end) or_return 2
    service :: connector.dial[network.Network](dialing.end, port) or_return 2
    peer :: net_address.v4(10, 0, 2, 2)
    echo_tcp(service, net_address.Endpoint.{address = peer, port = tcp_echo})
    echo_udp(service, net_address.Endpoint.{address = peer, port = udp_echo})
    if service_kit.word_after(text, "dns=") is_some {
        use_names(service, tcp_echo)
    }
    serve_echo(service)
    if tcp_sink != 0 {
        measure_send(service, net_address.Endpoint.{address = peer, port = tcp_sink})
    }
    return 0
}

/** The name the development machine's DNS peer answers with its addresses: fec0::2 and 10.0.2.2. */
PEER_NAME :: "peer.slopos.test"

/**
 * Resolve the peer's name, reach its echo by name through a connection allowing QEMU's ranges, and be refused it
 * through one allowing public addresses only; and resolve a name that doesn't exist.
 *
 * @param service The connection to the network service, which allows everything.
 * @param tcp_echo The echo peer's port.
 */
use_names :: fn(service: os.Channel[network.Network], tcp_echo: u16) {
    startup :: slop_os.startup_block()
    port :: os.port_for(startup.budget, service.end) or_return void
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    // QEMU's ranges, 10.0.2.0/24 and fec0::/64, by TCP
    site := net_address.Address.{family = .V6}
    site.bytes[0] = 0xfe
    site.bytes[1] = 0xc0
    ranges := network.Policy.{connect_count = 2}
    ranges.connect[0] = network.range_rule(net_address.v4(10, 0, 2, 0), 24, network.TRANSPORT_TCP, 0, 65535)
    ranges.connect[1] = network.range_rule(site, 64, network.TRANSPORT_TCP, 0, 65535)
    local :: network.narrow(service.end, port, &ranges) or_return void
    storage : u8[200]
    line := text_buffer.make(storage)
    match net.resolve(local, PEER_NAME) {
        case Ok(found) => {
            text_buffer.append_format(&line, "% resolves to", PEER_NAME)
            for i in 0..<found.count {
                if i < found.addresses.count {
                    text_buffer.append(&line, if i == 0 { " " } else { " and " })
                    append_address(&line, found.addresses[i])
                }
            }
            runtime.log_info("%", text_buffer.as_string(&line))
        }
        case Error(failure) => runtime.log_info("% wasn't resolved: %", PEER_NAME, failure)
    }
    match net.open_name(local, PEER_NAME, tcp_echo) {
        case Ok(found) => {
            tcp := found
            info :: net.describe(&tcp)
            message :: "hello by name"
            _ = net.write(&tcp, string_bytes(message))
            net.finish(&tcp)
            back : u8[64]
            got := cast[usize](0)
            loop {
                at :: got
                if at >= back.count {
                    break
                }
                count :: net.read(&tcp, back[at..<back.count]) or_else 0
                if count == 0 {
                    break
                }
                got = at + count
            }
            while true
            line = text_buffer.make(storage)
            text_buffer.append_format(&line, "% reached by name at ", PEER_NAME)
            match info {
                case Some(described) => append_address(&line, described.remote.address)
                case None => text_buffer.append(&line, "an unknown address")
            }
            text_buffer.append(&line, if got == string_bytes(message).count && string_of(&back[0], got) == message { ", its echo whole" } else { ", its echo wrong" })
            runtime.log_info("%", text_buffer.as_string(&line))
            net.close(&tcp)
        }
        case Error(failure) => runtime.log_info("% wasn't reached by name: %", PEER_NAME, failure)
    }
    public := network.public_only()
    outward :: network.narrow(service.end, port, &public) or_return void
    match net.open_name(outward, PEER_NAME, tcp_echo) {
        case Ok(found) => {
            tcp := found
            net.close(&tcp)
            runtime.log_info("% was reached through a public-only connection", PEER_NAME)
        }
        case Error(failure) => runtime.log_info("% refused through a public-only connection: %", PEER_NAME, failure)
    }
    match net.resolve(local, "missing.slopos.test") {
        case Ok(found) => runtime.log_info("missing.slopos.test resolved to % addresses", found.count)
        case Error(failure) => runtime.log_info("missing.slopos.test: %", failure)
    }
}

/**
 * Append an address: dotted decimal for IPv4, eight groups in hexadecimal for IPv6.
 *
 * @param line Where.
 * @param address The address.
 */
append_address :: fn(line: ptr[mut text_buffer.TextBuffer], address: net_address.Address) {
    b :: address.bytes
    if address.family == .V4 {
        text_buffer.append_format(line, "%.%.%.%", b[0], b[1], b[2], b[3])
        return void
    }
    for group in cast[usize](0)..<8 {
        if group > 0 {
            text_buffer.append(line, ":")
        }
        text_buffer.append_format(line, "%{x}", (cast[u32](b[group * 2]) << 8) | cast[u32](b[group * 2 + 1]))
    }
}

/**
 * Measure how long SINK_BYTES take to send to the TCP sink, from opening the connection to the sink's finishing once it
 * has them all.
 *
 * @param service The connection to the network service.
 * @param to The sink.
 */
measure_send :: fn(service: os.Channel[network.Network], to: net_address.Endpoint) {
    started :: slop_os.clock_monotonic() or_else 0
    tcp := match open_when_routed(service, to) {
        case Ok(found) => found
        case Error(failure) => {
            runtime.log_info("the TCP sink couldn't be reached: %", failure)
            return void
        }
    }
    chunk : u8[CHUNK]
    for &byte, i in chunk {
        byte^ = pattern(i)
    }
    sent := cast[usize](0)
    loop {
        if sent >= SINK_BYTES {
            break
        }
        written :: net.write(&tcp, view_of(&chunk[0], chunk.count))
        if written == 0 {
            break
        }
        sent += written
    }
    while true
    net.finish(&tcp)
    back : u8[16]
    _ = net.read(&tcp, view_of(&back[0], back.count))
    net.close(&tcp)
    elapsed :: (slop_os.clock_monotonic() or_else 0) - started
    if sent < SINK_BYTES {
        runtime.log_info("the TCP sink took % of % bytes", sent, SINK_BYTES)
        return void
    }
    runtime.log_info("perf: tcp_send_4mib %", elapsed)
    runtime.log_info("sent % MiB in % ms", SINK_BYTES >> 20, elapsed / 1_000_000)
}

/**
 * Give the pattern's byte at an offset.
 *
 * @param offset The offset.
 * @return The byte.
 */
pattern :: fn(offset: usize) -> u8 {
    return cast[u8]((offset * 131 + (offset >> 8)) & 0xff)
}

/**
 * Open a connection, trying again while there's no route, as the address is still being leased.
 *
 * @param service The connection to the network service.
 * @param to Who to.
 * @return The connection, or why not.
 */
open_when_routed :: fn(service: os.Channel[network.Network], to: net_address.Endpoint) -> Result[net.Tcp, net.Failure] {
    for try in 0..<OPEN_TRIES {
        match net.open(service, to) {
            case Ok(tcp) => return .Ok(tcp)
            case Error(failure) => {
                if failure != .NoRoute {
                    return .Error(failure)
                }
            }
        }
        wait(500_000_000)
    }
    return .Error(.NoRoute)
}

/**
 * Wait a while.
 *
 * @param nanoseconds How long.
 */
wait :: fn(nanoseconds: u64) {
    waiter :: slop_os.port_create(slop_os.startup_block().budget) or_return void
    packets : slop_os.Packet[1]
    _ = slop_os.port_wait(waiter, packets, (slop_os.clock_monotonic() or_else 0) + nanoseconds)
    _ = slop_os.handle_close(cast[slop_os.Handle](waiter))
}

/**
 * Write ECHO_BYTES of the pattern to the TCP echo peer, a chunk at a time, reading each chunk's echo back and checking
 * it, then finish and wait for the peer to.
 *
 * @param service The connection to the network service.
 * @param to The peer.
 */
echo_tcp :: fn(service: os.Channel[network.Network], to: net_address.Endpoint) {
    tcp := match open_when_routed(service, to) {
        case Ok(found) => found
        case Error(failure) => {
            runtime.log_info("the TCP echo peer couldn't be reached: %", failure)
            return void
        }
    }
    chunk : u8[CHUNK]
    back : u8[CHUNK]
    wrong := cast[usize](0)
    sent := cast[usize](0)
    received := cast[usize](0)
    loop {
        if sent >= ECHO_BYTES {
            break
        }
        for &byte, i in chunk {
            byte^ = pattern(sent + i)
        }
        written :: net.write(&tcp, view_of(&chunk[0], chunk.count))
        sent += written
        if written < chunk.count {
            break
        }
        // Its echo, all of it, before the next
        loop {
            if received >= sent {
                break
            }
            count :: match net.read(&tcp, view_of(&back[0], back.count)) {
                case Ok(found) => found
                case Error(failure) => 0
            }
            if count == 0 {
                break
            }
            for i in 0..<count {
                if i < back.count && back[i] != pattern(received + i) {
                    wrong += 1
                }
            }
            received += count
        }
        while true
    }
    while true
    net.finish(&tcp)
    // The peer finishes once it has everything
    finished := false
    loop {
        count :: match net.read(&tcp, view_of(&back[0], back.count)) {
            case Ok(found) => found
            case Error(failure) => {
                runtime.log_info("the TCP echo connection failed: %", failure)
                break
            }
        }
        if count == 0 {
            finished = true
            break
        }
        received += count
    }
    while true
    net.close(&tcp)
    if received == ECHO_BYTES && wrong == 0 && finished {
        runtime.log_info("TCP echo of % bytes from 10.0.2.2:% matched, and both finished", received, to.port)
    }
    else {
        runtime.log_info("TCP echo: % of % bytes back, % wrong, finished %", received, ECHO_BYTES, wrong, finished)
    }
}

/**
 * Send a datagram to the UDP echo peer, and check its echo.
 *
 * @param service The connection to the network service.
 * @param to The peer.
 */
echo_udp :: fn(service: os.Channel[network.Network], to: net_address.Endpoint) {
    socket := match net.udp(service) {
        case Ok(found) => found
        case Error(failure) => {
            runtime.log_info("no UDP socket: %", failure)
            return void
        }
    }
    message :: "a datagram from SlopOS"
    if !net.send_to(&socket, to, string_bytes(message)) {
        runtime.log_info("the datagram wasn't sent")
        net.close_udp(&socket)
        return void
    }
    back : u8[256]
    match net.receive_from(&socket, view_of(&back[0], back.count)) {
        case Some(got) => {
            if string_of(&back[0], got.count) == message {
                runtime.log_info("UDP echo from 10.0.2.2:% matched", got.from.port)
            }
            else {
                runtime.log_info("UDP echo didn't match")
            }
        }
        case None => runtime.log_info("no UDP echo")
    }
    net.close_udp(&socket)
}

/**
 * Listen on port 7, and echo back what the first connection sends, until it finishes.
 *
 * @param service The connection to the network service.
 */
serve_echo :: fn(service: os.Channel[network.Network]) {
    listener := match net.listen(service, 7) {
        case Ok(found) => found
        case Error(failure) => {
            runtime.log_info("couldn't listen on 7: %", failure)
            return void
        }
    }
    runtime.log_info("listening on 7")
    accepted := match net.accept(&listener) {
        case Ok(found) => found
        case Error(failure) => {
            runtime.log_info("nothing accepted: %", failure)
            net.close_listener(&listener)
            return void
        }
    }
    buffer : u8[CHUNK]
    echoed := cast[usize](0)
    loop {
        count :: match net.read(&accepted.tcp, view_of(&buffer[0], buffer.count)) {
            case Ok(found) => found
            case Error(failure) => 0
        }
        if count == 0 {
            break
        }
        echoed += net.write(&accepted.tcp, view_of(&buffer[0], count))
    }
    while true
    net.finish(&accepted.tcp)
    _ = net.flush(&accepted.tcp)
    net.close(&accepted.tcp)
    net.close_listener(&listener)
    address :: accepted.remote.address.bytes
    runtime.log_info("echoed % bytes back to %.%.%.%", echoed, address[0], address[1], address[2], address[3])
}
