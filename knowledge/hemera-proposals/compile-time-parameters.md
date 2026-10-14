# Proposal: Compile-Time Parameters Through Generics

Status: **adopted** 2026-10-13, with these answers to the open questions:
- Redundant explicit generics (`size_of[Foo](Foo)`) are allowed, with a compiler warning, and not
  written in `base`, `std` or SlopOS.
- Compile-time values are integers, enums, booleans and functions for now.
- No limit or warning on the number of instances yet; revisit once real usage (like `size_of`'s)
  shows what's common.

Done so far: `x86_64.entry_points` and `new`/`new_aligned`/`new_array`/`new_array_aligned` follow
rule 3 (`T: type`). Not done yet: a generics section in Hemera's docs, and value parameters in
generic lists (`struct[T, capacity: usize]`), which need a grammar and parser change.

Raised by `kernel-entry.md` (*Open Questions*): `x86_64.entry_points`
needs its handler at compile time, and AArch64's `mrs`/`msr` and RISC-V's CSR instructions encode
the register in the instruction. Replaces the `#compile_time` parameter directive suggested there.

## Problem

Some arguments have to be known when compiling:
- **To generate code from them:** `entry_points(user_entry)` makes the compiler emit 256 stubs that
  jump to `user_entry`, so it must know which function that is.
- **To encode them in an instruction:** `mrs x0, TPIDR_EL1` has the register number inside the
  instruction, with no form that takes it from a register.
- **To size or specialize something:** a fixed-capacity ring buffer `Ring[T, 16]`, or a function
  specialized for one constant value.

Hemera's generics already do this for types. Its `fn[T]` is what Jai writes as `$T`, chosen over
Jai's dollar signs for the reasons in Hemera's `docs/faq.md`. But generic parameters are only
types, and how a generic is bound from an argument isn't written down anywhere:

```
// base/builtin/builtin.hsc: T is bound by the parameter with the same name
size_of : fn[T](T: type) -> usize : ---

// base/runtime/alloc.hsc: T is bound by... t?
new :: fn[T](t: type, allocator := context.allocator, loc := #caller_location) -> (ptr[mut T], AllocatorError?)
```

## Proposal

### How generics are bound

A function's generic parameters are bound, for each call, in one of three ways:
1. **Explicitly**, in brackets after the name: `new_array[u8](count)`.
2. **Inferred from a parameter's type:** `free(pointer)` binds `T` from `pointer: ptr[T]`.
3. **By a parameter with the same name:** `size_of(Foo)` binds `T` to `Foo`, because the parameter
   `T` is the generic `T`. The argument must be known at compile time.

Rule 3 is what Jai's `$` on a parameter does, and it's already how `size_of`, `align_of`,
`offset_of`, `type_info_of`, `max_value` and `min_value` are declared.

### Values, not just types

**Rule 3 applies to any parameter type, not only `type`.** A generic parameter with the same name
as a value parameter makes that parameter compile-time:

```
// handler must be a constant, and the compiler generates stubs for each one it's called with
entry_points : fn[handler](handler: (fn(frame: ptr[mut RegisterFrame]) #never_returns)) -> ptr[EntryPoints] : ---
addresses :: x86_64.entry_points(user_entry)

// The register is encoded in the instruction
mrs : fn[register](register: SystemRegister) -> u64 : ---
thread_pointer :: aarch64.mrs(.TPIDR_EL1)

// A function with a body gets one instance per distinct value, where count is a constant
zeroed_buffer :: fn[count](count: usize) -> u8[count] {
    buffer : u8[count]
    return buffer
}
```

- **The argument must be a compile-time constant:** a literal, a named constant, a function, an
  enum member, or the result of `#run`. Anything else is an error at the call.
- **Functions with bodies are instantiated per distinct value**, exactly as they are per distinct
  type, and the parameter is a constant inside the body (usable as an array size, in `#if`, in
  `#assert`).
- **Bodiless declarations** (`---` intrinsics) receive the value at compile time, so the compiler
  can generate code from it or encode it in an instruction.
- The call looks like any other call. Nothing marks it at the call site, as with `size_of(Foo)`.

### Values in a generic list without a parameter

For values that aren't function parameters, like a struct's capacity, the generic list itself
takes `name: type`:

```
Ring :: struct[T, capacity: usize] {
    items : T[capacity],
    head : usize,
    tail : usize,
}

ring : Ring[u8, 4096]
```

Without a matching parameter, these are bound explicitly (rule 1), or inferred from a parameter's
type (rule 2), like `fn[T, capacity: usize](ring: ptr[mut Ring[T, capacity]])`. This one is a
grammar change: the generic list (`generic_tag`) currently takes only types.

## Where It Applies

| Where | Change |
|---|---|
| `base/intrinsics/x86_64` | `entry_points : fn[handler](handler: ...)`. Done with this proposal |
| `base/runtime/alloc.hsc` | `new`, `new_aligned`, `new_array` and `new_array_aligned` take `T: type` instead of `t: type`, so they follow rule 3 like `size_of`. Done with this proposal |
| AArch64 and RISC-V intrinsics, later | `mrs`, `msr`, `csrr`, `csrw` take the register as a compile-time parameter |
| `std`, later | Fixed-capacity containers for the freestanding tier (`Ring[T, capacity]`, bitmaps) |

## Alternatives Considered

- **A `#compile_time` parameter directive** (suggested in `kernel-entry.md`): marks the parameter
  without involving generics. But it would be a second mechanism for what generics already do for
  types, and it wouldn't explain whether a function with a body is instantiated per value.
- **Jai's `#bake_arguments`:** makes a specialized copy of a procedure with some arguments fixed, at
  the place it's used. Useful in its own right, but it's chosen by the caller, while here the
  function itself requires the argument to be constant.
- **One intrinsic per value** (`mrs_tpidr_el1`, `mrs_vbar_el1`, ...): no language change, but dozens
  of declarations per architecture, and no help for `entry_points` or for containers.

## Open Questions

- **Explicit generic arguments for a function whose generic is bound by a parameter:** is
  `size_of[Foo](Foo)` allowed (redundant), an error, or just never written?
- **Which values are allowed:** integers, enums, booleans and functions clearly; strings and struct
  values would need rules for comparing instances.
- **Instance count:** a function instantiated for many values can grow the binary. Worth a limit
  or a warning?
