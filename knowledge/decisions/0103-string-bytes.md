# 0103: A String's Bytes Through string_bytes

Status: accepted
Date: 2026-10-30
Related: `0102` (rawptr reviewed)

## Context
`0102` left 9 packages on `RAW_POINTERS` only because they read a string's bytes as
`view_of(cast[ptr[u8]](text.data), text.count)`, and a string's `data` is a `rawptr`. Hemera's base now has
`string_bytes(text: string) -> u8[]`, a view of the same bytes, whose lifetime the compiler tracks as the string's.

## Decision
- Every string's bytes are `string_bytes(text)`: 29 places, in the kernel, the file systems, the services, the
  protocols, the tests and the tools.
- Part of a string is a slice of it: `supervisor`'s module name without its extension is `module[0..<i]`, and
  `console_log`'s line, cut to what a message holds, is a slice of its bytes.
- **The list is 21 packages**: `bundle_store_service`, `console_log`, `disk_check`, `elf_loader_test`, `events`,
  `log_line`, `scheduler` and `supervisor` left it. With the list emptied, the check flags exactly these 21, so each
  is on it for a use it has. `events_service` stays for a reason of its own: it reads structs at offsets in a buffer of
  bytes, from the buffer's address.

## Alternatives considered
- **`cast[u8[]](text)`**: Hemera allows it only for a constant string.

## Consequences
- Reading a string's bytes no longer puts a package on the list.
