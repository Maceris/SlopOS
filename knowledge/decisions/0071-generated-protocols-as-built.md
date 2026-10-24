# 0071: Generated Protocols as Built

Status: accepted
Date: 2026-10-24
Related: `0040` (protocols), `0070` (the plan for M7), `0068` (typed entry points), `../design/protocols.md`,
`../../docs/specs/system_calls.md`, `../roadmap.md` M7

## Context
M7's first stage (7a). `0040` designed protocols as unions whose messages are their own layout, with
variable-size data after them, handles as indices into the message's batch, a validator generated at compile
time, and a tag on each channel. The first services sent fixed structs by hand, with handles in a batch in an
order each side knew, and `0068` put protocol tags in startup grants. `0070` chose to build `0040` now: a `std`
type for variable-size data, code generated per protocol with `#insert`, tags on channels, and the first services
moved over.

## Decision
As `0070` chose, built:
- **`slop_os.Relative[T]`**: an offset and a count, with a zero-length `elements : T[0]` that names `T` for the
  generator. The offset is from the message's start, rather than from the field itself as `0040`'s `relptr32`
  would be: building a message is then appending, and the meaning is the same wherever the message is copied.
- **`os.protocol_code(Request, Response)`**, inserted at a protocol package's top level, generates
  `validate_request` and `validate_response`, `send_request` and `send_response`, `receive_request` and
  `receive_response`, and `answer_unsupported`. It walks the unions' `TypeInfo` at compile time, collecting what
  each variant needs at each offset: bools (0 or 1), enums (one of their values), handles, and Relatives (after
  the fixed part, aligned, inside the message). Messages may hold only plain data, handles (`slop_os`'s handle
  types, `os.Channel[P]` and `os.Listener[P]`) and Relatives of plain data; anything else, or a Response without an
  empty `Unsupported` variant, stops the build where the protocol inserts its code.
- **Handles travel in place**: sending moves each handle field's handle into the batch and writes its index there
  (`NO_HANDLE_INDEX` for none); receiving puts the taken handles back, and checks each `Channel[P]` and
  `Listener[P]` field's channel has `P`'s tag. A message that fails is refused and its handles closed.
- **Messages** are built in an `os.Outgoing` (`begin[T]`, then `append` for variable-size data) and received into an
  `os.Incoming` (`message_of[T]`, `items`), each up to 4 KiB. Receiving gives an `os.Arrival`: `Received`, `Empty`
  (without waiting), `Unsupported`, `Invalid`, `WrongProtocol` or `Failed`. A message shorter than its type, an older
  sender's, reads its missing fields as zeros.
- **Channel tags**: `channel_create` takes a tag, kept on the channel, and `channel_tag` (call 50) reads an end's.
  `os.channel_for[P]` makes a channel with `P`'s tag, FNV-1a of `P`'s name. An entry parameter of `Channel[P]` or
  `Listener[P]` needs its grant's channel to have `P`'s tag: the compiler now passes the protocol's name to base's
  `os_entry_grant`, which asks the kernel. The startup grant's tag is gone (a grant is 40 bytes again), and so are
  the process manager's per-grant tags. ABI version 2.
- **Protocol packages** declare `PROTOCOL` (`slop_os.Protocol`: name, major version, `Lending`) and `is_idempotent`,
  which a house rule (`check_protocols`) requires of any package that generates protocol code.
- **The first services moved**: the process manager's protocol (`std/os/slop_os/process_manager`: `Load` and
  `Connect`; `Loaded`, `NotLoaded`, `Unsupported`), the entropy service's (`src/protocols/entropy`: `Fill` and
  `Connect`; `Filled(Relative[u8])`) and the supervisor's reports (`src/protocols/supervision`). A listener's
  connections arrive as its protocol's `Connect`, each package's `connect` making one. The services' shared code
  moved from `src/protocols` to `src/service_kit`.
- **`test_protocols`**: a protocol of its own, sent whole with a bool, an enum, a handle, a Relative and a typed
  channel; then messages made by hand broken in each way the validator checks; an unknown variant; a channel of
  another protocol; and a short message.
- **Found in Hemera on the way, fixed (`0047`)**: a union's variant without values, written in full as an `if`'s
  value (`if c { Outcome.Empty } else { Outcome.Missing }`), was stored as the first variant, whatever it was, and
  with no type to go to, the `if` had none and the compiler crashed. Both are fixed, with a test in
  `expression_forms`. And a protocol package in `std` writes `#if base.OS == .SlopOS`, since an `#if` on `OS` waits
  for the `#insert` inside it, which could declare an `OS`.

## Alternatives considered
- **Offsets relative to the field**, as `relptr32` is: what `0040` sketched, but every append would have to know
  where its field ends up.
- **Handle fields as explicit indices** the sender fills in: no generated encoding, but every sender and receiver
  would track the batch's order by hand, which is what generation was for.
- **Keeping messages unbounded**: buffers sized by each protocol's ring; one size for now is simpler, and bulk data
  goes in shared memory anyway.

## Consequences
- A protocol is a package with two unions, a marker type, `PROTOCOL`, `is_idempotent` and one `#insert`; the
  device classes in 7c to 7f are written that way.
- A message is at most 4 KiB here (`MESSAGE_BYTES`); a protocol whose messages need more uses shared memory.
- Messages hold no nested unions yet, and a Relative's elements are plain data.
- Protocol tags are by name; a new major version is a new marker type.
