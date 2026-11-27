/*
 * netdb.h, SlopOS's libc (decisions/0202, 21h): names to addresses through the network service's resolver, and
 * addresses to text. A service is a port's number, or one of the few names getaddrinfo knows (echo, domain, http,
 * https); there's no services file.
 */
#ifndef _NETDB_H
#define _NETDB_H

#include <netinet/in.h>
#include <sys/socket.h>

#ifdef __cplusplus
extern "C" {
#endif

/* One of getaddrinfo's answers: a socket's family, type and protocol, its address, and the next. */
struct addrinfo {
    int ai_flags;
    int ai_family;
    int ai_socktype;
    int ai_protocol;
    socklen_t ai_addrlen;
    struct sockaddr *ai_addr;
    char *ai_canonname;
    struct addrinfo *ai_next;
};

#define AI_PASSIVE 0x1     /* With no host, the any address, to bind to; without it, the loopback */
#define AI_CANONNAME 0x2   /* The first answer's ai_canonname is the host as it was given */
#define AI_NUMERICHOST 0x4 /* The host is an address's text; a name fails with EAI_NONAME */
#define AI_V4MAPPED 0x8    /* Taken, changing nothing */
#define AI_ALL 0x10        /* Taken, changing nothing */
#define AI_ADDRCONFIG 0x20 /* Taken, changing nothing */
#define AI_NUMERICSERV 0x400 /* The service is a port's number */

#define EAI_BADFLAGS -1 /* A flag it doesn't know */
#define EAI_NONAME -2   /* No such name, or none with an address of the family */
#define EAI_AGAIN -3    /* No DNS server answered: maybe for now */
#define EAI_FAIL -4     /* No network to ask, or one whose policy allows connecting nowhere */
#define EAI_FAMILY -6   /* A family that isn't AF_INET, AF_INET6 or AF_UNSPEC */
#define EAI_SOCKTYPE -7 /* A type that isn't SOCK_STREAM, SOCK_DGRAM or 0 */
#define EAI_SERVICE -8  /* A service it doesn't know */
#define EAI_MEMORY -10  /* Out of memory */
#define EAI_SYSTEM -11  /* errno says */
#define EAI_OVERFLOW -12 /* No room for the text */

#define NI_NUMERICHOST 1
#define NI_NUMERICSERV 2
#define NI_NOFQDN 4
#define NI_NAMEREQD 8
#define NI_DGRAM 16
#define NI_MAXHOST 1025
#define NI_MAXSERV 32

/*
 * Find a host's and a service's socket addresses, as POSIX's getaddrinfo: an address's text is read as one, a name
 * asked of the network service, NULL the any address (AI_PASSIVE) or the loopback. With no socket type in hints, each
 * address comes as a SOCK_STREAM answer then a SOCK_DGRAM one. *answers is freed with freeaddrinfo. It answers 0, or
 * an EAI_ error.
 */
int getaddrinfo(const char *host, const char *service, const struct addrinfo *hints, struct addrinfo **answers);
/* Free what getaddrinfo answered. */
void freeaddrinfo(struct addrinfo *answers);
/* Say what an EAI_ error means: a string that's never changed. */
const char *gai_strerror(int error);
/*
 * Write a socket address's host and service as text: always numeric, as there's no reverse resolving; with
 * NI_NAMEREQD that fails with EAI_NONAME. It answers 0, or an EAI_ error.
 */
int getnameinfo(const struct sockaddr *address, socklen_t length, char *host, socklen_t host_room, char *service,
                socklen_t service_room, int flags);

#ifdef __cplusplus
}
#endif

#endif
