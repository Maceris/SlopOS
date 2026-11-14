"""
Fuzzes SlopOS's hosted fuzz targets, each a property test, under Hemera's coverage-guided fuzzer (hemera --fuzz, its
docs/testing.md, Fuzzing; knowledge/decisions/0186, He): each target is built on its own, as hemera --fuzz builds one
test, and run for SLOPOS_FUZZ_SECONDS seconds (60 by default).

Each target's inputs are kept in its own folder under SLOPOS_FUZZ_FOLDER (slopos-fuzz in the system's temporary folder by
default), so a run goes on from what the last one found: corpus/ holds the inputs that reached new code, findings/ those
that failed, which the next run tries first. A finding is fixed, then kept as an ordinary test.

SlopOS's programs are built first, for the targets that read one, like the ELF loader's (SLOPOS_PROGRAMS).

The network's targets (decisions/0188, 13h) are the stack's, in src/net_stack/test, and, for what it's built on in
Hemera's std, Hemera's own scenarios: TLS, NTS, X.509, DER and PEM, and the network policies. Those are found under
Hemera's source, HEMERA_SOURCE, or else where the compiler's in it (apps/compiler/bin/<build>/hemera).

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
    # The network (decisions/0188, 13h)
    ("frames", "src/net_stack/test", "takes_any_checksummed_frames"),
    ("tcp_peer", "src/net_stack/test", "withstands_a_hostile_peer"),
    ("dns_answers", "src/net_stack/test", "takes_any_answer"),
    ("tls_flight", "hemera:apps/compiler/test/back_end/scenarios/tls", "refuses_a_changed_flight"),
    ("nts_ke", "hemera:apps/compiler/test/back_end/scenarios/ntp", "reads_any_ke_records"),
    ("der", "hemera:apps/compiler/test/back_end/scenarios/x509", "reads_any_der"),
    ("x509_chain", "hemera:apps/compiler/test/back_end/scenarios/x509", "refuses_any_changed_chain"),
    ("pem", "hemera:apps/compiler/test/back_end/scenarios/x509", "reads_any_pem"),
    ("policy", "hemera:apps/compiler/test/back_end/scenarios/network_policy", "narrowing_never_widens"),
    # Remote login (decisions/0191)
    ("ssh_server", "hemera:apps/compiler/test/back_end/scenarios/ssh", "takes_any_bytes"),
    ("ssh_client", "hemera:apps/compiler/test/back_end/scenarios/ssh", "client_takes_any_bytes"),
    ("ssh_keys", "hemera:apps/compiler/test/back_end/scenarios/ssh", "reads_any_keys"),
    # Display and input (decisions/0192)
    ("font_bytes", "hemera:apps/compiler/test/back_end/scenarios/fonts", "reads_any_font_bytes"),
    ("font_changed", "hemera:apps/compiler/test/back_end/scenarios/fonts", "reads_a_changed_font"),
    ("canvas_paths", "hemera:apps/compiler/test/back_end/scenarios/canvas", "draws_any_path"),
    ("ui_input", "hemera:apps/compiler/test/back_end/scenarios/ui", "takes_any_input"),
]

# How much longer than its fuzzing a target may run, building aside, before it's taken as hung
GRACE_SECONDS = 120


def find_hemera() -> str:
    found = os.environ.get("HEMERA") or shutil.which("hemera")
    if found is None:
        sys.exit("fuzz.py: can't find Hemera's compiler: put hemera on the PATH, or set HEMERA")
    return found


def package_path(hemera: str, package: str) -> Path:
    """A target's package: SlopOS's, from its root; or Hemera's, hemera:<path>, from Hemera's source."""
    if not package.startswith("hemera:"):
        return ROOT / package
    source = os.environ.get("HEMERA_SOURCE")
    root = Path(source) if source else Path(hemera).resolve().parents[4]
    return root / package.removeprefix("hemera:")


def chosen(names: list) -> list:
    """The targets whose names have one of names in them; every target for none."""
    return [target for target in TARGETS if not names or any(name in target[0] for name in names)]


def fuzz(hemera: str, target: tuple, seconds: int, folder: Path, programs: Path, built: Path) -> bool:
    """Builds one target for fuzzing and runs it: whether it found nothing."""
    name, package, test = target
    suffix = ".exe" if sys.platform == "win32" else ""
    program = built / f"{name}{suffix}"
    command = [hemera, f"--fuzz={test}", f"--fuzz-seconds={seconds}", f"--fuzz-folder={(folder / name).as_posix()}",
               f"--output={program}", str(package_path(hemera, package))]
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
