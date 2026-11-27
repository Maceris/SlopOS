/*
 * sys/socket.h, SlopOS's libc (decisions/0202, 21h): sockets over the network service, through the connection to it
 * the program was given (src/libc/sockets.hsc). AF_INET and AF_INET6; SOCK_STREAM (TCP) and SOCK_DGRAM (UDP). A
 * socket is a file descriptor: read, write, close and fcntl's O_NONBLOCK take it too. Linux's values, so ported code
 * that compares them sees the familiar ones. Each function sets errno and answers -1 when it fails.
 */
#ifndef _SYS_SOCKET_H
#define _SYS_SOCKET_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef uint32_t socklen_t;
typedef uint16_t sa_family_t;

/* Any socket address: its family, then what that family has. */
struct sockaddr {
    sa_family_t sa_family;
    char sa_data[14];
};

/* Room for any socket address, aligned for any. */
struct sockaddr_storage {
    sa_family_t ss_family;
    char __padding[118];
    uint64_t __align;
};

#define AF_UNSPEC 0
#define AF_INET 2
#define AF_INET6 10
#define PF_UNSPEC AF_UNSPEC
#define PF_INET AF_INET
#define PF_INET6 AF_INET6

#define SOCK_STREAM 1
#define SOCK_DGRAM 2
/* socket's type may have these with it: non-blocking, and close on exec (kept, changing nothing, as there's no exec) */
#define SOCK_NONBLOCK 04000
#define SOCK_CLOEXEC 02000000

#define SOL_SOCKET 1
#define SO_REUSEADDR 2  /* Kept for getsockopt; the service decides */
#define SO_TYPE 3       /* SOCK_STREAM or SOCK_DGRAM, to read */
#define SO_ERROR 4      /* The last connect's failure, taken by reading it */
#define SO_BROADCAST 6  /* Kept for getsockopt */
#define SO_SNDBUF 7     /* A connection's ring's bytes, to read; set, it changes nothing */
#define SO_RCVBUF 8     /* As SO_SNDBUF */
#define SO_KEEPALIVE 9  /* Kept for getsockopt */
#define SO_RCVTIMEO 20  /* A struct timeval: how long a receive waits; zero for for ever */
#define SO_SNDTIMEO 21  /* As SO_RCVTIMEO, for a send */

#define SHUT_RD 0
#define SHUT_WR 1
#define SHUT_RDWR 2

#define MSG_PEEK 0x2        /* Leave what's received to be received again */
#define MSG_DONTWAIT 0x40   /* Fail with EAGAIN rather than wait, this once */
#define MSG_WAITALL 0x100   /* A TCP receive waits until it has all it asks, or the connection's end */
#define MSG_NOSIGNAL 0x4000 /* Taken, changing nothing: there are no signals */

#define SOMAXCONN 4096

/*
 * Make a socket of a domain, AF_INET or AF_INET6, and a type, SOCK_STREAM or SOCK_DGRAM with SOCK_NONBLOCK or
 * SOCK_CLOEXEC; protocol 0 or the type's own. It answers the lowest free descriptor.
 */
int socket(int domain, int type, int protocol);
/* Bind a socket to the address's port, 0 for one the service picks; its address is taken but not kept. */
int bind(int fd, const struct sockaddr *address, socklen_t length);
/* Listen on a TCP socket's bound port; backlog is taken and not used. */
int listen(int fd, int backlog);
/* Take a listener's next connection, waiting for one unless it's non-blocking; who from goes in address. */
int accept(int fd, struct sockaddr *address, socklen_t *length);
/* Connect a TCP socket, waiting for its handshake even when non-blocking; or set a UDP socket's peer. */
int connect(int fd, const struct sockaddr *address, socklen_t length);
/* Send on a connected socket: all of it, unless it's non-blocking and there's room for less. */
ssize_t send(int fd, const void *bytes, size_t count, int flags);
/* Send on a socket, a UDP one to the address, or its peer if the address is NULL. */
ssize_t sendto(int fd, const void *bytes, size_t count, int flags, const struct sockaddr *address, socklen_t length);
/* Receive on a socket: 0 once a TCP peer has finished. */
ssize_t recv(int fd, void *into, size_t count, int flags);
/* Receive on a socket, and who from: a datagram's sender, a connection's peer. */
ssize_t recvfrom(int fd, void *into, size_t count, int flags, struct sockaddr *address, socklen_t *length);
/* Stop reading (SHUT_RD), writing (SHUT_WR, which finishes a connection) or both. */
int shutdown(int fd, int how);
/* Set an option: SOL_SOCKET's listed above, IPPROTO_TCP's TCP_NODELAY; another fails with ENOPROTOOPT. */
int setsockopt(int fd, int level, int name, const void *value, socklen_t length);
/* Give an option's value, as setsockopt's. */
int getsockopt(int fd, int level, int name, void *value, socklen_t *length);
/* Give a socket's own address. */
int getsockname(int fd, struct sockaddr *address, socklen_t *length);
/* Give a connected socket's peer's address. */
int getpeername(int fd, struct sockaddr *address, socklen_t *length);

#ifdef __cplusplus
}
#endif

#endif
