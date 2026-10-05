# Security Design

Status: **proposed**, assembled from accepted decisions. This note is the overview: each
section summarizes and links the decision records, which stay authoritative. Parts marked
*proposed* are not yet decided. Unresolved items are listed in §13 and in
`../open-questions.md`.

## 1. Goals and threat model (`0013`)
A machine has few users and many mutually untrusting programs. The design protects:
- users' data and the system from **malicious or buggy applications**;
- users **from each other**;
- everything from **malicious or buggy drivers and devices** (user-space drivers, IOMMU);
- data at rest from **someone with the disk**, through per-user encryption.

Deliberately not covered: timing and covert channels, transient-execution attacks (no
KPTI; performance counters and energy readings are not ambient), capabilities over the
network, and an administrator who replaces system software. Where protection would cost
significant performance, performance wins.

## 2. Principles
1. **No ambient authority.** A process can do only what its handles allow, plus the small
   ambient floor of §5.
2. **Authority is an object capability:** an unforgeable handle that both designates an
   object and grants rights to it. Never an identity checked against a list.
3. **Everything is owned.** Each object has exactly one owner in a tree; destroying the owner
   destroys everything below it. Destroying is revoking.
4. **Agents are trusted as far as their authority.** A service handing out access on
   someone's behalf is believed about whom it gave it to (`0014`).
5. **Code you link is code you trust.** In-process code shares all of a process's authority;
   isolation means a separate process.

## 3. Trusted computing base
A bug in any of these can break the guarantees above (`0013`, `services.md`):
kernel · root task · process manager · supervisor · config store · bundle store · platform
service · storage · account service · session manager · login front ends · terminal service
· powerbox · (later) compositor and input.

Not trusted: drivers (confined by the IOMMU and their device capabilities), applications,
the shell, logging.

## 4. Kernel mechanisms
- **Handles** (`0008`): a per-process handle table; a handle is an opaque 32-bit value
  encoding a table index and generation. Each object has one owning handle; other handles
  are non-owning references and can be sent to other processes (`0010`).
- **Lifetime and revocation** (`0008`, `0010`): objects live in typed pools with generation
  counters. Destroying an object makes every handle to it stale, everywhere and
  transitively. To revoke one recipient, destroy a child object only they reach, or close
  their connection. No derivation tree, no per-call cost.
- **Rights** (`0010`, `0015`): a small fixed set checked at each syscall: `duplicate`,
  `transfer`, plus per-type rights (memory `read`/`write`/`execute`/`map`; process rights
  in §11). Attenuation only removes rights. Handle types are `distinct` per object kind;
  rights are runtime values, not part of types.
- **Connections** (`0010`): one channel per client connection, no badges, no sender
  identity. Ports/wait-sets let one thread wait on thousands of channels.
- **Budgets** (`0011`): separate memory and CPU budget objects. Every kernel object is
  charged to its owner's memory budget; transferring ownership moves the charge; receiving
  owned objects is explicit and can fail with `BudgetExceeded`.

## 5. Boot and the ambient floor
- **Root of authority** (`0012`): the kernel gives everything to one tiny root task, which
  starts the process manager, supervisor and platform service from the boot configuration
  and then only restarts the supervisor (`0017`).
- **Ambient floor** (`0009`): executing, using mapped memory, syscalls on held handles,
  monotonic time, timeouts, yield and exit. Nothing else.
- **Startup grants** (`0009`): own address space and memory budget, a limited handle to
  itself, logging, and whatever the launcher chooses (wall clock, entropy, files). Each can
  be withheld or substituted.

## 6. Granting authority (`0018`)
- **At launch:** command-line arguments are grants. Named files become individual handles;
  globs become a `FileSet` (directory plus filter). Capabilities carry an informational name
  for display.
- **At runtime:** a program asks the powerbox for more authority. The user answers on the
  console (terminal service) or, later, in the GUI; both use the same protocol. Prompts name
  the requester by its connection label. During a console prompt, keystrokes go only to the
  powerbox.
- *Proposed:* the shell derives grants from a program's typed parameters (a `ReadOnlyFile`
  parameter is opened read-only). Waits on what executables look like.

## 7. Rules for servers (`0010`, `0014`)
- Authorize a request **only by the connection it arrived on**: its protocol and the rights
  attached when the server issued it. No caller identity exists to check.
- **Objects created through a connection belong to that connection** in the server's own
  ownership tree, so closing the connection revokes them.
- Narrower authority is a **new connection speaking a narrower protocol**.
- Labels describe connections for audit, quotas and prompts; they never grant anything.

## 8. Persistence and sharing (*proposed*)
Kernel handles don't survive a reboot. Authority that must persist is rebuilt or stored:
- **System wiring** is rebuilt from the declarative system configuration at boot.
- **User grants that must persist** ("this editor may reopen this file", "user B may use
  this shared folder") are **stored links**: entries the storage service keeps in the
  recipient's namespace, pointing at the granted object with the granted rights. Opening a
  link gives a fresh connection. A link is a capability kept by the storage service on the
  recipient's behalf, so the stored-authority form of §7, not an ACL. The granter can list
  and delete the links it issued, which revokes them.
- **Shared areas between users** are separate volumes with their own volume key, wrapped
  for each member. Granting access is a link in the member's namespace plus a wrapped key.

## 9. Users, sessions and encryption (`0016`)
- The kernel has no users. A **session** is an ownership-tree node with the user's starting
  capabilities (home volume, own config, a terminal or display, a powerbox connection).
  Several sessions can run at once, locally or remotely.
- **Authentication:** passwords, and keys or tokens (especially for remote login), checked by
  the account service (*proposed*, `services.md`). The session manager then creates the
  session.
- **Administrator:** an account given capabilities to the config store, account management
  and volume management. It can change configuration, create and delete accounts, and
  delete or move a user's encrypted volume. It can't read it.
- **Per-user encryption:** each user's volume has a random key, stored only wrapped by keys
  derived from the user's credentials. Only the storage service holds raw `block`
  capabilities; anything else gets them only by explicit configuration.

## 10. Restart and reconnection (`0017`)
Clients reach services through connectors owned by the supervisor. On `ObjectGone`, `std`
reconnects automatically for idempotent protocols and reports the error for the rest.

## 11. Debugging, process control and replay (`0009`, `0017`)
- Process rights: `inspect`, `read_memory`, `write_state`, `intercept`, `kill`. They cover
  the whole subtree. The creator gets all of them and hands out attenuated copies. Nothing is
  hidden from its creator.
- **Replay** (`0009`, amended by `0024`): a recorded process sees nondeterminism only as
  syscall results. A recorder uses `intercept` to record them and a replayer answers them.
  Replay is opt-in. The recorder withholds the `map` right on channels, so IPC goes through
  syscalls. Other processes use direct shared-memory IPC and aren't strictly replayable.
  `RDTSC`/`RDRAND` are avoided by convention.

## 12. Out of scope
Timing and covert channels; transient-execution attacks; network capabilities (for now);
protection from a malicious administrator replacing system software; code signing (for now).

## 13. Open items
- Key-based remote login and background work when an encrypted volume is locked (`0016`).
- How the console marks genuine prompts, locally and over remote login (`0018`).
- Persistence and sharing (§8) as a decision; re-keying a shared volume after removing a member.
- The final list of kernel object types (proposed in `kernel.md` §2).
- Executables, libraries and typed entry points, which decide static authority and shell
  grants.
- Service details in `services.md` (account database protection, powerbox per session).
- ~~Whether AES instructions become part of the CPU baseline~~: no; detected at boot with a
  software fallback (`0019`).
