# Proposal: Typed Context Extensions (a `pNext`-Style Chain)

Status: **draft**, for discussion on the Hemera side. Raised by SlopOS's question about the
friction of every subsystem sharing `Context.user_data: rawptr` (`../hemera-feedback.md` §2,
`../design/kernel.md` §3).

## Problem
Programs can't add fields to `Context`, so everything that needs per-call-tree state beyond
the built-in fields goes through one `user_data: rawptr`.
- **In the SlopOS kernel this is fine.** The kernel is the only user, and `user_data` points
  at its `PerCpu` block (`../design/kernel.md` §3).
- **In user space it isn't.** `std`'s OS layer (the process's connections: clock server,
  entropy, powerbox), a server framework (the current connection, its lent CPU budget), a
  tracing library and the program itself all want a slot. Whoever sets `user_data` last
  wins, and every reader casts a `rawptr` and hopes.

So far the answer has been to promote common needs to real fields (`clock`, `random`), but
adding a field changes the layout of `Context`, which every call passes. On SlopOS that is an
ABI break (`../design/system-abi.md` §7).

## Proposal
A chain of typed extension nodes, as in Vulkan's `pNext` chains, but scoped like the rest of
`Context`:
```
ContextExtension :: struct {
    type: typeid,                   //HEMERA(guess): name of the runtime type identifier
    next: ptr[ContextExtension]?,
    data: rawptr,
}

Context :: struct {
    ...
    extensions: ptr[ContextExtension]?,   // replaces, or sits next to, user_data
}

// std: typed access, the only place that casts
context_get :: fn[T]() -> ptr[T]? { ... }    // walk the chain, match typeid(T)
with_extension :: fn[T](value: ptr[T], body: fn()) { ... }   // push_context with a new head
```

### Why a chain fits Hemera's context model
- **The chain is persistent (never mutated in place).** Adding an extension makes a new node
  whose `next` is the current head, and installs it with `push_context`. When that context is
  popped, the old head is back automatically. Scoping is just the existing
  `push_context` behaviour, with no cleanup code.
- **Type-safe at the use site.** `context_get[MyState]()` returns `ptr[MyState]?`. The
  `rawptr` cast lives in one generic function, keyed by `typeid`.
- **ABI-stable.** `Context` gains one pointer, once. Libraries add extension types without
  changing `Context`'s layout.

### Costs and questions
- **Lookup is O(chain length).** Chains are short (a handful of nodes), and a hot path can
  look its extension up once and pass the pointer down. Alternatively, a tiny inline cache
  in the node.
- **Node lifetime.** Since 2026-10-04 Hemera allows pointers to the stack, and fiber frames
  never move, but `push_context` overrides must be unrestricted values (Hemera
  `docs/memory.md`, *Contexts*), so a node on the pushing frame's stack still can't be
  installed. It must come from `context.allocator` or an arena: one allocation per push.
  Worse, threads and fibers created inside the scope copy the context, chain pointer included,
  and can outlive the scope, so a node can't be freed when the scope ends. Options: nodes are
  immortal (allocated once per extension type and reused), owned by an arena that outlives
  every fiber the scope creates, or reference-counted.
- **Context size now costs per fiber.** Every fiber embeds a copy of its root context in its
  ~1.4 KiB block (Hemera `docs/multitasking.md`, *Memory Budget*), so growing `Context`
  costs memory per idle fiber as well as an ABI change. One `extensions` pointer is cheaper
  than any number of new fields.
- **Is `typeid` stable across separately compiled libraries?** It must be, for a library's
  extension to be found by code compiled separately. On SlopOS, content hashes of type
  definitions would work.
- **Does it replace `user_data`?** Suggest keeping `user_data` for the one-owner case
  (kernels, embedded programs) and adding `extensions` for composition.

## Alternatives
- **Keep `user_data` and let each program define one struct of everything.** Works for
  applications, but libraries can't add their own state without the program's cooperation.
- **Compile-time-assembled `Context`:** the program registers extension fields with `#run`,
  and the compiler generates a `Context` with them. Lookup is free, but the layout differs
  per program, so separately compiled and shared libraries break.
- **Thread-local storage:** exactly what Hemera removed (`../design/threads.md`).
