# Proposal: Constraints on Generics

Status: **agreed** 2026-10-18; phase 1 done (*Phases*), phase 2 (checked bodies) next. In Hemera: `#constraint`,
the first requirements, `T: C` with `&&`/`||`/parentheses, `where` clauses on functions, structs and unions, checking
where instances are made with E4032 and its reasons, constraints on `array_find` and std's containers,
`compiler.satisfies`, `require_any`, derived parameters and generic aliases (Hemera's `docs/types.md`, *Constraints*,
*Derived Parameters* and *Generic Aliases*). What implementing it settled:
- The core constraints (`Equatable`, `Ordered`, `Integer`, `Float`, `Numeric`, `AtLeastOne`, `PowerOfTwo`) are in
  `base/compiler`, not a new `std/constraints`, since base's own generics (`array_find`) need them.
- `where` is a word only after a signature or generic list, not a keyword, since SlopOS and tests use it as a name.
- `T: Name` in a generic list is a constrained type parameter when `Name` is a `#constraint` function, and a value
  parameter when it's a type: the checker resolves it, since the two look the same.
- An instance whose constraints fail isn't checked, so its body can't add errors of its own.
- A derived value is an untyped constant in the body, like a literal; compile-time code can now return `type`.
- Overriding a derived parameter means giving the ones before it, which isn't warned about as giving them twice.
- A generic alias's list and `where` sit on the `alias` word: `Named :: alias[V] Pair[string, V] where ...`. When
  what it names fails its own constraints, the error points at the alias's declaration, not the use.

Directions chosen with the Hemera author:
- **Checked generics**, or at least a serious attempt: a constrained generic's body is checked
  against what its constraints promise, before anything instantiates it. What can't be decided that
  way is checked again at instantiation, as today.
- **Structural:** a type satisfies a constraint because of what it is and what exists for it, never
  because it declares that it does.
- **Functions a generic needs are given to it,** as compile-time parameters, since without
  overloading they're named per type (`hash_point`), not found by a shared name. A whole-program
  lookup stays possible as a later convenience (*Finding Functions*), with waiting and cycles
  through `#if` handled like other `#if` cycles.
- **Both syntaxes:** `fn[T: Equatable]` in the generic list and a `where` clause. Constraints
  combine like short-circuiting boolean expressions, with `&&`, `||` and parentheses, in both.
- **`#constraint`** marks a constraint, rather than a keyword. Constraints are limited: never
  generic themselves, and made only of requirements, other constraints, `#if` and `compiler`
  queries, so they're quick and can always run on archetypes.
- **Explicit:** the compiler never picks anything for a generic, like a default hash function: the
  caller passes it, and type aliases shorten what's used often. Functions passed this way are named
  like any others, in snake_case, with no special convention.
- **Derived parameters:** a generic's author can work out one parameter from others, like
  `E = element_of(C)`, bound once what it depends on is. Like a default argument, the caller may
  give it instead, and the constraints then check what was given.
- **A constraint's body can be as involved as it needs,** including alternatives
  (`compiler.require_any(...)`). Since the more involved it is, the less obvious what it promises,
  the requirement vocabulary starts small and grows where real uses show friction or confusion.
- **Only explicit constraints apply:** an unconstrained `fn[T]` stays a template, checked per
  instantiation as today. Libraries that want more can enforce their own house rules with
  build-time code that analyzes the program, beyond what constraints say.
- **Visible at compile time:** code can ask whether types satisfy a constraint, in `#if` and
  compile-time functions.
- **Two new error codes:** a constraint that isn't satisfied (at instantiation), and a checked body
  using what its constraints don't promise. Constraints give the details: why, not just which.

## Problem

A Hemera generic is a template: its body is checked once for each set of type arguments, and may use
anything they happen to support. That keeps generics simple, but:
- **Nothing says what a generic needs.** `array_find :: fn[T](array: T[], value: T) -> usize?`
  compares with `==`, which only its body shows. Readers, and `compiler.package_info`, can't tell.
- **Errors come from inside the body,** at the instantiation: `array_find(points, p)` with a struct
  `Point` reports that `==` doesn't work on structs, in `base/runtime/array.hsc`, not that
  `Point` isn't something `array_find` takes.
- **A generic nobody instantiates isn't checked,** except what doesn't depend on its parameters.
  The generate-everything sweep has to instantiate each one by hand to find out.
- **Value parameters have no rules:** `RingBuffer[T, 0]` or a capacity that isn't a power of two
  fails late, or not at all.
- **A library generic can't say which of the user's functions it needs:** a `HashMap[K, V]` needs
  a hash for `K`, which the user names after their type (`hash_point`), since there's no overloading.

## What Hemera Already Has

- No methods and no operator overloading (`docs/about.md`): what a type supports is decided by its
  kind (numbers, characters, booleans, enums, pointers, strings, structs, unions, arrays), its
  fields, and the free functions that take it. So capabilities are a small, closed vocabulary,
  plus "these functions exist".
- No function overloading, so constraints never have to rank candidates. That's where most of C++
  concepts' complexity (subsumption, partial ordering of constraints) comes from.
- Compile-time execution of ordinary code, reflection through `type_info_of` and `base/compiler`,
  and `compiler.report_error`, so a constraint can be an ordinary function.
- Value generics (`struct[T, capacity: usize]`), which constraints should cover too.

## Prior Art

| | Constraint is... | Bodies checked against it? | Satisfied by | Notes |
|---|---|---|---|---|
| **C++20 concepts** | A named predicate, usually `requires { a == b; }` (this expression is valid) | No | Structure | Subsumption ranks overloads; errors still nest deeply |
| **C++0x concepts** (dropped 2009) | Concept with signatures, concept maps | **Yes, with archetypes**: the body was checked against stand-in types having only what the concept promised | Mostly nominal (concept maps), "auto concepts" structural | The closest prior art for checking bodies against structural promises. ConceptGCC implemented it; it was dropped for complexity and compile time, mostly around concept maps and overloading, which Hemera doesn't have |
| **Rust traits, Haskell type classes** | A named set of functions, with types implementing it | Yes | Nominal (`impl`, `instance`) | Excellent errors. Coherence/orphan rules decide which impl applies |
| **Go 1.18+** | An interface as a type set: `~int \| ~float64`, `comparable`, methods | Yes | Structural | Simple, but can't say "has field `count`" |
| **Swift protocols, Carbon interfaces** | Named requirements | Yes | Nominal | **Carbon has both checked generics and templates**, side by side: precedent for keeping today's templates while adding checked ones |
| **Nim concepts** | `type C = concept x: x < x is bool` | Partly | Structural | |
| **D** | `if (isInputRange!R)`: compile-time boolean | No | Structure | `__traits(compiles, ...)`; "does not match template declaration" says nothing about why |
| **Odin** | `where intrinsics.type_is_numeric(T)` | No | Structure | Names the clause that failed |
| **Jai** | `#modify { ... }`: code run at instantiation that can reject or change `T`; `$T/Interface` for struct members | No | Structure | Custom messages from `#modify` |
| **Zig** | Comptime duck typing, `@compileError` by hand with `@typeInfo`/`@hasDecl` | No | Structure | Great errors when written by hand, otherwise errors deep in the body |

The design below is C++0x's archetype idea, without concept maps or overloading, with constraints
written as ordinary compile-time code as in Jai and Zig, and named and combined as in C++20.

## Design

### 1. A constraint is a compile-time function of requirements

```
// Values of T can be compared with ==
Equatable #constraint :: fn(T: type) {
    compiler.require_equality(T)
}

// Values of T have an order: <, <=, >, >=, and ==
Ordered #constraint :: fn(T: type) {
    Equatable(T)
    compiler.require_ordering(T)
}

// K can be a hash table's key, hashed by hash: == on K, and hash a function of a K giving a u64
Hashable #constraint :: fn(K: type, hash: fn(key: K) -> u64) {
    Equatable(K)
}

// Something with a length, like a view or a dynamic array, or a struct with a count field
Counted #constraint :: fn(T: type) {
    compiler.require_field(T, "count", usize)
}

// A container's capacity: a value parameter, checked when it's instantiated
AtLeastOne #constraint :: fn(capacity: usize) {
    compiler.require(capacity > 0, "a capacity of % holds nothing; it needs to be at least 1", capacity)
}

PowerOfTwo #constraint :: fn(capacity: usize) {
    AtLeastOne(capacity)
    compiler.require(capacity & (capacity - 1) == 0, "% isn't a power of two", capacity)
}
```

- `#constraint` marks a function the compiler runs at compile time, with any mix of type and value
  parameters, and nothing to return.
- **Requirements** are `compiler.require_*` calls. Each one either holds or records a failure with
  its reason, and checking goes on, so one run reports everything that's missing.
- **Composition is a call.** `Ordered` calls `Equatable`, so a failure inside it is reported as
  `Ordered` → `Equatable` → the reason.
- A requirement can carry its own message, for library authors:
  `compiler.require(capacity > 0, "a RingBuffer needs room for at least one element")`.
- **Details:** a failed requirement's reason is the first line of the error. `compiler.note(...)`
  adds lines a constraint thinks will help, like what the type is instead, or what to write:
  `compiler.note("% is a struct; give it a hash function and pass that as hash", K)`.
- **A function parameter's type is its requirement:** `hash: fn(key: K) -> u64` in `Hashable`'s
  parameters means only functions with that signature can be given, checked like any argument.
  Anything more about it (that it's `#no_context`, say) is a requirement in the body, from
  `type_info_of(hash)`.

The requirement vocabulary in `base/compiler`, small and closed, since types can only do what
their kind, fields and functions allow:

| Requirement | Means | In a checked body, allows |
|---|---|---|
| `require_equality(T)` | `==`, `!=` | those operators |
| `require_ordering(T)` | `<`, `<=`, `>`, `>=` | those operators |
| `require_integer(T)`, `require_signed(T)`, `require_unsigned(T)`, `require_float(T)`, `require_numeric(T)` | That kind of number | Arithmetic, bitwise operators for integers, literals of T, `max_value(T)` |
| `require_kind(T, .POINTER)` and friends | A kind, from `compiler.TypeInfoVariant` | What that kind allows, like `^` |
| `require_field(T, name, type)` | A struct with that field, or a view's `count` | Reading (and with `mut`, writing) the field |
| A constraint's function parameter | The function given for it has that signature | Calling it, by the parameter's name |
| `require(condition, message, args...)` | Anything computable, usually about value parameters | Nothing in the body; checked at instantiation |

What every `T` allows, with no requirements: being copied, assigned, passed and returned, `size_of`,
`align_of`, pointers to it, and arrays, views, optionals and results of it. That's all a generic
container needs.

### 2. Generics name their constraints

```
array_find :: fn[T: Equatable](array: T[], value: T) -> usize?

// The hash function is a compile-time parameter, like entry_points' handler
HashMap :: struct[K, V, hash: fn(key: K) -> u64] where Hashable(K, hash) { ... }
points : HashMap[Point, int, hash_point]

// Several on one parameter, and alternatives
sorted_unique :: fn[T: Ordered && Equatable](values: T[]) -> T[..]
average :: fn[T: Integer || Float](values: T[]) -> T

// Relations between parameters, and value parameters, in a where clause
convert :: fn[From, To](value: From) -> To where Convertible(From, To)

RingBuffer :: struct[T, capacity: usize] where PowerOfTwo(capacity) { ... }
```

- `T: C` is short for `where C(T)`. Constraints combine with `&&`, `||` and parentheses, in the
  generic list (`T: (Integer || Float) && Ordered`) or a `where` clause, whose conditions are
  joined by `&&`. Both can be used at once:
  ```
  sum :: fn[C, E: (Numeric || NumberLike) && SmallNumber](container: C) -> E
      where ContainerOf(C, E) || NearlyContainerOf(C, E)
  ```
- **`||` in a checked body** allows what every alternative promises, and no more: `Integer || Float`
  allows arithmetic and ordering but not bitwise operators. A body that needs more checks which it
  has with `#if compiler.satisfies(Integer, T)`, whose branch gets that alternative's promises.
- **Errors for `||`** list why each alternative failed.

#### How a constraint expression is worked out

A constraint expression reads like a short-circuiting boolean expression, but each part gives more
than a boolean, so it's worked out its own way:

- **At instantiation,** each constraint call gives *satisfied*, or *not, because...* with its
  reasons. `A && B` works out `A` first and stops if it isn't satisfied, like `&&`, so `B` can rely on
  what `A` checked: `IsStruct(T) && HasCount(T)`. `A || B` stops at the first one that's satisfied.
  The error for an unsatisfied expression gives the reasons along the path it took: for `&&` the part
  that failed, for `||` every alternative.
- **On archetypes (the early check),** each part gives what it *promises* the body instead.
  `A && B` promises what either does (both hold), and `A || B` only what both do (either might be
  the one that holds). A part that can't be worked out on an archetype (an opaque constraint)
  promises nothing, and `||` with it promises only what the other side and it share: nothing.
- **Order matters only for short-circuiting,** never for meaning: constraints have no effects, so
  `A && B` and `B && A` accept the same arguments, but `B` may then report reasons that `A` would
  have made unnecessary.
- **A where clause** is one expression over all the generic's parameters, worked out after the
  generic list's constraints, once every parameter it mentions is bound (*Derived Parameters*).

### 3. Two checks: the body early, the arguments at instantiation

**Early, at the declaration (checked generics).** The compiler runs each constraint once with
**archetypes**: stand-in types, one per type parameter, that have nothing of their own. Run on an
archetype, a requirement can't fail: it records a **capability** instead, like "T has `==`" or
"`hash(T) -> u64` exists". The body is then checked once, with each type parameter bound to its
archetype, so it can only use what was promised:

```
array_find :: fn[T](array: T[], value: T) -> usize? {
    for element, index in array {
        if element == value {      // error: == on T, which array_find's constraints don't promise
                                   //   add T: Equatable (base/compiler: require_equality)
```

- This happens even if nothing instantiates the generic, so the sweep's hand-written instances
  become unnecessary for constrained generics.
- A function the generic was given, like `HashMap`'s `hash`, is called in the body through its
  parameter, whose signature the constraint fixed.
- The escape and bounds analyses run on the archetype body too, assuming the worst of `T` (that it
  may hold pointers into the stack, that its size is unknown), so what they prove holds for every `T`.

**At instantiation.** The constraints run again with the real arguments. A failed requirement is
reported at the instantiation, with the chain that led to it:

```
main.hsc:12:9: error E4032: array_find[T = Point]: Point isn't Equatable
    Point is a struct, which has no ==
    (Equatable at std/constraints.hsc:4, needed by array_find at base/runtime/array.hsc:110)
```

Then the body is checked with the real arguments, as today. For a checked generic this should never
find anything new. It still runs, because it's what generates the instance, and because some things
only show up with real arguments, like bounds proofs that use a value parameter.

### 4. When a body can't be checked early

A constraint may branch or compute: `if compiler.is_integer(T) { ... }`, or a requirement that
depends on a value. Run on an archetype, a **question** (`compiler.is_integer`, as opposed to
`compiler.require_integer`) has no answer. Proposed rules:

- Questions about an archetype make the constraint **opaque**: it still gates arguments at
  instantiation, but promises nothing to the early check, so a body that relies on it is reported
  as needing a requirement it can't see.
- `require(condition, ...)` with a condition about values, like `capacity > 0`, is checked at
  instantiation only. In the early check, the bounds prover could take it as a fact about
  `capacity`.
- An **unconstrained** generic, `fn[T]` with no constraints at all, stays a template, checked only
  per instantiation, as today, and always will: constraints only apply where they're written. It's
  also how every existing generic keeps working while `base` and `std` gain constraints one at a time.
- A library that wants stricter rules, like "every generic in this package is constrained", can
  check them itself with build-time code over `compiler.package_info`, like any house rule.

That makes checked generics opt-in by writing constraints, like Carbon's split between checked
generics and templates.

### 5. Functions a generic needs

Without overloading, functions are named for what they take: `hash_point`, `hash_string`. So a
generic that needs one takes it as a compile-time parameter, like `x86_64.entry_points(handler)`,
and its constraint says what it must be:

```
HashMap :: struct[K, V, hash: fn(key: K) -> u64] where Hashable(K, hash) { ... }

hash_point :: fn(point: Point) -> u64 { ... }
points : HashMap[Point, int, hash_point]
```

- In a checked body, `hash(key)` calls the parameter, whose signature is known, so nothing is looked
  up and nothing waits.
- std can give the common ones (`hash_string`, `hash_integer[T: Integer]`), but the caller always
  passes one: `HashMap[string, int, hash_string]`. No default is picked for them, so a wrong
  pick can't happen quietly.
- A type alias names a combination that's used often, like C++'s `using`:
  ```
  StringHashMap :: alias HashMap[string, int, hash_string]
  ```
  A generic alias goes further, fixing some parameters and leaving others (*Generic Aliases*).
- **Rejected for now: finding the function by name.** `require_function("hash", ...)` searching the
  whole program assumes one name for every type's hash, which overloading would give and Hemera
  doesn't have.

#### Finding Functions (later)

If passing functions turns out too verbose, a constraint could search the whole program for
functions by signature and a convention, like `compiler.find_functions(fn(key: K) -> u64,
prefix = "hash_")`, giving what it finds, for the constraint to pick from or report:

- **None, or more than one,** is the constraint's to report, listing the candidates.
- **Waiting:** the program's functions are only all known once every import is, including imports
  behind `#if`. A search waits until then, the way checking waits for a declaration. One that an
  `#if` deciding an import waits for (directly, or through `compiler.satisfies`) is a cycle,
  reported at both, like other `#if` cycles.
- **Generic candidates and cycles:** a candidate like `hash_list[T: Hashable]` has constraints of
  its own, and checking them can lead back to the one being worked out. The compiler keeps a stack
  of the constraints being checked, with their arguments: the same constraint with the same
  arguments again is a cycle, reported with the stack, rather than recursing. Different arguments
  each time (`List[List[List[...]]]`) are cut off at a depth limit, as instantiation already is.

### 6. Asking at compile time

```
#if compiler.satisfies(Hashable, Point) {
    POINT_SET :: HashSet[Point]
}

// Specializing without overloading: one generic choosing at compile time
format_value :: fn[T](value: T, out: ptr[mut TextBuffer]) {
    #if compiler.satisfies(Formattable, T) {
        format(value, out)
    }
    else {
        append_bytes(out, value)
    }
}
```

- `compiler.satisfies(C, args...) -> bool` runs the constraint without reporting anything.
  `compiler.unsatisfied(C, args...) -> string[]` gives the reasons, for build packages and tools.
- `compiler.package_info` lists each generic's constraints and each constraint's requirements, so
  documentation tools can show them.
- An `#if` on `satisfies` in a generic body is decided per instance. In the early check, its branch
  is checked with the capability added, like Zig's comptime dispatch.

## Examples From std

| Generic | Constraint |
|---|---|
| `array_find` | `T: Equatable` |
| `RingBuffer[T, capacity]`, `Channel[T, capacity]`, `FixedArray[T, capacity]` | `where AtLeastOne(capacity)` |
| `Bitmap[size]` | `where AtLeastOne(size)` |
| `memory.SharedPtr[T]` | None: it only copies `T` |
| `is_ok`, `is_error` | None |
| A future `HashMap[K, V, hash]` | `where Hashable(K, hash)` |
| `strings.parse_*` made generic over integer types | `T: Integer` |

## Phases

1. **Constraints that gate.** `#constraint`, the first requirements (*The First Requirements*),
   `T: C`, `where`, `&&`/`||`/parentheses, checked at instantiation with the chained error messages
   and the new error code, plus `compiler.satisfies`, derived parameters and generic aliases. No
   body checking yet, so no archetypes. This alone fixes the documentation and error-location
   problems, and value generics' rules.
2. **Checked bodies.** Archetypes, capabilities recorded from constraints, and the early check of
   constrained bodies, including the escape and bounds analyses on them. Unconstrained generics
   stay templates.
3. **Constraints in base and std,** like `array_find`'s `Equatable` and the containers' capacities,
   a `HashMap` taking its hash function, and the sweep's hand-written instances shrinking to the
   unconstrained generics that remain.
4. **Maybe, later: finding functions,** if passing them turns out too verbose.

## Derived Parameters

Some generics are about something inside a type: a function summing any container wants the
container's element type, like Rust's associated types (`Iterator::Item`). The generic's author
works it out from the type, with a compile-time function, written in the generic list:

```
// The type of C's elements: a view's, a dynamic array's, or a struct's data field's
element_of :: fn(C: type) -> type { ... }

sum :: fn[C, E = element_of(C)](container: C) -> E where E: Numeric && ContainerOf(C, E)
```

- A **derived parameter** (`E = ...`) is worked out by the generic, so the call is just
  `sum(points)`. Like a default argument, a caller may give it instead (`sum[Points, i64](points)`),
  and then the generic's constraints decide whether what was given works: the where clause still
  has to hold with `E = i64`.
- **Binding happens in steps,** since `E` can't be worked out until `C` is known:
  1. The parameters the call binds (from arguments, by name, or in brackets), as today.
  2. Each derived parameter, once everything its expression mentions is bound, in the order that
     needs, whatever order they're written in. One that needs itself, directly or through others,
     is an error naming the cycle.
  3. The constraints, on each parameter as it's bound and then the where clause, so a constraint
     on `C` can stop `element_of(C)` from being worked out for a type it doesn't make sense for:
     `fn[C: Container, E = element_of(C)]`.
- **In the early check,** a derived parameter is an archetype of its own, promising what its
  constraints promise. What the function would work out isn't known until there's a `C`.
- A derived parameter can be a value too: `fn[T, bits = size_of(T) * 8]`.

### Alternatives in a Constraint's Body

A constraint's body can choose between alternatives too, and check whatever it needs:

```
// A number std's formatting can write
Formattable #constraint :: fn(T: type) {
    compiler.require_any(Integer(T), Float(T), Character(T))
}
```

- `require_any` is satisfied by the first that is, like `||`, and otherwise reports why each wasn't.
- On archetypes, it promises what every alternative shares, as `||` does.
- **Showing what's promised:** since an involved constraint can make that hard to see,
  `compiler.package_info` gives each constraint's promises as worked out on archetypes (what a
  checked body may use), and the error for a checked body using something unpromised names the
  constraint that would have to promise it. Documentation tools can show both.

## Generic Aliases

An alias can take generic parameters of its own, fixing some of what it names and leaving others:

```
StringMap :: alias[V] HashMap[string, V, hash_string]
names : StringMap[int]                        // HashMap[string, int, hash_string]

Ring :: alias[T] RingBuffer[T, 256]
```

- It's the same type as what it names with its arguments filled in, not a new one, like a plain
  alias: `StringMap[int]` and `HashMap[string, int, hash_string]` can be used for each other.
- Its parameters can have constraints and a where clause, checked when it's used, in addition to
  the named type's own: `SmallRing :: alias[T, capacity: usize] RingBuffer[T, capacity] where capacity <= 64`.
- `distinct alias[...]` makes a new type for each set of arguments, as `distinct alias` does now.
- Where the parameters go (`alias[V] HashMap[...]`, or `StringMap[V] :: alias HashMap[...]`) is for
  the grammar to settle; the first reads like `fn[T]` and `struct[T]`.

## The First Requirements

What std needs first, to grow from where real uses show friction or confusion:

| Requirement | For |
|---|---|
| `require_equality(T)` | `array_find`, a future `HashMap`'s keys |
| `require_ordering(T)` | Sorting, searching sorted views |
| `require_integer(T)`, `require_signed(T)`, `require_unsigned(T)`, `require_float(T)`, `require_numeric(T)` | Generic parsing and formatting, `sum`-like functions |
| `require_field(T, name, type)` | Structural containers (`count`, `data`) |
| `require_any(...)` | `Integer(T) \|\| Float(T)`-like alternatives inside a constraint |
| `require(condition, message, args...)` and `compiler.note(...)` | Value parameters (capacities), and anything else, with its own message |

The first constraints, in `base/compiler` (so base's own generics can use them): `Equatable`,
`Ordered`, `Integer`, `Float`, `Numeric`, `AtLeastOne` and `PowerOfTwo`.
