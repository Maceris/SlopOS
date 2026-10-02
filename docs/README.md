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

## Planned Layout

```
docs/
  architecture/   layer model, component and data-flow diagrams
  specs/          syscall ABI, IPC, device-class protocols, BootInfo, formats
  api/            kernel, services, std (SlopOS-specific parts)
  guides/         building, running, writing drivers and services
```

Nothing has graduated here yet. The first candidates are the layer model
(`../knowledge/design/layers.md`, once accepted) and the `BootInfo` and arch-interface
specifications from roadmap milestone M0.
