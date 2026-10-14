# Protocols: Wire Format, Evolution, Tags and Metadata

Status: **accepted** 2026-10-13 (`../decisions/0040`). Answers the *IPC and data* open questions on
the wire format, schema evolution, protocol versioning, protocol identifiers, idempotence and
displaying values without a compiled type.

A protocol is a pair of Hemera `union` types, requests and responses, in its own package
(`../decisions/0033`: `src/protocols/<class>/`, or `std/os/slop_os/<name>/` for the ones `std`
speaks). This note says how values of those types travel over channels (`../decisions/0035`), how
the types change over time, and what else a protocol package declares.

## 1. Wire Format: Hemera's Own Layout, Validated on Arrival

**A message is the protocol type's in-memory layout**, the way Cap'n Proto and FlatBuffers work:
- The fixed-size part is the value itself, laid out as Hemera lays it out.
- Variable-size data (strings, arrays, nested variable-size values) follows it in the same message,
  reached through **relative pointers** (`relptr32`), which mean the same thing wherever the
  message is copied.
- **Handles** are encoded as indices into the message's handle batch (`ipc.md` §2), never as raw
  handle values.
- **Byte order is native.** Every target is little-endian, and messages don't leave the machine.
  On-disk and network formats use explicit-endian types (`u32le`), as before.

**Protocol types may contain only plain data, relative pointers and handles.** No `ptr`, `rawptr`,
`any` or function values. A house-rule check (`0007`, `0029`) rejects anything else in a protocol
package.

**Receiving:**
1. `std` copies the message out of the ring into private memory (`ipc.md` §2, *Untrusted peer
   memory*; buffers in `../decisions/0041`).
2. A **validator generated at compile time** from the type, by `#run` code over its `TypeInfo`,
   checks every relative pointer's bounds (inside the message, properly aligned, not overlapping
   the fixed part), every union tag and enum value, and every `bool`.
3. Only then does `std` hand out a typed view of the message. There is no separate decoding step.

Validators, like all ring parsing, live in one `std` package and are fuzzed.

## 2. Schema Evolution and Versioning

Rules, as in Cap'n Proto and protobuf:
- **Struct fields are only added at the end.** Every message carries its size. A reader whose type
  is older ignores bytes past the end it knows. A reader whose type is newer sees the missing
  fields as their Hemera default values (`field : T = default`), or zero.
- **Union variants are only appended.** Tags are never reordered, reused or removed.
- **When a server receives a request variant it doesn't know**, `std` answers `.Unsupported`
  without involving the server's code. Every response union therefore has an `Unsupported`
  variant, which a house-rule check requires.
- **Removing or changing a field or variant** (its type, order or meaning) is a **new major
  version**, which is in effect a new protocol. A server can speak both during a transition.
- **`Features`:** a protocol may define a `Features` request whose response lists what the server
  supports, for optional behaviour that isn't simply a new variant.
- **Checked at release:** the release tooling compares each protocol type with its previous
  release and rejects changes that break these rules within a major version, as it does for the
  ABI package (`../decisions/0025`).

Device-class protocols (`block`, `net`, ...) follow the same rules: when `block` gains a request,
it's a new variant at the end, and old drivers answer it with `.Unsupported`.

## 3. Protocol Tags

Each channel carries an opaque **64-bit protocol tag**, set when it's created:
- **The kernel never interprets it.** It's stored with the channel and readable by both ends.
- **`std` checks it** when a handle arrives typed as `Channel[P]`, and refuses the handle on a
  mismatch, catching wiring mistakes before any message is sent.
- **The tag is a hash of the protocol package's path, the protocol's name, and its major version.**
  Compatible changes (section 2) don't change it.
- **It isn't security.** Whoever creates a channel chooses its tag. Rights and authority come from
  handles (`../decisions/0015`).

## 4. What a Protocol Package Declares

Besides its request and response unions, every protocol package declares, by convention, checked
by a house rule:

```
package block

// Protocol and Lending live next to the ABI package (see Open Questions)
import slop_os from "std/os"

PROTOCOL :: slop_os.Protocol.{
    name = "block",
    major_version = 1,
    // Who pays for the server's work (../decisions/0037, scheduling.md §4)
    lending = .PerConnection,
}

/*
 * Whether sending request again after a reconnect is safe (0017). std retries automatically
 * only when this is true.
 */
is_idempotent :: fn(request: ptr[BlockRequest]) -> bool {
    return match request^ {
        case Read(_) => true
        case Write(_) => true     // writes a given block, so repeating it is harmless
        case Flush => true
        case Info => true
    }
}
```

- **Idempotence is a function**, not a flag on each variant: Hemera's annotations can't be put on
  union variants or read through reflection, and a function can depend on the request's contents
  (a write at an offset is idempotent, an append isn't).
- The `match` must cover every variant, so adding a variant forces a decision about it.

## 5. Values Without a Compiled Type

Generic tools (a pager, a table viewer, a query tool) need to read values whose type they weren't
compiled with. Rather than a second, self-describing format:
- A **schema** is a serialized form of a type's `TypeInfo` (field names, types, offsets, variants),
  stored in the bundle store by the hash of its contents.
- **Values point to their schema.** Files and stream headers carry the schema hash. A channel's
  protocol tag leads to its protocol's schemas through the bundle store.
- A tool fetches the schema and reads the raw layout with the same rules the validator uses.
- `std` renders any value as text through reflection, like Hemera's `std/reflection`, so every
  value is debuggable as text without text being the format (`../problems-and-directions.md` §3).

## Open Questions

- The exact bundle-store record for schemas, and whether protocol packages publish theirs at build
  time.
- Where `Protocol` and `Lending` live: likely next to the ABI package, since `std` needs them too.
