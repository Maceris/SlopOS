"""
Fuzzes SlopOS's hosted fuzz targets, each a property test, under Hemera's coverage-guided fuzzer (hemera --fuzz, its
docs/testing.md, Fuzzing; knowledge/decisions/0186, He): each target is built on its own, as hemera --fuzz builds one
test, and run for SLOPOS_FUZZ_SECONDS seconds (60 by default).

Each target's inputs are kept in its own folder under SLOPOS_FUZZ_FOLDER (slopos-fuzz in the system's temporary folder by
default), so a run goes on from what the last one found: corpus/ holds the inputs that reached new code, findings/ those
that failed, which the next run tries first. A finding is fixed, then kept as an ordinary test.

SlopOS's programs are built first, for the targets that read one, like the ELF loader's (SLOPOS_PROGRAMS).

    tools/fuzz.py              every target
    tools/fuzz.py fat elf      the targets whose names have one of these in them

hemera is found on the PATH, or as HEMERA. Ends with 0 if no target found anything, 1 otherwise.
"""

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Name, the test package (a test/ folder), and the property test fuzzed
TARGETS = [
    ("fat", "src/fat/test", "a_volume_damaged_as_drawn_is_used_as_far_as_it_goes_without_crashing"),
    ("slopfs", "src/slopfs/test", "an_image_damaged_as_drawn_is_used_as_far_as_it_goes_without_crashing"),
    ("slopfs_sealed", "src/slopfs/test", "an_encrypted_image_damaged_as_drawn_is_used_as_far_as_it_goes_without_crashing"),
    ("elf_loader", "src/elf_loader/test", "a_changed_file_is_loaded_or_refused_without_crashing"),
    ("aml_random", "src/aml/test", "random_tables_never_fault"),
    ("aml_changed", "src/aml/test", "changed_tables_never_fault"),
    ("aml_qemu", "src/aml/test", "changed_qemu_dsdts_never_fault"),
    ("protocols", "src/protocols/test", "any_bytes_are_judged_without_reading_outside_them"),
]

# How much longer than its fuzzing a target may run, building aside, before it's taken as hung
GRACE_SECONDS = 120


def find_hemera() -> str:
    found = os.environ.get("HEMERA") or shutil.which("hemera")
    if found is None:
        sys.exit("fuzz.py: can't find Hemera's compiler: put hemera on the PATH, or set HEMERA")
    return found


def chosen(names: list) -> list:
    """The targets whose names have one of names in them; every target for none."""
    return [target for target in TARGETS if not names or any(name in target[0] for name in names)]


def fuzz(hemera: str, target: tuple, seconds: int, folder: Path, programs: Path, built: Path) -> bool:
    """Builds one target for fuzzing and runs it: whether it found nothing."""
    name, package, test = target
    suffix = ".exe" if sys.platform == "win32" else ""
    program = built / f"{name}{suffix}"
    command = [hemera, f"--fuzz={test}", f"--fuzz-seconds={seconds}", f"--fuzz-folder={(folder / name).as_posix()}",
               f"--output={program}", str(ROOT / package)]
    if subprocess.run(command).returncode != 0 or not program.exists():
        print(f"FAILED: {name} doesn't build for fuzzing")
        return False
    environment = dict(os.environ, SLOPOS_PROGRAMS=programs.as_posix())
    try:
        code = subprocess.run([str(program)], env=environment, timeout=seconds + GRACE_SECONDS).returncode
    except subprocess.TimeoutExpired:
        print(f"FAILED: {name}, still running {GRACE_SECONDS} seconds past its time")
        return False
    if code == 0:
        print(f"passed: {name}, {seconds} seconds")
        return True
    print(f"FAILED: {name} found something, kept in {folder / name / 'findings'}" if code == 1 else f"FAILED: {name}, ended with {code}")
    return False


def main() -> int:
    hemera = find_hemera()
    seconds = int(os.environ.get("SLOPOS_FUZZ_SECONDS", "60"))
    folder = Path(os.environ.get("SLOPOS_FUZZ_FOLDER") or Path(tempfile.gettempdir()) / "slopos-fuzz")
    targets = chosen(sys.argv[1:])
    if not targets:
        sys.exit(f"fuzz.py: no target is named like {' or '.join(sys.argv[1:])}; they're {', '.join(t[0] for t in TARGETS)}")
    with tempfile.TemporaryDirectory(prefix="slopos-fuzz-") as temporary:
        programs = Path(temporary) / "programs"
        programs.mkdir()
        if subprocess.run([hemera, f"--setting=targets=programs,programs_output={programs.as_posix()}", str(ROOT / "src" / "build")]).returncode != 0:
            print("FAILED: the programs don't build")
            return 1
        passed = sum(1 for target in targets if fuzz(hemera, target, seconds, folder, programs, Path(temporary)))
    print(f"{passed} of {len(targets)} found nothing")
    return 0 if passed == len(targets) else 1


if __name__ == "__main__":
    sys.exit(main())
