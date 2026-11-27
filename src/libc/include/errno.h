/*
 * errno.h, SlopOS's libc (decisions/0201, 20l): the error numbers its functions set errno to, with Linux's values, so
 * ported code that prints or compares them sees the familiar ones. errno is one per program: SlopOS's C has no threads
 * of its own.
 */
#ifndef _ERRNO_H
#define _ERRNO_H

#ifdef __cplusplus
extern "C" {
#endif

/* Where errno is: a function, so it could become one per thread without changing what C compiled against this sees. */
int *__errno_location(void);
#define errno (*__errno_location())

#define EPERM 1         /* Not allowed */
#define ENOENT 2        /* Nothing at the path */
#define EINTR 4         /* Interrupted */
#define EIO 5           /* The device or server failed */
#define EBADF 9         /* Not an open file descriptor, or not open for that */
#define EAGAIN 11       /* Try again */
#define ENOMEM 12       /* Out of memory */
#define EACCES 13       /* Access denied, or a revoked grant */
#define EFAULT 14       /* A bad address */
#define EBUSY 16        /* Busy */
#define EEXIST 17       /* Something's at the path already */
#define EXDEV 18        /* Across volumes */
#define ENOTDIR 20      /* A part of the path isn't a directory */
#define EISDIR 21       /* A directory, where a file was wanted */
#define EINVAL 22       /* An argument isn't valid */
#define EMFILE 24       /* No file descriptor left */
#define ENOTTY 25       /* Not a terminal */
#define EFBIG 27        /* Too big */
#define ENOSPC 28       /* The volume's full */
#define ESPIPE 29       /* Can't seek on it */
#define EROFS 30        /* A read-only volume */
#define EPIPE 32        /* The other end's gone */
#define EDOM 33         /* Outside a math function's domain */
#define ERANGE 34       /* A result out of range */
#define EDEADLK 35      /* Would deadlock */
#define ENAMETOOLONG 36 /* A path or name too long */
#define ENOSYS 38       /* Not on SlopOS */
#define ENOTEMPTY 39    /* A directory with something in it */
#define EOVERFLOW 75    /* A value too large for its type */
#define EILSEQ 84       /* Not a valid character */
#define ENOTSOCK 88     /* Not a socket */
#define EDESTADDRREQ 89 /* No address to send to */
#define EMSGSIZE 90     /* A datagram too long */
#define EPROTOTYPE 91   /* The wrong kind of socket for the protocol */
#define ENOPROTOOPT 92  /* An option the socket hasn't */
#define EPROTONOSUPPORT 93 /* A protocol there's none of */
#define ENOTSUP 95      /* Not supported */
#define EAFNOSUPPORT 97 /* An address family there's none of */
#define EADDRINUSE 98   /* The port's taken */
#define EADDRNOTAVAIL 99 /* Not an address of this machine's */
#define ENETUNREACH 101 /* No route to the network */
#define ECONNABORTED 103 /* The connection was given up */
#define ECONNRESET 104  /* The peer reset the connection */
#define ENOBUFS 105     /* No room for it */
#define EISCONN 106     /* Connected already */
#define ENOTCONN 107    /* Not connected */
#define ETIMEDOUT 110   /* Nothing answered in time */
#define ECONNREFUSED 111 /* Nothing listens there */
#define EHOSTUNREACH 113 /* No route to the host */
#define EALREADY 114    /* Under way already */
#define EINPROGRESS 115 /* Under way, not done */
#define EOPNOTSUPP ENOTSUP
#define EWOULDBLOCK EAGAIN

#ifdef __cplusplus
}
#endif

#endif
