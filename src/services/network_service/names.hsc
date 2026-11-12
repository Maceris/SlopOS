package network_service

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import net_address from "std/os/slop_os"
import network from "std/os/slop_os"
import net_stack from "../../net_stack"
import service_kit from "../../libraries/service_kit"

/*
 * Names (decisions/0188, 13e): Resolve and OpenName, each held while the stack's resolver looks the name up, and
 * answered from its Resolved event. A name's addresses are checked against the asking connection's policy as a name's
 * are (network.allows_named): an address that isn't public is reached only through a range the policy names, so a
 * name answered with a local address reaches nothing else (DNS rebinding).
 *
 * OpenName connects as RFC 8305's Happy Eyeballs does: its stream is answered at once, its first address tried, and
 * while none has connected, the next started every ATTEMPT_DELAY, up to ATTEMPTS at once, each over the stream's own
 * rings, as no byte moves before a connection's established. The first to connect is the stream's, the others aborted;
 * one that fails starts the next address at once; once all have failed, the stream ends as the last did.
 */

/** The most Resolves and OpenNames held at once: the stack's lookups. */
PENDING :: net_stack.LOOKUPS
/** How long an attempt has before the next address is tried too: 250 ms (RFC 8305 §5's Connection Attempt Delay). */
ATTEMPT_DELAY : u64 : 250_000_000
/** The most attempts a connection by name has at once. */
ATTEMPTS :: 4

/** A Resolve or OpenName waiting for its lookup. */
Pending :: struct {
    active : bool,
    /** The stack's lookup. */
    lookup : u32,
    /** The client asking, by its index, and its end then, so an answer's dropped if the client's gone. */
    client : usize,
    end : slop_os.Channel,
    /** Whether it's an OpenName, with the port and memory. */
    opening : bool,
    port : u16,
    memory : slop_os.Memory,
    /** The name, its first name_length bytes. */
    name : u8[network.MAX_NAME],
    name_length : usize,
}

/** A connection by name racing its addresses. */
Race :: struct {
    /** Whether it's still racing: no attempt's connected yet. */
    racing : bool,
    /** The attempts running, by connection, 0 for a free place, and the address each is to. */
    attempts : u32[ATTEMPTS],
    attempt_to : net_address.Endpoint[ATTEMPTS],
    /** The addresses the policy allows, in the order they're tried, and the next not yet tried. */
    candidates : net_stack.IpAddress[network.MAX_ADDRESSES],
    candidate_count : usize,
    next_candidate : usize,
    /** When the next address is started if none's connected by then. */
    next_attempt : u64,
    port : u16,
}

/**
 * Start a lookup for a Resolve or an OpenName, or say why it can't be.
 *
 * @param service The service.
 * @param client The asking client's index.
 * @param end Its end.
 * @param name The name, as the message has it; copied.
 * @param v4 Whether IPv4 addresses are wanted.
 * @param v6 Whether IPv6 addresses are wanted.
 * @param opening Whether it's an OpenName, to port, with memory, the service's now.
 * @param port OpenName's port.
 * @param memory OpenName's memory; closed if it's refused here.
 * @return A refusal to answer at once; null once it's held, to be answered when the lookup's done.
 */
start_lookup :: fn(service: ptr[mut Service], client: usize, end: slop_os.Channel, name: u8[], v4: bool, v6: bool, opening: bool,
    port: u16, memory: slop_os.Memory) -> network.Refusal? {

    refusal := network.Refusal.NoRoom
    match service.stack {
        case Some(found) => {
            if name.count == 0 || name.count > network.MAX_NAME {
                refusal = .BadName
            }
            else if opening && port == 0 {
                refusal = .BadEndpoint
            }
            else {
                for &each in service.serving.pending {
                    if each.active {
                        continue
                    }
                    lookup :: net_stack.resolve(found, name, v4, v6) or_break
                    each^ = Pending.{active = true, lookup = lookup, client = client, end = end, opening = opening, port = port,
                        memory = memory, name_length = name.count}
                    for byte, i in name {
                        if i < each.name.count {
                            each.name[i] = byte
                        }
                    }
                    return null
                }
            }
        }
        case None => refusal = .NoRoute
    }
    if opening {
        _ = slop_os.handle_close(cast[slop_os.Handle](memory))
    }
    return refusal
}

/**
 * Drop what a client gone has held: its lookups cancelled, OpenName's memory closed.
 *
 * @param service The service.
 * @param client The client's index.
 */
drop_lookups :: fn(service: ptr[mut Service], client: usize) {
    for &each in service.serving.pending {
        if !each.active || each.client != client {
            continue
        }
        match service.stack {
            case Some(stack) => net_stack.cancel_resolve(stack, each.lookup)
            case None => {}
        }
        if each.opening {
            _ = slop_os.handle_close(cast[slop_os.Handle](each.memory))
        }
        each.active = false
    }
}

/**
 * Answer the Resolve or OpenName a lookup was for, now it's done.
 *
 * @param service The service.
 * @param stack The stack.
 * @param lookup The lookup.
 */
lookup_done :: fn(service: ptr[mut Service], stack: ptr[mut net_stack.Stack], lookup: u32) {
    result :: net_stack.take_resolution(stack, lookup) or_return void
    for &each in service.serving.pending {
        if !each.active || each.lookup != lookup {
            continue
        }
        each.active = false
        serving :: &service.serving
        client :: each.client
        present :: client < serving.clients.ends.count && client < serving.policies.count
            && cast[slop_os.Handle](serving.clients.ends[client]) == cast[slop_os.Handle](each.end)
        if !present || client >= serving.policies.count {
            if each.opening {
                _ = slop_os.handle_close(cast[slop_os.Handle](each.memory))
            }
            return void
        }
        refusal :: refusal_of(result.outcome)
        if each.opening {
            response :: match refusal {
                case Some(why) => {
                    _ = slop_os.handle_close(cast[slop_os.Handle](each.memory))
                    network.Response.Refused(why)
                }
                case None => open_by_name(service, stack, each, &result, &serving.policies[client])
            }
            answer_network(service, each.end, response)
            return void
        }
        out := os.Outgoing.{}
        made :: os.begin[network.Response](&out)
        match refusal {
            case Some(why) => made^ = .Refused(why)
            case None => {
                addresses : network.ResolvedAddress[network.MAX_ADDRESSES]
                count := cast[usize](0)
                for i in 0..<result.count {
                    if i < result.addresses.count && count < addresses.count {
                        address :: endpoint_of(result.addresses[i], 0).address
                        addresses[count] = network.ResolvedAddress.{family = cast[u8](address.family), bytes = address.bytes}
                        count += 1
                    }
                }
                made^ = .Resolved(os.append(&out, view_of(&addresses[0], count)))
            }
        }
        _ = network.send_response(each.end, service.port, &out)
        return void
    }
}

/**
 * Give the refusal a lookup's outcome means, if it means one.
 *
 * @param outcome The outcome.
 * @return Null for Found.
 */
refusal_of :: fn(outcome: net_stack.ResolveOutcome) -> network.Refusal? {
    return match outcome {
        case .Found => null
        case .NoSuchName => network.Refusal.NoSuchName
        case .NoAddress => network.Refusal.NoAddress
        case .Failed => network.Refusal.ResolveFailed
        case .BadName => network.Refusal.BadName
    }
}

/**
 * Open a connection by name to the addresses a lookup found that the policy allows, its first attempt started.
 *
 * @param service The service.
 * @param stack The stack.
 * @param pending The OpenName, whose memory is the stream's or closed.
 * @param result The lookup's addresses.
 * @param policy The asking connection's policy.
 * @return Opened with the stream's channel; or Refused NotAllowed if no address is allowed, or why it couldn't open.
 */
open_by_name :: fn(service: ptr[mut Service], stack: ptr[mut net_stack.Stack], pending: ptr[Pending], result: ptr[net_stack.Resolution],
    policy: ptr[network.Policy]) -> network.Response {

    race := Race.{racing = true, port = pending.port}
    name :: view_of(&pending.name[0], pending.name_length)
    for i in 0..<result.count {
        if i < result.addresses.count && race.candidate_count < race.candidates.count
            && network.allows_named(policy, network.TRANSPORT_TCP, name, endpoint_of(result.addresses[i], pending.port)) {
            race.candidates[race.candidate_count] = result.addresses[i]
            race.candidate_count += 1
        }
    }
    if race.candidate_count == 0 {
        _ = slop_os.handle_close(cast[slop_os.Handle](pending.memory))
        return .Refused(.NotAllowed)
    }
    index :: match free_stream(service) {
        case Some(found) => found
        case None => {
            _ = slop_os.handle_close(cast[slop_os.Handle](pending.memory))
            return .Refused(.NoRoom)
        }
    }
    if index >= service.serving.streams.count {
        _ = slop_os.handle_close(cast[slop_os.Handle](pending.memory))
        return .Refused(.NoRoom)
    }
    bytes :: take_memory(pending.memory) or_return .Refused(.BadMemory)
    stream :: &service.serving.streams[index]
    stream.bytes = bytes
    stream.memory = pending.memory
    stream.race = race
    // The first address that has a route
    if !start_attempt(service, stack, index) {
        release_memory(pending.memory)
        stream.memory = cast[slop_os.Memory](slop_os.NO_HANDLE)
        stream.race = Race.{}
        return .Refused(.NoRoute)
    }
    channel :: match make_stream_channel(service, index) {
        case Some(found) => found
        case None => {
            abort_attempts(stack, &stream.race)
            stream.race = Race.{}
            release_memory(pending.memory)
            stream.memory = cast[slop_os.Memory](slop_os.NO_HANDLE)
            return .Refused(.NoRoom)
        }
    }
    stream.memory = pending.memory
    stream.watching = false
    stream.ended = false
    stream.ending = .None
    pump(service, stack)
    return .Opened(channel)
}

/**
 * Start an attempt to the next address not yet tried that has a route, in a free place.
 *
 * @param service The service.
 * @param stack The stack.
 * @param index The stream's index.
 * @return True if one started; false if none's left with a route, or there's no free place.
 */
start_attempt :: fn(service: ptr[mut Service], stack: ptr[mut net_stack.Stack], index: usize) -> bool {
    if index >= service.serving.streams.count {
        return false
    }
    stream :: &service.serving.streams[index]
    race :: &stream.race
    place := cast[usize](ATTEMPTS)
    for attempt, i in race.attempts {
        if attempt == 0 {
            place = i
            break
        }
    }
    if place >= race.attempts.count || place >= race.attempt_to.count {
        return false
    }
    loop {
        if race.next_candidate >= race.candidate_count || race.next_candidate >= race.candidates.count {
            return false
        }
        to :: race.candidates[race.next_candidate]
        race.next_candidate += 1
        match net_stack.tcp_connect(stack, to, race.port, rings_of(stream.memory, stream.bytes)) {
            case Some(connection) => {
                race.attempts[place] = connection
                race.attempt_to[place] = endpoint_of(to, race.port)
                race.next_attempt = now() + ATTEMPT_DELAY
                // The stream's connection, while it races, is its first attempt still running
                stream.connection = connection
                stream.remote = race.attempt_to[place]
                return true
            }
            case None => {}
        }
    }
}

/** Abort every attempt of a race. */
abort_attempts :: fn(stack: ptr[mut net_stack.Stack], race: ptr[mut Race]) {
    for &attempt in race.attempts {
        if attempt^ != 0 {
            net_stack.tcp_abort(stack, attempt^)
            attempt^ = 0
        }
    }
}

/**
 * Tell whether a connection is one of a racing stream's attempts.
 *
 * @param stream The stream.
 * @param connection The connection.
 * @return True if it is.
 */
is_attempt :: fn(stream: ptr[Stream], connection: u32) -> bool {
    if !stream.race.racing || connection == 0 {
        return false
    }
    for attempt in stream.race.attempts {
        if attempt == connection {
            return true
        }
    }
    return false
}

/**
 * See whether an attempt of a racing stream has connected: the first to is the stream's, and the others are aborted.
 *
 * @param service The service.
 * @param stack The stack.
 * @param index The stream's index.
 * @param connection The attempt that changed.
 */
attempt_changed :: fn(service: ptr[mut Service], stack: ptr[mut net_stack.Stack], index: usize, connection: u32) {
    if index >= service.serving.streams.count {
        return void
    }
    stream :: &service.serving.streams[index]
    status :: net_stack.tcp_status(stack, connection)
    if status.state == .SynSent || status.state == .Incoming || status.state == .SynReceived || status.state == .Free {
        return void
    }
    race :: &stream.race
    for &attempt, i in race.attempts {
        if attempt^ == connection {
            if i < race.attempt_to.count {
                stream.remote = race.attempt_to[i]
            }
            attempt^ = 0
        }
    }
    abort_attempts(stack, race)
    race.racing = false
    stream.connection = connection
}

/**
 * Take an attempt's end: the next address started at once, or, if there's none and no attempt's left, the stream ended
 * as the attempt did.
 *
 * @param service The service.
 * @param stack The stack.
 * @param index The stream's index.
 * @param ended The attempt's end.
 * @return True if the stream ended with it, for connection_ended to finish; false if it races on.
 */
attempt_ended :: fn(service: ptr[mut Service], stack: ptr[mut net_stack.Stack], index: usize, ended: net_stack.TcpEnded) -> bool {
    if index >= service.serving.streams.count {
        return true
    }
    stream :: &service.serving.streams[index]
    race :: &stream.race
    running := false
    for &attempt in race.attempts {
        if attempt^ == ended.connection {
            attempt^ = 0
        }
        running = running || attempt^ != 0
    }
    if start_attempt(service, stack, index) {
        return false
    }
    if running {
        // Still racing: the stream's connection is one still running
        for attempt in race.attempts {
            if attempt != 0 {
                stream.connection = attempt
                break
            }
        }
        return false
    }
    race.racing = false
    stream.connection = ended.connection
    return true
}

/**
 * Start the next address of each racing stream whose last attempt's had ATTEMPT_DELAY without connecting.
 *
 * @param service The service.
 * @param stack The stack.
 */
race_on :: fn(service: ptr[mut Service], stack: ptr[mut net_stack.Stack]) {
    time :: now()
    for i in cast[usize](0)..<STREAMS {
        if i >= service.serving.streams.count {
            break
        }
        stream :: &service.serving.streams[i]
        if cast[slop_os.Handle](stream.end) == slop_os.NO_HANDLE || !stream.race.racing || time < stream.race.next_attempt {
            continue
        }
        if !start_attempt(service, stack, i) {
            // Nothing more to start: no next time
            stream.race.next_attempt = ~cast[u64](0)
        }
    }
}

/**
 * Give when the next racing stream's next address is due.
 *
 * @param service The service.
 * @return The soonest; 0xffffffffffffffff for none.
 */
race_deadline :: fn(service: ptr[Service]) -> u64 {
    soonest := ~cast[u64](0)
    for stream in service.serving.streams {
        if cast[slop_os.Handle](stream.end) != slop_os.NO_HANDLE && stream.race.racing
            && stream.race.next_candidate < stream.race.candidate_count && stream.race.next_attempt < soonest {
            soonest = stream.race.next_attempt
        }
    }
    return soonest
}

/**
 * Set the resolver's server from the command line's dns=<address>:<port>, if it has one: an IPv4 address, and the port,
 * 53 if it's left out.
 *
 * @param stack The stack.
 * @param text The command line.
 */
configure_dns :: fn(stack: ptr[mut net_stack.Stack], text: string) {
    value :: service_kit.word_after(text, "dns=") or_return void
    bytes :: string_bytes(value)
    colon := bytes.count
    for byte, i in bytes {
        if byte == 58 {
            colon = i
            break
        }
    }
    if colon > value.count {
        return void
    }
    address :: net_address.parse_v4(value[0..<colon]) or_return void
    port :: if colon + 1 < value.count { cast[u16](service_kit.number_of(value[colon + 1..<value.count]) or_else 53) }
        else { cast[u16](53) }
    stack_address :: net_stack.IpAddress.V4(net_stack.Ipv4.{bytes = u8.[address.bytes[0], address.bytes[1], address.bytes[2], address.bytes[3]]})
    if net_stack.set_dns_server(stack, stack_address, port) {
        runtime.log_info("the DNS server is %.%.%.%, port %", address.bytes[0], address.bytes[1], address.bytes[2], address.bytes[3], port)
    }
}
