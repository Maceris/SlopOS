/*
 * sys/select.h, SlopOS's libc (decisions/0202, 21h): select, over poll (poll.h), for descriptors below FD_SETSIZE.
 */
#ifndef _SYS_SELECT_H
#define _SYS_SELECT_H

#include <sys/types.h>
#include <time.h>

#ifdef __cplusplus
extern "C" {
#endif

/* A time, in seconds and microseconds: select's timeout, and SO_RCVTIMEO's and SO_SNDTIMEO's. */
#ifndef _STRUCT_TIMEVAL
#define _STRUCT_TIMEVAL
struct timeval {
    time_t tv_sec;
    long tv_usec;
};
#endif

/* The most descriptors a set holds: the libc has 64 at most. */
#define FD_SETSIZE 64

/* A set of descriptors, a bit each. */
typedef struct {
    unsigned long fds_bits[FD_SETSIZE / (8 * sizeof(unsigned long))];
} fd_set;

#define FD_ZERO(set) do { for (unsigned long __i = 0; __i < sizeof((set)->fds_bits) / sizeof((set)->fds_bits[0]); __i++) (set)->fds_bits[__i] = 0; } while (0)
#define FD_SET(fd, set) ((set)->fds_bits[(fd) / (8 * sizeof(unsigned long))] |= 1UL << ((fd) % (8 * sizeof(unsigned long))))
#define FD_CLR(fd, set) ((set)->fds_bits[(fd) / (8 * sizeof(unsigned long))] &= ~(1UL << ((fd) % (8 * sizeof(unsigned long)))))
#define FD_ISSET(fd, set) (((set)->fds_bits[(fd) / (8 * sizeof(unsigned long))] >> ((fd) % (8 * sizeof(unsigned long)))) & 1UL)

/*
 * Wait until a descriptor below count in readable is ready to read, or in writable to write, or one in errors has
 * failed, or the timeout (NULL for for ever), as POSIX's select; each set's left with those that are. It answers how
 * many bits are left set, 0 only once the timeout has passed; -1 with errno EINVAL for a count over FD_SETSIZE or a
 * negative timeout, EBADF for a descriptor that isn't open. One that hung up is ready to read and to write.
 */
int select(int count, fd_set *readable, fd_set *writable, fd_set *errors, struct timeval *timeout);

#ifdef __cplusplus
}
#endif

#endif
