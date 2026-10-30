# 0094: The Bundle Store, as Built

Status: accepted
Date: 2026-10-29
Related: `0092` (the plan for M9), `0093` (9a), `0045` (content-addressed libraries), `0044` (manifests), `0040`
(schemas), `../design/software.md` §2–§3, `../design/storage.md` §7, `../roadmap.md` M9

## Context
M9's second stage (9b, `0092`): content-addressed objects and bundles, collected from roots; pager-backed memory
objects in the kernel, and read-only memory objects shared between processes at different addresses; the process
manager loading from the store; the system booting with the boot set from the ESP and everything else from the store.
Chosen with the project's owner:
- **A bundle store service** holds the system volume's store directory, objects named by their hashes, and is the
  pager for the memory objects it gives out, reading pages through the file protocol; the volume server stays as it
  is.
- **Paged memory takes a page by copy**: a fault on a page that isn't there yet queues a packet on the pager's port
  and the thread waits; the pager answers with a call that copies a page of its own memory in. Pages stay once
  supplied, as the content can't change.
- **A boot root until generations**: the image builder writes the store and a root object listing the system's
  bundles, which a small file on the system volume names, until 9d's generation records replace it; developers' pins
  come with it, as a directory of names and hashes.
- **A bundle is a Hemera struct**, written as a value with `std/schema` under its schema's hash, as log records are:
  the program's hash, its manifest (its entry's type, as its schema), and its libraries' and resources' hashes. The
  build makes them.
Delivered in parts, each committed as it passes, with one report at the end: 9b1 paged memory, 9b2 the store service,
9b3 booting from the store.

## Decision
### 9b1: Paged memory
- **`memory_create_paged(budget, port, key, size)`** (ABI 8): memory charged for its whole size, as any is, whose pager
  made a wake binding with key on port; the memory keeps the binding's address and generation, as a channel end keeps
  its watchers'. It can be mapped only to read or execute (`allowed`), by any number of spaces at any addresses.
- **A fault** on a page that isn't there (`paging.hsc`, `resolve_paged_fault`) marks the page's slot `PAGE_WANTED`,
  raises the binding (one packet however many pages are wanted, as wake bits are ORed), and blocks the thread on the
  memory, its state saved as a port waiter's is; it runs again at the faulting instruction once woken, and maps the
  page or waits again. A fault with the binding gone fails, and the thread stops as for a touch of nothing mapped.
- **The pager** asks `memory_page_wanted`, each page reported once (`PAGE_REPORTED`), and supplies each with
  `memory_supply(memory, offset, source, source_offset)`, a copy of a page of its own memory, which wakes every thread
  waiting on the memory. Both need `RIGHT_MEMORY_WRITE`, which only the creator's handle has as handed out; a page
  supplied twice is kept the first time.
- **Locks**: a space's lock, then the memory's `page_lock`, then the port's. A destroyed memory wakes its waiters, who
  find their mapping gone; a destroyed thread leaves its memory's list.
- **Tests**: `test_pager`, on both architectures: a pager thread of the program's own supplies pages as the program
  touches them through one of two read-only mappings, each page's pattern read back, page 0 through the second
  mapping supplied once; mapping it to write, asking what's wanted without the right to write it, and a pager with no
  binding are refused.

## Alternatives considered
- **The store in the volume server**, paging straight from its block cache: fewer copies, but the volume server would
  grow a second protocol and the store's logic.
- **Pages moved in rather than copied**: no copy, but frames moving between objects and budgets in the kernel.
- **Pins as the only roots before generations**: one kind of root, but the system's own bundles would be a
  developer's pins.
- **A SlopOS binary format for bundles**: independent of Hemera's schemas, but a second way to describe typed data.

## Consequences
