# 0072: The Order of the Milestones After M7, and Device Isolation Before Storage

Status: accepted
Date: 2026-10-24
Related: `0039` (IOMMUs in the kernel behind `iommu_interface`), `0070` (drivers trusted until an IOMMU stage),
`0013` (malicious drivers and devices are in scope), `../roadmap.md` *After M7*, the design notes for M8 to M16

## Context
The roadmap after M7 was drafted on 2026-10-24 as a proposal: a milestone per subsystem, with a design note each,
and two questions left for the project's owner. The first was the order: the draft built each layer on the one it
needs (storage, then the software and services that live on it, then accounts and sessions, then the shell), which
reaches an interactive system only at the end of M11; the alternative put a console and a shell first, on programs
from boot modules with nothing persistent. The second was where the IOMMU stage goes: `0070` keeps drivers in the
TCB until it exists, and M8's storage stack is the first that would hold users' data through drivers.

## Decision
Chosen with the project's owner:
- **The order is storage first**, as drafted:
  D → M8 storage → M9 system services and software (with B, the Hemera bootloader, alongside) → M10 console, accounts
  and sessions → M11 shell and tools (with P, power, before it ends) → M12 observability and debugging → H hardening →
  M13 networking → M14 remote login → M15 display and input → M16 audio.
- **The end of M11 is the first usable system**: booting from a disk image into a console login, an encrypted home
  volume unlocked by the password, a shell running installed programs, files that survive a crash, updates that roll
  back (`../roadmap.md`).
- **D comes right after M7 and before M8, with the real IOMMUs**: Intel VT-d and Arm SMMUv3 behind `iommu_interface`
  (`0039`), with interrupt remapping, so no driver of the storage stack, or any later one, is trusted with DMA
  anywhere. `virtio-iommu` isn't the first step.
- Each milestone is planned in detail when it starts, with its own plan record, as `0058` and `0070` were; the
  milestones' design choices stay open until then (`../open-questions.md`).

## Alternatives considered
- **A console and a shell before storage**: interactive sooner, but the shell's grants, history and installations
  would be built once without files and again with them, and nothing typed in would persist.
- **Networking right after M11**: remote access sooner, but debugging and hardening would come after the network's
  attack surface instead of before.
- **`virtio-iommu` first**: one driver for both architectures, but no interrupt remapping, so a device could still
  forge MSIs, and VT-d and SMMUv3 would follow anyway.
- **D after M8**: storage sooner, with its drivers in the TCB meanwhile, holding exactly the data the IOMMU is meant to
  protect.

## Consequences
- M8 starts only after D's VT-d and SMMUv3 work; drivers leave the TCB before any user data exists on SlopOS.
- QEMU runs with `intel-iommu,intremap=on` on q35 and `iommu=smmuv3` on `virt` from D onward, in every boot test that
  starts drivers.
- B and P are scheduled relative to M9 and M11 rather than as milestones of their own in the sequence.
