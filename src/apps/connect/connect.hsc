/**
 * connect: open a TCP connection, send a message, and show what comes back until the other end finishes (decisions/0188,
 * 13c). It reaches the network through the session's connection, which allows public addresses; for an address it
 * doesn't allow, as a private one, it asks the powerbox for a connection to that address and port, which the user
 * allows, or doesn't, on the trusted path.
 *
 *     connect 93.184.215.14 7 "hello"
 */
package connect

import runtime from "base"
import net from "std"
import os from "std"
import text_buffer from "std"
import slop_os from "std/os"
import net_address from "std/os/slop_os"
import network from "std/os/slop_os"
import stream from "std/os/slop_os"
import powerbox_protocol from "../../protocols/powerbox"

/** The most bytes of what comes back that are shown: 4 KiB. */
MAX_SHOWN :: 4096
/** How many bytes a line shown has at most. */
LINE_BYTES :: 200

/** A line of what came back. */
Line :: struct {
    /** Its text, without its line break. */
    text : string,
}

/** A parameter that's wrong. */
Problem :: struct {
    parameter : os.ParameterName,
}

/** Why the connection failed. */
Failure :: enum {
    /** Nothing listens there. */
    Refused,
    /** Nothing answered. */
    TimedOut,
    /** The other end reset it. */
    Reset,
    /** There's no route there, or no network. */
    NoRoute,
    /** Something else went wrong. */
    Broken,
}

/** What went wrong. */
ConnectError :: union {
    /** The address isn't an IPv4 address in dotted decimal. */
    BadAddress(Problem),
    /** The session's network doesn't allow it, and the user didn't, or there was no powerbox to ask. */
    NotAllowed,
    /** It was allowed, but the connection failed. */
    Failed(Failure),
}

/**
 * Connect, send, and show what comes back.
 *
 * @param address The IPv4 address, in dotted decimal.
 * @param port The port.
 * @param message What's sent; the connection's finished after it.
 * @param network The session's network connection.
 * @param powerbox The session's powerbox, asked for a connection the session's doesn't allow; without it, that's
 *     NotAllowed.
 * @param output Where what comes back goes, a line at a time; without it, it's only counted.
 * @return How many bytes came back; or what went wrong.
 */
main :: fn(address: string, port: u16, message: string, network: os.Channel[network.Network],
    powerbox: os.Channel[powerbox_protocol.Powerbox]?, output: os.Sink[Line]?) -> Result[u64, ConnectError] {
    to :: net_address.Endpoint.{address = net_address.parse_v4(address) or_return .Error(.BadAddress(Problem.{
        parameter = os.ParameterName.{name = "address"}})), port = port}
    tcp := match net.open(network, to) {
        case Ok(opened) => opened
        case Error(failure) => {
            if failure != .NotAllowed {
                return .Error(.Failed(failure_of(failure)))
            }
            // More than the session's network allows: the user's to allow
            allowed :: ask(powerbox, to) or_return .Error(.NotAllowed)
            match net.open(allowed, to) {
                case Ok(opened) => opened
                case Error(again) => return .Error(if again == .NotAllowed { ConnectError.NotAllowed } else { ConnectError.Failed(failure_of(again)) })
            }
        }
    }
    _ = net.write(&tcp, string_bytes(message))
    net.finish(&tcp)
    writer : stream.Writer[Line]
    writing := false
    match output {
        case Some(sink) => match stream.writer_on(sink) {
            case Ok(made) => {
                writer = made
                writing = true
            }
            case Error(error) => {}
        }
        case None => {}
    }
    buffer : u8[1024]
    line_storage : u8[LINE_BYTES]
    line := text_buffer.make(line_storage)
    received := cast[u64](0)
    loop {
        count :: match net.read(&tcp, view_of(&buffer[0], buffer.count)) {
            case Ok(found) => found
            case Error(failure) => 0
        }
        if count == 0 {
            break
        }
        received += cast[u64](count)
        for i in 0..<count {
            if i >= buffer.count {
                break
            }
            byte :: buffer[i]
            if byte == cast[u8]('\n') {
                if writing {
                    _ = stream.write(&writer, Line.{text = text_buffer.as_string(&line)})
                }
                line = text_buffer.make(line_storage)
            }
            else if received <= MAX_SHOWN {
                text_buffer.append(&line, string_of(&buffer[i], 1))
            }
        }
    }
    while true
    if writing {
        if text_buffer.as_string(&line).count > 0 {
            _ = stream.write(&writer, Line.{text = text_buffer.as_string(&line)})
        }
        _ = stream.finish(&writer, 0)
    }
    net.close(&tcp)
    return .Ok(received)
}

/**
 * Ask the powerbox for a network connection to one endpoint by TCP, and wait for the user's answer.
 *
 * @param powerbox The session's powerbox, if there is one.
 * @param to The endpoint.
 * @return The connection the user allowed; null if they didn't, or there's no powerbox.
 */
ask :: fn(powerbox: os.Channel[powerbox_protocol.Powerbox]?, to: net_address.Endpoint) -> os.Channel[network.Network]? {
    box :: powerbox or_return null
    port :: os.port_for(slop_os.startup_block().budget, box.end) or_return null
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    rule :: network.range_rule(to.address, 32, network.TRANSPORT_TCP, to.port, to.port)
    out := os.Outgoing.{}
    request :: os.begin[powerbox_protocol.Request](&out)
    request^ = .RequestNetwork(powerbox_protocol.NetworkRequest.{purpose = os.append(&out, string_bytes("to send it a message")),
        connect = os.append(&out, network.Rule.[rule]), listen = os.append(&out, network.Rule.[])})
    if powerbox_protocol.send_request(box.end, port, &out) is_some {
        return null
    }
    into := os.Incoming.{}
    match powerbox_protocol.receive_response(box.end, port, &into, true) {
        case Received => {}
        case _ => return null
    }
    return match os.message_of[powerbox_protocol.Response](&into)^ {
        case NetworkGranted(given) => given
        case _ => null
    }
}

/**
 * Give the failure std/net's means.
 *
 * @param failure std/net's.
 * @return Its own.
 */
failure_of :: fn(failure: net.Failure) -> Failure {
    return match failure {
        case .Refused => .Refused
        case .TimedOut => .TimedOut
        case .Reset => .Reset
        case .NoRoute => .NoRoute
        case _ => .Broken
    }
}
