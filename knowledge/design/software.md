# Software: Bundles, Configuration, Generations and Installations

Status: **proposed** 2026-10-24, for roadmap M9 (and B); its open questions decided 2026-10-27 (`../decisions/0092`). Builds on `../decisions/0044` (typed entry points and the
system configuration), `0045` (content-addressed libraries), `0040` (schemas), `0012` (root task), `0017`
(supervisor) and `../problems-and-directions.md` §5–§7 and §13. The choices still to make are at the end and in
`../open-questions.md`, *Software*.

## 1. What Goes Wrong Elsewhere

| Problem | Where | SlopOS answer |
|---|---|---|
| Installing runs the package's own scripts with full authority (maintainer scripts, `postinstall`, installers) | dpkg, rpm, npm, Windows | Installing is adding a reference to inert data; no code runs (§3) |
| Files scattered through shared locations; uninstalling leaves residue; two packages clobber each other | `/usr`, `Program Files`, `AppData` | Code lives only in the bundle store, by hash; an app's data belongs to its installation (§6) |
| One shared version of each library for everyone (DLL hell), or a whole OS per app (containers) | Linux, Windows; Docker, Flatpak | Programs pin the hashes they were built with (`0045`) |
| An interrupted upgrade leaves a half-updated system; there's no clean way back | apt, Windows Update | A generation is switched to whole, at boot; the previous one stays bootable (§5) |
| A failed update that doesn't boot needs someone at the console | Most desktops | Boot counting and automatic fallback (§5, with B) |
| Configuration files edited by packages and by people, merged on upgrade (`.dpkg-old`, `.rpmnew`) | `/etc` | Defaults come with the bundle, overrides are stored apart, both typed, so an update never merges text (§4) |
| An untyped global configuration database | Windows registry, GConf | Typed values owned by whoever they configure, validated by schema (§4) |
| Symbol linking by name only, so a changed signature crashes at run time | ELF, PE | Imports name the function's type hash; a mismatch is a load error (§7) |

## 2. The Bundle Store

- **Objects** are blobs keyed by BLAKE3-256 of their contents: built programs, libraries, schemas (`0040`), and the
  data files a program ships with. The store checks the hash of everything put into it.
- **A bundle** is a record of its own: the program's hash, its manifest (the entry signature, `0044`, with its
  documentation comments for the shell's help), the libraries and schemas it references, and its resources. A
  bundle's hash covers all of it, so it names exactly one build.
- **Roots** keep objects alive: system generations (§5), installations (§6), and pins a developer makes. Collection
  is a mark from the roots and a sweep, run in the background.
- **Reading** returns a read-only memory object: through a pager-backed memory object (the kernel feature planned for
  M9, `storage.md` §7), so a program's pages are read when touched, and objects shared by hash are mapped from one
  memory object into every process using them.
- **Putting** is a stream of the object's bytes and its expected hash; it's committed only if they match.
- The store lives on the system volume. Its protocol is held by the process manager (to read), by the update and
  installation services (to put and to add roots), and by nothing else.

Builds must be **reproducible**: the same sources and options give the same bytes, or content addressing degrades to
"a new hash every build". That's a requirement on Hemera's compiler (`../hemera-feedback.md`).

## 3. Installing and Running

- The process manager loads a program by bundle hash, resolving each library hash through the substitution policy
  (`0045`) first.
- **Installing** a bundle is putting its objects and adding a root; nothing in it runs. **Running** a bundle
  doesn't need installing it: the process manager can load any bundle in the store for a requester that may launch
  it.
- Where bundles come from (built on a developer machine and copied in, later downloaded) is a separate question; the
  store only cares that the hashes match. Code signing stays out of scope for now (`security.md` §12).

## 4. The Config Store

- **A configuration value** is a Hemera value of a type its owner declares, stored in the protocol layout with its
  schema hash, and validated with the protocol validators (`0071`) when read and when written.
- **Layers:** the default comes from the bundle (a compile-time value in the program), the system's override and the
  user's override are stored apart, and the value a program sees is the default with the overrides applied field by
  field. An update that changes a default changes it, without a merge, unless an override set that field.
- **Versions:** every write is a new version with its author's connection label and time; a value can be rolled back
  to any kept version. Writes are transactions over several values.
- **Watching:** a holder of a value's connection can wait for its next version, to apply it live; a service that
  can't is restarted by the supervisor instead.
- **In a program's entry**, a parameter `config: Config[T]` is a connection to its value of type `T` (`0044`'s
  manifest grows a kind).
- **The system configuration** stops being only a compile-time value. It's still written in Hemera and checked by
  the build (`0044`), and the build serializes it, with its schema, into the generation (§5). The root task validates
  it at boot with the same validator and the same wiring check, ordinary Hemera code that the build runs through
  `#run` and the root task calls. A change made at run time goes through the config store, is checked by that code
  too, and becomes the next generation.

## 5. Generations and Updates

- **A system generation** is a record: the kernel's hash, the boot set's hashes, the system configuration's version
  and the system bundles' roots. Generations are numbered and kept until collected.
- **The boot set** is what has to run before the system volume can be read: the root task, process manager,
  supervisor, platform service, the disk's driver, the storage manager and its servers, and the bundle and config
  stores. It's on the ESP (`storage.md` §8), one directory per generation, beside the bootloader's entries for each.
  Everything else is loaded from the bundle store.
- **An update** puts the new objects in the store, writes the new generation and its boot set to the ESP, and makes
  it the default. Nothing of the running generation is touched, so an interrupted update leaves the old one as it
  was.
- **Boot assessment:** a new generation is tentative. The supervisor reports it healthy once every service its
  configuration lists has started and answered on its listener; the update service then makes it permanent. With the
  Hemera bootloader (B), a tentative generation that doesn't report healthy within a few attempts is skipped, as
  systemd-boot's automatic boot assessment does with counters in entry names. With Limine, choosing the previous
  generation from the menu is the fallback.
- **Updating a service without rebooting** is restarting it from a new bundle under the same generation's next
  version, when only services change: `problems-and-directions.md` §13. Live state handoff isn't planned.

## 6. Installations and App Data

A content hash names a build, but an app's data has to outlive its updates, so it can't be keyed by the hash.

- **An installation** is an entry in a session's app list (in the user's volume) or in the system configuration: a
  name chosen when installing, the bundle hash it runs, the grants and configuration given to it, and the previous
  hashes kept for rollback.
- **Its data** is a directory belonging to the installation, given to the program as a `data: AppData` parameter
  (a `Dir` the program can't see out of), and its configuration as `Config[T]` (§4). Nothing else is writable by it
  unless granted.
- **Updating** an app replaces the hash in its entry; **uninstalling** deletes the entry, its data directory and its
  configuration, after asking, and the bundle store collects the code.
- **Sharing between apps** (a photo library two editors use) is a directory granted to both, explicitly
  (`problems-and-directions.md` §6). Plugins are code linked into another app, with its authority (`0013`).

## 7. Shared Libraries

- **A library** is built separately, for a pinned calling-convention version (`system-abi.md` §7): position-
  independent code, exported Hemera functions, and an interface record listing each export's name and the hash of
  its type.
- **Imports name types:** a program's import of a function names the library's hash, the export's name and its type
  hash. The loader checks all three, then binds through a table in the program's data; a mismatch fails the load with
  the import named, never a call that crashes later.
- **Text is shared:** a library's code is one read-only memory object mapped into every process using it, at
  different addresses (ASLR, `0004`), with no relocations in its text.
- **Substitution** (`0045`): the config store's policy maps hash X to hash Y once Y's interface passes the
  compatibility check against X; the loader applies it, and it's recorded and reversible.
- The compiler's side (building libraries, interface records, typed imports) is the largest Hemera piece of M9 and is
  proposed in `../hemera-proposals/` when it starts.

## 8. Decided (`../decisions/0092`)

- One bundle store, on the system volume, for every user's apps.
- The system configuration as a generation's serialized value (§4), validated at boot by the code the build runs.
- B (the bootloader) after M9: until then, Limine's menu is the way back to the previous generation.
