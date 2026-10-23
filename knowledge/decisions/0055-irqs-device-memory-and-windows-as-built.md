# 0055: IRQs, Device Memory and Windows as Built

Status: accepted
Date: 2026-10-23
Related: `0039` (platform discovery), `0049` (device interrupts), `0010` (child memory objects), `0054`
(memory objects and budgets), `0034` (kernel scope), `../design/ipc.md` §3, `../roadmap.md` M5

## Context
M5's fourth stage, second part (4b): drivers in user space need their device's interrupts and registers.
`0039` has the platform service register interrupt controllers and make IRQs "using a capability the
root task gives it", and `0010` puts child memory objects in place of a derivation tree. Neither the root
task nor the platform service exists yet (M6, M7); until now the kernel's tests routed the emulator's I/O
APIC themselves.

## Decision
Chosen with the project's owner:
- **A Platform capability**, a new object kind, is the authority over the hardware. The kernel makes one
  at boot for the root task to hand on. Behind it: `ControllerRegister(platform, kind, registers)`,
  `IrqCreate(platform, budget, controller, line, flags)` and `MemoryCreatePhysical(platform, budget,
  address, size, cache)`.
- **IRQs reach drivers through ports**: `PortBind` takes an IRQ like any object, and each interrupt adds to
  the count in its `Irq` packet (`../design/ipc.md` §3). A level-triggered line stays masked until
  `IrqAck`. The kernel picks the CPU a line is routed to.
- **Windows die with their memory**: destroying a memory object destroys its windows, unmapping them
  everywhere; destroying a window leaves the memory. A window is a revocable view (`0010`).
- **I/O-port ranges and IOMMU domains wait for drivers** (M7), with message-signaled interrupts.

As built:
- **An IRQ is one line**: making it routes the line to the next CPU in turn, with the IRQ recorded in the
  route, and unmasks it; a line has at most one IRQ (`LineInUse`). One port binding per IRQ. Closing it
  masks the line and forgets the route. Interrupts arriving while it's being destroyed find no binding.
- **Registering a controller twice** gives the number it already has, so the platform service can restart.
- **Device memory** must not overlap RAM the kernel owns (free memory, boot memory, its image, boot
  modules), which the kernel now keeps from the memory map; framebuffers, firmware tables and the
  firmware's own memory are the platform service's to map. It's charged only its slot.
- **A window's rights**: it can be mapped only as the handle it was made through allowed, kept in the
  window itself, since its own handle is owning and has every right. Windows of windows and of device
  memory work the same way. A window is charged only its slot; the frames stay its parent's.

## Alternatives considered
- **The kernel making IRQs and device memory itself until M7**: less ABI now, but nothing in user space
  could drive a device, and the platform service's calls would be designed without a user.
- **A wait call on the IRQ itself**: a second wait mechanism, against `../design/kernel.md`'s one.
- **Windows that keep their range of frames alive**: the memory's owner couldn't revoke what it handed
  out by closing the memory, which is what `0010` uses windows for.
- **Giving a window's handle only the rights it was made with**: every owning handle has every right
  (`0008`); the limit belongs to the object.

## Consequences
- The root task (M6) gets the platform capability and passes it to the platform service.
- The platform service (M7) reads the firmware tables for controllers' registers and lines' trigger and
  polarity, and makes device memory for the tables themselves.
- CPU affinity for IRQs, and moving a line between CPUs, come with the scheduler service.
