"""
Profiles boots (decisions/0194, T3): boots boot_tests.py's tests whose names have one of the words given, with
profile_boot on the kernel's command line, and says where their CPUs' ticks went: the kernel samples each tick of each
CPU, in user code or idle, and writes them out once the root task's ended; the root task and the process manager say
where each program's image went. Each sample's program counter is named by the function of the program whose image
holds it, through the program's ELF symbols, and its frame pointers' chain gives the functions it was called from.

    python tools/profile_boot.py [--arch=aarch64] [--runs=N] [--top=N] [--timeline] "words in a test's name" ...

Each test boots N times (default 1), its samples added up. --timeline shows each boot's quarter seconds too: how many
of its CPUs' ticks were busy, and where most of them were. Programs are built into build/profile_boot.
"""
import argparse
import bisect
import re
import struct
import subprocess
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import boot_tests  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
# A tick: its time in microseconds, its CPU, then "idle", or its thread and its frames in hex
SAMPLE = re.compile(r"^\[profile\] (\d+) (\d+) (?:idle|(\d+)((?: [0-9a-f]+)+))$")
DROPPED = re.compile(r"^\[profile\] dropped (\d+)$")
# A timeline's window, in microseconds
WINDOW = 250_000
IMAGE = re.compile(r"^\[user\] (?:root task|process manager): profile: (\S+) at (\d+)$")


class Program:
    """A program's ELF: its image's size and its function symbols, by address from its base."""

    def __init__(self, path: Path):
        data = path.read_bytes()
        self.size = 0
        self.starts: list[int] = []
        self.names: list[str] = []
        if data[:4] != b"\x7fELF":
            return
        phoff, = struct.unpack_from("<Q", data, 0x20)
        shoff, = struct.unpack_from("<Q", data, 0x28)
        phentsize, phnum, shentsize, shnum = struct.unpack_from("<HHHH", data, 0x36)
        for i in range(phnum):
            kind, _flags, _offset, vaddr, _paddr, _filesz, memsz, _align = struct.unpack_from(
                "<IIQQQQQQ", data, phoff + i * phentsize)
            if kind == 1:  # PT_LOAD
                self.size = max(self.size, vaddr + memsz)
        sections = [struct.unpack_from("<IIQQQQIIQQ", data, shoff + i * shentsize) for i in range(shnum)]
        functions = []
        for _name, kind, _flags, _addr, offset, size, link, _info, _align, entsize in sections:
            if kind != 2:  # SHT_SYMTAB
                continue
            strings = sections[link][4]
            for at in range(offset, offset + size, entsize):
                name, info, _other, _shndx, value, _length = struct.unpack_from("<IBBHQQ", data, at)
                if info & 0xF == 2 and value != 0:  # STT_FUNC
                    end = data.index(b"\0", strings + name)
                    functions.append((value, data[strings + name:end].decode("utf-8", "replace")))
        functions.sort()
        self.starts = [value for value, _ in functions]
        self.names = [name for _, name in functions]

    def function(self, offset: int) -> str:
        at = bisect.bisect_right(self.starts, offset) - 1
        return self.names[at] if at >= 0 else f"+{offset:#x}"


def program_file(programs: Path, name: str) -> Path | None:
    """
    The ELF a program's started as, by the name it's started under: as it is, or as a service's, its name and _service,
    the plural's s dropped too (accounts, account_service).
    """
    for candidate in (name, f"{name}_service", name.removesuffix("_service"), f"{name.removesuffix('s')}_service"):
        path = programs / f"{candidate}.elf"
        if path.is_file():
            return path
    return None


def profile(output: str, programs: Path, loaded: dict, totals: dict, timeline: bool) -> None:
    """
    Add a boot's samples to totals: self and inclusive counts by function, counts by program, idle and unplaced; and
    with timeline, say the boot's quarter seconds.
    """
    images = []
    for line in output.splitlines():
        found = IMAGE.match(line.strip())
        if found:
            name, base = found.group(1), int(found.group(2))
            if name not in loaded:
                path = program_file(programs, name)
                loaded[name] = Program(path) if path is not None else None
            if loaded[name] is not None:
                images.append((base, base + loaded[name].size, name))
    images.sort()
    starts = [start for start, _, _ in images]

    def place(address: int) -> tuple[str, str] | None:
        at = bisect.bisect_right(starts, address) - 1
        if at < 0 or address >= images[at][1]:
            return None
        start, _, name = images[at]
        return name, loaded[name].function(address - start)

    windows: dict[int, list] = {}
    for line in output.splitlines():
        line = line.strip()
        found = DROPPED.match(line)
        if found:
            totals["dropped"] += int(found.group(1))
            continue
        found = SAMPLE.match(line)
        if not found:
            continue
        window = windows.setdefault(int(found.group(1)) // WINDOW, [0, 0, Counter()])
        window[0] += 1
        if found.group(3) is None:
            totals["idle"] += 1
            continue
        window[1] += 1
        frames = [int(word, 16) for word in found.group(4).split()]
        totals["samples"] += 1
        first = place(frames[0])
        # The innermost frame that isn't a system call's wrapper names what the tick was in better
        named = next((placed for placed in map(place, frames) if placed is not None and "system_call" not in placed[1]
                      and "slop_os_call" not in placed[1]), first)
        window[2][f"{named[0]}: {named[1]}" if named is not None else "(unplaced)"] += 1
        if first is None:
            totals["unplaced"] += 1
            continue
        totals["programs"][first[0]] += 1
        totals["self"][f"{first[0]}: {first[1]}"] += 1
        seen = set()
        for frame in frames:
            placed = place(frame)
            if placed is not None and placed not in seen:
                seen.add(placed)
                totals["inclusive"][f"{placed[0]}: {placed[1]}"] += 1
    if timeline and windows:
        print("  time     ticks busy  where most busy ticks were")
        for index in range(min(windows), max(windows) + 1):
            ticks, busy, where = windows.get(index, [0, 0, Counter()])
            most = ", ".join(f"{name} {count}" for name, count in where.most_common(2))
            print(f"  {index * WINDOW / 1e6:6.2f} s {ticks:5} {busy:4}  {most}")


def main() -> int:
    parser = argparse.ArgumentParser(description="profile boot tests' boots")
    parser.add_argument("--arch", choices=["x86_64", "aarch64"], default="x86_64")
    parser.add_argument("--runs", type=int, default=1, help="boots of each test, their samples added up")
    parser.add_argument("--top", type=int, default=40, help="functions said, the most sampled")
    parser.add_argument("--timeline", action="store_true", help="say each boot's quarter seconds too")
    parser.add_argument("--cpus", type=int, help="boot with this many CPUs rather than the test's (QEMU's -smp)")
    parser.add_argument("words", nargs="+", help="words in the names of the tests to boot")
    arguments = parser.parse_args()
    aarch64 = arguments.arch == "aarch64"

    built = ROOT / "build" / "profile_boot"
    kernel = built / f"kernel_{arguments.arch}.elf"
    programs = built / f"programs_{arguments.arch}"
    tools = built / "tools"
    if not (boot_tests.build_kernel(kernel, architecture=arguments.arch) and boot_tests.build_programs(programs, arguments.arch)
            and boot_tests.build_tools(tools)):
        print("profile_boot.py: the build failed")
        return 1
    boot_tests.PROGRAMS = programs if not aarch64 else boot_tests.PROGRAMS
    boot_tests.PROGRAMS_AARCH64 = programs if aarch64 else boot_tests.PROGRAMS_AARCH64
    boot_tests.IMAGE_BUILDER = next(tools.glob("image_builder*"))

    tests = boot_tests.AARCH64_TESTS if aarch64 else boot_tests.TESTS
    chosen = [(name, expected, arguments_of) for name, expected, arguments_of in tests
              if any(word in name for word in arguments.words)]
    if not chosen:
        print("profile_boot.py: no test's name has those words")
        return 1
    more = ["--arch=aarch64"] if aarch64 else []
    totals = {"samples": 0, "idle": 0, "dropped": 0, "unplaced": 0, "programs": Counter(), "self": Counter(),
              "inclusive": Counter()}
    loaded: dict = {}
    for name, expected, test_arguments in chosen:
        given = [argument.replace("--command-line=", "--command-line=profile_boot ", 1)
                 if argument.startswith("--command-line=") else argument
                 for argument in boot_tests.boot_arguments(test_arguments, more)]
        if arguments.cpus is not None and "-smp" in given:
            given[given.index("-smp") + 1] = str(arguments.cpus)
        if not any(argument.startswith("--command-line=") for argument in given):
            given.insert(0, "--command-line=test_exit profile_boot")
        for run in range(arguments.runs):
            result = subprocess.run([sys.executable, str(boot_tests.BOOT), f"--kernel={kernel}", "--timeout=180",
                                     f"--expect={expected}", *given], capture_output=True, text=True)
            took = re.search(r"took .*", result.stderr)
            print(f"{'passed' if result.returncode == 0 else 'FAILED'}: {name}, run {run + 1}"
                  f"{', ' + took.group(0) if took else ''}")
            profile(result.stdout, programs, loaded, totals, arguments.timeline)

    samples = totals["samples"]
    print(f"\n{samples} samples in user code, {totals['idle']} idle, {totals['unplaced']} of them not in a program's image "
          f"(a library's, or a program not said), {totals['dropped']} dropped")
    if samples == 0:
        return 0
    print("\nBy program:")
    for program, count in totals["programs"].most_common(arguments.top):
        print(f"  {count:6} {100 * count / samples:5.1f}%  {program}")
    print("\nBy function, where the tick was:")
    for function, count in totals["self"].most_common(arguments.top):
        print(f"  {count:6} {100 * count / samples:5.1f}%  {function}")
    print("\nBy function, with what it called:")
    for function, count in totals["inclusive"].most_common(arguments.top):
        print(f"  {count:6} {100 * count / samples:5.1f}%  {function}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
