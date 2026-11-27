package libc

/*
 * Sockets (decisions/0202, 21h): sys/socket.h's, over the network service through std's net (TCP) and the datagrams
 * protocol (UDP), on the connection to the network service the program was given (Start.network; a C program run
 * from the shell asks for one with a network parameter of its entry, as native programs do). A socket is a file
 * descriptor, in the table files are, so read, write and close take it too.
 *
 * Every socket's channel is bound to one port of the libc's own, under its descriptor's number: whatever waits, a
 * blocking call or poll, waits on that port and then looks again at what it waits for, so poll can wait on many
 * sockets at once. AF_INET and AF_INET6, SOCK_STREAM and SOCK_DGRAM. A TCP socket connects, or listens once bound to
 * a port; connect always waits for the handshake, O_NONBLOCK or not. Closing a TCP connection finishes it and waits
 * up to CLOSE_WAIT for what was written to be acknowledged, so its bytes aren't lost to the reset closing its channel
 * would otherwise be. A UDP socket's made with the service on its first bind, connect or sendto, an unbound one on a
 * port the service picks. What a socket is bound to is the service's: an address given to bind is taken but not
 * kept, as the service listens on its interfaces' addresses.
 */

import runtime from "base:runtime"
import net from "std:net"
import os from "std:os"
import slop_os from "std:os/slop_os"
import datagrams from "std:os/slop_os/datagrams"
import net_address from "std:os/slop_os/net_address"
import network from "std:os/slop_os/network"
import tcp_stream from "std:os/slop_os/tcp_stream"

/*
 * The constants of sys/socket.h, netinet/in.h, poll.h and netdb.h this reads, with Linux's values, as the headers
 * have them.
 */
AF_UNSPEC : i32 : 0
AF_INET : i32 : 2
AF_INET6 : i32 : 10
SOCK_STREAM : i32 : 1
SOCK_DGRAM : i32 : 2
/** socket's type may have these with it: close on exec, kept; and non-blocking. */
SOCK_NONBLOCK : i32 : 0o4000
SOCK_CLOEXEC : i32 : 0o2000000
IPPROTO_TCP : i32 : 6
IPPROTO_UDP : i32 : 17
SOL_SOCKET : i32 : 1
SO_REUSEADDR : i32 : 2
SO_TYPE : i32 : 3
SO_ERROR : i32 : 4
SO_BROADCAST : i32 : 6
SO_SNDBUF : i32 : 7
SO_RCVBUF : i32 : 8
SO_KEEPALIVE : i32 : 9
SO_RCVTIMEO : i32 : 20
SO_SNDTIMEO : i32 : 21
TCP_NODELAY : i32 : 1
SHUT_RD : i32 : 0
SHUT_WR : i32 : 1
SHUT_RDWR : i32 : 2
MSG_PEEK : i32 : 2
MSG_WAITALL : i32 : 0x100
MSG_DONTWAIT : i32 : 0x40
POLLIN : i16 : 1
POLLOUT : i16 : 4
POLLERR : i16 : 8
POLLHUP : i16 : 16
POLLNVAL : i16 : 32
O_NONBLOCK : i32 : 0o4000
/** netdb.h's getaddrinfo errors that the resolver's failures are. */
EAI_NONAME : i32 : -2
EAI_AGAIN : i32 : -3
EAI_FAIL : i32 : -4
EAI_FAMILY : i32 : -6

/*
 * The errors sockets add, with Linux's numbers, as include/errno.h has them.
 */
E_AGAIN : i32 : 11
E_PIPE : i32 : 32
E_NOTSOCK : i32 : 88
E_DESTADDRREQ : i32 : 89
E_MSGSIZE : i32 : 90
E_PROTOTYPE : i32 : 91
E_NOPROTOOPT : i32 : 92
E_PROTONOSUPPORT : i32 : 93
E_OPNOTSUPP : i32 : 95
E_AFNOSUPPORT : i32 : 97
E_ADDRINUSE : i32 : 98
E_NETUNREACH : i32 : 101
E_CONNABORTED : i32 : 103
E_CONNRESET : i32 : 104
E_NOBUFS : i32 : 105
E_ISCONN : i32 : 106
E_NOTCONN : i32 : 107
E_TIMEDOUT : i32 : 110
E_CONNREFUSED : i32 : 111
E_HOSTUNREACH : i32 : 113

/** How long close waits for a TCP connection's bytes to be acknowledged: 5 s, in nanoseconds. */
CLOSE_WAIT : u64 : 5_000_000_000

/** The bytes of a sockaddr_in and a sockaddr_in6, as netinet/in.h lays them out. */
SOCKADDR_IN_BYTES : u32 : 16
SOCKADDR_IN6_BYTES : u32 : 28

/** What a socket is so far. */
SocketState :: enum {
    /** Made, maybe bound, not yet connected or listening; a UDP socket not yet made with the service. */
    Fresh,
    /** A TCP socket listening on its bound port. */
    Listening,
    /** A TCP socket connected, by connect or accept. */
    Connected,
    /** A UDP socket made with the service. */
    Datagram,
}

/** A socket: a Socket descriptor's, on the heap, freed by its close. */
Socket :: struct {
    /** AF_INET or AF_INET6. */
    family : i32,
    /** SOCK_STREAM or SOCK_DGRAM. */
    kind : i32,
    state : SocketState,
    /** The port bind gave it, 0 for none: a listener's, or a UDP socket's to be. */
    bound_port : u16,
    /** The connection, when Connected; the caller's, closed by close. */
    tcp : net.Tcp,
    /** The listener, when Listening. */
    listener : net.Listener,
    /** An accept asked of the listener, and whether it's come (from came_from); its memory's this socket's. */
    accepting : net.Tcp,
    asked_accept : bool,
    came : bool,
    came_from : net_address.Endpoint,
    /** The UDP socket, when Datagram. */
    udp : net.Udp,
    /** Whether a Receive is with the service, unanswered. */
    asked_receive : bool,
    /** A datagram taken from the service and not yet read: who from, and its bytes. */
    stash : u8[datagrams.MAX_DATAGRAM],
    stash_count : usize,
    stash_from : net_address.Endpoint,
    has_stash : bool,
    /** Where a connected UDP socket sends, and the only peer it takes datagrams from. */
    peer : net_address.Endpoint,
    has_peer : bool,
    /** shutdown's: no more is read, or written. */
    read_shut : bool,
    write_shut : bool,
    /** The options setsockopt keeps, which change nothing but what getsockopt gives. */
    reuse_address : i32,
    keep_alive : i32,
    no_delay : i32,
    broadcast : i32,
    /** SO_RCVTIMEO and SO_SNDTIMEO: how long a receive or a send waits, in nanoseconds; 0 for for ever. */
    receive_wait : u64,
    send_wait : u64,
    /** SO_ERROR's: the last connect's failure, taken by reading it. */
    pending_error : i32,
}

/** poll.h's struct pollfd. */
PollFd :: struct {
    fd : i32,
    events : i16,
    revents : i16,
}

#assert size_of(PollFd) == 8

/** C's struct timeval, for SO_RCVTIMEO and SO_SNDTIMEO. */
TimeVal :: struct {
    seconds : i64,
    microseconds : i64,
}

/**
 * Find a socket descriptor's socket.
 *
 * @param state The libc's state.
 * @param fd The descriptor.
 * @param errno_out Set to EBADF for one that isn't open, ENOTSOCK for one that isn't a socket.
 * @return The socket; null, with errno_out set, otherwise.
 */
socket_of :: fn(state : ptr[mut State], fd : i32, errno_out : ptr[mut i32]) -> ptr[mut Socket]? {
    errno_out^ = E_BADF
    found :: descriptor_of(state, fd) or_return null
    errno_out^ = E_NOTSOCK
    if found.kind != .Socket {
        return null
    }
    return found.socket
}

/**
 * Find the libc's port every socket's channel is bound to, making it the first time.
 *
 * @param state The libc's state, which keeps it until run ends.
 * @return The port; null without the memory for it.
 */
socket_port_of :: fn(state : ptr[mut State]) -> slop_os.Port? {
    if state.has_socket_port {
        return state.socket_port
    }
    made :: slop_os.port_create(slop_os.startup_block().budget) or_return null
    state.socket_port = made
    state.has_socket_port = true
    return made
}

/**
 * Wait on the sockets' port until something's raised there, or the deadline.
 *
 * @param state The libc's state, whose port has been made.
 * @param deadline In the monotonic clock's nanoseconds; slop_os.NO_DEADLINE for never.
 * @return True if something was raised; false at the deadline, or if the port can't be waited on.
 */
wait_sockets :: fn(state : ptr[mut State], deadline : u64) -> bool {
    if !state.has_socket_port {
        return false
    }
    packets : slop_os.Packet[8]
    waited :: slop_os.port_wait(state.socket_port, packets[0..<8], deadline) or_else 0
    return waited > 0
}

/**
 * Bind a channel to the sockets' port, under a descriptor's number, so its messages raise the port.
 *
 * @param state The libc's state.
 * @param end The channel.
 * @param fd The descriptor, the key its packets come under.
 * @return True once it's bound.
 */
bind_to_port :: fn(state : ptr[mut State], end : slop_os.Channel, fd : i32) -> bool {
    port :: socket_port_of(state) or_return false
    signals :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    return slop_os.port_bind(port, cast[u64](fd), cast[slop_os.Handle](end), signals, .Persistent) is_ok
}

/**
 * Work out when a wait of so long from now ends.
 *
 * @param wait How long, in nanoseconds; 0 for for ever.
 * @return The deadline, in the monotonic clock's nanoseconds; slop_os.NO_DEADLINE for for ever.
 */
deadline_after :: fn(wait : u64) -> u64 {
    if wait == 0 {
        return slop_os.NO_DEADLINE
    }
    return (slop_os.clock_monotonic() or_else 0) + wait
}

/**
 * Give the errno a std net failure is.
 *
 * @param failure The failure.
 * @return The errno.
 */
errno_of_failure :: fn(failure : net.Failure) -> i32 {
    return match failure {
        case .NotAllowed => E_ACCES
        case .PortTaken => E_ADDRINUSE
        case .NoRoute => E_NETUNREACH
        case .NoRoom => E_NOBUFS
        case .BadEndpoint => E_INVAL
        case .Refused => E_CONNREFUSED
        case .TimedOut => E_TIMEDOUT
        case .Reset => E_CONNRESET
        case .Broken => E_CONNABORTED
        case _ => E_HOSTUNREACH
    }
}

/**
 * Give the errno a connection's ending is.
 *
 * @param ending How it ended, not None.
 * @return The errno; 0 for one that closed as it should.
 */
errno_of_ending :: fn(ending : tcp_stream.Ending) -> i32 {
    return match ending {
        case .Reset => E_CONNRESET
        case .Refused => E_CONNREFUSED
        case .TimedOut => E_TIMEDOUT
        case .Aborted => E_CONNABORTED
        case _ => 0
    }
}

/**
 * Read a C socket address: a sockaddr_in or a sockaddr_in6, its port and address in network order.
 *
 * @param address The address, length bytes.
 * @param length Its bytes: at least a sockaddr_in's, or a sockaddr_in6's for AF_INET6.
 * @param family The socket's family, which the address has to be.
 * @return The endpoint; Error with EINVAL for one too short or null, EAFNOSUPPORT for another family.
 */
endpoint_of :: fn(address : ptr[u8]?, length : u32, family : i32) -> Result[net_address.Endpoint, i32] {
    given :: address or_return .Error(E_INVAL)
    if length < SOCKADDR_IN_BYTES {
        return .Error(E_INVAL)
    }
    given_bytes :: view_of(given, cast[usize](length))
    bytes : u8[28]
    for &byte, i in bytes {
        if i < given_bytes.count {
            byte^ = given_bytes[i]
        }
    }
    their_family :: cast[i32](bytes[0]) | (cast[i32](bytes[1]) << 8)
    if their_family != family {
        return .Error(E_AFNOSUPPORT)
    }
    endpoint := net_address.Endpoint.{port = (cast[u16](bytes[2]) << 8) | cast[u16](bytes[3])}
    if family == AF_INET {
        endpoint.address.family = .V4
        endpoint.address.bytes[0] = bytes[4]
        endpoint.address.bytes[1] = bytes[5]
        endpoint.address.bytes[2] = bytes[6]
        endpoint.address.bytes[3] = bytes[7]
        return .Ok(endpoint)
    }
    if length < SOCKADDR_IN6_BYTES {
        return .Error(E_INVAL)
    }
    endpoint.address.family = .V6
    for &byte, i in endpoint.address.bytes {
        place :: 8 + i
        if place < bytes.count {
            byte^ = bytes[place]
        }
    }
    return .Ok(endpoint)
}

/**
 * Write a C socket address, as accept, recvfrom, getsockname and getpeername give one.
 *
 * @param into Where it goes, at most length^ bytes of it; null for nowhere.
 * @param length In: the room at into. Out: the address's whole size, which may be more than was written, as POSIX
 *     has it; null for nowhere.
 * @param endpoint The endpoint: a V6 one's a sockaddr_in6, any other a sockaddr_in.
 */
give_endpoint :: fn(into : ptr[mut u8]?, length : ptr[mut u32]?, endpoint : net_address.Endpoint) {
    room := match length {
        case Some(given) => given^
        case None => cast[u32](0)
    }
    six :: endpoint.address.family == .V6
    whole :: if six { SOCKADDR_IN6_BYTES } else { SOCKADDR_IN_BYTES }
    made : u8[28]
    family :: if six { AF_INET6 } else { AF_INET }
    made[0] = cast[u8](family & 0xff)
    made[1] = cast[u8]((family >> 8) & 0xff)
    made[2] = cast[u8](endpoint.port >> 8)
    made[3] = cast[u8](endpoint.port & 0xff)
    for byte, i in endpoint.address.bytes {
        place :: if six { 8 + i } else { 4 + i }
        if (six || i < 4) && place < made.count {
            made[place] = byte
        }
    }
    match into {
        case Some(place) => {
            count :: if room < whole { room } else { whole }
            out :: view_of(place, cast[usize](count))
            for &byte, i in out {
                if i < made.count {
                    byte^ = made[i]
                }
            }
        }
        case None => {}
    }
    match length {
        case Some(given) => given^ = whole
        case None => {}
    }
}

/**
 * Add a descriptor, at the lowest number free.
 *
 * @param state The libc's state.
 * @param made The descriptor: its socket, if it has one, on the heap.
 * @return Its number; -1 with errno EMFILE when MOST_DESCRIPTORS are open.
 */
add_descriptor :: fn(state : ptr[mut State], made #escaping : Descriptor) -> i32 {
    for &descriptor, i in state.descriptors {
        if descriptor.kind == .Closed {
            descriptor^ = made
            return cast[i32](i)
        }
    }
    if state.descriptors.count >= MOST_DESCRIPTORS {
        return failed(E_MFILE)
    }
    runtime.array_add(&state.descriptors, made)
    return cast[i32](state.descriptors.count - 1)
}

/**
 * Make a socket, as C's socket.
 *
 * @param domain AF_INET or AF_INET6.
 * @param kind SOCK_STREAM or SOCK_DGRAM, with SOCK_NONBLOCK or SOCK_CLOEXEC if wanted.
 * @param protocol 0, or the kind's own: IPPROTO_TCP for a stream, IPPROTO_UDP for datagrams.
 * @return The lowest free descriptor; -1 with errno EAFNOSUPPORT for another domain, EPROTONOSUPPORT for another
 *     kind or protocol, EMFILE when 64 are open.
 */
socket #export #calling_convention(.c) :: fn(domain : i32, kind : i32, protocol : i32) -> i32 {
    state :: state_of() or_return failed(E_NOSYS)
    if domain != AF_INET && domain != AF_INET6 {
        return failed(E_AFNOSUPPORT)
    }
    base :: kind & ~(SOCK_NONBLOCK | SOCK_CLOEXEC)
    if base != SOCK_STREAM && base != SOCK_DGRAM {
        return failed(E_PROTONOSUPPORT)
    }
    if protocol != 0 && protocol != (if base == SOCK_STREAM { IPPROTO_TCP } else { IPPROTO_UDP }) {
        return failed(E_PROTONOSUPPORT)
    }
    made :: runtime.new(Socket)
    made.family = domain
    made.kind = base
    fd :: add_descriptor(
        state,
        Descriptor.{
            kind = .Socket,
            socket = made,
            readable = true,
            writable = true,
            nonblocking = (kind & SOCK_NONBLOCK) != 0,
            close_on_exec = (kind & SOCK_CLOEXEC) != 0,
        }
    )
    if fd < 0 {
        runtime.free(made)
    }
    return fd
}

/**
 * Make a UDP socket with the service, on its bound port or one the service picks, its channel bound to the sockets'
 * port.
 *
 * @param state The libc's state.
 * @param socket The socket, a Fresh SOCK_DGRAM one.
 * @param fd Its descriptor.
 * @return 0 once it's made; an errno otherwise: ENETUNREACH without a connection to the network service.
 */
make_udp :: fn(state : ptr[mut State], socket : ptr[mut Socket], fd : i32) -> i32 {
    if socket.state == .Datagram {
        return 0
    }
    if !state.has_network {
        return E_NETUNREACH
    }
    made :: match net.udp(state.network, socket.bound_port) {
        case Ok(found) => found
        case Error(failure) => return errno_of_failure(failure)
    }
    socket.udp = made
    if !bind_to_port(state, made.channel.end, fd) {
        net.close_udp(&socket.udp)
        return E_NOBUFS
    }
    socket.state = .Datagram
    return 0
}

/**
 * Bind a socket to a port, as C's bind.
 *
 * @param fd The socket, not yet listening, connected or made with the service.
 * @param address Its sockaddr_in or sockaddr_in6: its port is kept, 0 for one the service picks, which a TCP socket
 *     can't listen on; its address is taken but not kept, as the service listens on its interfaces'.
 * @param length The address's bytes.
 * @return 0; -1 with errno EBADF, ENOTSOCK, EINVAL for a bad address or a socket bound already, EAFNOSUPPORT for an
 *     address of another family, or for UDP what making the socket with the service failed with (EADDRINUSE).
 */
bind #export #calling_convention(.c) :: fn(fd : i32, address : ptr[u8]?, length : u32) -> i32 {
    state :: state_of() or_return failed(E_BADF)
    why := cast[i32](0)
    socket :: socket_of(state, fd, &why) or_return failed(why)
    if socket.state != .Fresh || socket.bound_port != 0 {
        return failed(E_INVAL)
    }
    endpoint :: match endpoint_of(address, length, socket.family) {
        case Ok(found) => found
        case Error(error) => return failed(error)
    }
    socket.bound_port = endpoint.port
    if socket.kind == SOCK_DGRAM {
        made :: make_udp(state, socket, fd)
        if made != 0 {
            socket.bound_port = 0
            return failed(made)
        }
    }
    return 0
}

/**
 * Listen on a TCP socket's bound port, as C's listen.
 *
 * @param fd The socket, SOCK_STREAM, bound to a port.
 * @param backlog Taken and not used: the service holds what's come until it's accepted.
 * @return 0; -1 with errno EBADF, ENOTSOCK, EOPNOTSUPP for a datagram socket, EINVAL for one connected or not bound
 *     to a port, ENETUNREACH without a network, or the service's refusal (EADDRINUSE, EACCES).
 */
listen #export #calling_convention(.c) :: fn(fd : i32, backlog : i32) -> i32 {
    state :: state_of() or_return failed(E_BADF)
    why := cast[i32](0)
    socket :: socket_of(state, fd, &why) or_return failed(why)
    if socket.kind != SOCK_STREAM {
        return failed(E_OPNOTSUPP)
    }
    if socket.state == .Listening {
        return 0
    }
    if socket.state != .Fresh || socket.bound_port == 0 {
        return failed(E_INVAL)
    }
    if !state.has_network {
        return failed(E_NETUNREACH)
    }
    match net.listen(state.network, socket.bound_port) {
        case Ok(made) => socket.listener = made
        case Error(failure) => return failed(errno_of_failure(failure))
    }
    port :: socket_port_of(state) or_return failed(E_NOBUFS)
    if !net.listener_on(&socket.listener, port, cast[u64](fd)) {
        net.close_listener(&socket.listener)
        return failed(E_NOBUFS)
    }
    socket.state = .Listening
    /*
     * Its first connection asked for at once, as a backlog of one, so a client's handshake finishes before accept is
     * called, as a program connecting to its own listener needs; a failure here is accept's to report
     */
    _ = check_accept(socket)
    return 0
}

/**
 * See whether a listener's next connection has come, asking for it if it hasn't been asked.
 *
 * @param socket The socket, Listening.
 * @return 0 if it's come (came), or not yet; an errno if the listener failed.
 */
check_accept :: fn(socket : ptr[mut Socket]) -> i32 {
    if socket.came {
        return 0
    }
    if !socket.asked_accept {
        match net.ask_accept(&socket.listener) {
            case Ok(pending) => socket.accepting = pending
            case Error(failure) => return errno_of_failure(failure)
        }
        socket.asked_accept = true
    }
    match net.take_accepted(&socket.listener, &socket.accepting) {
        case Waiting => return 0
        case Came(from) => {
            socket.came = true
            socket.came_from = from
            return 0
        }
        case Failed(failure) => {
            socket.asked_accept = false
            return errno_of_failure(failure)
        }
    }
}

/**
 * Take a listener's next connection, waiting for one unless the socket's non-blocking, as C's accept.
 *
 * @param fd The socket, listening.
 * @param address Where who it's from goes, as give_endpoint says; null for nowhere.
 * @param length The room at address, and then its size; null with a null address.
 * @return The connection's descriptor, the lowest free, blocking and its own; -1 with errno EBADF, ENOTSOCK, EINVAL
 *     for a socket not listening, EAGAIN for a non-blocking one with none come, EMFILE, or the listener's failure.
 */
accept #export #calling_convention(.c) :: fn(fd : i32, address : ptr[mut u8]?, length : ptr[mut u32]?) -> i32 {
    state :: state_of() or_return failed(E_BADF)
    why := cast[i32](0)
    socket :: socket_of(state, fd, &why) or_return failed(why)
    if socket.state != .Listening {
        return failed(E_INVAL)
    }
    nonblocking :: (descriptor_of(state, fd) or_return failed(E_BADF)).nonblocking
    loop {
        checked :: check_accept(socket)
        if checked != 0 {
            return failed(checked)
        }
        if socket.came {
            break
        }
        if nonblocking {
            return failed(E_AGAIN)
        }
        _ = wait_sockets(state, slop_os.NO_DEADLINE)
    }
    // The port first, so a failure past here has a descriptor to give back and a connection to close, nothing else
    port :: socket_port_of(state) or_return failed(E_NOBUFS)
    made :: runtime.new(Socket)
    made.family = socket.family
    made.kind = SOCK_STREAM
    made.state = .Connected
    made.tcp = socket.accepting
    socket.came = false
    socket.asked_accept = false
    accepted :: add_descriptor(state, Descriptor.{kind = .Socket, socket = made, readable = true, writable = true})
    if accepted < 0 {
        net.close(&made.tcp)
        runtime.free(made)
        return -1
    }
    // Never served, so there's nothing written to wait on, as close_socket would: closed at once, its place freed
    if !net.serve_on(&made.tcp, port, cast[u64](accepted)) {
        net.close(&made.tcp)
        runtime.free(made)
        match descriptor_of(state, accepted) {
            case Some(descriptor) => descriptor^ = Descriptor.{}
            case None => {}
        }
        return failed(E_CONNABORTED)
    }
    give_endpoint(address, length, socket.came_from)
    // The next one asked for, so the listener's backlog of one stays
    _ = check_accept(socket)
    return accepted
}

/**
 * Connect a socket, as C's connect: a TCP one opens a connection, waiting for its handshake, whether non-blocking or
 * not; a UDP one sets where send sends, and the only peer it takes datagrams from.
 *
 * @param fd The socket.
 * @param address Who to, a sockaddr_in or sockaddr_in6 of the socket's family.
 * @param length The address's bytes.
 * @return 0; -1 with errno EBADF, ENOTSOCK, EINVAL or EAFNOSUPPORT for a bad address, EISCONN for a TCP socket
 *     connected already, EOPNOTSUPP for a listening one, ENETUNREACH without a network, or the connection's failure
 *     (ECONNREFUSED, ETIMEDOUT, EACCES for one the network's policy doesn't allow), which SO_ERROR gives too.
 */
connect #export #calling_convention(.c) :: fn(fd : i32, address : ptr[u8]?, length : u32) -> i32 {
    state :: state_of() or_return failed(E_BADF)
    why := cast[i32](0)
    socket :: socket_of(state, fd, &why) or_return failed(why)
    to :: match endpoint_of(address, length, socket.family) {
        case Ok(found) => found
        case Error(error) => return failed(error)
    }
    if socket.kind == SOCK_DGRAM {
        made :: make_udp(state, socket, fd)
        if made != 0 {
            return failed(made)
        }
        socket.peer = to
        socket.has_peer = true
        return 0
    }
    if socket.state == .Connected {
        return failed(E_ISCONN)
    }
    if socket.state == .Listening {
        return failed(E_OPNOTSUPP)
    }
    if !state.has_network {
        return failed(E_NETUNREACH)
    }
    opened :: match net.open(state.network, to) {
        case Ok(found) => found
        case Error(failure) => {
            socket.pending_error = errno_of_failure(failure)
            return failed(socket.pending_error)
        }
    }
    socket.tcp = opened
    socket.state = .Connected
    port :: socket_port_of(state) or_return failed(E_NOBUFS)
    if !net.serve_on(&socket.tcp, port, cast[u64](fd)) {
        net.close(&socket.tcp)
        socket.state = .Fresh
        return failed(E_CONNABORTED)
    }
    return 0
}

/**
 * Copy what's arrived on a connection without taking it, as MSG_PEEK does.
 *
 * @param tcp The connection.
 * @param into Where it goes.
 * @return How many bytes were copied.
 */
peek_tcp :: fn(tcp : ptr[net.Tcp], into : mut u8[]) -> usize {
    waiting :: tcp.progress.delivered - tcp.read
    count :: if cast[u64](into.count) < waiting { into.count } else { cast[usize](waiting) }
    ring :: view_of(cast[ptr[u8]](tcp.at + tcp.ring), cast[usize](tcp.ring))
    for i in 0..<count {
        at :: cast[usize]((tcp.read + cast[u64](i)) % tcp.ring)
        if at < ring.count && i < into.count {
            into[i] = ring[at]
        }
    }
    return count
}

/**
 * Receive from a connected TCP socket.
 *
 * @param state The libc's state.
 * @param socket The socket.
 * @param into Where the bytes go.
 * @param flags MSG_PEEK, MSG_WAITALL, MSG_DONTWAIT; others are taken and change nothing.
 * @param nonblocking Whether the descriptor's non-blocking.
 * @return How many bytes, 0 once the peer has finished, or after shutdown's SHUT_RD; -1 with errno ENOTCONN, EAGAIN
 *     when it would wait, or wait longer than SO_RCVTIMEO, or how the connection ended (ECONNRESET).
 */
receive_tcp :: fn(state : ptr[mut State], socket : ptr[mut Socket], into : mut u8[], flags : i32, nonblocking : bool) -> i64 {
    if socket.state != .Connected {
        return failed(E_NOTCONN)
    }
    if socket.read_shut || into.count == 0 {
        return 0
    }
    waits :: !nonblocking && (flags & MSG_DONTWAIT) == 0
    deadline :: deadline_after(socket.receive_wait)
    got := cast[usize](0)
    loop {
        if !net.poll(&socket.tcp) {
            return if got > 0 { cast[i64](got) } else { failed(E_CONNRESET) }
        }
        if (flags & MSG_PEEK) != 0 {
            peeked :: peek_tcp(&socket.tcp, into)
            if peeked > 0 {
                return cast[i64](peeked)
            }
        }
        else {
            if got < into.count {
                got += net.read_now(&socket.tcp, into[got..<into.count])
            }
            if got >= into.count || (got > 0 && (flags & MSG_WAITALL) == 0) {
                return cast[i64](got)
            }
        }
        if socket.tcp.progress.peer_finished || socket.tcp.progress.ending == .Closed {
            return cast[i64](got)
        }
        if socket.tcp.progress.ending != .None {
            return if got > 0 { cast[i64](got) } else { failed(errno_of_ending(socket.tcp.progress.ending)) }
        }
        if !waits {
            return if got > 0 { cast[i64](got) } else { failed(E_AGAIN) }
        }
        if !wait_sockets(state, deadline) {
            return if got > 0 { cast[i64](got) } else { failed(E_AGAIN) }
        }
    }
}

/**
 * Send on a connected TCP socket, all of the bytes unless it's non-blocking.
 *
 * @param state The libc's state.
 * @param socket The socket.
 * @param bytes What's sent.
 * @param flags MSG_DONTWAIT; others are taken and change nothing.
 * @param nonblocking Whether the descriptor's non-blocking.
 * @return How many were sent: all, unless it doesn't wait and there's room for fewer; -1 with errno ENOTCONN, EPIPE
 *     after shutdown's SHUT_WR or once the connection's ended, EAGAIN when there's no room and it doesn't wait or
 *     waited SO_SNDTIMEO.
 */
send_tcp :: fn(state : ptr[mut State], socket : ptr[mut Socket], bytes : u8[], flags : i32, nonblocking : bool) -> i64 {
    if socket.state != .Connected {
        return failed(E_NOTCONN)
    }
    if socket.write_shut {
        return failed(E_PIPE)
    }
    waits :: !nonblocking && (flags & MSG_DONTWAIT) == 0
    deadline :: deadline_after(socket.send_wait)
    sent := cast[usize](0)
    loop {
        if sent >= bytes.count {
            return cast[i64](sent)
        }
        if !net.poll(&socket.tcp) || socket.tcp.progress.ending != .None {
            return if sent > 0 { cast[i64](sent) } else { failed(E_PIPE) }
        }
        wrote :: net.write_now(&socket.tcp, bytes[sent..<bytes.count])
        sent += wrote
        if wrote == 0 {
            if !waits || !wait_sockets(state, deadline) {
                return if sent > 0 { cast[i64](sent) } else { failed(E_AGAIN) }
            }
        }
    }
}

/**
 * Take the next datagram from the service into a UDP socket's stash, asking for one if none's asked, without waiting;
 * a connected socket's from another peer is dropped. The service's other answers, as Describe's, are passed over.
 *
 * @param socket The socket, Datagram.
 * @return 1 with a datagram in the stash; 0 with none yet; -1 if its connection to the service failed.
 */
take_datagram :: fn(socket : ptr[mut Socket]) -> i32 {
    loop {
        if socket.has_stash {
            return 1
        }
        if !socket.asked_receive {
            out := os.Outgoing.{}
            os.begin[datagrams.Request](&out)^ = .Receive
            if datagrams.send_request(socket.udp.channel.end, socket.udp.port, &out) is_some {
                return -1
            }
            socket.asked_receive = true
        }
        into := os.Incoming.{}
        match datagrams.receive_response(socket.udp.channel.end, socket.udp.port, &into, false) {
            case Received => {}
            case Empty => return 0
            case _ => return -1
        }
        match os.message_of[datagrams.Response](&into)^ {
            case Datagram(arrived) => {
                socket.asked_receive = false
                if socket.has_peer && !same_endpoint(arrived.from, socket.peer) {
                    continue
                }
                bytes :: os.items(&into, arrived.bytes)
                count :: if bytes.count < socket.stash.count { bytes.count } else { socket.stash.count }
                for i in 0..<count {
                    if i < bytes.count && i < socket.stash.count {
                        socket.stash[i] = bytes[i]
                    }
                }
                socket.stash_count = count
                socket.stash_from = arrived.from
                socket.has_stash = true
            }
            case _ => {}
        }
    }
}

/**
 * Tell whether two endpoints are the same.
 *
 * @param a One.
 * @param b The other.
 * @return True for the same family, address and port.
 */
same_endpoint :: fn(a : net_address.Endpoint, b : net_address.Endpoint) -> bool {
    if a.port != b.port || a.address.family != b.address.family {
        return false
    }
    for byte, i in a.address.bytes {
        if i < b.address.bytes.count && byte != b.address.bytes[i] {
            return false
        }
    }
    return true
}

/**
 * Receive a datagram on a UDP socket.
 *
 * @param state The libc's state.
 * @param socket The socket.
 * @param fd Its descriptor.
 * @param into Where its bytes go; what doesn't fit is dropped, as POSIX has it.
 * @param flags MSG_PEEK, which leaves it to be received again, and MSG_DONTWAIT.
 * @param nonblocking Whether the descriptor's non-blocking.
 * @param from Where who it's from goes, as give_endpoint says, and its size; null for nowhere.
 * @return Its bytes put in into; -1 with errno EAGAIN when it would wait, or waited SO_RCVTIMEO, ECONNRESET if the
 *     socket's connection to the service failed, or what making the socket failed with.
 */
receive_udp :: fn(
    state : ptr[mut State],
    socket : ptr[mut Socket],
    fd : i32,
    into : mut u8[],
    flags : i32,
    nonblocking : bool,
    from : ptr[mut u8]?,
    from_length : ptr[mut u32]?
) -> i64 {
    made :: make_udp(state, socket, fd)
    if made != 0 {
        return failed(made)
    }
    waits :: !nonblocking && (flags & MSG_DONTWAIT) == 0
    deadline :: deadline_after(socket.receive_wait)
    loop {
        taken :: take_datagram(socket)
        if taken < 0 {
            return failed(E_CONNRESET)
        }
        if taken > 0 {
            break
        }
        if !waits || !wait_sockets(state, deadline) {
            return failed(E_AGAIN)
        }
    }
    count :: if into.count < socket.stash_count { into.count } else { socket.stash_count }
    for i in 0..<count {
        if i < into.count && i < socket.stash.count {
            into[i] = socket.stash[i]
        }
    }
    give_endpoint(from, from_length, socket.stash_from)
    if (flags & MSG_PEEK) == 0 {
        socket.has_stash = false
    }
    return cast[i64](count)
}

/**
 * Send a datagram on a UDP socket.
 *
 * @param state The libc's state.
 * @param socket The socket.
 * @param fd Its descriptor.
 * @param bytes Its payload: at most datagrams.MAX_DATAGRAM bytes.
 * @param to Who to, or null for a connected socket's peer.
 * @return bytes' count once it's with the service, which drops it if it can't go, as one lost would be; -1 with
 *     errno EMSGSIZE for one too long, EDESTADDRREQ with neither an address nor a peer, ECONNRESET if the socket's
 *     connection to the service failed, or what making the socket failed with.
 */
send_udp :: fn(state : ptr[mut State], socket : ptr[mut Socket], fd : i32, bytes : u8[], to : net_address.Endpoint?) -> i64 {
    if bytes.count > cast[usize](datagrams.MAX_DATAGRAM) {
        return failed(E_MSGSIZE)
    }
    made :: make_udp(state, socket, fd)
    if made != 0 {
        return failed(made)
    }
    where :: match to {
        case Some(given) => given
        case None => {
            if !socket.has_peer {
                return failed(E_DESTADDRREQ)
            }
            socket.peer
        }
    }
    if !net.send_to(&socket.udp, where, bytes) {
        return failed(E_CONNRESET)
    }
    return cast[i64](bytes.count)
}

/**
 * Send on a socket, as C's send.
 *
 * @param fd The socket, connected.
 * @param bytes What's sent, count of them.
 * @param count How many.
 * @param flags MSG_DONTWAIT; MSG_NOSIGNAL and others are taken and change nothing, as there are no signals.
 * @return As send_tcp or send_udp: how many were sent; -1 with errno.
 */
send #export #calling_convention(.c) :: fn(fd : i32, bytes : ptr[u8]?, count : usize, flags : i32) -> i64 {
    return sendto(fd, bytes, count, flags, null, 0)
}

/**
 * Send on a socket, to an address for a UDP one, as C's sendto.
 *
 * @param fd The socket.
 * @param bytes What's sent, count of them.
 * @param count How many.
 * @param flags As send's.
 * @param address Who to, for a UDP socket; null for its peer. A TCP socket's is taken and not used.
 * @param length The address's bytes.
 * @return As send_tcp or send_udp: how many were sent; -1 with errno, EINVAL or EAFNOSUPPORT for a bad address.
 */
sendto #export #calling_convention(.c) :: fn(
    fd : i32,
    bytes : ptr[u8]?,
    count : usize,
    flags : i32,
    address : ptr[u8]?,
    length : u32
) -> i64 {
    state :: state_of() or_return failed(E_BADF)
    why := cast[i32](0)
    socket :: socket_of(state, fd, &why) or_return failed(why)
    nonblocking :: (descriptor_of(state, fd) or_return failed(E_BADF)).nonblocking
    given :: match bytes {
        case Some(found) => view_of(found, count)
        case None => u8.[]
    }
    if socket.kind == SOCK_STREAM {
        return send_tcp(state, socket, given, flags, nonblocking)
    }
    to : net_address.Endpoint? = null
    if address is_some {
        match endpoint_of(address, length, socket.family) {
            case Ok(found) => to = found
            case Error(error) => return failed(error)
        }
    }
    return send_udp(state, socket, fd, given, to)
}

/**
 * Receive on a socket, as C's recv.
 *
 * @param fd The socket.
 * @param into Where the bytes go, count of them.
 * @param count How many at most.
 * @param flags MSG_PEEK, MSG_WAITALL (TCP), MSG_DONTWAIT.
 * @return As receive_tcp or receive_udp.
 */
recv #export #calling_convention(.c) :: fn(fd : i32, into : ptr[mut u8]?, count : usize, flags : i32) -> i64 {
    return recvfrom(fd, into, count, flags, null, null)
}

/**
 * Receive on a socket, and say who from, as C's recvfrom.
 *
 * @param fd The socket.
 * @param into Where the bytes go, count of them.
 * @param count How many at most.
 * @param flags As recv's.
 * @param address Where who sent them goes, as give_endpoint says; a TCP socket's peer. Null for nowhere.
 * @param length The room at address, and then its size.
 * @return As receive_tcp or receive_udp.
 */
recvfrom #export #calling_convention(.c) :: fn(
    fd : i32,
    into : ptr[mut u8]?,
    count : usize,
    flags : i32,
    address : ptr[mut u8]?,
    length : ptr[mut u32]?
) -> i64 {
    state :: state_of() or_return failed(E_BADF)
    why := cast[i32](0)
    socket :: socket_of(state, fd, &why) or_return failed(why)
    nonblocking :: (descriptor_of(state, fd) or_return failed(E_BADF)).nonblocking
    none : u8[1]
    place :: match into {
        case Some(found) => view_of(found, count)
        case None => none[0..<0]
    }
    if socket.kind == SOCK_STREAM {
        got :: receive_tcp(state, socket, place, flags, nonblocking)
        if got >= 0 && address is_some {
            match net.describe(&socket.tcp) {
                case Some(info) => give_endpoint(address, length, info.remote)
                case None => {}
            }
        }
        return got
    }
    return receive_udp(state, socket, fd, place, flags, nonblocking, address, length)
}

/**
 * Read from a socket descriptor, as read gives it to recv.
 *
 * @param state The libc's state.
 * @param descriptor The descriptor, a Socket's.
 * @param fd Its number.
 * @param into Where the bytes go.
 * @return As recv's.
 */
read_socket :: fn(state : ptr[mut State], descriptor : ptr[mut Descriptor], fd : i32, into : mut u8[]) -> i64 {
    socket :: descriptor.socket or_return failed(E_BADF)
    if socket.kind == SOCK_STREAM {
        return receive_tcp(state, socket, into, 0, descriptor.nonblocking)
    }
    return receive_udp(state, socket, fd, into, 0, descriptor.nonblocking, null, null)
}

/**
 * Write to a socket descriptor, as write gives it to send.
 *
 * @param state The libc's state.
 * @param descriptor The descriptor, a Socket's.
 * @param fd Its number.
 * @param bytes What's written.
 * @return As send's.
 */
write_socket :: fn(state : ptr[mut State], descriptor : ptr[mut Descriptor], fd : i32, bytes : u8[]) -> i64 {
    socket :: descriptor.socket or_return failed(E_BADF)
    if socket.kind == SOCK_STREAM {
        return send_tcp(state, socket, bytes, 0, descriptor.nonblocking)
    }
    return send_udp(state, socket, fd, bytes, null)
}

/**
 * Close a socket descriptor: a connection finished, and waited on up to CLOSE_WAIT for its bytes to be acknowledged,
 * then closed; a listener's accept asked given up; a UDP socket closed; its socket freed and its number free.
 *
 * @param state The libc's state.
 * @param fd The descriptor, a Socket's.
 */
close_socket :: fn(state : ptr[mut State], fd : i32) {
    descriptor :: descriptor_of(state, fd) or_return void
    match descriptor.socket {
        case Some(socket) => {
            match socket.state {
                case .Connected => {
                    net.finish(&socket.tcp)
                    deadline :: deadline_after(CLOSE_WAIT)
                    loop {
                        if !net.poll(&socket.tcp) || socket.tcp.progress.ending != .None
                            || socket.tcp.progress.acknowledged >= socket.tcp.written {
                            break
                        }
                        if !wait_sockets(state, deadline) {
                            break
                        }
                    }
                    net.close(&socket.tcp)
                }
                case .Listening => {
                    if state.has_socket_port {
                        _ = slop_os.port_unbind(state.socket_port, cast[u64](fd))
                    }
                    if socket.came {
                        net.close(&socket.accepting)
                    }
                    else if socket.asked_accept {
                        net.unmake(&socket.accepting)
                    }
                    net.close_listener(&socket.listener)
                }
                case .Datagram => {
                    if state.has_socket_port {
                        _ = slop_os.port_unbind(state.socket_port, cast[u64](fd))
                    }
                    net.close_udp(&socket.udp)
                }
                case .Fresh => {}
            }
            runtime.free(socket)
        }
        case None => {}
    }
    descriptor^ = Descriptor.{}
}

/**
 * Stop a socket's reading, writing or both, as C's shutdown: SHUT_WR finishes a connection, so the peer reads to its
 * end; SHUT_RD makes every later receive give 0.
 *
 * @param fd The socket.
 * @param how SHUT_RD, SHUT_WR or SHUT_RDWR.
 * @return 0; -1 with errno EBADF, ENOTSOCK, EINVAL for another how, ENOTCONN for a TCP socket not connected.
 */
shutdown #export #calling_convention(.c) :: fn(fd : i32, how : i32) -> i32 {
    state :: state_of() or_return failed(E_BADF)
    why := cast[i32](0)
    socket :: socket_of(state, fd, &why) or_return failed(why)
    if how != SHUT_RD && how != SHUT_WR && how != SHUT_RDWR {
        return failed(E_INVAL)
    }
    if socket.kind == SOCK_STREAM && socket.state != .Connected {
        return failed(E_NOTCONN)
    }
    if how != SHUT_WR {
        socket.read_shut = true
    }
    if how != SHUT_RD {
        socket.write_shut = true
        if socket.kind == SOCK_STREAM {
            net.finish(&socket.tcp)
        }
    }
    return 0
}

/**
 * Read an int option's value.
 *
 * @param value Where it is, length bytes.
 * @param length Its bytes: at least an int's.
 * @return The int; null for one too short or null.
 */
int_of :: fn(value : ptr[u8]?, length : u32) -> i32? {
    given :: value or_return null
    if length < 4 {
        return null
    }
    return cast[ptr[i32]](given)^
}

/**
 * Read a timeout option's value, a struct timeval.
 *
 * @param value Where it is, length bytes.
 * @param length Its bytes: at least a timeval's, 16.
 * @return The time, in nanoseconds, 0 for none; null for one too short, null or negative.
 */
wait_of :: fn(value : ptr[u8]?, length : u32) -> u64? {
    given :: value or_return null
    if length < cast[u32](size_of(TimeVal)) {
        return null
    }
    time :: cast[ptr[TimeVal]](given)^
    if time.seconds < 0 || time.microseconds < 0 {
        return null
    }
    return cast[u64](time.seconds) * 1_000_000_000 + cast[u64](time.microseconds) * 1000
}

/**
 * Set a socket's option, as C's setsockopt: SOL_SOCKET's SO_REUSEADDR, SO_KEEPALIVE, SO_BROADCAST, SO_SNDBUF and
 * SO_RCVBUF, kept for getsockopt and changing nothing; SO_RCVTIMEO and SO_SNDTIMEO, how long receives and sends wait;
 * IPPROTO_TCP's TCP_NODELAY, kept.
 *
 * @param fd The socket.
 * @param level SOL_SOCKET or IPPROTO_TCP.
 * @param name The option.
 * @param value Its value: an int, or a struct timeval for the timeouts.
 * @param length The value's bytes.
 * @return 0; -1 with errno EBADF, ENOTSOCK, EINVAL for a value too short, ENOPROTOOPT for an option it hasn't.
 */
setsockopt #export #calling_convention(.c) :: fn(fd : i32, level : i32, name : i32, value : ptr[u8]?, length : u32) -> i32 {
    state :: state_of() or_return failed(E_BADF)
    why := cast[i32](0)
    socket :: socket_of(state, fd, &why) or_return failed(why)
    if level == SOL_SOCKET && (name == SO_RCVTIMEO || name == SO_SNDTIMEO) {
        wait :: wait_of(value, length) or_return failed(E_INVAL)
        if name == SO_RCVTIMEO {
            socket.receive_wait = wait
        }
        else {
            socket.send_wait = wait
        }
        return 0
    }
    number :: int_of(value, length) or_return failed(E_INVAL)
    if level == SOL_SOCKET {
        if name == SO_REUSEADDR {
            socket.reuse_address = number
            return 0
        }
        if name == SO_KEEPALIVE {
            socket.keep_alive = number
            return 0
        }
        if name == SO_BROADCAST {
            socket.broadcast = number
            return 0
        }
        if name == SO_SNDBUF || name == SO_RCVBUF {
            return 0
        }
    }
    if level == IPPROTO_TCP && name == TCP_NODELAY {
        socket.no_delay = number
        return 0
    }
    return failed(E_NOPROTOOPT)
}

/**
 * Give a socket's option, as C's getsockopt: those setsockopt keeps, SO_TYPE, SO_ERROR (taken: the last connect's
 * failure, then 0), and SO_SNDBUF and SO_RCVBUF as a connection's ring's bytes.
 *
 * @param fd The socket.
 * @param level SOL_SOCKET or IPPROTO_TCP.
 * @param name The option.
 * @param value Where its value goes: an int, or a struct timeval for the timeouts.
 * @param length In: the room at value. Out: the value's bytes.
 * @return 0; -1 with errno EBADF, ENOTSOCK, EINVAL for too little room, ENOPROTOOPT for an option it hasn't.
 */
getsockopt #export #calling_convention(.c) :: fn(
    fd : i32,
    level : i32,
    name : i32,
    value : ptr[mut u8]?,
    length : ptr[mut u32]?
) -> i32 {
    state :: state_of() or_return failed(E_BADF)
    why := cast[i32](0)
    socket :: socket_of(state, fd, &why) or_return failed(why)
    place :: value or_return failed(E_INVAL)
    room :: length or_return failed(E_INVAL)
    if level == SOL_SOCKET && (name == SO_RCVTIMEO || name == SO_SNDTIMEO) {
        if room^ < cast[u32](size_of(TimeVal)) {
            return failed(E_INVAL)
        }
        wait :: if name == SO_RCVTIMEO { socket.receive_wait } else { socket.send_wait }
        cast[ptr[mut TimeVal]](place)^ = TimeVal.{
            seconds = cast[i64](wait / 1_000_000_000),
            microseconds = cast[i64]((wait % 1_000_000_000) / 1000),
        }
        room^ = cast[u32](size_of(TimeVal))
        return 0
    }
    if room^ < 4 {
        return failed(E_INVAL)
    }
    number := cast[i32](0)
    if level == SOL_SOCKET && name == SO_REUSEADDR {
        number = socket.reuse_address
    }
    else if level == SOL_SOCKET && name == SO_KEEPALIVE {
        number = socket.keep_alive
    }
    else if level == SOL_SOCKET && name == SO_BROADCAST {
        number = socket.broadcast
    }
    else if level == SOL_SOCKET && name == SO_TYPE {
        number = socket.kind
    }
    else if level == SOL_SOCKET && name == SO_ERROR {
        number = socket.pending_error
        socket.pending_error = 0
    }
    else if level == SOL_SOCKET && (name == SO_SNDBUF || name == SO_RCVBUF) {
        number = if socket.state == .Connected { cast[i32](socket.tcp.ring) } else { cast[i32](net.DEFAULT_MEMORY / 2) }
    }
    else if level == IPPROTO_TCP && name == TCP_NODELAY {
        number = socket.no_delay
    }
    else {
        return failed(E_NOPROTOOPT)
    }
    cast[ptr[mut i32]](place)^ = number
    room^ = 4
    return 0
}

/**
 * Ask a UDP socket's own endpoint of the service, waiting for its answer; a datagram that comes first is stashed.
 *
 * @param socket The socket, Datagram.
 * @return Its endpoint; null if its connection to the service failed.
 */
describe_udp :: fn(socket : ptr[mut Socket]) -> net_address.Endpoint? {
    out := os.Outgoing.{}
    os.begin[datagrams.Request](&out)^ = .Describe
    if datagrams.send_request(socket.udp.channel.end, socket.udp.port, &out) is_some {
        return null
    }
    loop {
        into := os.Incoming.{}
        match datagrams.receive_response(socket.udp.channel.end, socket.udp.port, &into, true) {
            case Received => {}
            case _ => return null
        }
        match os.message_of[datagrams.Response](&into)^ {
            case Described(endpoint) => return endpoint
            case Datagram(arrived) => {
                socket.asked_receive = false
                if !socket.has_stash && !(socket.has_peer && !same_endpoint(arrived.from, socket.peer)) {
                    bytes :: os.items(&into, arrived.bytes)
                    count :: if bytes.count < socket.stash.count { bytes.count } else { socket.stash.count }
                    for i in 0..<count {
                        if i < bytes.count && i < socket.stash.count {
                            socket.stash[i] = bytes[i]
                        }
                    }
                    socket.stash_count = count
                    socket.stash_from = arrived.from
                    socket.has_stash = true
                }
            }
            case _ => {}
        }
    }
}

/**
 * Give a socket's own address, as C's getsockname: a connection's as the service says, a UDP socket's as the service
 * says, a listener's or one only bound its port with the any address, and a fresh one's the any address and port 0.
 *
 * @param fd The socket.
 * @param address Where it goes, as give_endpoint says.
 * @param length The room at address, and then its size.
 * @return 0; -1 with errno EBADF, ENOTSOCK, ECONNRESET if the service couldn't be asked.
 */
getsockname #export #calling_convention(.c) :: fn(fd : i32, address : ptr[mut u8]?, length : ptr[mut u32]?) -> i32 {
    state :: state_of() or_return failed(E_BADF)
    why := cast[i32](0)
    socket :: socket_of(state, fd, &why) or_return failed(why)
    endpoint := net_address.Endpoint.{port = socket.bound_port}
    endpoint.address.family = if socket.family == AF_INET6 { net_address.Family.V6 } else { net_address.Family.V4 }
    if socket.state == .Connected {
        info :: net.describe(&socket.tcp) or_return failed(E_CONNRESET)
        endpoint = info.local
    }
    else if socket.state == .Datagram {
        endpoint = describe_udp(socket) or_return failed(E_CONNRESET)
    }
    give_endpoint(address, length, endpoint)
    return 0
}

/**
 * Give a socket's peer's address, as C's getpeername.
 *
 * @param fd The socket: a connection, or a connected UDP socket.
 * @param address Where it goes, as give_endpoint says.
 * @param length The room at address, and then its size.
 * @return 0; -1 with errno EBADF, ENOTSOCK, ENOTCONN for a socket that isn't connected, ECONNRESET if the service
 *     couldn't be asked.
 */
getpeername #export #calling_convention(.c) :: fn(fd : i32, address : ptr[mut u8]?, length : ptr[mut u32]?) -> i32 {
    state :: state_of() or_return failed(E_BADF)
    why := cast[i32](0)
    socket :: socket_of(state, fd, &why) or_return failed(why)
    if socket.state == .Connected {
        info :: net.describe(&socket.tcp) or_return failed(E_CONNRESET)
        give_endpoint(address, length, info.remote)
        return 0
    }
    if socket.kind == SOCK_DGRAM && socket.has_peer {
        give_endpoint(address, length, socket.peer)
        return 0
    }
    return failed(E_NOTCONN)
}

/**
 * Say what a descriptor is ready for, without waiting: what poll gives as revents.
 *
 * @param state The libc's state.
 * @param fd The descriptor.
 * @param events What's asked: POLLIN, POLLOUT, or both.
 * @return What it's ready for of those, with POLLERR, POLLHUP or POLLNVAL as they are; a file, stdin, stdout or
 *     stderr is ready for both always, as reading or writing it waits no more than a file's does.
 */
ready_for :: fn(state : ptr[mut State], fd : i32, events : i16) -> i16 {
    descriptor :: descriptor_of(state, fd) or_return POLLNVAL
    if descriptor.kind != .Socket {
        return events & (POLLIN | POLLOUT)
    }
    socket :: descriptor.socket or_return POLLNVAL
    ready := cast[i16](0)
    match socket.state {
        case .Fresh => {
            ready = if socket.kind == SOCK_DGRAM { POLLOUT } else { POLLHUP }
        }
        case .Listening => {
            if check_accept(socket) != 0 {
                ready = POLLERR
            }
            else if socket.came {
                ready = POLLIN
            }
        }
        case .Connected => {
            if !net.poll(&socket.tcp) {
                ready = POLLERR | POLLHUP
            }
            else {
                progress :: socket.tcp.progress
                if progress.delivered > socket.tcp.read || progress.peer_finished || progress.ending != .None
                    || socket.read_shut {
                    ready |= POLLIN
                }
                room :: socket.tcp.ring - (socket.tcp.written - progress.acknowledged)
                if progress.ending == .None && !socket.write_shut && room > 0 {
                    ready |= POLLOUT
                }
                if progress.ending != .None && progress.ending != .Closed {
                    ready |= POLLERR
                }
                if progress.ending != .None || (progress.peer_finished && socket.write_shut) {
                    ready |= POLLHUP
                }
            }
        }
        case .Datagram => {
            taken :: take_datagram(socket)
            ready = POLLOUT
            if taken > 0 {
                ready |= POLLIN
            }
            else if taken < 0 {
                ready |= POLLERR
            }
        }
    }
    return ready & (events | POLLERR | POLLHUP | POLLNVAL)
}

/**
 * Wait for descriptors to be ready, as C's poll.
 *
 * @param descriptors The pollfd entries, count of them: each one's revents set to what its fd's ready for of its
 *     events (ready_for); a negative fd's is 0.
 * @param count How many.
 * @param timeout How long to wait, in milliseconds: 0 for not at all, negative for until one's ready.
 * @return How many entries have revents not 0: 0 if the timeout came first; -1 with errno EINVAL for entries null
 *     with a count.
 */
poll #export #calling_convention(.c) :: fn(descriptors : ptr[mut PollFd]?, count : u64, timeout : i32) -> i32 {
    state :: state_of() or_return failed(E_NOSYS)
    none : PollFd[1]
    entries :: match descriptors {
        case Some(found) => view_of(found, cast[usize](count))
        case None => {
            if count != 0 {
                return failed(E_INVAL)
            }
            none[0..<0]
        }
    }
    deadline :: if timeout < 0 { slop_os.NO_DEADLINE }
        else { (slop_os.clock_monotonic() or_else 0) + cast[u64](timeout) * 1_000_000 }
    loop {
        ready := cast[i32](0)
        for &entry in entries {
            entry.revents = if entry.fd < 0 { cast[i16](0) } else { ready_for(state, entry.fd, entry.events) }
            if entry.revents != 0 {
                ready += 1
            }
        }
        if ready > 0 || timeout == 0 {
            return ready
        }
        if !wait_sockets(state, deadline) {
            if (slop_os.clock_monotonic() or_else deadline) >= deadline {
                return 0
            }
            // No socket's port to wait on: nothing asked will ever be ready
            if !state.has_socket_port {
                return 0
            }
        }
    }
}

/**
 * Resolve a host's name through the network service, for getaddrinfo (c/sockets.c).
 *
 * @param name The name, a C string, at most network.MAX_NAME bytes.
 * @param family AF_INET, AF_INET6, or AF_UNSPEC for both.
 * @param addresses Where the addresses go, 16 bytes each, in network order, an IPv4 one in the first 4.
 * @param families Where each one's family goes, AF_INET or AF_INET6.
 * @param most How many addresses and families there's room for.
 * @return How many were given, at least 1; a negative EAI_ error otherwise: EAI_FAMILY for another family,
 *     EAI_NONAME for a name that doesn't exist, has no address of the family, or isn't a name, EAI_AGAIN when no DNS
 *     server answered, EAI_FAIL without a network, or for one whose policy allows connecting nowhere.
 */
slopos_libc_resolve #export #calling_convention(.c) :: fn(
    name : ptr[u8],
    family : i32,
    addresses : ptr[mut u8],
    families : ptr[mut i32],
    most : i32
) -> i32 {
    state :: state_of() or_return EAI_FAIL
    if !state.has_network {
        return EAI_FAIL
    }
    if family != AF_INET && family != AF_INET6 && family != AF_UNSPEC {
        return EAI_FAMILY
    }
    kinds :: if family == AF_INET { network.Kinds.V4 } else if family == AF_INET6 { network.Kinds.V6 } else { network.Kinds.Both }
    found :: match net.resolve(state.network, string_of(name, strlen(name)), kinds) {
        case Ok(got) => got
        case Error(failure) => return match failure {
            case .NoSuchName => EAI_NONAME
            case .NoAddress => EAI_NONAME
            case .BadName => EAI_NONAME
            case .ResolveFailed => EAI_AGAIN
            case _ => EAI_FAIL
        }
    }
    room :: if most < 0 { cast[usize](0) } else { cast[usize](most) }
    bytes :: view_of(addresses, room * 16)
    kinds_out :: view_of(families, room)
    given := cast[usize](0)
    for i in 0..<found.count {
        if given >= room || given >= kinds_out.count || i >= found.addresses.count {
            break
        }
        address :: found.addresses[i]
        kinds_out[given] = if address.family == .V6 { AF_INET6 } else { AF_INET }
        for byte, b in address.bytes {
            place :: given * 16 + b
            if place < bytes.count {
                bytes[place] = byte
            }
        }
        given += 1
    }
    return if given == 0 { EAI_NONAME } else { cast[i32](given) }
}
