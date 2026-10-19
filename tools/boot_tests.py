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

# Name, the code expected, and boot.py's arguments
TESTS = [
    ("boots and halts (BIOS)", 0, []),
    ("boots and halts (UEFI)", 0, ["--uefi"]),
    ("reports a kernel fault", 1, ["--command-line=test_exit test_fault"]),
    ("reports a failed assertion", 3, ["--command-line=test_exit test_assert"]),
    ("refuses a CPU below x86-64-v3", 2, ["--cpu=qemu64"]),
    ("starts every CPU", 0, ["--expect-line=[info] 4 of 4 CPUs online", "--", "-smp", "4"]),
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


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="slopos-boot-tests-") as temporary:
        kernel = Path(temporary) / "kernel.elf"
        if not build_kernel(kernel):
            print("FAILED: the kernel doesn't build")
            return 1
        morestack_kernel = Path(temporary) / "kernel_morestack.elf"
        if not build_kernel(morestack_kernel, "morestack"):
            print("FAILED: the kernel doesn't build with morestack")
            return 1
        failed = run_tests(kernel, TESTS) + run_tests(morestack_kernel, MORESTACK_TESTS)
        count = len(TESTS) + len(MORESTACK_TESTS)
        print(f"{count - failed} of {count} passed")
        return 0 if failed == 0 else 1


def run_tests(kernel: Path, tests: list) -> int:
    """Boots kernel for each test, and gives how many failed."""
    failed = 0
    for name, expected, arguments in tests:
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
