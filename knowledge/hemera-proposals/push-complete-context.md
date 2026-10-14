# Proposal: Pushing a Complete Context

Status: **adopted** 2026-10-13, with `from` as the keyword and `runtime.MINIMAL_CONTEXT` in `base`
(with `DISCARDING_LOGGER`, `NO_CLOCK` and `NO_RANDOM`). Hemera's `docs/control_flow.md` (*Pushing a
Whole Context*, *Functions Without a Context*) is the reference, and the parser supports it; the
rest of this document is the original draft. Raised writing Hemera's `docs/calling_convention.md` (*Entry
Functions*). Logged in `../hemera-feedback.md` as *Pushing a complete context*. Blocks the kernel's
entry stubs (`../../docs/specs/arch_interface.md`, *Entry Stubs*, step 3) and its boot entry
(`../../docs/specs/boot_info.md`).

## Problem

`push_context` makes a new context as a **copy of the current one** with some fields overridden:

```
push_context my_context (allocator = memory.ArenaAllocator) { /* ... */ }
```

Three kinds of code start with **no current context**:
- **freestanding entry points** (`TargetOptions.startup_code = false`), like the kernel's boot entry;
- **interrupt functions** (`#calling_convention(.interrupt)`);
- **entry functions** (`.entry`, `.syscall_entry`).

Hemera's docs tell each of them to push one: `docs/compilation.md` says to "`push_context` a context
built from constants", and the interrupt-function docs say to push a context. But there's nothing to
copy, so there's no way to write it. The SlopOS kernel also wants to push a **prebuilt** context,
not build one each time: each CPU's `PerCpu.context`, made once at boot with that CPU's allocator,
logger and random generator (`../design/kernel.md` §3).

The docs also never say what happens in those functions *before* a context is pushed. Every Hemera
call passes the context register, and there's nothing valid in it.

## Proposal

### `push_context name from value`

A second form of `push_context` pushes a whole `runtime.Context` value:

```
push_context cpu_context from cpu.context^ {
    kernel_entry.dispatch(frame)
}
```

- `value` is any expression of type `runtime.Context`. It's **copied** into the pushing frame, like
  the context the override form makes, so the pushed context can't change under the block even if
  the original does.
- It follows the same rules as overrides: everything reachable from it must be an unrestricted
  value (nothing pointing into the stack, `docs/memory.md`, *Contexts*), except `extensions`, whose
  nodes may be on the pushing frame's stack.
- Everything else about `push_context` is unchanged: `name` refers to the new context in the block,
  it's restored when the block is left however that happens, and `defer`s in the block see it.
- It works anywhere, not only where there's no current context. With a current context, it replaces
  it for the block, which is useful for running a callback with a context saved earlier.

The two forms don't combine. `push_context name from base (allocator = x)` would be ambiguous,
because line breaks mean nothing and `base(allocator = x)` reads as a call with a named argument.
Nest them instead:

```
push_context cpu_context from cpu.context^ {
    push_context quiet (log_level = .Error) { /* ... */ }
}
```

The value is followed directly by its block, the way an `if` condition is, so `from cpu.context^ {`
parses without ambiguity.

### Functions without a context

Freestanding entry points, interrupt functions and entry functions have **no current context
until they push one**. In those functions, outside any `push_context ... from` block:
- `context` can't be used;
- the only calls allowed are to **intrinsics** (bodiless `---` declarations in `base`, which compile
  to instructions and take no context), like `intrinsics.set_carrier` and `x86_64.read_gs_base`;
- the override form of `push_context` is an error, since there's nothing to copy.

Calls inside the block get the pushed context as usual. The compiler can check this from the source alone:
each call is either inside such a block or not. (These functions also start without a carrier
block, which is why `intrinsics.set_carrier` comes first and their prologue has no stack check.)

### Building a context from constants

For a freestanding entry point, the value is a struct literal:

```
boot_context :: runtime.Context.{
    allocator = runtime.FAILING_ALLOCATOR,
    logger = early_serial_logger(),
    log_level = .Info,
    clock = &NO_CLOCK,
    random = &NO_RANDOM,
    assertion_handler = runtime.trap_assertion_handler,
    user_data = null,
    extensions = null,
}

kernel_entry #export :: fn() #never_returns {
    // set up the carrier first (see compilation.md)
    push_context boot from boot_context {
        kernel.boot(build_boot_info())
    }
}
```

## How SlopOS Uses It

| Where | Use |
|---|---|
| `boot/limine` entry point (L0) | `push_context boot from` a context built from constants (`../../docs/specs/boot_info.md`, *Handoff*) |
| L0's secondary-CPU entry | The same, then the kernel's `entry` pushes the CPU's own |
| Entry functions (L1) | `push_context cpu_context from cpu.context^`, where `cpu` is the `ArchCpu` found through the `gs` base |
| `std`'s thread entry stub on SlopOS | `push_context` the context the creating thread handed over (`../decisions/0026`) |

## Alternatives Considered

- **Push by pointer** (point the context register at `PerCpu.context` without copying): saves a copy
  of about 80 bytes per kernel entry. But `ptr[Context]` doesn't promise the pointee won't change,
  so a function could no longer rely on its context staying the same, which is the point of
  `push_context`. The copy costs about ten stores, which is small next to the rest of an entry.
- **Let `context = value` assign once in functions without a context:** shorter, but it's assignment
  to the context, which the language rejects everywhere else, and it has no scope to restore.
- **The compiler pushes a context for these functions automatically,** from a `TargetOptions`
  setting: hides where the context comes from, and can't use a per-CPU one.
- **Combine with overrides (`from value (field = x)`):** ambiguous with a call, as above.

## Open Questions

- **The keyword:** `from` is already a keyword (imports). Alternatives: `push_context name = value`,
  or `push_context name (..value)`.
- **A minimal context in `base`:** `Context`'s `clock` and `random` are non-optional pointers, so a
  freestanding program must invent placeholder ones before it has real ones. `base` could provide a
  `runtime.MINIMAL_CONTEXT` (the failing allocator, a logger that drops everything, the trap
  assertion handler, a clock and random generator that fail), or those fields could become optional.
- **`#run` code** always has the compiler's context. Should `push_context ... from` work there too
  (probably yes, unchanged)?
