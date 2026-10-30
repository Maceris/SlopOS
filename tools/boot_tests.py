"""
Builds SlopOS's kernel once, through its build package (src/build), then boots it for each test
below with tools/boot.py and checks the code it stops with (src/kernel/stop.hsc, StopReason). Tests
of growing stacks get a second kernel, built with morestack (the build package's stack_check), and the
AArch64 tests kernels built for AArch64 (its arch setting), the same two ways.
Exits 0 if every test passed. SLOPOS_BOOT_TESTS, names separated by commas, runs only the tests whose names have one of
them in them.

    python tools/boot_tests.py
"""

import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BOOT = ROOT / "tools" / "boot.py"
# SlopOS's programs, built once for each architecture, carried as modules by the tests whose arguments have WITH_PROGRAMS
PROGRAMS = Path()
PROGRAMS_AARCH64 = Path()
WITH_PROGRAMS = "<programs>"
# The image builder, built once, for the tests whose arguments have WITH_IMAGE_BUILDER (decisions/0088)
IMAGE_BUILDER = Path()
WITH_IMAGE_BUILDER = "<image builder>"


def program_test(name: str, program: str, line: str, words: str = "", qemu: list = []) -> tuple:
    """
    A test program the root task runs (src/tests, knowledge/decisions/0069) on 2 CPUs, with more QEMU arguments if it
    needs a device: it says line and ends with 0, its budget is back to nothing, and once the root task has ended, only
    the kernel's own objects are left.
    """
    command_line = f"test_exit {words} test_program={program}" if words else f"test_exit test_program={program}"
    return (name, 7, [WITH_PROGRAMS, f"--command-line={command_line}", f"--expect-line=[user] {program}: {line}",
                      f"--expect-line=[user] root task: {program} ended with 0, and its budget is back to nothing",
                      "--expect-line=[info] objects left: only the kernel's own", "--", "-smp", "2", *qemu])


# What the kernel says of the IOMMU QEMU gives each machine (src/kernel/iommus.hsc)
X86_IOMMU_LINE = "[info] IOMMU 0: VT-d, 4 KiB of registers at 0x00000000fed90000, version 1.0, 48-bit I/O addresses"
AARCH64_IOMMU_LINE = "[info] IOMMU 0: SMMUv3, 128 KiB of registers at 0x0000000009050000, version 3.1, 44-bit I/O addresses"
# How it translates (src/kernel/translation.hsc): VT-d remapping interrupts too, and signalling its faults; SMMUv3 not
# What test_io_ports says: x86-64 has ports, AArch64 none
X86_PORTS_LINE = "[user] test_io_ports: the RTC's status read through its ports, and ports outside them refused"
AARCH64_PORTS_LINE = "[user] test_io_ports: no ports here, and every range refused"
# The real-time clock the platform service finds: the MC146818 on x86-64, and the device tree's PL031 on AArch64
X86_CLOCK_LINE = "[user] platform: the real-time clock (Mc146818) claimed"
AARCH64_CLOCK_LINE = "[user] platform: the real-time clock (Pl031) claimed"
X86_TRANSLATING_LINE = "[info] IOMMU 0: translating, 256 interrupts remapped, its faults to CPU 0's interrupt 48"
AARCH64_TRANSLATING_LINE = "[info] IOMMU 0: translating, 0 interrupts remapped, its faults read at CPU 0's ticks"

# Name, the code expected, and boot.py's arguments
# What booting from the image builder's disk checks: the disk's five partitions, the FAT server on its EFI system
# partition, which Limine was read from, and the disk check's lines and writes, as on the test disk
BOOT_DISK_ARGUMENTS = [WITH_PROGRAMS, WITH_IMAGE_BUILDER, "--boot-disk", "--timeout=120",
    "--command-line=test_exit test_services", "--disk=SlopOS disk check: from the host",
    "--expect-line=[user] virtio_blk: serving 206848 blocks",
    "--expect-line=[user] partition_server: 5 partitions on a disk of 206848 blocks",
    "--expect-line=[user] storage: disk 0 partition 0: SlopOS check, 2048 blocks from 2048",
    "--expect-line=[user] storage: disk 0 partition 2: BIOS boot, 2048 blocks from 6144",
    "--expect-line=[user] storage: disk 0 partition 3: EFI system partition, 131072 blocks from 8192",
    "--expect-line=[user] storage: disk 0 partition 4: SlopOS system, 65536 blocks from 139264",
    "--expect-line=[user] storage: started a FAT server for disk 0 partition 3",
    "--expect-line=[user] fat_server: serving a FAT32 volume of 128992 clusters of 512 bytes",
    "--expect-line=[user] storage: started a container service for disk 0 partition 4",
    "--expect-line=[user] storage: started a volume server for the system volume",
    "--expect-line=[user] volume_server: serving volume 1 (system), from transaction 3",
    "--expect-line=[user] supervisor: console from the system volume", "--expect-line=[user] supervisor: hello from the system volume",
    "--expect-line=[user] supervisor: disk_check from the system volume", "--expect-line=[user] hello: heap working, random numbers working",
    "--expect-line=[user] disk_check: on the EFI system partition, read the host's files, wrote, moved and read back its own, "
    "listed 3, and was refused a path above it",
    "--expect-line=[user] disk_check: narrowed EFI/SlopOS to read only, selected 2 of its files by *.TXT, and was refused a "
    "file made in the set",
    "--expect-line=[user] disk_check: on the system volume, read modules/hello.elf as the EFI system partition has it, wrote, "
    "synced and read back its own file, and moved it",
    "--expect-line=[user] disk_check: on the system volume, replaced an open file, committed a transaction, was refused a conflicting "
    "one, had a failing one leave nothing, and followed every change",
    "--expect-line=[user] storage: started a volume server for the sealed volume, encrypted",
    "--expect-line=[user] volume_server: volume 2 unlocked",
    "--expect-line=[user] volume_server: volume 2 sealing with key generation 2",
    "--expect-line=[user] disk_check: on the sealed volume, was refused locked and with a wrong passphrase, unlocked it, read its "
    "file, wrote one, started key generation 2, wrote another and read all three",
    "--expect-line=[user] disk_check: links: the system volume wrote and read through two from the sealed one; what one reached "
    "granted nothing; one revoked opened nothing",
    "--expect-line=[user] disk_check: snapshots: read one of the system volume as it was, read only, wrote to its clone, couldn't "
    "delete it while cloned, and read one of the sealed volume",
    "--expect-line=[user] disk_check: quotas: its clone's refused a file past it and took a small one, and its usage says so",
    "--expect-disk-block=2049=SlopOS disk check: from the guest", "--expect-disk-text=Written by the guest, through std's files",
    "--expect-disk-text=Written to the system volume by the guest, and synced",
    # What the encrypted volume's files hold, as the image builder and the disk check wrote them, is nowhere on the disk
    "--refuse-disk-text=ONLY ITS PASSPHRASE OPENS THIS",
    "--refuse-disk-text=WRITTEN TO THE SEALED VOLUME WITH ITS FIRST KEY GENERATION",
    "--refuse-disk-text=WRITTEN TO THE SEALED VOLUME WITH ITS SECOND KEY GENERATION",
    "--expect-line=[info] root task ended with code 0", "--", "-smp", "2"]



def with_before_qemu(arguments: list[str], more: list[str]) -> list[str]:
    """boot.py's arguments with more added before those it passes on to QEMU, after "--"."""
    split = arguments.index("--") if "--" in arguments else len(arguments)
    return arguments[:split] + more + arguments[split:]


TESTS = [
    ("boots and halts (BIOS)", 0, ["--expect-line=[info] boot memory reclaimed"]),
    ("starts the first services from the root task", 7, [WITH_PROGRAMS, "--command-line=test_exit test_services",
        "--expect-line=[boot] module root_task.elf", "--expect-line=[user] root task: started, with 37 grants",
        "--expect-line=[user] entropy: serving", "--expect-line=[user] root task: started process_manager",
        "--expect-line=[user] scheduler: 3 budgets and the default split off the root's, 800000 of its 1000000 millionths of a CPU",
        "--expect-line=[user] root task: started scheduler",
        "--expect-line=[user] process manager: started supervisor", "--expect-line=[user] process manager: started hello",
        "--expect-line=[user] hello: heap working, random numbers working", "--expect-line=[user] root task: the supervisor started hello",
        "--expect-line=[user] platform: serving", "--expect-line=[user] root task: the supervisor started all 4 of its services",
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
    # A virtio console whose other end boot.py types into: hello's line through the console service, and an echo
    ("shows lines on a virtio console, and echoes what's typed into it", 7, [WITH_PROGRAMS,
        "--command-line=test_exit test_services", "--console-input=ping from the host",
        "--expect-line=[user] virtio_console: serving", "--expect-line=[user] console: read ping from the host",
        "--expect-console-line=SlopOS console", "--expect-console-line=hello: heap and random numbers working",
        "--expect-console-line=echo: ping from the host", "--expect-line=[info] root task ended with code 0", "--", "-smp", "2"]),
    # A virtio keyboard boot.py types on through QEMU's machine protocol: keys as HID usages, typed by the console's keymap
    ("types on a virtio keyboard into the console", 7, [WITH_PROGRAMS,
        "--command-line=test_exit test_services", "--keyboard-input=Hi there, 42!",
        "--expect-line=[user] virtio_input: serving", "--expect-line=[user] console: read Hi there, 42!",
        "--expect-console-line=echo: Hi there, 42!", "--expect-line=[info] root task ended with code 0", "--", "-smp", "2"]),
    # The console's driver killed once the console has dialed it: restarted with its device reissued, and dialed again
    ("restarts a driver that's killed, and its client dials it again", 7, [WITH_PROGRAMS,
        "--command-line=test_exit test_services test_restart", "--console-input=before the restart",
        "--console-input=after the restart", "--expect-line=[user] supervisor: test_restart: killing virtio_console",
        "--expect-line=[user] supervisor: restarted virtio_console", "--expect-line=[user] console: its serial line went; dialing again",
        "--expect-line=[user] console: read after the restart", "--expect-console-line=echo: after the restart",
        "--expect-line=[info] root task ended with code 0", "--", "-smp", "2"]),
    # A GPT disk image boot.py marks, whose partitions the storage manager's partition server finds; the disk check reads,
    # writes, flushes and reads back its partition, is refused a block past it, and the image holds what it wrote after;
    # then, through std's files, it reads, writes, moves and lists files on the EFI system partition boot.py wrote with
    # FAT32, through a FAT server the storage manager starts
    ("reads and writes a virtio disk through the block protocol", 7, [WITH_PROGRAMS,
        "--command-line=test_exit test_services", "--disk=SlopOS disk check: from the host",
        "--expect-line=[user] virtio_blk: serving 77824 blocks",
        "--expect-line=[user] partition_server: 3 partitions on a disk of 77824 blocks",
        "--expect-line=[user] storage: disk 0 partition 0: SlopOS check, 2048 blocks from 2048",
        "--expect-line=[user] storage: disk 0 partition 1: SlopOS spare, 2048 blocks from 4096",
        "--expect-line=[user] storage: disk 0 partition 2: EFI system partition, 69632 blocks from 6144",
        "--expect-line=[user] storage: started a FAT server for disk 0 partition 2",
        "--expect-line=[user] fat_server: serving a FAT32 volume of 68512 clusters of 512 bytes",
        "--expect-line=[user] disk_check: in SlopOS check, 2048 blocks from 2048 of disk 0, read the host's mark, wrote, flushed and "
        "read back block 1, read 8 blocks at once, and was refused the block past its end",
        "--expect-line=[user] disk_check: on the EFI system partition, read the host's files, wrote, moved and read back its own, "
        "listed 3, and was refused a path above it",
        "--expect-line=[user] disk_check: narrowed EFI/SlopOS to read only, selected 2 of its files by *.TXT, and was refused a "
        "file made in the set",
        "--expect-disk-block=2049=SlopOS disk check: from the guest", "--expect-disk-text=Written by the guest, through std's files",
        "--expect-line=[info] root task ended with code 0", "--", "-smp", "2"]),
    # Booted from a disk the image builder made rather than the ISO: Limine read from its EFI system partition, its
    # BIOS boot partition for BIOS, loading only the boot set; the storage stack finding its partitions and its SlopOS
    # container, every other program read from the system volume, and the disk check passing on it as on the test disk
    ("boots from a disk the image builder made", 7, BOOT_DISK_ARGUMENTS),
    ("boots from a disk the image builder made, through UEFI", 7, ["--uefi"] + BOOT_DISK_ARGUMENTS),
    # Behind a root port, with firmware's bus numbers and BARs taken as unset
    ("numbers buses and places BARs behind a bridge", 7, [WITH_PROGRAMS,
        "--command-line=test_exit test_services test_reassign", "--expect-line=[user] platform: 1:0.0 (6900 4164) claimed",
        "--expect-line=[user] virtio_rng: serving, a source of the entropy service's",
        "--expect-line=[user] entropy: reseeded from a hardware source, 32 bytes", "--expect-line=[info] root task ended with code 0",
        "--", "-smp", "2", "-device", "pcie-root-port,id=bridge,chassis=1,slot=1", "-device", "virtio-rng-pci,bus=bridge,disable-legacy=on,iommu_platform=on"]),
    ("keeps a program running after the process manager ends", 7, [WITH_PROGRAMS,
        "--command-line=test_exit test_outlive_manager", "--expect-line=[user] root task: killing process_manager",
        "--expect-line=[user] root task: process_manager was killed",
        "--expect-line=[user] hello: still running after the process manager ended",
        "--expect-line=[user] root task: the supervisor's hello ended with 0", "--expect-line=[info] root task ended with code 0"]),
    ("keeps the time with the real-time clock, and sets it", 7, [WITH_PROGRAMS,
        "--command-line=test_exit test_services test_clock", f"--expect-line={X86_CLOCK_LINE}",
        "--expect-line=[user] clock: serving",
        "--expect-line=[user] clock: set to 2030-01-02 03:04:05 UTC, and the real-time clock reads it back",
        "--expect-line=[user] hello: the wall clock says it's 2030-01-02", "--expect-line=[info] root task ended with code 0"]),
    ("keeps every program's log records on the system volume once it's there", 7, with_before_qemu(
        [argument.replace("test_services", "test_services test_events") for argument in BOOT_DISK_ARGUMENTS], [
        "--expect-line=[user] events: serving",
        "--expect-line=[user] supervisor: test_events: the waiting query got hello's record 0: heap working, random numbers working",
        "--expect-line=[user] supervisor: test_events: hello's record 0 read back from the system volume: heap working, random numbers working",
        "--expect-line=[user] supervisor: test_events: clock's record 1 read back from the system volume: serving"])),
    ("starts the events service, the clock service and the storage manager again when they're killed", 7, with_before_qemu(
        [argument.replace("test_services", "test_services test_restart_services") for argument in BOOT_DISK_ARGUMENTS], [
        "--expect-line=[user] supervisor: test_restart_services: killing events", "--expect-line=[user] supervisor: restarted events",
        "--expect-line=[user] supervisor: test_restart_services: killing clock", "--expect-line=[user] supervisor: restarted clock",
        "--expect-line=[user] supervisor: test_restart_services: the clock service, started again, set the time",
        "--expect-line=[user] supervisor: test_restart_services: the events service, started again, has the clock service's record 1: serving",
        "--expect-line=[user] supervisor: test_restart_services: killing storage_manager",
        "--expect-line=[user] supervisor: restarted storage_manager",
        "--expect-line=[user] supervisor: test_restart_services: the storage manager, started again, gave the system volume"])),
    ("doesn't start the root task with no_root_task", 0, [WITH_PROGRAMS, "--command-line=test_exit no_root_task",
        "--expect-line=[info] boot memory reclaimed"]),
    ("boots and halts (UEFI)", 0, ["--uefi", "--expect-line=[info] boot memory reclaimed"]),
    ("reports a kernel fault", 1, ["--command-line=test_exit test_fault"]),
    ("reports a failed assertion", 3, ["--command-line=test_exit test_assert"]),
    ("refuses a CPU below x86-64-v3", 2, ["--cpu=qemu64"]),
    ("starts every CPU", 0, ["--expect-line=[info] 4 of 4 CPUs online", "--expect-line=[info] boot memory reclaimed",
                             "--", "-smp", "4"]),
    ("keeps the kernel's code read-only", 1, ["--command-line=test_exit test_write_code",
                                              "--expect-line=[info] test_write_code: writing to the kernel's code"]),
    ("allocates from the kernel heap", 0, ["--command-line=test_exit test_heap",
        "--expect-line=[info] test_heap: 200 blocks kept their contents, grown, shrunk and freed"]),
    ("keeps time with the counter", 0, ["--command-line=test_exit test_clock",
        "--expect-line=[info] test_clock: 10 ms by the counter is 10 ms by the clock"]),
    ("shoots down TLB entries on every CPU", 0, ["--command-line=test_exit test_shootdown",
        "--expect-line=[info] test_shootdown: every CPU read the new page after the shootdown", "--", "-smp", "4"]),
    ("routes a device's interrupts through the I/O APIC", 0, ["--command-line=test_exit test_ioapic",
        "--expect-line=[info] test_ioapic: 10 interrupts arrived from the test device"]),
    ("gives a thread its CPU budget", 0, ["--command-line=test_exit test_budgets",
        "--expect-line=[info] test_budgets: the budgeted threads shared their budget at its priority, then the background"]),
    program_test("runs threads of its own, each preempted and with its own vector state", "test_threads",
        "4 threads of its own, each preempted and run again, each with its own vector state"),
    program_test("takes system calls on handles", "test_syscalls",
        "handles were looked up, copied, refused, closed and went stale; threads and processes made and destroyed"),
    program_test("waits on ports, wakes them and sets their timers", "test_ports",
        "wakes, timers, deadlines and other threads woke waiters; closing the port woke the last"),
    program_test("passes handles and messages over channels", "test_channels",
        "handles moved, messages went through the kernel and the rings, doorbells and Once bindings woke the right waiters, "
        "and closing an end reached the other"),
    program_test("maps memory objects, paid for by budgets", "test_memory",
        "budgets split and closed, memory filled as it was touched and shared between mappings, and a write it didn't allow "
        "stopped the thread"),
    program_test("splits, sets and destroys CPU budgets", "test_cpu_budgets",
        "budgets split off the root's share and refused past it, set, and destroyed, what ran on them going to their parent"),
    program_test("reads I/O ports through a range of them", "test_io_ports",
        "the RTC's status read through its ports, and ports outside them refused"),
    program_test("supplies paged memory's pages from a pager in user mode", "test_pager",
        "2 pages supplied as they were touched, read at two addresses, and writing them refused"),
    program_test("drives a device from user mode with the platform capability", "test_devices",
        "a driver registered a controller, took an IRQ's interrupts through its port, read device memory, and lost a window "
        "with its memory; IOMMUs that aren't were refused", "test_device"),
    # QEMU's edu device, its DMA reaching all of memory, which starts at 1 GiB on virt
    program_test("drives a PCIe device's MSI and DMA from user mode", "test_msi_dma",
        "edu took its MSI and copied a page through DMA memory, and its device took its IRQs with it",
        qemu=["-device", "edu,dma_mask=0xffffffffff"]),
    program_test("sends and checks messages with generated protocol code", "test_protocols",
        "messages went through with their handles and data, and broken, unknown and mistyped ones were refused"),
    program_test("controls a process from a debugger in user mode", "test_control",
        "a debugger skipped and changed calls, fixed a fault, read and wrote memory, suspended, resumed and started threads, "
        "gave a handle and killed its target; an exit's code came with its end"),
    ("resumes after an NMI", 0, ["--command-line=test_exit test_nmi", "--expect-line=[info] test_nmi: back from the NMI"]),
    ("switches between fibers", 0, ["--command-line=test_exit test_fibers",
                                    "--expect-line=[info] test_fibers: stack traces follow suspended and resumed fibers"]),
    ("shares fiber pools between CPUs", 0, ["--command-line=test_exit test_pool",
        "--expect-line=[info] test_pool: two pools shared five CPUs, each fiber staying on its own pool's", "--", "-smp", "6"]),
]

# The same, on the kernel built with morestack
MORESTACK_TESTS = [
    ("grows a fiber's stack onto segments", 0, ["--command-line=test_exit test_segments",
        "--expect-line=[info] test_segments: stack traces leave out morestack, across segments"]),
]


# Every test again on AArch64 (tools/boot.py --arch aarch64, always through UEFI), but those that can't apply there:
# BIOS, x86-64's baseline, and the NMI, which AArch64 has no counterpart for yet (knowledge/decisions/0065)
AARCH64_LEFT_OUT = {"boots and halts (BIOS)", "refuses a CPU below x86-64-v3", "resumes after an NMI",
                    "boots from a disk the image builder made, through UEFI"}
AARCH64_NAMES = {
    "boots and halts (UEFI)": "boots and halts",
    "routes a device's interrupts through the I/O APIC": "routes a device's interrupts through the GIC",
}


def aarch64_tests(tests: list) -> list:
    """The tests for AArch64, named so, with AArch64's own baseline check and IOMMU among them."""
    lines = {f"--expect-line={X86_IOMMU_LINE}": f"--expect-line={AARCH64_IOMMU_LINE}",
             f"--expect-line={X86_TRANSLATING_LINE}": f"--expect-line={AARCH64_TRANSLATING_LINE}",
             f"--expect-line={X86_PORTS_LINE}": f"--expect-line={AARCH64_PORTS_LINE}",
             f"--expect-line={X86_CLOCK_LINE}": f"--expect-line={AARCH64_CLOCK_LINE}"}
    adapted = [(f"AArch64: {AARCH64_NAMES.get(name, name)}", expected, [lines.get(argument, argument) for argument in arguments])
               for name, expected, arguments in tests if name not in AARCH64_LEFT_OUT]
    return adapted + [("AArch64: refuses a CPU below ARMv8.2-A with LSE", 2, ["--cpu=cortex-a57"])]


AARCH64_TESTS = aarch64_tests(TESTS)

AARCH64_MORESTACK_TESTS = aarch64_tests(MORESTACK_TESTS)[:-1]


# Where a failed build's output is kept, since a run's own output may be cut short or filtered
FAILED_BUILD_LOG = ROOT / "build" / "failed_kernel_build.log"


def build_kernel(output: Path, stack_check: str = "trap", architecture: str = "x86_64") -> bool:
    """
    Builds the kernel through the build package, checks and all. If it fails, everything the compiler
    wrote, with its exit code, is printed and kept in FAILED_BUILD_LOG (hemera-feedback.md's build
    failure seen once, which needs its output to be looked into).
    """
    command = ["hemera", f"--setting=targets=kernel,stack_check={stack_check},kernel_output={output},arch={architecture}",
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


def build_programs(output: Path, architecture: str = "x86_64") -> bool:
    """Builds SlopOS's programs through the build package, for an architecture, into the folder output."""
    output.mkdir(parents=True, exist_ok=True)
    command = ["hemera", f"--setting=targets=programs,programs_output={output.as_posix()},arch={architecture}",
               str(ROOT / "src" / "build")]
    if os.environ.get("HEMERA_INSTALL"):
        command.insert(1, f"--install-path={os.environ['HEMERA_INSTALL']}")
    return subprocess.run(command).returncode == 0


def main() -> int:
    global PROGRAMS, PROGRAMS_AARCH64, IMAGE_BUILDER
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
        failed = run_tests(kernel, TESTS) + run_tests(morestack_kernel, MORESTACK_TESTS) + run_address_tests(kernel)
        aarch64_morestack_kernel = Path(temporary) / "kernel_aarch64_morestack.elf"
        if not build_kernel(aarch64_morestack_kernel, "morestack", "aarch64"):
            print("FAILED: the kernel doesn't build for AArch64 with morestack")
            return 1
        failed += run_tests(aarch64_kernel, AARCH64_TESTS, ["--arch=aarch64"])
        failed += run_tests(aarch64_morestack_kernel, AARCH64_MORESTACK_TESTS, ["--arch=aarch64"])
        failed += run_address_tests(aarch64_kernel, ["--arch=aarch64"], "AArch64: ")
        count = len(TESTS) + len(MORESTACK_TESTS) + len(AARCH64_TESTS) + len(AARCH64_MORESTACK_TESTS) + 2 * len(ADDRESS_TESTS)
        print(f"{count - failed} of {count} passed")
        return 0 if failed == 0 else 1


# Where the kernel says it is: its image, its direct map and its window (decisions/0021)
ADDRESS_LINES = ["[boot] kernel image at ", "[boot] kernel page tables active: ", "[boot] kernel window at "]

# Name, whether two boots should be at different addresses, and boot.py's arguments for both
ADDRESS_TESTS = [
    ("randomizes its addresses (KASLR)", True, []),
    ("keeps its addresses without KASLR", False, ["--no-kaslr"]),
]


def addresses(kernel: Path, arguments: list) -> list | None:
    """Boots kernel, and gives the lines that say where it is, or None if it didn't halt as usual."""
    result = subprocess.run([sys.executable, str(BOOT), f"--kernel={kernel}", "--timeout=60", "--expect=0", *arguments],
                            capture_output=True, text=True)
    if result.returncode != 0:
        sys.stdout.write(result.stdout)
        sys.stdout.write(result.stderr)
        return None
    # Only the kernel's own addresses: where the firmware put the image physically is its choice, and can differ between boots
    return [line.split(", physical ")[0] for line in result.stdout.splitlines() if any(line.startswith(prefix) for prefix in ADDRESS_LINES)]


def run_address_tests(kernel: Path, more: list = [], prefix: str = "") -> int:
    """Boots kernel twice for each address test, comparing where it was, and gives how many failed."""
    failed = 0
    for name, differ, arguments in ADDRESS_TESTS:
        first = addresses(kernel, more + arguments)
        second = addresses(kernel, more + arguments)
        passed = first is not None and second is not None and len(first) == len(ADDRESS_LINES) and len(second) == len(first)
        if passed:
            # Every line differs with KASLR, by the image's base, the direct map's offset and the window's; none without
            passed = all((a != b) == differ for a, b in zip(first, second))
        print(f"{'passed' if passed else 'FAILED'}: {prefix}{name}")
        if not passed:
            failed += 1
            print(f"first boot: {first}")
            print(f"second boot: {second}")
    return failed


def run_tests(kernel: Path, tests: list, more: list = []) -> int:
    """Boots kernel for each test, with more of boot.py's arguments, and gives how many failed."""
    failed = 0
    # SLOPOS_BOOT_TESTS: only the tests whose names have one of these, separated by commas, in them
    only = [part for part in os.environ.get("SLOPOS_BOOT_TESTS", "").split(",") if part]
    for name, expected, arguments in tests:
        if only and not any(part in name for part in only):
            continue
        programs = PROGRAMS_AARCH64 if "--arch=aarch64" in more else PROGRAMS
        arguments = more + [f"--programs={programs}" if argument == WITH_PROGRAMS else
                            f"--image-builder={IMAGE_BUILDER}" if argument == WITH_IMAGE_BUILDER else argument for argument in arguments]
        result = subprocess.run([sys.executable, str(BOOT), f"--kernel={kernel}", "--timeout=60", f"--expect={expected}",
                                 *arguments], capture_output=True, text=True)
        passed = result.returncode == 0
        print(f"{'passed' if passed else 'FAILED'}: {name}")
        if not passed:
            failed += 1
            sys.stdout.write(result.stdout)
            sys.stdout.write(result.stderr)
    return failed


if __name__ == "__main__":
    sys.exit(main())
