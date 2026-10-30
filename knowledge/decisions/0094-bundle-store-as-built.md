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

### 9b2: The store service
- **Records** (`src/bundle`): `Hash`, `Bundle` (program, manifest, libraries, resources) and `Root` (entries, each a
  name and a bundle) are written as their type's schema hash, then the value as `schema.write_value` writes it; the
  store reads back only what it needs, the hashes a bundle refers to and a root's entries, checking the schema hash
  first.
- **The store** (`src/services/bundle_store_service`, the `bundle_store` protocol), in the system volume's `store`
  directory, which the supervisor makes and gives it once the storage manager has given the volume: `objects/<hex>`,
  each written as `objects/<hex>.part` and renamed once whole; `root`, the boot root's hash in hex; `pins/<name>`.
  - `Get(hash)` opens the object's file read-only, has the file server read into a page of the store's own memory
    (`UseBuffer`), and makes paged memory of the object's size in pages, bound to the store's port; each wanted page is
    read into that page, zeroed past the object's end, and supplied. The same memory is given to everyone who asks,
    read and execute only; up to 64 objects are open at once, and stay open.
  - `Put(hash, size, data)` maps the memory given, hashes its first size bytes, and keeps them only if the hash is the
    one given.
  - `Pin` and `Unpin` by name; `SetRoot`, for an object it has, and `Root`.
  - `Collect` marks the boot root, every pin, a root's bundles and a bundle's program, manifest, libraries and
    resources, and removes every other object but those open, and every `.part` left over.
- **The supervisor** starts it with the system volume, restarts it like anything else, and keeps its listener's other
  end; its budget grew to 128 MiB, as the store's 16 joined the storage manager's 64.
- **Tests**: "keeps objects in the bundle store and pages them in", on both architectures, from the disk: with
  `test_store`, the supervisor puts hello's program in the store and reads it back whole through paged memory, is
  refused it under a wrong hash, and sees an object it never read kept while it's pinned and collected once unpinned.

### 9b3: Booting from the store
- **The store builder** (`src/tools/store_builder`, a hosted tool `tools/boot.py` runs): every program outside the
  boot set becomes an object, with a bundle naming it, and a boot root names each bundle by the program's name; it
  writes them as the store keeps them, `store/objects/<hex>` and `store/root`, into the folder the image builder copies
  into the system volume. A bundle's manifest is all zeros for now: nothing gives the schema of a program's entry type
  from its build yet (`0044`'s extraction step), which the store doesn't need, but the shell will.
- **The supervisor loads from the store** (`stored_program`): a service outside the boot set is the program of the
  bundle its boot root names after it, given as the store's paged memory, which the supervisor passes to the process
  manager as it passed the module it read before. Without a store or a root, it reads `modules/` as before, which the
  disk check still compares with the EFI system partition's copy.
- **Code shared between processes** (`process_builder`): given the memory object a program's file is in, a read-only
  segment whose place in the file and in the image agree within a page, and which takes no more than the file has of
  it, is mapped straight from that object, read or executed, rather than copied into the process's image; the loader
  puts relocations only in writable segments. `os.launch` passes the executable with `RIGHT_MEMORY_EXECUTE` where the
  caller's handle has it. So a program from the store has its code and read-only data paged in by the store once, and
  every process running it maps the same pages; a boot module, which Limine's handle doesn't let execute, shares only
  its read-only data, and its code is copied.
- **The process manager doesn't ask the store itself yet**: it's started before the store and the system volume, and
  takes what it loads as a memory object, which from the store is paged; loading by bundle hash, with the
  substitution policy (`0045`), comes with shared libraries (9e).
- **Tests**: the boot-disk tests expect console, hello and the disk check "from the bundle store"; that their code is
  mapped from the store's memory was checked by hand, not by a test.
- **Reproducible output** (`../hemera-proposals/reproducible-builds.md`), where hashes first matter: SlopOS's 34
  programs, built twice into different folders on the same host, came out the same bytes, so the same objects. Across
  hosts it isn't checked yet.

## Alternatives considered
- **The store in the volume server**, paging straight from its block cache: fewer copies, but the volume server would
  grow a second protocol and the store's logic.
- **Pages moved in rather than copied**: no copy, but frames moving between objects and budgets in the kernel.
- **Pins as the only roots before generations**: one kind of root, but the system's own bundles would be a
  developer's pins.
- **A SlopOS binary format for bundles**: independent of Hemera's schemas, but a second way to describe typed data.

## Consequences
- Programs outside the boot set come from the bundle store, their code paged in once and shared; the boot set still
  comes from the EFI system partition through Limine, as `0092` planned.
- The store's paged memory belongs to the store: if it ends, every object it gave out is destroyed with it, and the
  processes whose code was mapped from one fault and end. Restarting the store doesn't bring them back; the supervisor
  restarts them as their own failures.
- An open object stays open, and its memory with it, until the store ends; up to 64 at once.
- Paged memory waiting on a pager whose binding is gone waits until it's killed.
- Manifests, and the process manager loading by bundle hash, are still to come (above).
