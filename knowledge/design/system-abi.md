# The System ABI

Status: **partly decided.**
- *Decided* (`../decisions/0025`): raw syscalls are the stable interface; every stable
  surface lives in one ABI package; stability starts at a declared ABI v1.
- *Decided* (`../decisions/0026`): threads start in an entry stub of their own `std`, which
  sets up the carrier register; stack overflow is caught by Hemera's prologue check.
- *Decided* (`../decisions/0027`): nothing here is frozen until the OS design is thorough and
  development is under way.
- *Proposed*: the rest of this note, including the Hemera-native conventions.

Answers *"Is the system ABI Hemera-native, with a C-ABI shim only for ported code?"*, and
whether we can do better than the C ABI and other operating systems' ABIs.

Short answer: **yes, Hemera-native**. All SlopOS code calls each other with the Hemera
calling convention. C code is reached through thunks generated at compile time, as Hemera
does on other operating systems. "Better than C" comes mostly from what the ABI *leaves out*
(§3).

## 1. The Stable Surfaces

**This table is the complete stability promise.** Everything user space can depend on
across a kernel or system update is listed here, and all of it is defined in the single
freestanding **ABI package** (`0025`). If it's not in this table, it isn't stable.

| Surface | What is frozen at v1 | Defined in | Designed in |
|---|---|---|---|
| **ABI version** | The version number and how it's checked | ABI package | §5 |
| **Syscall table** | Numbers, argument and result types, the register convention | ABI package (typed declarations; stubs and dispatch generated) | §4 |
| **Handles and rights** | The 32-bit handle encoding as user space sees it (opaque), rights bit values, handle kinds | ABI package | `0008`, `0010`, `0015` |
| **Error types** | Each syscall's error union: variant tags and data | ABI package | §4 |
| **Channel rings** | `RingIndices`, `MessageHeader`, alignment, the wake (event-suppression) protocol, handle-batch numbering | ABI package | `ipc.md` §2 |
| **Port packets** | `Packet`, `PacketData` variants and their tags, `Signals` bits | ABI package | `ipc.md` §3 |
| **Startup block** | Layout, relative-pointer encoding, the ABI-version field, where grants and typed arguments sit | ABI package | §6 |
| **`CpuFeatures`** | Feature enum values | ABI package | `0019` |
| **Process start** | Initial registers: entry, stack pointer, startup-block argument; everything else zeroed (`0026`) | ABI package (documented with the startup block) | §6 |
| **Calling convention version** | The pinned Hemera convention version, for separately compiled libraries | Hemera's `calling_convention.md`, pinned by version (not frozen, `0027`) | §7 |

**Not stable:** kernel internals; the layout of anything a process reaches only through a
syscall; `std`'s own API. `std` is versioned like any content-addressed library: programs pin
the `std` they were built with, and the kernel promises only the table above.

**Before v1** every row can change, and programs are rebuilt with the system. **From v1**,
numbers are append-only, layouts grow only through size-prefixed structs or new versions,
and the release tooling compares the ABI package against the previous release
(`0025`).

### Where it sits
```
 programs
   │
 std  (os tier: blocking calls, channels with direct and kernel backends (0024), ports,
   │   fiber integration, startup → typed entry parameters)
   │
 ABI package (freestanding: syscall table + generated stubs, ring, packet and startup layouts)
   │                                        │
 user/kernel boundary ──────────────────────┼─────
                                             │
                                          kernel (imports the same ABI package; dispatch generated)
```
A house-rule check (`0007`) rejects any type crossing the user/kernel boundary that isn't
defined in the ABI package.

## 2. What the ABI Covers

| Boundary | Convention |
|---|---|
| User ↔ kernel (syscalls) | A register convention generated from the typed syscall table (§4) |
| Process start | Hemera calling convention: context register, stack pointer, one startup argument (§6) |
| Program ↔ separately compiled library | The Hemera calling convention, pinned per version (§7) |
| Process ↔ process | Not a calling convention: typed messages over channel rings (`ipc.md`) |
| Hemera ↔ C (ported code, a future POSIX personality) | Generated thunks (§8) |

## 3. Lessons From Existing ABIs

| Flaw found in practice | Where | SlopOS answer |
|---|---|---|
| Errors through a thread-local global and in-band sentinel values (`errno`, `-1`) | C, POSIX | Every syscall returns `Result[T, E]`, with `E` specific to the call (§4) |
| NUL-terminated strings: length scans, truncation, injection bugs | C, every C-based OS ABI | Slices (pointer + length) only. No NUL-terminated strings anywhere in the ABI |
| Type sizes defined by C headers, leading to painful transitions (`time_t` Y2038, `off_t` and large files, `struct stat` differing per architecture) | Linux/glibc | ABI types use explicit-width fields and compile-time size asserts. 64-bit time everywhere. One layout for every architecture |
| Syscall numbers differ per architecture, legacy calls exist only on some | Linux | One architecture-independent numbering, generated from a single table |
| Arguments can't grow without new syscalls (`clone` → `clone3`, `openat` → `openat2`) | Linux | Calls likely to grow take a struct with a leading size field, as `clone3` does. The kernel zero-extends older, shorter structs |
| File descriptors are small reused integers: close-then-reuse races, confused deputies | POSIX | Handles carry a generation, so a stale handle fails instead of aliasing (`0008`) |
| Varargs (`printf`, `ioctl`, `fcntl`) | C, POSIX | None. `ioctl`-style escape hatches are typed protocol requests instead |
| Struct-passing rules so intricate that compilers disagree (SysV classification, MSVC rules) | C ABIs | One rule set, written down in Hemera's `calling_convention.md`, with tests generated from `TypeInfo` |
| Signals interrupting arbitrary code, `EINTR` | POSIX | No signals, no `EINTR` (`../problems-and-directions.md` §9, `kernel.md` §4) |
| No stack probes, so a large frame can jump the guard page (Stack Clash, 2017) | SysV/Linux, until `-fstack-clash-protection` | Every Hemera prologue checks the stack pointer (or where its frame will end) against the carrier block's `stack_limit`, so overflow is a deterministic error and no frame can skip past the limit. No guard pages or probes needed for Hemera code (`0026`) |
| Frame pointers omitted, so profilers and crash reports can't unwind (Fedora and Ubuntu turned them back on in 2023–24) | SysV/Linux | Every Hemera function keeps a base pointer (`calling_convention.md`), across stack segments and suspended fibers, so unwinding always works |
| The only stable interface is a private system library, so every program depends on one shared, mutable library | macOS, Windows | Raw syscalls are stable (`0025`), so programs can embed their own content-addressed `std` |

## 4. The Syscall ABI

**The syscall table is data.** A single list of typed declarations in the ABI package
generates the kernel's dispatch table, the user-space stubs, the interception filter bits
(`kernel.md` §4) and the documentation:
```
port_wait :: fn(port: Port, out: mut Packet[], deadline: MonotonicTime?) -> Result[u32, PortError]
```
On x86-64:
- The syscall number goes in `rax`, and up to six register-sized arguments in the remaining
  argument registers. A slice takes two registers. Larger arguments go in a size-prefixed
  struct passed by pointer.
- Results: `rax` holds `0` for success or the error variant's tag, and `rdx` (plus `r8` if
  needed) carries the value or the error's data. A `#run` check rejects syscalls whose
  success value or error variants don't fit.
- The kernel preserves every register except the result registers, including the context
  register, so a syscall stub is an ordinary Hemera function.
- AArch64 and RISC-V get the same rules with their own registers, generated from the same
  table, with the same numbers.

**Numbering:** free until ABI v1, then append-only (`0025`).

**No vDSO by default.** Time is read through a syscall so it can be recorded (`0009`). Under
`0024`, a mapped time page could come back as an opt-in direct mode if syscall cost for time
turns out to matter. It would then join the table in §1.

## 5. ABI Version

- The ABI package defines `ABI_VERSION`.
- The startup block carries the version the kernel implements, and `std`'s startup code
  compares it with the version the program was built against. Before v1, any difference
  is a refusal to start. From v1, a newer kernel accepts older programs.
- A content-addressed program's hash covers the ABI version it was built for.

## 6. Process Start and the Startup Block

A new process starts in its own `std`'s entry stub (`0026`), which runs before any Hemera
function:
- The stub sets up the initial thread's **carrier block** and **carrier register**, then
  builds the `Context` and calls the program's exported entry function with it. The carrier
  block's layout is private to the program's `std`, so it isn't part of the startup block.
- **One argument** points at the **startup block**: a structure made of relative pointers
  (`relptr`), written by the process manager into a memory object mapped into the new
  process. It holds:
  - the ABI version;
  - `CpuFeatures` (`0019`);
  - the startup grants (`0009`), with their handle kinds and labels;
  - the typed arguments of the exported entry point (`0018`).
- `std`'s startup code turns the startup block into the program's typed parameters. How
  entry-point types become grants is still open under *Executables*.

## 7. Library ABI Between Separately Compiled Hemera Code

- Content-addressed libraries (`../problems-and-directions.md` §5) are called with the
  Hemera convention.
- The convention is still evolving on the Hemera side (it changed substantially on
  2026-10-04: return values through pointers, no frame-size word, a reserved carrier register,
  a stack check in every prologue). SlopOS **names and pins the version** it builds against
  (`hemera-abi-v1` once there is one) and includes it in what a library's content hash and
  interface check cover. Libraries built for different versions are different hashes, never
  silently mixed. The pin is **not a freeze**: SlopOS follows Hemera's changes until it
  declares ABI v1 (`0027`).
- The `Context` layout is part of this ABI, since every call passes it. Changing its fields
  is an ABI version change (the 2026-10-04 redesign removed `stack_trace`, `thread_index` and
  the fiber fields, and added `assertion_handler`). Every fiber also embeds a copy, so its
  size counts against each fiber's memory. Both are reasons to keep extensions out of the
  struct itself (`../hemera-proposals/context-extensions.md`).

## 8. Calling C, and Being Called From C

Hemera specifies these shims itself (Hemera `docs/calling_convention.md`, *Calls to Foreign
Code*):
- **Hemera → C:** the shim increments the carrier's `foreign_depth` and saves the current
  context pointer in the carrier block, switches from a fiber's segment to the carrier
  thread's own stack, calls with the platform convention, and undoes both. Yields decline
  while foreign frames are on the stack.
- **C → Hemera (callbacks):** the entry shim saves the foreign code's value of the carrier
  register, reloads the carrier pointer from OS thread-local storage (creating a carrier block
  if the thread has never run Hemera code), and uses the context the outgoing shim saved, or a
  default one on a foreign thread.
- **On SlopOS** the callback path needs somewhere to find the carrier pointer, and SlopOS has
  no TLS (`0023`, `0026`). Either one kernel-saved per-thread pointer only for this, or no
  foreign callbacks until ported C code exists (`../open-questions.md`, *Kernel*). Calls from
  Hemera into C need nothing extra.

## 9. Open Questions
- Where the ABI package lives: inside Hemera `std`'s SlopOS OS layer, or in `src/` next to
  `protocols/` (`0025`; decided with package structure under *Scope*).
- Answered: hardware control-flow integrity no longer conflicts with Hemera's fibers (Hemera's
  2026-10-04 redesign). Whether SlopOS enables CET, GCS, PAC and BTI is open
  (`../open-questions.md`, *Kernel*).
- `#escaping` on syscall parameters the kernel keeps after the call (`../open-questions.md`,
  *Kernel*).
- A per-thread pointer for foreign callbacks (§8).
