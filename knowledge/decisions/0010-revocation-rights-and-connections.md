# 0010: Revocation by Destruction, Kernel Rights, and One Channel per Connection

Status: accepted
Date: 2026-10-02

## Context
`0008` made destroying an object revoke every handle to it, but left open how to revoke
*one* recipient's access while keeping the object alive. The candidates were a kernel
derivation tree (seL4 `Revoke`), caretaker/forwarder proxies with membranes, or service-side
revocation. We also needed a rights model, and a decision on how a server tells its clients
apart: one channel per connection (Zircon) or one endpoint with badged capabilities (seL4).

## Decision
**Non-owning handles can be sent to other processes.** So revocation by destruction is
*transitive*. If A gives B a handle and B passes a copy to C, destroying the object makes
both stale. Membrane behaviour comes for free for kernel objects.

**Revoking one recipient means destroying an object that only that recipient reaches.**
There is no kernel derivation tree and there are no kernel forwarders.
- *Kernel objects:* derive an owned child object and hand that out instead. For memory,
  a child memory object (a window onto the parent). Destroying the child unmaps it everywhere
  and leaves the parent and other children intact.
- *Server capabilities:* each client connection is its own channel. The server revokes a
  client by closing that connection.
- *Server-side derivatives:* objects a server creates *through* a connection (a file opened
  through a directory connection) are owned by that connection in the server's own ownership
  tree. Closing the connection destroys them too. This is principle 4 applied inside servers,
  and it covers the case membranes exist for.
- Forwarders remain a user-space library pattern for anything unusual.

Cost per call: nothing beyond the generation compare that every lookup already does.

**One channel per connection.** The kernel delivers no badge or sender identity with
messages. A server knows who it's talking to only by which connection a message arrived on.

**Cheap waiting on many channels is a requirement.** Hemera servers handling many idle
connections (a web server, say) are expected to run one fiber per connection over a few
kernel threads. The kernel must therefore let one thread wait on thousands of channels
without a thread or a syscall per channel: a port/wait-set object to which channels are
bound with a user-chosen key, delivering readiness or completion packets that the fiber
scheduler maps back to fibers. Its exact shape is decided with the IPC primitive and the
completion-queue syscall interface (`../problems-and-directions.md` §9).

**Kernel rights: a small fixed set, checked at syscalls.**
- Generic: `duplicate` (may make another handle to the object) and `transfer` (may send it
  over IPC). `transfer` can't prevent a holder from proxying for others, so it guards
  against accidental leaks, not determined ones.
- Per type, defined as each object type is designed. For example, memory `read`/`write`/
  `execute`/`map`; process `inspect`/`debug`/`kill`.
- Ownership (`0008`) is a flag on the handle entry, not a right.
- No user-defined rights bits in the kernel.

**Attenuation, two ways:**
- Kernel: `duplicate(handle, rights)` creates a new handle-table entry with a subset of the
  rights. Rights can never be added.
- Servers: a request on a connection returns a new, narrower connection (read-only,
  subtree-only, append-only, expiring). Rights richer than the kernel's live in the server
  and are tied to that connection.

## Alternatives considered
- **seL4-style derivation tree and `Revoke`:** precise and recursive, but needs a kernel
  data structure updated on every copy, and long revocations conflict with one kernel stack
  per CPU (`../design/threads.md`). Destroying derived objects gives the same result.
- **Kernel forwarder objects:** an extra lookup on every call through the forwarder. Not
  needed now that revocation is transitive.
- **Badged endpoints:** fewer kernel objects per client, but per-client revocation then
  needs a badge-revocation mechanism, and a server can't wait on clients separately.

## Consequences
- Connections are cheap kernel objects but not free. A server with many clients pays one
  channel each, charged to whoever creates it (`0011`).
- The port/wait-set design becomes a kernel open question with a concrete user: `std`'s
  fiber scheduler.
- Servers should be written so that every object they create belongs to the connection it
  was created through. This is a candidate rule for `std`'s server framework.
- Whether channels carry a protocol identifier (to catch type confusion when a handle
  arrives) is still open: `../open-questions.md`.
