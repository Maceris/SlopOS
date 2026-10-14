# 0046: Storage Model: Typed Bytes, Handle-Relative Trees, Transactions in the Filesystem

Status: accepted
Date: 2026-10-13
Related: `0015` (`Dir` and `ReadOnlyDir`), `0016` (per-user volumes), `0018` (`FileSet`), `0040`
(protocol layout and schemas), `0042`, `0044`

## Context
`../problems-and-directions.md` §8 leaned toward per-process namespaces and handle-relative
operations, and left open whether files are bytes or typed values, how much of a path-based tree
interop needs, and where transactions and snapshots belong. Roadmap M8 plans FAT32 first, then a
native copy-on-write filesystem.

## Decision
- **Files are bytes, with an optional type.** Every file is a byte sequence at the storage layer.
  A file may also carry a schema hash (`0040`): its contents are then a Hemera value of that type,
  in the same layout as protocol messages, position-independent through relative pointers. `std`'s
  typed open validates the bytes like an incoming message before handing out a typed view. Generic
  tools display typed files through their schema. Queryable typed attributes can come later.
- **A tree beneath each directory handle, and no global root.**
  - A directory is a capability speaking `Dir` (or `ReadOnlyDir`, `0015`).
  - Relative paths with several components resolve beneath the handle, like `openat2` with
    `RESOLVE_BENEATH` or WASI: `..` can't go above it, there are no absolute paths, and nothing
    leads outside it.
  - Names are UTF-8 without `/` or NUL. The native filesystem compares them byte for byte and has
    no symlinks.
  - Interop filesystems (FAT, git trees, network shares) are `Dir` servers. Each handles its own
    rules, like FAT's case-insensitivity, and follows symlinks only within the subtree.
  - A shell, or a POSIX personality later, composes a per-process `/` from the handles it holds,
    as Plan 9 does.
- **Transactions and snapshots are in the filesystem.** The native copy-on-write filesystem
  provides atomic file replacement, transactions over several files under one `Dir`, and snapshots
  of a subtree or volume. Foreign filesystems report what they support through `Features`
  (`0040`), answer the rest with `.Unsupported`, and FAT's atomic replacement is best effort.

## Alternatives considered
- **Only typed values:** no interop with existing formats or filesystems.
- **Only bytes, with types elsewhere:** the type and the data could disagree, and generic tools
  couldn't find the schema.
- **A global path tree with permission checks:** the ambient authority the capability model exists
  to remove.
- **Transactions in a layer above the filesystem:** can't be made atomic and crash-consistent
  without the filesystem's help, and would duplicate copy-on-write.

## Consequences
- The `Dir` protocol gains path resolution beneath a handle, `FileSet` (`0018`), schema hashes,
  transactions and snapshots, and `Features`.
- Typed files share the protocol validators (`0040`).
- Programs never see a global namespace, which matches per-process namespaces in
  `../problems-and-directions.md` §8.
