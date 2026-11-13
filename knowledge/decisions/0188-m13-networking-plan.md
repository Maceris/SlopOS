# 0188: M13, Networking, Planned

Status: accepted, chosen with the project's owner; 13a to 13h built
Date: 2026-11-10
Related: `0013` (capabilities don't cross the network), `0014` (servers authorize by connection), `0037` and `0130`
(lending), `0073` (MSIs), `0080` to `0083` (IOMMUs), `0093` (the clock service), `0165` (streams), `0170` (the shell's
grants), `0187` (Before M13), `../design/networking.md`, `../design/lessons.md` §7, `../roadmap.md` M13

## Context
Before M13 is done (`0187`), and M13 is next. `../design/networking.md` proposed its shape in 2026-10. A survey found:
- **Devices:** a modern virtio transport (`src/virtio`) with split queues of at most 64 entries in one page, chains of
  4, and one MSI-X vector a driver; `virtio_console` already keeps a receive queue offered and a transmit queue; the
  kernel gives up to 32 MSIs a device, DMA memory behind VT-d or SMMUv3, and port timers. There's no networking code,
  and `boot.py` attaches no network device (q35's default NIC, which no driver claims, aside).
- **Protocols:** block shares DMA memory with its client as a window, so the device reads and writes the client's
  buffer; no protocol shares a ring between a driver and its client. Streams (`0165`) are rings a writer makes, with
  `Ended` and a status, but no reset.
- **Services:** clients reach drivers through the supervisor's connectors; grants are wired by protocol tag; narrowing
  exists for directories (`Narrow`) and partitions; the powerbox grants files, directories, accounts, power, debugging
  and traces. No service runs on fibers yet.
- **Time:** the clock service reads the RTC at start; nothing keeps the time across boots, and no generation records
  its build time. There's no NTP.
- **Hemera's crypto** (`std/crypto`): SHA-256 and SHA-512, HMAC and HKDF over them, AES-256-GCM, ChaCha20-Poly1305,
  X25519, Ed25519, BLAKE2b, BLAKE3, Argon2id, tested against Wycheproof and for constant time. Not there: P-256, RSA,
  big integers, SHA-384, AES-128, AES-SIV, ASN.1, X.509. Hemera has no sockets on its hosted targets, and `std/net` is
  empty.

The design left three questions open (`../open-questions.md`, Networking; `networking.md` §9), and three proposals from
`lessons.md` §7 to decide now.

## Decision
Chosen with the project's owner:
- **TLS interoperates with the Internet's servers.** Hemera's `std` gains what TLS 1.3's mandatory suites and common
  certificate chains need (13d), so TLS and NTS work with real servers, not only with each other.
- **TLS is in `std`**, a library over a TCP stream, as the roadmap has it: keys stay in the program that serves, and
  every program that speaks TLS links the one implementation. A TLS service isn't built.
- **The resolver is in the network service**, which resolves names in policies at each connect anyway.
- **Authority is `Narrow(policy)` connections, and the powerbox for more.** A program is given its session's default
  network connection, or less; anything wider (listening, private ranges, loopback) is a powerbox `RequestNetwork`
  the user answers. No prompt on each new destination.

Decided by the plan, as `lessons.md` §7 proposed:
- **No loopback for local services**, which are reached through capabilities; loopback only in a policy that names it.
- **A destination by name never reaches a private, loopback or link-local address** unless the policy names that
  range, checked at each connect (DNS rebinding).
- **A floor for the wall clock**: the latest of the RTC, the time last saved, and the running generation's build time,
  so certificates are checked against a time that may be late, never decades early.

And by the plan, from the survey:
- **The network service is the first service on fibers**: one fiber a connection and one for each timer wheel, on
  Hemera's fiber pool, waiting at its port. Its stack is a package of its own (`src/net_stack`), with no system calls,
  so hosted tests drive it against a simulated link, as `frames` and `slab` are tested.
- **A connection's buffers are the client's**: `Connect`, `Listen` and `Udp` take memory the client gives for its rings,
  as the volume server's transactions do (`0089`), and the `Network` protocol lends per connection (`0037`), so a
  program with many connections pays for them.
- **Test peers run on the development machine**, reached through QEMU's user-mode network at 10.0.2.2: Python's
  servers for TCP, UDP, DNS and TLS, with a test certificate authority made for the tests; chrony on the Linux test VM
  for NTS. Nothing in the tests reaches the Internet.

Seven stages, each with an as-built record:

- **13a, virtio-net and `net`.**
  - **Transport:** queues of up to 256 entries over several pages, and a vector for each queue.
  - **The `net` protocol:** `Features` answers the MAC address, the MTU, the link's state and the offloads (checksums
    first). Frames go through two rings in DMA memory the driver makes and shares with its client as a window, as
    block's buffers are: fixed slots of 2 KiB, and `Send(slot, length)` and `Received(slot, length)` messages, so a
    frame is copied neither way. `LinkChanged` is sent as the link goes up or down.
  - **The driver** (`virtio_net`): MAC, status and checksum features; its receive slots always offered.
  - **Wiring:** a system configuration entry for virtio-net, `Speaks.Net`, and connectors for the network service.
    `boot.py` passes `-nic none` unless a test attaches a network.
  - **Tests:** a boot test with user-mode networking: the driver comes up with QEMU's MAC and the link up, and a
    test program's ARP request for 10.0.2.2 is answered.
- **13b, the network layer** (`src/net_stack`, and the network service): Ethernet, ARP (RFC 826), IPv4 (791), ICMP
  (792), DHCPv4 (2131), IPv6 (8200), ICMPv6 (4443), neighbour discovery (4861) and SLAAC (4862). Addresses are a union
  of v4 and v6 everywhere.
  - **Tests:** hosted, the stack against a simulated link that drops, delays, duplicates and reorders frames, seeded so
    a failure replays, and fuzzed packet parsing; boot, a DHCP lease and SLAAC address from QEMU, and pings answered
    both ways.
- **13c, TCP, UDP and the `Network` protocol.**
  - **TCP** (RFC 9293) with SACK (2018), window scaling and timestamps (7323), RTO (6298) and CUBIC (9438); **UDP**
    (768). Sequence numbers in wrapping arithmetic.
  - **The `Network` protocol:** `Connect(destination)` answers a `TcpStream`: a byte stream each way over `0165`'s
    rings, with shutdown and reset, a write to a closed connection answered `Closed`. `Listen(rule)` answers a listener
    whose `Accepted` messages bring streams; `Udp(rule)` answers datagrams. `Narrow(policy)` answers a connection
    allowed only less: `NetworkPolicy{connect, listen}`, destinations by address range or name, with ports and
    transport. Refusals are values.
  - **Authority:** the supervisor gives the network service's root connection to the session manager, which narrows
    one for each session (`SessionSettings`'s default: public addresses, any port, no listening); the shell gives it,
    or less, to a program whose manifest takes `net: Channel[Network]`. The powerbox gains `RequestNetwork(policy)`.
  - **`std/net`** (on SlopOS only): connect by address, a listener's accept loop on fibers.
  - **Tests:** hosted, packetdrill-style scripts of TCP's state machine, and transfers over the lossy link checked
    whole; boot, a connection to an echo server on the development machine and one from it, UDP echo, a policy's
    refusal, and throughput in `perf_tests.py`.
- **13d, crypto for TLS** (Hemera's `std/crypto`, a stage there): SHA-384 and HMAC and HKDF over it; AES-128-GCM;
  P-256 for ECDHE and ECDSA, constant time; big integers and RSA verification (PKCS#1 v1.5 and PSS); AES-SIV-CMAC
  (RFC 5297) for NTS; DER, X.509 (RFC 5280's path validation, name constraints and the extensions TLS needs) and PEM.
  - **Tests:** Wycheproof's vectors for each, the constant-time harness for P-256's and AES-128's secrets, and X.509
    chains, good and bad, from a test authority.
- **13e, names and the clock's floor.**
  - **The resolver:** a stub (RFC 1035, AAAA in 3596) with a cache; servers from DHCP or the configuration; typed
    `Resolve(name, kinds)`. Connecting by name tries both families (Happy Eyeballs, RFC 8305), and checks the rebinding
    rule at each connect.
  - **The floor:** the clock service saves the wall time every few minutes and at shutdown, and a generation records
    its build time; the clock starts at the latest of these and the RTC.
  - **Tests:** a name resolved through a DNS server on the development machine; a name answered with a private
    address refused; the floor after a boot with the RTC set back.
- **13f, TLS 1.3** (`std/tls`, client and server): RFC 8446's mandatory suites, and ChaCha20-Poly1305 and AES-256-GCM
  besides; X25519 and P-256 key exchange; ECDSA, RSA-PSS and Ed25519 signatures. **Hostname verification is part of
  connecting**; a connection without it is a function of another name. **The trust store is a capability**: a
  read-only directory of roots, given at launch; there's no global one.
  - **Tests:** hosted, RFC 8448's traces; boot, against Python's TLS server with RSA and ECDSA certificates, a wrong
    name, an expired certificate and an unknown root refused, and SlopOS's server reached from the development
    machine.
- **13g, NTP with NTS** in the clock service (RFC 5905, 8915), through its own narrowed network connection: NTS-KE over
  `std/tls`, then authenticated NTP, the clock stepped or slewed.
  - **Tests:** the clock set from chrony on the Linux test VM over NTS, and a forged answer refused.
- **13h, a security review of M13's code**, added 2026-11-12 by the project's owner, after 13f found that any program
  could crash the network service (its streams' memory mapped through a handle that didn't own it). A pass over all of
  it, looking for vulnerabilities and bugs:
  - **What's read:** the virtio-net driver; the stack (`src/net_stack`: Ethernet, ARP, IPv4 and IPv6, ICMP, neighbour
    discovery, DHCPv4, SLAAC, TCP, UDP, DNS); the network service (its protocols, policies, Happy Eyeballs, streams,
    listeners and sockets); `std/net`, `std/tls` and 13d's crypto (X.509, DER, PEM, RSA, P-256, AES-GCM); and NTS, 13g.
  - **What's looked for:** memory safety past what Hemera proves (use after free, a handle or memory another process
    can destroy, reads through rawptr and views of others' memory); anything a peer on the network can do with crafted
    packets (remote code execution, crashes, hangs, unbounded memory or CPU, state that grows without limit, SYN and
    fragment floods, amplification); anything a program can do to the service or to other programs through the
    protocols (crashing it, starving others, escaping its policy, reaching an address the rebinding rule should
    refuse, keeping resources after it's gone); DNS cache poisoning and spoofed answers; TLS's state machine (messages
    out of order, downgrades, truncation, renegotiation-like tricks, alerts), its certificate checks, and secrets in
    constant time; and integer overflow in lengths, sequence numbers and windows.
  - **Testing better:** fuzz targets for `tools/fuzz.py` (`hemera --fuzz`) where input comes from outside: frames into
    the stack, TCP segments into a connection in each state, DHCP, router advertisements and DNS answers, the
    network protocols' messages from a program, TLS records and handshake messages from a peer, DER and X.509, and
    PEM; and tests for each bug found, hosted where it can be, booted where it can't.
  - **What comes of it:** each finding fixed, or recorded with why not; a written account in this decision's As Built
    for 13h, what was read, found and fixed, and what's left.
  - **Tests:** the new fuzz targets run clean for a set time each; the new tests; and M13's full suites after it, as
    its last stage.

13d is Hemera's and needs nothing of 13a to 13c, so it may be built alongside them.

## Alternatives
- **TLS with only the modern suites** (X25519, Ed25519): no new crypto, but most public certificates couldn't be
  verified, and NTS servers couldn't be reached.
- **TLS as a service**: keys out of programs and one place to fix, but it would see every connection's plaintext and
  add a hop to each.
- **The resolver as its own service**: restarted and isolated alone, but the network service needs its answers at each
  connect, and another protocol and hop.
- **A first-use prompt** for each new destination, as Little Snitch does: one more prompt to tire of; a program that
  needs more asks the powerbox, once.
- **BSD sockets in `std`**: there's no such API in SlopOS; programs get channels and streams.

## Consequences
- Hemera's `std` gains a big-integer type and the NIST curves, with the constant-time work they need.
- The network service's fibers are the first in a service, so its waits, timers and budgets on fibers are proved there.
- A program's reach on the network is its policy, answered without looking at its traffic.
- Remote login (M14) builds on the `Network` protocol's listeners, the stack and `std/crypto`.

## As Built: 13a
- **Transport** (`src/virtio`): a queue's layout follows its size, descriptors then the driver's ring then the device's,
  and `setup_queue` takes its memory's size, sizing the queue to the largest power of two the device takes, the memory
  holds and `MAX_QUEUE_SIZE` (256) allows: one page holds 128, so the other drivers' queues, a page each, grew from 64.
  `add_chain` adds a chain without notifying, `notify` tells the device once, and `set_config_vector` routes
  configuration changes to a vector.
- **The `net` protocol** (`src/protocols/net`): as planned, with each slot's answer its own: `Receive(slot)` is held
  until a frame arrives in it, and `Send(frame)` answered `Sent(slot)` once the device has taken it, in any order, so
  no message carries a frame. `WatchLink(state)` is held until the link leaves it. A driver serves one client at a
  time, and the buffer is the driver's for its life, so a new client sees the slots the last left given. Its channels'
  ring is 16 KiB (`RING_BYTES`): every slot's request and answer fit, as a sender that doesn't watch for room would
  otherwise wait on a full ring for ever, which the network service did on the default 1 KiB.
- **The driver** (`src/drivers/virtio_net`): MAC, status, MTU and both checksum features where offered; a chain is the
  frame's 12-byte header, from a page of the driver's, then the slot, so frames sit at a slot's start. Each queue
  interrupts through a vector of its own, and configuration changes through a third. A received frame whose checksum
  the device left partial is completed in software. QEMU's user-mode network offers no checksum offloads, so those
  paths wait for a tap device to be tried.
- **The network service** (`src/services/network_service`): it dials the first NIC, says what it is, maps the buffer
  and gives every receive slot; with `test_arp=<address>` it probes that address by ARP, from 0.0.0.0. It's started
  only when there's a NIC, after the other drivers. It and the driver are boot modules, as the other drivers are.
- **`boot.py` passes `-nic none`**, so q35's default NIC and AArch64's are gone unless a test adds one; QEMU's PCI
  addresses moved up a slot, and the virtio-rng test's expected address with them.
- **Not yet:** the link going down and up (`WatchLink`) isn't tested, which needs QEMU's monitor.
- **Tests:** "drives virtio-net, and its ARP probe for the gateway is answered", on both architectures: QEMU's MAC, the
  link up, the MTU, and 10.0.2.2's answer from QEMU's gateway.

## As Built: 13b
- **`src/net_stack`**: the network layer as a state machine with no system calls: `receive` takes a frame, `tick` the
  time, and it answers with frames its caller takes (`take_frame`, into a send slot) and events (`take_event`): a lease,
  an address ready, a router found, a conflict, a ping answered. Its tables are fixed (16 neighbours of each family, 4
  global IPv6 addresses, 2 routers, 32 frames waiting), and a frame for a neighbour not yet resolved waits in its entry,
  the last one winning. Frames are read through bounds-checked helpers, so a short one reads zeroes, never past its end.
- **IPv4**: ARP, answering for the interface's address and learning who asks; IPv4 without fragments, which are dropped;
  ICMP echo both ways. **DHCPv4** with backoff from 4 s to 64 s, renewal at T1 to the server, rebinding at T2, and the
  lease lost at its end; an ACK is announced by a gratuitous ARP, and an offered address someone answers ARP for is
  declined. Its messages are 548 bytes, 576 with their headers: QEMU's user-mode DHCP server reads none shorter, and
  BOOTP's 300, which the stack first sent, went unanswered.
- **IPv6**: a link-local address and one for each autonomous /64 a router advertises, each checked for duplicates by
  one solicitation and a second's wait, with stable interface identifiers: SHA-256 over the prefix, the MAC address, a
  counter and a secret from the boot's seed (RFC 7217). Routers solicited three times; neighbour discovery answers and
  resolves; RFC 4862's two-hour rule on lifetimes; ICMPv6 echo both ways. Only hop-by-hop options among extension
  headers are passed over; multicast listener discovery isn't spoken.
- **The network service** runs it: frames received go to the stack and their slots are given again, frames it queues go
  out through free send slots, and one port timer wakes it at the stack's next deadline. Its events are logged, and with
  `test_ping` it pings each family's router once it's known. **Found:** it sent frames before handling events, so a
  ping an event started waited for the next wake, the stack's next deadline, seconds later; events go first now. Fibers
  wait for 13c, where connections need them.
- **Found in testing:** QEMU's `-netdev user,ipv6=on` alone turns IPv4 off: naming one family leaves the other off
  unless it's named too. The boot test names neither, so both are on.
- **Tests:** hosted (`net_stack_test`): a host and a router stack on a simulated link, the test playing the router's
  DHCP server and advertisements: a lease, a link-local and a global address, and pings answered over both families, on
  a clean link and over 20 seeds of a link that drops a fifth of frames, duplicates a tenth and delays each up to 50 ms;
  a lease renewed past its first term; frames made at random, as a property, taken without harm; and IPv6 text as RFC
  5952 writes it. Taking the prefix option out fails every seed. Boot, on both architectures: a lease of 10.0.2.15/24
  from QEMU, link-local and fec0::/64 addresses, its router fe80::2, and pings to 10.0.2.2 and fe80::2 answered.

## As Built: 13c
Built in four parts: TCP and UDP in the stack (13c1), the protocols and the network service serving them (13c2),
policies (13c3), and throughput (13c4).
- **TCP** (`src/net_stack/tcp.hsc`): RFC 9293's states, window scaling and timestamps, SACK and recovery by it (and by
  three duplicate acknowledgements), RFC 6298's timers, CUBIC, keyed initial sequence numbers (RFC 6528), zero-window
  probes and TIME-WAIT. A connection's send and receive rings are its caller's memory, given by address, so data is
  copied once each way. Changed connections are listed for the caller (`take_changed`), and `Incoming` and `Ended`
  events, `Ended` carrying the final totals, so a program reads what arrived before a reset. **UDP** sockets over both
  families, with an inbox of datagrams each.
- **The protocols** (Hemera's `std/os/slop_os`), as planned with these changes: `Open(to, memory)` rather than
  `Connect(destination)`, as `Connect` is every protocol's for a fresh connection; the stream is `tcp_stream`, whose
  rings are halves of memory the program gives, and whose `Watch(progress)` is held until the totals move, with
  `Wrote`, `Read`, `Finish`, `Abort` and `Describe`; a listener's `Accept(memory)` answers each stream, rather than
  `Accepted` messages it sends unasked, so the program gives each stream's memory. Datagrams' `Send` and `Receive`.
  `std/net` writes, reads, finishes, listens, accepts and sends datagrams over them, each call waiting on a port of its
  connection's own, so a program on fibers waits a fiber at a time.
- **Policies** (`std/os/slop_os/network/policy.hsc`): up to 16 rules for connecting and 16 for listening, each public
  addresses, any or a range, a family, transports and ports; plain bytes, as a message's contents must be. Names in
  rules wait for 13e's resolver. `Narrow` answers a connection allowed what both policies allow, `Copy` one allowed the
  same. **Found:** a `Connect` on a narrowed connection was served as on the listener, with everything allowed; a
  connection made through any channel but the listener now gets its sender's policy.
- **The network service** serves a client at a time per message, not on fibers, as planned: every request is answered
  at once or held as state (a stream's watch, a datagram receive, an accept) and answered from the stack's changes, so
  fibers weren't needed. A stream's memory is mapped at an address slot of its own, up to 1 MiB each.
- **Authority:** the supervisor starts the network service before the session manager, which holds its root
  connection. Each session's shell gets it narrowed to public addresses, any port, no listening, and gives copies to
  programs that take a `Channel[Network]` (`Giving.Network`); the powerbox gets it whole, and `RequestNetwork` asks on
  the trusted path, a prompt answered as a debugger's is, and narrows it to what was asked. The `connect` app sends a
  line and shows the echo, asking the powerbox when its policy refuses.
- **Throughput (13c4).** **Found:** TCP queued past the stack's 32 frames waiting, the newest dropped, so every window
  ended on the retransmission timer: 4 MiB to a peer on the development machine took 10.3 s. TCP now holds back while
  the outbox is nearly full (`outbox_full`) and goes on as frames are taken (`tcp_resume`), which the network service
  calls once it's filled the send slots; the outbox holds 64. The same 4 MiB take about 200 ms.
- **Found in testing:** QEMU's user-mode network never answers a SYN to a closed port on the host, so refusal is tested
  hosted only; system records hold 48 services (magic `SLOPSYS2`), as `test_network` made 33; the house rules' tier
  check crashed on a std package without a `PACKAGE_TIER`, and reports it now.
- **Tests:** hosted (`net_stack_test`), two stacks over the simulated link: 200 KB each way over both families, clean
  and over ten lossy seeds, checked whole; refusal, a timeout, a reset, a closed window, a SYN-ACK's options,
  datagrams; and one data segment dropped, sent again on duplicate acknowledgements and never on the timer, 500 KB
  arriving whole. Packetdrill-style scripts weren't written: the paired stacks over a faulty link took their place.
  `network_policy` (Hemera's hosted tests): public addresses, what a policy allows, and narrowing. Boot, on both
  architectures (`test_network`, with `--network-peers`): TCP and UDP echo off peers on the development machine, one
  connection in through QEMU's forward, and `connect` to private 10.0.2.2 refused on Escape and echoed once allowed on
  Enter. `perf_tests.py` reports 4 MiB's sending in wall time only, as it runs in the host's time.

## As Built: 13d
In Hemera's `std/crypto`, Freestanding, nothing allocated; secrets `#secret` and their functions `#constant_time`.
- **SHA-384**, and HMAC and HKDF over it: SHA-512 from its own words, a type of its own (`Sha384`).
- **AES-128-GCM**: AES's core became an `AesKey` of 10 or 14 rounds, AES-NI or bitsliced, which AES-256-GCM, AES-128-GCM
  and AES-SIV share; AES-256-GCM's API is unchanged.
- **AES-SIV-CMAC** (RFC 5297), 256 and 512 (AES-192's 384 isn't there): associated data and an optional nonce, which is
  RFC 5297's two forms and what NTS's AEAD_AES_SIV_CMAC_256 uses, not its general list of strings, since Hemera's
  escape checks refuse a list of views into a caller's stack. A refused message's plaintext is zeroed, as SIV decrypts
  before it can check.
- **P-256**: Montgomery arithmetic on four 64-bit limbs, Renes–Costello–Batina's complete formulas, a 4-bit window read
  from every table entry with `intrinsics.select`; ctgrind caught LLVM turning a mask of ands and ors into a branch,
  hence `select`. ECDH, key generation, and ECDSA signing with RFC 6979's nonce (random bytes mixed in when given) and
  verifying. Public keys uncompressed or compressed, checked on the curve.
- **P-384 ECDSA verification**, beyond the plan: Let's Encrypt's ECDSA intermediates and ISRG Root X2 are P-384 keys
  signing with ecdsa-with-SHA384, so without it common chains fail. Verifying only, on the big-integer type.
- **Big integers and RSA**: `BigNumber`, up to 8192 bits in place, public and variable time, Montgomery modulo an odd
  number; PKCS #1 v1.5 (the expected encoding built and compared whole, so a DigestInfo without its NULL is refused)
  and PSS with MGF1 over the same hash, SHA-256/384/512. No RSA signing or decryption.
- **DER, X.509, PEM**: DER read strictly; each element a view with what follows it (a reader struct's views couldn't
  be returned past the escape checks). `x509_verify_chain(chain, anchors, now, purpose)` takes a chain and the anchors
  each as DER certificates one after another, builds paths depth first (order and extra certificates don't matter),
  and checks signatures (RSA ≥ 2048 bits, P-256, P-384, Ed25519), validity, basic constraints, key usage, path lengths,
  extended key usage (the leaf's and any CA's that has one), name constraints on DNS names, IP addresses, email
  addresses and directory names, and that every critical extension is understood; it answers an `X509Verdict` naming
  the reason. `x509_matches_host` matches a leaf to a host name (wildcards in the first label) or IP address; the
  common name isn't used. `pem_certificates` turns a PEM file into the DER list the anchors are. Names are compared
  byte for byte; policies aren't processed; there's no revocation.
- **Tests:** `wycheproof_tls`, Wycheproof's vectors: HMAC/HKDF-SHA384, AES-128-GCM (AES-NI and software), both AES-SIV
  files (both paths), P-256 ECDH (raw points and SubjectPublicKeyInfo) and ECDSA (P1363 and DER), P-384 ECDSA, RSA
  PKCS #1 v1.5 and PSS at 2048 to 4096 bits; about 8,000 cases. `x509`, chains from a test authority its
  `make_certificates.py` makes with Python's cryptography: good ones (RSA, RSA-PSS, P-256, P-384, Ed25519, out of
  order) and one bad chain for each verdict, host names, base64, DER times. `curves` gains RFC 6979's signatures and
  ECDH agreement; `hashes` SHA-384's known answers; `ctgrind` P-256 (keys, ECDH, signing), AES-128-GCM, AES-SIV and
  SHA-384 under Valgrind, clean. HemeraTest Release 195 of 195; the Linux tests 63 of 63 on x86-64 and 61 of 61 on
  AArch64.
- **For the owner:** P-384 verification was added (above). Anchors are checked as if in the path, so an expired root
  or one whose constraints don't allow the chain refuses it; a version 1 anchor is taken to be a CA. RSA keys under
  2048 bits are refused in certificates. A chain is DER certificates one after another, so 13f's TLS copies a
  Certificate message's entries together before validating.

## As Built: 13e
Built in two parts: names (13e1) and the clock's floor (13e2).
- **The resolver** (`src/net_stack/dns.hsc`), in the stack as planned and so tested hosted: a stub resolver over the
  stack's own UDP, a query for each kind (A, AAAA) from a socket of its own on a random port with a random ID, whose
  datagrams go to it rather than the inbox; an answer counts only from the server asked, with the query's ID and its
  question (RFC 5452). A query unanswered is asked again of the next server, its wait doubling from 1 s, four tries;
  SERVFAIL and REFUSED pass to the next server at once. CNAMEs are followed, eight deep. Answers are cached for their
  TTL, an hour at most; a name that doesn't exist, or has no address of a kind, for a minute (RFC 2308). Results come
  IPv6 first, the families taking turns (RFC 8305 §4). Servers are configured, or learned from DHCP's option 6 and
  routers' RDNSS options (RFC 8106), which the plan didn't name; configured ones take their place. Names are checked as
  labels of letters, digits, hyphens and underscores; literal addresses aren't parsed, as Open takes them.
- **The protocol** (Hemera's `std/os/slop_os/network`): `Resolve(name, kinds)` answered `Resolved` with up to 8
  addresses, and `OpenName(name, port, memory)` answered `Opened` once resolved, or `Refused` with the resolver's
  outcome (`NoSuchName`, `NoAddress`, `ResolveFailed`, `BadName`). Resolving needs a policy that connects somewhere, so
  a program allowed nothing can't send its secrets out in queries. `std/net` gains `resolve`, `open_name` and
  `describe`. **Policies by name**: a rule may name a host, or `*.domain` for the names under it, up to 63 bytes, which
  allows connecting by that name; rules grew, so the protocol's ring is 8 KiB. **The rebinding rule** (`allows_named`):
  an address a name resolved to that isn't public is reached only through a range rule covering it, whatever else the
  policy allows, everything included; a public one through any rule covering it, or a rule naming the host.
- **Happy Eyeballs** in the network service (`names.hsc`): OpenName's stream is answered once resolved, its addresses
  those the policy allows, tried IPv6 first, the next started every 250 ms while none has connected, up to four at once,
  every attempt over the stream's own rings, as no byte moves before a connection's established; the first to connect
  is the stream's and the others are aborted, one that fails starts the next at once, and the last to fail ends it.
- **The clock's floor** (13e2): a generation's record keeps when it was built (`built`, seconds since 1970, in what had
  been padding, so its layout is unchanged and older records read 0), set by the generation builder; the bootloader adds
  `built=<seconds>` to the kernel's command line, and the clock service starts no earlier. The time's kept in the system
  volume's `clock` directory, which the supervisor gives the clock through `clock_setting`'s new `Keep` once the volume's
  there (and again if either restarts): the time saved there is read, the clock set forward to it if it's behind, and it's
  saved then, every five minutes, after each `Set` and as the service stops, as its seconds in decimal, so a torn write
  reads as none. A real-time clock behind the floor is set forward too.
- **Found:** `boot.py` gave every boot of a test the same QEMU arguments, so a test of the saved time couldn't set the
  real-time clock differently in each; `--boot-qemu-argument=<boot>:<argument>` does, and `--expect-boot-line-start`
  checks a later boot's line by its start.
- **Tests:** hosted (`net_stack_test`'s `dns_test`): names of both kinds, a CNAME, case and a final dot, IPv4 only, a name
  that doesn't exist, a server that fails, bad names; the cache and its expiry; a forged answer ignored; a silent server
  passed over; the servers learned from DHCP and RDNSS; ten lossy seeds; and names read from random bytes. Hemera's
  `network_policy`: names matched, names reaching public addresses only, narrowing to names. Boot, on both
  architectures: `test_network` with a DNS peer on the development machine (`{dns}`), `peer.slopos.test` resolved IPv6
  first, reached by name at 10.0.2.2 after QEMU never connects its IPv6 address, refused through a public-only
  connection, and a missing name; and the floor, the first boot's real-time clock in 2030 saved, the second's in 2001
  starting at the build time and going forward to 2030.

## As Built: 13f
Built in three parts: TLS 1.3 in Hemera's `std/tls` (13f1, 13f2) and its use on SlopOS (13f3).
- **`std/tls`**, Freestanding: a `Connection` is a state machine its caller feeds what arrives (`received`) and takes
  what to send from (`output`, `sent`); nothing in it waits, allocates or makes a system call, so it's tested in
  memory and runs over SlopOS's TCP alike. Some 300 KiB, so on the heap. The suites TLS_AES_128_GCM_SHA256,
  TLS_AES_256_GCM_SHA384 and TLS_CHACHA20_POLY1305_SHA256; X25519 and P-256 with HelloRetryRequest; signatures ECDSA
  on P-256 and P-384, RSA-PSS (and PKCS #1 in certificates) and Ed25519, of which a server signs with P-256 or
  Ed25519. KeyUpdate both ways, close_notify, compatibility mode's ChangeCipherSpec. **Verification is part of
  connecting**: `client(connection, host, anchors, now)` checks the chain with 13d's `x509_verify_chain` and the leaf
  with `x509_matches_host`, refusing with the alert for the verdict (bad_certificate, certificate_expired, unknown_ca,
  ...); `client_unverified` is the function of another name. No resumption, no 0-RTT, no client certificates (a client
  asked for one sends none). A server takes an `Identity` (`identity_of(kind, chain, key)`), and a suite or group to
  insist on, for tests. A server whose identity has no chain ends with internal_error rather than send an empty
  Certificate, which OpenSSL refuses (`LENGTH_MISMATCH`), as the boot test found.
- **`std/net`'s TLS** (`tls_stream.hsc`, SlopOS only): `connect_tls(network, host, port, anchors)` connects by name
  (or an IPv4 address's text) and runs the handshake to its end; `accept_tls(listener, identity)` serves one;
  `read_tls`, `write_tls`, `close_tls`, which waits until the peer's acknowledged everything before closing the TCP
  connection, as closing one that hasn't ended resets it and could lose the close_notify. A failure is a `TlsFailure`:
  the TCP connection's, or the alert, the certificate's verdict and whether the name was wrong.
- **The trust store is a capability**, as planned: `load_anchors(trust)` reads every file of a read-only directory,
  PEM (each CERTIFICATE) or DER, into anchors, up to 256 KiB of them. The system volume's `trust` directory is it; the
  supervisor narrows it to a `read_only_dir` (`trust_store`) and gives it to programs that take one, test_network for
  now, and records it as served by the supervisor so the system records check. The boot disk's holds the test root.
- **Found, the network service:** a stream's rings were the program's memory mapped into the service, through a
  duplicate handle, which doesn't own the memory (`0054`): a program that closed its stream with data still to send
  destroyed the memory, and the service faulted resending from it, so any program could crash the network. The stack
  now copies to and from a stream's memory through the kernel (`memory_read`, `memory_write`), as stream readers do
  (`0165`), and nothing's mapped: a copy that fails resets that connection only. A copy is a system call per segment,
  which costs nothing measurable: `tcp_send_4mib` took 264 ms on x86-64 and 688 ms on AArch64, against 282 ms and
  750 ms mapped, wall time on the same host.
- **Tests:** hosted (Hemera's `tls` scenario, 9 tests): RFC 8448's Simple 1-RTT Handshake replayed as a client, every
  secret, record and the application data matching (its 1024-bit RSA key let through by a flag only the replay sets,
  as 13d refuses keys under 2048 bits), and as a server up to its ServerHello; a client and a server in memory over each
  suite, Ed25519, a HelloRetryRequest, data both ways, KeyUpdate and close_notify; chains refused as expired, for
  another name, from an unknown root and signed by another key; a changed record refused; a server without a chain;
  and random bytes. Boot, on both architectures, from a disk (the trust store's on the system volume): boot.py serves a
  TLS 1.3 echo choosing its certificate by SNI from `tools/tls_peers`' test authority (`make_authority.py`, Python's
  cryptography): test_network reaches `rsa.slopos.test` and `ecdsa.slopos.test` by name, their chains checked against
  the trust store and their echoes whole, and refuses `wrong.slopos.test` (alert 42), `expired.slopos.test` (45) and
  `stranger.slopos.test` (48); then serves TLS on port 443 as `machine.slopos.test`, which boot.py's Python client
  verifies against the root, its echo checked, closing with close_notify both ways.
- **For the owner:** Python's ssl (OpenSSL 3.0) refused the test authority's certificates without key identifiers
  (Authority and Subject Key Identifier), so `make_authority.py` adds them; `std/crypto` doesn't need them. The service
  copying rather than mapping is a change to 13c's design, made here for the crash.

## As Built: 13g
- **`std/tls`** gained what NTS-KE needs: ALPN (RFC 7301), offered by a client (`client(..., protocol)`) and chosen by a
  server, which refuses a client offering only others with no_application_protocol; a client refuses an answer it
  didn't offer or doesn't match; `protocol_agreed` says whether they did. And the exporter (RFC 8446 §7.5,
  `export_keying_material`), from exporter_master_secret, checked against RFC 8448's. It exports after a clean close
  too, close_notify either way, as NTS-KE servers close once they've answered, but not after a failed handshake.
- **`std/ntp`**, Freestanding: NTP's header and 32.32 timestamps, an exchange's offset and delay (RFC 5905 §8), and NTS
  (RFC 8915): NTS-KE's records, asked for and read, with NTPv4 and AES-SIV-CMAC-256 or nothing; the keys exported; and
  requests with a unique identifier, the last cookie, placeholders asking for enough to have 8 again, and an
  authenticator sealing the header and fields; an answer is checked against its request's origin and identifier, then
  opened with the server's key, its new cookies kept. A NAK, which may come unauthenticated, is told apart.
- **`std/net`** (SlopOS): `nts_establish` (NTS-KE over a TLS stream offering `ntske/1`) and `nts_query`, which keeps
  waiting until its deadline past forged answers and NAKs, as anyone can send one ahead of the server's, and says which
  it had. `receive_from` takes a deadline.
- **The clock service** keeps the time from an NTS server once the supervisor's `Synchronize` gives it a name, a
  connection to the network service and the trust store: every 1024 s it takes keys if it has no cookies, then 4
  samples, keeping the one with the least delay; an offset of 128 ms or more is stepped (the real-time clock with it),
  a smaller one slewed, 0.5 ms a second, by publishing the clock page again. A failure is logged and tried again after
  2 s, doubling to 64 s.
- **The supervisor** gives it from the kernel's command line: `nts=<name>[:<port>]`, through a connection narrowed to
  TCP to public addresses on the NTS-KE port and UDP to public addresses, and `nts_range=<address>/<bits>` besides,
  for a test's server on a private network.
- **Found, a deadlock:** the supervisor first gave the clock its connection right after launching the network service,
  which dials its NIC through a connector only the supervisor's loop answers, while the supervisor waited on the
  network service. It's given once the NIC's been dialed. **Found, the clock's time:** the clock service had its page as
  the grant `clock_page`, so the runtime, which reads the time from the grant `clock`, couldn't: `time.now` failed
  there, and TLS checked certificates against 1970. It's `clock` now, mapped read-only by the runtime as everywhere.
- **Tests:** hosted (Hemera's `ntp` scenario, 5 tests: timestamps and samples; NTS-KE records; requests and answers,
  the server played with known keys, forged, NAKed and others' answers told apart; no request without a cookie; random
  bytes), and the `tls` scenario's ALPN and exporter. Boot, on both architectures: chrony 4.6.1 on the Linux test VM,
  started by boot.py (`--nts-server`) as `nts.slopos.test` with the test authority's certificate, unprivileged and
  setting no clock, serves its own clock; the machine's real-time clock is set to 2026-01-01, so the clock is behind,
  takes keys and 8 cookies, and is stepped to chrony's time. test_network does NTS-KE with boot.py's forging server,
  which gives keys honestly but can't seal its answers, and refuses them as forged.
- **For the owner:** chrony has to be installed on the test VM (`apt install chrony`). Debian's AppArmor profile for
  `/usr/sbin/chronyd` won't let it read a configuration in a home directory, so boot.py runs a copy of it. A UDP send a
  connection's policy refuses is dropped without an error, as a firewall drops it, which first hid that test_network's
  connection allowed only TCP.

## As Built: 13h
A review of M13's code, in six parts read side by side: the virtio-net driver and the stack's link and IP layers; TCP;
DNS and the policies by name; the network service; TLS, TLS streams and NTS; and 13d's crypto. Each finding was traced
end to end before it was taken. **No memory-safety bug was found**: every read of a packet goes through checked
accessors or proven slices, and 13f's fix for streams' memory holds everywhere a ring is touched. What was found was
availability and protocol bugs, two of them critical, and weak randomness.

**Fixed, the network service:**
- **Critical: any program could freeze the service** by not reading its answers: `os.send` waited, on the service's
  only port, while the program's ring was full. std's `send` and every generated `send_<side>` and `answer_unsupported`
  now take `wait`; the service answers without waiting, and a channel an answer can't be sent on is let go once its
  serving's done (`answered`, `drop_broken`), as if its program had closed it.
- **Critical: paged memory as a stream's** had the service's one thread wait on the program's pager in `memory_read`.
  `take_memory` writes nothing to it first, which the kernel refuses for paged, boot-module and unwritable memory.
- **A failed send leaked the handles it carried**, so a stream or listener could outlive everything: `send` closes
  handles it couldn't send.
- **Extra handles in a valid message stayed in the receiver's table**, for any SlopOS service: the generated validators
  now refuse a message unless each handle it carries is named by exactly one of its fields (`index_takes`,
  `every_handle_named`).
- **One channel could take every shared resource**: streams, listeners, sockets and lookups. Each network channel is
  charged for what's made through it: 16 streams, 4 listeners, 4 sockets, 2 lookups. By channel, not by program, as
  the session manager hands every session and program a Narrow or Copy of one connection, and channels can be passed
  on: charging by the connection the supervisor gave was tried first, and left the powerbox unable to grant a second
  program. The listener is a flag, not "index 0".
- **A UDP socket needed no policy**, and took the resolver's sockets: an ephemeral one needs a connect rule allowing
  UDP, and the stack has 32 sockets to the service's 16.
- **Resolving was a way out past any policy**: `allows_resolve(policy, name)` allows a name only under a public or
  any rule, or a name rule covering it.
- **A listener's waiting connections that had ended spent Accepts**, unanswered: they're taken off as they end, an
  Accept whose connection's gone keeps its memory, and a consumed Accept is always answered.
- Narrow could widen into special /24s within a public /16: a range is public only if no RFC 6890 range overlaps it
  (`is_public_range`); 2001::/23 and 2002::/16 aren't public. Describe checks its connection's generation.
- **A dropped event** (the stack's queue full) stranded a lookup or a stream: a quarter of the queue is kept from
  Incoming and EchoReplied, what a peer makes at will, and a dropped event has the service look again (`catch_up`).

**Fixed, the stack:**
- **High: its random numbers could be predicted**: DNS's IDs and ports, TCP's ports and DHCP's transaction IDs came
  from xorshift64* seeded with 64 bits, a few outputs giving its state away. It's ChaCha20's keystream under a 32-byte
  key from the system's generator now. **High: TCP's initial sequence numbers** hashed the secret with FNV-1a, which
  left 32 bits of it: BLAKE2b now, of the secret and the connection's addresses and ports (RFC 6528).
- **An expired SLAAC address spun the service** for ever, its deadline in the past (and a first assignment never
  expired): addresses keep their lifetime, and are let go when it ends (`AddressExpired`).
- Spoofed pings could hold every neighbour entry resolving, and push out the router's: a new entry takes the one
  resolved longest, or the one asked for most, never a default router's.
- A router lifetime of 0 removes the router; an RA gives at most 2 DNS servers, none ::, loopback or multicast.
- Packets from broadcast, multicast, loopback or the interface's own address are dropped, so nothing's answered to
  them.
- TCP: a backlog of 8 per listener, and 8 entries kept from incoming connections; a SYN-ACK sent 3 times, not 6; the
  oldest TIME-WAIT reused when the table's full; FIN-WAIT-2 let go after 60 s with nothing from the peer; an
  acknowledgement of what wasn't sent, or older than the peer's largest window, drops its segment (RFC 5961 §5); a
  segment at a closed window still has its ACK taken; a FIN sent before a timeout is still counted as sent; a zero
  window is probed for as long as the peer answers; a SYN-ACK has a window scale only if the SYN did; an MSS under 88
  is raised to it.
- DNS: a truncated answer without an address asks the next server; a query with no server fails rather than waits.
- One socket's datagrams take at most 8 of the 32 waiting; DHCP's retry jitter can't land before now.
- virtio-net: a received length out of range is answered as an empty frame, so its slot isn't lost; a used element
  naming a descriptor that isn't an outstanding chain's head is passed over.

**Fixed, std's TLS, NTS and crypto:**
- **High: chain building took factorial time**: a hostile server's nine CAs of one name and key, each able to issue the
  others, would hold a client for hours. The search has a budget of 64 steps and 64 signature checks, each pair
  checked once, past which it's TOO_COMPLEX.
- A wildcard SAN reaching a name in an excluded subtree is refused; an RSA exponent over 2^32 is refused; P-384's
  check for the point at infinity read an unnormalized count.
- **The clock could be stepped anywhere** by a server it trusts: never below its floor now (the build time or the time
  saved), not by more than 1000 s once synchronized, and from at least 2 samples within 500 ms, so one who delays the
  answers without the keys moves it by 250 ms at most.
- **A silent NTS-KE server hung the clock service**: TCP connections and TLS streams take a deadline, and NTS-KE has
  10 s.
- A host name past 255 bytes is refused rather than matched cut short; a server whose ECDSA signature fails ends the
  handshake rather than send zeros; a connection's secrets are zeroed before its memory's freed (`tls.forget`);
  NTS-KE's Server record has to be a host's text, its Port record not 0.

**Recorded, not fixed:**
- Every SlopOS service but the network's still waits on clients as it answers; `wait = false` is there for each to
  take up. The network driver's requests wait, but the driver's trusted.
- The network service's 16 channels can all be taken by one program, by Copy, Narrow, or Connecting both ends of a
  pair it made, which nothing frees while it lives. The protocol's lending (a connection's resources charged to the
  budget its program gives) is the way to bound it, not yet built.
- A listener takes connections from any peer, as listen rules name ports and not peers; whether incoming peers should
  meet the connect rules is the policy's design, left as it is.
- Happy Eyeballs' attempts share the stream's rings: two that connect in one round could both deliver into it before
  the loser's aborted. The service should hold back delivery until the race is won.
- "Public" includes the local network's own global IPv6 addresses (and a publicly numbered IPv4 network's), so a
  public-only policy reaches the LAN by such addresses, by name too; the service would need the on-link prefixes.
- Routers: an RA's addresses are kept first come, an RDNSS lifetime isn't honoured, and on-link is the address's /64,
  not the prefix's L flag. DHCP's ACK and NAK aren't checked against the offer. Frames are parsed in the NIC's shared
  memory, so a hostile device could change them as they're read (reads stay within bounds).
- TCP has no keepalive, so an established connection whose peer vanishes lasts until its program ends it; challenge
  ACKs and resets aren't rate limited; an exact RST ends TIME-WAIT (RFC 1337).
- The DNS cache is shared, so a program can tell whether a name was looked up lately.
- TLS: no KeyUpdate after AES-GCM's record limit; ChangeCipherSpec taken anywhere before the handshake ends; unknown
  extensions in EncryptedExtensions ignored; a second ClientHello not compared with the first; test-only setups
  (`client_after_hello`, `server_with_keys`) are ordinary functions.
- X.509: rfc822Name constraints aren't applied to a subject's emailAddress, nor IPv4 constraints to IPv4-mapped IPv6;
  PEM stops quietly at a block without its END; Ed25519's small-order keys are taken, as RFC 8032 allows.

**Tests:** hosted, on Hemera's side: the tls scenario's changed flight (any byte flipped, the flight cut or added to,
fed in any pieces) never connects, but for the ServerHello record's legacy_record_version, which RFC 8446 has ignored
and which its first run found; NTS-KE responses of drawn records read within bounds; DER walked from any bytes, a
chain with any byte changed never valid, PEM from any text; policies, a narrowed one never reaching what its parent
can't (whose first run found that "by name" has to allow for the rebinding rule), and special ranges in public ones;
chains made to be slow, and wildcards under exclusions, refused. On SlopOS's: frames of every kind with their
checksums right, over hours, the stack's next deadline always ahead after a tick (which found an expired address's
deadline left behind a tick); a hostile peer's segments into a live connection; answers of any bytes to a lookup's
queries; a SYN flood held to the backlog; a quiet FIN-WAIT-2 let go; the validators' handle rule, with the network's
protocols now among those fuzzed. Each fuzz target (`tools/fuzz.py`, which finds Hemera's scenarios too, as
`hemera:<path>`) ran clean for 60 s.
