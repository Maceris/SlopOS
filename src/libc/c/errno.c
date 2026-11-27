/*
 * errno.c, SlopOS's libc (decisions/0201, 20l): errno itself, which the libc's Hemera sets through __libc_set_errno,
 * and strerror's words for each number.
 */
#include <errno.h>
#include <string.h>

/* The program's errno: one, as SlopOS's C has no threads of its own. */
static int error_number;

int *__errno_location(void) {
    return &error_number;
}

/* Set errno, for the libc's Hemera, which can't reach a C variable itself. */
void __libc_set_errno(int number) {
    error_number = number;
}

/* An error number and what strerror says of it. */
struct error_words {
    int number;
    const char *words;
};

static const struct error_words ERROR_WORDS[] = {
    {0, "Success"},
    {EPERM, "Operation not permitted"},
    {ENOENT, "No such file or directory"},
    {EINTR, "Interrupted"},
    {EIO, "Input/output error"},
    {EBADF, "Bad file descriptor"},
    {EAGAIN, "Resource temporarily unavailable"},
    {ENOMEM, "Out of memory"},
    {EACCES, "Permission denied"},
    {EFAULT, "Bad address"},
    {EBUSY, "Busy"},
    {EEXIST, "File exists"},
    {EXDEV, "Across volumes"},
    {ENOTDIR, "Not a directory"},
    {EISDIR, "Is a directory"},
    {EINVAL, "Invalid argument"},
    {EMFILE, "Too many open files"},
    {ENOTTY, "Not a terminal"},
    {EFBIG, "File too large"},
    {ENOSPC, "No space left on the volume"},
    {ESPIPE, "Illegal seek"},
    {EROFS, "Read-only volume"},
    {EPIPE, "Broken pipe"},
    {EDOM, "Numerical argument out of domain"},
    {ERANGE, "Numerical result out of range"},
    {EDEADLK, "Deadlock avoided"},
    {ENAMETOOLONG, "File name too long"},
    {ENOSYS, "Not available on SlopOS"},
    {ENOTEMPTY, "Directory not empty"},
    {EOVERFLOW, "Value too large for defined data type"},
    {EILSEQ, "Invalid character"},
    {ENOTSUP, "Not supported"},
    {ENOTSOCK, "Socket operation on non-socket"},
    {EDESTADDRREQ, "Destination address required"},
    {EMSGSIZE, "Message too long"},
    {EPROTOTYPE, "Protocol wrong type for socket"},
    {ENOPROTOOPT, "Protocol not available"},
    {EPROTONOSUPPORT, "Protocol not supported"},
    {EAFNOSUPPORT, "Address family not supported by protocol"},
    {EADDRINUSE, "Address already in use"},
    {EADDRNOTAVAIL, "Cannot assign requested address"},
    {ENETUNREACH, "Network is unreachable"},
    {ECONNABORTED, "Software caused connection abort"},
    {ECONNRESET, "Connection reset by peer"},
    {ENOBUFS, "No buffer space available"},
    {EISCONN, "Transport endpoint is already connected"},
    {ENOTCONN, "Transport endpoint is not connected"},
    {ETIMEDOUT, "Connection timed out"},
    {ECONNREFUSED, "Connection refused"},
    {EHOSTUNREACH, "No route to host"},
    {EALREADY, "Operation already in progress"},
    {EINPROGRESS, "Operation now in progress"},
};

/* Say what an error number means: a string that's never changed, "Unknown error" for a number not among them. */
char *strerror(int number) {
    for (size_t i = 0; i < sizeof ERROR_WORDS / sizeof ERROR_WORDS[0]; i++) {
        if (ERROR_WORDS[i].number == number) {
            return (char *)ERROR_WORDS[i].words;
        }
    }
    return (char *)"Unknown error";
}

/* The place strtok goes on from, between calls. */
static char *token_place;

/* Split a string into tokens as strtok_r does, keeping its place itself. */
char *strtok(char *text, const char *separators) {
    return strtok_r(text, separators, &token_place);
}
