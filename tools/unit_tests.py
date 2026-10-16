"""
Builds and runs every package's tests (decisions/0033, Tests): each test/ folder under src/ is a
package whose main returns 0 if everything worked, or the number of the first check that failed.
They're hosted programs, built for this machine with Hemera's compiler (hemera on the PATH, or
HEMERA), so they test code that doesn't need ring 0, like the frame allocator over a buffer.

Until the build package can discover and run tests itself (decisions/0028), this does.
"""

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def find_hemera() -> str:
    found = os.environ.get("HEMERA") or shutil.which("hemera")
    if found is None:
        sys.exit("unit_tests.py: can't find Hemera's compiler: put hemera on the PATH, or set HEMERA")
    return found


def main() -> int:
    hemera = find_hemera()
    packages = sorted(path for path in (ROOT / "src").rglob("test") if path.is_dir())
    failed = 0
    with tempfile.TemporaryDirectory(prefix="slopos-tests-") as temporary:
        for package in packages:
            name = package.relative_to(ROOT).as_posix()
            output = Path(temporary) / package.parent.name
            build = subprocess.run([hemera, f"--output={output}", str(package)], capture_output=True, text=True)
            if build.returncode != 0:
                print(f"FAILED: {name} doesn't build")
                sys.stdout.write(build.stdout)
                sys.stdout.write(build.stderr)
                failed += 1
                continue
            executable = output.with_suffix(".exe") if sys.platform == "win32" else output
            code = subprocess.run([str(executable)]).returncode
            if code == 0:
                print(f"passed: {name}")
            else:
                print(f"FAILED: {name}, check {code}")
                failed += 1
    print(f"{len(packages) - failed} of {len(packages)} passed")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
