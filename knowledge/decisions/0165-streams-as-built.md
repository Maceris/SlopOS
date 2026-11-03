# 0165: 11a2, Streams, as Built

Status: accepted
Date: 2026-11-02
Related: `0162` (M11's plan), `0164` (a stage's output a `Sink[T]`), `0163` (entry values), `../design/shell.md` §4

## Context
`0162` and `0164`: `Stream[T]` in Hemera's `std`, batches of records in shared memory with backpressure, and its
writing end a `Sink[T]`.

## Decision
- **The ends** (Hemera's `std/os`): `Stream[T]` and `Sink[T]`, each a channel end, kinds of handle the runtime and the
  compiler know, so an entry takes them as grants; their channel is tagged with the stream protocol whatever `T` is.
- **The protocol** (`std/os/slop_os`'s `stream`): the writer makes a ring of shared memory (64 KiB unless asked for
  more) and offers it with `Open`, with `T`'s schema hash; the reader maps it to read and answers `Consumed(0)`, or
  `WrongType`. A record in the ring is its byte count, its kind and its value, written as base's
  `schema_write_value` writes one (for a `Stream[u8]`, the bytes as they are), padded to 8 bytes; one that wouldn't fit
  before the ring's end is preceded by a wrap. The writer says how far it has written (`Wrote`) once a quarter of the
  ring is waiting, or when it needs room; the reader answers each `Wrote` with how far it has read once it's read that
  far, so the writer waits only while the ring is full. `Ended` carries the writer's status, and is answered once
  everything's read.
- **The API**: `pair[T]` makes a stream's two ends; `writer_on`, `write`, `write_bytes`, `flush` and `finish` write;
  `reader_on`, `next`, `next_bytes` and `close_reader` read. `next` copies a record to the heap with the context's
  allocator, so a reader of many pushes an arena and resets it.
- **Tests**: `test_streams` launches a copy of itself with a `Sink[Item]` and a `Sink[u8]`; the copy writes 3000
  records, more than the ring holds at once, then 100 chunks of bytes, and the test reads and checks each.

## Found along the way
- `x?` on a call returning an error optional (`StreamError?`) returns when the call gives no error, so it can't be used
  to pass an error on; the stream code matches the error instead.

## Consequences
- The root task has 59 grants now, one per boot module; M11's tools must not all be boot modules (`0162`'s 11e).
