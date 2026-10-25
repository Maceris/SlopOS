# 0087: FAT32 and the File Protocols as Built

Status: accepted
Date: 2026-10-25
Related: `0085` (the plan for M8), `0086` (partitions), `0015` and `0046` (directories and what a file system
offers), `0018` (file sets and informational names), `0071` (generated protocols), `../design/storage.md`,
`../../docs/specs/programs.md`, `../roadmap.md` M8

## Context
M8's second stage (8b, `0085`): the FAT server, the protocols `Dir`, `ReadOnlyDir`, `File`, `ReadOnlyFile` and
`FileSet`, informational names, bulk data through a buffer each connection registers, and `std`'s files for SlopOS,
with the EFI system partition readable from a boot test. Left to this stage: how far FAT goes, where the protocols
live, how `std`'s path functions work on a system with no paths above what a program is given, and what tests it.
Chosen with the project's owner: FAT read and write; and in `std`, both a directory-relative API for every OS and
SlopOS's path functions resolving beneath a `working_directory` grant.

## Decision
Built:
- **`src/fat`**, a portable package: FAT32 over a device of read and write functions, mounting (the boot sector,
  FSInfo ignored), directories with long names, reading and writing across clusters, growing and cutting files,
  making files and directories (a long name, and a Windows-style `~N` 8.3 alias), removing, renaming (replacing a
  file; a moved directory's `..` fixed), and formatting. Names compare ignoring ASCII case; times are 1980-01-01;
  `.` and `..` are refused in paths; FAT12 and FAT16 are refused. Its test formats a 34 MiB volume in memory and
  checks long and short names, writes across clusters, resizing, renaming, removing and remounting
  (`tools/unit_tests.py`).
- **The file protocols**, in Hemera's `std/os/slop_os` (`files`, `dir`, `read_only_dir`, `file`, `read_only_file`,
  `file_set`), since `std`'s files speak them: generated (`0071`), with paths as `Relative[u8]` resolved beneath the
  connection they're sent on. Each open gives a connection of its own; `Narrow` gives a directory or file only to
  read; `Select` gives a `file_set`, a directory and a pattern applied when it's used. A file connection's data moves
  through a memory object the client gives it once (`UseBuffer`), which the server maps, up to 16 MiB; `Read` and
  `Write` name offsets in it. `Info`'s name is informational, the path it was opened as (`0018`). `Features` says
  what a file system offers beyond the least (`0046`), which for FAT is only ignoring case.
- **The FAT server** (`src/services/fat_server`), given a connection narrowed to its partition and a listener, and
  nothing else, serving up to 64 connections. Each request on a file re-reads its directory entry, so a rename or
  removal through another connection is seen at once. `Sync` is the block connection's `Flush`.
- **The storage manager** starts a FAT server for an EFI system or basic data partition the first time its files are
  asked for (`OpenFiles`), with a block connection narrowed to it, and gives each asker a `dir` connection of its own
  to the root.
- **`std`'s files**: `os.Directory`, `open_directory`, `working_directory`, `close_directory`, and `_in` forms of
  the path functions that resolve beneath a Directory, refusing a path that isn't beneath it by its text
  (`is_beneath`). On Linux they're `openat` and the other `*at` calls, the plain ones `AT_FDCWD`; on Windows, NT opens
  relative to the directory's handle (`NtCreateFile`, and a rename by `FILE_RENAME_INFORMATION` with a root). On
  SlopOS (`std/os/slop_os_files.hsc`), a Directory is a `dir` connection and a File a `file` or `read_only_file` one
  with a 64 KiB buffer of its own, and the plain path functions resolve beneath the `working_directory` grant.
- **The disk check** is given the first EFI system partition's root as its working directory, which the supervisor
  asks the storage manager for. Through `std` it reads the host's two files, one with a long name, writes one of its
  own, makes a directory and moves its file into it, lists, reads its file back through the opened directory, and is
  refused `../`; through the protocols it narrows `EFI/SlopOS`, selects `*.TXT` (two, as FAT ignores case), and is
  refused a file made in the set the read-only directory gave.
- **Tests**: `boot.py`'s test disk is 38 MiB, with a third partition, a 34 MiB EFI system partition holding a FAT32
  volume `boot.py` writes itself from Microsoft's specification, apart from `src/fat`, so each checks the other: an
  8.3 name with its case flags, and a long name. The disk boot test checks the FAT server's line, both of the disk
  check's new ones, and that the image holds the guest's file's text afterwards.
- **Found on the way, fixed**:
  - Hemera: `OS` and `TARGET_ARCH` used as values, outside `#if`, couldn't be generated; they're their target's
    enum members now.
  - The process builder took at most 16 grants, and the supervisor now has 17; it's 24, with the process manager's
    protocol at version 2.
  - The supervisor waited for the storage manager's answer while the storage manager waited for the supervisor to
    serve its disk's connector: the supervisor now waits on its own port, serving connectors meanwhile.
  - The FAT server reuses free slots, and a connection added in a slot its pass had gone by was never read, so its
    channel never woke the server: a pass is done again whenever one added a connection (`loop #at_least_once`).
    A `loop`'s `while` is checked first, which the first attempt missed.

## Alternatives considered
- **FAT read-only**: enough to read what firmware boots, but the ESP is where an installer and updates write, and writing
  tests the protocols' writes before the native filesystem does.
- **The protocols in SlopOS's `src/protocols`**: `std` can't import SlopOS's packages, and its files must speak them.
- **Path functions failing on SlopOS**: ported software opens files by path; a working directory gives it paths
  without anything above what it was given.
- **The disk check asking the storage manager itself**: then `std`'s path functions, which read the grant, wouldn't
  be tested as a program sees them.
- **Copying through the channel instead of a registered buffer**: a channel's 2 KiB ring would cut every transfer
  into small messages.

## Consequences
- 8d's volume servers serve the same protocols, with more of `Features`; programs using `std`'s files don't change.
- A FAT server holds only its partition, so a malicious volume reaches only that process.
- FAT's directory entries aren't kept open, so two connections writing the same file see each other's sizes only
  per request; FAT has no stronger guarantee to give.
- Not yet: the storage manager restarting a FAT server that crashes, timestamps, and a FAT volume's free count kept
  in FSInfo.
