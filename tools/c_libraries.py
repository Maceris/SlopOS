"""
Build SlopOS's C libraries (decisions/0201, 20k and 20l): each program folder's c/ folder of C sources, compiled by a
stock clang as freestanding, position-independent ELF for the programs' architecture, into lib<program>_c.a in a c/
folder beside the programs, which the build package gives every program as a library path, so a program's
#library("<program>_c") links it.

    python -I tools/c_libraries.py <programs folder> <architecture>

The architecture is x86_64, aarch64 or riscv64. clang and llvm-ar are CLANG and LLVM_AR if set, else found on the PATH,
else beside Visual Studio's LLVM. A clang without the architecture's backend, as Visual Studio's has no RISC-V, gives
LLVM bitcode instead, which llc compiles: LLC if set, else the one built in Hemera's LLVM beside the hemera on the PATH.
Nothing's built, and it succeeds, where no program has C. It ends with 1 if a source doesn't compile or the tools
aren't found.

Environment:
    CLANG     clang, or its folder
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
# Visual Studio's LLVM, where a Windows machine with it has clang
VISUAL_STUDIO_LLVM = Path("C:/Program Files/Microsoft Visual Studio/2022/Community/VC/Tools/Llvm/x64/bin")
# Each architecture's target and flags: the programs' baseline, and the control-flow integrity they're built with
TARGETS = {
    "x86_64": ["--target=x86_64-unknown-none-elf", "-march=x86-64-v3", "-fcf-protection=full", "-mno-red-zone"],
    "aarch64": ["--target=aarch64-unknown-none-elf", "-mbranch-protection=standard"],
    "riscv64": ["--target=riscv64-unknown-none-elf", "-march=rv64gc", "-mabi=lp64d"],
}
FLAGS = ["-ffreestanding", "-fPIC", "-O2", "-g", "-fno-stack-protector", "-fno-common", "-Wall", "-Werror"]
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
    if not programs:
        return 0
    clang = find_tool("CLANG", "clang")
    if clang is None:
        print("c_libraries.py: no clang: set CLANG, or put it on the PATH", file=sys.stderr)
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


if __name__ == "__main__":
    sys.exit(main())
