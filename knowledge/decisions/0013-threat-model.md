# 0013: Threat Model and Security Scope

Status: accepted
Date: 2026-10-02

## Context
Decisions 0008–0012 settled the capability mechanisms. A security design also needs to say
what it defends against, what it deliberately doesn't, and where performance wins over
protection. SlopOS favours performance where the two conflict and the threat is narrow.

## Decision
**In scope:**
- **Malicious or buggy applications** attacking the user's data, other applications or the
  system. This is the core case the capability model exists for.
- **Users attacking each other** on a machine with several accounts (`0016`).
- **Malicious or buggy drivers and DMA-capable devices.** Drivers run in user space with
  only their own device's capabilities, and the IOMMU confines what devices can DMA into
  (`../design/layers.md` L3).
- **Physical access to the disk**, as far as per-user encryption at rest covers it
  (`0016`), because its cost is low on CPUs with AES instructions. Measures that would be
  expensive (encrypting all metadata, hiding volume sizes, defeating cold-boot attacks) are
  out of scope.

**Out of scope:**
- **Timing and covert channels** (`0009`).
- **Transient-execution attacks** (Spectre, Meltdown and relatives). No kernel page-table
  isolation (KPTI) and no mitigations with a significant cost. The facilities these attacks
  rely on beyond ordinary timing are not ambient, though: performance-monitoring counters
  (`RDPMC` stays disabled in user mode, CR4.PCE = 0) and power/energy readings (RAPL MSRs,
  which only the kernel can read) are reached only through capabilities.
- **Capabilities across the network.** Kernel handles never leave the machine. When
  networking is designed, the network service can issue its own network capabilities (for
  example following OCapN/CapTP).
- **An administrator subverting system software.** An administrator can change the system
  configuration, so can install a modified login or storage service that captures a user's
  password next time. Per-user encryption protects against an administrator (or a thief)
  *reading* data directly, not against one who replaces the trusted code. Closing that gap
  would need signed system images from a party other than the administrator, plus measured
  boot. Not planned.

**Trusting code (who can run system software):**
- Programs and libraries are identified by content hash (`../problems-and-directions.md` §5).
- System services and the boot configuration are whatever the administrator-approved system
  configuration names by hash. No code signing for now. Signing is a possible later layer
  for updates distributed by others.

**Code you link is code you trust.** Linking another program's functions into your own
process (§4) gives that code all of your process's authority. Running it as a separate
process and calling it over IPC is the isolated option, and is the default to recommend
for code from someone else.

## Alternatives considered
- **KPTI and the full transient-execution mitigation set:** a measurable cost on every
  kernel entry and exit, which matters most to a microkernel, where IPC means many entries.
  Rejected in favour of performance. Hardware that fixes these issues makes the question
  moot over time.
- **Code signing from the start:** needs a key-management and update story before there
  is anything to update. Deferred.

## Consequences
- Cheap hardware mitigations that are on by default or cost close to nothing can still be
  enabled, decided case by case and recorded in `../design/arch-x86-64.md`.
- The trusted computing base is named explicitly in `../design/security.md`: the kernel,
  root task, process manager, supervisor, storage, account and session services, login
  front ends, the console/terminal service and the powerbox.
- Per-user encryption puts AES performance on the critical path for storage: whether AES
  instructions become part of the CPU baseline (`0003`) is an open question.
