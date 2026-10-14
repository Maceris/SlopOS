# Proposal: Externally Initialized Data and Section Placement

Status: **adopted** 2026-10-13, with one change: `#section` is only allowed together with
`#externally_initialized`, since every other constant goes in a read-only section (subject to
reconsideration). Array literals use Jai's syntax, `u64.[a, b]`. Hemera's `docs/directives.md`
(*Constants*) and `docs/types.md` (*Static Arrays*) are the reference; the rest of this document is
the original draft. Raised by `../../docs/specs/boot_info.md` (*Not Yet Expressible
in Hemera*), where it blocks roadmap M1. Logged in `../hemera-feedback.md` as *Data written by
the bootloader*.

## Problem

The Limine boot protocol (base revision 6) talks to the kernel through data in the kernel's own
image:
- The kernel contains **request blocks**: small structs, each starting with a fixed 4-word ID,
  with a `response` pointer that's null in the file.
- Before starting the kernel, Limine **scans the loaded image** for those IDs (only between
  start and end marker blocks, if the image has them), and **writes a response pointer** into
  each request it supports.
- The kernel then reads `request.response`, and finds null for anything the bootloader didn't
  answer.

So the kernel needs data that:
1. **is emitted** even though code may never reference it (the marker blocks never are);
2. **isn't folded:** the compiler must not replace a read of `response` with the initializer's
   `null`, since the value at run time is whatever the bootloader wrote;
3. **is placed in a named section**, so the linker script can put the markers before and after
   the requests (`.limine_requests_start`, `.limine_requests`, `.limine_requests_end`).

Hemera has none of these. Its top-level data is constants, which the compiler may fold, drop
when unused, and place wherever it likes. And with no mutable globals, there's no `var` to fall
back on, which is how other languages do it.

### How other languages do it

| Language | Limine requests are declared as |
|---|---|
| C | `__attribute__((used, section(".limine_requests"))) static volatile struct limine_memmap_request req = {...};` |
| Zig | `export var req: limine.MemoryMapRequest linksection(".limine_requests") = .{};` (`export` keeps it) |
| Rust (`limine` crate) | `#[used] #[link_section = ".limine_requests"] static REQ: MemoryMapRequest = ...;` where the response is read with `read_volatile` through interior mutability |

Each one combines a **keep** attribute, a **section** attribute, and a **mutable or volatile**
global so the read isn't folded. LLVM has a name for the last part:
**`externally_initialized`**, a global whose initializer may be replaced before the program
starts, so optimizations can't rely on it.

## Proposal

Two directives on top-level constants.

### `#externally_initialized`

```
MEMORY_MAP_REQUEST #externally_initialized #section(".limine_requests") :: limine.MemoryMapRequest.{
    id = limine.MEMORY_MAP_REQUEST_ID,
}
```

The constant's initializer is only the **initial contents of the image**. Something outside the
program (a bootloader, a loader, a post-link tool) may replace it before the program's first
instruction runs, and the program sees the replaced value.

- **Always emitted**, as data in the output, even if nothing references it.
- **Never folded.** Every run-time read loads from the image. The compiler treats the value as
  unknown, though it may still assume the value doesn't change while the program runs, so two
  reads may be merged.
- **Read-only to the program.** It's still a constant: the program can't assign to it, and `&`
  gives a `ptr[T]`, never a `ptr[mut T]`.
- **Not readable at compile time.** `#run` code that reads it is an error, since its value isn't
  known until load time. Its address and `size_of`/`align_of` are fine.
- **Has an address**, like any data in the image, so it can be passed by pointer.
- Lowers to an LLVM global with `externally_initialized`, not `constant`, listed in `@llvm.used`.

### `#section(name)`

```
LIMINE_REQUESTS_START #externally_initialized #section(".limine_requests_start") :: limine.REQUESTS_START_MARKER
```

Places a constant (or a function) in the named output section, for a linker script to place.
Without it, the compiler chooses. It doesn't imply keeping: an unreferenced constant in a section
can still be dropped unless it's also `#externally_initialized`.

The compiler doesn't promise any order between constants in one section. Code that needs an
order uses separate sections and lets the linker script order them, as Limine's markers do.

### Why this isn't a mutable global

Hemera bans mutable globals so that no hidden state is shared between call trees. An
externally initialized constant shares nothing that changes: its value is fixed before the
program starts and is the same for every reader for the whole run, so it can't be a data race,
and it can't be used to pass state between functions.

It's the same thing the loader already does to every position-independent image: **relocations
rewrite pointer constants at load time** (`../decisions/0004`). This proposal names that for
data the program declares itself.

## What It Looks Like in `boot/limine`

```
package limine

import intrinsics from "base"

// Every request starts with these two words. //SPEC: Limine protocol, "Requests"
COMMON_MAGIC_0 :: 0xc7b1dd30df4c8b88
COMMON_MAGIC_1 :: 0x0a82e883a194f07b

MemoryMapRequest :: struct {
    id : u64[4],
    revision : u64,
    response : ptr[MemoryMapResponse]?,
}

MEMORY_MAP_REQUEST #externally_initialized #section(".limine_requests") :: MemoryMapRequest.{
    id = u64.[COMMON_MAGIC_0, COMMON_MAGIC_1, 0x67cf3d9d378a806f, 0xe304acdfc50c3c62],
}

read_memory_map :: fn() -> ptr[MemoryMapResponse]? {
    // An ordinary read: loaded from the image, never folded to the initializer's null
    return MEMORY_MAP_REQUEST.response
}
```

No `volatile_load` is needed: the bootloader writes before the program starts, so there's no
concurrent writer, only an unknown initial value.

## Other Uses

- **Boot headers that are only read,** like a Multiboot2 header or a UEFI loader's
  `.sbat` section: `#section` plus `#externally_initialized` to keep them.
- **Values stamped in after linking:** a build ID, a signature, or the boot configuration
  compiled into the boot image (`../decisions/0012`) when it's written by a tool after the
  kernel is linked.
- **Placing code:** `#section(".text.boot")` for code the kernel frees after boot.

## Alternatives Considered

- **Generate the request blob in the build package.** The build program serializes the requests
  as bytes into a section, and the kernel finds them through a section-start symbol, reading with
  raw pointers and offsets. No new language semantics except finding a section, but every access
  is an untyped cast, and the request types are written twice.
- **Treat it as device memory:** declare `#section` constants and read every field with
  `intrinsics.volatile_load_*`. It works for a single `u64` at a time, but volatile means "every
  access happens exactly as written", which is stronger than needed, needs the address of a
  constant, and still needs something to stop the constant being dropped or folded elsewhere.
- **`#export` on constants as the keep mechanism:** `#export` already means "part of the
  program's public interface", which would put boot data in the system ABI.
- **Allow mutable globals for this one case:** more than needed, since the program never writes.

## Open Questions

- **Name.** `#externally_initialized` matches LLVM and covers loaders and post-link tools.
  Shorter options: `#loader_written`, `#patched`, `#load_time`.
- **Should `#section` be allowed on any constant, or only together with
  `#externally_initialized`?** On ordinary constants it would let the compiler still fold reads
  and only place the copy it emits, which is fine but easy to misread.
- **Array literals:** the example writes `id = .{...}` for a `u64[4]` field, which
  `docs/types.md` doesn't show yet (`//HEMERA(guess)`).
- **Formatter and language server:** nothing new beyond two directives.
