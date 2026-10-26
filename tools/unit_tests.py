"""
Builds and runs every package's tests (decisions/0033, Tests): each test/ folder under src/ is a
package whose main returns 0 if everything worked, or the number of the first check that failed.
They're hosted programs, built for this machine by SlopOS's build package (src/build, targets=tests)
with Hemera's compiler (hemera on the PATH, or HEMERA), so they test code that doesn't need ring 0,
like the frame allocator over a buffer.

SlopOS's programs are built first (targets=programs), and each test is given the folder they're in,
for tests that read one, like the ELF loader's.
"""

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# How long a test may take, so one that hangs, as a fuzzed image could make it, fails rather than stops the run
TEST_SECONDS = 900


def find_hemera() -> str:
    found = os.environ.get("HEMERA") or shutil.which("hemera")
    if found is None:
        sys.exit("unit_tests.py: can't find Hemera's compiler: put hemera on the PATH, or set HEMERA")
    return found


def build(hemera: str, settings: str) -> bool:
    """Runs SlopOS's build package with settings, and whether it worked."""
    command = [hemera, f"--setting={settings}", str(ROOT / "src" / "build")]
    if os.environ.get("HEMERA_INSTALL"):
        command.insert(1, f"--install-path={os.environ['HEMERA_INSTALL']}")
    return subprocess.run(command).returncode == 0


def main() -> int:
    hemera = find_hemera()
    with tempfile.TemporaryDirectory(prefix="slopos-tests-") as temporary:
        programs = Path(temporary) / "programs"
        programs.mkdir()
        if not build(hemera, f"targets=programs,programs_output={programs.as_posix()}"):
            print("FAILED: the programs don't build")
            return 1
        if not build(hemera, f"targets=tests,tests_output={Path(temporary).as_posix()}"):
            print("FAILED: the tests don't build")
            return 1
        # The build package names each test program after the package it tests, <package>_test
        suffix = ".exe" if sys.platform == "win32" else ""
        tests = sorted(path for path in Path(temporary).iterdir() if path.name.endswith("_test" + suffix))
        failed = 0
        for test in tests:
            name = test.name.removesuffix(suffix)
            try:
                code = subprocess.run([str(test), str(programs)], timeout=TEST_SECONDS).returncode
            except subprocess.TimeoutExpired:
                print(f"FAILED: {name}, still running after {TEST_SECONDS} seconds")
                failed += 1
                continue
            if code == 0:
                print(f"passed: {name}")
            else:
                print(f"FAILED: {name}, check {code}")
                failed += 1
        if not tests:
            print("FAILED: no tests were built")
            return 1
    print(f"{len(tests) - failed} of {len(tests)} passed")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
