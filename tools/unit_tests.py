"""
Builds and runs every package's tests (decisions/0033, Tests): each test/ folder under src/ is a
package whose main returns 0 if everything worked, or the number of the first check that failed.
They're hosted programs, built for this machine by SlopOS's build package (src/build, targets=tests)
with Hemera's compiler (hemera on the PATH, or HEMERA), so they test code that doesn't need ring 0,
like the frame allocator over a buffer.

SlopOS's programs are built first (targets=programs), and each test is given the folder they're in,
for tests that read one, like the ELF loader's.

With --robustness it sweeps the tests in SWEPT instead (knowledge/decisions/0096, 0104): built with robustness=on, each
runs once counting its allocations and failure points (SLOPOS_FAIL=count, src/robustness/hosted), then once for each
chosen allocation or pass, failing it.
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


# Robustness sweeps (knowledge/decisions/0096, 0104): `unit_tests.py --robustness`

# The tests swept, which run their checks through robustness/hosted's run
SWEPT = ["frames_test", "slab_test", "gpt_test", "fat_test", "elf_loader_test", "slopfs_test"]
# Every allocation or pass up to SWEEP_BOUND fails in turn, then about SWEEP_BEYOND more, evenly spread over the rest
SWEEP_BOUND = 64
SWEEP_BEYOND = 64
SWEEP_WORKERS = 12
# A run's code is a check's number; anything this big or more is a crash, not a check
LARGEST_CHECK = 999


def sweep_values(count: int) -> list:
    """What a sweep fails, a run each: every one up to SWEEP_BOUND, then a stride through the rest."""
    values = list(range(1, min(count, SWEEP_BOUND) + 1))
    if count > SWEEP_BOUND:
        stride = max(1, (count - SWEEP_BOUND) // SWEEP_BEYOND)
        values += list(range(SWEEP_BOUND + stride, count + 1, stride))
    return values


def run_failing(test: Path, programs: Path, fail: str) -> tuple:
    """Runs test with SLOPOS_FAIL=fail: its code, and what robustness/hosted said ({"allocations": .., "live": .., "points": ..})."""
    environment = dict(os.environ, SLOPOS_FAIL=fail)
    try:
        result = subprocess.run([str(test), str(programs)], env=environment, capture_output=True, text=True, errors="replace",
                                timeout=TEST_SECONDS)
    except subprocess.TimeoutExpired:
        return None, {}
    said = {}
    lines = (result.stdout + result.stderr).splitlines()
    # An assertion that memory ran out, made by the test's own code (a *_test.hsc file), not by what it tests
    for at, line in enumerate(lines):
        if line.startswith("assertion failed:") and "out of memory" in line and at + 1 < len(lines) and "_test.hsc:" in lines[at + 1]:
            said["harness"] = True
    for line in lines:
        if "faults: allocations " in line:
            allocations, live = line.split("faults: allocations ", 1)[1].split(", live ")
            said["allocations"], said["live"] = int(allocations), int(live)
        if "faults: points " in line:
            said["points"] = int(line.split("faults: points ", 1)[1])
    return result.returncode, said


def robustness() -> int:
    """
    The hosted sweeps: each test in SWEPT, built with robustness=on, runs once counting, then once for each allocation
    chosen, failing it, and each pass through a frame allocator's failure points, failing that. Each run must end with a
    check's code, not crash or hang; one that ends with 0, finishing despite the failure, must leave no more blocks
    allocated than the counting run did (one that stopped at a failed check skipped its own cleanup).
    """
    from concurrent.futures import ThreadPoolExecutor
    hemera = find_hemera()
    with tempfile.TemporaryDirectory(prefix="slopos-tests-robustness-") as temporary:
        programs = Path(temporary) / "programs"
        programs.mkdir()
        if not build(hemera, f"targets=programs,programs_output={programs.as_posix()}"):
            print("FAILED: the programs don't build")
            return 1
        if not build(hemera, f"targets=tests,robustness=on,tests_output={Path(temporary).as_posix()}"):
            print("FAILED: the tests don't build with robustness=on")
            return 1
        suffix = ".exe" if sys.platform == "win32" else ""
        failed = 0
        for name in SWEPT:
            test = Path(temporary) / (name + suffix)
            code, counted = run_failing(test, programs, "count")
            if code != 0 or "allocations" not in counted:
                print(f"FAILED: {name}: the counting run ended with {code}")
                failed += 1
                continue
            runs = [f"alloc:{value}" for value in sweep_values(counted["allocations"])]
            runs += [f"point:{value}" for value in sweep_values(counted.get("points", 0))]

            def one(fail: str) -> tuple:
                return (fail, *run_failing(test, programs, fail))

            wrong = 0
            with ThreadPoolExecutor(max_workers=SWEEP_WORKERS) as pool:
                for fail, code, said in pool.map(one, runs):
                    problem = None
                    if code is None:
                        problem = "it hung"
                    elif said.get("harness"):
                        problem = None
                    elif code < 0 or code > LARGEST_CHECK or "live" not in said:
                        problem = f"it crashed ({code})"
                    # A test that stopped at a failed check skipped its own cleanup; one that finished must have freed as much
                    elif code == 0 and said["live"] > counted["live"]:
                        problem = f"it left {said['live'] - counted['live']} more blocks allocated"
                    if problem is not None:
                        wrong += 1
                        print(f"FAILED: {name}, SLOPOS_FAIL={fail}: {problem}")
            print(f"{'passed' if wrong == 0 else 'FAILED'}: {name}: {len(runs) - wrong} of {len(runs)} runs, "
                  f"{counted['allocations']} allocations and {counted.get('points', 0)} passes")
            failed += wrong
        print("every sweep passed" if failed == 0 else f"{failed} swept runs went wrong")
        return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(robustness() if "--robustness" in sys.argv[1:] else main())
