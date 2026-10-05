# System Services

Status: **proposed**. A working list of the user-space services SlopOS needs, what each one
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

## Hardware

| Service | Layer | Does | Holds | TCB |
|---|---|---|---|---|
| **Platform service** | L3 | Parses ACPI or devicetree, enumerates PCIe, starts drivers with only their own device's capabilities | Device memory, IRQs, I/O ports for all devices until handed out | yes |
| **Drivers** | L3 | One per device; implement device-class protocols | Their own device's MMIO, IRQs, DMA buffers in an IOMMU domain | no (confined by the IOMMU) |
| **Clock** | L3/L4 | Wall-clock time: RTC, later NTP (`0009`) | RTC device | no |
| **Entropy** | L3/L4 | Random bytes for seeding `std` generators (`0009`) | Hardware RNG device, boot seed | partly (keys depend on it) |

## Storage

| Service | Layer | Does | Holds | TCB |
|---|---|---|---|---|
| **Storage** | L4 | Filesystems on `block`; per-user encrypted volumes; volume management (delete, move, quotas) on encrypted volumes; `FileSet` and informational names (`0016`, `0018`); stored links for persistent grants (`security.md` §8) | The disks' `block` capabilities | yes |

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
| **Input** | L4 | Keyboard, pointer and touch events routed to the focused client | Input devices | yes |

## Other

| Service | Layer | Does | Holds | TCB |
|---|---|---|---|---|
| **Network** | L4 | TCP/IP on `net`; issues socket connections | NIC `net` capabilities | partly |
| **Events / log** | L4 | Structured, typed events; logging destinations handed out at launch (`0009`) | Its own storage | no |

## Open
- Does the account service own its database volume directly, and what key protects it at
  rest (a machine key, or a key unlocked at boot)?
- Is the powerbox one service per session or one system service handling all sessions?
- Is the terminal service also what remote login attaches to, so remote shells get the
  same console prompts?
