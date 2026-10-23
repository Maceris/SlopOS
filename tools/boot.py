"""
Boots a kernel in QEMU through Limine, for end-to-end tests (knowledge/compiler-plan.md, Phase 6).

    python tools/boot.py --expect 0
    python tools/boot.py --kernel build/kernel.elf
    python tools/boot.py --package other/kernel --linker-script other/kernel/linker.ld --expect 42

Without --kernel it builds the kernel first, with Hemera's compiler (hemera on the PATH): SlopOS's
through its build package (src/build, targets=kernel), which also runs the house-rule checks; or,
with --package, another kernel package directly, with the freestanding flags (no startup code, no
red zone, no SIMD, stack checks that trap) and --linker-script. The compiler finds std next to
itself, or in HEMERA_INSTALL if that's set.

The kernel's command line is --command-line, test_exit by default, which makes SlopOS write why it
stopped to the debug exit device (src/kernel/stop.hsc, StopReason). QEMU's CPU is --cpu, max by
default, since SlopOS needs x86-64-v3.

The kernel's ELF goes in a Limine ISO, which QEMU boots (BIOS by default, --uefi for UEFI) with the
serial port captured. Limine randomizes the kernel's base and its direct map (KASLR), unless --no-kaslr. A kernel ends the run by writing a code to QEMU's isa-debug-exit device at
port 0xf4; QEMU then exits with (code << 1) | 1, which this script turns back into the code. It
exits with that code, so --expect makes it a test: 0 if the kernel's code matched, 1 otherwise.

Tools are found from the environment, then the PATH:
    QEMU      qemu-system-x86_64, or its folder
    LIMINE    the folder of Limine's binary release (limine-bios.sys, BOOTX64.EFI, ...)
    XORRISO   xorriso
    OVMF      UEFI firmware for --uefi, if QEMU's own edk2-x86_64-code.fd isn't next to it
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

# What the kernel writes to port 0xf4 can't be told apart from a reset or a crash when QEMU exits
# with an even code, so those are reported as these.
TIMED_OUT = 124
NO_EXIT_CODE = 125

KERNEL_FLAGS = [
    "--os=none",
    "--no-startup-code",
    "--entry=kernel_entry",
    "--no-red-zone",
    "--stack-check=trap",
    "--cpu-features=-mmx,-sse,-sse2,-avx,-avx2,+soft-float",
]

# KASLR (knowledge/decisions/0021): Limine loads the kernel at a random base and puts its direct map at a random
# offset, which this Limine doesn't do unless asked. --no-kaslr turns both off, so every boot has the same addresses.
LIMINE_CONFIG = """timeout: 0

/SlopOS
    protocol: limine
    kaslr: {kaslr}
    randomise_hhdm_base: {kaslr}
    path: boot():/boot/kernel
    cmdline: {command_line}
"""

ROOT = Path(__file__).resolve().parent.parent
BUILD_PACKAGE = ROOT / "src" / "build"
# SlopOS needs x86-64-v3 (knowledge/decisions/0003), which QEMU's default CPU model lacks
DEFAULT_CPU = "max"


def find_tool(variable: str, names: list[str], folders: list[Path]) -> Path:
    """A tool from its environment variable (a file, or a folder holding it), the PATH, or a usual folder."""
    configured = os.environ.get(variable)
    candidates = []
    if configured:
        path = Path(configured)
        candidates += [path] if path.is_file() else [path / name for name in names]
    candidates += [Path(found) for found in (shutil.which(name) for name in names) if found]
    candidates += [folder / name for folder in folders for name in names]
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    sys.exit(f"boot.py: can't find {names[0]}; set {variable}")


def find_limine() -> Path:
    """Limine's binary release: from LIMINE, or the folder of limine on the PATH."""
    configured = os.environ.get("LIMINE")
    folders = [Path(configured)] if configured else []
    found = shutil.which("limine")
    if found:
        folders += [Path(found).parent, Path(found).parent.parent]
    for folder in folders:
        if (folder / "limine-bios-cd.bin").is_file():
            return folder
    sys.exit("boot.py: can't find Limine's binary release; set LIMINE to its folder")


def limine_tool(limine: Path) -> Path:
    """Limine's own tool, which installs its BIOS stages into the ISO."""
    names = ["limine.exe", "limine"]
    for candidate in [limine / name for name in names] + [limine / "limine-tool-windows-x86" / name for name in names]:
        if candidate.is_file():
            return candidate
    return find_tool("LIMINE_TOOL", names, [])


def run_hemera(arguments: list[str], what: str) -> None:
    """Runs Hemera's compiler, stopping if it fails."""
    command = ["hemera", *arguments]
    if os.environ.get("HEMERA_INSTALL"):
        command.insert(1, f"--install-path={os.environ['HEMERA_INSTALL']}")
    result = subprocess.run(command)
    if result.returncode != 0:
        sys.exit(f"boot.py: building {what} failed")


def build_kernel(package: Path, linker_script: Path, output: Path) -> None:
    """Builds a kernel package directly, with the freestanding flags."""
    run_hemera([*KERNEL_FLAGS, f"--linker-script={linker_script}", f"--output={output}", str(package)], str(package))


def build_slopos_kernel(output: Path) -> None:
    """Builds SlopOS's kernel through its build package, checks and all."""
    run_hemera([f"--setting=targets=kernel,kernel_output={output}", str(BUILD_PACKAGE)], "SlopOS's kernel")


def make_image(kernel: Path, limine: Path, xorriso: Path, folder: Path, command_line: str, kaslr: bool) -> Path:
    """An ISO that boots kernel through Limine, from BIOS or UEFI."""
    root = folder / "iso_root"
    (root / "boot" / "limine").mkdir(parents=True)
    (root / "EFI" / "BOOT").mkdir(parents=True)
    shutil.copy(kernel, root / "boot" / "kernel")
    (root / "boot" / "limine" / "limine.conf").write_text(LIMINE_CONFIG.format(command_line=command_line, kaslr="yes" if kaslr else "no"), newline="\n")
    for name in ["limine-bios.sys", "limine-bios-cd.bin", "limine-uefi-cd.bin"]:
        shutil.copy(limine / name, root / "boot" / "limine" / name)
    shutil.copy(limine / "BOOTX64.EFI", root / "EFI" / "BOOT" / "BOOTX64.EFI")
    image = folder / "image.iso"
    subprocess.run([
        str(xorriso), "-as", "mkisofs", "-R", "-r", "-J",
        "-b", "boot/limine/limine-bios-cd.bin", "-no-emul-boot", "-boot-load-size", "4", "-boot-info-table",
        "-hfsplus", "-apm-block-size", "2048",
        "--efi-boot", "boot/limine/limine-uefi-cd.bin", "-efi-boot-part", "--efi-boot-image", "--protective-msdos-label",
        "iso_root", "-o", "image.iso",
    ], cwd=folder, check=True, capture_output=True)
    subprocess.run([str(limine_tool(limine)), "bios-install", str(image)], check=True, capture_output=True)
    return image


def run(image: Path, qemu: Path, serial: Path, timeout: float, uefi: bool, cpu: str, extra: list[str]) -> int:
    """Boots the image, and gives the code the kernel wrote to the debug exit device."""
    command = [
        str(qemu), "-M", "q35", "-m", "256M", "-cpu", cpu, "-cdrom", str(image),
        "-serial", f"file:{serial}", "-display", "none", "-no-reboot",
        "-device", "isa-debug-exit,iobase=0xf4,iosize=0x04",
    ]
    if uefi:
        firmware = find_tool("OVMF", ["edk2-x86_64-code.fd", "OVMF_CODE.fd", "OVMF.fd"], [qemu.parent / "share"])
        command += ["-drive", f"if=pflash,format=raw,readonly=on,file={firmware}"]
    try:
        result = subprocess.run(command + extra, timeout=timeout)
    except subprocess.TimeoutExpired:
        return TIMED_OUT
    # An odd code came from the debug exit device; anything else is QEMU's own (a reset, a crash)
    return result.returncode >> 1 if result.returncode % 2 == 1 else NO_EXIT_CODE


def main() -> int:
    parser = argparse.ArgumentParser(description="Boots a kernel in QEMU through Limine.")
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--kernel", type=Path, help="the kernel's ELF")
    source.add_argument("--package", type=Path, help="a kernel package to build first (default: SlopOS's, through src/build)")
    parser.add_argument("--linker-script", type=Path, help="the linker script, with --package")
    parser.add_argument("--command-line", default="test_exit", help="the kernel's command line")
    parser.add_argument("--cpu", default=DEFAULT_CPU, help="QEMU's CPU model")
    parser.add_argument("--expect", type=int, help="the exit code the kernel should write; exits 0 if it does")
    parser.add_argument("--expect-line", action="append", default=[],
                        help="a line the serial output should contain, with --expect; may be repeated")
    parser.add_argument("--timeout", type=float, default=30, help="seconds before giving up")
    parser.add_argument("--uefi", action="store_true", help="boot with UEFI firmware instead of BIOS")
    parser.add_argument("--no-kaslr", action="store_true", help="the same addresses every boot: no random kernel base or direct map")
    parser.add_argument("--serial", type=Path, help="also keep the serial output in this file")
    parser.add_argument("qemu_arguments", nargs="*", help="more arguments for QEMU, after --")
    arguments = parser.parse_args()

    qemu = find_tool("QEMU", ["qemu-system-x86_64.exe", "qemu-system-x86_64"], [Path(r"C:\Program Files\qemu")])
    limine = find_limine()
    xorriso = find_tool("XORRISO", ["xorriso.exe", "xorriso"], [])
    with tempfile.TemporaryDirectory(prefix="slopos-boot-") as temporary:
        folder = Path(temporary)
        kernel = arguments.kernel
        if kernel is None:
            kernel = folder / "kernel.elf"
            if arguments.package is None:
                build_slopos_kernel(kernel)
            elif arguments.linker_script is None:
                parser.error("--package needs --linker-script")
            else:
                build_kernel(arguments.package.resolve(), arguments.linker_script.resolve(), kernel)
        # The kernel's own regions follow its command line; the image and the direct map, Limine's configuration
        command_line = arguments.command_line + (" no_kaslr" if arguments.no_kaslr else "")
        image = make_image(kernel.resolve(), limine, xorriso, folder, command_line, not arguments.no_kaslr)
        serial = folder / "serial.txt"
        code = run(image, qemu, serial, arguments.timeout, arguments.uefi, arguments.cpu, arguments.qemu_arguments)
        output = serial.read_text(errors="replace") if serial.exists() else ""
        if arguments.serial is not None:
            arguments.serial.write_text(output)
    sys.stdout.write(output)
    description = {TIMED_OUT: "timed out", NO_EXIT_CODE: "ended without an exit code"}.get(code, f"exited with {code}")
    print(f"boot.py: the kernel {description}", file=sys.stderr)
    if arguments.expect is not None:
        lines = output.splitlines()
        missing = [line for line in arguments.expect_line if line not in lines]
        for line in missing:
            print(f"boot.py: the serial output has no line {line!r}", file=sys.stderr)
        return 0 if code == arguments.expect and not missing else 1
    return code


if __name__ == "__main__":
    sys.exit(main())
