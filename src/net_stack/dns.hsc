package net_stack

/*
 * The resolver (decisions/0188, 13e): a stub resolver (RFC 1035, AAAA in RFC 3596) asking recursive servers over UDP,
 * with a cache. resolve starts a lookup of a name's IPv4 or IPv6 addresses or both; each kind is a query of its own,
 * from a UDP socket of the resolver's on a random port, with a random ID, and an answer counts only if it's from the
 * server asked, with the query's ID and question. A query not answered within DNS_TIMEOUT is asked again, of the next
 * server, its wait doubling, up to DNS_TRIES times; a server failing or refusing is passed over at once. Answers are
 * followed through CNAMEs. When every query's done the lookup's done, and a Resolved event says so; take_resolution
 * gives its addresses, IPv6 and IPv4 interleaved, as RFC 8305 orders them for connecting.
 *
 * The servers are configured ones (set_dns_server), or else those DHCP and routers' RDNSS options give. Answers are
 * cached for their TTL, at most CACHE_LONGEST; a name that doesn't exist, or has no address of a kind, for
 * NEGATIVE_LIFE.
 *
 * SPEC: RFC 1035 (the protocol), RFC 3596 (AAAA), RFC 2308 (negative caching), RFC 5452 (resilience against spoofing:
 *     random IDs and ports, and the question checked), RFC 8106 (RDNSS), RFC 8305 §4 (the order of addresses)
 */

/** DNS's port. */
DNS_PORT : u16 : 53
/** How many lookups run at once. */
LOOKUPS :: 8
/** How many servers are kept. */
DNS_SERVERS :: 4
/** How many names, of each kind, are cached. */
CACHE_ENTRIES :: 32
/** The longest name, in its text form without a final dot (RFC 1035 §2.3.4's 255 bytes on the wire). */
MAX_NAME :: 253
/** The most addresses a lookup gives, of both kinds together; a kind's past MAX_ANSWERS / 2 are dropped. */
MAX_ANSWERS :: 8
/** How long a query's first try waits for its answer: 1 s, doubling with each try after. */
DNS_TIMEOUT : u64 : SECOND
/** How many times a query is sent before it's failed. */
DNS_TRIES :: 4
/** The longest an answer is cached, whatever its TTL: an hour. */
CACHE_LONGEST : u64 : 3600 * SECOND
/** How long a name that doesn't exist, or has no address of a kind, is remembered as such: a minute. */
NEGATIVE_LIFE : u64 : 60 * SECOND
/** The most records of an answer looked at; past them, the rest are ignored. */
MAX_RECORDS :: 32
/** The most CNAMEs followed from a name. */
MAX_ALIASES :: 8

/** The bytes of names: a dot, the letters' ends in each case, the digits', a hyphen and an underscore. */
DOT : u8 : 46
UPPER_A : u8 : 65
UPPER_Z : u8 : 90
LOWER_A : u8 : 97
LOWER_Z : u8 : 122
DIGIT_0 : u8 : 48
DIGIT_9 : u8 : 57
HYPHEN : u8 : 45
UNDERSCORE : u8 : 95

/** DNS's types and class. */
TYPE_A : u16 : 1
TYPE_CNAME : u16 : 5
TYPE_AAAA : u16 : 28
CLASS_IN : u16 : 1

/** How a lookup ended. */
ResolveOutcome :: enum {
    /** It has addresses. */
    Found,
    /** The name doesn't exist (NXDOMAIN). */
    NoSuchName,
    /** The name exists, but has no address of the kinds asked for. */
    NoAddress,
    /** No server answered, every one failed, or there's no server. */
    Failed,
    /** The name isn't one: empty, too long, or with an empty or overlong label, or a character DNS names don't have. */
    BadName,
}

/** A lookup's result, as take_resolution gives it. */
Resolution :: struct {
    outcome : ResolveOutcome,
    /** Its addresses, the first count of them, IPv6 and IPv4 interleaved, IPv6 first. */
    addresses : IpAddress[MAX_ANSWERS],
    count : usize,
}

/** A server the resolver asks. */
DnsServer :: struct {
    active : bool,
    address : IpAddress,
    port : u16,
    /** Whether it's configured, rather than learned from DHCP or a router. */
    configured : bool,
    /** Whether a router's RDNSS option gave it, which anyone on the link can send. */
    from_router : bool,
}

/**
 * How many of the servers routers' advertisements may give: the rest are kept for DHCP's, so that one advertisement
 * naming many can't take every place.
 */
ROUTER_DNS_SERVERS :: 2

/** Where a query is. */
QueryState :: enum {
    /** Not asked: not wanted, or answered from the cache. */
    Idle,
    /** Asked, waiting for its answer. */
    Asking,
    /** Answered, or given up. */
    Done,
}

/** One kind's query of a lookup. */
Query :: struct {
    state : QueryState,
    /** Its socket, while Asking. */
    socket : u32,
    id : u16,
    /** How many times it's been sent. */
    tries : u32,
    /** The server last asked, by its index among the active ones. */
    server : usize,
    /** When it's next sent, or given up. */
    deadline : u64,
    outcome : ResolveOutcome,
    addresses : IpAddress[MAX_ANSWERS / 2],
    count : usize,
    /** The answer's lowest TTL, in nanoseconds, for the cache. */
    life : u64,
}

/** Where a lookup is. */
LookupState :: enum {
    Free,
    /** Its queries are out. */
    Asking,
    /** Done, waiting for take_resolution. */
    Done,
}

/** A lookup: a name, and its queries, IPv4's first. */
Lookup :: struct {
    state : LookupState,
    generation : u16,
    name : u8[MAX_NAME],
    name_length : usize,
    queries : Query[2],
    result : Resolution,
}

/** A name's addresses of one kind, or that it has none, cached. */
CacheEntry :: struct {
    used : bool,
    name : u8[MAX_NAME],
    name_length : usize,
    v6 : bool,
    outcome : ResolveOutcome,
    addresses : IpAddress[MAX_ANSWERS / 2],
    count : usize,
    expires : u64,
}

/** What the resolver keeps in the stack. */
Resolver :: struct {
    servers : DnsServer[DNS_SERVERS],
    lookups : Lookup[LOOKUPS],
    cache : CacheEntry[CACHE_ENTRIES],
}

/**
 * Configure a server, which the resolver asks rather than any DHCP or a router gives; servers configured are asked in
 * the order they're set.
 *
 * @param stack The stack.
 * @param address Its address.
 * @param port Its port: DNS_PORT, or another for a test's server.
 * @return False if DNS_SERVERS are configured already.
 */
set_dns_server :: fn(stack: ptr[mut Stack], address: IpAddress, port: u16) -> bool {
    // Learned ones give way
    for &server in stack.resolver.servers {
        if server.active && !server.configured {
            server.active = false
        }
    }
    return add_dns_server(stack, address, port, true)
}

/**
 * Learn a server from DHCP or a router's RDNSS option; ignored once any is configured, or if it's known. A router may
 * give ROUTER_DNS_SERVERS at most, none of them ::, loopback or multicast.
 *
 * @param stack The stack.
 * @param address Its address.
 * @param from_router Whether a router's advertisement gave it.
 */
learn_dns_server :: fn(stack: ptr[mut Stack], address: IpAddress, from_router: bool = false) {
    routers := 0
    for server in stack.resolver.servers {
        if server.active && (server.configured || same_address(server.address, address)) {
            return void
        }
        if server.active && server.from_router {
            routers += 1
        }
    }
    if from_router {
        match address {
            case V6(v6) => {
                loopback := Ipv6.{}
                loopback.bytes[15] = 1
                if is_zero_ipv6(v6) || same_ipv6(v6, loopback) || v6.bytes[0] == 0xff {
                    return void
                }
            }
            case V4(v4) => {}
        }
        if routers >= ROUTER_DNS_SERVERS {
            return void
        }
    }
    for &server in stack.resolver.servers {
        if !server.active {
            server^ = DnsServer.{active = true, address = address, port = DNS_PORT, from_router = from_router}
            return void
        }
    }
}

/** Keep a server in a free place; false if there's none. */
add_dns_server :: fn(stack: ptr[mut Stack], address: IpAddress, port: u16, configured: bool) -> bool {
    for &server in stack.resolver.servers {
        if !server.active {
            server^ = DnsServer.{active = true, address = address, port = port, configured = configured}
            return true
        }
    }
    return false
}

/**
 * Give the servers asked, in order.
 *
 * @param stack The stack.
 * @param into Where they go, as many as fit.
 * @return How many there are.
 */
dns_servers :: fn(stack: ptr[Stack], into: mut DnsServer[]) -> usize {
    count := cast[usize](0)
    for server in stack.resolver.servers {
        if server.active {
            if count < into.count {
                into[count] = server
            }
            count += 1
        }
    }
    return count
}

/**
 * Start looking up a name's addresses. A kind cached is answered from the cache; if every kind wanted is, the lookup's
 * done at once, its Resolved event queued.
 *
 * @param stack The stack.
 * @param name The name, as text: labels of letters, digits, hyphens and underscores, a final dot or not, any case.
 * @param v4 Whether its IPv4 addresses are wanted.
 * @param v6 Whether its IPv6 addresses are wanted.
 * @return The lookup's number, never 0, for take_resolution once Resolved says it's done; null if LOOKUPS are running.
 *     A name that isn't one, or neither kind wanted, is done at once, BadName or NoAddress.
 */
resolve :: fn(stack: ptr[mut Stack], name: u8[], v4: bool, v6: bool) -> u32? {
    index := cast[usize](LOOKUPS)
    for each, i in stack.resolver.lookups {
        if each.state == .Free {
            index = i
            break
        }
    }
    if index >= stack.resolver.lookups.count {
        return null
    }
    lookup :: &stack.resolver.lookups[index]
    lookup.generation += 1
    if lookup.generation == 0 {
        lookup.generation = 1
    }
    number :: (cast[u32](lookup.generation) << 16) | cast[u32](index)
    lookup.state = .Asking
    lookup.result = Resolution.{outcome = .Failed}
    lookup.queries[0] = Query.{state = .Idle}
    lookup.queries[1] = Query.{state = .Idle}
    lookup.name_length = normal_name(name, view_of(&lookup.name[0], lookup.name.count)) or_else 0
    if lookup.name_length == 0 {
        lookup.result.outcome = .BadName
        finish_lookup(stack, lookup, number)
        return number
    }
    for &query, kind in lookup.queries {
        wanted :: if kind == 0 { v4 } else { v6 }
        if !wanted {
            continue
        }
        if from_cache(stack, lookup, query, kind == 1) {
            query.state = .Done
            continue
        }
        start_query(stack, lookup, query, kind == 1)
    }
    check_lookup(stack, lookup, number)
    return number
}

/**
 * Take a done lookup's result, freeing it.
 *
 * @param stack The stack.
 * @param lookup Its number, as resolve gave it.
 * @return Its result; null if it isn't done, or isn't a lookup.
 */
take_resolution :: fn(stack: ptr[mut Stack], lookup: u32) -> Resolution? {
    found :: find_lookup(stack, lookup) or_return null
    if found.state != .Done {
        return null
    }
    found.state = .Free
    return found.result
}

/**
 * Stop a lookup, as its asker's gone; its queries' answers are ignored, and it's freed.
 *
 * @param stack The stack.
 * @param lookup Its number.
 */
cancel_resolve :: fn(stack: ptr[mut Stack], lookup: u32) {
    found :: find_lookup(stack, lookup) or_return void
    for &query in found.queries {
        stop_query(stack, query)
    }
    found.state = .Free
}

/** Find a lookup by number; null if it's free, or its number's old. */
find_lookup :: fn(stack: ptr[mut Stack], lookup: u32) -> ptr[mut Lookup]? {
    index :: cast[usize](lookup & 0xffff)
    if index >= stack.resolver.lookups.count {
        return null
    }
    found :: &stack.resolver.lookups[index]
    if found.state == .Free || cast[u32](found.generation) != lookup >> 16 {
        return null
    }
    return found
}

/**
 * Write a name in the form the resolver keeps: lower case, without a final dot, each label checked.
 *
 * @param name The name as given.
 * @param into Where it goes: MAX_NAME bytes.
 * @return Its length; null if it isn't a name.
 */
normal_name :: fn(name: u8[], into: mut u8[]) -> usize? {
    length := name.count
    if length > 0 && name[length - 1] == DOT {
        length -= 1
    }
    if length == 0 || length > MAX_NAME || length > into.count {
        return null
    }
    label := cast[usize](0)
    for i in 0..<length {
        c := name[i]
        if c == DOT {
            if label == 0 {
                return null
            }
            label = 0
        }
        else {
            if c >= UPPER_A && c <= UPPER_Z {
                c = c - UPPER_A + LOWER_A
            }
            if !((c >= LOWER_A && c <= LOWER_Z) || (c >= DIGIT_0 && c <= DIGIT_9) || c == HYPHEN || c == UNDERSCORE) {
                return null
            }
            label += 1
            if label > 63 {
                return null
            }
        }
        into[i] = c
    }
    if label == 0 {
        return null
    }
    return length
}

/**
 * Answer a query from the cache, if it holds the name's kind and it hasn't expired.
 *
 * @return True if it did, the query's outcome and addresses set.
 */
from_cache :: fn(stack: ptr[mut Stack], lookup: ptr[Lookup], query: ptr[mut Query], v6: bool) -> bool {
    name :: view_of(&lookup.name[0], lookup.name_length)
    for &entry in stack.resolver.cache {
        if !entry.used || entry.v6 != v6 || !same_name(view_of(&entry.name[0], entry.name_length), name) {
            continue
        }
        if stack.now >= entry.expires {
            entry.used = false
            return false
        }
        query.outcome = entry.outcome
        query.addresses = entry.addresses
        query.count = entry.count
        return true
    }
    return false
}

/** Cache a query's answer, in place of the entry that expires first. */
cache_answer :: fn(stack: ptr[mut Stack], lookup: ptr[Lookup], query: ptr[Query], v6: bool) {
    life :: if query.outcome == .Found { if query.life < CACHE_LONGEST { query.life } else { CACHE_LONGEST } }
        else if query.outcome == .NoSuchName || query.outcome == .NoAddress { NEGATIVE_LIFE } else { cast[u64](0) }
    if life == 0 {
        return void
    }
    name :: view_of(&lookup.name[0], lookup.name_length)
    chosen := cast[usize](0)
    soonest := ~cast[u64](0)
    for entry, i in stack.resolver.cache {
        if entry.used && entry.v6 == v6 && same_name(view_of(&entry.name[0], entry.name_length), name) {
            chosen = i
            break
        }
        expires :: if entry.used { entry.expires } else { cast[u64](0) }
        if expires < soonest {
            soonest = expires
            chosen = i
        }
    }
    if chosen >= stack.resolver.cache.count {
        return void
    }
    entry :: &stack.resolver.cache[chosen]
    entry.used = true
    entry.name = lookup.name
    entry.name_length = lookup.name_length
    entry.v6 = v6
    entry.outcome = query.outcome
    entry.addresses = query.addresses
    entry.count = query.count
    entry.expires = stack.now + life
}

/** Tell whether two names in the resolver's form are the same: they're lower case already. */
same_name :: fn(a: u8[], b: u8[]) -> bool {
    if a.count != b.count {
        return false
    }
    for byte, i in a {
        if byte != b[i] {
            return false
        }
    }
    return true
}

/** Count the active servers. */
server_count :: fn(stack: ptr[Stack]) -> usize {
    count := cast[usize](0)
    for server in stack.resolver.servers {
        if server.active {
            count += 1
        }
    }
    return count
}

/** Give the active server at an index among them, wrapped round; null if there's none. */
server_at :: fn(stack: ptr[Stack], index: usize) -> DnsServer? {
    count :: server_count(stack)
    if count == 0 {
        return null
    }
    wanted := index % count
    for server in stack.resolver.servers {
        if server.active {
            if wanted == 0 {
                return server
            }
            wanted -= 1
        }
    }
    return null
}

/** Open a query's socket and send its first try, or fail it if there's no server or socket. */
start_query :: fn(stack: ptr[mut Stack], lookup: ptr[Lookup], query: ptr[mut Query], v6: bool) {
    query.state = .Asking
    query.tries = 0
    query.server = 0
    query.count = 0
    query.life = ~cast[u64](0)
    if server_count(stack) == 0 {
        query.state = .Done
        query.outcome = .Failed
        return void
    }
    query.socket = udp_open(stack, 0) or_else 0
    if query.socket == 0 {
        query.state = .Done
        query.outcome = .Failed
        return void
    }
    match find_socket(stack, query.socket) {
        case Some(socket) => socket.resolver = true
        case None => {}
    }
    send_query(stack, lookup, query, v6)
}

/** Send a query's next try, of its server, with a new ID, and set when it's next due. */
send_query :: fn(stack: ptr[mut Stack], lookup: ptr[Lookup], query: ptr[mut Query], v6: bool) {
    server :: match server_at(stack, query.server) {
        case Some(found) => found
        // No server to ask: it fails now, rather than wait for a deadline it'd never move (13h)
        case None => {
            query.outcome = .Failed
            query.state = .Done
            return void
        }
    }
    query.id = cast[u16](next_random(stack))
    message : u8[MAX_NAME + 2 + 12 + 4]
    length :: build_query(view_of(&message[0], message.count), query.id, view_of(&lookup.name[0], lookup.name_length),
        if v6 { TYPE_AAAA } else { TYPE_A })
    _ = udp_send(stack, query.socket, server.address, server.port, view_of(&message[0], length))
    // 1, 2, 4, 8 s
    query.deadline = stack.now + (DNS_TIMEOUT << cast[u64](query.tries))
    query.tries += 1
}

/**
 * Build a query: a header asking for recursion, and one question.
 *
 * @param into Where it goes: at least the name's length plus 18 bytes.
 * @param id Its ID.
 * @param name The name, in the resolver's form.
 * @param kind TYPE_A or TYPE_AAAA.
 * @return Its length.
 */
build_query :: fn(into: mut u8[], id: u16, name: u8[], kind: u16) -> usize {
    put_u16(into, 0, id)
    // RD: recursion desired
    put_u16(into, 2, 0x0100)
    put_u16(into, 4, 1)
    put_u16(into, 6, 0)
    put_u16(into, 8, 0)
    put_u16(into, 10, 0)
    at := cast[usize](12)
    start := cast[usize](0)
    for i in 0..=name.count {
        if i == name.count || name[i] == DOT {
            put_u8(into, at, cast[u8](i - start))
            put_bytes(into, at + 1, part(name, start, i))
            at += 1 + (i - start)
            start = i + 1
        }
    }
    put_u8(into, at, 0)
    put_u16(into, at + 1, kind)
    put_u16(into, at + 3, CLASS_IN)
    return at + 5
}

/** Close a query's socket, if it has one, and leave it done. */
stop_query :: fn(stack: ptr[mut Stack], query: ptr[mut Query]) {
    if query.state == .Asking && query.socket != 0 {
        udp_close(stack, query.socket)
    }
    query.socket = 0
    if query.state == .Asking {
        query.state = .Done
    }
}

/**
 * Take a datagram to one of the resolver's sockets: an answer, if it's from the server asked and answers the query.
 *
 * @param stack The stack.
 * @param socket The socket it came to.
 * @param from Who sent it.
 * @param from_port Their port.
 * @param message The datagram's payload.
 */
dns_received :: fn(stack: ptr[mut Stack], socket: u32, from: IpAddress, from_port: u16, message: u8[]) {
    for &lookup, index in stack.resolver.lookups {
        if lookup.state != .Asking {
            continue
        }
        for &query, kind in lookup.queries {
            if query.state != .Asking || query.socket != socket {
                continue
            }
            server :: server_at(stack, query.server) or_return void
            if !same_address(server.address, from) || server.port != from_port {
                return void
            }
            v6 :: kind == 1
            if !take_answer(stack, lookup, query, v6, message) {
                return void
            }
            if query.state == .Done {
                udp_close(stack, query.socket)
                query.socket = 0
                cache_answer(stack, lookup, query, v6)
            }
            check_lookup(stack, lookup, (cast[u32](lookup.generation) << 16) | cast[u32](index))
            return void
        }
    }
}

/**
 * Read an answer to a query: its header, its question, and its records.
 *
 * @return False if it isn't the query's answer, and is ignored; true if it was taken: the query done with its
 *     outcome, or, from a server that failed or refused, sent again to the next.
 */
take_answer :: fn(stack: ptr[mut Stack], lookup: ptr[Lookup], query: ptr[mut Query], v6: bool, message: u8[]) -> bool {
    if message.count < 12 || u16_at(message, 0) != query.id {
        return false
    }
    flags :: u16_at(message, 2)
    // An answer (QR), to a standard query (opcode 0)
    if flags & 0x8000 == 0 || (flags >> 11) & 0xf != 0 || u16_at(message, 4) != 1 {
        return false
    }
    name :: view_of(&lookup.name[0], lookup.name_length)
    kind :: if v6 { TYPE_AAAA } else { TYPE_A }
    question_end :: match name_equals(message, 12, name) {
        case Some(end) => end
        case None => return false
    }
    if u16_at(message, question_end) != kind || u16_at(message, question_end + 2) != CLASS_IN {
        return false
    }
    code :: flags & 0xf
    // Truncated (TC): what fitted is taken if it has an address; otherwise it's no answer, and the next server's asked,
    // as there's no TCP to ask again by, rather than its absence be kept as no address (13h)
    truncated :: flags & 0x0200 != 0
    if truncated && code == 0 {
        read_addresses(message, question_end + 4, u16_at(message, 6), name, kind, query)
        if query.count > 0 {
            query.outcome = .Found
            query.state = .Done
            return true
        }
    }
    if code == 3 {
        query.outcome = .NoSuchName
        query.state = .Done
        return true
    }
    if code != 0 || truncated {
        // SERVFAIL, REFUSED, truncated or the like: the next server, at once, while tries are left
        if query.tries >= DNS_TRIES {
            query.outcome = .Failed
            query.state = .Done
            return true
        }
        query.server += 1
        send_query(stack, lookup, query, v6)
        return true
    }
    read_addresses(message, question_end + 4, u16_at(message, 6), name, kind, query)
    query.outcome = if query.count > 0 { ResolveOutcome.Found } else { ResolveOutcome.NoAddress }
    query.state = .Done
    return true
}

/** A record of an answer's, as read_addresses keeps it. */
Record :: struct {
    owner : usize,
    kind : u16,
    ttl : u32,
    data : usize,
    data_length : usize,
}

/**
 * Read an answer section's addresses of a kind for a name, following CNAMEs from it.
 *
 * @param message The message.
 * @param at Where the answer section starts.
 * @param count How many records it has.
 * @param name The name asked for.
 * @param kind TYPE_A or TYPE_AAAA.
 * @param query Where the addresses go, and the lowest TTL among the records followed.
 */
read_addresses :: fn(message: u8[], at: usize, count: u16, name: u8[], kind: u16, query: ptr[mut Query]) {
    records : Record[MAX_RECORDS]
    taken := cast[usize](0)
    offset := at
    for i in cast[u16](0)..<count {
        if taken >= records.count {
            break
        }
        data_at :: skip_name(message, offset) or_break
        if data_at + 10 > message.count {
            break
        }
        length :: cast[usize](u16_at(message, data_at + 8))
        if data_at + 10 + length > message.count {
            break
        }
        if u16_at(message, data_at + 2) == CLASS_IN {
            records[taken] = Record.{owner = offset, kind = u16_at(message, data_at), ttl = u32_at(message, data_at + 4),
                data = data_at + 10, data_length = length}
            taken += 1
        }
        offset = data_at + 10 + length
    }
    // The name the addresses are under: the name asked, or what its CNAMEs lead to
    target : u8[MAX_NAME]
    target_length := name.count
    put_bytes(view_of(&target[0], target.count), 0, name)
    lowest := ~cast[u32](0)
    for alias in 0..<MAX_ALIASES {
        followed := false
        for i in 0..<taken {
            if i >= records.count {
                break
            }
            record :: records[i]
            if record.kind == TYPE_CNAME && (name_equals(message, record.owner, view_of(&target[0], target_length)) is_some) {
                target_length = read_name(message, record.data, view_of(&target[0], target.count)) or_else 0
                lowest = if record.ttl < lowest { record.ttl } else { lowest }
                followed = true
                break
            }
        }
        if !followed || target_length == 0 {
            break
        }
    }
    wanted :: if kind == TYPE_A { cast[usize](4) } else { cast[usize](16) }
    for i in 0..<taken {
        if i >= records.count {
            break
        }
        record :: records[i]
        if record.kind != kind || record.data_length != wanted || query.count >= query.addresses.count
            || (name_equals(message, record.owner, view_of(&target[0], target_length)) is_none) {
            continue
        }
        slot :: query.count
        if slot < query.addresses.count {
            query.addresses[slot] = if kind == TYPE_A { IpAddress.V4(ipv4_at(message, record.data)) }
                else { IpAddress.V6(ipv6_at(message, record.data)) }
            query.count = slot + 1
        }
        lowest = if record.ttl < lowest { record.ttl } else { lowest }
    }
    query.life = if lowest == ~cast[u32](0) { cast[u64](0) } else { cast[u64](lowest) * SECOND }
}

/**
 * Tell whether a name in a message, compressed or not, is a name in the resolver's form, its letters' case aside.
 *
 * @param message The message.
 * @param at Where the name starts.
 * @param name The name to compare with.
 * @return Where the message's name ends, past its pointer if it's compressed; null if they differ, or it isn't read.
 */
name_equals :: fn(message: u8[], at: usize, name: u8[]) -> usize? {
    read : u8[MAX_NAME]
    length :: read_name(message, at, view_of(&read[0], read.count)) or_return null
    if !same_name(view_of(&read[0], length), name) {
        return null
    }
    return skip_name(message, at)
}

/**
 * Give where a name in a message ends.
 *
 * @param message The message.
 * @param at Where it starts.
 * @return Past its last label or its pointer; null if it runs past the message.
 */
skip_name :: fn(message: u8[], at: usize) -> usize? {
    offset := at
    loop {
        if offset >= message.count {
            return null
        }
        length :: message[offset]
        if length == 0 {
            return offset + 1
        }
        if length & 0xc0 == 0xc0 {
            return if offset + 2 <= message.count { offset + 2 } else { null }
        }
        if length & 0xc0 != 0 {
            return null
        }
        offset += 1 + cast[usize](length)
    }
}

/**
 * Read a name from a message, following its pointers, into the resolver's form: lower case, labels by dots.
 *
 * @param message The message.
 * @param at Where it starts.
 * @param into Where it goes: MAX_NAME bytes.
 * @return Its length; null if it's malformed, loops, runs past the message, or is longer than MAX_NAME.
 */
read_name :: fn(message: u8[], at: usize, into: mut u8[]) -> usize? {
    offset := at
    written := cast[usize](0)
    // Pointers only go back, and there are at most as many as bytes before them: a bound that ends any loop
    jumps := cast[usize](0)
    loop {
        if offset >= message.count {
            return null
        }
        length :: cast[usize](message[offset])
        if length == 0 {
            return if written > 0 { written } else { null }
        }
        if length & 0xc0 == 0xc0 {
            if offset + 1 >= message.count {
                return null
            }
            target :: ((length & 0x3f) << 8) | cast[usize](message[offset + 1])
            jumps += 1
            if target >= offset || jumps > 64 {
                return null
            }
            offset = target
            continue
        }
        if length > 63 || offset + 1 + length > message.count {
            return null
        }
        if written > 0 {
            if written >= into.count {
                return null
            }
            into[written] = DOT
            written += 1
        }
        if written + length > into.count {
            return null
        }
        for i in 0..<length {
            c := byte_at(message, offset + 1 + i)
            if c >= UPPER_A && c <= UPPER_Z {
                c = c - UPPER_A + LOWER_A
            }
            put_u8(into, written + i, c)
        }
        written += length
        offset += 1 + length
    }
}

/**
 * Finish a lookup if every query's done: its result made, its Resolved event queued.
 *
 * @param stack The stack.
 * @param lookup The lookup.
 * @param number Its number.
 */
check_lookup :: fn(stack: ptr[mut Stack], lookup: ptr[mut Lookup], number: u32) {
    for query in lookup.queries {
        if query.state == .Asking {
            return void
        }
    }
    v4 :: &lookup.queries[0]
    v6 :: &lookup.queries[1]
    result := Resolution.{}
    // IPv6 first, the families taking turns (RFC 8305 §4)
    for i in cast[usize](0)..<(MAX_ANSWERS / 2) {
        if i < v6.count && result.count < result.addresses.count {
            result.addresses[result.count] = v6.addresses[i]
            result.count += 1
        }
        if i < v4.count && result.count < result.addresses.count {
            result.addresses[result.count] = v4.addresses[i]
            result.count += 1
        }
    }
    asked :: v4.state == .Done || v6.state == .Done
    no_such :: (v4.state != .Done || v4.outcome == .NoSuchName) && (v6.state != .Done || v6.outcome == .NoSuchName)
    failed :: (v4.state == .Done && v4.outcome == .Failed) || (v6.state == .Done && v6.outcome == .Failed)
    result.outcome = if result.count > 0 { ResolveOutcome.Found } else if asked && no_such { ResolveOutcome.NoSuchName }
        else if failed { ResolveOutcome.Failed } else { ResolveOutcome.NoAddress }
    lookup.result = result
    finish_lookup(stack, lookup, number)
}

/** Leave a lookup done, and say so. */
finish_lookup :: fn(stack: ptr[mut Stack], lookup: ptr[mut Lookup], number: u32) {
    lookup.state = .Done
    event(stack, .Resolved(number))
}

/**
 * Send again each query whose answer's overdue, to the next server, or fail it once it's been sent DNS_TRIES times.
 *
 * @param stack The stack.
 */
tick_dns :: fn(stack: ptr[mut Stack]) {
    for &lookup, index in stack.resolver.lookups {
        if lookup.state != .Asking {
            continue
        }
        for &query, kind in lookup.queries {
            if query.state != .Asking || stack.now < query.deadline {
                continue
            }
            if query.tries >= DNS_TRIES {
                query.outcome = .Failed
                stop_query(stack, query)
                continue
            }
            query.server += 1
            send_query(stack, lookup, query, kind == 1)
        }
        check_lookup(stack, lookup, (cast[u32](lookup.generation) << 16) | cast[u32](index))
    }
}

/**
 * Give when the resolver next wants tick.
 *
 * @param stack The stack.
 * @return The soonest query's deadline; 0xffffffffffffffff for none.
 */
dns_deadline :: fn(stack: ptr[Stack]) -> u64 {
    soonest := ~cast[u64](0)
    for lookup in stack.resolver.lookups {
        if lookup.state != .Asking {
            continue
        }
        for query in lookup.queries {
            if query.state == .Asking && query.deadline < soonest {
                soonest = query.deadline
            }
        }
    }
    return soonest
}
