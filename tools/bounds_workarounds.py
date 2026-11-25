"""Find code that works around the bounds proof (decisions/0198, B4), to see what's left of it.

Each shape below is something people wrote because the bounds proof couldn't prove what they meant, before the
bounds checker's B1 to B3: a count beside a fixed array checked against it again and again, which #at_most now says
once; a minimum written as an if expression and a second guard beside it; an index modulo its own array's count. Not
every match is a workaround: a ring buffer's index modulo its size is the point. It's a list to read, not to apply.

Usage: python -I tools/bounds_workarounds.py [--show N] [folder...]
With no folder, SlopOS's src and, beside it, Hemera's std and base, if HEMERA_ROOT names Hemera's checkout.
"""
import argparse
import os
import re
import sys
from pathlib import Path

SLOPOS = Path(__file__).resolve().parent.parent

# A count field checked against an array field of the same struct, through one path: a.count <= a.items.count
RECHECK = re.compile(r"\b([\w.]+)\.(\w*count)\s*(<=|<)\s*\1\.(\w+)\.count\b")
SHAPES = {
    "an index modulo its own array's count": re.compile(r"(\w+)\[\s*\w+\s*%\s*\1\.count\s*\]"),
    "a constant index modulo a count": re.compile(r"\[\s*\d+\s*%\s*[\w.]+\.count\s*\]"),
    "a loop's index checked against two counts": re.compile(r"if\s+i\s*<\s*[\w.]+\.count\s*&&\s*i\s*<\s*[\w.]+\.count"),
    "a counter checked against its own buffer before a slice": re.compile(r"if\s+(\w+)_count\s*>\s*\1\.count\s*\{"),
    "a min_count helper": re.compile(r"\bmin_count\("),
}
# A struct's field declaration: name : type
FIELD = re.compile(r"^\s+(\w+)(\s+#at_most\([^)]*\))?\s*:\s*([^,=]+)")
STRUCT = re.compile(r"^(\w+)\s*::\s*struct\b")
FIXED_ARRAY = re.compile(r"\[[^\]\[]+\]\s*$")


def structs_in(path: Path):
    """Each struct in a file: its name, and its fields' names, types and whether they've #at_most."""
    found = {}
    name = None
    for line in path.read_text(encoding="utf-8", errors="replace").split("\n"):
        start = STRUCT.match(line)
        if start:
            name = start.group(1)
            found[name] = {}
            continue
        if name is not None:
            if line.startswith("}"):
                name = None
                continue
            field = FIELD.match(line)
            if field:
                found[name][field.group(1)] = (field.group(3).strip(), field.group(2) is not None)
    return found


def main() -> int:
    parser = argparse.ArgumentParser(description="Find code that works around the bounds proof.")
    parser.add_argument("--show", type=int, default=5, help="examples shown of each shape")
    parser.add_argument("folders", nargs="*")
    arguments = parser.parse_args()
    folders = [Path(folder) for folder in arguments.folders]
    if not folders:
        folders = [SLOPOS / "src"]
        hemera = os.environ.get("HEMERA_ROOT")
        if hemera:
            folders += [Path(hemera) / "std", Path(hemera) / "base"]
    files = [path for folder in folders for path in folder.rglob("*.hsc")]

    # Structs with a count beside a fixed array, which code checks against it: candidates for #at_most
    declared = {}
    for path in files:
        for struct, fields in structs_in(path).items():
            declared.setdefault(struct, []).append((path, fields))
    pairs = {}
    hits = {name: [] for name in SHAPES}
    for path in files:
        for number, line in enumerate(path.read_text(encoding="utf-8", errors="replace").split("\n"), 1):
            for match in RECHECK.finditer(line):
                pairs.setdefault((match.group(2), match.group(4)), []).append((path, number))
            for name, pattern in SHAPES.items():
                if pattern.search(line):
                    hits[name].append((path, number, line.strip()))

    print(f"{len(files)} files")
    print("\n== a count beside a fixed array, checked against it where it's used (#at_most says it once)")
    candidates = 0
    for (count, array), uses in sorted(pairs.items(), key=lambda item: -len(item[1])):
        owners = []
        for struct, places in declared.items():
            for path, fields in places:
                if count in fields and array in fields and FIXED_ARRAY.search(fields[array][0]):
                    owners.append((struct, path, fields[count][1]))
        for struct, path, bounded in owners:
            candidates += 1
            state = "has #at_most" if bounded else "no #at_most"
            print(f"  {struct}.{count} beside {array} ({path.name}, {state}): checked {len(uses)} times")
    print(f"  {candidates} structs")
    for name, found in hits.items():
        print(f"\n== {name}: {len(found)}")
        for path, number, line in found[: arguments.show]:
            print(f"  {path.relative_to(path.parents[2]) if len(path.parents) > 2 else path}:{number}: {line[:120]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
