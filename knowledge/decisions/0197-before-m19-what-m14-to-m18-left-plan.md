# 0197: Before M19, What M14 to M18 Left, Planned

Status: accepted; built
Date: 2026-11-23
Related: `0191` (M14, SFTP), `0193` (M16, what its review left), `0195` (M18, what its review left), `0196` (M17, the
microphone), `0013` (the threat model), `0022` (RISC-V third), `../design/lessons.md` §10.1, `../hemera-feedback.md`,
`../roadmap.md`
Before M19

## Context
M18 is built, and nothing was planned after it. The reviews of M14 to M18 left items for the project's owner, M17
deferred one to M18, and `open-questions.md` held one question past its time. The owner settled them on 2026-11-23,
and chose RISC-V as the next track (M19). This stage clears what's small first, as Before M13 did.

## Settled with the owner (2026-11-23)
- **SFTP stays in the SSH service** (`0191`, *As Built: 14e*, changed from the plan). It reaches only the login's
  home, as a program would; its parser runs in the service that holds every connection, and is fuzzed.
- **Sealing the system volume's key to a measured boot is dropped** (`lessons.md` §10.1). The threat model (`0013`)
  stops at an attacker with the disk; one who can change the boot set (an evil maid) is out of it.
- **M18's review, fixed in part** (`0195`, *As Built: 18e*):
  - Fixed here: (a) the steering prompt names the program by what the asker says; (c) two installations of one
    executable can't be told apart.
  - Accepted as recorded: (b) a debugger the user allows to attach to a running program acts with that program's
    grants, as attaching always has; (d) the process manager lets go of a gone program's handles only when it's next
    asked something.

## Decision: N1, the microphone's mark on its holder's windows
M17 showed the microphone's indicator in the trusted layer and the console's status line, and left a mark on each
holding program's windows for M18 (`0196`, *Chosen with the owner after 17e*). M18 names every powerbox and compositor
connection by its holder's launch, so the powerbox's grant and the compositor's windows now share a name the system
proved. The compositor marks, on the identity band it draws, each window whose connection is named as a holder of a
microphone grant, while the grant is held; the powerbox tells it, through the trusted path's own connection, when a
grant is given and taken back. No client can draw the mark, nor take it away. Tests: the GUI login test's
microphone grant shows the mark on the granted program's window and not on another's, and takes it away on Revoke.

## Decision: N2, M18's (a) and (c)
- **(a) The steering prompt names what's steered by its launch.** The session manager asks the process manager's
  `Identify` of the program to be steered, and the prompt shows the installation its executable was handed out as,
  not the name the asker gave. A program that wasn't launched from a handed-out executable is shown as such.
- **(c) Installations told apart.** Two installations of one executable share one memory object in the bundle store,
  so `handle_same` can't tell which was launched. The stage chooses between giving each installation its own object
  over the same frames (so the executable's handle names the installation), and the process manager keeping the
  installation each launch was found as. To settle when it's built, the first preferred: it keeps the process
  manager knowing nothing of installations.

## Decision: N3, what M16 and M17 left
- **The trusted path's waits get deadlines** (`0196`, *As Built: 17h*): its waits on the audio service and the session
  manager. Nothing in them waits on a program, but a stuck service shouldn't stop the secure attention key.
- **A failed launch's font handles** (`0193`, *As Built: 16g*): `os.launch`'s `ManagerGone` split into a request not
  sent, whose handles are closed, and one sent and not answered, whose handles are the manager's now.
- **The greeter's keys zeroed** in gui_kit's and the compositor's queues once taken.
- Kept as recorded in `0193`: ListKeys answering without asking (public keys and their comments), and the greeter's
  fonts in the bundle store.

## Decision: N4, Hemera
- **A warning for an escape a string doesn't know** (`"\x00"` is `x00` today, with nothing said).
- **Checked arithmetic**: intrinsics over LLVM's `llvm.*.with.overflow`, the shell language's hand-written checks
  moved to them.
- **An undeclared name's cascade**: in M18's 18b, one undeclared name in a shell file gave about 64 E4030 errors
  ("escapes into the stack") elsewhere, which hid it. Errors that follow from a name that couldn't be resolved are
  left out.
- **The race in `get_base_type`** (`0196`, *As Built: 17c*): the compiler crashed laying a struct out once, then built
  the same sources cleanly. Looked into under load, with the struct layouts of that build.

## M19, RISC-V
Planned with the owner when Before M19 is built, on A's pattern (`0061` to `0066`): LLVM built with its RISC-V backend
and Hemera's `riscv64` for Linux first, its tests under user-mode QEMU; kernel entry (`sret`, the CSRs by name, the
carrier register `s11`); the kernel on QEMU `virt` through SlopOS's bootloader on UEFI; Sv48 paging with ASIDs, the
AIA's interrupt controllers or the PLIC, SBI's timer or Sstc, the other harts; user mode, and every boot test that
applies; then the RISC-V IOMMU and the CFI extensions (Zicfiss, Zicfilp) as D and H did for the others.

## Alternatives considered
- **Real hardware next** (NVMe, xHCI, AHCI): what everything so far lacks, since it runs only under QEMU; the owner
  chose RISC-V first.
- **Fixing all of M18's four**: (b) would change what debugging can do; (d) costs a timer for nothing a user sees.

## As Built: N1, the microphone's mark
- **The surface protocol's `MicrophoneHeld`**, a trusted client's alone: the holders' names, each ended by a line
  break, at most `MAX_HELD_BYTES` (256). The compositor draws "Microphone", white on red in a box no title can draw,
  after the name on the band of every window whose client is named as a holder, and logs how many programs hold it and
  how many windows are marked. From any other client it's refused, and logged.
- **The greeter tells it** whenever its holders change (`show_microphone`): a grant given, let go, taken back, or every
  one gone with the audio service. The names are the prompt's requesters, which are the names the session manager gave
  the programs' powerbox and compositor connections alike. Two copies of one program share a name, so both are marked
  while either holds it; a script, shown as "name, a script", has no window to mark.
- **Tests:** test_compositor is given a trusted connection too, by the supervisor, only with its word on the command
  line, on the trusted listener's other end, which no greeter has then: A, not trusted, saying who holds it is refused;
  the trusted connection saying A does marks A's window and not B's, never named; then none. The GUI login test sees
  the compositor told capture holds it, with no window of its own to mark.

## As Built: N2, what's steered named by its launch, and installations told apart
- **(a)** Before the powerbox asks the user to let a program steer one it launched (`RequestSteer`), it asks the session
  manager what that one was launched as (`NameOwn`, with a copy of the launcher's handle), and waits for the answer as
  it does for `Locate`, not in place. The session manager asks the process manager's new `IdentifyProcess`, on its
  steering connection, which finds the program by that handle as `Steer` does and answers `Identified`; the name's
  the installation whose window it was loaded from. The prompt shows that name, or for a program loaded from no
  executable `Find` gave, the asker's name followed by ", by its launcher's word". The first run found the powerbox's
  copy without `RIGHT_DUPLICATE`, which the session manager needs to send one on: every name came back empty.
- **(c)** `Find` gives each installation's executable as a window of its own onto the bundle store's
  (`memory_create_window`), so the process manager's copy of what a program was loaded from names the installation.
  A name and executable kept already give a copy of the same window; a new one takes a free place, or the oldest
  whose window no one else holds (`memory_holders`), since closing a window destroys it, and a program the process
  manager still keeps names it by it. With every place held, `Find` gives the executable itself, whose programs'
  powerbox connections then aren't named, and says so. The process manager copies an executable before building
  from it, so a window gone later takes nothing from a program running.

## As Built: N3, what M16 and M17 left
- **Deadlines:** `std/os`'s generated `receive_request` and `receive_response` take a `deadline`, `NO_DEADLINE` by
  default, and answer `Empty` past it (`receive` and `arrive` beneath them). The trusted path waits `ANSWER_LIMIT`, 5 s,
  for the audio service and the session manager: the terminal service's `ask_session` and the microphone's grants, the
  greeter's volume and grants. An answer given up on is owed, counted, and dropped when it comes, so it isn't taken for
  the next request's; a microphone connection that doesn't answer in time is let go, every grant with it, as the audio
  service closes them. Starting and ending a session wait on its programs, so they keep no limit. On the way: the
  greeter took any answer for the one it waited for, so a session that ended while the volume was being set would
  have lost its `Exited`, and the login window not come back; it's kept for `wait_for_session` now.
- **A failed launch's font handles** aren't leaked: `send` takes a message's handles out of the caller's table whether
  or not it's sent, closing them if they weren't, so after `ManagerGone` or `NotLoaded` none are the launcher's, and
  `close_font_grants` already closes them only before the send. Nothing changed; 0193's note was wrong.
- **Typed text zeroed:** the compositor zeroes a client's queued text once it's given or dropped, and the message that
  carried it once it's sent; gui_kit zeroes the text it queues for a frame, pasted text and the raw keys' text once
  they're taken, and each `Input` message once it's read.

## As Built: N4, Hemera
- **W2003**, an escape that isn't one, in strings and characters: any but the table's and `\\`, `\"` and `\'`. Its
  first build of SlopOS found the bootloader's backspace, `"\x08 \x08"`, showing `x08 x08` on the screen; it's
  `"\u{8} \u{8}"` now.
- **Checked arithmetic:** `intrinsics.add_overflows`, `subtract_overflows` and `multiply_overflows`, LLVM's
  `*.with.overflow` signed or not as the type is, and `std:math`'s `checked_add`, `checked_subtract` and
  `checked_multiply`, giving optionals. The shell language's `added`, `subtracted`, `multiplied`, `added_sizes` and
  `multiplied_sizes` are them now.
- **The cascade** came from the stack-pointer check: a function whose body had errors wasn't checked, so its callers
  took it to give back pointers from all they passed it, and each `&local` passed was reported escaping. It's taken
  to give back nothing now; its own errors are reported.
- **The race in `get_base_type`** didn't come back: SlopOS's programs built from scratch six times on each architecture,
  every one checked and laid out again, without a crash. Left noted.
- **Found on the way:** the bounds proof loses a counter kept at most a fixed array's count through a loop, which the
  powerbox's prompt needed an unreachable `if` for (`hemera-feedback.md`).

## As Built: the full suites
Run 2026-11-23: the boot suite (310 of 310; two failed among the others and passed alone: test_memory's large pages
once, and a bootloader test whose expected line a QEMU message cut in two), HemeraTest (303 passed), the Linux tests
(85 of 85 on x86-64, 83 of 83 on AArch64), the unit tests (25 of 25) and every fuzz target for 60 s (26, nothing
found). Status: built.
