# 0005: Scope — Real Implementations, Narrow Feature Set

Status: accepted
Date: 2026-09-30

## Context
SlopOS's real artifact is its **source code**, as a stress test and proof of concept for
the Hemera language, compiler and standard library. A running system is a welcome bonus,
not the goal. Toy implementations would make the stress test inaccurate: they don't use
the language the way real software does, so they don't reveal the problems real software
would hit.

## Decision
**Narrow scope, full depth.** Cut *features*, never *implementation quality* within a feature.

Within anything we implement:
- **Follow the real specification** (Intel SDM, ACPI, PCIe, virtio, ELF, Limine protocol,
  filesystem specs) and cite it in the code.
- **Real algorithms and data structures**: the ones a production system would use (e.g. a
  buddy allocator plus slabs, not a bump allocator).
- **Every error path is handled** with `Result`/optional types. No "can't happen" shortcuts.
- **SMP-safe from the start.** No "assume one CPU for now".
- **No fake stubs** in finished code (`return 0 // TODO`). If something isn't implemented,
  it returns an explicit `NotSupported` error, and the missing part is listed in the roadmap.
- **No external C code linked into SlopOS.** Limine is used as an external bootloader (like
  firmware); everything SlopOS runs is Hemera.

Allowed reductions in scope:
- Fewer drivers (virtio first; no GPU acceleration, Wi-Fi, USB until much later, if ever).
- Fewer subsystems at first (networking and graphics after storage).
- Static ACPI tables only; an AML interpreter is a project in itself (ACPICA is very large).

## Alternatives considered
- **Minimal/toy OS to reach "boots and runs" quickly:** faster feedback from running code,
  but the code would mostly exercise easy parts of the language.
- **Full general-purpose OS ambitions:** unbounded; the language would stop being the focus.

## Consequences
- Code is written against the language as documented and proposed, before the compiler
  can build it. Conventions for marking gaps and guesses are in `../conventions.md`.
- When SlopOS needs a library facility (containers, formatting, allocators), it gets a
  real implementation, which is direct input to Hemera's `std`.
- Progress is measured in milestones of real subsystems (`../roadmap.md`), each listing
  which Hemera features it stresses.
- If the compiler and `std` mature, the code should be close to buildable and runnable,
  because it was written to the real specs.
