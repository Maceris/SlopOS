# 0025: Raw Syscalls Are the Stable Interface; All Stable Surfaces in One ABI Package

Status: accepted
Date: 2026-10-04

## Context
A system ABI can be stable at the raw-syscall level (Linux) or only at a system library that
every program must call through (macOS's `libSystem`, Windows's `ntdll`/`kernel32`).
SlopOS programs are content-addressed (`../problems-and-directions.md` §5), so each one
embeds a specific `std`. If only `std` were stable, a kernel change would break every
program built against an older `std`. The syscall table is also not the only thing user
space depends on: channel rings, port packets and the process startup block are binary
layouts shared with the kernel and other processes.

## Decision
**Raw syscalls are the stable interface.** Programs may call them through any code built
from the ABI package below, not only through `std`.

**Every stable surface lives in one place: a small, freestanding ABI package**
(`../design/system-abi.md` §1 lists its contents). It holds:
- the syscall table: a list of typed declarations, with stubs and kernel dispatch generated
  from it;
- the channel ring and message header layout;
- port packet types;
- the startup block;
- handle, rights, error and `CpuFeatures` types;
- the ABI version.

The kernel and `std`'s `os` tier both import it. `std` builds blocking calls, channels and
the rest of the OS layer on top of it. Nothing else may define a type that crosses the
user/kernel boundary, which is a house-rule check (`0007`).

**Stability starts at a declared ABI v1.**
- **Before v1:** numbers and layouts may change freely. Programs are rebuilt with the
  system.
- **From v1:**
  - Syscall numbers are append-only and never reused.
  - A removed call keeps its number and returns `NotSupported`.
  - A changed signature gets a new number.
  - Layouts are frozen, and grow only through size-prefixed structs or new versions.
- A compiler-checked comparison of the ABI package against the previous release
  (`../problems-and-directions.md` §5) rejects accidental breaks.
- The startup block carries the ABI version, so a program can check it once at start.

## Alternatives considered
- **Only `std` stable, syscalls private (macOS, Windows):** the kernel interface could change
  freely, but every content-addressed program pins a `std` version, so old programs would
  break, or every program would need one shared, mutable system library, which §5 avoids.
- **Stable from the first syscall:** commits to mistakes made before anything runs.

## Consequences
- The ABI package must stay small and freestanding (tier `Freestanding`, no allocation), so
  the kernel can import it.
- Where it lives is decided with package structure (open under *Scope*). Two candidates:
  inside `std_proposal` under the `OS == .SlopOS` OS layer (as Zig's `std.os.linux` holds
  Linux's syscall definitions), or in `src/` next to `protocols/`.
- Every syscall, ring field and packet variant added after v1 is permanent, so the design
  notes for each are reviewed before v1 is declared.
