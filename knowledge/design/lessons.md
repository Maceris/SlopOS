# Lessons From Other Systems, by Milestone

Status: **proposed** 2026-10-29. A pass over the roadmap from B onward, looking for what other operating systems,
modern and historical, get wrong (gripes, design flaws, performance and UX problems, bug classes, security holes)
that the plans so far don't answer yet. Each milestone's design note already has a *What Goes Wrong Elsewhere*
table; this note doesn't repeat those. It adds what they miss, says where each answer lands (a milestone and stage,
or a new track), and lists the decisions it would revisit. Nothing here is decided: items move into a milestone's
plan when it's planned, as `0058` and `0070` did, and the choices are in `../open-questions.md`, *Lessons*.

Each table has the same columns as the design notes': the problem, where it happens, and SlopOS's answer, with the
stage it lands in.

---

## 1. B — Boot

Boot is where an OS is least observable and most fragile: nothing is logged yet, the user can't do anything, and a
mistake can leave a machine that doesn't start at all.

| Problem | Where | SlopOS answer |
|---|---|---|
| Boot waits on a device or service that isn't there: "A start job is running for dev-disk-by-uuid…" for 90 s, then an emergency shell over a missing USB disk in `fstab` | systemd, `fstab` without `nofail` | Every dependency in `system_config` is required or optional; an optional one never blocks anything; a required one has a deadline, and missing it boots **degraded** with a report naming it, not a hang (§1.1) |
| Services start one after another, or poll for each other; boot time is opaque | SysV init; systemd before socket activation | Start in parallel from the wiring graph, with listeners made before services run; a boot timeline from the trace ring (§1.2) |
| A failed boot loops on "automatic repair", or needs install media | Windows' Startup Repair loop, Linux without a rescue image | A pinned recovery generation, reached by a key or after repeated failures (§1.3) |
| The boot partition fills with old kernels and the next update fails | Ubuntu's `/boot`; Windows' KB5034441, which failed with 0x80070643 because the recovery partition was too small | The update service budgets the ESP: a generation is written only if it fits beside the previous and the recovery generation; boot-set files are named by hash, so generations share them (§1.4) |
| Bootloaders parse configuration languages, images and fonts, and their bugs break Secure Boot | BootHole (CVE-2020-10713, GRUB's config parser), LogoFAIL (2023, firmware image parsers) | The Hemera bootloader reads one record type, the generation, in the protocol layout, checked by a generated validator and fuzzed; no scripting, no images (§1.5) |
| Anyone at the boot menu can edit the command line (`init=/bin/sh`) | GRUB, Limine, systemd-boot | The command line comes from the generation; editing it needs the generation to be marked for development; test options aren't compiled into release kernels (§1.5) |
| A kernel panic on a desktop with no serial console is lost: the screen freezes, the user power-cycles, nothing is recorded | Linux without `pstore`; early Windows | The panic record survives the reset and is shown and logged on the next boot (§1.6) |
| Early boot has little entropy; a cloned VM or restored snapshot repeats its random numbers | Linux's `getrandom` stalls before 5.4; VM clones (fixed by VM Generation ID) | A seed file on the ESP mixed into the boot seed and replaced before it's used; the VM Generation ID watched where the platform has one (§1.7) |

### 1.1 Required, optional and degraded

- `system_config`'s services gain a **dependency kind** for each `Channel[P]` they depend on: required (the service
  can't run without it), optional (it runs and learns when the dependency arrives) or late (it isn't needed to report
  healthy). The wiring check already sees every edge, so the kind is checked at compile time like the rest.
- A required dependency has a **deadline**, defaulting from the configuration. Missing it starts what doesn't depend
  on it and writes a degraded-boot record: what's missing, why (the driver crashed three times, the volume didn't
  unlock), and what was skipped because of it.
- **Boot assessment** (`software.md` §5) counts a degraded boot as unhealthy only if a service the generation marks
  essential is missing, so a missing USB disk doesn't roll back an update.
- Lands in **9d** (generations already need "healthy"), with the dependency kinds in `system_config`.

### 1.2 Parallel start and a boot timeline

- The supervisor makes each service's listener before starting it (as launchd and systemd's socket activation do),
  and hands clients their connectors at once; a client's first message waits in the ring until its server runs. Every
  service then starts as soon as its own startup grants exist, in parallel, with no polling and no ordering written by
  hand.
- The kernel's trace ring (M12, 12d) records each process's creation, first run and first `PortWait`; the events
  service has each service's "listening" record. **`boot-timeline`** joins them into a chart of the boot, like
  `systemd-analyze plot`. The trace ring is needed earlier than 12d for this; it moves to 9a's follow-ups or B.
- A **boot-time budget** test: boot tests record the time from kernel entry to "healthy" and fail on a regression
  beyond a margin (§9.1).

### 1.3 The recovery generation

- One generation is the **recovery generation**: pinned, never collected, updated only deliberately (as macOS
  Recovery and WinRE are). It boots the boot set, the console, the account service and a shell, with the administrator's
  login, and no session services.
- From it the administrator can roll back to any kept generation, check every volume (`slopfs verify`), unlock a
  volume and copy data off, and read the degraded-boot and panic records.
- It's reached by holding a key at the bootloader, and **automatically** after the boot counter runs out on every
  normal generation, so a machine never loops.
- Lands in **B**, with **9d** writing it.

### 1.4 The ESP is small

- The update service asks the FAT server for the ESP's free space and refuses to write a generation that wouldn't
  leave room for the current one and the recovery generation; it collects the oldest unpinned generations first.
- Boot-set files are named by their BLAKE3 hash in a shared directory, and a generation's entry lists hashes, so a
  generation that changes one service writes one file.
- The image builder sizes the ESP for a configured number of generations, and a boot test fills the ESP and checks the
  update is refused cleanly, not half-written.

### 1.5 A bootloader with nothing to parse

- The bootloader reads the ESP's FAT (the same `src/fat`, fuzzed already), the generation records in Hemera's
  protocol layout, checked by the validators `os.protocol_code` generates, and ELF images through the shared loader.
  There's no configuration language, no theme, no image or font decoding, no network.
- **Verifying the boot set**: each file's hash is checked against its generation's record before it's used. That
  catches FAT's silent corruption (FAT has no checksums), and the generation falls back. It isn't a defence against an
  attacker with the disk unless the record is sealed (§10.1).
- **The command line** is a field of the generation. The bootloader's editor is offered only for a generation built
  with `development = true`; release kernels are built without the `test_*` options (a compile-time setting of the
  build package), so they can't be turned on at boot.

### 1.6 Panic records that survive

- On a panic, the kernel writes a fixed-size **panic record** (the reason, the `Fault`, registers, the image-relative
  stack trace, the last kernel log lines, the generation) into a reserved region that the bootloader marks and the
  next boot doesn't clear (`pstore`/`ramoops`); on UEFI, the bootloader copies it to the ESP before handing over, since
  RAM can be lost across a full reset.
- The next boot hands it to the events service, the console shows "the last boot ended in a kernel panic" once, and
  the recovery generation can read it.
- The panic screen on the framebuffer shows the reason and a short code, not just a frozen frame.
- Lands in **B** (the region and the bootloader's copy) and **10a** (showing it).

### 1.7 Entropy across boots

- The bootloader reads a 32-byte seed from the ESP, mixes it with the firmware's `EFI_RNG_PROTOCOL` and `RDSEED` or
  `RNDR`, and **writes a new seed before handing over** (systemd-boot's rule), so a power cut can't make two boots
  use the same one. A seed is never the only source.
- The entropy service watches the VM Generation ID (ACPI's `VMGENID`, and the devicetree's `vmgenid`) where the
  platform has one, and reseeds every client's stream when it changes, as Linux's `vmgenid` does since 5.18.

---

## 2. M9's rest — Configuration, Updates, Libraries (9c–9e)

| Problem | Where | SlopOS answer |
|---|---|---|
| A content update to a trusted component crashes every machine at once, with no way back but hand repair | CrowdStrike's channel file 291 (July 2024) | Data a TCB service loads is part of a generation too, so a bad one is rolled back by boot assessment; updates roll out in stages (§2.1) |
| A mirror serves an old, vulnerable version (rollback attack) or stops updating without anyone noticing (freeze attack); one signing key is a single point of failure | apt and many updaters before TUF | Remote updates follow The Update Framework's metadata: thresholds of keys, version numbers, expiry (§2.2) |
| Updates force a reboot at the vendor's chosen time, losing work | Windows Update | Nothing reboots without the user; services update by restarting; a new kernel waits for the next boot (§2.3) |
| "What did I change from the defaults?" has no answer; resetting one setting means finding the file it's in | `/etc`, dotfiles, the registry | The config store's overrides layer is the answer, field by field; a reset is deleting a field's override (§2.4) |
| Any program running as the user can read the user's secrets: browsers' cookie and password databases are the target of every infostealer; DPAPI decrypts for any process of the user | Windows, Linux keyrings unlocked for the whole session | Already answered: an installation's `AppData` is its own, and there is no user identity a program could use to read another's. What's added is a secret type that never reaches a log (§2.5) |

### 2.1 Every update is a generation

- `software.md` §5 makes the kernel, the boot set and the configuration a generation. **Data that TCB services load**
  (the substitution policy, the trust store, the keymaps, the time zone database) is in the generation too, by hash,
  never fetched and loaded live behind its back.
- **Staged rollout** for updates from a distributor: the update metadata names a fraction of machines per stage,
  chosen by a per-machine random value; a stage only proceeds when the distributor sees enough healthy reports, which
  is the distributor's business, but the metadata format has the field from the start.

### 2.2 Authentic updates

- When bundles come from elsewhere (M13 brings the network), the update service checks **TUF metadata** (the root,
  targets, snapshot and timestamp roles): a threshold of keys for each role, monotonically increasing versions so an old
  set is refused, and expiry times so a frozen mirror is noticed. Bundle hashes are the targets, so content addressing
  does the rest.
- This is the "signing as a later layer" `0013` left open; it guards distribution, not the administrator (§10.1).
- **Rollback by the user is still allowed**, since it's the administrator's choice; rolling back to a generation
  containing a hash the substitution policy has since replaced warns which fixes it loses.
- Reproducible builds (`../hemera-proposals/reproducible-builds.md`) are what lets anyone check a distributor's hash
  against a build of their own, the defence TUF doesn't give against a compromised build (xz, CVE-2024-3094; SolarWinds).

### 2.3 Updates without lost work

- A generation that changes only services applies **live**: the supervisor restarts each changed service from its new
  bundle, between requests, using the restarts 9a built; clients redial through their connectors.
- A generation that changes the kernel or the boot set is staged and becomes the default **for the next boot**. The
  console's status line says one is waiting; nothing reboots on its own unless the configuration's maintenance window
  says so.
- Downloading and putting objects runs on an idle budget (§9.3), so updating never competes with the user.

### 2.4 Settings from schemas

- The config store answers "what's overridden" per value, field by field, with each override's author and time, and
  resets a field by removing its override.
- A **settings tool** (shell in 11e, GUI in M15) renders any value from its schema with its documentation comments,
  the same way the shell renders results and manifests: no hand-written settings screens to fall behind.

### 2.5 Secrets in Hemera

- `Secret[T]`, a `distinct` wrapper in `std` that the formatter prints as `<secret>`, that the typed log records
  (`../hemera-proposals/typed-log-records.md`) refuse to copy, and whose memory is zeroed when freed. Passphrases in
  the account service, volume keys and TLS keys use it. Proposed to Hemera with 9c.

---

## 3. M10 — Console, Accounts and Sessions

| Problem | Where | SlopOS answer |
|---|---|---|
| Under memory or CPU pressure the whole desktop freezes, and even switching to a text console or killing the culprit doesn't respond | Linux before PSI and `systemd-oomd`; any OS that thrashes | The input and terminal services, the session manager and the powerbox run on reserved budgets at high priority, so the secure attention key's menu always answers; from it, a session's programs can be listed and ended (§3.1) |
| A program that stops responding can't be told apart from a busy one; ending it is `kill -9` from somewhere else | Unix; Windows has "not responding", macOS Force Quit | The lifecycle channel has a `Ping`; a program that misses it while it has the focus is shown as not responding, with an offer to end it (§3.1) |
| A forgotten password on an encrypted home means the data is gone | LUKS, eCryptfs without escrow | A **recovery key** made at setup: the volume key wrapped once more, for a code the user writes down, as FileVault and BitLocker do (§3.2) |
| A password is typed with the wrong keyboard layout at the unlock prompt, and fails for no visible reason | LUKS in the initramfs | The status line shows the layout in use during login, and switching it is a key on the login screen |
| A plugged-in "keyboard" types commands (BadUSB, the Rubber Ducky) | Every OS with HID hot-plug | A new keyboard's keys reach nothing but the trusted path until the user accepts it there, by typing a code shown on screen with it (§3.3) |
| Locale is a global environment variable, so formatting changes under programs that parse their own output (Turkish dotless i, decimal commas) | `LANG`, `LC_*` | The session's locale is a value in the context; machine-facing output is typed, so no parser sees it (§3.4) |
| Filenames and terminal text can hide their real content: right-to-left overrides make `gpj.exe` read as `exe.jpg`; bidi controls make code read differently than it compiles | Every OS; Trojan Source (CVE-2021-42574) | Native names refuse bidirectional controls and other invisible formatting; the terminal shows them as visible substitutes everywhere (§3.5) |
| Password rules force rotation and composition, so people write passwords down | Many enterprise policies, now against NIST SP 800-63B | Length, not composition; no rotation; a check against a list of common passwords shipped with the account service |

### 3.1 Always responsive

- The scheduler service gives the **trusted path's services** (input, terminal, session manager, powerbox, account
  service, and the compositor in M15) a reserved budget at the highest user priority, never lent away, and their memory
  is charged to a budget the session's programs can't exhaust (`0011`).
- **The secure attention key's menu** lists the session's programs with their CPU and memory use (from their budgets,
  attributed with lending, §6.1) and can end any of them, reaching the process through the session manager's
  ownership.
- **The lifecycle channel** (`shell.md` §6, proposed for 11a) gains `Ping`, answered by `std` on its own fiber, so
  answering doesn't depend on the program's own code. A missed `Ping` marks the program not responding. Moved to
  10a, since the terminal service needs it before the shell exists.

### 3.2 Recovery keys

- At setup, and on request, the account service wraps each volume key once more under a key derived from a random
  recovery code (128 bits, shown once as groups of digits). Entering it on the trusted path unlocks the volume and
  sets a new password. Losing both the password and the code still loses the data: that's encryption, and the setup
  screen says so.

### 3.3 New input devices

- The input service keeps a list of accepted devices (by bus path and HID descriptor hash, in the configuration). A new
  one is read only by the trusted path until accepted: the terminal service shows a short code to type on it. The boot
  keyboard and virtio's are accepted by the image builder's configuration. Matters with USB (*Later*), designed in 10a.

### 3.4 Locale as a value

- `Locale` (language, region, number and date formats, collation) is a `context` value set by the session manager from
  the user's configuration, read by `std`'s human-facing formatters only. `runtime.log_*` and every protocol stay
  locale-free. Time zones (TZif, 11a) the same.

### 3.5 Names that show what they are

- slopfs names (`0046`: UTF-8 without `/` or NUL, compared byte for byte) additionally refuse C0 and C1 controls,
  bidirectional controls (U+202A–U+202E, U+2066–U+2069) and the invisible formatting characters Unicode's UTS #39
  lists, with `InvalidName`. Normalization stays byte for byte (§10.4).
- The terminal protocol already never interprets text; it also shows these characters as visible substitutes, so a
  name from a FAT stick that has one can't disguise itself.

---

## 4. M11 — The Shell and Tools

| Problem | Where | SlopOS answer |
|---|---|---|
| `rm` is forever; a typo in a script deletes a home directory | Unix; recycle bins exist only in GUIs | Removal from the shell's tools is recoverable for a while, through snapshots (§4.1) |
| Long operations give no progress and can't be cancelled cleanly (`dd`, `cp` of a large tree) | Unix tools | Progress and cancellation are part of the lifecycle channel (§4.2) |
| Error messages lose their context, or are a code to look up | `errno`'s "No such file or directory"; Windows' 0x8007…-style codes | Errors are typed values with their data; the shell renders them with the parameter they came from and a suggestion where its manifest has one (§4.2) |
| Two names look the same but differ (NFC vs NFD from a Mac, a trailing space) and the file "isn't there" | Every filesystem without normalization | Completion inserts the stored bytes; a typed path that matches only after normalization gets "did you mean" with the difference shown |

### 4.1 Recoverable removal

- Each volume takes **automatic snapshots** on a schedule from the configuration (hourly, kept a day, as Time
  Machine's local snapshots and snapper do), cheap with 8e's birth times.
- The shell's `remove` records what it removed in the session's data, with the snapshot that still has it; **`recover`**
  lists recent removals and restores them through a clone of that snapshot. Space is reclaimed when the snapshot goes,
  and the reserve (8e) keeps deleting possible on a full disk.
- Explore later: running a command's grants inside a volume transaction (`0046`), so `--preview` shows what a command
  would change before it's committed.

### 4.2 Progress, cancellation and errors

- The lifecycle channel carries **`Progress`** (done, total, a unit, a label) from the program and **`Stop`** to it; the
  shell draws progress on the job's line and Ctrl-C sends `Stop` (`shell.md` §6).
- An error's rendering names the parameter it came from where the error's type says so (a field of type
  `ParameterName`), and the manifest's documentation can attach a hint to each error variant.

---

## 5. P — Power

| Problem | Where | SlopOS answer |
|---|---|---|
| Shutdown waits 90 s on a service that won't stop ("A stop job is running…") | systemd's default stop timeout | Shutdown sends `Stop` to everything in reverse dependency order with a short deadline each, commits the volumes, and kills what's left; the log names what was killed |
| A laptop "asleep" in a bag drains its battery or overheats | Windows' Modern Standby | Suspend (when it comes, after P) is only S3 or s2idle with every wake source listed and owned by a capability; no background work while suspended unless granted |
| A stolen laptop that's suspended has its volume keys in RAM | Everything that keeps keys across suspend | Explore: volumes the configuration marks lock on suspend, as iOS's complete protection class does (§10.3) |

---

## 6. M12 — Observability and Debugging

| Problem | Where | SlopOS answer |
|---|---|---|
| "Why is my machine busy?" points at a shared service: `svchost`, `WindowServer`, `kernel_task`, `systemd-journald` | Every OS | Lending already charges a service's work to the client's budget (`0037`); the process tree shows it attributed (§6.1) |
| Symbolizing a crash report parses debug information that came from the crashed program, in a privileged tool | Debuggers and crash reporters everywhere | DWARF is parsed by a decoder with no authority (§9.4) |
| A CPU stuck with interrupts off hangs the machine silently | Every kernel without a lockup detector | A watchdog: CPUs check each other's progress, and a hardware watchdog resets a machine whose supervisor stops answering (§6.2) |

### 6.1 Attribution

- A service's work for a client runs on the client's lent budget (`0037`), so the **process tree** tool (11e) shows
  each process's own use and, separately, what services spent on its behalf; the same for memory charged to
  connections (`0011`). This answers the `svchost` question without a separate accounting system.

### 6.2 Watchdogs

- **Lockup detection:** each CPU's tick checks that every other CPU has passed a quiescent point (`0051`) within a few
  seconds; one that hasn't is sent an NMI, which writes its registers and stack into the panic record and stops the
  kernel with that reason. NMIs and their handler exist since M1.
- **The hardware watchdog** (QEMU's `i6300esb`, the SBSA generic watchdog on AArch64) is driven by a driver whose client
  is the supervisor, which pets it only while the services it supervises answer; a hung system resets, and boot
  counting does the rest.
- Lands in **12a** (lockups) and **P** (the hardware watchdog's driver).

---

## 7. M13 — Networking

| Problem | Where | SlopOS answer |
|---|---|---|
| A local service on `localhost` trusts anything that reaches it, so a web page can call it (Zoom's local web server, 2019; development servers) | Every OS with loopback | There is no loopback for local services: they're reached through capabilities, never by port; loopback exists only for programs that ask for it in their policy |
| DNS rebinding: a name a program may reach resolves to a private or loopback address | Browsers, routers | A policy scoped to names never reaches private, link-local or loopback addresses unless it lists them (§7.1) |
| A dead RTC battery puts the clock in 1970, and every TLS certificate is "not yet valid", so NTP over TLS can't fix it | Everything with TLS and no RTC | The clock service keeps a floor: the generation's build time and the last time it saved, never going below it (§7.2) |

### 7.1 Names don't reach private addresses

- `Destination` by name resolves through the network service and is refused if the answer is in a private, loopback
  or link-local range, unless the policy also names that range. Checked at each connect, since answers change.

### 7.2 A floor for the clock

- The clock service stores the wall time every few minutes and at shutdown, and the generation records its build time;
  the clock starts at the latest of these and the RTC. NTS (RFC 8915) can then authenticate, since certificates
  validate against a time that's late, never decades early.

---

## 8. M15 and M16 — Display and Audio

| Problem | Where | SlopOS answer |
|---|---|---|
| The screen locker is a client; when it crashes, the session is unlocked | X11 screen lockers, long complained of by xscreensaver's author | The lock screen is the compositor's trusted layer (`display.md` §5): if the locker's process dies, the screen stays locked (fails closed) |
| A window takes the focus while the user types, and gets the password meant for another | X11, Windows' focus stealing | Focus moves only on the user's gesture, or with an activation token from the focused client (Wayland's `xdg-activation`) |
| Notifications are a free-for-all, used for advertising | Android, Windows | Notifications are a capability granted per installation, rate-limited, and listed in the session's grants |
| Fractional scaling and HiDPI are retrofits, blurry or inconsistent | X11, Windows | Surfaces declare a scale from the first protocol version, and the UI library lays out in logical units |
| Input-to-photon latency isn't measured, only felt | Most desktops | A boot test measures it with injected input and presentation feedback, as the audio test counts underruns |

---

## 9. New Tracks

### 9.1 Perf — Numbers Kept, Not Assumed

Performance wins over determinism and protection (`0013`, `0024`), so it should be measured as carefully.

- **Benchmarks as boot tests** with recorded baselines, failing on a regression beyond a margin: IPC round trip
  (notify-and-wait through a channel, the number to compare with seL4's), page fault on an anonymous object, thread
  and process creation, a program's start from the bundle store, file create and `Sync` on slopfs, boot to healthy.
  QEMU's timing is noisy, so these use instruction counts where it can give them (`-icount`) and wall time as a second
  number.
- **Tickless idle**: an idle CPU stops ticking (`0050` left it for when power matters); with ticks only on CPUs
  running a budget, an idle machine's host CPU use drops, which is visible even under QEMU.
- **Large pages** for the direct map and for memory objects of 2 MiB and more, where they're aligned.
- **Storage bandwidth by budget**: a background copy shouldn't stall the interactive session (Linux's bug 12309, a
  decade of desktop stalls under writeback). The volume and container services schedule requests by the lent
  budget's priority, and writeback of one client doesn't block another's reads.
- Lands alongside each milestone, with the benchmark suite in **9c**, so later milestones have baselines.

### 9.2 Memory Pressure and Reclaim

No overcommit (`0011`) removes the OOM killer, but not pressure: caches in services (volume servers, the bundle
store's pages, 9b's pager-backed objects) grow until a budget is full, and then allocation fails somewhere unrelated.

- **A pressure signal**: a new signal on memory budgets, raised at a threshold the holder sets and bound to a port like
  any other (`0052`), so a service learns it's near its limit before allocations fail, as Linux's PSI and iOS's memory
  warnings do.
- **Evictable pages**: pager-backed memory objects (9b) can give clean pages back to their pager under pressure, and
  fault them in again; the pager decides which (CLOCK-Pro or ARC rather than plain LRU, for scans).
- **The session manager's policy** for sessions: idle installations are asked to save and `Stop` first (Android's
  `lmkd`, iOS's jetsam), never a random kill.
- **No swap** to begin with; compressed memory (as macOS and `zram` do) is the first thing to try if one is needed.
- The trusted path's working set is never evicted (§3.1).
- Lands in **9c** (the signal) and **10c** (the session policy).

### 9.3 Background Work

- An **idle budget** class in the scheduler service: runs only on CPU time no other budget wants, never lends upward.
  Updates (§2.3), snapshots' cleanup, the bundle store's collection and future indexing use it, so maintenance never
  makes a machine slow at the moment someone uses it (Windows' antivirus scans and Superfetch).

### 9.4 Untrusted Data in Processes With Nothing

The pattern already used for the FAT server and the AML interpreter, made a rule: **anything that parses data from
outside the system runs in a process that holds only its input and its output channel** (as Chrome's renderers and
iOS's BlastDoor do). Applies to fonts (M15), images, archives, DWARF in crash reports (§6), certificates and TLS
records where practical (`networking.md` §9's TLS-service question), and the image builder's own reading of foreign
images. `std` provides a `decode_in_process` helper: launch a decoder, give it the bytes, read back a typed value.

### 9.5 R — Robustness: Testing Every Path

Rule 2 says every error path is handled; only some of them are ever run. Bug classes other kernels found the hard
way, and their tests:

| Bug class | Where | Test |
|---|---|---|
| Error paths never run, so they're wrong | Linux, found by `failslab` and syzkaller | **Fault injection**: a test setting fails the *n*th allocation, budget charge, frame allocation or block request; boot tests and hosted tests sweep *n* |
| Counters that wrap after long uptime | Windows 95/98's hang at 49.7 days; the Boeing 787's power-down at 248 days | **Start near the wrap**: test builds start the clock, handle generations, sequence numbers and IOVAs close to their limits, as Linux's `INITIAL_JIFFIES` does |
| Lock order inversions found in production | Every SMP kernel; Linux answered with `lockdep` | **Lock order checking** in debug kernels: `0053`'s order (core, then port, then run queue) checked at every acquisition |
| Races that appear once in a million runs | Everything concurrent | **Schedule exploration** for hosted tests of lock-free code (the frame allocator's per-CPU caches, the slab magazines), as `loom` and CHESS do |
| A write error lost after a failed `fsync`, so the application believes data is on disk | Linux, fsyncgate (PostgreSQL, 2018) | A **faulty `block` driver** for tests that fails chosen writes; slopfs must report the error to every `Sync` after it, never only the first |
| Recovery code that's never exercised | Everyone's restart paths | **Chaos boot tests**: kill random services and drivers in a loop; the system must keep serving, and budgets must show no leaks afterwards |

Planned in `../decisions/0096`, in six stages. R runs from now: fault injection and wrap starts first (they find bugs in what's already built), lock order checking
with them, chaos tests once 10a can show what's running.

---

## 10. Decisions This Would Revisit

These are the user's to decide; nothing above depends on them except where it says so.

### 10.1 Physical attackers and the boot set (`0013`, `0042`)

`0013` leaves out an administrator who replaces system software, and `0042` the TPM. With B, the bootloader is SlopOS's
own and already hashes the boot set (§1.5), so **sealing** is a small step: a TPM (QEMU's `swtpm`) measures the
bootloader and the generation record, and the volume key's wrap for the system volume is sealed to those
measurements, so a modified boot set can't capture a passphrase without the unlock failing visibly first. This guards
against an evil maid, not an administrator. Proposed as an option for B, off by default.

### 10.2 Transient execution (`0013`)

`0013` accepts no costly mitigations, and keeps cheap ones. Worth recording per CPU, at boot, which are needed and
free: `RDCL_NO` and friends from `IA32_ARCH_CAPABILITIES` make KPTI unnecessary on most CPUs since 2019; `VERW` buffer
clearing on returns to user space costs little where MDS applies. A boot log line saying which vulnerabilities apply
to this CPU and which are left open makes the trade visible instead of silent. Proposed for H.

### 10.3 Keys across suspend (`0042`)

`0042` keeps a volume unlocked until shutdown. Once suspend exists (after P), a per-volume option to forget its key on
suspend and ask for the password on resume, as iOS's complete protection class does. Not before suspend.

### 10.4 Normalized names (`0046`)

`0046` compares names byte for byte. The alternative, refusing names that aren't NFC, avoids two files that look the
same, at the cost of copying a name from a FAT stick or a Mac failing. Proposed: keep bytes, refuse invisible and
bidirectional characters (§3.5), and let the shell bridge the rest (§4).
