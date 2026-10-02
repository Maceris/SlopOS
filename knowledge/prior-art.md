# Prior Art

Systems worth studying, and what to take from each.

## Microkernels
- **L4 family / seL4** — fast synchronous IPC; seL4 is formally verified and capability-based. The reference point for "how small can a kernel be".
- **GNU Hurd** — servers on top of Mach; a cautionary tale about scope and IPC performance as much as a model.
- **MINIX 3** — reincarnation server: automatically restarts crashed drivers.
- **QNX** — commercially successful microkernel; pragmatic message-passing design.
- **Fuchsia / Zircon** — modern capability-based handles, async channels, component framework, content-addressed packages. Probably the closest modern relative.
- **Redox** — microkernel in Rust; good example of a new-language OS and its "everything is a URL scheme" namespace.
- **Genode** — capability-based framework with strict resource accounting (resources are donated by clients).

## Capability systems
- **KeyKOS / EROS / CapROS / Coyotos** — persistent capability OSes; origin of many of the ideas.
- **Capsicum** (FreeBSD) — capabilities retrofitted onto Unix; shows the pain of retrofitting.
- **CHERI** — hardware capabilities; interesting if we ever target it.
- **WASI** — capability-based system interface for WebAssembly; a small, modern API to crib from.

## Language-based and research systems
- **Singularity / Midori** (Microsoft Research) — software-isolated processes, typed channel contracts. Very relevant to typed IPC.
- **Theseus** — Rust OS relying on the language for isolation and live updating.
- **Oberon** — whole system in one language, tiny and comprehensible; commands are exported procedures (close to §4 of our brainstorm).
- **Barrelfish** — multikernel: treat a multi-core machine as a distributed system.

## App sandboxing (retrofitted)
- **iOS app sandbox / Android permissions** — per-app sandboxing with declared permissions;
  the closest mainstream models to per-program least privilege, and a study in what goes wrong
  when it's added on top of ambient-authority APIs.
- **Flatpak portals / macOS TCC** — desktop sandboxes that mediate file and device access
  through trusted dialogs (close to the powerbox idea).

## Namespaces, data and shells
- **Plan 9** — per-process namespaces, everything-is-a-file taken seriously, 9P protocol.
- **BeOS / Haiku** — typed file attributes with live queries; message-based app architecture.
- **PowerShell / Nushell** — shells passing structured data instead of text.

## Packaging and system state
- **Nix / NixOS / Guix** — content-addressed packages, declarative system config, atomic rollback.
- **Unison** — code identified by hash of its syntax tree; no dependency conflicts.
- **ChromeOS / Android** — A/B system partitions and atomic updates.

## Boot, hardware and portability
- **Limine** — modern boot protocol (x86-64, AArch64, RISC-V); our proposed L0 to start.
- **virtio** (OASIS spec) — standard virtual devices; same drivers on every architecture under QEMU.
- **Windows NT HAL** — the classic single hardware abstraction layer, for contrast with our two-boundary design.
- **seL4's arch split / Zircon's `arch/`** — examples of keeping per-arch kernel code isolated.
- **OSDev wiki** (wiki.osdev.org) — practical x86-64 reference for GDT/IDT/APIC/paging.

## Papers
- "A fork() in the road" (Baumann et al., HotOS 2019)
- "Improving IPC by Kernel Design" (Liedtke, 1993)
- "The Confused Deputy" (Hardy, 1988)
- "seL4: Formal Verification of an OS Kernel" (Klein et al., 2009)
- "Singularity: Rethinking the Software Stack" (Hunt & Larus, 2007)
