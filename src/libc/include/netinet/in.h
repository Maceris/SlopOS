/*
 * netinet/in.h, SlopOS's libc (decisions/0202, 21h): IPv4 and IPv6 socket addresses, as Linux lays them out, their
 * ports and addresses in network order, and byte order's conversions.
 */
#ifndef _NETINET_IN_H
#define _NETINET_IN_H

#include <stdint.h>
#include <sys/socket.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef uint16_t in_port_t;
typedef uint32_t in_addr_t;

/* An IPv4 address, in network order. */
struct in_addr {
    in_addr_t s_addr;
};

/* An IPv4 socket address: AF_INET, the port and the address in network order, then zeros. */
struct sockaddr_in {
    sa_family_t sin_family;
    in_port_t sin_port;
    struct in_addr sin_addr;
    unsigned char sin_zero[8];
};

/* An IPv6 address, its 16 bytes in network order. */
struct in6_addr {
    union {
        uint8_t __u6_addr8[16];
        uint16_t __u6_addr16[8];
        uint32_t __u6_addr32[4];
    } __in6_u;
};
#define s6_addr __in6_u.__u6_addr8

/* An IPv6 socket address: AF_INET6, the port in network order, its flow label (taken, not used), the address, and its
 * scope (taken, not used). */
struct sockaddr_in6 {
    sa_family_t sin6_family;
    in_port_t sin6_port;
    uint32_t sin6_flowinfo;
    struct in6_addr sin6_addr;
    uint32_t sin6_scope_id;
};

#define IPPROTO_IP 0
#define IPPROTO_TCP 6
#define IPPROTO_UDP 17
#define IPPROTO_IPV6 41

#define INADDR_ANY ((in_addr_t)0x00000000)
#define INADDR_BROADCAST ((in_addr_t)0xffffffff)
#define INADDR_NONE ((in_addr_t)0xffffffff)
#define INADDR_LOOPBACK ((in_addr_t)0x7f000001)

#define INET_ADDRSTRLEN 16
#define INET6_ADDRSTRLEN 46

/* The IPv6 any address, ::, and loopback, ::1. */
extern const struct in6_addr in6addr_any;
extern const struct in6_addr in6addr_loopback;
#define IN6ADDR_ANY_INIT {{{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}}}
#define IN6ADDR_LOOPBACK_INIT {{{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1}}}

/* Byte order's conversions: SlopOS's architectures are all little-endian, network order big-endian. */
uint32_t htonl(uint32_t value);
uint16_t htons(uint16_t value);
uint32_t ntohl(uint32_t value);
uint16_t ntohs(uint16_t value);

#ifdef __cplusplus
}
#endif

#endif
