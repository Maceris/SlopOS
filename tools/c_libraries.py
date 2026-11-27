"""
Build SlopOS's C libraries (decisions/0201, 20k and 20l): each program folder's c/ folder of C sources, and the libc
package's (src/libc/c), compiled by a stock clang as freestanding, position-independent ELF for the programs'
architecture, into lib<program>_c.a (liblibc_c.a for the libc) in a c/ folder beside the programs. The build package
gives every program that folder as a library path, so a program's #library("<program>_c") links it; Hemera's build
cache keys a program by the bytes of the libraries it links, so a change to its C relinks it. Every source is compiled with the libc's headers (src/libc/include) and clang's own freestanding ones (stddef.h, stdint.h,
stdarg.h, limits.h, float.h, stdbool.h), and no others.

    python -I tools/c_libraries.py <programs folder> <architecture>

The architecture is x86_64, aarch64 or riscv64. clang is CLANG if set; else the first that has the architecture's
backend of: an LLVM release's (LLVM, its folder or its bin, if set; then LLVM_RELEASES, the newest first), the PATH's,
and Visual Studio's. llvm-ar is LLVM_AR if set, else beside that clang. Only where no clang has the backend, as Visual
Studio's has no RISC-V, is the first found made to give LLVM bitcode, which llc compiles: LLC if set, else the one
built in Hemera's LLVM beside the hemera on the PATH.
Nothing's built, and it succeeds, where no program has C. A c/key.txt and keyed folders an earlier version left are
removed. It ends with 1 if a source doesn't compile or the tools aren't found.

Environment:
    CLANG     clang, or its folder
    LLVM      an LLVM release's folder, or its bin, whose clang is taken before the PATH's
    LLVM_AR   llvm-ar, or its folder (default: beside clang)
    LLC       llc, or its folder, for an architecture clang has no backend for
"""
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# Where programs are: every folder of each is one, as the build package's add_programs takes them
PROGRAM_FOLDERS = [ROOT / "src" / "services", ROOT / "src" / "apps", ROOT / "src" / "tests", ROOT / "src" / "drivers"]
# Packages that aren't programs but have C of their own, each built into lib<package>_c.a as a program's is
C_PACKAGES = [ROOT / "src" / "libc"]
# The libc's headers, which every C source is compiled with (decisions/0201, 20l)
LIBC_HEADERS = ROOT / "src" / "libc" / "include"
# Where LLVM releases are unpacked, each a glob of their bin folders: an installer's, and a release's archive unpacked
# beside the other tools (decisions/0202, 21g); the newest version first
LLVM_RELEASES = ["C:/Program Files/LLVM/bin", "D:/Programs/System Tools/llvm-*-download/clang+llvm-*/bin"]
# Visual Studio's LLVM, where a Windows machine with it has clang
VISUAL_STUDIO_LLVM = Path("C:/Program Files/Microsoft Visual Studio/2022/Community/VC/Tools/Llvm/x64/bin")
# Each architecture's target and flags: the programs' baseline, and the control-flow integrity they're built with
TARGETS = {
    "x86_64": ["--target=x86_64-unknown-none-elf", "-march=x86-64-v3", "-fcf-protection=full", "-mno-red-zone"],
    "aarch64": ["--target=aarch64-unknown-none-elf", "-mbranch-protection=standard"],
    "riscv64": ["--target=riscv64-unknown-none-elf", "-march=rv64gc", "-mabi=lp64d"],
}
FLAGS = ["-ffreestanding", "-fPIC", "-O2", "-g", "-fno-stack-protector", "-fno-common", "-Wall", "-Werror",
         # Only the libc's headers and clang's own, never the host's
         "-nostdlibinc", "-isystem", str(LIBC_HEADERS), "-D__slopos__"]
# What llc is told for bitcode of each architecture: its triple and the features clang's flags give
LLC_TARGETS = {
    "x86_64": ["-mtriple=x86_64-unknown-none-elf", "-mcpu=x86-64-v3"],
    "aarch64": ["-mtriple=aarch64-unknown-none-elf"],
    "riscv64": ["-mtriple=riscv64-unknown-none-elf", "-mattr=+m,+a,+f,+d,+c", "-target-abi=lp64d"],
}
# clang's -print-targets name of each architecture's backend
BACKENDS = {"x86_64": "x86-64", "aarch64": "aarch64", "riscv64": "riscv64"}


def find_tool(variable: str, name: str, beside: Path | None = None) -> Path | None:
    """A tool: the environment variable's, a file or a folder holding it; else beside, on the PATH, or VS's LLVM."""
    given = os.environ.get(variable)
    if given:
        path = Path(given)
        return path / (name + ".exe" if os.name == "nt" else name) if path.is_dir() else path
    for folder in ([beside] if beside else []):
        for candidate in (folder / name, folder / (name + ".exe")):
            if candidate.exists():
                return candidate
    found = shutil.which(name)
    if found:
        return Path(found)
    candidate = VISUAL_STUDIO_LLVM / (name + ".exe")
    return candidate if candidate.exists() else None


def version_key(folder: Path) -> list[int]:
    """The version in an LLVM release's folder name, like clang+llvm-23.1.5-..., as numbers to sort by; [] for none."""
    for part in folder.parent.name.split("-"):
        if part[:1].isdigit():
            return [int(n) for n in part.split(".") if n.isdigit()]
    return []


def clang_candidates() -> list[Path]:
    """Every clang that might be used, in the order they're preferred: LLVM's, LLVM_RELEASES', the PATH's, VS's."""
    folders = []
    given = os.environ.get("LLVM")
    if given:
        folders += [Path(given) / "bin", Path(given)]
    for pattern in LLVM_RELEASES:
        anchor = Path(pattern[:3])
        found = [Path(match) for match in anchor.glob(pattern[3:])] if "*" in pattern else [Path(pattern)]
        folders += sorted(found, key=version_key, reverse=True)
    name = "clang.exe" if os.name == "nt" else "clang"
    candidates = [folder / name for folder in folders if (folder / name).is_file()]
    on_path = shutil.which("clang")
    if on_path:
        candidates.append(Path(on_path))
    if (VISUAL_STUDIO_LLVM / "clang.exe").is_file():
        candidates.append(VISUAL_STUDIO_LLVM / "clang.exe")
    return candidates


def find_clang(architecture: str) -> Path | None:
    """CLANG's clang; else the first candidate with the architecture's backend; else the first found; else None."""
    if os.environ.get("CLANG"):
        return find_tool("CLANG", "clang")
    candidates = clang_candidates()
    for candidate in candidates:
        if has_backend(candidate, architecture):
            return candidate
    return candidates[0] if candidates else None


def has_backend(clang: Path, architecture: str) -> bool:
    """Whether clang can make objects for the architecture itself, as -print-targets lists its backend."""
    listed = subprocess.run([str(clang), "-print-targets"], capture_output=True, text=True).stdout
    return any(line.split()[:1] == [BACKENDS[architecture]] for line in listed.splitlines())


def find_llc() -> Path | None:
    """llc: LLC's, or the one built in Hemera's LLVM beside the hemera on the PATH."""
    if os.environ.get("LLC"):
        return find_tool("LLC", "llc")
    hemera = shutil.which("hemera")
    if hemera is None:
        return shutil.which("llc") and Path(shutil.which("llc"))
    # build/<platform>/bin/Release/hemera, and build/<platform>/apps/compiler/third-party/llvm-project/llvm/Release/bin
    build = Path(hemera).resolve().parent.parent.parent
    for candidate in (build / "apps/compiler/third-party/llvm-project/llvm/Release/bin/llc.exe",
                      build / "apps/compiler/third-party/llvm-project/llvm/bin/llc"):
        if candidate.exists():
            return candidate
    return None


def main() -> int:
    if len(sys.argv) != 3 or sys.argv[2] not in TARGETS:
        print("usage: c_libraries.py <programs folder> x86_64|aarch64|riscv64", file=sys.stderr)
        return 1
    output = Path(sys.argv[1]) / "c"
    architecture = sys.argv[2]
    programs = [folder for parent in PROGRAM_FOLDERS if parent.exists() for folder in sorted(parent.iterdir())
                if (folder / "c").is_dir() and any((folder / "c").glob("*.c"))]
    programs += [package for package in C_PACKAGES if (package / "c").is_dir() and any((package / "c").glob("*.c"))]
    forget_keys(output)
    if not programs:
        return 0
    clang = find_clang(architecture)
    if clang is None:
        print("c_libraries.py: no clang: set CLANG or LLVM, or put it on the PATH", file=sys.stderr)
        return 1
    archiver = find_tool("LLVM_AR", "llvm-ar", clang.parent)
    if archiver is None:
        print("c_libraries.py: no llvm-ar: set LLVM_AR, or put it beside clang", file=sys.stderr)
        return 1
    llc = None if has_backend(clang, architecture) else find_llc()
    if not has_backend(clang, architecture) and llc is None:
        print(f"c_libraries.py: clang has no {architecture} backend, and there's no llc: set LLC", file=sys.stderr)
        return 1
    output.mkdir(parents=True, exist_ok=True)
    for program in programs:
        objects = []
        built = output / f"{program.name}_c"
        built.mkdir(exist_ok=True)
        for source in sorted((program / "c").glob("*.c")):
            made = built / (source.stem + ".o")
            if llc is None:
                command = [str(clang), *TARGETS[architecture], *FLAGS, "-c", str(source), "-o", str(made)]
                compiled = subprocess.run(command).returncode == 0
            else:
                bitcode = built / (source.stem + ".bc")
                command = [str(clang), *TARGETS[architecture], *FLAGS, "-emit-llvm", "-c", str(source), "-o", str(bitcode)]
                compiled = subprocess.run(command).returncode == 0 and subprocess.run(
                    [str(llc), *LLC_TARGETS[architecture], "-O2", "-relocation-model=pic", "-filetype=obj",
                     str(bitcode), "-o", str(made)]).returncode == 0
            if not compiled:
                print(f"c_libraries.py: {source} doesn't compile", file=sys.stderr)
                return 1
            objects.append(str(made))
        library = output / f"lib{program.name}_c.a"
        library.unlink(missing_ok=True)
        if subprocess.run([str(archiver), "rcs", str(library), *objects]).returncode != 0:
            print(f"c_libraries.py: {library} couldn't be made", file=sys.stderr)
            return 1
    return 0


def forget_keys(output: Path) -> None:
    """
    Remove c/key.txt and the keyed folders (16 hex digits) an earlier version of this script copied the libraries into:
    nothing's done where c/ isn't.
    """
    if not output.is_dir():
        return
    (output / "key.txt").unlink(missing_ok=True)
    for other in output.iterdir():
        if other.is_dir() and len(other.name) == 16 and all(c in "0123456789abcdef" for c in other.name):
            shutil.rmtree(other)


if __name__ == "__main__":
    sys.exit(main())
