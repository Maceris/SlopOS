/*
 * arpa/inet.h, SlopOS's libc (decisions/0202, 21h): addresses' text, as POSIX has it.
 */
#ifndef _ARPA_INET_H
#define _ARPA_INET_H

#include <netinet/in.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Read an address's text into its bytes, in network order: AF_INET's dotted decimal, four parts of 0 to 255, into a
 * struct in_addr; AF_INET6's colon-separated hex, with one :: at most and a dotted IPv4 tail, into a struct in6_addr.
 * It answers 1 once it's read; 0 for text that isn't one; -1 with errno EAFNOSUPPORT for another family.
 */
int inet_pton(int family, const char *text, void *into);
/*
 * Write an address's text, AF_INET's dotted decimal or AF_INET6's shortest form (RFC 5952), into room bytes at into,
 * its 0 too. It answers into; NULL with errno ENOSPC without room, EAFNOSUPPORT for another family.
 */
const char *inet_ntop(int family, const void *address, char *into, socklen_t room);
/* Read dotted decimal: the address, in network order; INADDR_NONE for text that isn't one. */
in_addr_t inet_addr(const char *text);
/* Read dotted decimal into an address: 1 once it's read, 0 if it isn't one. */
int inet_aton(const char *text, struct in_addr *into);
/* Write an address's dotted decimal, in a buffer of the libc's that the next call writes again. */
char *inet_ntoa(struct in_addr address);

#ifdef __cplusplus
}
#endif

#endif
