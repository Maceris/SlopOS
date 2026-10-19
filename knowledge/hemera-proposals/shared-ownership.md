# Proposal: Shared Ownership

Status: **agreed** 2026-10-19, directions chosen with the Hemera author (below). Phases 1 to 4 are in Hemera:
`using` on named fields (`docs/types.md`, *Structs*), `mut` in type arguments (*Mutability in Type Arguments*), and
`#owned` (`docs/memory.md`, *Owned Types*), and std/memory's `SharedPtr`, `LocalPtr` and `WeakPtr` (*Shared
Ownership*); phase 5, thread binding, next. What implementing them settled:
- A `mut` argument is an alias of its type that remembers it, so it only changes pointers, keeps its own instances
  and constraint runs, and has its own type value, which `compiler.Mutable` reads. Inside the generic, the parameter
  is the plain type.
- `mut` is never inferred: `poke(&number, 1)` binds `T = int` from a `ptr[mut int]`. C++ infers `const`, but here
  that would double the instances of every generic taking a pointer. It's written where it's wanted, like
  `poke[mut int](...)`, and a written one isn't warned about as given twice.
- Writing through a `ptr[T]` in a checked body needs `T: compiler.Mutable`, with E4033 saying so.
- `compiler.Mutable(mut int)` in an expression, like `#assert`, doesn't parse yet: `mut` is only in a type's position.
- `#owned` is checked by `ownership.cpp`, walking each body like the bounds prover, with E4035. A type parameter in
  a body checked before any instance counts as copyable: each real instance is checked with its own types, and
  treating every unconstrained `T` as owned would have broken most constrained generics. `compiler.Copyable` says up
  front that a generic copies its `T`.
- Taking an owner's address may fill it, so an empty owner whose address is taken owns from then on: `files :
  File[..]` filled by `array_add(&files, ...)` has to be released with `array_release`.
- A `for` loop's element and a `match` on an owner borrow; a `match` on an owned temporary, like `upgrade(&weak)`'s
  result, gives its bindings ownership.
- `forget`, `duplicate` and `take` are ordinary functions in base/compiler, whose bodies aren't checked;
  `compiler.release` is resolved by the checker to the function the type names.
- The handle's field is `shared_value`, not `value`: the struct's own members come before what `using` forwards, so
  a field called `value` hid the value's own `value`. `memory.pointer_of(&shared)` gives the pointer itself.
- `SharedPtr` and `WeakPtr` are `#unrestricted`: they point at heap blocks, never into a stack, which the escape
  analysis couldn't tell from a handle derived from `&buffer`.
- A generic function named with its arguments and not called, like `release_in_place[T]`, is now a function value of
  that instance, which `make_shared` stores for an `#owned` value's default destroy.
- Derived parameters are values or types by how they're written (`atomic = true` is a value), everywhere a
  generic's arguments are checked.
- Optional function types still need an alias (`Destroy :: alias fn(value: rawptr)`, then `Destroy?`): the
  feedback index's open friction.
- Found along the way: base's `output_unsigned` printed nothing for 0, since `loop { } while` checks first; it's
  `#at_least_once` now, which the generator didn't implement until then (it's documented in `control_flow.md`), and
  the format scenario checks 0.

`std/memory`'s `SharedPtr[T]` counts its owners by hand: every owner calls `increment` and `decrement`, a missed
one leaks or frees early, and the value is always `ptr[mut T]`. This proposal makes shared ownership work like
C++'s `shared_ptr` without hidden calls: the compiler checks that each owner is released, rather than releasing it.

## Directions Chosen With the Hemera Author

- **Counting is explicit and checked.** `share` makes another owner and `release` drops one. A type marked `#owned`
  can't be copied or silently dropped: the compiler reports an owner that goes out of scope without being released
  or moved. No call is ever inserted.
- **The directive is `#owned`**: each value has one owner at a time.
- **Moves are implicit**, like Rust: `b := a`, passing `a` by value, returning it or storing it moves it, and using
  `a` afterwards is an error.
- **The escape hatches are explicit**: a type's own functions end a value with `compiler.forget(value)` and make a
  second owner with `compiler.duplicate(&value)`, anyone can use them, and they're easy to find.
- **Immutable sharing comes from `mut` in type arguments**: `SharedPtr[Buffer]` shares read-only and
  `SharedPtr[mut Buffer]` shares changeable. Inside the generic, `ptr[T]` becomes `ptr[mut Buffer]`.
- **A changeable share turns read-only by itself**: `SharedPtr[mut Buffer]` is accepted (moved) where
  `SharedPtr[Buffer]` is wanted.
- **Access uses `using` on a pointer field**: `using value : ptr[T]` forwards member access, so `shared.field`
  reads the value's field.
- **The layout is a handle plus a block**: a `SharedPtr` is one pointer, to the value, in one allocation with its
  counts, like `make_shared`. Weak references get a weak count.
- **Dynamic arrays of owners are owned** (2026-10-19): `T[..]` holds its elements, so it's `#owned` when `T` is.
- **Atomic by default, not by necessity** (2026-10-19): `SharedPtr[T, atomic = true]`, a derived parameter acting as
  a default, with `#if atomic` choosing the counting in `share` and `release`; `LocalPtr[T]` is an alias for
  `SharedPtr[T, false]`.
- **Releasing at scope end is a directive** (2026-10-19): a type names its release function, `#owned(release)`, and
  `#release` on a parameter or local releases it at the end of its scope, as a `defer` written there would.
- **What runs at the final release is in the block** (2026-10-19), like C++'s type-erased deleter: `make_shared`
  takes it, like `close_file`, and it defaults to the value's own release function when its type is `#owned`, so a
  shared file closes itself. Every `SharedPtr[FileStream]` is one type, whatever closes it.
- **What can't leave its thread is tracked** (2026-10-19), as phase 5: a type marked `#thread_bound`, like
  `LocalPtr`, can't be given to a parameter marked `#crosses_threads`, like a new thread's data or `channel_send`'s
  value. Rust's `Send`, not `Sync`: data races through shared pointers are out of scope.

## Prior Art

| | Counting | Immutable sharing | Reaching the value |
|---|---|---|---|
| C++ `shared_ptr` | Copy constructor and destructor, invisible | `shared_ptr<const T>`, converts from `shared_ptr<T>` | `->` overloaded |
| Rust `Rc`/`Arc` | Moves by default, `clone()` explicit, `Drop` at scope end | Shared is read-only, `RefCell`/`Mutex` inside to change | `Deref` |
| Swift | Retain and release inserted everywhere | `let` and `var` | Built in |
| Zig, Odin, Jai | By hand | `*const T` | By hand |

Hemera sits with Rust on moves, but without `Drop`: where Rust inserts the drop, Hemera asks for it to be written
(`release(a)`, or `defer release(a)`) and reports where it's missing. That keeps Hemera's rule that what runs is
what's written, and still turns a missed release into a compile error.

## 1. `#owned` Types

```
SharedPtr :: struct[T, atomic = true] #owned(release) {
    using value : ptr[T],
}
```

A value of an `#owned` type has one owner: the local, parameter, field or array element holding it. The function
named in `#owned(...)` releases one, taking it by value; it's what error messages suggest, and what `#release`
calls.

- **Moving.** Assigning it to a local, passing it by value, returning it, storing it through a pointer (`p^ = a`,
  `array_add(&list, a)`) or putting it in a struct literal moves it, and the place it came from can't be used again
  until something new is put there.
- **Borrowing.** Taking its address, reading its fields, comparing it, or giving it to an `any` (to log it) doesn't
  move it. Hemera has no borrow checker: a pointer to an owner is checked by the escape rules, as any pointer is.
- **Ending.** On every path out of a scope, each owner it holds has been moved or released: passed by value to a
  function that takes it, like `release`, or named in a `defer` that does. One that isn't is an error where the
  scope ends, naming the path. An owner that's moved on one path and not the other is an error at the merge, with
  which one.
- **Replacing.** Assigning to a place that still owns something is an error: release or move it first.
- **Loops.** Moving something declared outside a loop, inside it, is an error unless the loop puts a new owner
  there before going around.
- **Zero.** An `#owned` type's zero value owns nothing, so a local declared without a value and never given one
  needs no release, and `release` of a zero value does nothing. `compiler.take(&place)` moves out what a place
  holds and leaves zero behind, for moving out of a field or an array element.
- **Containing.** A struct, union or static array holding an `#owned` value is itself owned, and has to say so
  with `#owned`, so it's visible where the type is declared. Releasing it is a function of its own, which releases
  what it holds. A generic type is owned in the instances whose layout holds an owned type.
- **Dynamic arrays.** `T[..]` holds its elements, so it's owned when `T` is: dropping one without releasing its
  elements is caught. `runtime.array_release(array, release)` takes it, releases each element with the function
  given, and frees it. A view, `T[]`, borrows: going through one doesn't move its elements, but moving one out of
  it does, so that's `compiler.take`.
- **Owned by condition.** A container that keeps its elements in memory it allocates and views, like `HashMap`,
  says when it's owned: `HashMap :: struct[K, V, hash] #owned(map_release, !compiler.satisfies(compiler.Copyable(V)))`.
- **Releasing in general code.** `compiler.release(value)` calls the release function a value's type names, for code
  that's generic over owned types, like `make_shared`'s default and `array_release`.
- **Escape hatches.** `compiler.forget(value)` ends an owner without anything happening, and
  `compiler.duplicate(&value)` copies one into a second owner without the type knowing. Each type's own functions
  are built on them (`release` forgets after counting down, `share` duplicates after counting up); anywhere else,
  they're a visible, greppable step outside the rules.

Through pointers and in the heap, the compiler stops tracking: storing an owner through a pointer moves it there,
and whoever owns that memory is responsible for it, as with `#escaping` today. What owns that memory is itself
owned, as dynamic arrays are, so the chain ends at something the compiler does check.

### Releasing at the End of a Scope

`#release` on a parameter or a local releases it, with its type's release function, when its scope ends: the same
as `defer release(name)` written where it's declared, so what runs is still in the code, at the declaration.

```
consume :: fn(reader #release : memory.SharedPtr[Data]) {
    log_info("% items", reader.count)
}                                                   // released here

buffer #release :: memory.make_shared(Buffer.{size = 4096}, destroy_buffer)
```

An owner marked `#release` can't be moved: whether to release it would then depend on the path taken, which needs
flags the code doesn't show. To hand it on, share it, or don't mark it.

### In Generic Code

A template instantiated with an `#owned` type follows the rules in its instance: copying a `T` out of a view, as
`for element in array` does, is a move out through a pointer, an error there. For checked bodies (generic
constraints, phase 2), an archetype might be owned, so copying it needs a promise:

- `compiler.require_copyable(T)`, and a `Copyable` constraint: `T` isn't `#owned`.
- Equality, ordering and the number requirements imply it, since every type with `==` is copyable. So
  `array_find[T: Equatable]` needs nothing new, but a container's value type, like `HashMap`'s `V`, needs
  `V: compiler.Copyable` for `map_get` to return a copy, or `map_get` returns `ptr[V]?` instead.

## 2. `mut` in Type Arguments

```
config : memory.SharedPtr[Config]          // shared read-only
buffer : memory.SharedPtr[mut Buffer]      // shared and changeable
```

A type argument can be written with `mut`. Inside the generic, the parameter is the type wherever it's held by
value, and the `mut` applies wherever it's pointed to: `ptr[T]` is `ptr[mut Buffer]`. `G[X]` and `G[mut X]` are
different instances.

- **Becoming read-only.** `G[mut X]` converts to `G[X]` by itself, moving if it's owned, when every use of `G`'s
  parameter in its layout is under a pointer, so the two have the same layout and only lose the right to change.
  The compiler checks that where `G` is declared, and only offers the conversion for generics where it holds.
- **Checked bodies.** An archetype's pointers are read-only unless `compiler.require_mutable(T)` (a `Mutable`
  constraint) promises the `mut`.

## 3. `using` on a Pointer Field

`using` on a pointer field forwards member access through the pointer: `shared.width` is `shared.value.width` when
`SharedPtr` has no member `width` of its own. Changing it goes by the pointer's mutability, so
`SharedPtr[Config]`'s fields are read-only. It's general: handles, wrappers and intrusive links can use it too. It
doesn't add a conversion to the pointer; passing the value along is written `shared.value`.

## 4. The Handle and Its Block

`SharedPtr[T, atomic = true]` counts atomically, so it can be shared between threads. `atomic` is a derived
parameter, which works as a default: `SharedPtr[T, false]` counts with plain arithmetic, for values that stay on
one thread, and a generic alias names it, `LocalPtr :: alias[T] SharedPtr[T, false]`. Its functions bind `atomic`
from the handle's type and choose with `#if atomic`, so callers never write it. The compiler doesn't count
anything either way: it only checks each owner is released or moved.

```
// Before the value, in the same allocation
SharedHeader :: struct {
    strong : u32,
    weak : u32,
    destroy : fn(value: rawptr)?,
    allocator : runtime.Allocator,
    size : usize,
}

SharedPtr :: struct[T, atomic = true] #owned(release) {
    using value : ptr[T],
}

WeakPtr :: struct[T, atomic = true] #owned(release_weak) {
    value : ptr[T],
}

LocalPtr :: alias[T] SharedPtr[T, false]

make_shared :: fn[T, atomic = true](value #escaping : T, destroy : fn(value: ptr[mut T])? = null,
    allocator := context.allocator) -> SharedPtr[mut T, atomic]
share :: fn[T, atomic: bool](shared: ptr[SharedPtr[T, atomic]]) -> SharedPtr[T, atomic]
release :: fn[T, atomic: bool](shared: SharedPtr[T, atomic])
weaken :: fn[T, atomic: bool](shared: ptr[SharedPtr[T, atomic]]) -> WeakPtr[T, atomic]
upgrade :: fn[T, atomic: bool](weak: ptr[WeakPtr[T, atomic]]) -> SharedPtr[T, atomic]?
release_weak :: fn[T, atomic: bool](weak: WeakPtr[T, atomic])
```

- **One pointer.** The handle points at the value, so `using value` reaches it with no offset, and only the value's
  fields can be reached: no header field can shadow one of them. The header sits right before the value, found from
  it by subtracting its size, with the block aligned for both.
- **Counts.** Atomic ones count up without ordering, and down with release ordering and an acquire fence before
  destroying, as today; plain ones just add and subtract.
- **Weak references.** The block stays while there are weak references, after the value is destroyed when the
  last strong one goes; `upgrade` counts up only while there's still a strong one, with a compare-and-swap loop.
- **What runs at the final release.** `destroy` is called with the value when the last strong owner releases it,
  before the block is freed, for whatever has to happen then: closing a file, returning a buffer to a pool, telling
  someone. It's stored in the header as a function of a `rawptr`, so it doesn't change the type, as with C++'s
  deleter, and the call is one indirect call. When it isn't given:
  - A `T` that's `#owned` is released with its own release function, `compiler.release(value)`, the value moved out
    of the block first; so `make_shared(open_file(path))`, for an `#owned(close_file)` `FileStream`, closes the file
    when the last owner is done, without naming `close_file` anywhere.
  - Any other `T` needs nothing, and nothing runs.
  A `destroy` given for an `#owned` `T` replaces its release function, so it's responsible for what the value holds:
  it gets a `ptr[mut T]` and takes from it what it releases.

```
buffer #release :: memory.make_shared(Buffer.{size = 4096}, destroy_buffer)
reader :: memory.share(&buffer)
spawn_reader(reader)                            // moved into the reader, which releases it
log_info("% bytes", buffer.size)                // through using value
                                                // buffer is released here
```

## 5. Values That Stay on Their Thread

A `LocalPtr` counts with plain arithmetic, so two threads releasing it at once would lose a count. Types like it say
so, and the few places that hand a value to another thread check for it.

```
SharedPtr :: struct[T, atomic = true] #owned(release) #thread_bound(!atomic) {
    using value : ptr[T],
}

thread_create :: fn(function: ThreadFunction, data #escaping #crosses_threads : any? = null, ...) -> ptr[mut Thread]
channel_send :: fn[T, capacity: usize](channel: ptr[mut Channel[T, capacity]], value #escaping #crosses_threads : T) -> bool
```

- **Marked, not assumed.** `#thread_bound` is opt-in, like `#owned`, so everything that isn't marked can cross as it
  always could.
- **Spreading.** A type is thread-bound when it's marked, when its layout holds a thread-bound type (fields, static
  and dynamic arrays, unions), or when one of its type arguments is: `SharedPtr[LocalPtr[Config]]` is bound, since
  sharing it between threads would let two of them release the `LocalPtr` inside. A condition makes it depend on the
  instance: `#thread_bound(!atomic)`.
- **Crossing points.** A parameter marked `#crosses_threads` takes nothing thread-bound. In base and std that's
  `thread_create`'s and `fiber_create`'s `data` (a pool's fibers move between its threads), `spawn`'s, and
  `channel_send`'s `value`; anything that hands work to another thread does the same. An `any` given to one is
  checked by the value's own type, which is known where it's passed.
- **The error** names what makes the value bound: `LocalPtr[Config] is #thread_bound (SharedPtr with atomic =
  false), so it can't be given to thread_create's data`.
- **Moving an owner across.** Giving an `#owned` value to an `#escaping` `any`, as thread data, moves it: the new
  thread owns it.
- **Contexts.** A new thread starts with a copy of its creator's context, extensions included; a thread-bound value
  in one is reported where the thread is made, like any other crossing.

What this doesn't do is prove there are no data races: two threads changing what one `ptr[mut T]` points to is still
the program's to prevent, with locks, atomics or channels. That would be Rust's `Sync`, or its borrow rules, a design
of its own.

## Phases

1. **`using` on pointer fields.** Small and independent.
2. **`mut` in type arguments**, with the read-only conversion and `require_mutable`.
3. **`#owned`**: moves, the end-of-scope check, merges and loops, `forget`, `duplicate`, `take`, `release`, owned
   dynamic arrays and `array_release`, owned-by-condition, `#release`, and `require_copyable` for checked bodies.
4. **`std/memory`'s new `SharedPtr`, `LocalPtr` and `WeakPtr`**, and `make_shared`; the old
   `increment`/`decrement` go.
5. **`#thread_bound` and `#crosses_threads`**, with base and std's crossing points marked, so `LocalPtr` is checked.

## Open Questions

- Data races through shared mutable pointers (Rust's `Sync`): out of scope here.
- Settled 2026-10-19: dynamic arrays of owners are owned; non-atomic counting is a parameter, not a separate type;
  releasing at scope end is `#release`, not inferred; what runs at the final release is in the block; keeping a
  `LocalPtr` on its thread is phase 5.
