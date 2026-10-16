"""
Boots the kernel once for each test below with tools/boot.py, and checks the code it stops with
(src/kernel/stop.hsc, StopReason). Exits 0 if every test passed.

    python tools/boot_tests.py
"""

import subprocess
import sys
from pathlib import Path

BOOT = Path(__file__).resolve().parent / "boot.py"

# Name, the code expected, and boot.py's arguments
TESTS = [
    ("boots and halts (BIOS)", 0, []),
    ("boots and halts (UEFI)", 0, ["--uefi"]),
    ("reports a kernel fault", 1, ["--command-line=test_exit test_fault"]),
    ("reports a failed assertion", 3, ["--command-line=test_exit test_assert"]),
    ("refuses a CPU below x86-64-v3", 2, ["--cpu=qemu64"]),
    ("starts every CPU", 0, ["--expect-line=[info] 4 of 4 CPUs online", "--", "-smp", "4"]),
]


def main() -> int:
    failed = 0
    for name, expected, arguments in TESTS:
        result = subprocess.run([sys.executable, str(BOOT), "--timeout=60", f"--expect={expected}", *arguments],
                                capture_output=True, text=True)
        passed = result.returncode == 0
        print(f"{'passed' if passed else 'FAILED'}: {name}")
        if not passed:
            failed += 1
            sys.stdout.write(result.stdout)
            sys.stdout.write(result.stderr)
    print(f"{len(TESTS) - failed} of {len(TESTS)} passed")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
