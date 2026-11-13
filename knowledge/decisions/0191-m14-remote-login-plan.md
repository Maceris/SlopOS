# 0191: M14, Remote Login, Planned

Status: accepted, chosen with the project's owner; 14a and 14b built
Date: 2026-11-13
Related: `0016` (users and encryption), `0018` (the powerbox), `0042` (unlocking), `0043` (the trusted path and remote
login), `0136` to `0161` (M10's console, accounts and sessions), `0188` (M13, its 13h review's way of working),
`../design/console-and-sessions.md`, `../design/networking.md` §7, `../roadmap.md` M14

## Context
M13 is done, and M14 is next. `0043` decided SSH first and a native protocol later; `0042` that a key login over SSH
can't unwrap a home volume, so its session starts with the home locked until the password is given once. A survey
found:
- **Crypto** (`std/crypto`): X25519, Ed25519, ChaCha20-Poly1305 (RFC 8439's, with ChaCha20's blocks and Poly1305 under
  it), AES-256-GCM, SHA-256 and SHA-512, HMAC, P-256 and RSA verification, all constant time where secrets are. Not
  there: ML-KEM, OpenSSH's `chacha20-poly1305@openssh.com` construction, and OpenSSH's key formats.
- **Clients to test with:** OpenSSH 10.0 on the development machine and on the Linux test VM (which has `sshd`). OpenSSH
  10 prefers the post-quantum hybrid `mlkem768x25519-sha256`, and still takes `curve25519-sha256`.
- **Accounts:** the account service checks passwords and opens home volumes (`OpenHome`); it keeps no public keys yet,
  though `0042` says its database holds them.
- **Terminals:** the terminal service is the console: one screen model (`src/screen`), sessions as views of it, the VT
  adapter (`src/vt`) for the serial line, and the trusted path (status line, secure attention key) built in.
- **Sessions:** the session manager's `Start` takes whatever terminal channel a front end gives it, and the home.
- **Network:** listening on a port is a grant (`0188`); TCP streams and TLS are in `std/net`. Hemera's hosted targets
  have no sockets.

## Decision
Chosen with the project's owner:
- **An SSH server and an SSH client.** The server is remote login's front end; the client is a SlopOS program, `ssh`,
  and lets `std/ssh` be tested client against server in memory, as `std/tls` is. **The native protocol waits** until
  after M15 and M16.
- **The SSH service serves each session's terminal itself**, over the terminal protocol, from the libraries the
  terminal service uses (`src/screen`, `src/vt`), sized as the client says. The console's trusted path stays the
  console's alone: over SSH there is none (`0043`).
- **Key exchange: `mlkem768x25519-sha256` and `curve25519-sha256`.** The hybrid needs ML-KEM-768 (FIPS 203) in
  `std/crypto`; it protects recorded sessions against later quantum decryption, and is what OpenSSH picks.
- **SFTP, and scp over it.** No port forwarding, no agent forwarding.

Proposed, for the stages to settle as they're built:
- **Algorithms:** host keys `ssh-ed25519`; users' keys `ssh-ed25519`, `ecdsa-sha2-nistp256` and `rsa-sha2-256`/`512`
  verified (the client signs with Ed25519); ciphers `chacha20-poly1305@openssh.com` and `aes256-gcm@openssh.com`, AEADs
  only, so no MACs; no compression. **Strict key exchange** (`kex-strict-*-v00@openssh.com`) against Terrapin, required
  of a peer that offers it; `ext-info` with `server-sig-algs`; rekeying after 1 GiB or an hour.
- **`std/ssh`**, Freestanding, a state machine its caller feeds and drains, as `std/tls` is: the transport (RFC 4253),
  authentication (4252) and connection (4254) protocols, both roles; channels for sessions (`pty-req`, `shell`,
  `exec`, `subsystem`, `window-change`, `signal`, `exit-status`).
- **Authentication through the account service:** a password opens the home as console login does; a public key is
  checked against the account's keys, the SSH service verifying the signature over the session's hash, as a front end
  trusted with passwords is. Keys are the account's, added and removed by its user from a session (a `keys` program),
  in OpenSSH's `authorized_keys` line form.
- **A key login** gets the home if it's unlocked (`0042`: it is from the first login until shutdown), or else a session
  with the home locked and an `unlock` program that asks for the password over the channel.
- **The host key**, Ed25519, is made the first time the SSH service starts, kept on the system volume, and its
  fingerprint shown on the console's secure attention screen, so a user can check it before trusting it.
- **The SSH service runs only when the system configuration enables it,** with a listen grant for its port (22 by
  default). Before authentication: at most 10 connections, 3 from one address, 30 s to authenticate, 6 tries, and the
  account service's rate limits.
- **Remote sessions' powerbox** answers nothing interactively: grants are configured ahead of time (`0043`).
- **SFTP** (version 3, as OpenSSH speaks it) is a program the session runs with only the home, confined as any program
  is; scp is OpenSSH 9's, over SFTP. The old scp protocol isn't served.
- **The client** keeps its key and known hosts in the user's home, asks on the terminal the first time it meets a host
  key, and refuses one that's changed. A destination outside the session's network policy is asked of the powerbox.

In seven stages:
- **14a, crypto for SSH** in Hemera's `std`: ML-KEM-768 (FIPS 203), constant time, tested against NIST's ACVP vectors
  and others with known answers; `chacha20-poly1305@openssh.com`; OpenSSH's public key, `authorized_keys` and
  unencrypted `openssh-key-v1` private key formats.
- **14b, `std/ssh`**: transport, both key exchanges, strict key exchange, authentication, channels and rekeying, client
  and server. Tests: hosted, a client and a server in memory, every algorithm, refused and damaged messages, and a
  rekey mid-transfer; against OpenSSH, its client with a `ProxyCommand` running a hosted Hemera server over its
  standard input and output, and a hosted Hemera client talking to `sshd -i` the same way, on the Linux test VM; fuzz
  targets for packets and messages from a peer.
- **14c, keys**: the account service keeps each account's public keys, the `keys` program manages them, and the host
  key is made, kept and shown.
- **14d, the SSH service**: listening when enabled, its limits, authentication through the account service, sessions
  through the session manager with a terminal it serves, `exec`, exit statuses, locked homes and `unlock`. Boot tests
  with the development machine's OpenSSH through QEMU's forwarded port: a password login, a key login, a command run,
  an interactive shell, wrong credentials refused, a locked home unlocked.
- **14e, SFTP and scp**: the SFTP program and the subsystem. Boot tests with OpenSSH's `sftp` and `scp`.
- **14f, the client**: `ssh` and `ssh_keygen` on SlopOS, known hosts, the powerbox for a destination. Boot test: SlopOS's
  client logs in to the Linux test VM's `sshd` and runs a command.
- **14g, a security review of M14's code**, as 13h was for M13: the new crypto, `std/ssh`, the SSH service, SFTP and
  the client, read for what a peer or a program can do; fuzz targets run for a set time; findings fixed or recorded;
  then M14's full suites.

## Alternatives
- **The SSH server only:** smaller, but no way to reach another machine from SlopOS, and `std/ssh` tested only against
  OpenSSH.
- **The native protocol in M14 too:** the better protocol for SlopOS, typed and with prompts outside the stream, but a
  milestone's work of its own, and no client exists for it.
- **Remote terminals in the terminal service:** one place for terminals, but the console's trusted path and the
  network's byte streams in one service, and per-terminal sizes in a service built for one screen.
- **`curve25519-sha256` only:** no ML-KEM to build, but sessions recorded now could be read once quantum computers can
  break X25519, and OpenSSH would fall back from its first choice.
- **Port and agent forwarding:** port forwarding would carry the network past the session's policy unless matched to
  it; agent forwarding lends the client's keys to the remote machine. Neither is needed to log in or copy files.
- **The old scp protocol:** it runs a shell command on the server for each copy, which is what OpenSSH replaced.

## Consequences
- Hemera's `std` gains ML-KEM and `std/ssh`, usable by any Hemera program, hosted or on SlopOS.
- The account service gains public keys, and the session manager sessions whose home is locked.
- SSH sessions have no trusted path: a program in one can print a fake prompt, which is why their grants are set ahead
  of time (`0043`).
- Encrypted private keys (bcrypt's KDF) aren't read: the client's key lives in the user's encrypted home instead.

## As Built: 14a
- **SHA-3 and SHAKE** (FIPS 202) in `std/crypto`: Keccak-f[1600]'s sponge on a secret state, so secrets can be
  absorbed, with SHA3-256, SHA3-512, SHAKE128 and SHAKE256 over it. ML-KEM is made of them; nothing in `std` had them.
- **ML-KEM-768** (FIPS 203): key pairs from their seeds, encapsulation, and decapsulation with implicit rejection chosen
  without branching; the public key's modulus check and the secret key's hash check. Coefficients are u16s below q,
  reduced by Barrett's method and compressed by multiplying, never by dividing; the NTT uses FIPS 203's tables. All of it
  `#constant_time` where the secret key or the message is.
- **`chacha20-poly1305@openssh.com`**, from `std`'s ChaCha20 and Poly1305: the length under its own key, readable from
  a packet's first 4 bytes; the tag over the encrypted length and packet.
- OpenSSH's key formats moved to 14b: they're SSH's wire encoding, so `std/ssh`'s.
- **Tests:** hosted: SHA-3 and SHAKE against FIPS 202's answers (empty, "abc", a million a's absorbed in pieces);
  ML-KEM-768 against NIST's ACVP vectors (25 key pairs, 25 encapsulations, 10 decapsulations, 5 of them rejections,
  20 key checks) and 161 of Wycheproof's (40 left out, of sizes the types can't hold), and both sides agreeing for
  drawn keys, a changed ciphertext not; OpenSSH's construction sealing and opening drawn packets, refusing a changed
  byte or another sequence number. Its known answers come in 14b, against OpenSSH itself.

## As Built: 14b
- **`std/ssh`**, Freestanding, a state machine like `std/tls`'s: the caller feeds what arrives, takes what to send and
  answers events (a host key to trust, a password or key to judge, a channel request). Its buffers are its own
  (`Connection`, about 800 KB with its 4 channels, so callers allocate it); nothing in it waits or calls the system.
- **Transport:** `mlkem768x25519-sha256` and `curve25519-sha256`, strict key exchange both ways (sequence numbers reset
  at NEWKEYS, anything unexpected before it fatal), `chacha20-poly1305@openssh.com` and `aes256-gcm@openssh.com`, a
  key exchange again after 1 GiB either way or when the peer starts one, with messages held meanwhile. A server's
  EXT_INFO (`server-sig-algs`) goes as its first packet under the first keys, as RFC 8308 allows.
- **Authentication:** Ed25519, ECDSA P-256 and RSA (`rsa-sha2-256`, `-512`) users' keys, queries answered before a
  signature's asked for, and passwords; 6 tries, then disconnection. The client tries its key, then asks its caller for
  a password each time one's refused, until the server gives up.
- **Channels:** sessions, a 64 KB window each, given back once half's read; `pty-req`, `shell`, `exec`, `subsystem`,
  `window-change`, `signal`, `exit-status`. A channel closed both ways is freed only once what arrived on it is read.
- **Keys:** `authorized_keys` lines, unencrypted `openssh-key-v1` Ed25519 private keys written and read, and SHA256
  fingerprints.
- **Found against OpenSSH:** a cipher that keeps the length apart (chacha20-poly1305 as well as GCM) pads the packet
  without its length to the block, both ways; EXT_INFO after SERVICE_ACCEPT is refused by OpenSSH's client.
- **Tests:** hosted, a client and a server in memory: key and password logins, a wrong password asked again until the
  server ends it, an untrusted host key, 200 KB each way under every exchange and cipher with a key exchange midway, a
  changed packet, a key ssh-keygen wrote read (its line and fingerprint ssh-keygen's) and written back; property tests
  for any bytes to either side and as keys, which `tools/fuzz.py` fuzzes (`ssh_server`, `ssh_client`, `ssh_keys`).
  Against OpenSSH 10.0 on the Linux test VM, x86-64 and AArch64 (Hemera's `linux_tests.py`, `openssh_interop`): its
  `ssh` through a `ProxyCommand` running a Hemera server, under each exchange and cipher, a command, a megabyte through
  `cat` with key exchanges every 256 KB, a password, a wrong one and an unauthorized key refused, ECDSA and RSA keys;
  a Hemera client of `sshd -i` the same ways, an unknown host key refused; ssh-keygen reading a key Hemera wrote, and
  their fingerprints agreeing.
