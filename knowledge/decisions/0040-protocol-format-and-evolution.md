# 0040: Protocol Wire Format, Evolution, Tags and Metadata

Status: accepted
Date: 2026-10-13
Related: `0015` (server rights), `0017` (reconnect and retry), `0025` (ABI package), `0033`,
`0035` (IPC), `0037` (lending)

## Context
Channels carry typed messages (`0035`), but how values are laid out, how protocol types may change,
how a channel says which protocol it speaks, and how a protocol declares idempotence and its lending
level were all open. Details are in `../design/protocols.md`.

## Decision
- **Wire format:** a message is the protocol type's own Hemera layout, with variable-size data
  reached through relative pointers, handles as indices into the handle batch, and native byte
  order. A validator generated at compile time checks every message after it's copied out of the
  ring and before it's used. Protocol types hold only plain data, relative pointers and handles,
  enforced by a house-rule check.
- **Evolution:** struct fields and union variants are only appended. Messages carry their size, so
  older readers ignore new fields and newer readers default missing ones. An unknown request
  variant gets `.Unsupported` from `std`. Anything else is a new major version. Release tooling
  checks the rules, as for the ABI package.
- **Protocol tags:** an opaque 64-bit tag per channel, a hash of the protocol's package path, name
  and major version, never interpreted by the kernel and checked by `std` for `Channel[P]`. It
  catches wiring mistakes, and isn't security.
- **Metadata:** each protocol package declares a `PROTOCOL` constant (name, major version, lending
  level) and an `is_idempotent(request) -> bool` function, checked by a house rule.
- **Values without a compiled type:** schemas are serialized `TypeInfo`, kept in the bundle store by
  hash and referenced from files and stream headers. There is no second, self-describing format.

## Alternatives considered
- **A separate encoding** (protobuf, a custom tagged format): independent of Hemera's layout rules,
  but every message is encoded and decoded, and the schema lives in a second language or format.
- **Exact type hashes as tags:** any compatible change would break existing channels.
- **A flag per variant for idempotence:** Hemera's annotations can't go on variants and aren't
  visible to reflection, and a flag can't depend on the request's contents.
- **A self-describing format for generic tools:** a second format to keep in step with the first.

## Consequences
- The layout of a protocol type is a compatibility surface: Hemera layout rules for a type must not
  change under a protocol without a new major version.
- Three house-rule checks join the checks package: allowed field types in protocol packages, an
  `Unsupported` response variant, and `PROTOCOL` and `is_idempotent` present.
- The bundle store gains schema records.
