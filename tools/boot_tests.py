"""
Builds SlopOS's kernel once, through its build package (src/build), then boots it for each test
below with tools/boot.py and checks the code it stops with (src/kernel/stop.hsc, StopReason). Tests
of growing stacks get a second kernel, built with morestack (the build package's stack_check), and the
AArch64 tests kernels built for AArch64 (its arch setting), the same two ways.
Exits 0 if every test passed.

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


# Name, the code expected, and boot.py's arguments
TESTS = [
    ("boots and halts (BIOS)", 0, ["--expect-line=[info] boot memory reclaimed"]),
    ("starts the first services from the root task", 7, [WITH_PROGRAMS, "--command-line=test_exit test_services",
        "--expect-line=[boot] module root_task.elf", "--expect-line=[user] root task: started, with 17 grants",
        "--expect-line=[user] entropy: serving", "--expect-line=[user] root task: started process_manager",
        "--expect-line=[user] process manager: started supervisor", "--expect-line=[user] process manager: started hello",
        "--expect-line=[user] hello: heap working, random numbers working", "--expect-line=[user] root task: the supervisor started hello",
        "--expect-line=[info] root task ended with code 0"]),
    ("keeps a program running after the process manager ends", 7, [WITH_PROGRAMS,
        "--command-line=test_exit test_outlive_manager", "--expect-line=[user] root task: killing process_manager",
        "--expect-line=[user] root task: process_manager was killed",
        "--expect-line=[user] hello: still running after the process manager ended",
        "--expect-line=[user] root task: the supervisor's hello ended with 0", "--expect-line=[info] root task ended with code 0"]),
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
        "--expect-line=[info] test_budgets: the budgeted thread got its budget at its priority, then shared the background"]),
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
    program_test("drives a device from user mode with the platform capability", "test_devices",
        "a driver registered a controller, took an IRQ's interrupts through its port, read device memory, and lost a window "
        "with its memory", "test_device"),
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
AARCH64_LEFT_OUT = {"boots and halts (BIOS)", "refuses a CPU below x86-64-v3", "resumes after an NMI"}
AARCH64_NAMES = {
    "boots and halts (UEFI)": "boots and halts",
    "routes a device's interrupts through the I/O APIC": "routes a device's interrupts through the GIC",
}


def aarch64_tests(tests: list) -> list:
    """The tests for AArch64, named so, with AArch64's own baseline check among them."""
    adapted = [(f"AArch64: {AARCH64_NAMES.get(name, name)}", expected, arguments)
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


def build_programs(output: Path, architecture: str = "x86_64") -> bool:
    """Builds SlopOS's programs through the build package, for an architecture, into the folder output."""
    output.mkdir(parents=True, exist_ok=True)
    command = ["hemera", f"--setting=targets=programs,programs_output={output.as_posix()},arch={architecture}",
               str(ROOT / "src" / "build")]
    if os.environ.get("HEMERA_INSTALL"):
        command.insert(1, f"--install-path={os.environ['HEMERA_INSTALL']}")
    return subprocess.run(command).returncode == 0


def main() -> int:
    global PROGRAMS, PROGRAMS_AARCH64
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
    for name, expected, arguments in tests:
        programs = PROGRAMS_AARCH64 if "--arch=aarch64" in more else PROGRAMS
        arguments = more + [f"--programs={programs}" if argument == WITH_PROGRAMS else argument for argument in arguments]
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
