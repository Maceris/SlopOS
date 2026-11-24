# 0197: Before M19, What M14 to M18 Left, Planned

Status: accepted
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
