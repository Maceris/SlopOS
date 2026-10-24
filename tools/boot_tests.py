"""
Builds SlopOS's kernel once, through its build package (src/build), then boots it for each test
below with tools/boot.py and checks the code it stops with (src/kernel/stop.hsc, StopReason). Tests
of growing stacks get a second kernel, built with morestack (the build package's stack_check).
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
# SlopOS's programs, built once, carried as modules by the tests whose arguments have WITH_PROGRAMS
PROGRAMS = Path()
WITH_PROGRAMS = "<programs>"

# Name, the code expected, and boot.py's arguments
TESTS = [
    ("boots and halts (BIOS)", 0, ["--expect-line=[info] boot memory reclaimed"]),
    ("starts the root task, which reports and ends", 7, [WITH_PROGRAMS, "--expect-line=[boot] module root_task.elf",
        "--expect-line=[boot] module hello.elf", "--expect-line=[user] root task: started, with 3 grants",
        "--expect-line=[user] root task: hello.elf mapped, heap working, seeded: true",
        "--expect-line=[info] root task ended with code 0"]),
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
    ("runs user threads on every CPU", 0, ["--command-line=test_exit test_threads",
        "--expect-line=[info] test_threads: 4 user threads on 2 CPUs, each preempted and run again, each with its own vector state",
        "--", "-smp", "2"]),
    ("gives a thread its CPU budget", 0, ["--command-line=test_exit test_budgets",
        "--expect-line=[info] test_budgets: the budgeted thread got its budget at its priority, then shared the background"]),
    ("takes system calls on handles", 0, ["--command-line=test_exit test_syscalls",
        "--expect-line=[info] test_syscalls: handles were looked up, copied, refused, closed and went stale; threads and processes made and destroyed",
        "--expect-line=[info] test_syscalls: destroying the process freed everything it owned, after a grace period",
        "--", "-smp", "2"]),
    ("waits on ports, wakes them and sets their timers", 0, ["--command-line=test_exit test_ports",
        "--expect-line=[info] test_ports: wakes, timers, deadlines and other threads woke waiters; closing the port woke the last",
        "--expect-line=[info] test_ports: destroying the process freed its ports and their bindings",
        "--", "-smp", "2"]),
    ("passes handles and messages over channels", 0, ["--command-line=test_exit test_channels",
        "--expect-line=[info] test_channels: handles moved, messages went through the kernel and the rings, doorbells and Once bindings woke the right waiters, and closing an end reached the other",
        "--expect-line=[info] test_channels: destroying the processes freed their channels, ports and bindings",
        "--", "-smp", "2"]),
    ("maps memory objects, paid for by budgets", 0, ["--command-line=test_exit test_memory",
        "--expect-line=[info] test_memory: budgets split and closed, memory filled as it was touched and shared between mappings, and a write it didn't allow stopped the thread",
        "--expect-line=[info] test_memory: destroying the process freed its memory, its mappings and its budgets, and gave the root budget back what it paid for",
        "--", "-smp", "2"]),
    ("drives a device from user mode with the platform capability", 0, ["--command-line=test_exit test_devices",
        "--expect-line=[info] test_devices: a driver registered a controller, took an IRQ's interrupts through its port, read device memory, and lost a window with its memory",
        "--expect-line=[info] test_devices: destroying the process freed its IRQs, its device memory and its windows",
        "--", "-smp", "2"]),
    ("controls a process from a debugger in user mode", 0, ["--command-line=test_exit test_control",
        "--expect-line=[info] test_control: a debugger skipped and answered a call, changed a result, fixed a fault, read and wrote memory, suspended and resumed a thread, and killed the process it watched; a process ended itself, and its code came with its end",
        "--expect-line=[info] test_control: destroying the debugger freed its intercept, and the target's threads",
        "--", "-smp", "2"]),
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


# Where a failed build's output is kept, since a run's own output may be cut short or filtered
FAILED_BUILD_LOG = ROOT / "build" / "failed_kernel_build.log"


def build_kernel(output: Path, stack_check: str = "trap") -> bool:
    """
    Builds the kernel through the build package, checks and all. If it fails, everything the compiler
    wrote, with its exit code, is printed and kept in FAILED_BUILD_LOG (hemera-feedback.md's build
    failure seen once, which needs its output to be looked into).
    """
    command = ["hemera", f"--setting=targets=kernel,stack_check={stack_check},kernel_output={output}", str(ROOT / "src" / "build")]
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


def build_programs(output: Path) -> bool:
    """Builds SlopOS's programs through the build package, into the folder output."""
    output.mkdir(parents=True, exist_ok=True)
    command = ["hemera", f"--setting=targets=programs,programs_output={output.as_posix()}", str(ROOT / "src" / "build")]
    if os.environ.get("HEMERA_INSTALL"):
        command.insert(1, f"--install-path={os.environ['HEMERA_INSTALL']}")
    return subprocess.run(command).returncode == 0


def main() -> int:
    global PROGRAMS
    with tempfile.TemporaryDirectory(prefix="slopos-boot-tests-") as temporary:
        kernel = Path(temporary) / "kernel.elf"
        if not build_kernel(kernel):
            print("FAILED: the kernel doesn't build")
            return 1
        PROGRAMS = Path(temporary) / "programs"
        if not build_programs(PROGRAMS):
            print("FAILED: the programs don't build")
            return 1
        morestack_kernel = Path(temporary) / "kernel_morestack.elf"
        if not build_kernel(morestack_kernel, "morestack"):
            print("FAILED: the kernel doesn't build with morestack")
            return 1
        failed = run_tests(kernel, TESTS) + run_tests(morestack_kernel, MORESTACK_TESTS) + run_address_tests(kernel)
        count = len(TESTS) + len(MORESTACK_TESTS) + len(ADDRESS_TESTS)
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
    return [line for line in result.stdout.splitlines() if any(line.startswith(prefix) for prefix in ADDRESS_LINES)]


def run_address_tests(kernel: Path) -> int:
    """Boots kernel twice for each address test, comparing where it was, and gives how many failed."""
    failed = 0
    for name, differ, arguments in ADDRESS_TESTS:
        first = addresses(kernel, arguments)
        second = addresses(kernel, arguments)
        passed = first is not None and second is not None and len(first) == len(ADDRESS_LINES) and len(second) == len(first)
        if passed:
            # Every line differs with KASLR, by the image's base, the direct map's offset and the window's; none without
            passed = all((a != b) == differ for a, b in zip(first, second))
        print(f"{'passed' if passed else 'FAILED'}: {name}")
        if not passed:
            failed += 1
            print(f"first boot: {first}")
            print(f"second boot: {second}")
    return failed


def run_tests(kernel: Path, tests: list) -> int:
    """Boots kernel for each test, and gives how many failed."""
    failed = 0
    for name, expected, arguments in tests:
        arguments = [f"--programs={PROGRAMS}" if argument == WITH_PROGRAMS else argument for argument in arguments]
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
