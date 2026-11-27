/*
 * sockets.c, SlopOS's libc (decisions/0202, 21h): what of the sockets is C's: byte order, addresses' text
 * (arpa/inet.h), getaddrinfo and its kin over the network service's resolver (slopos_libc_resolve, sockets.hsc),
 * and select over poll. The sockets themselves are the Hemera's (sockets.hsc).
 */
#include <arpa/inet.h>
#include <errno.h>
#include <netdb.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>

/* The Hemera's: a name's addresses, 16 bytes each, and their families; how many, or an EAI_ error. */
int slopos_libc_resolve(const char *name, int family, unsigned char *addresses, int *families, int most);

/* The most addresses a name resolves to: the network service's MAX_ADDRESSES. */
#define MOST_ADDRESSES 8

_Static_assert(sizeof(struct sockaddr_in) == 16, "a sockaddr_in is as sockets.hsc reads it");
_Static_assert(sizeof(struct sockaddr_in6) == 28, "a sockaddr_in6 is as sockets.hsc reads it");
_Static_assert(sizeof(struct pollfd) == 8, "a pollfd is as sockets.hsc's PollFd");
_Static_assert(sizeof(struct timeval) == 16, "a timeval is as sockets.hsc's TimeVal");

const struct in6_addr in6addr_any = IN6ADDR_ANY_INIT;
const struct in6_addr in6addr_loopback = IN6ADDR_LOOPBACK_INIT;

uint32_t htonl(uint32_t value) {
    return __builtin_bswap32(value);
}

uint16_t htons(uint16_t value) {
    return __builtin_bswap16(value);
}

uint32_t ntohl(uint32_t value) {
    return __builtin_bswap32(value);
}

uint16_t ntohs(uint16_t value) {
    return __builtin_bswap16(value);
}

/* Read dotted decimal's four parts into four bytes: 1, or 0 for text that isn't exactly that. */
static int read_v4(const char *text, unsigned char *into) {
    for (int part = 0; part < 4; part++) {
        if (*text < '0' || *text > '9') {
            return 0;
        }
        unsigned value = 0;
        int digits = 0;
        while (*text >= '0' && *text <= '9') {
            /* No leading zeros, as inet_pton has it: they'd be octal to inet_aton's older readers */
            if (digits > 0 && value == 0) {
                return 0;
            }
            value = value * 10 + (unsigned)(*text - '0');
            if (value > 255 || ++digits > 3) {
                return 0;
            }
            text++;
        }
        into[part] = (unsigned char)value;
        if (part < 3) {
            if (*text != '.') {
                return 0;
            }
            text++;
        }
    }
    return *text == '\0';
}

/* A hex digit's value; -1 for a character that isn't one. */
static int hex_value(char c) {
    if (c >= '0' && c <= '9') {
        return c - '0';
    }
    if (c >= 'a' && c <= 'f') {
        return c - 'a' + 10;
    }
    if (c >= 'A' && c <= 'F') {
        return c - 'A' + 10;
    }
    return -1;
}

/* Read an IPv6 address's text into its 16 bytes: 1, or 0 for text that isn't one. */
static int read_v6(const char *text, unsigned char *into) {
    unsigned char bytes[16] = {0};
    int at = 0;
    int gap = -1;
    if (text[0] == ':') {
        if (text[1] != ':') {
            return 0;
        }
        text++;
    }
    while (*text != '\0') {
        if (*text == ':') {
            /* "::", once only, where the zeros go */
            if (gap >= 0) {
                return 0;
            }
            gap = at;
            text++;
            if (*text == '\0') {
                break;
            }
            continue;
        }
        if (at > 14) {
            return 0;
        }
        /* A dotted IPv4 tail, in the last 4 bytes */
        const char *dot = text;
        while (*dot != '\0' && *dot != ':' && *dot != '.') {
            dot++;
        }
        if (*dot == '.') {
            if (at > 12 || !read_v4(text, bytes + at)) {
                return 0;
            }
            at += 4;
            break;
        }
        unsigned value = 0;
        int digits = 0;
        while (hex_value(*text) >= 0) {
            value = (value << 4) | (unsigned)hex_value(*text);
            if (++digits > 4) {
                return 0;
            }
            text++;
        }
        if (digits == 0) {
            return 0;
        }
        bytes[at++] = (unsigned char)(value >> 8);
        bytes[at++] = (unsigned char)value;
        if (*text == ':') {
            text++;
            if (*text == '\0') {
                return 0;
            }
            if (*text == ':') {
                continue;
            }
        }
        else if (*text != '\0') {
            return 0;
        }
    }
    if (gap >= 0) {
        int tail = at - gap;
        if (at == 16) {
            return 0;
        }
        memmove(bytes + 16 - tail, bytes + gap, (size_t)tail);
        memset(bytes + gap, 0, (size_t)(16 - tail - gap));
    }
    else if (at != 16) {
        return 0;
    }
    memcpy(into, bytes, 16);
    return 1;
}

int inet_pton(int family, const char *text, void *into) {
    if (family == AF_INET) {
        return read_v4(text, (unsigned char *)into);
    }
    if (family == AF_INET6) {
        return read_v6(text, (unsigned char *)into);
    }
    errno = EAFNOSUPPORT;
    return -1;
}

const char *inet_ntop(int family, const void *address, char *into, socklen_t room) {
    const unsigned char *bytes = (const unsigned char *)address;
    char made[INET6_ADDRSTRLEN];
    if (family == AF_INET) {
        snprintf(made, sizeof made, "%u.%u.%u.%u", bytes[0], bytes[1], bytes[2], bytes[3]);
    }
    else if (family == AF_INET6) {
        unsigned groups[8];
        for (int i = 0; i < 8; i++) {
            groups[i] = ((unsigned)bytes[2 * i] << 8) | bytes[2 * i + 1];
        }
        /* RFC 5952: the longest run of two or more zero groups, the first of the longest, is :: */
        int best = -1, best_length = 0;
        for (int i = 0; i < 8;) {
            if (groups[i] != 0) {
                i++;
                continue;
            }
            int j = i;
            while (j < 8 && groups[j] == 0) {
                j++;
            }
            if (j - i > best_length && j - i >= 2) {
                best = i;
                best_length = j - i;
            }
            i = j;
        }
        size_t at = 0;
        for (int i = 0; i < 8; i++) {
            if (i == best) {
                at += (size_t)snprintf(made + at, sizeof made - at, "::");
                i += best_length - 1;
                continue;
            }
            at += (size_t)snprintf(made + at, sizeof made - at, "%x%s", groups[i], i < 7 && i + 1 != best ? ":" : "");
        }
    }
    else {
        errno = EAFNOSUPPORT;
        return NULL;
    }
    if (strlen(made) + 1 > room) {
        errno = ENOSPC;
        return NULL;
    }
    strcpy(into, made);
    return into;
}

in_addr_t inet_addr(const char *text) {
    struct in_addr address;
    return inet_aton(text, &address) ? address.s_addr : INADDR_NONE;
}

int inet_aton(const char *text, struct in_addr *into) {
    return read_v4(text, (unsigned char *)&into->s_addr);
}

char *inet_ntoa(struct in_addr address) {
    static char text[INET_ADDRSTRLEN];
    inet_ntop(AF_INET, &address, text, sizeof text);
    return text;
}

/* A service getaddrinfo knows by name, and its port. */
struct known_service {
    const char *name;
    int port;
};

static const struct known_service KNOWN_SERVICES[] = {
    {"echo", 7}, {"ssh", 22}, {"domain", 53}, {"http", 80}, {"ntp", 123}, {"https", 443},
};

/* Read a service: a port's number, 0 to 65535, or a name it knows; -1 for one it doesn't. */
static int port_of(const char *service, int numeric_only) {
    if (service == NULL) {
        return 0;
    }
    if (*service >= '0' && *service <= '9') {
        long value = 0;
        for (const char *c = service; *c != '\0'; c++) {
            if (*c < '0' || *c > '9') {
                return -1;
            }
            value = value * 10 + (*c - '0');
            if (value > 65535) {
                return -1;
            }
        }
        return (int)value;
    }
    if (numeric_only) {
        return -1;
    }
    for (size_t i = 0; i < sizeof KNOWN_SERVICES / sizeof KNOWN_SERVICES[0]; i++) {
        if (strcmp(KNOWN_SERVICES[i].name, service) == 0) {
            return KNOWN_SERVICES[i].port;
        }
    }
    return -1;
}

/* Add an answer for an address of a family and a type to the end of a list: 0, or EAI_MEMORY. */
static int add_answer(struct addrinfo ***tail, int family, int type, const unsigned char *bytes, int port) {
    struct addrinfo *answer = calloc(1, sizeof *answer);
    if (answer == NULL) {
        return EAI_MEMORY;
    }
    if (family == AF_INET6) {
        struct sockaddr_in6 *address = calloc(1, sizeof *address);
        if (address == NULL) {
            free(answer);
            return EAI_MEMORY;
        }
        address->sin6_family = AF_INET6;
        address->sin6_port = htons((uint16_t)port);
        memcpy(address->sin6_addr.s6_addr, bytes, 16);
        answer->ai_addr = (struct sockaddr *)address;
        answer->ai_addrlen = sizeof *address;
    }
    else {
        struct sockaddr_in *address = calloc(1, sizeof *address);
        if (address == NULL) {
            free(answer);
            return EAI_MEMORY;
        }
        address->sin_family = AF_INET;
        address->sin_port = htons((uint16_t)port);
        memcpy(&address->sin_addr.s_addr, bytes, 4);
        answer->ai_addr = (struct sockaddr *)address;
        answer->ai_addrlen = sizeof *address;
    }
    answer->ai_family = family;
    answer->ai_socktype = type;
    answer->ai_protocol = type == SOCK_STREAM ? IPPROTO_TCP : IPPROTO_UDP;
    **tail = answer;
    *tail = &answer->ai_next;
    return 0;
}

int getaddrinfo(const char *host, const char *service, const struct addrinfo *hints, struct addrinfo **answers) {
    int flags = hints != NULL ? hints->ai_flags : 0;
    int family = hints != NULL ? hints->ai_family : AF_UNSPEC;
    int type = hints != NULL ? hints->ai_socktype : 0;
    *answers = NULL;
    if ((flags & ~(AI_PASSIVE | AI_CANONNAME | AI_NUMERICHOST | AI_V4MAPPED | AI_ALL | AI_ADDRCONFIG | AI_NUMERICSERV)) != 0) {
        return EAI_BADFLAGS;
    }
    if (family != AF_UNSPEC && family != AF_INET && family != AF_INET6) {
        return EAI_FAMILY;
    }
    if (type != 0 && type != SOCK_STREAM && type != SOCK_DGRAM) {
        return EAI_SOCKTYPE;
    }
    if (host == NULL && service == NULL) {
        return EAI_NONAME;
    }
    int port = port_of(service, flags & AI_NUMERICSERV);
    if (port < 0) {
        return EAI_SERVICE;
    }
    unsigned char addresses[MOST_ADDRESSES * 16] = {0};
    int families[MOST_ADDRESSES];
    int count = 0;
    if (host == NULL) {
        /* The any address to bind to, or the loopback: IPv4's for AF_UNSPEC */
        families[0] = family == AF_INET6 ? AF_INET6 : AF_INET;
        if (!(flags & AI_PASSIVE)) {
            if (families[0] == AF_INET6) {
                addresses[15] = 1;
            }
            else {
                addresses[0] = 127;
                addresses[3] = 1;
            }
        }
        count = 1;
    }
    else if (family != AF_INET6 && read_v4(host, addresses)) {
        families[0] = AF_INET;
        count = 1;
    }
    else if (family != AF_INET && read_v6(host, addresses)) {
        families[0] = AF_INET6;
        count = 1;
    }
    else if (flags & AI_NUMERICHOST) {
        return EAI_NONAME;
    }
    else {
        count = slopos_libc_resolve(host, family, addresses, families, MOST_ADDRESSES);
        if (count < 0) {
            return count;
        }
    }
    struct addrinfo *list = NULL;
    struct addrinfo **tail = &list;
    for (int i = 0; i < count; i++) {
        for (int kind = SOCK_STREAM; kind <= SOCK_DGRAM; kind++) {
            if (type != 0 && kind != type) {
                continue;
            }
            int added = add_answer(&tail, families[i], kind, addresses + 16 * i, port);
            if (added != 0) {
                freeaddrinfo(list);
                return added;
            }
        }
    }
    if (list != NULL && (flags & AI_CANONNAME) && host != NULL) {
        list->ai_canonname = strdup(host);
        if (list->ai_canonname == NULL) {
            freeaddrinfo(list);
            return EAI_MEMORY;
        }
    }
    *answers = list;
    return 0;
}

void freeaddrinfo(struct addrinfo *answers) {
    while (answers != NULL) {
        struct addrinfo *next = answers->ai_next;
        free(answers->ai_addr);
        free(answers->ai_canonname);
        free(answers);
        answers = next;
    }
}

const char *gai_strerror(int error) {
    switch (error) {
    case 0: return "Success";
    case EAI_BADFLAGS: return "Bad value for ai_flags";
    case EAI_NONAME: return "Name or service not known";
    case EAI_AGAIN: return "Temporary failure in name resolution";
    case EAI_FAIL: return "Non-recoverable failure in name resolution";
    case EAI_FAMILY: return "ai_family not supported";
    case EAI_SOCKTYPE: return "ai_socktype not supported";
    case EAI_SERVICE: return "Servname not supported for ai_socktype";
    case EAI_MEMORY: return "Memory allocation failure";
    case EAI_SYSTEM: return "System error";
    case EAI_OVERFLOW: return "Argument buffer overflow";
    default: return "Unknown error";
    }
}

int getnameinfo(const struct sockaddr *address, socklen_t length, char *host, socklen_t host_room, char *service,
                socklen_t service_room, int flags) {
    if (address == NULL) {
        return EAI_FAIL;
    }
    if (flags & NI_NAMEREQD) {
        return EAI_NONAME;
    }
    unsigned port;
    if (address->sa_family == AF_INET && length >= sizeof(struct sockaddr_in)) {
        const struct sockaddr_in *v4 = (const struct sockaddr_in *)address;
        port = ntohs(v4->sin_port);
        if (host != NULL && host_room > 0 && inet_ntop(AF_INET, &v4->sin_addr, host, host_room) == NULL) {
            return EAI_OVERFLOW;
        }
    }
    else if (address->sa_family == AF_INET6 && length >= sizeof(struct sockaddr_in6)) {
        const struct sockaddr_in6 *v6 = (const struct sockaddr_in6 *)address;
        port = ntohs(v6->sin6_port);
        if (host != NULL && host_room > 0 && inet_ntop(AF_INET6, &v6->sin6_addr, host, host_room) == NULL) {
            return EAI_OVERFLOW;
        }
    }
    else {
        return EAI_FAMILY;
    }
    if (service != NULL && service_room > 0) {
        int written = snprintf(service, service_room, "%u", port);
        if (written < 0 || (socklen_t)written >= service_room) {
            return EAI_OVERFLOW;
        }
    }
    return 0;
}

int select(int count, fd_set *readable, fd_set *writable, fd_set *errors, struct timeval *timeout) {
    if (count < 0 || count > FD_SETSIZE || (timeout != NULL && (timeout->tv_sec < 0 || timeout->tv_usec < 0))) {
        errno = EINVAL;
        return -1;
    }
    struct pollfd asked[FD_SETSIZE];
    int places = 0;
    for (int fd = 0; fd < count; fd++) {
        short events = 0;
        if (readable != NULL && FD_ISSET(fd, readable)) {
            events |= POLLIN;
        }
        if (writable != NULL && FD_ISSET(fd, writable)) {
            events |= POLLOUT;
        }
        if (events != 0 || (errors != NULL && FD_ISSET(fd, errors))) {
            asked[places].fd = fd;
            asked[places].events = events;
            asked[places].revents = 0;
            places++;
        }
    }
    int wait = -1;
    if (timeout != NULL) {
        long long milliseconds = (long long)timeout->tv_sec * 1000 + (timeout->tv_usec + 999) / 1000;
        wait = milliseconds > 0x7fffffff ? 0x7fffffff : (int)milliseconds;
    }
    int ready = poll(asked, (nfds_t)places, wait);
    if (ready < 0) {
        return -1;
    }
    for (int i = 0; i < places; i++) {
        if (asked[i].revents & POLLNVAL) {
            errno = EBADF;
            return -1;
        }
    }
    if (readable != NULL) {
        FD_ZERO(readable);
    }
    if (writable != NULL) {
        FD_ZERO(writable);
    }
    fd_set failed;
    FD_ZERO(&failed);
    int bits = 0;
    for (int i = 0; i < places; i++) {
        int fd = asked[i].fd;
        short got = asked[i].revents;
        if (readable != NULL && (asked[i].events & POLLIN) && (got & (POLLIN | POLLHUP | POLLERR))) {
            FD_SET(fd, readable);
            bits++;
        }
        if (writable != NULL && (asked[i].events & POLLOUT) && (got & (POLLOUT | POLLERR))) {
            FD_SET(fd, writable);
            bits++;
        }
        if (errors != NULL && FD_ISSET(fd, errors) && (got & POLLERR)) {
            FD_SET(fd, &failed);
            bits++;
        }
    }
    if (errors != NULL) {
        *errors = failed;
    }
    return bits;
}
