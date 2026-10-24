# System Services

Status: **proposed**, extended 2026-10-24 with the services of roadmap M8 to M16. A working list of the user-space services SlopOS needs, what each one
does, and what authority it holds. Grows as designs are settled. Layers refer to
`layers.md`. **TCB** marks services in the trusted computing base (`../decisions/0013`): a
bug or compromise there can break the guarantees of `security.md`.

## Boot and process management

| Service | Layer | Does | Holds | TCB |
|---|---|---|---|---|
| **Root task** | — | First process. Splits budgets and device capabilities, starts the services below from the boot configuration, restarts the supervisor. Never restarted (`0012`, `0017`) | Everything the kernel hands over at boot | yes |
| **Process manager** | L4 | Loads programs and builds processes *for* a requester, which owns the result and pays for it (`0012`) | Executable loading only; no standing authority over the processes it builds | yes |
| **Supervisor** | L4 | Starts and restarts services and drivers; owns the connectors clients use to reach them (`0017`) | Handles to the services it supervises | yes |
| **Config store** | L4 | Holds the typed, versioned system configuration; atomic updates and rollback (`../problems-and-directions.md` §6, §13) | Its own storage | yes |
| **Bundle store** | L4 | Content-addressed programs and libraries (§5) | Its own storage | yes |
| **Scheduler service** | L4 | Holds the root CPU budget, splits it for sessions, services and drivers, adjusts parameters slowly; never on the dispatch path (`0037`, `scheduling.md`) | The root CPU budget | yes |
| **Update service** | L4 | Writes new generations (objects into the bundle store, the boot set and entries to the ESP), makes a healthy one permanent (`software.md` §5) | Bundle store put and roots, the ESP's `Dir`, the config store | yes |

## Hardware

| Service | Layer | Does | Holds | TCB |
|---|---|---|---|---|
| **Platform service** | L3 | Parses the static firmware tables (ACPI or devicetree), enumerates PCIe, registers interrupt controllers and IOMMUs with the kernel, starts drivers with only their own device's capabilities (`0039`) | Device memory, IRQs, I/O ports for all devices until handed out; the capability to register platform hardware | yes |
| **ACPI service** | L3 | Later: runs ACPI's AML (legacy interrupt routing, power management, battery, embedded controller) for the platform service (`0039`) | The ACPI namespace's device memory and I/O ports | partly |
| **Drivers** | L3 | One per device; implement device-class protocols | Their own device's MMIO, IRQs, DMA buffers in an IOMMU domain | no (confined by the IOMMU) |
| **Clock** | L3/L4 | Wall-clock time: RTC (M9), later NTP with NTS (`0009`, `networking.md` §5) | RTC device, a narrowed network connection | no |
| **Entropy** | L3/L4 | Random bytes for seeding `std` generators (`0009`) | Hardware RNG device, boot seed | partly (keys depend on it) |

## Storage

| Service | Layer | Does | Holds | TCB |
|---|---|---|---|---|
| **Storage manager** | L4 | Holds every disk; starts the servers below through the process manager, each with only its own piece; unlocks volumes for the session manager; volume management (create, delete, move, quotas) on encrypted volumes; `FileSet` and informational names (`0016`, `0018`); resolves stored links for persistent grants (`security.md` §8). Split proposed in `storage.md` §2 | The disks' `block` capabilities | yes |
| **Partition server** | L4 | One per disk: parses the GPT, hands out `block` connections narrowed to a partition (`storage.md` §2) | One disk's `block` | no |
| **Container service** | L4 | One per SlopOS partition: free space, the volumes' extents, checkpoints, quotas; never sees plaintext (`storage.md` §2) | One partition's `block` | yes, for availability and isolation between volumes |
| **Volume server** | L4 | One per unlocked volume: its tree, its key, its cache, its clients' `Dir` and `File` connections (`storage.md` §2) | Its volume's extents through the container, its key | yes, for its own volume |
| **FAT server** | L4 | One per FAT partition (the ESP, later USB sticks) (`storage.md` §8) | One partition's `block` | no |

## Users and sessions

| Service | Layer | Does | Holds | TCB |
|---|---|---|---|---|
| **Account service** | L4 | Holds the account database (users, password hashes, public keys and tokens, each user's wrapped volume keys). Verifies credentials; on success, unwraps the volume key | Its own storage volume, account management | yes |
| **Session manager** | L4 | Creates a session node after a successful login, asks storage to unlock the user's volume, and starts the session's first program (shell or desktop) with the session's starting capabilities | Session creation; the right to ask storage to unlock volumes with keys from the account service | yes |
| **Console login** | L4 | Login prompt on the local console; passes credentials to the account service | Its terminal | yes |
| **Remote login** | L4 | Login over the network (SSH-like); key and password authentication | Network listener, account service connection | yes |

**What "the session's starting capabilities" means.** After a login succeeds, some service
has to give the new session its starting authority: a directory capability for the user's
home volume, the user's own configuration, a terminal or display, and a powerbox
connection. Under this proposal the session manager does it. It's the only service that
takes "a login succeeded" and turns it into capabilities, which is why it's in the TCB.

## User interaction

| Service | Layer | Does | Holds | TCB |
|---|---|---|---|---|
| **Terminal service** | L4 | Owns the text console (keyboard and screen, or serial), multiplexes terminals, shows powerbox prompts on the console's trusted path (`0018`) | Console devices | yes |
| **Powerbox** | L4 | Handles programs' runtime requests for authority; asks the user through the terminal service or compositor; returns capabilities chosen from the session's authority (`0018`) | The session's grantable authority (proposed: one instance per session) | yes |
| **Shell** | L6 | Interactive language; turns command lines into processes and launch grants | Whatever its session gives it | no (runs as the user) |
| **Display / compositor** | L4 | Later: GUI, owns the GUI trusted path | Framebuffer/display, input | yes |
| **Input** | L4 | Owns the seat: keyboard, pointer and touch events routed to the terminal service or the compositor, whichever has the seat; recognizes the secure attention key first (`console-and-sessions.md` §3) | Input devices | yes |

## Other

| Service | Layer | Does | Holds | TCB |
|---|---|---|---|---|
| **Network** | L4 | IPv4 and IPv6, TCP and UDP, the resolver on `net`; issues connections narrowed to destinations and listening ports (`networking.md`) | NIC `net` capabilities | partly |
| **Events / log** | L4 | Structured, typed events; logging destinations handed out at launch (`0009`); records labeled by connection, kept per source (`observability.md` §2) | Its own storage, a directory in each session's volume | no |
| **Audio** | L4 | Mixes clients' streams on a short-period, high-priority budget; capture as a powerbox capability (`display.md` §7) | `audio` devices | partly (the microphone) |

## Open
- Does the account service own its database volume directly? (It isn't encrypted, `0042`.)
  Proposed: yes, a volume of its own given by the system configuration (`console-and-sessions.md` §4).
- Is the powerbox one service per session or one system service handling all sessions?
  Proposed: one per session (`console-and-sessions.md` §5).
- Is the terminal service also what remote login attaches to? Remote prompts are settled
  (`0043`: outside the stream over the native protocol, none over SSH); where sessions attach
  isn't. Proposed: yes, through the VT adapter for SSH (`console-and-sessions.md` §2, `networking.md` §7).
- Whether the network service's resolver is its own service (`networking.md` §9).
