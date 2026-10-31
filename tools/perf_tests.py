"""
SlopOS's benchmarks (roadmap Perf, 9c5, knowledge/decisions/0097, 0112): builds the kernel, the programs and the tools,
as tools/boot_tests.py does, and boots, for each architecture, test_perf (the kernel's numbers) and a boot from the image
builder's disk (boot to healthy, a program's start from the bundle store, a file made and synced on slopfs), each line
"perf: <name> <nanoseconds>".

Each boots twice: under QEMU's -icount, where a guest nanosecond is an instruction, so the numbers are counts, held to
the baselines in tools/perf_baselines.json, failing past MARGIN above one; and as usual, wall time, which is noisy on a
shared host and only reported. With --update, the counts become the baselines. Only the kernel's numbers (GATED) are held
to theirs: the rest wait on the disk, whose requests finish in the host's time even under -icount. On x86-64, QEMU stops a guest under
-icount ("Bad icount read"), so its numbers are only wall time, reported, until it doesn't (decisions/0112).

    python tools/perf_tests.py
    python tools/perf_tests.py --update
"""

import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

import boot_tests

ROOT = Path(__file__).resolve().parent.parent
BOOT = ROOT / "tools" / "boot.py"
BASELINES = ROOT / "tools" / "perf_baselines.json"
# How far above its baseline a count may go
MARGIN = 0.10
# Each guest instruction one nanosecond of the guest's clock, which idles forward rather than waiting for the host's
ICOUNT = ["-icount", "shift=0,sleep=off"]
PERF_LINE = re.compile(r"perf: (\w+) (\d+)")
NAMES = ["ipc_round_trip", "page_fault", "thread_create", "process_create", "file_create_sync", "program_start",
         "boot_to_healthy"]
# What's held to its baseline: the kernel's, whose counts repeat. The rest wait on the disk, whose requests finish in the
# host's time even under -icount, so their counts move by tens of percent from one boot to the next: reported only
GATED = ["ipc_round_trip", "page_fault", "thread_create", "process_create"]


def boots(kernel: Path, programs: Path, image_builder: Path, more: list) -> list:
    """The boots that measure: test_perf alone, on one CPU, and a boot from the image builder's disk."""
    return [
        [f"--kernel={kernel}", f"--programs={programs}", "--timeout=600", "--expect=7",
         "--command-line=test_exit test_program=test_perf", "--expect-line=[user] test_perf: measured ipc_round_trip, page_fault, "
         "thread_create and process_create", *more],
        [f"--kernel={kernel}", f"--programs={programs}", f"--image-builder={image_builder}", "--boot-disk", "--timeout=900", "--expect=7",
         "--command-line=test_exit test_services", "--disk=SlopOS disk check: from the host", *more],
    ]


def measure(kernel: Path, programs: Path, image_builder: Path, more: list, icount: bool, folder: Path) -> dict | None:
    """Every number the boots say, by name: null if one didn't end as it should."""
    numbers = {}
    for index, arguments in enumerate(boots(kernel, programs, image_builder, more)):
        serial = folder / f"serial_{index}_{'icount' if icount else 'wall'}.txt"
        command = [sys.executable, str(BOOT), *arguments, f"--serial={serial}", "--", *(ICOUNT if icount else []), "-smp", "1"]
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode != 0:
            sys.stdout.write(result.stdout)
            sys.stdout.write(result.stderr)
            return None
        for line in serial.read_text(errors="replace").splitlines():
            found = PERF_LINE.search(line)
            if found:
                numbers[found.group(1)] = int(found.group(2))
    return numbers


def main() -> int:
    update = "--update" in sys.argv[1:]
    baselines = json.loads(BASELINES.read_text()) if BASELINES.exists() else {}
    failed = 0
    with tempfile.TemporaryDirectory(prefix="slopos-perf-") as temporary:
        folder = Path(temporary)
        tools = folder / "tools"
        if not boot_tests.build_tools(tools):
            print("FAILED: the tools don't build")
            return 1
        image_builder = next(tools.glob("image_builder*"))
        for architecture, more, counted in [("x86_64", [], False), ("aarch64", ["--arch=aarch64"], True)]:
            kernel = folder / f"kernel_{architecture}.elf"
            programs = folder / f"programs_{architecture}"
            if not boot_tests.build_kernel(kernel, architecture=architecture) or not boot_tests.build_programs(programs, architecture):
                print(f"FAILED: {architecture} doesn't build")
                return 1
            times = measure(kernel, programs, image_builder, more, False, folder)
            counts = measure(kernel, programs, image_builder, more, True, folder) if counted else {}
            if counts is None or times is None:
                print(f"FAILED: {architecture}: a boot that measures didn't end as it should")
                failed += 1
                continue
            known = baselines.setdefault(architecture, {})
            for name in NAMES:
                if not counted:
                    if name in times:
                        print(f"measured: {architecture}: {name}: {times[name]} ns, wall time only")
                    else:
                        print(f"FAILED: {architecture}: {name} wasn't measured")
                        failed += 1
                    continue
                count = counts.get(name)
                if count is None:
                    print(f"FAILED: {architecture}: {name} wasn't measured")
                    failed += 1
                    continue
                time = times.get(name, 0)
                baseline = known.get(name)
                if update or baseline is None:
                    known[name] = count
                    print(f"recorded: {architecture}: {name}: {count} instructions ({time} ns)")
                elif name not in GATED:
                    print(f"measured: {architecture}: {name}: {count} instructions, against {baseline}, not held to it ({time} ns)")
                elif count > baseline * (1 + MARGIN):
                    print(f"FAILED: {architecture}: {name}: {count} instructions, {count / baseline - 1:.0%} over {baseline} ({time} ns)")
                    failed += 1
                else:
                    note = "; under the baseline by more than the margin, which --update records" if count < baseline * (1 - MARGIN) else ""
                    print(f"passed: {architecture}: {name}: {count} instructions against {baseline} ({time} ns){note}")
    if update or failed == 0:
        BASELINES.write_text(json.dumps(baselines, indent=4, sort_keys=True) + "\n")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
