/*
 * The libc's sockets (decisions/0202, 21h), from C, against the development machine's peers (boot.py's
 * --network-peers): a TCP echo of 64 KiB through poll and non-blocking receives, a UDP echo sent to and connected,
 * names resolved by getaddrinfo and reached by name, calls a socket can't take, a client and a server of its own over
 * the loopback interface, 127.0.0.1 and ::1 (21i), and last a server on port 7 that echoes back what the development
 * machine sends it. A refused connection isn't among them, as QEMU's user network
 * never answers a SYN for a closed port (test_network.hsc). Each check says what it found; then how many passed.
 *
 *     sockets <peer address> <TCP echo's port> <UDP echo's port>
 */
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>

static int checks;
static int passed;

/* Count a check, saying it if it failed. */
static void check(int ok, const char *what) {
    checks++;
    if (ok) {
        passed++;
    }
    else {
        printf("failed: %s (errno %d, %s)\n", what, errno, strerror(errno));
    }
}

/* The bytes the TCP echo sends: a pattern no two neighbours share. */
static unsigned char pattern(size_t i) {
    return (unsigned char)((i * 7 + 3) & 0xff);
}

#define ECHO_BYTES 65536

/* How many times, and how far apart in milliseconds, a connect with no route yet is tried, as test_network's
 * OPEN_TRIES: the network's lease may come after the program starts. */
#define CONNECT_TRIES 60
#define CONNECT_PAUSE 500

/* Connect, trying again while there's no route yet, until CONNECT_TRIES have failed so: 0, or -1 with errno. */
static int connect_when_routed(int fd, const struct sockaddr *to, socklen_t length) {
    for (int tries = 0; tries < CONNECT_TRIES; tries++) {
        if (connect(fd, to, length) == 0) {
            return 0;
        }
        if (errno != ENETUNREACH) {
            return -1;
        }
        poll(NULL, 0, CONNECT_PAUSE);
    }
    return -1;
}

/* Addresses' text, both ways, and byte order. */
static void check_addresses(void) {
    unsigned char bytes[16];
    char text[INET6_ADDRSTRLEN];
    check(inet_pton(AF_INET, "10.0.2.2", bytes) == 1 && bytes[0] == 10 && bytes[3] == 2, "inet_pton reads 10.0.2.2");
    check(inet_pton(AF_INET, "256.1.1.1", bytes) == 0, "inet_pton refuses 256.1.1.1");
    check(inet_pton(AF_INET, "1.2.3", bytes) == 0, "inet_pton refuses 1.2.3");
    check(inet_pton(AF_INET6, "fec0::2", bytes) == 1 && bytes[0] == 0xfe && bytes[1] == 0xc0 && bytes[15] == 2,
          "inet_pton reads fec0::2");
    check(inet_pton(AF_INET6, "::ffff:10.0.2.2", bytes) == 1 && bytes[10] == 0xff && bytes[12] == 10,
          "inet_pton reads an IPv4 tail");
    check(inet_pton(AF_INET6, "1::2::3", bytes) == 0, "inet_pton refuses two ::");
    inet_pton(AF_INET6, "2001:db8:0:0:1:0:0:1", bytes);
    check(inet_ntop(AF_INET6, bytes, text, sizeof text) != NULL && strcmp(text, "2001:db8::1:0:0:1") == 0,
          "inet_ntop shortens the first longest run");
    inet_pton(AF_INET6, "::1", bytes);
    check(inet_ntop(AF_INET6, bytes, text, sizeof text) != NULL && strcmp(text, "::1") == 0, "inet_ntop writes ::1");
    check(inet_ntop(AF_INET6, bytes, text, 3) == NULL && errno == ENOSPC, "inet_ntop without room");
    check(htons(0x1234) == 0x3412 && ntohl(htonl(0x01020304)) == 0x01020304, "byte order");
    check(inet_addr("10.0.2.15") == htonl(0x0a00020f), "inet_addr");
}

/* A TCP echo of ECHO_BYTES, written in pieces and read back through poll and non-blocking receives. */
static void check_tcp(const char *peer, const char *port) {
    struct addrinfo hints = {0};
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    struct addrinfo *found = NULL;
    int resolved = getaddrinfo(peer, port, &hints, &found);
    check(resolved == 0 && found != NULL && found->ai_next == NULL, "getaddrinfo of a numeric host");
    if (resolved != 0) {
        return;
    }
    int fd = socket(found->ai_family, found->ai_socktype, found->ai_protocol);
    check(fd >= 3, "a TCP socket");
    int one = 1;
    check(setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one) == 0, "TCP_NODELAY kept");
    check(connect_when_routed(fd, found->ai_addr, found->ai_addrlen) == 0, "connect to the TCP echo");
    struct sockaddr_in them;
    socklen_t length = sizeof them;
    check(getpeername(fd, (struct sockaddr *)&them, &length) == 0 && length == sizeof them
          && them.sin_family == AF_INET && memcmp(&them.sin_addr, &((struct sockaddr_in *)found->ai_addr)->sin_addr, 4) == 0
          && them.sin_port == ((struct sockaddr_in *)found->ai_addr)->sin_port, "getpeername is the echo");
    struct sockaddr_in us;
    length = sizeof us;
    check(getsockname(fd, (struct sockaddr *)&us, &length) == 0 && us.sin_family == AF_INET && us.sin_port != 0,
          "getsockname has a port");
    freeaddrinfo(found);
    check(connect(fd, (struct sockaddr *)&them, sizeof them) == -1 && errno == EISCONN, "connected twice is EISCONN");
    check(fcntl(fd, F_SETFL, O_NONBLOCK) == 0 && (fcntl(fd, F_GETFL) & O_NONBLOCK), "O_NONBLOCK set");
    unsigned char *back = malloc(ECHO_BYTES);
    unsigned char piece[4096];
    size_t sent = 0, got = 0;
    int stalls = 0;
    while (got < ECHO_BYTES && stalls < 200) {
        struct pollfd ask = {fd, (short)(POLLIN | (sent < ECHO_BYTES ? POLLOUT : 0)), 0};
        if (poll(&ask, 1, 5000) <= 0) {
            stalls++;
            continue;
        }
        if ((ask.revents & POLLOUT) && sent < ECHO_BYTES) {
            size_t count = ECHO_BYTES - sent < sizeof piece ? ECHO_BYTES - sent : sizeof piece;
            for (size_t i = 0; i < count; i++) {
                piece[i] = pattern(sent + i);
            }
            ssize_t wrote = write(fd, piece, count);
            if (wrote > 0) {
                sent += (size_t)wrote;
                if (sent == ECHO_BYTES) {
                    check(shutdown(fd, SHUT_WR) == 0, "shutdown SHUT_WR");
                }
            }
        }
        if (ask.revents & POLLIN) {
            ssize_t read_count = recv(fd, back + got, ECHO_BYTES - got, 0);
            if (read_count > 0) {
                got += (size_t)read_count;
            }
            else if (read_count == 0) {
                break;
            }
            else if (errno != EAGAIN) {
                break;
            }
        }
    }
    int same = got == ECHO_BYTES;
    for (size_t i = 0; same && i < ECHO_BYTES; i++) {
        same = back[i] == pattern(i);
    }
    check(same, "the TCP echo's bytes all back");
    char end;
    int waited = 0;
    ssize_t last = -1;
    while (waited++ < 100) {
        struct pollfd ask = {fd, POLLIN, 0};
        poll(&ask, 1, 5000);
        last = recv(fd, &end, 1, 0);
        if (last >= 0 || errno != EAGAIN) {
            break;
        }
    }
    check(last == 0, "the echo's end read as 0");
    check(recv(fd, &end, 1, MSG_DONTWAIT) == 0, "and again");
    check(send(fd, "x", 1, 0) == -1 && errno == EPIPE, "send after SHUT_WR is EPIPE");
    free(back);
    check(close(fd) == 0, "close the connection");
    printf("TCP echo of %zu bytes from %s:%s, %s\n", got, peer, port, same ? "whole" : "not whole");
}

/* A UDP echo: sent to its address, then through a connected socket with read and write. */
static void check_udp(const char *peer, const char *port) {
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    check(fd >= 3, "a UDP socket");
    struct sockaddr_in to = {0};
    to.sin_family = AF_INET;
    to.sin_port = htons((uint16_t)atoi(port));
    inet_pton(AF_INET, peer, &to.sin_addr);
    struct timeval wait = {5, 0};
    check(setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, sizeof wait) == 0, "SO_RCVTIMEO set");
    const char *message = "a datagram from C";
    char back[64] = {0};
    int echoed = 0;
    struct sockaddr_in from;
    for (int tries = 0; tries < 5 && !echoed; tries++) {
        if (sendto(fd, message, strlen(message), 0, (struct sockaddr *)&to, sizeof to) != (ssize_t)strlen(message)) {
            break;
        }
        socklen_t length = sizeof from;
        ssize_t count = recvfrom(fd, back, sizeof back - 1, 0, (struct sockaddr *)&from, &length);
        echoed = count == (ssize_t)strlen(message) && memcmp(back, message, strlen(message)) == 0
                 && from.sin_port == to.sin_port && from.sin_addr.s_addr == to.sin_addr.s_addr;
    }
    check(echoed, "the UDP echo from its address");
    struct sockaddr_in us;
    socklen_t length = sizeof us;
    check(getsockname(fd, (struct sockaddr *)&us, &length) == 0 && us.sin_port != 0, "a UDP socket's port");
    check(connect(fd, (struct sockaddr *)&to, sizeof to) == 0, "connect a UDP socket");
    int again = 0;
    for (int tries = 0; tries < 5 && !again; tries++) {
        if (write(fd, "connected", 9) != 9) {
            break;
        }
        memset(back, 0, sizeof back);
        struct pollfd ask = {fd, POLLIN, 0};
        if (poll(&ask, 1, 5000) == 1 && (ask.revents & POLLIN)) {
            again = read(fd, back, sizeof back) == 9 && memcmp(back, "connected", 9) == 0;
        }
    }
    check(again, "the UDP echo through a connected socket");
    struct timeval brief = {0, 200000};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &brief, sizeof brief);
    check(recv(fd, back, sizeof back, 0) == -1 && errno == EAGAIN, "a receive times out with EAGAIN");
    check(close(fd) == 0, "close the UDP socket");
    printf("UDP echo from %s:%s, %s\n", peer, port, echoed && again ? "both ways" : "missing");
}

/* Names through the network service's resolver, and reaching the echo by name. */
static void check_names(const char *port) {
    struct addrinfo hints = {0};
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_CANONNAME;
    struct addrinfo *found = NULL;
    int resolved = getaddrinfo("peer.slopos.test", port, &hints, &found);
    int v4 = 0, v6 = 0;
    char text[INET6_ADDRSTRLEN];
    for (struct addrinfo *each = found; resolved == 0 && each != NULL; each = each->ai_next) {
        if (each->ai_family == AF_INET) {
            inet_ntop(AF_INET, &((struct sockaddr_in *)each->ai_addr)->sin_addr, text, sizeof text);
            v4 = strcmp(text, "10.0.2.2") == 0;
        }
        else if (each->ai_family == AF_INET6) {
            inet_ntop(AF_INET6, &((struct sockaddr_in6 *)each->ai_addr)->sin6_addr, text, sizeof text);
            v6 = strcmp(text, "fec0::2") == 0;
        }
    }
    check(resolved == 0 && v4 && v6, "peer.slopos.test resolves to fec0::2 and 10.0.2.2");
    check(resolved == 0 && found->ai_canonname != NULL && strcmp(found->ai_canonname, "peer.slopos.test") == 0,
          "AI_CANONNAME");
    int reached = 0;
    for (struct addrinfo *each = found; resolved == 0 && each != NULL && !reached; each = each->ai_next) {
        /* QEMU's user network connects no IPv6, so the IPv4 address is the one reached */
        if (each->ai_family != AF_INET) {
            continue;
        }
        int fd = socket(each->ai_family, each->ai_socktype, each->ai_protocol);
        if (fd >= 0 && connect(fd, each->ai_addr, each->ai_addrlen) == 0) {
            char back[16] = {0};
            reached = send(fd, "by name", 7, 0) == 7 && recv(fd, back, 7, MSG_WAITALL) == 7
                      && memcmp(back, "by name", 7) == 0;
        }
        close(fd);
    }
    check(reached, "the echo reached by name");
    if (resolved == 0) {
        freeaddrinfo(found);
    }
    resolved = getaddrinfo("missing.slopos.test", port, &hints, &found);
    check(resolved == EAI_NONAME, "missing.slopos.test is EAI_NONAME");
    printf("peer.slopos.test reached by name: %s; missing.slopos.test: %s\n", reached ? "yes" : "no", gai_strerror(resolved));
    char host[NI_MAXHOST], service[NI_MAXSERV];
    struct sockaddr_in6 six = {0};
    six.sin6_family = AF_INET6;
    six.sin6_port = htons(443);
    inet_pton(AF_INET6, "fec0::2", &six.sin6_addr);
    check(getnameinfo((struct sockaddr *)&six, sizeof six, host, sizeof host, service, sizeof service, NI_NUMERICHOST) == 0
          && strcmp(host, "fec0::2") == 0 && strcmp(service, "443") == 0, "getnameinfo");
}

/* Errors: calls a socket can't take. */
static void check_errors(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    int error = -1;
    socklen_t length = sizeof error;
    check(getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 && error == 0 && length == sizeof error, "SO_ERROR");
    check(recv(fd, &length, 1, 0) == -1 && errno == ENOTCONN, "receiving unconnected is ENOTCONN");
    check(shutdown(fd, SHUT_WR) == -1 && errno == ENOTCONN, "shutting down unconnected is ENOTCONN");
    check(listen(fd, 1) == -1 && errno == EINVAL, "listening unbound is EINVAL");
    check(close(fd) == 0, "close it");
    check(socket(AF_INET, 3, 0) == -1 && errno == EPROTONOSUPPORT, "a raw socket is EPROTONOSUPPORT");
    check(socket(1, SOCK_STREAM, 0) == -1 && errno == EAFNOSUPPORT, "AF_UNIX is EAFNOSUPPORT");
    check(accept(0, NULL, NULL) == -1 && errno == ENOTSOCK, "accept on stdin is ENOTSOCK");
    check(send(99, "x", 1, 0) == -1 && errno == EBADF, "send on a closed descriptor is EBADF");
    int types = -1;
    fd = socket(AF_INET6, SOCK_DGRAM, 0);
    length = sizeof types;
    check(getsockopt(fd, SOL_SOCKET, SO_TYPE, &types, &length) == 0 && types == SOCK_DGRAM, "SO_TYPE");
    check(getsockopt(fd, SOL_SOCKET, 999, &types, &length) == -1 && errno == ENOPROTOOPT, "an unknown option");
    close(fd);
}

/* Serve one connection on port 7 through select and accept, echoing back all it sends until it finishes. */
static void serve_echo(void) {
    int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    int one = 1;
    check(setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one) == 0, "SO_REUSEADDR kept");
    struct sockaddr_in here = {0};
    here.sin_family = AF_INET;
    here.sin_port = htons(7);
    here.sin_addr.s_addr = htonl(INADDR_ANY);
    check(bind(fd, (struct sockaddr *)&here, sizeof here) == 0, "bind to port 7");
    check(listen(fd, SOMAXCONN) == 0, "listen on 7");
    fcntl(fd, F_SETFL, O_NONBLOCK);
    check(accept(fd, NULL, NULL) == -1 && errno == EAGAIN, "a non-blocking accept with none come is EAGAIN");
    printf("listening on 7\n");
    fflush(stdout);
    fd_set readable;
    FD_ZERO(&readable);
    FD_SET(fd, &readable);
    struct timeval wait = {60, 0};
    check(select(fd + 1, &readable, NULL, NULL, &wait) == 1 && FD_ISSET(fd, &readable), "select says one's come");
    struct sockaddr_in from;
    socklen_t length = sizeof from;
    int connection = accept(fd, (struct sockaddr *)&from, &length);
    check(connection >= 0 && length == sizeof from && from.sin_family == AF_INET, "accept it");
    size_t echoed = 0;
    unsigned char buffer[8192];
    while (connection >= 0) {
        ssize_t count = read(connection, buffer, sizeof buffer);
        if (count <= 0) {
            break;
        }
        if (write(connection, buffer, (size_t)count) != count) {
            break;
        }
        echoed += (size_t)count;
    }
    check(close(connection) == 0, "close what was accepted");
    check(close(fd) == 0, "stop listening");
    char text[INET_ADDRSTRLEN] = "?";
    inet_ntop(AF_INET, &from.sin_addr, text, sizeof text);
    printf("echoed %zu bytes back to %s\n", echoed, text);
}

/* The ports the loopback checks listen on and send from. */
#define LOOPBACK_TCP_PORT 5555
#define LOOPBACK_UDP_PORT 5556

/* A loopback address of a family, as a sockaddr, with a port: 127.0.0.1 or ::1. */
static socklen_t loopback_address(int family, uint16_t port, struct sockaddr_storage *into) {
    memset(into, 0, sizeof *into);
    if (family == AF_INET) {
        struct sockaddr_in *v4 = (struct sockaddr_in *)into;
        v4->sin_family = AF_INET;
        v4->sin_port = htons(port);
        v4->sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        return sizeof *v4;
    }
    struct sockaddr_in6 *v6 = (struct sockaddr_in6 *)into;
    v6->sin6_family = AF_INET6;
    v6->sin6_port = htons(port);
    v6->sin6_addr.s6_addr[15] = 1;
    return sizeof *v6;
}

/*
 * A client and a server of the program's own over the loopback interface, in one thread: the server listening, the
 * client connected to it (the listener's backlog of one finishing the handshake before accept), 64 KiB echoed by the
 * server through poll over both, and a datagram there and back between two UDP sockets.
 */
static void check_loopback(int family, const char *name) {
    char what[96];
    struct sockaddr_storage address;
    socklen_t length = loopback_address(family, LOOPBACK_TCP_PORT, &address);
    int server = socket(family, SOCK_STREAM, 0);
    snprintf(what, sizeof what, "%s: a listener bound and listening", name);
    check(server >= 3 && bind(server, (struct sockaddr *)&address, length) == 0 && listen(server, 4) == 0, what);
    int client = socket(family, SOCK_STREAM, 0);
    snprintf(what, sizeof what, "%s: a client connected to the listener", name);
    check(client >= 3 && connect_when_routed(client, (struct sockaddr *)&address, length) == 0, what);
    struct sockaddr_storage from;
    socklen_t from_length = sizeof from;
    int served = accept(server, (struct sockaddr *)&from, &from_length);
    snprintf(what, sizeof what, "%s: the connection accepted, from the loopback address", name);
    check(served >= 3 && from.ss_family == family
              && (family == AF_INET ? ((struct sockaddr_in *)&from)->sin_addr.s_addr == htonl(INADDR_LOOPBACK)
                                    : ((struct sockaddr_in6 *)&from)->sin6_addr.s6_addr[15] == 1),
          what);
    if (client < 0 || served < 0) {
        close(client);
        close(served);
        close(server);
        return;
    }
    fcntl(client, F_SETFL, O_NONBLOCK);
    fcntl(served, F_SETFL, O_NONBLOCK);
    unsigned char *back = malloc(ECHO_BYTES);
    unsigned char *held = malloc(ECHO_BYTES);
    unsigned char piece[4096];
    size_t sent = 0, got = 0, taken = 0, given = 0;
    int stalls = 0;
    while (got < ECHO_BYTES && stalls < 50 && back != NULL && held != NULL) {
        struct pollfd ask[2] = {{client, (short)(POLLIN | (sent < ECHO_BYTES ? POLLOUT : 0)), 0},
                                {served, (short)(POLLIN | (given < taken ? POLLOUT : 0)), 0}};
        if (poll(ask, 2, 5000) <= 0) {
            stalls++;
            continue;
        }
        if ((ask[0].revents & POLLOUT) && sent < ECHO_BYTES) {
            size_t count = ECHO_BYTES - sent < sizeof piece ? ECHO_BYTES - sent : sizeof piece;
            for (size_t i = 0; i < count; i++) {
                piece[i] = pattern(sent + i);
            }
            ssize_t wrote = write(client, piece, count);
            sent += wrote > 0 ? (size_t)wrote : 0;
        }
        if (ask[1].revents & POLLIN) {
            ssize_t count = read(served, held + taken, ECHO_BYTES - taken);
            taken += count > 0 ? (size_t)count : 0;
        }
        if ((ask[1].revents & POLLOUT) && given < taken) {
            ssize_t wrote = write(served, held + given, taken - given);
            given += wrote > 0 ? (size_t)wrote : 0;
        }
        if (ask[0].revents & POLLIN) {
            ssize_t count = read(client, back + got, ECHO_BYTES - got);
            got += count > 0 ? (size_t)count : 0;
        }
    }
    int same = got == ECHO_BYTES;
    for (size_t i = 0; same && i < ECHO_BYTES; i++) {
        same = back[i] == pattern(i);
    }
    snprintf(what, sizeof what, "%s: 64 KiB echoed back by the program's own server", name);
    check(same, what);
    free(back);
    free(held);
    close(client);
    close(served);
    close(server);
    // A datagram from one socket of the program's to another, and an answer back
    struct sockaddr_storage to;
    socklen_t to_length = loopback_address(family, LOOPBACK_UDP_PORT, &to);
    int receiver = socket(family, SOCK_DGRAM, 0);
    int sender = socket(family, SOCK_DGRAM, 0);
    struct timeval wait = {5, 0};
    setsockopt(receiver, SOL_SOCKET, SO_RCVTIMEO, &wait, sizeof wait);
    setsockopt(sender, SOL_SOCKET, SO_RCVTIMEO, &wait, sizeof wait);
    snprintf(what, sizeof what, "%s: a UDP socket bound to receive", name);
    check(receiver >= 3 && sender >= 3 && bind(receiver, (struct sockaddr *)&to, to_length) == 0, what);
    char text[32] = {0};
    struct sockaddr_storage sent_from;
    socklen_t sent_from_length = sizeof sent_from;
    int there = sendto(sender, "to myself", 9, 0, (struct sockaddr *)&to, to_length) == 9
                && recvfrom(receiver, text, sizeof text, 0, (struct sockaddr *)&sent_from, &sent_from_length) == 9
                && memcmp(text, "to myself", 9) == 0;
    snprintf(what, sizeof what, "%s: a datagram to the program's own socket", name);
    check(there, what);
    memset(text, 0, sizeof text);
    int answered = there && sendto(receiver, "answered", 8, 0, (struct sockaddr *)&sent_from, sent_from_length) == 8
                   && recv(sender, text, sizeof text, 0) == 8 && memcmp(text, "answered", 8) == 0;
    snprintf(what, sizeof what, "%s: its answer back to where it came from", name);
    check(answered, what);
    close(receiver);
    close(sender);
    printf("loopback over %s: %s\n", name, same && there && answered ? "both ways" : "missing");
}

int main(int argc, char **argv) {
    if (argc < 4) {
        printf("usage: sockets <peer> <TCP echo's port> <UDP echo's port>\n");
        return 2;
    }
    check_addresses();
    check_tcp(argv[1], argv[2]);
    check_udp(argv[1], argv[3]);
    check_names(argv[2]);
    check_errors();
    check_loopback(AF_INET, "127.0.0.1");
    check_loopback(AF_INET6, "::1");
    serve_echo();
    printf("sockets: %d of %d checks passed\n", passed, checks);
    printf("sockets: %s\n", passed == checks ? "every check passed" : "a check failed");
    return passed == checks ? 0 : 1;
}
