/*
 * poll.h, SlopOS's libc (decisions/0202, 21h): waiting for descriptors to be ready. A socket's ready as its
 * connection, listener or datagrams are; a file, stdin, stdout and stderr are always ready, as reading or writing one
 * waits no longer than a file's does.
 */
#ifndef _POLL_H
#define _POLL_H

#ifdef __cplusplus
extern "C" {
#endif

typedef unsigned long nfds_t;

/* A descriptor, what it's asked to be ready for, and what poll found it ready for. */
struct pollfd {
    int fd;
    short events;
    short revents;
};

#define POLLIN 0x001   /* Something to read: bytes, a connection to accept, a datagram, or the peer's end */
#define POLLPRI 0x002  /* Never: there's no urgent data */
#define POLLOUT 0x004  /* Room to write */
#define POLLERR 0x008  /* Failed: the connection was reset or refused; always given, never asked */
#define POLLHUP 0x010  /* Hung up, or not connected; always given, never asked */
#define POLLNVAL 0x020 /* Not an open descriptor; always given, never asked */
#define POLLRDNORM POLLIN
#define POLLWRNORM POLLOUT

/*
 * Wait until one of count descriptors is ready for what it's asked, or timeout milliseconds (0 not at all, negative for
 * ever), setting each one's revents. It answers how many have revents not 0, 0 at the timeout; -1 with errno.
 */
int poll(struct pollfd *descriptors, nfds_t count, int timeout);

#ifdef __cplusplus
}
#endif

#endif
