"""
Builds SlopOS's kernel once, through its build package (src/build), then boots it for each test
below with tools/boot.py and checks the code it stops with (src/kernel/stop.hsc, StopReason). Tests
of growing stacks get a second kernel, built with morestack (the build package's stack_check), and the
AArch64 tests kernels built for AArch64 (its arch setting), the same two ways.
Exits 0 if every test passed. SLOPOS_BOOT_TESTS, names separated by commas, runs only the tests whose names have one of
them in them. SLOPOS_KVM_HOST, user@address of a Linux machine with KVM and a CPU with CET, adds the tests that boot
there (KVM_TESTS, boot.py --kvm).

The tests boot in parallel, --jobs of them at once (or SLOPOS_BOOT_JOBS; half the CPUs, at most 8, by default), the
slowest of the last run first; each QEMU has 512 MiB. A test that fails among the others is booted again alone: if it
passes then, it's reported FLAKY, a timing it's sensitive to, and doesn't fail the run, unless it stopped with a fatal error (a
kernel fault, a failed assertion) the first time. --jobs 1 boots one at a time.

With --robustness it runs the robustness sweeps instead (knowledge/decisions/0096, 0104): kernels built with robustness=on
boot each of SWEEP_TESTS once counting the passes through the kernel's failure points (fail=count), then once for each
pass chosen, failing it (fail=any:<n>). Each run must halt, stop for want of memory, or end its root task with nothing
of anyone else's left, never fault, fail an assertion or hang. Then a boot from the image builder's disk, its programs
built with robustness=on too, for each of FAULTY_BLOCKS: the partition server fails that read or write, or tears that
write (faulty_block, decisions/0112), and the run must end as a failed allocation's may.

    python tools/boot_tests.py
    python tools/boot_tests.py --jobs 4
    python tools/boot_tests.py --robustness
"""

import json
import os
import subprocess
import sys
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BOOT = ROOT / "tools" / "boot.py"
# SlopOS's programs, built once for each architecture, carried as modules by the tests whose arguments have WITH_PROGRAMS
PROGRAMS = Path()
PROGRAMS_AARCH64 = Path()
# How long each test took, in seconds, by name, for the summary of the slowest
TIMINGS: dict[str, float] = {}
WITH_PROGRAMS = "<programs>"
# The image builder, built once, for the tests whose arguments have WITH_IMAGE_BUILDER (decisions/0088)
IMAGE_BUILDER = Path()
WITH_IMAGE_BUILDER = "<image builder>"
# How many tests boot at once (--jobs, SLOPOS_BOOT_JOBS)
JOBS = 1
# Each test's time the last run, slowest first next time; kept outside the repository
TIMINGS_FILE = Path(tempfile.gettempdir()) / "slopos_boot_test_timings.json"
# Tests booted again alone that passed then
FLAKY: list[str] = []
# One test's lines printed at a time
PRINTING = threading.Lock()


def jobs_wanted() -> int:
    """--jobs N, or SLOPOS_BOOT_JOBS, or half the CPUs, at most 8."""
    arguments = sys.argv[1:]
    for i, argument in enumerate(arguments):
        if argument == "--jobs" and i + 1 < len(arguments):
            return max(1, int(arguments[i + 1]))
        if argument.startswith("--jobs="):
            return max(1, int(argument.split("=", 1)[1]))
    if os.environ.get("SLOPOS_BOOT_JOBS"):
        return max(1, int(os.environ["SLOPOS_BOOT_JOBS"]))
    return max(1, min(8, (os.cpu_count() or 2) // 2))


def boot_arguments(arguments: list, more: list) -> list:
    """
    boot.py's arguments for a test: the programs and the image builder built once in place of WITH_PROGRAMS and
    WITH_IMAGE_BUILDER. Every boot needs both, for the bootloader and the ISO's generation (decisions/0135), so a test
    without WITH_PROGRAMS boots the kernel alone, with the programs only for the bootloader.
    """
    programs = PROGRAMS_AARCH64 if "--arch=aarch64" in more + arguments else PROGRAMS
    alone = [] if WITH_PROGRAMS in arguments else ["--kernel-alone"]
    return more + [f"--programs={programs}", f"--image-builder={IMAGE_BUILDER}"] + alone + [
        argument for argument in arguments if argument not in (WITH_PROGRAMS, WITH_IMAGE_BUILDER)]


def summary(count: int, passed: int, skipped: int = 0) -> str:
    """A run of tests' last line when none failed (Hemera's docs/testing.md): how many ran, passed and skipped themselves."""
    line = f"{count} test{'' if count == 1 else 's'}: {passed} passed, 0 failed"
    return line + (f", {skipped} skipped" if skipped else "")


def tests_passed(program: str, count: int, skipped: int = 0) -> str:
    """The line a program's tests end with when none failed: count of them, all but skipped passing."""
    return f"[user] {program}: {summary(count, count - skipped, skipped)}"


def program_test(name: str, program: str, line, words: str = "", qemu: list = []) -> tuple:
    """
    A test program the root task runs (src/tests, knowledge/decisions/0069) on 2 CPUs, with more QEMU arguments if it
    needs a device: it says line, or, given a number, reports that many tests all passed (decisions/0175), and ends with
    0, its budget is back to nothing, and once the root task has ended, only the kernel's own objects are left.
    """
    command_line = f"test_exit {words} test_program={program}" if words else f"test_exit test_program={program}"
    said = tests_passed(program, line) if isinstance(line, int) else f"[user] {program}: {line}"
    return (name, 7, [WITH_PROGRAMS, f"--command-line={command_line}", f"--expect-line={said}",
                      f"--expect-line=[user] root task: {program} ended with 0, and its budget is back to nothing",
                      "--expect-line=[info] objects left: only the kernel's own", "--", "-smp", "2", *qemu])


# What the kernel says of the IOMMU QEMU gives each machine (src/kernel/iommus.hsc)
X86_IOMMU_LINE = "[info] IOMMU 0: VT-d, 4 KiB of registers at 0x00000000fed90000, version 1.0, 48-bit I/O addresses"
AARCH64_IOMMU_LINE = "[info] IOMMU 0: SMMUv3, 128 KiB of registers at 0x0000000009050000, version 3.1, 44-bit I/O addresses"
# How it translates (src/kernel/translation.hsc): VT-d remapping interrupts too, and signalling its faults; SMMUv3 not
# The real-time clock the platform service finds: the MC146818 on x86-64, and the device tree's PL031 on AArch64
X86_CLOCK_LINE = "[user] platform: the real-time clock (Mc146818) claimed"
# What the shell says of a program that ran intrinsics.trap: ud2 on x86-64, brk on AArch64
CRASH_LINE = "error: test_shell_calls crashed: invalid instruction; crashes shows where"
AARCH64_CRASH_LINE = "error: test_shell_calls crashed: breakpoint; crashes shows where"
CRASH_REPORT_LINE = "test_shell_calls: invalid instruction"
AARCH64_CRASH_REPORT_LINE = "test_shell_calls: breakpoint"
AARCH64_CLOCK_LINE = "[user] platform: the real-time clock (Pl031) claimed"
# test_control's tests (decisions/0186): a tampered return, a branch to no landing pad and a write to the shadow stack
# are refused on AArch64, with pointer authentication, branch target identification and the Guarded Control Stack, and
# skipped on x86-64 under TCG, which has no CET
X86_CONTROL_TESTS = "8 tests: 5 passed, 0 failed, 3 skipped"
AARCH64_CONTROL_TESTS = "8 tests: 8 passed, 0 failed"
# What QEMU's max CPU has against exploits (decisions/0186): TCG gives x86-64 no CET, and AArch64 all three
X86_HARDENING_LINE = "[boot] cpu: control-flow integrity: shadow stacks no, indirect branch tracking no"
AARCH64_HARDENING_LINE = ("[boot] cpu: control-flow integrity: branch target identification yes, pointer authentication yes, "
                          "guarded control stack yes")
# The host bridge's windows from its _CRS, which the ACPI service gives (decisions/0182, P3); AArch64's are the device
# tree's ranges, which say nothing, so its test only sees the platform service serve
X86_WINDOWS_LINE = "[user] platform: the host bridge's 3 windows from its _CRS"
AARCH64_WINDOWS_LINE = "[user] platform: serving"
X86_TRANSLATING_LINE = "[info] IOMMU 0: translating, 256 interrupts remapped, its faults to CPU 0's interrupt 48"
AARCH64_TRANSLATING_LINE = "[info] IOMMU 0: translating, 0 interrupts remapped, its faults read at CPU 0's ticks"

# Lines of a boot disk's that a test killing the storage stack and the config service may not get to
RACING_RESTARTS = ["--expect-line=[user] fat_server: FSInfo's free count is the FAT's",
                   "--expect-line=[user] hello: config: declared repeats 1, wrote an override kept, read it back merged, by hello; "
                   "rolled back kept, repeats 1"]

# What the root task says of a boot every service the system needs came up in (decisions/0115)
HEALTHY_LINE = "--expect-line=[user] root task: the system is healthy"

# Name, the code expected, and boot.py's arguments
# What booting from the image builder's disk checks: the disk's four partitions, the FAT server on its EFI system
# partition, which the bootloader was read from, and the disk check's lines and writes, as on the test disk
# A boot disk to healthy without the disk check, which the boot's assessment waits for, and most tests of a disk don't need
BOOT_DISK_BASE = [
    WITH_PROGRAMS,
    WITH_IMAGE_BUILDER,
    "--boot-disk",
    "--timeout=120",
    "--command-line=test_exit test_services no_disk_check",
    "--disk=SlopOS disk check: from the host",
    "--expect-line=[user] virtio_blk: serving 206848 blocks",
    "--expect-line=[user] partition_server: 4 partitions on a disk of 206848 blocks",
    "--expect-line=[user] storage_manager: disk 0 partition 0: SlopOS check, 2048 blocks from 2048",
    "--expect-line=[user] storage_manager: disk 0 partition 2: EFI system partition, 131072 blocks from 6144",
    "--expect-line=[user] storage_manager: disk 0 partition 3: SlopOS system, 65536 blocks from 137216",
    "--expect-line=[user] storage_manager: started a FAT server for disk 0 partition 2",
    "--expect-line=[user] fat_server: serving a FAT32 volume of 128992 clusters of 512 bytes",
    "--expect-line=[user] fat_server: FSInfo's free count is the FAT's",
    "--expect-line=[user] hello: the entropy service gave 32 random bytes",
    "--expect-line=[user] storage_manager: started a container service for disk 0 partition 3",
    "--expect-line=[user] storage_manager: started a volume server for the system volume",
    "--expect-line=[user] volume_server: serving volume 1 (system), from transaction 3",
    "--expect-line=[user] supervisor: terminal from the bundle store",
    "--expect-line=[user] supervisor: hello from the bundle store",
    "--expect-line=[user] hello: heap working, random numbers working",
    "--expect-line=[user] config: serving",
    "--expect-line=[user] root task: booted generation 1",
    HEALTHY_LINE,
    "--expect-line=[user] supervisor: the system configuration's override tunes 0 services",
    "--expect-line=[user] hello: config: declared repeats 1, wrote an override kept, read it back merged, by hello; rolled back kept, repeats 1",
    "--expect-line=[info] root task ended with code 0",
    "--",
    "-smp",
    "2",
]
# The line of test_debug.hsc whose write crashes it, which a crash report with lines names
TEST_DEBUG_CRASH_LINE = 85
# The line of test_debug.hsc the debugger breaks at, where its values are all made and kept in memory
TEST_DEBUG_BREAK_LINE = 61
# BOOT_DISK_BASE with the programs' debug files in the store (decisions/0185), on a disk boot.py makes bigger for them
WITH_DEBUG_FILES = [argument.replace("serving 206848 blocks", "serving 305152 blocks")
                    .replace("partitions on a disk of 206848 blocks", "partitions on a disk of 305152 blocks")
                    .replace("SlopOS system, 65536 blocks", "SlopOS system, 163840 blocks") for argument in BOOT_DISK_BASE]

# What the disk check says, and writes, which the tests of booting a disk itself check
DISK_CHECK_LINES = [
    "--expect-line=[user] supervisor: disk_check from the bundle store",
    "--expect-line=[user] storage_manager: started a volume server for the sealed volume, encrypted",
    "--expect-line=[user] volume_server: volume 2 unlocked",
    "--expect-line=[user] volume_server: volume 2 sealing with key generation 2",
    "--expect-line=[user] storage_manager: made the made sealed volume",
    f"--expect-line={tests_passed('disk_check', 13)}",
    "--expect-disk-block=2049=SlopOS disk check: from the guest",
    "--expect-disk-text=Written by the guest, through std's files",
    "--expect-disk-text=Written to the system volume by the guest, and synced",
    "--refuse-disk-text=ONLY ITS PASSPHRASE OPENS THIS",
    "--refuse-disk-text=WRITTEN TO THE SEALED VOLUME WITH ITS FIRST KEY GENERATION",
    "--refuse-disk-text=WRITTEN TO THE SEALED VOLUME WITH ITS SECOND KEY GENERATION",
]

# A boot disk with the disk check, its lines before the arguments for QEMU
BOOT_DISK_ARGUMENTS = [argument.replace(" no_disk_check", "") for argument in BOOT_DISK_BASE[:-3]] + DISK_CHECK_LINES + BOOT_DISK_BASE[-3:]



def one_cpu(arguments: list[str]) -> list[str]:
    """boot.py's arguments with QEMU given one CPU, where they gave it more."""
    at = arguments.index("-smp")
    return arguments[:at + 1] + ["1"] + arguments[at + 2:]


def with_before_qemu(arguments: list[str], more: list[str]) -> list[str]:
    """boot.py's arguments with more added before those it passes on to QEMU, after "--"."""
    split = arguments.index("--") if "--" in arguments else len(arguments)
    return arguments[:split] + more + arguments[split:]


TESTS = [
    ("boots and halts", 0, ["--expect-line=[info] boot memory reclaimed", f"--expect-line={X86_HARDENING_LINE}"]),
    # Hemera's UEFI target (roadmap B1, decisions/0132): a program the firmware runs, which turns the machine off
    ("runs a Hemera program under UEFI, its memory from the pool and its log on the console", 0, [WITH_PROGRAMS, "--efi=uefi_hello",
        "--expect-line=[info] uefi_hello: Hemera on UEFI, 1000 numbers from the pool adding up to 499500"]),
    ("starts the first services from the root task", 7, [WITH_PROGRAMS, "--command-line=test_exit test_services",
        "--expect-line=[boot] module root_task.elf", "--expect-line=[user] root task: started, with 79 grants",
        "--expect-line=[user] entropy: serving", "--expect-line=[user] root task: started process_manager",
        "--expect-line=[user] scheduler: 6 budgets and the default split off the root's, 1000000 of its 1000000 millionths of a CPU",
        "--expect-line=[user] root task: started scheduler",
        "--expect-line=[user] process manager: started supervisor", "--expect-line=[user] process manager: started hello",
        "--expect-line=[user] hello: heap working, random numbers working",
        "--expect-line=[user] hello: the entropy service gave 32 random bytes", "--expect-line=[user] root task: the supervisor started hello",
        "--expect-line=[user] platform: serving", "--expect-line=[user] root task: the supervisor started all 8 of its services",
        HEALTHY_LINE,
        "--expect-line=[info] root task ended with code 0"]),
    # The IOMMU the platform service found in the firmware tables, which the kernel identified
    ("registers the IOMMU from the firmware tables", 7, [WITH_PROGRAMS, "--command-line=test_exit test_services",
        f"--expect-line={X86_IOMMU_LINE}", f"--expect-line={X86_TRANSLATING_LINE}", "--expect-line=[user] platform: serving",
        "--expect-line=[info] root task ended with code 0"]),
    # virtio-rng, modern only, found by the platform service, claimed by the supervisor for its driver
    ("drives virtio-rng from the platform service, and reseeds entropy from it", 7, [WITH_PROGRAMS,
        "--command-line=test_exit test_services", "--expect-line=[user] platform: 0:3.0 (6900 4164) claimed",
        "--expect-line=[user] root task: the supervisor started virtio_rng",
        "--expect-line=[user] virtio_rng: serving, a source of the entropy service's",
        "--expect-line=[user] entropy: reseeded from a hardware source, 32 bytes",
        "--expect-line=[info] root task ended with code 0", "--", "-smp", "2", "-device", "virtio-rng-pci,disable-legacy=on,iommu_platform=on"]),
    # The same without an IOMMU, where only trusted drivers will get DMA (decisions/0079)
    ("drives virtio-rng without an IOMMU", 7, [WITH_PROGRAMS, "--no-iommu", "--command-line=test_exit test_services",
        "--expect-line=[user] platform: the firmware tables describe no IOMMU, so devices' DMA reaches all of memory",
        "--expect-line=[user] virtio_rng: serving, a source of the entropy service's",
        "--expect-line=[info] root task ended with code 0", "--", "-smp", "2", "-device", "virtio-rng-pci,disable-legacy=on"]),
    # QEMU's edu device, its driver not trusted: DMA outside its domain blocked, and the driver killed and started again
    # until it's ended too often (knowledge/decisions/0084)
    ("stops a driver that DMAs outside its domain, until it's ended too often", 7, [WITH_PROGRAMS,
        "--command-line=test_exit test_services test_dma_fault",
        "--expect-line=[user] edu_dma: writing outside its domain, at 0x0000000004100000",
        "--expect-line=[user] supervisor: edu_dma's DMA was blocked, at 0x0000000004100000; killing it",
        "--expect-line=[user] supervisor: restarted edu_dma",
        "--expect-line=[user] supervisor: edu_dma ended 4 times in a minute, and isn't started again",
        "--expect-line=[info] root task ended with code 0", "--expect-line=[info] objects left: only the kernel's own",
        "--", "-smp", "2", "-device", "edu"]),
    # Without an IOMMU, a driver that isn't trusted gets no DMA memory
    ("gives no DMA memory to a driver that isn't trusted, without an IOMMU", 7, [WITH_PROGRAMS, "--no-iommu",
        "--command-line=test_exit test_services test_dma_fault",
        "--expect-line=[user] edu_dma: no DMA memory, as no IOMMU confines its device and it isn't trusted",
        "--expect-line=[user] root task: the supervisor's edu_dma ended with 0", "--expect-line=[info] root task ended with code 0",
        "--", "-smp", "2", "-device", "edu"]),
    # A virtio console whose other end boot.py types into: hello's line through the terminal service, and echo's answer
    ("shows lines on a virtio console, and echoes what's typed into it", 7, [WITH_PROGRAMS,
        "--command-line=test_exit test_services test_settle=4", "--console-input=ping from the host",
        "--console-input-after=hello: heap and random numbers working",
        "--expect-line=[user] virtio_console: serving", "--expect-line=[user] echo: read ping from the host",
        "--expect-console-line=SlopOS console", "--expect-console-line=hello: heap and random numbers working",
        "--expect-line=[user] echo: its locale is neutral",
        "--expect-console-line=Numbers here look like 1234567.89, and dates like 2026-12-31.",
        "--expect-console-line=echo: ping from the host", "--expect-line=[info] root task ended with code 0", "--", "-smp", "2"]),
    # Hemera's std/terminal line editor (decisions/0164), in echo: "abd", Left, "c" and Enter is abcd; then Up recalls it,
    # Home and "z" make zabcd
    ("edits a line with the cursor, and recalls a line from history", 7, [WITH_PROGRAMS,
        "--command-line=test_exit test_services test_settle=5", "--console-input=abd\\e[Dc\\r\\p\\e[A\\e[Hz",
        "--console-input-after=hello: heap and random numbers working",
        "--expect-console-line=echo: abcd", "--expect-console-line=echo: zabcd", "--expect-line=[user] echo: read zabcd",
        "--expect-line=[info] root task ended with code 0", "--", "-smp", "2"]),
    # Half a line typed, then hello's lines while it's being typed, which go above it whole (decisions/0147), then the
    # rest: the line's written as typed and answered
    ("keeps the line being typed below what's written meanwhile", 7, [WITH_PROGRAMS,
        "--command-line=test_exit test_services test_settle=4", "--console-input=half typed, \\wand finished",
        "--console-input-after=hello: heap and random numbers working",
        "--expect-console-line=hello: heap and random numbers working", "--expect-console-line=half typed, and finished",
        "--expect-console-line=echo: half typed, and finished", "--expect-line=[user] echo: read half typed, and finished",
        "--expect-line=[info] root task ended with code 0", "--", "-smp", "2"]),
    # Ctrl+Alt+Delete as a terminal sends it: the terminal service's own screen, which Enter leaves, the program's lines
    # drawn again, and what's typed after it the program's
    ("brings up the secure attention key's screen, and goes back to the program", 7, [WITH_PROGRAMS,
        "--command-line=test_exit test_services test_settle=5", "--console-input=\e[3;7~\p\r\pafter attention",
        "--expect-line=[user] terminal: secure attention", "--expect-line=[user] terminal: secure attention ended",
        "--expect-console-line=  Secure attention", "--expect-console-line=echo: after attention",
        "--expect-line=[info] root task ended with code 0", "--", "-smp", "2"]),
    # The secure attention key's screen lists the console's programs, each pinged on its lifecycle channel; E ends the
    # one chosen, echo, which stops when its runtime tells it it's asked to, and isn't started again
    ("ends a program from the secure attention key's screen, which asks it to stop", 7, [WITH_PROGRAMS,
        "--command-line=test_exit test_services test_settle=6", "--console-input=\e[3;7~\pe\p\e",
        "--expect-line=[user] sessions: ending echo on the trusted path's request", "--expect-line=[user] echo: stopping, as asked",
        "--expect-line=[user] sessions: echo ended", "--expect-console-line=  Programs on the console:",
        "--expect-line=[user] terminal: secure attention ended", "--expect-line=[info] root task ended with code 0", "--", "-smp", "2"]),
    # A virtio keyboard boot.py types on through QEMU's machine protocol: keys as HID usages, typed by the terminal service's keymap
    ("types on a virtio keyboard into the console", 7, [WITH_PROGRAMS,
        "--command-line=test_exit test_services test_settle=4", "--keyboard-input=Hi there, 42!",
        "--expect-line=[user] virtio_input: serving", "--expect-line=[user] echo: read Hi there, 42!",
        "--expect-console-line=echo: Hi there, 42!", "--expect-line=[info] root task ended with code 0", "--", "-smp", "2"]),
    # A keyboard that's new: what's typed on it before its code goes nowhere, the code on the status line typed on it
    # accepts it, and what's typed after reaches the program; Ctrl+Alt+Delete on it is the secure attention key
    ("accepts a new keyboard once the code on the console is typed on it", 7, [WITH_PROGRAMS,
        "--command-line=test_exit test_services test_new_keyboards test_settle=5", "--keyboard-input=before the code",
        "--keyboard-input=\code", "--keyboard-input=after the code",
        "--expect-line=[user] input: keyboard 0 is new: its code is on the console", "--expect-line=[user] input: keyboard 0 accepted",
        "--expect-console-line=echo: after the code", "--refuse-console-line=echo: before the code",
        "--expect-line=[info] root task ended with code 0", "--", "-smp", "2"]),
    # The framebuffer: the kernel gives it up once the platform service gives it out, and the terminal service draws the
    # console there, the status line and what's typed, as on the serial line
    ("draws the console on the framebuffer too", 7, [WITH_PROGRAMS,
        "--command-line=test_exit test_services test_settle=8", "--keyboard-input=on the screen", "--screen-after=echo: on the screen",
        "--expect-line=[info] the framebuffer is user space's now: the log stays on the serial console",
        "--expect-console-line=echo: on the screen", "--expect-line=[info] root task ended with code 0", "--", "-smp", "2"]),
    # The console's driver killed once the console has dialed it: restarted with its device reissued, and dialed again by the terminal service
    ("restarts a driver that's killed, and its client dials it again", 7, [WITH_PROGRAMS,
        "--command-line=test_exit test_services test_restart test_settle=4", "--console-input=before the restart",
        "--console-input=after the restart", "--expect-line=[user] supervisor: test_restart: killing virtio_console",
        "--expect-line=[user] supervisor: restarted virtio_console", "--expect-line=[user] terminal: its serial line went; dialing again",
        "--expect-line=[user] echo: read after the restart", "--expect-console-line=echo: after the restart",
        "--expect-line=[info] root task ended with code 0", "--", "-smp", "2"]),
    # A GPT disk image boot.py marks, whose partitions the storage manager's partition server finds; the disk check reads,
    # writes, flushes and reads back its partition, is refused a block past it, and the image holds what it wrote after;
    # then, through std's files, it reads, writes, moves and lists files on the EFI system partition boot.py wrote with
    # FAT32, through a FAT server the storage manager starts
    ("reads and writes a virtio disk through the block protocol", 7, [WITH_PROGRAMS,
        "--command-line=test_exit test_services", "--disk=SlopOS disk check: from the host",
        "--expect-line=[user] virtio_blk: serving 77824 blocks",
        "--expect-line=[user] partition_server: 3 partitions on a disk of 77824 blocks",
        "--expect-line=[user] storage_manager: disk 0 partition 0: SlopOS check, 2048 blocks from 2048",
        "--expect-line=[user] storage_manager: disk 0 partition 1: SlopOS spare, 2048 blocks from 4096",
        "--expect-line=[user] storage_manager: disk 0 partition 2: EFI system partition, 69632 blocks from 6144",
        "--expect-line=[user] storage_manager: started a FAT server for disk 0 partition 2",
        "--expect-line=[user] fat_server: serving a FAT32 volume of 68512 clusters of 512 bytes",
        f"--expect-line={tests_passed('disk_check', 13, 9)}",
        "--expect-disk-block=2049=SlopOS disk check: from the guest", "--expect-disk-text=Written by the guest, through std's files",
        "--expect-line=[info] root task ended with code 0", "--", "-smp", "2"]),
    # Booted from a disk the image builder made rather than the ISO: the bootloader read from its EFI system partition,
    # loading only the boot set; the storage stack finding its partitions and its SlopOS
    # container, every other program read from the system volume, and the disk check passing on it as on the test disk
    ("boots from a disk the image builder made", 7, BOOT_DISK_ARGUMENTS),
    # Behind a root port, with firmware's bus numbers and BARs taken as unset
    ("numbers buses and places BARs behind a bridge", 7, [WITH_PROGRAMS,
        "--command-line=test_exit test_services test_reassign", "--expect-line=[user] platform: 1:0.0 (6900 4164) claimed",
        f"--expect-line={X86_WINDOWS_LINE}",
        "--expect-line=[user] virtio_rng: serving, a source of the entropy service's",
        "--expect-line=[user] entropy: reseeded from a hardware source, 32 bytes", "--expect-line=[info] root task ended with code 0",
        "--", "-smp", "2", "-device", "pcie-root-port,id=bridge,chassis=1,slot=1", "-device", "virtio-rng-pci,bus=bridge,disable-legacy=on,iommu_platform=on"]),
    ("keeps a program running after the process manager ends", 7, [WITH_PROGRAMS,
        "--command-line=test_exit test_outlive_manager", "--expect-line=[user] root task: killing process_manager",
        "--expect-line=[user] root task: process_manager was killed",
        "--expect-line=[user] hello: still running after the process manager ended",
        "--expect-line=[user] root task: the supervisor's hello ended with 0", "--expect-line=[info] root task ended with code 0"]),
    # The root task's own services killed in turn once everything's started (decisions/0140): each started again, answering
    # through a connector, and the supervisor and the storage manager dialing their connections again
    ("starts the root task's services again when they end, and their clients dial them again", 7, with_before_qemu(
        [argument.replace("test_services", "test_services test_restart_root_services") for argument in BOOT_DISK_BASE], [
        "--expect-line=[user] root task: test_restart_root_services: killing entropy",
        "--expect-line=[user] root task: started entropy again",
        "--expect-line=[user] root task: test_restart_root_services: entropy answers again",
        "--expect-line=[user] root task: started process_manager again",
        "--expect-line=[user] supervisor: dialed the process manager again",
        "--expect-line=[user] storage_manager: dialed the process manager again",
        "--expect-line=[user] root task: test_restart_root_services: process_manager answers again",
        "--expect-line=[user] root task: started scheduler again", "--expect-line=[user] supervisor: dialed the scheduler service again",
        "--expect-line=[user] root task: test_restart_root_services: scheduler answers again",
        "--expect-line=[user] root task: started platform again", "--expect-line=[user] supervisor: dialed the platform service again",
        "--expect-line=[user] root task: test_restart_root_services: platform answers again",
        "--expect-line=[user] root task: test_restart_root_services: all four started again",
        "--expect-line=[info] root task ended with code 0"])),
    ("keeps the time with the real-time clock, and sets it", 7, [WITH_PROGRAMS,
        "--command-line=test_exit test_services test_clock", f"--expect-line={X86_CLOCK_LINE}",
        "--expect-line=[user] clock: serving",
        "--expect-line=[user] clock: set to 2030-01-02 03:04:05 UTC, and the real-time clock reads it back",
        "--expect-line=[user] hello: the wall clock says it's 2030-01-02", "--expect-line=[info] root task ended with code 0"]),
    # First-boot setup on the trusted path (decisions/0148): a name that can't be an account's and a common password
    # refused, the administrator made, and the recovery code shown once, until Enter. Then the login screen (0150): F2
    # changes the layout, a wrong password is refused, and the right one makes the session, whose echo has the home
    ("sets up the administrator's account at first boot, then logs in to a session with its home", 7,
     with_before_qemu([argument.replace("test_services", "test_services use_echo test_settle=30") for argument in BOOT_DISK_BASE], ["--shut-down-when-done", 
        "--console-input=\\wAdmin\\radmin\\rpassword\\rcorrect horse battery staple\\rcorrect horse battery staple\\r\\w\\r"
        "\\w\\eOQadmin\\rnot the password\\r\\wadmin\\rcorrect horse battery staple\\r\\wfrom the session",
        "--console-input-after=  First-boot setup", "--console-input-after=  Press Enter once you have.",
        "--console-input-after=  Log in",
        "--console-input-after=  That name and password don't open an account. Type them again.",
        "--console-input-after=Your home directory has 1 entry.",
        "--expect-line=[user] terminal: first-boot setup: no accounts yet",
        "--expect-console-line=  A name is 1 to 32 letters, digits, - or _, and starts with a lowercase letter.",
        "--expect-console-line=  That password is one of the most common ones. Choose another.",
        "--expect-line=[user] account_service: made the account admin, the administrator",
        "--expect-line=[user] terminal: first-boot setup: made the administrator's account",
        "--expect-console-line=  The administrator's account is made. Its recovery code, shown this once:",
        "--expect-line=[user] terminal: first-boot setup ended",
        "--expect-line=[user] terminal: login: the uk keyboard layout",
        "--expect-line=[user] input: typing through the uk layout",
        "--expect-line=[user] terminal: logged in as admin",
        "--expect-line=[user] sessions: a session for admin, in en-GB",
        "--expect-line=[user] echo: home has 1 entry",
        "--expect-line=[user] echo: its locale is en-GB",
        "--expect-console-line=Numbers here look like 1,234,567.89, and dates like 31/12/2026.",
        "--expect-line=[user] echo: read from the session",
        "--expect-console-line=echo: from the session",
        "--refuse-console-line=correct horse battery staple", "--refuse-console-line=not the password"])),
    # Several sessions (decisions/0151): the administrator's, then another of theirs logged in from the secure attention
    # key's screen (N), the first switched back to (S), the console locked (L) and unlocked with the password, and the
    # first logged out (O), which leaves the second shown
    ("keeps several sessions, switches between them, locks the console, and logs one out", 7,
     with_before_qemu([argument.replace("test_services", "test_services use_echo test_settle=45") for argument in BOOT_DISK_BASE], ["--shut-down-when-done", 
        "--console-input=\\wAdmin\\radmin\\rcorrect horse battery staple\\rcorrect horse battery staple\\r\\w\\r\\wadmin\\rcorrect horse battery staple\\r\\wfirst line\\r\\w\\e[3;7~\\pn\\wadmin\\rcorrect horse battery staple\\r\\wsecond line\\r\\w\\e[3;7~\\ps\\pthird line\\r\\w\\e[3;7~\\pl\\wcorrect horse battery staple\\r\\wfourth line\\r\\w\\e[3;7~\\po\\p\\pfifth line",
        "--console-input-after=  First-boot setup", "--console-input-after=  Press Enter once you have.",
        "--console-input-after=  Log in", "--console-input-after=Your home directory has 1 entry.",
        "--console-input-after=echo: first line", "--console-input-after=  Log in",
        "--console-input-after=Your home directory has 1 entry.", "--console-input-after=echo: second line",
        "--console-input-after=echo: third line", "--console-input-after=  Locked",
        # The session drawn again once it's unlocked
        "--console-input-after=echo: third line", "--console-input-after=echo: fourth line",
        "--expect-line=[user] terminal: login: another session",
        # The first login keeps the locale its layout suggests as the user's setting, which the second reads
        "--expect-line=[user] sessions: a session for admin, in en-US",
        "--expect-line=[user] terminal: switched to admin's session",
        "--expect-line=[user] terminal: locked", "--expect-line=[user] terminal: unlocked",
        "--expect-line=[user] sessions: ending session 0", "--expect-line=[user] terminal: logged out",
        "--expect-line=[user] echo: read first line", "--expect-line=[user] echo: read second line",
        "--expect-line=[user] echo: read third line", "--expect-line=[user] echo: read fourth line",
        "--expect-line=[user] echo: read fifth line",
        "--expect-console-line=echo: fifth line",
        "--refuse-console-line=correct horse battery staple"])),
    # The powerbox (decisions/0156): echo asks it for a file to save a line in, the secure attention key opens the
    # chooser, which offers the name echo suggested as a new file; then for a file to read, narrowed by typing; then for
    # a directory, the home chosen; and once more, refused
    ("asks the user for files and directories through the powerbox's chooser on the trusted path", 7,
     with_before_qemu([argument.replace("test_services", "test_services use_echo test_settle=90").replace("--timeout=120", "--timeout=180")
                       for argument in BOOT_DISK_BASE], ["--shut-down-when-done", 
        "--console-input=\\wAdmin\\radmin\\rcorrect horse battery staple\\rcorrect horse battery staple\\r\\w\\r\\wadmin\\rcorrect horse battery staple\\r"
        "\\wsave hello from the powerbox\\r\\w\\p\\e[3;7~\\w\\r"
        "\\wopen\\r\\w\\p\\e[3;7~\\wnotes\\r"
        "\\wlist\\r\\w\\p\\e[3;7~\\w\\r"
        "\\wopen\\r\\w\\p\\e[3;7~\\w\\e\\p",
        "--console-input-after=  First-boot setup", "--console-input-after=  Press Enter once you have.",
        "--console-input-after=  Log in", "--console-input-after=Your home directory has 1 entry.",
        "--console-input-after=Asked the powerbox; Ctrl+Alt+Delete shows what it asks.", "--console-input-after=  Choose a file",
        "--console-input-after=Saved.",
        "--console-input-after=Asked the powerbox; Ctrl+Alt+Delete shows what it asks.", "--console-input-after=  Choose a file",
        "--console-input-after=It says: hello from the powerbox",
        "--console-input-after=Asked the powerbox; Ctrl+Alt+Delete shows what it asks.", "--console-input-after=  Choose a directory",
        "--console-input-after=It has 2 entries: apps, notes.txt",
        "--console-input-after=Asked the powerbox; Ctrl+Alt+Delete shows what it asks.", "--console-input-after=  Choose a file",
        "--expect-line=[user] powerbox: echo asks for a file to write",
        "--expect-line=[user] terminal: chose notes.txt for echo",
        "--expect-line=[user] powerbox: gave echo notes.txt",
        "--expect-line=[user] echo: saved a line in a file the powerbox gave",
        "--expect-line=[user] powerbox: echo asks for a file to read",
        "--expect-line=[user] echo: read a file the powerbox gave",
        "--expect-line=[user] powerbox: echo asks for a directory to read",
        "--expect-line=[user] echo: listed a directory the powerbox gave",
        "--expect-line=[user] terminal: refused echo",
        "--expect-line=[user] echo: the powerbox gave nothing",
        "--expect-console-line=The powerbox gave nothing."])),
    # Kept grants (decisions/0158): echo's save asks to keep its file, which the user ticks (Tab) in the chooser; reopen
    # opens it again without asking; the grants view (G on the secure attention key's screen) revokes it, and reopen then
    # gets nothing
    ("keeps a grant the user ticks, reopens it, and revokes it from the grants view", 7,
     with_before_qemu([argument.replace("test_services", "test_services use_echo test_settle=90").replace("--timeout=120", "--timeout=180")
                       for argument in BOOT_DISK_BASE], ["--shut-down-when-done", 
        "--console-input=\\wAdmin\\radmin\\rcorrect horse battery staple\\rcorrect horse battery staple\\r\\w\\r\\wadmin\\rcorrect horse battery staple\\r"
        "\\wsave kept line\\r\\w\\p\\e[3;7~\\w\\t\\r"
        "\\wreopen\\r"
        "\\w\\p\\e[3;7~\\w\\pg\\w\\p\\e[3~\\w\\p\\e\\p\\e\\preopen",
        "--console-input-after=  First-boot setup", "--console-input-after=  Press Enter once you have.",
        "--console-input-after=  Log in", "--console-input-after=Your home directory has 1 entry.",
        "--console-input-after=Asked the powerbox; Ctrl+Alt+Delete shows what it asks.", "--console-input-after=  Choose a file",
        "--console-input-after=Saved.", "--console-input-after=It says: kept line",
        "--console-input-after=  Secure attention", "--console-input-after=  What programs may keep",
        "--console-input-after=  Nothing is kept.",
        "--expect-line=[user] powerbox: kept notes.txt for echo",
        "--expect-line=[user] powerbox: reopened notes for echo",
        "--expect-line=[user] terminal: revoked a kept grant of notes.txt",
        "--expect-line=[user] powerbox: couldn't reopen notes for echo",
        "--expect-console-line=The powerbox gave nothing."])),
    # Elevation (decisions/0158): echo asks the powerbox for another account; the secure attention key opens the
    # elevation screen, which refuses a wrong administrator's password, then makes bob's account with the right one, its
    # recovery code shown once; logged out, bob logs in
    ("makes another account when the administrator allows it on the trusted path, and its user logs in", 7,
     with_before_qemu([argument.replace("test_services", "test_services use_echo test_settle=150").replace("--timeout=120", "--timeout=240")
                       for argument in BOOT_DISK_BASE], ["--shut-down-when-done", 
        "--console-input=\\wAdmin\\radmin\\rcorrect horse battery staple\\rcorrect horse battery staple\\r\\w\\r\\wadmin\\rcorrect horse battery staple\\r"
        "\\wadduser\\r\\w\\p\\e[3;7~"
        "\\wadmin\\rnot the password\\rbob\\ranother good passphrase\\ranother good passphrase\\r"
        "\\wadmin\\rcorrect horse battery staple\\rbob\\ranother good passphrase\\ranother good passphrase\\r"
        "\\w\\r"
        "\\w\\p\\e[3;7~\\po"
        "\\wbob\\ranother good passphrase",
        "--console-input-after=  First-boot setup", "--console-input-after=  Press Enter once you have.",
        "--console-input-after=  Log in", "--console-input-after=Your home directory has 1 entry.",
        "--console-input-after=Asked the powerbox; Ctrl+Alt+Delete shows what it asks.", "--console-input-after=  Make an account",
        "--console-input-after=  That's not the administrator's name and password. Type them again.",
        "--console-input-after=  Press Enter once you have.", "--console-input-after=Made the account bob.",
        "--console-input-after=  Log in",
        "--expect-line=[user] powerbox: echo asks for a new account",
        "--expect-line=[user] terminal: elevation: echo asks for an account",
        "--expect-line=[user] account_service: made the account bob, as the administrator allowed",
        "--expect-line=[user] terminal: elevation: made the account bob",
        "--expect-line=[user] powerbox: made the account bob for echo",
        "--expect-line=[user] echo: the powerbox made an account",
        "--expect-line=[user] terminal: logged in as bob",
        "--expect-line=[user] sessions: a session for bob, in en-US",
        "--refuse-console-line=correct horse battery staple", "--refuse-console-line=another good passphrase",
        "--refuse-console-line=not the password"])),
    # The hardware watchdog (decisions/0182, P5): QEMU's i6300esb, armed for 4 seconds once the supervisor's start is
    # done, and reset while the services answer, through 20 seconds of settling, so the run ends as it would without
    # it; and with test_watchdog_hang not reset, so it resets the machine, which QEMU, without --allow-reboot, takes as
    # its end, without an exit code
    ("keeps a hardware watchdog from resetting the machine while the services answer", 7,
     with_before_qemu([argument.replace("test_services", "test_services watchdog=4 test_settle=20").replace("--timeout=120", "--timeout=180")
                       for argument in BOOT_DISK_BASE], [
        "--expect-line=[user] i6300esb: armed, 4 seconds", "--expect-line=[user] supervisor: the watchdog's armed, 4 seconds"])
     + ["-device", "i6300esb"]),
    ("lets the hardware watchdog reset a machine whose supervisor stops resetting it", 125,
     with_before_qemu([argument.replace("test_services", "test_services watchdog=4 test_watchdog_hang test_settle=60")
                       .replace("--timeout=120", "--timeout=180") for argument in BOOT_DISK_BASE
                       if not argument.startswith("--expect-line=") or argument == HEALTHY_LINE], [
        "--expect-line=[user] i6300esb: armed, 4 seconds",
        "--expect-line=[user] supervisor: test_watchdog_hang: the watchdog isn't reset"])
     + ["-device", "i6300esb"]),
    # Shutting down from the shell (decisions/0182, P4): shut-down asks the session's powerbox, the secure attention key
    # brings up the administrator's name and password on the trusted path, a wrong password is refused, and the right
    # one has the system shut down, gracefully, and the machine turned off; no password shows on the console
    ("shuts down from the shell once the administrator allows it on the trusted path", 125,
     with_before_qemu([argument.replace("test_services", "test_services test_power test_settle=90").replace("--timeout=120", "--timeout=180")
                       for argument in BOOT_DISK_BASE], [
        "--console-input=\\wAdmin\\radmin\\rcorrect horse battery staple\\rcorrect horse battery staple\\r\\w\\r\\wadmin\\rcorrect horse battery staple\\r"
        "\\wshut-down\\r\\w\\p\\e[3;7~"
        "\\wadmin\\rnot the password\\r"
        "\\wadmin\\rcorrect horse battery staple\\r",
        "--console-input-after=  First-boot setup", "--console-input-after=  Press Enter once you have.",
        "--console-input-after=  Log in", "--console-input-after=SlopOS shell",
        "--console-input-after=Press Ctrl+Alt+Delete: an administrator's name and password allow it.",
        "--console-input-after=  Shut the system down",
        "--console-input-after=  That's not the administrator's name and password. Type them again.",
        "--expect-line=[user] powerbox: shell asks for a shutdown",
        "--expect-line=[user] terminal: elevation: shell asks to shut down",
        "--expect-line=[user] terminal: elevation: the administrator allowed a shutdown",
        "--expect-line=[user] supervisor: the console asked to shut down",
        "--expect-line=[user] root task: shutting down, as the console asked", "--expect-line=[info] turning the machine off",
        "--refuse-console-line=correct horse battery staple", "--refuse-console-line=not the password"])),
    # Shared volumes (decisions/0158): the administrator has bob's account made, then shares a volume, team, with bob
    # from the secure attention key's screen (H), which links shared/team in their home; bob, logged in to another
    # session, finds it in theirs; back in the administrator's, bob is taken out, every link into team revoked, and
    # team given a new volume key (decisions/0181's F5), sealed again with it in the background, and its old key
    # generation deleted, no snapshot of it needing it
    ("shares a volume with another user, who finds it at login, and takes them out of it", 7,
     with_before_qemu([argument.replace("test_services", "test_services use_echo test_settle=180").replace("--timeout=120", "--timeout=270")
                       for argument in BOOT_DISK_BASE], ["--shut-down-when-done", 
        "--console-input=\\wAdmin\\radmin\\rcorrect horse battery staple\\rcorrect horse battery staple\\r\\w\\r\\wadmin\\rcorrect horse battery staple\\r"
        "\\wadduser\\r\\w\\p\\e[3;7~"
        "\\wadmin\\rcorrect horse battery staple\\rbob\\ranother good passphrase\\ranother good passphrase\\r"
        "\\w\\r"
        "\\w\\p\\e[3;7~\\ph"
        "\\wteam\\rbob\\r\\p\\p\\e[3;7~\\pn"
        "\\wbob\\ranother good passphrase\\r"
        "\\w\\p\\e[3;7~\\ps\\p\\e[3;7~\\ph"
        "\\wteam\\rbob\\e[3~\\p",
        "--console-input-after=  First-boot setup", "--console-input-after=  Press Enter once you have.",
        "--console-input-after=  Log in", "--console-input-after=Your home directory has 1 entry.",
        "--console-input-after=Asked the powerbox; Ctrl+Alt+Delete shows what it asks.", "--console-input-after=  Make an account",
        "--console-input-after=  Press Enter once you have.", "--console-input-after=Made the account bob.",
        "--console-input-after=  Share a volume", "--console-input-after=  Log in",
        "--console-input-after=Your home directory has 2 entries.", "--console-input-after=  Share a volume",
        "--expect-line=[user] account_service: made the shared volume team, admin's",
        "--expect-line=[user] account_service: shared team with bob",
        "--expect-line=[user] terminal: shared team, linked shared/team in the owner's home",
        "--expect-line=[user] account_service: bob joined team",
        "--expect-line=[user] account_service: took bob out of team, revoked 2 links into it, and gave it a new volume key, sealing with key generation 2",
        "--expect-line=[user] volume_server: volume 6 sealed again with key generation 2",
        "--expect-line=[user] volume_server: volume 6 deleted its key generations before 2",
        "--expect-line=[user] terminal: took a member out of team, linked shared/team in the owner's home",
        "--refuse-console-line=correct horse battery staple", "--refuse-console-line=another good passphrase"])),
    # The shell's language (decisions/0169), the session's first program: let, sizes and their
    # arithmetic, a string with a variable in it, lists, records, and errors that say where they are
    ("evaluates the shell language: values, names, lists, records and errors", 7,
     with_before_qemu([argument.replace("test_services", "test_services test_settle=60").replace("--timeout=120", "--timeout=180")
                       for argument in BOOT_DISK_BASE], ["--shut-down-when-done", 
        "--console-input=\\wAdmin\\radmin\\rcorrect horse battery staple\\rcorrect horse battery staple\\r\\w\\r\\wadmin\\rcorrect horse battery staple\\r"
        "\\wlet x = 4MiB + 512KiB\\r\\p$x\\r\\pprint \"size: $x\"\\r\\p[1, 2, 3][1] * 10\\r\\p{name: \"a\", n: 3}.n\\r\\p"
        "nope --now\\r\\p1 + \\r\\p250ms * 4 == 1s\\r\\p9223372036854775807 + 1\\r\\plet file-name = \"notes\"; print \"$file-name.txt\"",
        "--console-input-after=  First-boot setup", "--console-input-after=  Press Enter once you have.",
        "--console-input-after=  Log in", "--console-input-after=SlopOS shell",
        "--expect-line=[user] shell: reading commands",
        "--expect-console-line=4.5 MiB", "--expect-console-line=size: 4.5 MiB", "--expect-console-line=20",
        "--expect-console-line=3", "--expect-console-line=error: there's no command named nope",
        "--expect-console-line=error: something's missing at the end", "--expect-console-line=true",
        "--expect-console-line=error: that's too big: past what a 64-bit number holds", "--expect-console-line=notes.txt"])),
    # Restarting from the secure attention key's screen (decisions/0182): R, the supervisor told, the root task asks
    # the kernel to reset the machine once it ends, which with test_power it does, rather than exiting QEMU; QEMU,
    # without --allow-reboot, ends at the reset without an exit code
    ("restarts the machine when the console asks", 125,
     with_before_qemu([argument.replace("test_services", "test_services test_power test_settle=60").replace("--timeout=120", "--timeout=180")
                       for argument in BOOT_DISK_BASE], ["--restart-when-done",
        "--console-input=\\wAdmin\\radmin\\rcorrect horse battery staple\\rcorrect horse battery staple\\r\\w\\r\\wadmin\\rcorrect horse battery staple\\r",
        "--console-input-after=  First-boot setup", "--console-input-after=  Press Enter once you have.",
        "--console-input-after=  Log in", "--expect-console-line=SlopOS shell",
        "--expect-line=[user] supervisor: the console asked to restart",
        "--expect-line=[user] root task: restarting, as the console asked", "--expect-line=[info] restarting the machine"])),
    # Turning the machine off when the console shuts it down (decisions/0182): by PSCI's SYSTEM_OFF on AArch64, and on
    # x86-64 by S5's sleep types, which the ACPI service read from \_S5 for the kernel (P3); either ends QEMU without an
    # exit code, where a machine that only halted would time out
    ("turns the machine off when the console shuts it down", 125,
     with_before_qemu([argument.replace("test_services", "test_services test_power test_settle=60").replace("--timeout=120", "--timeout=180")
                       for argument in BOOT_DISK_BASE], ["--shut-down-when-done",
        "--console-input=\\wAdmin\\radmin\\rcorrect horse battery staple\\rcorrect horse battery staple\\r\\w\\r\\wadmin\\rcorrect horse battery staple\\r",
        "--console-input-after=  First-boot setup", "--console-input-after=  Press Enter once you have.",
        "--console-input-after=  Log in", "--expect-console-line=SlopOS shell",
        "--expect-line=[user] supervisor: the console asked to shut down",
        "--expect-line=[user] root task: shutting down, as the console asked", "--expect-line=[info] turning the machine off"])),
    # The power button (decisions/0182, P3): pressed through QEMU once the system's healthy, it reaches the supervisor
    # through the ACPI service's SCI on x86-64 or the PL061's driver on AArch64, and shuts the system down, turning the
    # machine off; which ends QEMU without an exit code. The shutdown is graceful (P4): every service asked to stop, the
    # last started first, but the update service, which test_ignore_stop has the supervisor not ask, as if it didn't
    # listen, so it's killed and named
    ("shuts down and turns off when the power button's pressed", 125,
     with_before_qemu([argument.replace("test_services", "test_services test_power test_ignore_stop=update test_settle=60")
                       .replace("--timeout=120", "--timeout=180") for argument in BOOT_DISK_BASE],
                      [f"--power-button-after={HEALTHY_LINE.removeprefix('--expect-line=')}",
        "--expect-line=[user] supervisor: the power button was pressed",
        "--expect-line=[user] supervisor: killed update, which didn't stop when asked",
        "--expect-line=[user] root task: shutting down, as the console asked", "--expect-line=[info] turning the machine off"])),
    # Calls through manifests (decisions/0170): test_shell_calls given values by position and by --name, a bool alone, an
    # enum's member, a duration, a list, a directory beneath the home and the terminal unasked; then its exit code as an
    # error, and errors found before anything starts: a value missing, a word that isn't a number, a member that isn't
    # one, and a grant the shell can't make
    ("calls programs through their manifests: arguments, values, grants and errors", 7,
     with_before_qemu([argument.replace("test_services", "test_services test_settle=60").replace("--timeout=120", "--timeout=180")
                       for argument in BOOT_DISK_BASE], ["--shut-down-when-done", 
        "--console-input=\\wAdmin\\radmin\\rcorrect horse battery staple\\rcorrect horse battery staple\\r\\w\\r\\wadmin\\rcorrect horse battery staple\\r"
        "\\wtest_shell_calls 3 hello --loud --speed Fast --wait 250ms\\r\\p\\p"
        "test_shell_calls --label \"two words\" --count 7 --tags [\"a\", \"b\"] --place ~\\r\\p\\p"
        "test_shell_calls 5 fail\\r\\p\\p"
        "test_shell_calls 3\\r\\ptest_shell_calls x y\\r\\ptest_shell_calls 1 a --speed Medium\\r\\ptest_values",
        "--console-input-after=  First-boot setup", "--console-input-after=  Press Enter once you have.",
        "--console-input-after=  Log in", "--console-input-after=SlopOS shell",
        "--expect-line=[user] shell: reading commands",
        "--expect-console-line=called with hello, 3, loud true, speed Fast, wait 250ms, tags none, place none",
        "--expect-console-line=called with two words, 7, loud false, speed none, wait none, tags a+b, place a directory",
        "--expect-console-line=called with fail, 5, loud false, speed none, wait none, tags none, place none",
        "--expect-console-line=error: test_shell_calls ended with 5",
        "--expect-console-line=error: test_shell_calls needs its label (string)",
        "--expect-console-line=error: --count: x isn't a number",
        "--expect-console-line=error: --speed: Medium isn't one of Slow or Fast",
        "--expect-console-line=error: test_values needs a log, which the shell can't give"])),
    # Crash reports (decisions/0183, 12a): a program the shell started traps, so the shell's intercept of its faults
    # reports it, logs the report, and ends it; crashes shows the report, its frames named, and the shell goes on
    ("reports a program's crash from the shell, and shows it with crashes", 7,
     with_before_qemu([argument.replace("test_services", "test_services test_settle=60").replace("--timeout=120", "--timeout=180")
                       for argument in BOOT_DISK_BASE], ["--shut-down-when-done",
        "--console-input=\\wAdmin\\radmin\\rcorrect horse battery staple\\rcorrect horse battery staple\\r\\w\\r\\wadmin\\rcorrect horse battery staple\\r"
        "\\wtest_shell_calls 2 crash\\r\\p\\pcrashes\\r\\p\\ptest_shell_calls 3 after\\r",
        "--console-input-after=  First-boot setup", "--console-input-after=  Press Enter once you have.",
        "--console-input-after=  Log in", "--console-input-after=SlopOS shell",
        "--expect-line=[user] shell: reading commands",
        "--expect-console-line=called with crash, 2, loud false, speed none, wait none, tags none, place none",
        f"--expect-console-line={CRASH_LINE}",
        f"--expect-console-line={CRASH_REPORT_LINE}",
        # Its frames named by the symbols program: the trap in main, called from the entry Hemera made for it
        "--expect-console-start=  #0 test_shell_calls.main+0x", "--expect-console-start=  #1 hemera_entry+0x",
        "--expect-console-line=called with after, 3, loud false, speed none, wait none, tags none, place none"])),
    # The debugger (decisions/0183, 12b): debug runs a program stopped before it begins; a breakpoint on main, found
    # through the symbols program, stops it there; a step, its stack, and with the breakpoint deleted it runs to its end
    ("debugs a program from the shell: a breakpoint by function, a step and its stack", 7,
     with_before_qemu([argument.replace("test_services", "test_services test_settle=60").replace("--timeout=120", "--timeout=180")
                       for argument in BOOT_DISK_BASE], ["--shut-down-when-done",
        "--console-input=\\wAdmin\\radmin\\rcorrect horse battery staple\\rcorrect horse battery staple\\r\\w\\r\\wadmin\\rcorrect horse battery staple\\r"
        "\\wdebug test_shell_calls 2 debugged\\r\\p\\pbreak test_shell_calls.main\\r\\p\\pcontinue\\r\\p\\pstep\\r\\p\\pwhere\\r\\p\\p"
        "delete 1\\r\\p\\pcontinue\\r\\p\\ptest_shell_calls 3 after\\r",
        "--console-input-after=  First-boot setup", "--console-input-after=  Press Enter once you have.",
        "--console-input-after=  Log in", "--console-input-after=SlopOS shell",
        "--expect-line=[user] shell: reading commands",
        "--expect-console-line=test_shell_calls stopped before it began; break, watch, step, continue, where, registers, threads, "
        "print, quit",
        "--expect-console-line=breakpoint 1 at test_shell_calls.main",
        "--expect-console-line=stopped at test_shell_calls.main+0x0: breakpoint",
        "--expect-console-start=stopped at test_shell_calls.main+0x", "--expect-console-start=  #0 test_shell_calls.main+0x",
        "--expect-console-line=deleted 1",
        "--expect-console-line=called with debugged, 2, loud false, speed none, wait none, tags none, place none",
        "--expect-console-line=test_shell_calls ended with 0",
        "--expect-console-line=called with after, 3, loud false, speed none, wait none, tags none, place none"])),
    # The debugger with debug files (decisions/0185, 12e): a breakpoint by file and line in test_debug, its stack with
    # lines, and its locals shown as Hemera values through their schemas: a struct, an optional, a union and a view
    ("debugs a program by its lines, and shows its values through their types", 7,
     with_before_qemu([argument.replace("test_services", "test_services test_settle=60").replace("--timeout=120", "--timeout=180")
                       for argument in WITH_DEBUG_FILES], ["--shut-down-when-done", "--debug-files",
        "--console-input=\\wAdmin\\radmin\\rcorrect horse battery staple\\rcorrect horse battery staple\\r\\w\\r\\wadmin\\rcorrect horse battery staple\\r"
        f"\\wdebug test_debug\\r\\p\\pbreak test_debug.hsc:{TEST_DEBUG_BREAK_LINE}\\r\\p\\pcontinue\\r\\p\\pwhere\\r\\p\\p"
        "print point\\r\\p\\pprint maybe\\r\\p\\pprint shape\\r\\p\\pprint view\\r\\p\\pprint nothing\\r\\p\\p"
        "delete 1\\r\\p\\pcontinue\\r\\p\\ptest_debug 1\\r\\p\\pcrashes\\r\\p\\ptest_shell_calls 3 after\\r",
        "--console-input-after=  First-boot setup", "--console-input-after=  Press Enter once you have.",
        "--console-input-after=  Log in", "--console-input-after=SlopOS shell",
        "--expect-line=[user] shell: reading commands",
        f"--expect-console-line=breakpoint 1 at test_debug.hsc:{TEST_DEBUG_BREAK_LINE}",
        "--expect-console-start=stopped at test_debug.main+0x",
        "--expect-console-start=  #0 test_debug.main+0x", f"--expect-console-end=at test_debug.hsc:{TEST_DEBUG_BREAK_LINE}",
        "--expect-console-line=point = Point{x = 3, y = -4, label = \"corner\"}",
        "--expect-console-line=maybe = Some(7)",
        "--expect-console-line=shape = Box(2, 5)",
        "--expect-console-line=view = [10, 20, 30]",
        "--expect-console-line=there's no local named nothing here",
        "--expect-console-line=test_debug ended with 0",
        # A crash's report, its frame's line from the debug file: the write through a bad pointer
        f"--expect-console-end=at test_debug.hsc:{TEST_DEBUG_CRASH_LINE}",
        "--expect-console-line=called with after, 3, loud false, speed none, wait none, tags none, place none"])),
    # The debugger's reach (decisions/0185, 12f): a breakpoint set before test_debug starts its second thread is hit by
    # it, as a process's breakpoints are every thread's; the thread carries a fiber pool, whose fibers are listed, the
    # one waiting suspended with its stack
    ("debugs a program's other threads and lists its fibers", 7,
     with_before_qemu([argument.replace("test_services", "test_services test_settle=60").replace("--timeout=120", "--timeout=180")
                       for argument in WITH_DEBUG_FILES], ["--shut-down-when-done", "--debug-files",
        "--console-input=\\wAdmin\\radmin\\rcorrect horse battery staple\\rcorrect horse battery staple\\r\\w\\r\\wadmin\\rcorrect horse battery staple\\r"
        "\\wdebug test_debug 2\\r\\p\\pbreak test_debug.in_fiber\\r\\p\\pcontinue\\r\\p\\pthreads\\r\\p\\pfibers\\r\\p\\p"
        "delete 1\\r\\p\\pcontinue\\r\\p\\ptest_shell_calls 3 after\\r",
        "--console-input-after=  First-boot setup", "--console-input-after=  Press Enter once you have.",
        "--console-input-after=  Log in", "--console-input-after=SlopOS shell",
        "--expect-line=[user] shell: reading commands",
        "--expect-console-line=breakpoint 1 at test_debug.in_fiber",
        "--expect-console-line=stopped at test_debug.in_fiber+0x0: breakpoint",
        "--expect-console-contains=, stopped",
        "--expect-console-line=2 fibers",
        "--expect-console-contains=: running on this thread", "--expect-console-contains=: suspended",
        "--expect-console-contains=test_debug.wait_for_done+0x",
        "--expect-console-line=test_debug ended with 0",
        "--expect-console-line=called with after, 3, loud false, speed none, wait none, tags none, place none"])),
    # Attaching (decisions/0185, 12f): the debugger attached to counter, the system's installation, which the shell
    # didn't start: the powerbox asks, the secure attention key's screen shows it, Enter allows it; its threads are
    # suspended, listed and walked, and quit lets it go. Asked again, Escape refuses it
    ("attaches the debugger to a program the shell didn't start, as the user allows", 7,
     with_before_qemu([argument.replace("test_services", "test_services test_settle=60").replace("--timeout=120", "--timeout=180")
                       for argument in WITH_DEBUG_FILES], ["--shut-down-when-done", "--debug-files",
        "--console-input=\\wAdmin\\radmin\\rcorrect horse battery staple\\rcorrect horse battery staple\\r\\w\\r\\wadmin\\rcorrect horse battery staple\\r"
        "\\wdebug attach counter\\r\\p\\p\\e[3;7~\\p\\p\\r\\p\\p\\pthreads\\r\\p\\pwhere\\r\\p\\pquit\\r\\p\\p"
        "debug attach counter\\r\\p\\p\\e[3;7~\\p\\p\\e\\p\\p\\ptest_shell_calls 3 after\\r",
        "--console-input-after=  First-boot setup", "--console-input-after=  Press Enter once you have.",
        "--console-input-after=  Log in", "--console-input-after=SlopOS shell",
        "--expect-line=[user] shell: reading commands",
        "--expect-console-line=Press Ctrl+Alt+Delete to allow the shell to debug counter.",
        "--expect-line=[user] sessions: attached a debugger to counter",
        "--expect-console-start=attached to counter, its ",
        "--expect-console-contains=, stopped", "--expect-console-start=  #0 ",
        "--expect-console-line=let counter go",
        "--expect-console-line=error: debugging counter was refused, or it isn't running",
        "--expect-console-line=called with after, 3, loud false, speed none, wait none, tags none, place none"])),
    # Tracing the whole system (decisions/0185, 12g): trace asks the powerbox, the secure attention key brings up the
    # elevation screen, and the administrator's name and password give the shell a trace connection to the supervisor,
    # which traces for a second and says what each service did
    ("traces the whole system once an administrator allows it", 7,
     with_before_qemu([argument.replace("test_services", "test_services test_settle=60").replace("--timeout=120", "--timeout=180")
                       for argument in BOOT_DISK_BASE], ["--shut-down-when-done",
        "--console-input=\\wAdmin\\radmin\\rcorrect horse battery staple\\rcorrect horse battery staple\\r\\w\\r\\wadmin\\rcorrect horse battery staple\\r"
        "\\wtrace 1\\r\\w\\p\\e[3;7~"
        "\\wadmin\\rcorrect horse battery staple\\r\\p\\p\\p\\p\\ptest_shell_calls 3 after\\r",
        "--console-input-after=  First-boot setup", "--console-input-after=  Press Enter once you have.",
        "--console-input-after=  Log in", "--console-input-after=SlopOS shell",
        "--console-input-after=Press Ctrl+Alt+Delete: an administrator's name and password allow it.",
        "--console-input-after=  Trace the system",
        "--expect-line=[user] powerbox: shell asks for a trace",
        "--expect-line=[user] supervisor: a trace connection for an administrator",
        "--expect-line=[user] supervisor: tracing for 1000 ms",
        "--expect-console-line=tracing for 1 s", "--expect-console-contains= events in 1 s",
        "--expect-console-contains= switches, ",
        "--expect-console-line=called with after, 3, loud false, speed none, wait none, tags none, place none"])),
    # The system's crash reports (decisions/0185, 12g): test_crash crashes the update service, which the supervisor
    # reports in its source; crashes system, once the administrator allows reading the log, reads it back as a typed
    # record and names its frames through the update service's files
    ("shows the system's crash reports to an administrator", 7,
     with_before_qemu([argument.replace("test_services", "test_services test_crash test_settle=60").replace("--timeout=120", "--timeout=180")
                       for argument in WITH_DEBUG_FILES], ["--shut-down-when-done", "--debug-files",
        "--console-input=\\wAdmin\\radmin\\rcorrect horse battery staple\\rcorrect horse battery staple\\r\\w\\r\\wadmin\\rcorrect horse battery staple\\r"
        "\\wcrashes system\\r\\w\\p\\e[3;7~"
        "\\wadmin\\rcorrect horse battery staple\\r\\p\\p\\p\\p\\ptest_shell_calls 3 after\\r",
        "--console-input-after=  First-boot setup", "--console-input-after=  Press Enter once you have.",
        "--console-input-after=  Log in", "--console-input-after=SlopOS shell",
        "--console-input-after=Press Ctrl+Alt+Delete: an administrator's name and password allow it.",
        "--console-input-after=  Read the system's log",
        "--expect-line=[user] supervisor: update crashed: execute fault",
        "--expect-line=[user] supervisor: an events connection for an administrator",
        "--expect-console-start=update: execute fault", "--expect-console-start=  #0 ",
        "--expect-console-line=called with after, 3, loud false, speed none, wait none, tags none, place none"])),
    # Record and replay (decisions/0183, 12c): test_replay's threads, recorded one at a time, replayed exactly from
    # the recording with its seeds; and replayed with another count, which diverges, where it's said
    ("records a program of several threads and replays it exactly, and says where a changed one diverges", 7,
     with_before_qemu([argument.replace("test_services", "test_services test_settle=60").replace("--timeout=120", "--timeout=180")
                       for argument in BOOT_DISK_BASE], ["--shut-down-when-done",
        "--console-input=\\wAdmin\\radmin\\rcorrect horse battery staple\\rcorrect horse battery staple\\r\\w\\r\\wadmin\\rcorrect horse battery staple\\r"
        "\\wrecord test_replay 20\\r\\p\\p\\preplay test_replay 20\\r\\p\\p\\preplay test_replay 21\\r\\p\\p\\p"
        # A channel end passed and used, recorded to a file and replayed from it (decisions/0185, 12g)
        "record test_replay 5 1 to passed.recording\\r\\p\\p\\preplay from passed.recording\\r\\p\\p\\p"
        "replay from nothing.recording\\r\\p\\ptest_shell_calls 3 after\\r",
        "--console-input-after=  First-boot setup", "--console-input-after=  Press Enter once you have.",
        "--console-input-after=  Log in", "--console-input-after=SlopOS shell",
        "--expect-line=[user] shell: reading commands",
        "--expect-console-start=test_replay: 20 turns, total 0x",
        "--expect-console-start=test_replay was recorded: ",
        "--expect-console-start=test_replay was replayed exactly: ",
        "--expect-console-start=test_replay diverged after ",
        "--expect-console-line=kept in passed.recording", "--expect-console-start=test_replay: 5 turns, total 0x",
        "--expect-console-start=error: nothing.recording isn't a recording that reads: ",
        "--expect-console-line=called with after, 3, loud false, speed none, wait none, tags none, place none"])),
    # Profiling (decisions/0183, 12d): test_profile spins in spin_here, which a profile of it finds most of its samples in;
    # then on a fiber, whose samples are said by fiber (0185, 12h)
    ("profiles a program, its samples named by function and by fiber", 7,
     with_before_qemu([argument.replace("test_services", "test_services test_settle=60").replace("--timeout=120", "--timeout=180")
                       for argument in BOOT_DISK_BASE], ["--shut-down-when-done",
        "--console-input=\\wAdmin\\radmin\\rcorrect horse battery staple\\rcorrect horse battery staple\\r\\w\\r\\wadmin\\rcorrect horse battery staple\\r"
        "\\wprofile test_profile 500\\r\\p\\p\\p\\pprofile test_profile 500 1\\r\\p\\p\\p\\ptest_shell_calls 3 after\\r",
        "--console-input-after=  First-boot setup", "--console-input-after=  Press Enter once you have.",
        "--console-input-after=  Log in", "--console-input-after=SlopOS shell",
        "--expect-line=[user] shell: reading commands",
        "--expect-console-start=profile of test_profile: ", "--expect-console-start=  1. test_profile.spin_here: ",
        # On a fiber (decisions/0185, 12h): its samples said by fiber, through its thread's per-thread page
        "--expect-console-start=  1. test_profile.spin_on_fiber: ", "--expect-console-line=by fiber:",
        "--expect-console-contains=samples, most in test_profile.spin_on_fiber",
        "--expect-console-line=called with after, 3, loud false, speed none, wait none, tags none, place none"])),
    # Shell functions, errors and the shell's directory (decisions/0171): a function's parameters matched and read by
    # their types, try/catch with the error as a record, ? passing a function's error to its caller where one without
    # is fatal, return, and cd beneath the home
    ("runs shell functions, handles errors with try, or and ?, and changes directory", 7,
     with_before_qemu([argument.replace("test_services", "test_services test_settle=60").replace("--timeout=120", "--timeout=180")
                       for argument in BOOT_DISK_BASE], ["--shut-down-when-done", 
        "--console-input=\\wAdmin\\radmin\\rcorrect horse battery staple\\rcorrect horse battery staple\\r\\w\\r\\wadmin\\rcorrect horse battery staple\\r"
        "\\wfn twice(n: int) { $n * 2 }\\r\\ptwice 21\\r\\ptwice --n 5\\r\\ptwice x\\r\\p"
        "try { nope } catch e { print \"caught:\" $e.message }\\r\\p"
        "fn strict() { nope }\\r\\pfn lenient() { nope? }\\r\\plenient or { print \"handled\" }\\r\\pstrict or { print \"handled\" }\\r\\p"
        "fn pick(a, b) { return $b; print \"not here\" }\\r\\ppick 1 \"second\"\\r\\p"
        "cd apps\\r\\pcd ../..\\r\\pcd nowhere\\r\\pcd ..\\r\\pcd ..",
        "--console-input-after=  First-boot setup", "--console-input-after=  Press Enter once you have.",
        "--console-input-after=  Log in", "--console-input-after=SlopOS shell",
        "--expect-console-line=42", "--expect-console-line=10", "--expect-console-line=error: --n: x isn't an integer",
        "--expect-console-line=caught: there's no command named nope", "--expect-console-line=handled",
        "--expect-console-line=error: in strict: there's no command named nope", "--expect-console-line=second",
        "--refuse-console-line=not here",
        "--expect-console-line=error: ../..: that's above your home",
        "--expect-console-line=error: nowhere: there's nothing there",
        "--expect-console-line=error: ..: that's above your home"])),
    # Pipelines (decisions/0172): a program's records shown as a table, the built-in stages on them, two programs
    # connected straight, a list written into a program, and the errors found before anything starts
    ("runs pipelines: programs' records as tables, the built-in stages, and programs connected", 7,
     with_before_qemu([argument.replace("test_services", "test_services test_settle=60").replace("--timeout=120", "--timeout=180")
                       for argument in BOOT_DISK_BASE], ["--shut-down-when-done", 
        "--console-input=\\wAdmin\\radmin\\rcorrect horse battery staple\\rcorrect horse battery staple\\r\\w\\r\\wadmin\\rcorrect horse battery staple\\r"
        "\\wtest_shell_calls 3 row\\r\\p\\p"
        "test_shell_calls 4 r | where id > 2 | map name\\r\\p\\p"
        "test_shell_calls 2 a | test_shell_calls 0 b\\r\\p\\p"
        "[{id: 7, name: \"seven\", kind: \"Fast\"}] | test_shell_calls 0 x\\r\\p\\p"
        "test_shell_calls 4 s | sort id --descending | take 1 | map name\\r\\p\\p"
        "test_shell_calls 4 g | group kind | map kind\\r\\p\\p"
        "[{count: 5}, {count: 5}] | group count | map it.key * 10 + it.count\\r\\p\\p"
        "test_shell_calls 1 a | print\\r\\p\\p"
        "[1, 2] | test_shell_calls 0 x\\r\\p\\p"
        "where id > 1\\r\\p"
        "test_shell_calls 2 a | where name",
        "--console-input-after=  First-boot setup", "--console-input-after=  Press Enter once you have.",
        "--console-input-after=  Log in", "--console-input-after=SlopOS shell",
        "--expect-console-line=id  name  kind", "--expect-console-line=1   row1  Slow", "--expect-console-line=3   row3  Slow",
        "--expect-console-line=\"r3\"", "--expect-console-line=\"r4\"",
        "--expect-console-line=10  a1    Slow", "--expect-console-line=20  a2    Fast",
        "--expect-console-line=70  seven  Fast",
        "--expect-console-line=\"s4\"", "--refuse-console-line=\"s3\"",
        "--expect-console-line=\"Slow\"", "--expect-console-line=\"Fast\"", "--expect-console-line=52",
        "--expect-console-line=error: only a program or a stage takes what comes before it in a pipeline",
        "--expect-console-line=error: item 1 of what's given to test_shell_calls: it takes a record of Row's fields, not an integer",
        "--expect-console-line=error: where works on what comes before it in a pipeline",
        "--expect-console-line=error: where needs true or false, not a string"])),
    # Help and completion (decisions/0174): help alone lists the built-ins; help on a program shows its documentation,
    # from its bundle, and its parameters' types, from its manifest; Tab completes a program's name, its --name and an
    # enum's member, and lists the programs a prefix starts with, each with its summary
    ("helps with the built-ins and programs, and completes commands, parameters and members", 7,
     with_before_qemu([argument.replace("test_services", "test_services test_settle=60").replace("--timeout=120", "--timeout=180")
                       for argument in BOOT_DISK_BASE], ["--shut-down-when-done", 
        "--console-input=\\wAdmin\\radmin\\rcorrect horse battery staple\\rcorrect horse battery staple\\r\\w\\r\\wadmin\\rcorrect horse battery staple\\r"
        "\\whelp\\r\\phelp test_shell_calls\\r\\p\\p"
        "test_shell_c\\t\\p3 tabbed\\r\\p\\p"
        "test_shell_calls 2 named --spe\\t\\pFa\\t\\p\\r\\p\\p"
        "test_\\t\\p\\p\\r",
        "--console-input-after=  First-boot setup", "--console-input-after=  Press Enter once you have.",
        "--console-input-after=  Log in", "--console-input-after=SlopOS shell",
        "--expect-console-line=print   Write its arguments on a line, separated by spaces.",
        "--expect-console-line=test_shell_calls:  Write what the shell gave on one line of the terminal, or, in a pipeline, write rows.",
        "--expect-console-line=  --count (count)  A number, written on the line; with an output and no input, how many rows are made; "
        "with the label \"fail\", the exit code.",
        "--expect-console-line=  --session_terminal (the shell's terminal, given without asking)  A connection to the shell's terminal, "
        "which the line is written on. Without it, as in the background, no line is written.",
        "--expect-console-line=called with tabbed, 3, loud false, speed none, wait none, tags none, place none",
        "--expect-console-line=called with named, 2, loud false, speed Fast, wait none, tags none, place none",
        "--expect-console-line=test_shell_calls    Write what the shell gave on one line of the terminal, or, in a pipeline, write rows.",
        "--expect-console-line=test_shell_results  Give back what it's asked to: a summary of what it was given, or an error.",
        "--expect-console-line=error: there's no command named test_"])),
    # History (design/shell.md §6): a line entered in one session comes back with Up in the next, from the shell's data
    # directory in the user's home
    ("keeps the shell's history from one session to the next", 7,
     with_before_qemu([argument.replace("test_services", "test_services test_settle=60").replace("--timeout=120", "--timeout=180")
                       for argument in BOOT_DISK_BASE], ["--shut-down-when-done", 
        "--console-input=\\wAdmin\\radmin\\rcorrect horse battery staple\\rcorrect horse battery staple\\r\\w\\r\\wadmin\\rcorrect horse battery staple\\r"
        "\\wprint \"remembered\"\\r\\pexit\\r\\wadmin\\rcorrect horse battery staple\\r\\w\\e[A\\p\\e[A\\p \"again\"\\r\\pexit now\\r",
        "--console-input-after=  First-boot setup", "--console-input-after=  Press Enter once you have.",
        "--console-input-after=  Log in", "--console-input-after=SlopOS shell", "--console-input-after=  Log in",
        "--console-input-after=SlopOS shell",
        "--expect-console-line=remembered", "--expect-console-line=remembered again", "--expect-console-line=error: exit takes nothing"])),
    # Jobs (decisions/0174, 0176): a program run in the background with &, without the terminal, its records read as
    # it writes them, said to have ended at the prompt and finished with wait, which gives them; Ctrl-C stopping one in
    # the foreground over its lifecycle channel, behind what's typed ahead too, and killing a stubborn one after the
    # grace period; stop ending a job; and jobs listing them
    # A job on a CPU budget of its own, an eighth of its session's, which processes shows (decisions/0187)
    ("runs each job on a CPU budget of its own, which processes shows", 7,
     with_before_qemu([argument.replace("test_services", "test_services test_settle=120").replace("--timeout=120", "--timeout=240")
                       for argument in BOOT_DISK_BASE], ["--shut-down-when-done",
        "--console-input=\\wAdmin\\radmin\\rcorrect horse battery staple\\rcorrect horse battery staple\\r\\w\\r\\wadmin\\rcorrect horse battery staple\\r"
        "\\wtest_shell_calls 1 cj --sleep 20s &\\r\\p\\p\\pprocesses | map name\\r\\p\\pprocesses | map share\\r\\p\\pprocesses | map budget\\r\\p\\pprocesses\\r\\p\\p\\p\\p\\p\\p\\p\\p\\p\\p\\p\\p",
        "--console-input-after=  First-boot setup", "--console-input-after=  Press Enter once you have.",
        "--console-input-after=  Log in", "--console-input-after=SlopOS shell",
        "--expect-console-line=[1] started",
        "--expect-console-contains=test_shell_calls (job 1)", "--expect-console-contains=25000", "--expect-console-contains=3125"])),
    ("runs jobs in the background, and stops them with Ctrl-C and stop", 7,
     with_before_qemu([argument.replace("test_services", "test_services test_settle=60").replace("--timeout=120", "--timeout=180")
                       for argument in BOOT_DISK_BASE], ["--shut-down-when-done", 
        "--console-input=\\wAdmin\\radmin\\rcorrect horse battery staple\\rcorrect horse battery staple\\r\\w\\r\\wadmin\\rcorrect horse battery staple\\r"
        "\\wtest_shell_calls 2 bg --sleep 1s &\\r\\p\\p\\p\\pwait 1\\r\\p\\p"
        "test_shell_calls 1 fg --sleep 20s\\r\\p\\p\\x03\\p\\p"
        "test_shell_calls 1 ta --sleep 20s\\r\\p\\ptyped ahead\\p\\x03\\p\\p"
        "test_shell_calls 1 st --sleep 20s --stubborn\\r\\p\\p\\x03\\p\\p\\p\\p"
        "test_shell_calls 1 sj --sleep 20s &\\r\\p\\pjobs\\r\\pstop\\r\\p\\p\\p\\pjobs\\r",
        "--console-input-after=  First-boot setup", "--console-input-after=  Press Enter once you have.",
        "--console-input-after=  Log in", "--console-input-after=SlopOS shell",
        "--expect-console-line=[1] started", "--expect-console-line=[1] ended, with 2 records: wait 1 for them",
        "--refuse-console-line=called with ta, 1, loud false, speed none, wait none, tags none, place none",
        "--expect-console-line=1   bg1   Slow", "--expect-console-line=2   bg2   Fast",
        "--expect-console-line=error: test_shell_calls ended with 10",
        "--expect-console-line=error: test_shell_calls was ended",
        "--expect-line=[user] shell: test_shell_calls didn't stop in time, so it's killed",
        "--expect-console-line=[2] started", "--expect-console-line=[2] stopped", "--expect-console-line=no jobs"])),
    # The bundle store's objects (decisions/0178): kept to 16 open, it's asked for more programs than that, one after
    # another, help taking each's executable and letting it go; it closes those no one holds to make room, and every
    # one is still found
    ("closes objects no one holds to make room for others in the bundle store", 7,
     with_before_qemu([argument.replace("test_services", "test_services store_objects=16 test_settle=60").replace("--timeout=120", "--timeout=180")
                       for argument in BOOT_DISK_BASE], ["--shut-down-when-done", 
        "--console-input=\\wAdmin\\radmin\\rcorrect horse battery staple\\rcorrect horse battery staple\\r\\w\\r\\wadmin\\rcorrect horse battery staple\\r"
        "\\w" + "".join(f"help {name}\\r\\p" for name in [
            "test_affinity", "test_budgets", "test_channels", "test_control", "test_cpu_budgets", "test_devices", "test_exits",
            "test_io_ports", "test_libraries", "test_memory", "test_msi_dma", "test_pager", "test_perf", "test_ports",
            "test_protocols", "test_streams", "test_syscalls", "test_threads", "test_values", "test_affinity"])
        + "test_shell_calls 1 still\\r",
        "--console-input-after=  First-boot setup", "--console-input-after=  Press Enter once you have.",
        "--console-input-after=  Log in", "--console-input-after=SlopOS shell",
        "--expect-line=[user] bundle_store: closed an object no one held, to make room: 1 closed so far",
        "--expect-console-line=test_values:  Run the tests, reporting to the debug log: as the program the root task ran, or, given "
        "count, as the copy, its lines started with COPY_NAME.",
        "--expect-console-line=called with still, 1, loud false, speed none, wait none, tags none, place none",
        "--refuse-console-line=error: there's no command named test_affinity"])),
    # Entry results (decisions/0179): a program's main gives back a Result; the shell shows an Ok's value, and an Error
    # by its variant, the parameter it names and the hint its documentation gives, which try catches
    ("shows what a program's entry gives back: a value, or an error with its parameter and hint", 7,
     with_before_qemu([argument.replace("test_services", "test_services test_settle=60").replace("--timeout=120", "--timeout=180")
                       for argument in BOOT_DISK_BASE], ["--shut-down-when-done", 
        "--console-input=\\wAdmin\\radmin\\rcorrect horse battery staple\\rcorrect horse battery staple\\r\\w\\r\\wadmin\\rcorrect horse battery staple\\r"
        "\\wtest_shell_results 3 abc\\r\\p\\p"
        "test_shell_results 1 x --asked Plain\\r\\p\\p"
        "test_shell_results 1 x --asked Refused\\r\\p\\p"
        "try { test_shell_results 1 x --asked Plain } catch e { print \"caught\" $e.message }\\r",
        "--console-input-after=  First-boot setup", "--console-input-after=  Press Enter once you have.",
        "--console-input-after=  Log in", "--console-input-after=SlopOS shell",
        "--expect-console-line=count: 3", "--expect-console-line=label: \"abc\"",
        "--expect-console-line=error: test_shell_results: Plain: Something went wrong that says nothing more.",
        "--expect-console-line=error: test_shell_results --label: Refused: The label isn't one it takes.",
        "--expect-console-line=caught test_shell_results: Plain: Something went wrong that says nothing more."])),
    # The file tools (decisions/0179): list, copy, move, remove, which takes a snapshot first, and recover, which finds
    # what's gone in the snapshots and brings it back; a path that matches only without case gets "did you mean"
    ("lists, copies, moves, removes and recovers files, and says what a path probably meant", 7,
     with_before_qemu([argument.replace("test_services", "test_services test_settle=180").replace("--timeout=120", "--timeout=330")
                       for argument in BOOT_DISK_BASE], [
        "--console-input=\\wAdmin\\radmin\\rcorrect horse battery staple\\rcorrect horse battery staple\\r\\w\\r\\wadmin\\rcorrect horse battery staple\\r"
        "\\wtest_file_tree\\r\\p\\p"
        "list\\r\\p\\p"
        "copy notes.txt notes2.txt\\r\\p\\p"
        "move notes2.txt pictures\\r\\p\\p"
        "list pictures\\r\\p\\p"
        "remove pictures\\r\\p\\p"
        "list\\r\\p\\p"
        "recover\\r\\p\\p\\p"
        "recover pictures\\r\\p\\p\\p"
        "list pictures\\r\\p\\p"
        "test_shell_calls 1 x --place photos\\r\\p\\p"
        "remove nothing_here\\r",
        "--console-input-after=  First-boot setup", "--console-input-after=  Press Enter once you have.",
        "--console-input-after=  Log in", "--console-input-after=SlopOS shell",
        "--expect-console-line=files: 3", "--expect-console-line=Report.txt  File       17 B", "--expect-console-line=bytes: 17 B",
        "--expect-console-line=to: \"pictures/notes2.txt\"", "--expect-console-line=notes2.txt  File  17 B",
        "--expect-console-line=path: \"pictures\"", "--expect-console-line=count: 3",
        "--expect-console-line=name      directory  snapshot", "--expect-console-line=name: \"pictures\"", "--expect-console-line=files: 2",
        "--expect-console-line=error: photos: there's nothing there; did you mean Photos?",
        "--expect-console-line=error: remove --path: NotFound: There's nothing at that path to remove.",
        # Done once it's all shown: P on the secure attention key's screen shuts it down (decisions/0180)
        "--shut-down-when-done", "--expect-line=[user] root task: shutting down, as the console asked"])),
    # Reading values (decisions/0179, 11e3): search over the files, view of a text, a binary and a typed file, and
    # the pager, a screen at a time: a screen on with Space, to the end with G, a line back with k, and x, which it
    # doesn't know, drawing it again before q quits, so the last status line isn't the prompt's line too
    ("searches files, views text, bytes and typed files, and pages a long value", 7,
     with_before_qemu([argument.replace("test_services", "test_services test_settle=180").replace("--timeout=120", "--timeout=330")
                       for argument in BOOT_DISK_BASE], [
        "--console-input=\\wAdmin\\radmin\\rcorrect horse battery staple\\rcorrect horse battery staple\\r\\w\\r\\wadmin\\rcorrect horse battery staple\\r"
        "\\wtest_file_tree --reading\\r\\p\\p"
        "search TODO\\r\\p\\p"
        "search LONG --names --ignore-case\\r\\p\\p"
        "search \"(\"\\r\\p"
        "view reading/todo.txt\\r\\p"
        "view reading/bytes.bin\\r\\p"
        "view reading/made.value\\r\\p\\p"
        "view reading/long.txt | page\\r\\p\\p \\p\\pG\\p\\pk\\p\\px\\p\\pq\\p"
        "view reading/todo.txt | page\\r\\p"
        "view reading/CAFE\\u0301.txt\\r",
        "--console-input-after=  First-boot setup", "--console-input-after=  Press Enter once you have.",
        "--console-input-after=  Log in", "--console-input-after=SlopOS shell",
        "--expect-console-line=files: 8", "--expect-console-line=reading/todo.txt  2     TODO: water the plants",
        # CAFÉ, written with E and a combining acute, is Café once both are normalized and case folded
        "--expect-console-line=error: reading/CAFE\u0301.txt: there's nothing there; did you mean reading/Café.txt?",
        "--expect-console-line=reading/long.txt  0     ",
        "--expect-console-line=error: search --pattern: BadPattern: The pattern isn't a regular expression; check its parentheses, "
        "brackets and repetitions.",
        "--expect-console-line=first", "--expect-console-line=last",
        "--expect-console-line=00000010  10 11 12 13 14 15 16 17 18 19 1a 1b 1c 1d 1e 1f  |................|",
        "--expect-console-line=files: 3", "--expect-console-line=directories: 1",
        "--expect-console-line=lines 1-22 of 60: Space and b page, Up and Down scroll, q quits",
        "--expect-console-line=lines 23-44 of 60: Space and b page, Up and Down scroll, q quits",
        "--expect-console-line=lines 39-60 of 60: Space and b page, Up and Down scroll, q quits",
        "--expect-console-line=lines 38-59 of 60: Space and b page, Up and Down scroll, q quits",
        "--shut-down-when-done", "--expect-line=[user] root task: shutting down, as the console asked"])),
    # The system as a session sees it (decisions/0179, 11e4): the user's own installations installed, listed, seen
    # running, ended and uninstalled, their data recoverable after; the refusals; and the kept grants, of which there
    # are none
    ("installs and uninstalls a user's own installations, lists the session's processes, and its kept grants", 7,
     with_before_qemu([argument.replace("test_services", "test_services test_settle=180").replace("--timeout=120", "--timeout=330")
                       for argument in BOOT_DISK_BASE], [
        "--console-input=\\wAdmin\\radmin\\rcorrect horse battery staple\\rcorrect horse battery staple\\r\\w\\r\\wadmin\\rcorrect horse battery staple\\r"
        "\\winstallations\\r\\p"
        "install counter --as tally\\r\\p\\p"
        "installations\\r\\p"
        "processes | where name == \"tally\" | map state\\r\\p\\p"
        "install list\\r\\p"
        "install counter --as tally\\r\\p"
        "end tally\\r\\p\\p\\p"
        "processes\\r\\p\\p"
        "uninstall tally\\r\\p\\p\\p"
        "installations\\r\\p"
        "cd apps\\r\\p"
        "recover\\r\\p\\p\\p"
        "grants\\r\\p"
        "grants --revoke 7\\r",
        "--console-input-after=  First-boot setup", "--console-input-after=  Press Enter once you have.",
        "--console-input-after=  Log in", "--console-input-after=SlopOS shell",
        "--expect-console-line=counter  counter  system", "--expect-console-line=tally    counter  yours",
        "--expect-console-line=\"running\"",
        "--expect-console-line=error: list: its program needs its here, which an installation isn't given: only a data directory, settings, the clock and the locale",
        "--expect-console-line=error: tally: an installation has that name already; give another with --as",
        "--expect-console-line=name   directory  snapshot", "--expect-console-line=no kept grants",
        "--expect-console-line=error: there's no kept grant 7", "--expect-console-contains=  cpu  ",
        "--expect-line=[user] sessions: installed tally (counter) for admin",
        "--expect-line=[user] sessions: ending tally as its session's shell asked",
        "--expect-line=[user] sessions: uninstalled tally for admin",
        "--shut-down-when-done", "--expect-line=[user] root task: shutting down, as the console asked"])),
    # The editor (decisions/0162, 0179, 11e5): on the terminal the shell gives it, notes.txt edited: a line added on
    # the empty last line, another after it taken back with Ctrl-Z, "second" found with Ctrl-F, saved with Ctrl-S; then
    # a change, and Ctrl-Q twice to quit without it; what it gives back shown, and the file viewed as saved
    ("edits a file on the terminal: types, undoes, finds, saves, and asks before quitting with changes", 7,
     with_before_qemu([argument.replace("test_services", "test_services test_settle=180").replace("--timeout=120", "--timeout=330")
                       for argument in BOOT_DISK_BASE], [
        "--console-input=\\wAdmin\\radmin\\rcorrect horse battery staple\\rcorrect horse battery staple\\r\\w\\r\\wadmin\\rcorrect horse battery staple\\r"
        "\\wtest_file_tree\\r\\p\\p"
        "edit notes.txt\\r\\p\\p"
        "\\e[Bsecond line\\r\\pthird\\p\\x1a\\p"
        "\\x06second\\r\\p\\x13\\p\\p"
        "x\\p\\x11\\p\\x11\\p\\p"
        "view notes.txt\\r",
        "--console-input-after=  First-boot setup", "--console-input-after=  Press Enter once you have.",
        "--console-input-after=  Log in", "--console-input-after=SlopOS shell",
        "--expect-console-line=line 1 of 2, column 1  ^S saves  ^Q quits  ^F finds  ^Z undoes",
        "--expect-console-line=find: second", "--expect-console-line=saved: 3 lines, 29 bytes",
        "--expect-console-line=the changes aren't saved: Ctrl-Q again quits without them, Ctrl-S saves",
        "--expect-console-line=saved: true", "--expect-console-line=lines: 3", "--expect-console-line=bytes: 30 B",
        "--expect-console-line=a line in a file", "--expect-console-line=second line",
        "--shut-down-when-done", "--expect-line=[user] root task: shutting down, as the console asked"])),
    # Scripts (decisions/0179, 11e6): each run in a shell of its own, given only what its param line says. report.shell
    # is given a pattern and a count, lists its here and searches it; into.shell lists a second directory it's given as
    # a handle; escape.shell can't view what's beyond its here, and ends at that line; a missing argument is refused
    # before anything runs; help says what a script takes
    ("runs scripts with only what their param lines give them", 7,
     with_before_qemu([argument.replace("test_services", "test_services test_settle=180").replace("--timeout=120", "--timeout=330")
                       for argument in BOOT_DISK_BASE], [
        "--console-input=\\wAdmin\\radmin\\rcorrect horse battery staple\\rcorrect horse battery staple\\r\\w\\r\\wadmin\\rcorrect horse battery staple\\r"
        "\\wtest_file_tree --reading --scripts\\r\\p\\p"
        "report.shell TODO --count 2\\r\\p\\p\\p"
        "into.shell reading\\r\\p\\p\\p"
        "escape.shell --here pictures\\r\\p\\p\\p"
        "report.shell\\r\\p"
        "help report.shell\\r",
        "--console-input-after=  First-boot setup", "--console-input-after=  Press Enter once you have.",
        "--console-input-after=  Log in", "--console-input-after=SlopOS shell",
        "--expect-console-line=files: 11", "--expect-console-line=looking for TODO, 2 times",
        "--expect-console-line=reading/todo.txt  2     TODO: water the plants",
        "--expect-console-line=made.value  File  16 B", "--expect-console-line=in here",
        "--expect-console-line=error: line 3: ../notes.txt: that's above your home",
        "--expect-console-line=error: escape.shell ended with 1",
        "--expect-console-line=error: report.shell needs its pattern",
        "--expect-console-line=report.shell is a script, run in a shell of its own with only what it's given. It takes:",
        "--expect-console-line=  --pattern (string)",
        "--refuse-console-line=not reached",
        "--shut-down-when-done", "--expect-line=[user] root task: shutting down, as the console asked"])),
    # Kept grants from the shell, end to end (decisions/0181, F4): a program the shell starts asks its powerbox for a file
    # to keep, which the user ticks (Tab) in the chooser; it opens it again by its key; grants lists it and revokes it;
    # opened again after, it's refused
    ("keeps a grant a program in the shell asks for, lists it with grants, and revokes it", 7,
     with_before_qemu([argument.replace("test_services", "test_services test_settle=180").replace("--timeout=120", "--timeout=330")
                       for argument in BOOT_DISK_BASE], [
        "--console-input=\\wAdmin\\radmin\\rcorrect horse battery staple\\rcorrect horse battery staple\\r\\w\\r\\wadmin\\rcorrect horse battery staple\\r"
        "\\wtest_kept_grant\\r\\w\\p\\e[3;7~\\w\\t\\r"
        "\\w\\ptest_kept_grant --reopen\\r\\p\\p"
        "grants\\r\\p"
        "grants --revoke 1\\r\\p"
        "grants\\r\\p"
        "test_kept_grant --reopen\\r",
        "--console-input-after=  First-boot setup", "--console-input-after=  Press Enter once you have.",
        "--console-input-after=  Log in", "--console-input-after=SlopOS shell",
        "--console-input-after=Asked the powerbox; Ctrl+Alt+Delete shows what it asks.", "--console-input-after=  Choose a file",
        "--console-input-after=line: a kept line",
        "--expect-line=[user] powerbox: kept kept.txt for test_kept_grant",
        "--expect-line=[user] powerbox: reopened kept for test_kept_grant",
        "--expect-console-line=grant 1 revoked", "--expect-console-line=no kept grants",
        "--expect-line=[user] powerbox: couldn't reopen kept for test_kept_grant",
        "--expect-console-line=error: test_kept_grant --powerbox: Refused: The powerbox gave nothing; for reopen, nothing's kept under the key, or it was revoked.",
        "--shut-down-when-done", "--expect-line=[user] root task: shutting down, as the console asked"])),
    # Chaos (decisions/0096's R5, 0181's F6): once everything's started, six services and drivers the supervisor starts
    # again, chosen at random from a logged seed, killed one at a time; each started again and answering, and the
    # supervisor's budget back where it was
    ("kills services and drivers at random, and each comes back and answers, with no memory lost", 7,
     with_before_qemu([argument.replace("test_services", "test_services test_chaos=6 test_settle=60").replace("--timeout=120", "--timeout=180")
                       for argument in BOOT_DISK_BASE if not argument.startswith("--expect-line=") or argument == HEALTHY_LINE], [
        "--expect-line=[user] supervisor: test_chaos: every service killed was started again and answered, and the budgets are as they were"])),
    # Automatic snapshots (decisions/0179): every 2 seconds with test_snapshot_seconds=2, kept 20, of the two volumes
    # served, so after a while two are taken and two deleted each time
    ("takes automatic snapshots of the volumes it serves, and deletes the old ones", 7,
     with_before_qemu([argument.replace("test_services", "test_services test_snapshot_seconds=2 test_settle=45").replace("--timeout=120", "--timeout=180")
                       for argument in BOOT_DISK_BASE], [
        "--expect-line=[user] storage_manager: automatic snapshots: 2 taken, 0 deleted",
        "--expect-line=[user] storage_manager: automatic snapshots: 2 taken, 2 deleted"])),
    # Memory pressure (decisions/0153): with two sessions, the session manager's budget charged to its threshold, it asks
    # the idle installation, the counter of the session not shown, to stop, and leaves the shown session's running
    ("stops the idle installations of sessions not shown under memory pressure", 7,
     with_before_qemu([argument.replace("test_services", "test_services use_echo test_pressure test_settle=45") for argument in BOOT_DISK_BASE], ["--shut-down-when-done", 
        "--console-input=\\wAdmin\\radmin\\rcorrect horse battery staple\\rcorrect horse battery staple\\r\\w\\r\\wadmin\\rcorrect horse battery staple\\r\\wfirst line\\r\\w\\e[3;7~\\pn\\wadmin\\rcorrect horse battery staple\\r\\p\\p\\p\\p\\p\\p\\p\\p\\e[3;7~\\ps",
        "--console-input-after=  First-boot setup", "--console-input-after=  Press Enter once you have.",
        "--console-input-after=  Log in", "--console-input-after=Your home directory has 1 entry.",
        "--console-input-after=echo: first line", "--console-input-after=  Log in",
        "--expect-line=[user] terminal: login: another session",
        "--expect-line=[user] sessions: memory pressure: asking counter in session 0 to stop",
        "--expect-line=[user] sessions: ending counter under memory pressure",
        "--expect-line=[user] sessions: test_pressure: idle installations stopped: 1; the shown session's left running",
        # Shown again, its installation stopped under pressure is started again (decisions/0181, F3)
        "--expect-line=[user] sessions: starting counter again in session 0, stopped under memory pressure"])),
    # Each session on a CPU budget of its own, a quarter of the sessions' tenth of a CPU (decisions/0187)
    ("runs each session on a CPU budget of its own", 7,
     with_before_qemu([argument.replace("test_services", "test_services use_echo test_session_cpu test_settle=30") for argument in BOOT_DISK_BASE], ["--shut-down-when-done",
        "--console-input=\\wAdmin\\radmin\\rcorrect horse battery staple\\rcorrect horse battery staple\\r\\w\\r\\wadmin\\rcorrect horse battery staple\\r\\wfirst line\\r\\w\\e[3;7~\\pn\\wadmin\\rcorrect horse battery staple\\r\\p\\p",
        "--console-input-after=  First-boot setup", "--console-input-after=  Press Enter once you have.",
        "--console-input-after=  Log in", "--console-input-after=Your home directory has 1 entry.",
        "--console-input-after=echo: first line", "--console-input-after=  Log in",
        "--expect-line=[user] terminal: login: another session",
        "--expect-line=[user] sessions: test_session_cpu: 2 sessions on CPU budgets of their own, 25000 millionths of a CPU each; the first's programs ran on its"])),
    ("makes the administrator's account and home volume, limits wrong passwords, and recovers it with its recovery code", 7,
     with_before_qemu([argument.replace("test_services", "test_services test_accounts") for argument in BOOT_DISK_BASE], [
        "--expect-line=[user] storage_manager: made the accounts volume",
        "--expect-line=[user] account_service: made the accounts volume",
        "--expect-line=[user] account_service: serving 0 accounts",
        "--expect-line=[user] storage_manager: made the home-admin volume",
        "--expect-line=[user] account_service: made the account admin, the administrator",
        "--expect-line=[user] account_service: admin recovered with its recovery code",
        f"--expect-line={tests_passed('supervisor: test_accounts', 4)}"])),
    ("keeps every program's log records on the system volume once it's there, each source's to its budget", 7, with_before_qemu(
        [argument.replace("test_services", "test_services test_events") for argument in BOOT_DISK_BASE], [
        "--expect-line=[user] events: serving",
        "--expect-line=[user] supervisor: test_events: the waiting query got hello's record 0: heap working, random numbers working",
        # hello's budget, from the system configuration (decisions/0185, 12g)
        "--expect-line=[user] supervisor: hello's records are kept to 2097152 bytes, as its configuration says",
        "--expect-line=[user] supervisor: test_events: hello's record 0 read back from the system volume: heap working, random numbers working",
        "--expect-line=[user] supervisor: test_events: clock's record 1 read back from the system volume: serving",
        # The clock service's source given the smallest budget, which its restarts pass, dropping its oldest records (decisions/0183)
        "--expect-line=[user] supervisor: test_events: the clock service's oldest records were dropped past its budget"])),
    ("starts the events service, the clock service and the storage manager again when they're killed", 7, with_before_qemu(
        # Not the FAT server's FSInfo line or hello's config line, which the kills may come before
        [argument.replace("test_services", "test_services test_restart_services test_storage_restart") for argument in BOOT_DISK_BASE
         if argument not in RACING_RESTARTS], [
        "--expect-line=[user] storage_manager: the volume server for the system volume ended",
        "--expect-line=[user] supervisor: the system volume's connection closed; opening it again",
        "--expect-line=[user] supervisor: test_restart_services: the system volume, served again after disk 0's partition server was, "
        "and the bundle store reads through it",
        "--expect-line=[user] supervisor: test_restart_services: killing events", "--expect-line=[user] supervisor: restarted events",
        "--expect-line=[user] supervisor: test_restart_services: killing clock", "--expect-line=[user] supervisor: restarted clock",
        "--expect-line=[user] supervisor: test_restart_services: the clock service, started again, set the time",
        "--expect-line=[user] supervisor: test_restart_services: the events service, started again, has the clock service's record 1: serving",
        "--expect-line=[user] supervisor: test_restart_services: killing storage_manager",
        "--expect-line=[user] supervisor: restarted storage_manager",
        "--expect-line=[user] supervisor: test_restart_services: the storage manager, started again, gave the system volume"])),
    ("keeps objects in the bundle store and pages them in", 7, with_before_qemu(
        [argument.replace("test_services", "test_services test_store") for argument in BOOT_DISK_BASE], [
        "--expect-line=[user] bundle_store: serving",
        "--expect-line=[user] supervisor: test_store: put hello's program, read it back whole as paged memory, a wrong hash refused; "
        "a pinned object kept (0 collected), and collected once unpinned (1)",
        "--expect-line=[user] supervisor: test_store: with 64 KiB of pages kept, read hello's program back whole twice, the rest given back "
        "under pressure",
        "--expect-line=[user] supervisor: test_store: hello's bundle's manifest is its entry's schema"])),
    # Crash reports (decisions/0183, 12a): the update service's thread is sent where nothing's mapped, so it faults; the
    # supervisor, holding the intercept of its faults, reports it, kills it, and starts it again
    ("reports a service's crash, and starts it again", 7, with_before_qemu(
        [argument.replace("test_services", "test_services test_crash") for argument in BOOT_DISK_BASE], [
        "--expect-line=[user] supervisor: test_crash: crashing update",
        "--expect-line=[user] supervisor: update crashed: execute fault",
        "--expect-line=[user] supervisor: update ended"])),
    # Tracing (decisions/0183, 12d): the kernel's trace from its start, the supervisor's boot timeline from it, and a
    # ping of the clock service, which the trace shows woken by it and run
    ("traces the boot's timeline and a known exchange", 7, with_before_qemu(
        [argument.replace("test_services", "test_services trace_boot test_trace") for argument in BOOT_DISK_BASE], [
        "--expect-line=[user] supervisor: test_trace: every running service is in the boot's timeline",
        "--expect-line=[user] supervisor: test_trace: a ping's exchange is in the trace: the clock service woken by it, and run to "
        "answer"])),
    ("boots degraded, with a record of why, when a service the system needs ends for good", 7, with_before_qemu(
        # hello's own lines too, which it may not get to before it's killed
        [argument.replace("test_services", "test_services test_degraded") for argument in BOOT_DISK_BASE
         if argument != HEALTHY_LINE and not argument.startswith("--expect-line=[user] hello: ")], [
        "--expect-line=[user] supervisor: degraded: hello ended for good, 4294967296",
        "--expect-line=[user] root task: the boot is degraded: 1 services the system needs aren't up",
        "--expect-disk-text=hello: ended for good"])),
    # Installations run in sessions (decisions/0153): the administrator's, once they've logged in, runs the counter
    # with its data in their home and its settings theirs, and the session manager updates it, uninstalls it and
    # installs it again, then makes it crash, which it reports (decisions/0183)
    ("runs installations in a session with their data and settings, updates one keeping its data, uninstalls it, and reports its crash", 7,
     with_before_qemu([argument.replace("test_services", "test_services test_installations test_settle=30") for argument in BOOT_DISK_BASE], ["--shut-down-when-done", 
        "--console-input=\\wAdmin\\radmin\\rcorrect horse battery staple\\rcorrect horse battery staple\\r\\w\\r\\wadmin\\rcorrect horse battery staple\\r",
        "--console-input-after=  First-boot setup", "--console-input-after=  Press Enter once you have.",
        "--console-input-after=  Log in",
        "--expect-line=[user] sessions: started counter in the session",
        "--expect-line=[user] counter: run 1, version 1",
        "--expect-line=[user] counter: run 2, version 2",
        "--expect-line=[user] config: forgot user:admin:counter's values",
        "--expect-line=[user] sessions: test_installations: an update to list's bundle refused, updated to counter_next and run, "
        "uninstalled whole, installed again and run",
        "--expect-line=[user] sessions: counter crashed: execute fault",
        "--expect-line=[user] sessions: test_installations: the counter crashed and ended"])),
    # SlopOS's own bootloader (roadmap B2, decisions/0133), which starts the other CPUs
    ("boots a disk through SlopOS's own bootloader, every CPU started", 7, with_before_qemu(BOOT_DISK_BASE, [
        "--expect-line=[info] bootloader: booting generation 1",
        "--expect-line=[boot] SlopOS, booted by SlopOS's bootloader (UEFI)", "--expect-line=[info] 2 of 2 CPUs online"])),
    # Boot counting (roadmap B3): generation 2 boots three times without ever being assessed, then is given up on
    ("falls back to the generation before when a new one never comes up healthy in its tries, and rolls it back", 7,
        with_before_qemu(BOOT_DISK_BASE, [
        "--stage-generation=test_exit test_services no_disk_check test_unassessed", "--boots=5",
        "--expect-line=[info] bootloader: a seed file written, for the next boot",
        "--expect-line=[user] update: installed generation 2, tentative",
        "--expect-boot-line=2:[info] bootloader: the seed file mixed in, and replaced",
        "--expect-boot-line=2:[info] bootloader: generation 2 is tentative, 2 tries left after this one",
        "--expect-boot-line=2:[user] supervisor: test_unassessed: the update service isn't told how the boot went",
        "--expect-boot-line=4:[info] bootloader: generation 2 is tentative, 0 tries left after this one",
        "--expect-boot-line=5:[info] bootloader: generation 2 never came up healthy in its tries, so the one before it boots",
        "--expect-boot-line=5:[user] root task: booted generation 1",
        "--expect-boot-line=5:[user] update: generation 2 never came up healthy in its tries, and is rolled back"])),
    # Without the normal boot's lines, which the recovery generation's doesn't have
    # A few seconds' settling, for the terminal, which serves once the session with no user has started its shell
    ("boots the recovery generation by its key: the boot set, the drivers and the console", 7, with_before_qemu(
        [argument.replace("test_services", "test_services test_settle=5") for argument in BOOT_DISK_BASE
         if not argument.startswith("--expect-line=") or argument == HEALTHY_LINE], [
        "--recovery-key", "--expect-line=[info] bootloader: the recovery generation, as a key asks",
        "--expect-line=[user] root task: booted the recovery generation",
        "--expect-line=[user] supervisor: recovery: the boot set, the drivers and the console only",
        "--expect-line=[user] terminal: serving"])),
    # The panic record (decisions/0134): the first boot panics and resets, keeping RAM; the next finds its record
    ("keeps a panic's record across a warm reset, on the ESP and for the root task", 7, with_before_qemu(
        [argument.replace("test_services", "test_services panic_reset test_panic_once") for argument in BOOT_DISK_BASE], [
        "--allow-reboot", "--expect-line=[info] test_panic_once: failing an assertion",
        "--expect-line=[info] resetting, the panic record kept",
        "--expect-line=[info] bootloader: the boot before stopped for a fault, its panic record kept as EFI/SlopOS/LAST_PANIC",
        "--expect-disk-text=assertion failed: test_panic_once",
        "--expect-line=[user] root task: the boot before stopped for a fault: [fatal] assertion failed: test_panic_once",
        "--expect-line=[user] terminal: showing the boot before's fault: [fatal] assertion failed: test_panic_once"])),
    # Its command line another word, so it isn't one that changes only services, which is applied live
    ("installs a staged generation, boots it, and makes it permanent once it's healthy", 7, with_before_qemu(BOOT_DISK_BASE, [
        "--stage-generation=test_exit test_services next_boot", "--boots=2",
        "--expect-line=[user] update: installed generation 2, tentative",
        "--expect-boot-line=2:[user] root task: booted generation 2",
        "--expect-boot-line=2:[user] root task: the system is healthy",
        "--expect-boot-line=2:[user] update: generation 2 made permanent"])),
    ("applies a staged generation that changes only a service live, restarting it from its new bundle", 7,
        with_before_qemu(BOOT_DISK_BASE, [
        "--stage-generation=test_exit test_services no_disk_check", "--stage-next-hello",
        "--expect-line=[user] update: installed generation 2, tentative",
        "--expect-line=[user] update: generation 2 changes only services, and is applied live",
        "--expect-line=[user] supervisor: generation 2 applied live, 1 services started again from their new bundles",
        "--expect-line=[user] hello: the next build",
        "--expect-line=[user] update: generation 2 made permanent"])),
    ("rolls a staged generation back when it boots degraded, and boots the one before", 7, with_before_qemu(BOOT_DISK_BASE, [
        "--stage-generation=test_exit test_services test_degraded", "--boots=3",
        "--expect-line=[user] update: installed generation 2, tentative",
        "--expect-boot-line=2:[user] root task: booted generation 2",
        "--expect-boot-line=2:[user] update: generation 2 booted degraded, and is rolled back",
        "--expect-boot-line=3:[user] root task: booted generation 1",
        "--expect-boot-line=3:[user] root task: the system is healthy"])),
    ("keeps an override of the system configuration in the config store, and starts what it tunes as it says", 7, with_before_qemu(
        [argument.replace("test_services", "test_services test_system_config") for argument in BOOT_DISK_BASE], [
        "--expect-line=[user] supervisor: the system configuration's override tunes 1 services",
        "--expect-line=[user] supervisor: test_system_config: killing hello",
        "--expect-line=[user] supervisor: test_system_config: an override of hello's budget taken, one of 0 refused; hello started again "
        "on 3 MiB"])),
    ("stages a generation with a substitution the config store asks for, only by a library that stands in, and boots it", 7,
        with_before_qemu([argument.replace("test_services", "test_services test_substitution") for argument in BOOT_DISK_BASE], [
        "--boots=2",
        "--expect-line=[user] update: warn: a substitution is refused: an export isn't there any more",
        "--expect-line=[user] update: generation 2 staged with 1 substitutions, booted next",
        "--expect-line=[user] supervisor: test_substitution: greeting for service_kit refused, service_kit_plus staged as generation 2",
        "--expect-boot-line=2:[user] root task: booted generation 2",
        "--expect-boot-line=2:[user] supervisor: test_substitution: booted generation 2 with service_kit_plus in service_kit's place",
        "--expect-boot-line=2:[user] update: generation 2 made permanent"])),
    # On one CPU, where requests wait for the volume server rather than it waiting for them
    ("serves a volume's clients by the priority of the CPU budgets they lend it", 7, with_before_qemu(
        one_cpu([argument.replace("test_services", "test_services use_echo test_lending") for argument in BOOT_DISK_BASE]), [
        "--expect-line=[user] supervisor: test_lending: a request lent echo's budget was answered ahead of the backlogs lent hello's",
        # What the volume server ran on hello's budget, in hello's attribution (decisions/0185, 12h)
        "--expect-line=[user] supervisor: test_lending: echo's budget shows what the volume server ran on it"])),
    ("starts a disk's partition server again when it's killed, and serves its volumes through the new one", 7, with_before_qemu(
        [argument.replace("test_services", "test_services test_storage_restart") for argument in BOOT_DISK_BASE], [
        "--expect-line=[user] storage_manager: test_storage_restart: killing the partition server for disk 0",
        "--expect-line=[user] storage_manager: the partition server for disk 0 ended",
        "--expect-line=[user] storage_manager: restarted the partition server for disk 0"])),
    ("keeps the kernel's share of memory out of the root budget", 7, [WITH_PROGRAMS, "--command-line=test_exit test_services kernel_reserve=24",
        "--expect-line=[info] memory: 24 MiB kept out of the root budget for the kernel's own",
        "--expect-line=[user] root task: the supervisor started all 8 of its services"]),
    ("doesn't start the root task with no_root_task", 0, [WITH_PROGRAMS, "--command-line=test_exit no_root_task",
        "--expect-line=[info] boot memory reclaimed"]),
    ("reports a kernel fault", 1, ["--command-line=test_exit test_fault"]),
    ("reports a failed assertion", 3, ["--command-line=test_exit test_assert"]),
    # The kernel's own control-flow integrity (decisions/0186, Hd): skipped under TCG's x86-64, which has no CET
    ("skips a tampered return in the kernel without signed returns or a shadow stack", 0, ["--command-line=test_exit test_tamper",
        "--expect-line=[info] test_tamper: skipped: the kernel has neither signed returns nor a shadow stack on this CPU"]),
    ("skips a branch to no landing pad in the kernel without landing pads", 0, ["--command-line=test_exit test_branch",
        "--expect-line=[info] test_branch: skipped: the kernel's indirect branches aren't checked for landing pads on this CPU"]),
    ("skips a write to the kernel's shadow stack without one", 0, ["--command-line=test_exit test_shadow_write",
        "--expect-line=[info] test_shadow_write: skipped: the kernel has no shadow stack on this CPU"]),
    ("refuses a CPU below x86-64-v3", 2, ["--cpu=qemu64"]),
    ("starts every CPU", 0, ["--expect-line=[info] 4 of 4 CPUs online", "--expect-line=[info] boot memory reclaimed",
                             "--", "-smp", "4"]),
    ("keeps the kernel's code read-only", 1, ["--command-line=test_exit test_write_code",
                                              "--expect-line=[info] test_write_code: writing to the kernel's code"]),
    ("allocates from the kernel heap", 0, ["--command-line=test_exit test_heap",
        "--expect-line=[info] test_heap: 2 tests: 2 passed, 0 failed"]),
    ("keeps time with the counter", 0, ["--command-line=test_exit test_clock",
        "--expect-line=[info] test_clock: 1 test: 1 passed, 0 failed"]),
    # A development generation's command line edited in the bootloader (decisions/0181, F7): e pressed as it starts,
    # test_clock typed after the line it shows, then Enter, so the kernel runs its clock test; a release generation's
    # isn't edited, and that's said
    ("edits a development generation's command line in the bootloader, for that boot", 0, ["--command-line=test_exit",
        "--bootloader-edit= test_clock", "--expect-line=[info] bootloader: booting with the command line edited",
        "--expect-line=[info] test_clock: 1 test: 1 passed, 0 failed"]),
    ("won't edit a release generation's command line in the bootloader", 0, ["--command-line=test_exit", "--release-generation",
        "--bootloader-edit= test_clock",
        "--expect-line=[info] bootloader: generation 1 isn't built for development, so its command line can't be edited"]),
    ("lets idle CPUs other than the boot CPU stop ticking", 0, ["--command-line=test_exit test_tickless",
        "--expect-line=[info] test_tickless: 1 test: 1 passed, 0 failed", "--", "-smp", "4"]),
    ("shoots down TLB entries on every CPU", 0, ["--command-line=test_exit test_shootdown",
        "--expect-line=[info] test_shootdown: 1 test: 1 passed, 0 failed", "--", "-smp", "4"]),
    # A binding slot read without a lock while it's made anew, as one kept after its port let it go is (decisions/0052)
    ("reads a binding slot whole on other CPUs while it's made anew", 0, ["--command-line=test_exit test_binding_reuse",
        "--expect-line=[info] test_binding_reuse: 1 test: 1 passed, 0 failed", "--", "-smp", "2"]),
    # An object moved to another owner, as take_one moves an owning handle, while it's destroyed (decisions/0051)
    ("moves an object to another owner on one CPU while another destroys it, and leaves it on neither list", 0, [
        "--command-line=test_exit test_ownership_race",
        "--expect-line=[info] test_ownership_race: 1 test: 1 passed, 0 failed", "--", "-smp", "2"]),
    ("routes a device's interrupts through the I/O APIC", 0, ["--command-line=test_exit test_ioapic",
        "--expect-line=[info] test_ioapic: test the_test_device_is_routed_to_the_boot_cpu ... ok",
        "--expect-line=[info] test_ioapic: test the_test_devices_interrupts_arrive ... ok"]),
    ("gives a thread its CPU budget", 7, [WITH_PROGRAMS, "--command-line=test_exit test_program=test_budgets",
        f"--expect-line={tests_passed('test_budgets', 1)}",
        "--expect-line=[user] root task: test_budgets ended with 0, and its budget is back to nothing", "--", "-smp", "1"]),
    ("runs a CPU budget's threads on its CPUs", 7, [WITH_PROGRAMS, "--command-line=test_exit test_program=test_affinity",
        f"--expect-line={tests_passed('test_affinity', 2)}",
        "--expect-line=[user] root task: test_affinity ended with 0, and its budget is back to nothing", "--", "-smp", "2"]),
    program_test("runs threads of its own, each preempted and with its own vector state", "test_threads", 1),
    program_test("takes system calls on handles", "test_syscalls", 3),
    program_test("waits on ports, wakes them and sets their timers, and refuses a wait with no room", "test_ports", 4),
    program_test("passes handles and messages over channels", "test_channels", 3),
    # And counts who holds a memory object, and says when no one does (decisions/0178)
    program_test("maps memory objects, paid for by budgets, and counts who holds them", "test_memory", 6),
    program_test("splits, sets and destroys CPU budgets", "test_cpu_budgets", 2),
    program_test("reads I/O ports through a range of them", "test_io_ports", 1),
    program_test("ends a program missing a grant, or told another ABI version, as its starter sees", "test_exits", 2),
    program_test("gives an entry's parameters that aren't handles as values", "test_values", 1),
    program_test("streams typed records and bytes between programs, with backpressure", "test_streams", 1),
    program_test("supplies paged memory's pages from a pager in user mode", "test_pager", 3),
    program_test("measures the kernel's benchmarks", "test_perf", 4),
    program_test("drives a device from user mode with the platform capability", "test_devices", 3, "test_device"),
    # QEMU's edu device, its DMA reaching all of memory, which starts at 1 GiB on virt
    program_test("drives a PCIe device's MSI and DMA from user mode", "test_msi_dma", 2,
        qemu=["-device", "edu,dma_mask=0xffffffffff"]),
    # A request that isn't the protocol ends its connection, at the process manager (decisions/0177)
    program_test("sends and checks messages with generated protocol code, and ends a connection a broken request comes on",
                 "test_protocols", 6),
    program_test("binds a typed library from its grant, and calls its exports", "test_libraries", 1),
    ("refuses a typed library whose export's type changed", 7, [WITH_PROGRAMS, "--command-line=test_exit test_changed_library test_program=test_libraries",
        "--expect-line=[user] root task: test_libraries ended with 1, and its budget is back to nothing",
        "--expect-line=[info] objects left: only the kernel's own", "--", "-smp", "2"]),
    program_test("controls a process from a debugger in user mode, with breakpoints, steps and watchpoints, and a launch's intercept of its faults",
                 "test_control", X86_CONTROL_TESTS),
    # The system call fuzzer, every input drawn afresh, as the kernel has no coverage counters (decisions/0186, He)
    program_test("survives the system call fuzzer", "test_fuzz_syscalls", 1),
    ("resumes after an NMI", 0, ["--command-line=test_exit test_nmi", "--expect-line=[info] test_nmi: back from the NMI"]),
    # A CPU spinning with interrupts off is caught by another's tick, and the kernel stops with Lockup (decisions/0183)
    ("catches a CPU that stops making progress", 8, ["--command-line=test_exit test_lockup",
        "--expect-line=[info] test_lockup: CPU 1 spins with interrupts off", "--", "-smp", "2"]),
    # Its registers and stack, from its NMI, kept in the panic record for the next boot (decisions/0185, 12h)
    ("keeps a stuck CPU's registers and stack in the panic record", 7, with_before_qemu(
        [argument.replace("test_services", "test_services panic_reset test_lockup") for argument in BOOT_DISK_BASE], [
        "--allow-reboot", "--expect-line=[info] test_lockup: CPU 1 spins with interrupts off",
        "--expect-line=[info] resetting, the panic record kept",
        "--expect-disk-text=lockup: CPU 1 was at kernel+", "--expect-disk-text=lockup: CPU 1's registers:",
        "--expect-disk-text=lockup: CPU 1's stack:", "--expect-disk-text=  at kernel+",
        "--expect-line=[user] root task: the boot before stopped for a fault: [fatal] lockup: CPU 1 made no progress for 5 seconds"])),
    ("switches between fibers", 0, ["--command-line=test_exit test_fibers",
                                    "--expect-line=[info] test_fibers: 2 tests: 2 passed, 0 failed"]),
    ("shares fiber pools between CPUs", 0, ["--command-line=test_exit test_pool",
        "--expect-line=[info] test_pool: 1 test: 1 passed, 0 failed", "--", "-smp", "6"]),
]

# The same, on the kernel built with morestack
MORESTACK_TESTS = [
    ("grows a fiber's stack onto segments", 0, ["--command-line=test_exit test_segments",
        "--expect-line=[info] test_segments: 1 test: 1 passed, 0 failed"]),
]


# Every test again on AArch64 (tools/boot.py --arch aarch64, always through UEFI), but those that can't apply there:
# x86-64's baseline, and the NMI, which AArch64 has no counterpart for yet (knowledge/decisions/0065)
AARCH64_LEFT_OUT = {"refuses a CPU below x86-64-v3", "resumes after an NMI",
                    "skips a tampered return in the kernel without signed returns or a shadow stack",
                    "skips a branch to no landing pad in the kernel without landing pads",
                    "skips a write to the kernel's shadow stack without one"}
AARCH64_NAMES = {
    "routes a device's interrupts through the I/O APIC": "routes a device's interrupts through the GIC",
}


def aarch64_tests(tests: list, own: bool = True) -> list:
    """
    The tests for AArch64, named so, with AArch64's own baseline check and IOMMU among them; and with own, its own tests,
    which have no x86-64 counterpart.
    """
    lines = {f"--expect-line={X86_IOMMU_LINE}": f"--expect-line={AARCH64_IOMMU_LINE}",
             f"--expect-line={X86_TRANSLATING_LINE}": f"--expect-line={AARCH64_TRANSLATING_LINE}",
             f"--expect-line={X86_CLOCK_LINE}": f"--expect-line={AARCH64_CLOCK_LINE}",
             f"--expect-line={X86_WINDOWS_LINE}": f"--expect-line={AARCH64_WINDOWS_LINE}",
             f"--expect-line={X86_HARDENING_LINE}": f"--expect-line={AARCH64_HARDENING_LINE}",
             f"--expect-line=[user] test_control: {X86_CONTROL_TESTS}": f"--expect-line=[user] test_control: {AARCH64_CONTROL_TESTS}",
             f"--expect-console-line={CRASH_LINE}": f"--expect-console-line={AARCH64_CRASH_LINE}",
             f"--expect-console-line={CRASH_REPORT_LINE}": f"--expect-console-line={AARCH64_CRASH_REPORT_LINE}"}
    adapted = [(f"AArch64: {AARCH64_NAMES.get(name, name)}", expected, [lines.get(argument, argument) for argument in arguments])
               for name, expected, arguments in tests if name not in AARCH64_LEFT_OUT]
    if not own:
        return adapted
    return adapted + [
        # The kernel's own control-flow integrity (decisions/0186, Hd): pointer authentication and BTI refuse each
        ("AArch64: stops at a tampered return in the kernel", 1, ["--command-line=test_exit test_tamper",
            "--expect-line=[info] test_tamper: returning through a tampered return address",
            "--expect-line-start=[fatal] kernel fault: failed authentication at "]),
        ("AArch64: stops at a branch to no landing pad in the kernel", 1, ["--command-line=test_exit test_branch",
            "--expect-line=[info] test_branch: branching into the middle of a function",
            "--expect-line-start=[fatal] kernel fault: branch to no landing pad at "]),
        # And the kernel's Guarded Control Stack an ordinary write
        ("AArch64: refuses a write to the kernel's shadow stack", 1, ["--command-line=test_exit test_shadow_write",
            "--expect-line=[info] test_shadow_write: writing to the kernel's shadow stack",
            "--expect-line-start=[fatal] kernel fault: page fault, write breaking the protection at "]),
        ("AArch64: refuses a CPU below ARMv8.2-A with LSE", 2, ["--cpu=cortex-a57"])]


AARCH64_TESTS = aarch64_tests(TESTS)

# x86-64 through KVM on SLOPOS_KVM_HOST's Linux machine (user@address), with its CPU, which gives CET's shadow stacks
# where TCG gives none (boot.py --kvm, decisions/0186); left out without one. Its machine is this project's: VMware gives
# it shadow stacks and not IBT
KVM_HOST = os.environ.get("SLOPOS_KVM_HOST")
KVM_TESTS = [
    ("KVM: has CET's shadow stacks", 0, ["--expect-line=[boot] cpu: control-flow integrity: shadow stacks yes, indirect branch tracking no"]),
    # A tampered return refused by the shadow stack (decisions/0186); a branch to no landing pad is skipped, with no IBT
    program_test("KVM: refuses a tampered return through the shadow stack", "test_control", "8 tests: 6 passed, 0 failed, 2 skipped"),
]

AARCH64_MORESTACK_TESTS = aarch64_tests(MORESTACK_TESTS, own=False)

# The system call fuzzer on a kernel with coverage counters (decisions/0186, He), which guide it; on the others it
# draws every input afresh (TESTS)
COVERAGE_TESTS = [
    program_test("fuzzes the system calls, guided by the kernel's coverage", "test_fuzz_syscalls", 1),
]
AARCH64_COVERAGE_TESTS = aarch64_tests(COVERAGE_TESTS, own=False)


# Where a failed build's output is kept, since a run's own output may be cut short or filtered
FAILED_BUILD_LOG = ROOT / "build" / "failed_kernel_build.log"


def build_kernel(output: Path, stack_check: str = "trap", architecture: str = "x86_64", coverage: bool = False) -> bool:
    """
    Builds the kernel through the build package, checks and all, with coverage counters for the system call fuzzer if
    asked (coverage=on). If it fails, everything the compiler wrote, with its exit code, is printed and kept in
    FAILED_BUILD_LOG (hemera-feedback.md's build failure seen once, which needs its output to be looked into).
    """
    setting = ",coverage=on" if coverage else ""
    command = ["hemera", f"--setting=targets=kernel,stack_check={stack_check},kernel_output={output},arch={architecture}{setting}",
               str(ROOT / "src" / "build")]
    if os.environ.get("HEMERA_INSTALL"):
        command.insert(1, f"--install-path={os.environ['HEMERA_INSTALL']}")
    result = subprocess.run(command, capture_output=True, text=True)
    sys.stdout.write(result.stdout)
    sys.stdout.write(result.stderr)
    if result.returncode == 0:
        return True
    FAILED_BUILD_LOG.parent.mkdir(parents=True, exist_ok=True)
    with open(FAILED_BUILD_LOG, "a", encoding="utf-8") as log:
        log.write(f"--- {' '.join(command)}\nexit code {result.returncode}\n{result.stdout}{result.stderr}\n")
    print(f"the build's output is kept in {FAILED_BUILD_LOG}")
    return False


def build_tools(output: Path) -> bool:
    """Builds SlopOS's hosted tools through the build package, into the folder output."""
    output.mkdir(parents=True, exist_ok=True)
    command = ["hemera", f"--setting=targets=tools,tools_output={output.as_posix()}", str(ROOT / "src" / "build")]
    if os.environ.get("HEMERA_INSTALL"):
        command.insert(1, f"--install-path={os.environ['HEMERA_INSTALL']}")
    return subprocess.run(command).returncode == 0


def build_programs(output: Path, architecture: str = "x86_64", robustness: bool = False) -> bool:
    """
    Builds SlopOS's programs through the build package, for an architecture, into the folder output; the system call
    fuzzer runs for SLOPOS_FUZZ_SECONDS, if it's set (fuzz_seconds).
    """
    output.mkdir(parents=True, exist_ok=True)
    setting = ",robustness=on" if robustness else ""
    if os.environ.get("SLOPOS_FUZZ_SECONDS"):
        setting += f",fuzz_seconds={int(os.environ['SLOPOS_FUZZ_SECONDS'])}"
    command = ["hemera", f"--setting=targets=programs,programs_output={output.as_posix()},arch={architecture}{setting}",
               str(ROOT / "src" / "build")]
    if os.environ.get("HEMERA_INSTALL"):
        command.insert(1, f"--install-path={os.environ['HEMERA_INSTALL']}")
    return subprocess.run(command).returncode == 0


def main() -> int:
    global PROGRAMS, PROGRAMS_AARCH64, IMAGE_BUILDER
    suite_started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="slopos-boot-tests-") as temporary:
        kernel = Path(temporary) / "kernel.elf"
        if not build_kernel(kernel):
            print("FAILED: the kernel doesn't build")
            return 1
        PROGRAMS = Path(temporary) / "programs"
        if not build_programs(PROGRAMS):
            print("FAILED: the programs don't build")
            return 1
        PROGRAMS_AARCH64 = Path(temporary) / "programs_aarch64"
        if not build_programs(PROGRAMS_AARCH64, "aarch64"):
            print("FAILED: the programs don't build for AArch64")
            return 1
        tools = Path(temporary) / "tools"
        if not build_tools(tools):
            print("FAILED: the tools don't build")
            return 1
        IMAGE_BUILDER = next(tools.glob("image_builder*"))
        morestack_kernel = Path(temporary) / "kernel_morestack.elf"
        if not build_kernel(morestack_kernel, "morestack"):
            print("FAILED: the kernel doesn't build with morestack")
            return 1
        aarch64_kernel = Path(temporary) / "kernel_aarch64.elf"
        if not build_kernel(aarch64_kernel, architecture="aarch64"):
            print("FAILED: the kernel doesn't build for AArch64")
            return 1
        aarch64_morestack_kernel = Path(temporary) / "kernel_aarch64_morestack.elf"
        if not build_kernel(aarch64_morestack_kernel, "morestack", "aarch64"):
            print("FAILED: the kernel doesn't build for AArch64 with morestack")
            return 1
        coverage_kernel = Path(temporary) / "kernel_coverage.elf"
        aarch64_coverage_kernel = Path(temporary) / "kernel_aarch64_coverage.elf"
        if not (build_kernel(coverage_kernel, coverage=True) and build_kernel(aarch64_coverage_kernel, architecture="aarch64", coverage=True)):
            print("FAILED: the kernel doesn't build with coverage counters")
            return 1
        built = time.monotonic() - suite_started
        jobs = (boot_jobs(kernel, TESTS) + boot_jobs(morestack_kernel, MORESTACK_TESTS) + address_jobs(kernel)
                + boot_jobs(coverage_kernel, COVERAGE_TESTS)
                + boot_jobs(aarch64_coverage_kernel, AARCH64_COVERAGE_TESTS, ["--arch=aarch64"])
                + boot_jobs(aarch64_kernel, AARCH64_TESTS, ["--arch=aarch64"])
                + boot_jobs(aarch64_morestack_kernel, AARCH64_MORESTACK_TESTS, ["--arch=aarch64"])
                + address_jobs(aarch64_kernel, ["--arch=aarch64"], "AArch64: "))
        kvm_tests = KVM_TESTS if KVM_HOST else []
        if not KVM_HOST:
            print("the KVM tests are left out: SLOPOS_KVM_HOST isn't set")
        jobs += boot_jobs(kernel, kvm_tests, [f"--kvm={KVM_HOST}"])
        failed = run_jobs(jobs)
        count = len(TESTS) + len(MORESTACK_TESTS) + len(AARCH64_TESTS) + len(AARCH64_MORESTACK_TESTS) + 2 * len(ADDRESS_TESTS)
        count += len(COVERAGE_TESTS) + len(AARCH64_COVERAGE_TESTS)             + len(kvm_tests)
        print_timings(time.monotonic() - suite_started, built)
        if FLAKY:
            print(f"{len(FLAKY)} flaky, failing among the others and passing alone: " + "; ".join(FLAKY))
        print(f"{count - failed} of {count} passed")
        return 0 if failed == 0 else 1


def print_timings(total: float, built: float) -> None:
    """
    The whole run's time, the builds' before the tests, the tests' added up (more than the time they took, in parallel),
    and the slowest tests, to see where it goes.
    """
    tested = sum(TIMINGS.values())
    print(f"took {total / 60:.1f} min: {built / 60:.1f} building, {(total - built) / 60:.1f} booting {len(TIMINGS)} tests, "
          f"{JOBS} at once, {tested / 60:.1f} of test time added up")
    for name, seconds in sorted(TIMINGS.items(), key=lambda item: item[1], reverse=True)[:12]:
        print(f"  {seconds:6.1f} s  {name}")


# Where the kernel says it is: its image, its direct map and its window (decisions/0021)
ADDRESS_LINES = ["[boot] kernel image at ", "[boot] kernel page tables active: ", "[boot] kernel window at "]

# Name, whether two boots should be at different addresses, and boot.py's arguments for both
ADDRESS_TESTS = [
    ("randomizes its addresses (KASLR)", True, []),
    ("keeps its addresses without KASLR", False, ["--no-kaslr"]),
]


def addresses(kernel: Path, arguments: list, output: list) -> list | None:
    """Boots kernel, and gives the lines that say where it is, or None if it didn't halt as usual, its output in output."""
    result = subprocess.run([sys.executable, str(BOOT), f"--kernel={kernel}", "--timeout=60", "--expect=0",
                             *boot_arguments(arguments, [])], capture_output=True, text=True)
    if result.returncode != 0:
        output.append(result.stdout + result.stderr)
        return None
    # Only the kernel's own addresses: where the firmware put the image physically is its choice, and can differ between boots
    return [line.split(", physical ")[0] for line in result.stdout.splitlines() if any(line.startswith(prefix) for prefix in ADDRESS_LINES)]


def address_test(kernel: Path, name: str, differ: bool, arguments: list) -> tuple[bool, str]:
    """Boots kernel twice for an address test, comparing where it was: whether it passed, and what to show if not."""
    output: list[str] = []
    first = addresses(kernel, arguments, output)
    second = addresses(kernel, arguments, output)
    passed = first is not None and second is not None and len(first) == len(ADDRESS_LINES) and len(second) == len(first)
    if passed:
        # Every line differs with KASLR, by the image's base, the direct map's offset and the window's; none without
        passed = all((a != b) == differ for a, b in zip(first, second))
    return passed, "".join(output) + f"first boot: {first}\nsecond boot: {second}\n"


def address_jobs(kernel: Path, more: list = [], prefix: str = "") -> list:
    """The address tests, as jobs: a name and what runs it."""
    return [(prefix + name, lambda name=name, differ=differ, arguments=arguments: address_test(kernel, name, differ, more + arguments))
            for name, differ, arguments in ADDRESS_TESTS]


def boot_test(kernel: Path, expected: int, arguments: list) -> tuple[bool, str]:
    """Boots kernel with boot.py's arguments: whether it stopped with expected, and what it printed."""
    result = subprocess.run([sys.executable, str(BOOT), f"--kernel={kernel}", "--timeout=60", f"--expect={expected}",
                             *arguments], capture_output=True, text=True)
    return result.returncode == 0, result.stdout + result.stderr


def boot_jobs(kernel: Path, tests: list, more: list = []) -> list:
    """
    The tests, as jobs booting kernel with more of boot.py's arguments: a name and what runs it. SLOPOS_BOOT_TESTS: only
    the tests whose names have one of these, separated by commas, in them.
    """
    only = [part for part in os.environ.get("SLOPOS_BOOT_TESTS", "").split(",") if part]
    return [(name, lambda expected=expected, arguments=boot_arguments(arguments, more): boot_test(kernel, expected, arguments))
            for name, expected, arguments in tests if not only or any(part in name for part in only)]


def run_jobs(jobs: list) -> int:
    """
    Runs jobs, JOBS at once, the slowest of the last run first, and gives how many failed: one that fails among the
    others runs again alone, and if it passes then, it's FLAKY, and doesn't count, unless the kernel faulted or a fatal
    error stopped it the first time, which is a bug however rarely it shows.
    """
    try:
        last = json.loads(TIMINGS_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        last = {}
    # Those not timed yet first, as they may be slow
    ordered = sorted(jobs, key=lambda job: last.get(job[0], float("inf")), reverse=True)
    failing: list = []

    def run(job) -> None:
        name, runner = job
        started = time.monotonic()
        passed, output = runner()
        TIMINGS[name] = time.monotonic() - started
        with PRINTING:
            if passed:
                print(f"passed: {name} ({TIMINGS[name]:.1f} s)", flush=True)
            elif JOBS == 1:
                print(f"FAILED: {name} ({TIMINGS[name]:.1f} s)")
                sys.stdout.write(output)
                sys.stdout.flush()
            else:
                print(f"failed among the others, to boot again alone: {name} ({TIMINGS[name]:.1f} s)", flush=True)
            if not passed:
                failing.append((job, output))

    with ThreadPoolExecutor(max_workers=JOBS) as pool:
        list(pool.map(run, ordered))
    failed = 0
    for (name, runner), first_output in failing:
        if JOBS == 1:
            failed += 1
            continue
        started = time.monotonic()
        passed, output = runner()
        if passed and "[fatal]" in first_output:
            failed += 1
            print(f"FAILED: {name}, with a fatal error among the others, though it passed alone; among the others it printed:")
            sys.stdout.write(first_output)
        elif passed:
            FLAKY.append(name)
            print(f"FLAKY: {name}, passed alone ({time.monotonic() - started:.1f} s); among the others it printed:")
            sys.stdout.write(first_output)
        else:
            failed += 1
            print(f"FAILED: {name}, alone too ({time.monotonic() - started:.1f} s)")
            sys.stdout.write(output)
        sys.stdout.flush()
    try:
        TIMINGS_FILE.write_text(json.dumps({**last, **TIMINGS}, indent=1), encoding="utf-8")
    except OSError:
        pass
    return failed


def run_tests(kernel: Path, tests: list, more: list = []) -> int:
    """Boots kernel for each test, with more of boot.py's arguments, and gives how many failed."""
    return run_jobs(boot_jobs(kernel, tests, more))


# Robustness sweeps (knowledge/decisions/0096, 0104): `boot_tests.py --robustness`

# boot.py's codes for a run that didn't stop by itself (tools/boot.py)
TIMED_OUT = 124
NO_EXIT_CODE = 125
# StopReason's codes a swept run may end with (src/kernel/stop.hsc): halted, out of memory, the root task ended
HALTED, OUT_OF_MEMORY, ROOT_TASK_ENDED = 0, 6, 7
# Every pass up to SWEEP_BOUND fails in turn, then about SWEEP_BEYOND more, evenly spread over the rest
SWEEP_BOUND = 48
SWEEP_BEYOND = 48
# Swept runs at once, each its own QEMU
SWEEP_WORKERS = 8
# How long a test program has before the root task kills it (its test_deadline), and a run before it's a hang
TEST_DEADLINE_SECONDS = 20
SWEEP_TIMEOUT_SECONDS = 150

# Name, the kernel command line's words besides fail=, and boot.py's other arguments
SWEEP_TESTS = [
    ("the kernel boots alone", "test_exit", []),
    *[(f"{program}", f"test_exit test_deadline={TEST_DEADLINE_SECONDS} test_program={program}", [WITH_PROGRAMS, "--", "-smp", "2"])
      for program in ["test_channels", 3, "test_threads", "test_control", "test_exits"]],
]


# The reads and writes a faulty block connection fails (faulty_block=<kind>:<n>): every one of the first few, then some
FAULTY_BLOCKS = [*[f"write:{n}" for n in [*range(1, 13), 16, 24, 32, 48, 64, 96]], *[f"tear:{n}" for n in [*range(1, 7), 12, 24, 48]],
                 *[f"read:{n}" for n in [*range(1, 7), 12, 24, 48]]]


def sweep_faulty(kernel: Path, more: list = [], label: str = "") -> int:
    """A boot from the image builder's disk for each of FAULTY_BLOCKS: how many runs went wrong."""
    from concurrent.futures import ThreadPoolExecutor
    disk = [WITH_PROGRAMS, WITH_IMAGE_BUILDER, "--boot-disk", "--disk=SlopOS disk check: from the host"]

    def one(fault: str) -> tuple:
        code, output = boot_once(kernel, f"test_exit test_services faulty_block={fault}", disk, more)
        return fault, judge(code, output), output

    failed = 0
    with ThreadPoolExecutor(max_workers=SWEEP_WORKERS) as pool:
        for fault, problem, output in pool.map(one, FAULTY_BLOCKS):
            if problem is not None:
                failed += 1
                print(f"FAILED: {label}faulty_block={fault}: {problem}")
                logged = [line for line in output.splitlines() if line.startswith("[")]
                sys.stdout.write("".join(f"    {line}\n" for line in logged[-30:]))
    print(f"{'passed' if failed == 0 else 'FAILED'}: {label}a faulty block connection: {len(FAULTY_BLOCKS) - failed} of "
          f"{len(FAULTY_BLOCKS)} runs")
    return failed


def sweep_values(passes: int) -> list:
    """The passes a sweep fails, one run each: every one up to SWEEP_BOUND, then a stride through the rest."""
    values = list(range(1, min(passes, SWEEP_BOUND) + 1))
    if passes > SWEEP_BOUND:
        stride = max(1, (passes - SWEEP_BOUND) // SWEEP_BEYOND)
        values += list(range(SWEEP_BOUND + stride, passes + 1, stride))
    return values


def boot_once(kernel: Path, words: str, arguments: list, more: list) -> tuple:
    """Boots kernel with words on its command line: the code it stopped with, and its serial output."""
    arguments = boot_arguments(arguments, more)
    command = [sys.executable, str(BOOT), f"--kernel={kernel}", f"--timeout={SWEEP_TIMEOUT_SECONDS}", f"--command-line={words}",
               *arguments]
    result = subprocess.run(command, capture_output=True, text=True, errors="replace")
    return result.returncode, result.stdout


def judge(code: int, output: str) -> str | None:
    """
    Why a swept run went wrong, or None if it's what a failed allocation may end in: the kernel halted, stopped for want of
    memory, or saw the root task end (with whatever code) and nothing of anyone else's left behind.
    """
    lines = output.splitlines()
    if code == TIMED_OUT:
        return "it hung"
    if code == ROOT_TASK_ENDED:
        if "[info] objects left: only the kernel's own" not in lines:
            return "objects were left once the root task ended"
        return None
    if code in (HALTED, OUT_OF_MEMORY):
        # A robustness kernel checks a root task that didn't start left nothing behind
        if any(line.startswith("[error] objects left:") for line in lines):
            return "objects were left once the root task didn't start"
        return None
    return {NO_EXIT_CODE: "QEMU ended without an exit code"}.get(code, f"the kernel stopped with {code}")


def passes_of(output: str) -> int | None:
    """The passes through every failure point a fail=count run made, from its report (src/robustness)."""
    for line in output.splitlines():
        if line.startswith("[info] faults: passes "):
            return int(line.rsplit("all ", 1)[1])
    return None


def sweep(kernel: Path, name: str, words: str, arguments: list, more: list = [], label: str = "") -> int:
    """Counts a test's passes, then fails each chosen pass in a run of its own: how many runs went wrong."""
    from concurrent.futures import ThreadPoolExecutor
    code, output = boot_once(kernel, f"{words} fail=count", arguments, more)
    passes = passes_of(output)
    problem = judge(code, output)
    if passes is None or problem is not None:
        print(f"FAILED: {label}{name}: the counting run went wrong ({problem or 'no pass count'})")
        logged = [line for line in output.splitlines() if line.startswith("[")]
        sys.stdout.write("".join(f"    {line}\n" for line in logged[-40:]))
        return 1
    values = sweep_values(passes)

    def one(value: int) -> tuple:
        code, output = boot_once(kernel, f"{words} fail=any:{value}", arguments, more)
        return value, judge(code, output), output

    failed = 0
    with ThreadPoolExecutor(max_workers=SWEEP_WORKERS) as pool:
        for value, problem, output in pool.map(one, values):
            if problem is not None:
                failed += 1
                print(f"FAILED: {label}{name}, fail=any:{value}: {problem}")
                failing = [line for line in output.splitlines() if "faults:" in line or line.startswith("[fatal]")
                           or line.startswith("[error]") or "stopped by a fault" in line]
                sys.stdout.write("".join(f"    {line}\n" for line in failing[-30:]))
    print(f"{'passed' if failed == 0 else 'FAILED'}: {label}{name}: {len(values) - failed} of {len(values)} runs, "
          f"failing passes up to {passes}")
    return failed


def build_robustness_kernel(output: Path, architecture: str) -> bool:
    """The kernel with robustness=on (decisions/0096), which fail= on its command line can make fail."""
    command = ["hemera", f"--setting=targets=kernel,robustness=on,kernel_output={output},arch={architecture}", str(ROOT / "src" / "build")]
    if os.environ.get("HEMERA_INSTALL"):
        command.insert(1, f"--install-path={os.environ['HEMERA_INSTALL']}")
    return subprocess.run(command).returncode == 0


def robustness() -> int:
    """
    The sweeps: for each test in SWEEP_TESTS, on both architectures, a run that counts the passes through the failure
    points, then runs that fail one each, which must each end as judge allows. SLOPOS_BOOT_TESTS chooses tests by name,
    as for the boot tests.
    """
    global PROGRAMS, PROGRAMS_AARCH64, IMAGE_BUILDER
    only = [part for part in os.environ.get("SLOPOS_BOOT_TESTS", "").split(",") if part]
    with tempfile.TemporaryDirectory(prefix="slopos-robustness-") as temporary:
        PROGRAMS = Path(temporary) / "programs"
        PROGRAMS_AARCH64 = Path(temporary) / "programs_aarch64"
        kernel = Path(temporary) / "kernel.elf"
        aarch64_kernel = Path(temporary) / "kernel_aarch64.elf"
        if not (build_programs(PROGRAMS, robustness=True) and build_programs(PROGRAMS_AARCH64, "aarch64", robustness=True)
                and build_robustness_kernel(kernel, "x86_64") and build_robustness_kernel(aarch64_kernel, "aarch64")):
            print("FAILED: the robustness kernels or the programs don't build")
            return 1
        tools = Path(temporary) / "tools"
        if not build_tools(tools):
            print("FAILED: the tools don't build")
            return 1
        IMAGE_BUILDER = next(tools.glob("image_builder*"))
        # Every boot test once more on the robustness kernels, whose counters start near their wraps (R2, decisions/0105)
        failed = run_tests(kernel, TESTS) + run_tests(aarch64_kernel, AARCH64_TESTS, ["--arch=aarch64"])
        for name, words, arguments in SWEEP_TESTS:
            if only and not any(part in name for part in only):
                continue
            failed += sweep(kernel, name, words, arguments)
            failed += sweep(aarch64_kernel, name, words, arguments, ["--arch=aarch64"], "AArch64: ")
        if not only or any(part in "a faulty block connection" for part in only):
            failed += sweep_faulty(kernel)
            failed += sweep_faulty(aarch64_kernel, ["--arch=aarch64"], "AArch64: ")
        print("every test and sweep passed" if failed == 0 else f"{failed} tests and swept runs went wrong")
        return 0 if failed == 0 else 1


if __name__ == "__main__":
    JOBS = jobs_wanted()
    sys.exit(robustness() if "--robustness" in sys.argv[1:] else main())
