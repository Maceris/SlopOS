# Proposal: `#no_return` for Functions That Never Return

Status: **adopted** 2026-10-13 as **`#never_returns`**, with `AssertionHandler` marked and no
`or_else` fallback (an `if` before the call is enough friction for something this rare). Hemera's
`docs/directives.md` (*Functions*) is the reference, and the parser supports it; the rest of this
document is the original draft. Raised by `../../docs/specs/arch_interface.md`; the Hemera author
asked for a compiler directive whose information reaches MLIR and LLVM. Logged in
`../hemera-feedback.md` as *Functions that never return*.

## Problem

Several functions never return, and today that is only a comment:
- in Hemera's `base` and `std`: `intrinsics.trap`, `runtime.trap_assertion_handler`, every
  `AssertionHandler` (*"if a handler returns, assert traps"*), and `os.exit`;
- in SlopOS's kernel: `return_to_user`, `idle`, `halt`, the `kernel_entry` handlers, the
  kernel's `boot` entry, and the `entry` function `BootInfo.start_cpu` calls.

Without a declaration:
- **nothing checks it:** a handler that falls off its end returns into code that assumes it
  can't;
- **callers can't use it:** code after `os.exit(1)` still has to satisfy "every path returns a
  value", and the optimizer keeps the code after the call;
- **the conformance check can't compare it** between an `arch_interface` declaration and its
  implementation.

## Proposal

### Syntax

A directive, `#no_return`, written where other function directives go:

```
// On a declaration, after the name, like #export and #calling_convention
exit #no_return :: fn(code: int) {/* ... */}
trap #no_return : fn() : ---

// In a function type, after the parameter list
AssertionHandler :: alias fn(location: SourceCodeLocation, message: string) #no_return
start_cpu : fn(cpu: ptr[BootCpu], carrier: ptr[mut runtime.CarrierBlock], entry: fn() #no_return)?
```

Both forms mean the same thing: `#no_return` is **part of the function's type**.

### Rules

1. **No results.** A `#no_return` function has no `->`, or `-> void`.
2. **The body can't finish.** `return` is an error, and so is reaching the end of the body. Every
   path must end in a call to a `#no_return` function, or in a `loop` with no `break` out of it.
3. **A call ends the path.** For the caller, code after the call is unreachable, exactly as
   after a `return`. A path that ends in such a call needs no `return` value.
4. **`defer` doesn't run.** The call never returns, so the caller's scopes are never left and
   their `defer`s never run. `os.exit` behaves like C's `exit` in that respect.
5. **Conversion only drops it.** A `fn() #no_return` value can be used where a `fn()` is
   expected, since the caller only loses the guarantee. A `fn()` can't be used where a
   `fn() #no_return` is expected.
6. **Declarations without bodies are trusted:** `---` intrinsics and foreign functions (C's
   `exit`, `abort`).
7. **Reflection:** `FunctionInfo` and `TypeInfoFunction` gain `no_return : bool`, so compile-time
   checks (like the arch-interface check) can compare it.

### Lowering

- The front end marks the `func.func` with a unit attribute (`hmir.no_return`).
- Lowering to the LLVM dialect gives the function LLVM's **`noreturn`** attribute (through the
  `llvm.func` `passthrough` list, if the dialect has no dedicated attribute).
- **Every call** to a `#no_return` function, direct or through a function pointer of a
  `#no_return` type, is followed by **`unreachable`**. That gives LLVM the same information at
  indirect call sites without depending on call-site attributes, and lets it remove the code
  after the call.

## Where It Would Apply

| Where | Function |
|---|---|
| `base/intrinsics` | `trap` |
| `base/runtime` | `AssertionHandler` (the type), `trap_assertion_handler`. `assert`'s final `trap` stays, for a failure inside a handler |
| `std/os` | `exit` |
| SlopOS `arch_interface` | `return_to_user`, `idle`, `halt` |
| SlopOS `kernel_entry` | `syscall`, `user_fault`, `interrupt`, `kernel_fault`; `critical` splits into a returning `nmi` and a `#no_return` `fatal` for machine checks and double faults |
| SlopOS `boot_info` | `start_cpu`'s `entry`, and the kernel's `boot` |

## Alternatives Considered

- **A `never` type** (Zig's `noreturn`, Rust's `!`): composes with expressions, so a `match` arm
  or an `or_else` can call `exit` where a value is expected. But it adds a type to the type
  system, with rules for it in generics, optionals and aliases, for a property that's about the
  function, not a value.
- **Leave it to comments:** what Hemera does today, with the problems above.
- **Infer it from the body:** works for functions with bodies, but not for `---` declarations,
  foreign functions or function pointers, which are most of the cases above, and an accidental
  infinite loop would silently change a function's type.

## Open Questions

- **Name:** `#no_return` (LLVM's and C's `noreturn`), or `#never_returns`.
- **As a fallback value:** should `value :: lookup(key) or_else os.exit(1)` be allowed, since the
  fallback never produces a value? Natural with a `never` type; with a directive it would be a
  special case for `or_else` (and maybe `match` arms).
- **`AssertionHandler`:** making the type `#no_return` turns "handlers must not return" from a
  runtime trap into a compile error. Every handler would have to end in `exit`, `trap` or another
  `#no_return` call.
