# Networking

Status: **proposed** 2026-10-24, for roadmap M13 and M14. Builds on `../decisions/0013` (capabilities don't cross
the network), `0014` (servers authorize by connection), `0037` (lending), `0043` (SSH, then a native protocol) and
`services.md`. The choices still to make are at the end and in `../open-questions.md`, *Networking*.

## 1. What Goes Wrong Elsewhere

| Problem | Where | SlopOS answer |
|---|---|---|
| Any process can open a socket to anywhere, so any program can exfiltrate data; per-app firewalls are added on top (Little Snitch, Windows Firewall rules) or all-or-nothing (Android's `INTERNET`) | Every OS | No process reaches the network without a connection to the network service, narrowed to the destinations it may use (§3) |
| Ports below 1024 need root, so servers start privileged and drop it | Unix | Listening on a port is a grant from the configuration or the powerbox (§3) |
| The TCP/IP stack runs in the kernel, so its bugs are kernel bugs (SACK Panic, CVE-2019-11477) | Linux, Windows, BSDs | A user-space stack in the network service (§2) |
| BSD sockets: blocking calls with `errno`, `EINTR`, `SIGPIPE` killing a program that writes to a closed connection, `select`'s limits, then `epoll` | POSIX | Each connection is a channel speaking a typed stream protocol; errors are values; nothing kills the writer (§4) |
| Name resolution is a blocking library call configured by global files (`resolv.conf`, `nsswitch.conf`), fought over by daemons | Linux | A resolver in the network service, configured by typed values (§5) |
| TLS libraries whose APIs make skipping verification the easy path; one global trust store | OpenSSL, `/etc/ssl` | Verification by default, skipping it a different, visible API; the trust store is a capability (§6) |
| IPv4 assumed in APIs and code; IPv6 an afterthought | BSD sockets' history | Addresses are a union of both; connecting by name tries both (Happy Eyeballs, RFC 8305) |

## 2. Processes

```
 programs ── Channel[Network] (narrowed) ──► network service ── net ──► virtio-net driver
                                              (IP, TCP, UDP, resolver)
```

- **The driver** speaks the `net` device-class protocol: frames through shared rings, the MAC address, link state,
  and offloads in `Features` (checksums first).
- **The network service** holds every `net` connection and runs the stack: Ethernet, ARP (RFC 826), IPv4 (791),
  ICMP (792), IPv6 (8200), ICMPv6 (4443), neighbour discovery (4861), SLAAC (4862), DHCPv4 (2131), UDP (768), TCP
  (9293) with SACK (2018), window scaling and timestamps (7323), and CUBIC (9438) for congestion control. One process,
  with fibers for its timers and connections.
- Its buffers for a connection are charged to the client's connection and its CPU time is lent from it (`0037`), so a
  program with many connections pays for them.

## 3. Network Authority

- **The root connection** (`Network`, unrestricted) is held by whoever the configuration says: the session manager,
  for sessions.
- **`Narrow(policy)`** returns a new `Channel[Network]` allowed only what the policy says, and only less than its
  parent:
  ```
  NetworkPolicy :: struct {
      connect : Relative[Destination],   // names or address ranges, with port ranges and transport
      listen  : Relative[ListenRule],    // addresses and ports this connection may listen on
      // later: rate and volume limits
  }
  ```
- **A program's manifest** says what it wants with a parameter (`net: Channel[Network]`), and the launcher narrows it;
  the shell asks the powerbox for anything wider than the session's default (`console-and-sessions.md` §5).
- **Names in policies** are resolved by the service when connecting, so a capability scoped to `example.com:443`
  stays scoped however the name's addresses change.
- What a program can reach is answered by its policy, without inspecting traffic.

## 4. Connections

- `Connect(destination)` answers with a `Channel[TcpStream]`; `Listen(rule)` with a `Listener[TcpStream]`; `Udp(rule)`
  with a `Channel[Datagrams]`.
- **A TCP connection** is `std`'s `Stream[u8]` (`shell.md` §4) with a shutdown and a reset: data in a shared buffer,
  backpressure through the ring. A write to a closed connection answers `Closed`.
- **`std/net`** wraps these for programs (connect by name, a listener's accept loop on fibers), on SlopOS only;
  there's no BSD socket API.

## 5. Names and Time

- **The resolver** is part of the network service: a stub resolver (RFC 1035, AAAA in 3596) with a cache, servers from
  DHCP or the configuration; queries are typed (`Resolve(name, kinds)`) and so are their answers.
- **Wall time**: the clock service (M9) gains NTP (RFC 5905) authenticated with NTS (RFC 8915), through its own narrowed
  network connection.

## 6. TLS

- TLS 1.3 (RFC 8446) only, client and server, in `std` (`std/crypto` has the primitives), with X.509 parsing for
  certificate chains.
- **The trust store is a capability**: a `ReadOnlyDir` of roots, or a connection to a trust service, given at launch;
  there's no global one.
- **Hostname verification is part of connecting**; a connection without it is a different function with a different
  name, so it can't be skipped by leaving out an option.
- Private keys of servers stay in the program that serves, which holds them as files it was given. A key-holding
  service (like `ssh-agent`) can come later.

## 7. SSH and the Native Protocol (M14)

- **The SSH server** (RFC 4251–4254) is the remote login front end (`console-and-sessions.md` §4): key exchange
  curve25519-sha256 (RFC 8731), Ed25519 host keys (RFC 8709), `chacha20-poly1305@openssh.com` and AES-256-GCM,
  public-key and password authentication through the account service. A session channel becomes a terminal in the
  terminal service through the VT adapter. `0043`'s limits apply: no interactive powerbox over SSH, and a key login
  starts with its volume locked until the password is given (`0042`).
- **The native protocol** comes later: typed values and capabilities over an authenticated channel (a Noise pattern
  is the likely basis), prompts as their own messages, and unlocking a volume from the client (`0042`).

## 8. Testing

- Hosted tests of the stack against a simulated link that drops, delays, duplicates and reorders frames, seeded so a
  failure replays; scripted packet tests in the style of packetdrill for TCP's state machine.
- QEMU user-mode networking for boot tests, a tap device for talking to the development machine.

## 9. Open Questions

- Whether `Narrow` policies are enough, or a session wants a per-program prompt the first time a program connects
  somewhere new (as Little Snitch does), through the powerbox.
- TLS in `std` (every program links it) or a TLS service holding keys and terminating connections (one
  implementation to fix, keys out of programs).
- Whether DNS resolution stays inside the network service or is a service of its own, for restarts and isolation.
