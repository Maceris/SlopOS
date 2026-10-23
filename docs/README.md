# SlopOS Documentation

Official documentation for SlopOS: what the system *is* and how to use and build on it.
Planning material (ideas, open questions, decisions, design discussions, Hemera feedback)
lives in `../knowledge/` instead.

## What Belongs Here

- **Specifications**: system call ABI, IPC message formats, device-class protocols
  (`block`, `net`, `input`, ...), boot handoff (`BootInfo`), on-disk formats.
- **API documentation**: kernel interfaces, service protocols, the SlopOS parts of `std`.
- **Architecture**: the layer model, component diagrams, how a request flows through the system.
- **Developer guides**: building, running under QEMU, writing a driver or a service.
- **User guides**: once there is something to use.

## Rules

- Describe the system as specified or built, not as debated. Rationale and alternatives
  belong in `../knowledge/decisions/`; link to them instead of repeating them.
- A spec here is the source of truth for the code. If they disagree, one of them is a bug.
- Mark anything not yet implemented as such.

## Layout

```
docs/
  architecture/   layer model, the kernel core, component and data-flow diagrams
  specs/          syscall ABI, IPC, device-class protocols, BootInfo, formats
  api/            kernel, services, std (SlopOS-specific parts): none yet
  guides/         building, running, writing drivers and services
```

## Contents

| Document | Status |
|---|---|
| `architecture/layers.md` | The layer model (L0–L6) and its interfaces. L0, L1 and much of L2 built |
| `architecture/kernel.md` | The kernel core as built: boot, memory, objects and handles, interrupts, time, threads and scheduling. Built (roadmap M1–M5 stage 1) |
| `specs/boot_info.md` | The boot handoff from L0 to the kernel core, and its Limine implementation. Implemented |
| `specs/arch_interface.md` | The boundary between the arch layer and the kernel core, in both directions. Implemented on x86-64 |
| `specs/system_calls.md` | How user space calls the kernel: registers, handles, rights, the calls and their errors. Implemented, growing |
| `guides/building.md` | Building, booting in QEMU, the kernel's command line, testing and debugging |
