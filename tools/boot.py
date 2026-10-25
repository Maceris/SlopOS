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

SlopOS's programs, each an ELF in --programs (built with the kernel when there's no --kernel), go in the
ISO as Limine's modules: root_task.elf first, which the kernel starts as the root task, then the others in
the order of their names.

The kernel's ELF goes in a Limine ISO, which QEMU boots (BIOS by default, --uefi for UEFI) with the
serial port captured. --arch aarch64 builds SlopOS's kernel for AArch64 (the build package's arch setting)
and boots it on QEMU's virt machine, always through UEFI, ending through semihosting instead of the debug
exit device, with the same code. Limine randomizes the kernel's base and its direct map (KASLR), unless --no-kaslr. A kernel ends the run by writing a code to QEMU's isa-debug-exit device at
port 0xf4; QEMU then exits with (code << 1) | 1, which this script turns back into the code. It
exits with that code, so --expect makes it a test: 0 if the kernel's code matched, 1 otherwise.

Tools are found from the environment, then the PATH:
    QEMU      qemu-system-x86_64, or its folder
    QEMU_AARCH64  qemu-system-aarch64, or its folder, for --arch aarch64 (default: next to qemu-system-x86_64)
    LIMINE    the folder of Limine's binary release (limine-bios.sys, BOOTX64.EFI, ...)
    XORRISO   xorriso
    OVMF      UEFI firmware for --uefi, if QEMU's own edk2-x86_64-code.fd isn't next to it
    AAVMF     UEFI firmware for --arch aarch64, if QEMU's own edk2-aarch64-code.fd isn't next to it
"""

import argparse
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
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
{modules}"""

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


def build_slopos_kernel(output: Path, architecture: str = "x86_64") -> None:
    """Builds SlopOS's kernel through its build package, checks and all."""
    run_hemera([f"--setting=targets=kernel,kernel_output={output},arch={architecture}", str(BUILD_PACKAGE)], "SlopOS's kernel")


def build_slopos_programs(output: Path, architecture: str = "x86_64") -> None:
    """Builds SlopOS's programs through its build package, into the folder output."""
    output.mkdir(parents=True, exist_ok=True)
    run_hemera([f"--setting=targets=programs,programs_output={output.as_posix()},arch={architecture}", str(BUILD_PACKAGE)],
               "SlopOS's programs")


def make_image(kernel: Path, programs: list[Path], limine: Path, xorriso: Path, folder: Path, command_line: str, kaslr: bool) -> Path:
    """An ISO that boots kernel through Limine, from BIOS or UEFI, with programs as its modules."""
    root = folder / "iso_root"
    (root / "boot" / "limine").mkdir(parents=True)
    (root / "boot" / "modules").mkdir(parents=True)
    (root / "EFI" / "BOOT").mkdir(parents=True)
    shutil.copy(kernel, root / "boot" / "kernel")
    modules = ""
    for program in programs:
        shutil.copy(program, root / "boot" / "modules" / program.name)
        modules += f"    module_path: boot():/boot/modules/{program.name}\n"
    config = LIMINE_CONFIG.format(command_line=command_line, kaslr="yes" if kaslr else "no", modules=modules)
    (root / "boot" / "limine" / "limine.conf").write_text(config, newline="\n")
    for name in ["limine-bios.sys", "limine-bios-cd.bin", "limine-uefi-cd.bin"]:
        shutil.copy(limine / name, root / "boot" / "limine" / name)
    for name in ["BOOTX64.EFI", "BOOTAA64.EFI"]:
        shutil.copy(limine / name, root / "EFI" / "BOOT" / name)
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


def run_aarch64(image: Path, qemu: Path, serial: Path, timeout: float, cpu: str, extra: list[str], iommu: bool) -> int:
    """Boots the image on QEMU's virt machine through UEFI, and gives the code the kernel ended with."""
    firmware = find_tool("AAVMF", ["edk2-aarch64-code.fd", "AAVMF_CODE.fd", "QEMU_EFI.fd"], [qemu.parent / "share"])
    # An SMMUv3 for the PCIe host bridge, with stage 2, the translation SlopOS's domains use (decisions/0079)
    machine = "virt,gic-version=3,acpi=off" + (",iommu=smmuv3" if iommu else "")
    command = [
        # GICv3, and the device tree rather than ACPI, which edk2 gives only with ACPI off
        str(qemu), "-M", machine, "-m", "256M", "-cpu", cpu,
        *(["-global", "arm-smmuv3.stage=2"] if iommu else []),
        "-drive", f"if=pflash,format=raw,readonly=on,file={firmware}",
        "-device", "virtio-scsi-pci", "-device", "scsi-cd,drive=cd",
        "-drive", f"if=none,id=cd,media=cdrom,format=raw,file={image}",
        "-serial", f"file:{serial}", "-display", "none", "-no-reboot",
        "-semihosting-config", "enable=on,target=native",
    ]
    try:
        result = subprocess.run(command + extra, timeout=timeout)
    except subprocess.TimeoutExpired:
        return TIMED_OUT
    # As with the debug exit device, the kernel's test_exit ends QEMU with (code << 1) | 1
    return result.returncode >> 1 if result.returncode % 2 == 1 else NO_EXIT_CODE


# On q35, VT-d with interrupt remapping (decisions/0079): before every other PCI device, as QEMU wants it
X86_IOMMU = ["-device", "intel-iommu,intremap=on"]

# The virtio console's banner, which says it's ready for what's typed into it (src/services/console)
CONSOLE_BANNER = "SlopOS console"


def free_port() -> int:
    """A TCP port on the loopback nothing is listening on, for QEMU to serve."""
    finding = socket.socket()
    finding.bind(("127.0.0.1", 0))
    port = finding.getsockname()[1]
    finding.close()
    return port


# QEMU's key codes (qcodes) for what a US keyboard types, each with whether shift is held for it
QCODES = {" ": ("spc", False), "-": ("minus", False), "_": ("minus", True), "=": ("equal", False), "+": ("equal", True),
          ".": ("dot", False), ",": ("comma", False), "/": ("slash", False), "?": ("slash", True), ";": ("semicolon", False),
          ":": ("semicolon", True), "'": ("apostrophe", False), "!": ("1", True), "@": ("2", True), "#": ("3", True),
          "$": ("4", True), "%": ("5", True), "^": ("6", True), "&": ("7", True), "*": ("8", True), "(": ("9", True),
          ")": ("0", True), "\n": ("ret", False)}


def qcode_of(character: str) -> tuple[str, bool]:
    if character.isascii() and character.isalnum():
        return character.lower(), character.isupper()
    return QCODES[character]


class Keyboard:
    """
    A virtio keyboard, typed into through QEMU's machine protocol (QMP), which QEMU serves on a loopback socket: each
    line, a key down and up at a time, with shift held where it's needed, and Enter at the end.
    """

    def __init__(self):
        self.port = free_port()
        self.connection = None
        self.replies = b""

    def qemu_arguments(self) -> list[str]:
        return ["-device", "virtio-keyboard-pci,disable-legacy=on,iommu_platform=on,id=keyboard",
                "-qmp", f"tcp:127.0.0.1:{self.port},server=on,wait=off"]

    def command(self, name: str, arguments: dict | None = None) -> None:
        message = {"execute": name} | ({"arguments": arguments} if arguments is not None else {})
        self.connection.sendall(json.dumps(message).encode() + b"\n")
        # Its reply, skipping the events QEMU sends between
        while True:
            while b"\n" not in self.replies:
                data = self.connection.recv(4096)
                if not data:
                    raise OSError("QMP closed")
                self.replies += data
            line, _, self.replies = self.replies.partition(b"\n")
            reply = json.loads(line)
            if "return" in reply or "error" in reply:
                return

    def connect(self) -> bool:
        deadline = time.monotonic() + 30
        while self.connection is None and time.monotonic() < deadline:
            try:
                self.connection = socket.create_connection(("127.0.0.1", self.port), timeout=5)
            except OSError:
                time.sleep(0.2)
        if self.connection is None:
            return False
        # Its greeting, then out of negotiation
        while b"\n" not in self.replies:
            self.replies += self.connection.recv(4096)
        _, _, self.replies = self.replies.partition(b"\n")
        self.command("qmp_capabilities")
        return True

    def key(self, qcode: str, down: bool) -> None:
        self.command("input-send-event", {"events": [
            {"type": "key", "data": {"down": down, "key": {"type": "qcode", "data": qcode}}}]})

    def type_line(self, line: str) -> None:
        for character in line + "\n":
            qcode, shifted = qcode_of(character)
            if shifted:
                self.key("shift", True)
            self.key(qcode, True)
            self.key(qcode, False)
            if shifted:
                self.key("shift", False)


class ConsoleLink:
    """
    A virtio console whose other end is a TCP socket QEMU serves on the loopback (a file can't be typed into on
    Windows): this connects to it, waits for the console's banner, types input into it, and keeps what it shows. QEMU
    waits for the connection before it starts the machine, since what's written with nothing connected is lost. The
    i-th line typed is typed at the i-th banner, so a console that's connected again gets the next; lines for a
    keyboard are typed at the first banner, once the serial lines have been.
    """

    def __init__(self, typed: list[str], keyed: list[str], keyboard: "Keyboard | None"):
        self.port = free_port()
        self.typed = typed
        self.keyed = keyed
        self.keyboard = keyboard
        self.shown = ""
        self.thread = threading.Thread(target=self.talk, daemon=True)

    def qemu_arguments(self) -> list[str]:
        return ["-device", "virtio-serial-pci,disable-legacy=on,iommu_platform=on",
                "-chardev", f"socket,id=console,host=127.0.0.1,port={self.port},server=on,wait=on",
                "-device", "virtconsole,chardev=console"]

    def talk(self) -> None:
        connection = None
        deadline = time.monotonic() + 30
        while connection is None and time.monotonic() < deadline:
            try:
                connection = socket.create_connection(("127.0.0.1", self.port), timeout=1)
            except OSError:
                time.sleep(0.2)
        if connection is None:
            return
        connection.settimeout(None)
        banners = 0
        with connection:
            while True:
                try:
                    data = connection.recv(4096)
                except OSError:
                    return
                if not data:
                    return
                self.shown += data.decode(errors="replace")
                while self.shown.count(CONSOLE_BANNER) > banners:
                    if banners < len(self.typed):
                        connection.sendall((self.typed[banners] + "\n").encode())
                    if banners == 0 and self.keyboard is not None and self.keyed:
                        try:
                            if self.keyboard.connect():
                                for line in self.keyed:
                                    self.keyboard.type_line(line)
                        except OSError:
                            pass
                    banners += 1

    def lines(self) -> list[str]:
        return [line.rstrip("\r") for line in self.shown.split("\n")]


# A disk image's size, and its blocks', as virtio-blk counts them
DISK_BYTES = 1 << 20
BLOCK_BYTES = 512


def make_disk(path: Path, mark: str) -> None:
    """A raw disk image: mark at the start of block 0, and "block N" at the start of blocks 2 to 9, zeros elsewhere."""
    image = bytearray(DISK_BYTES)
    image[0:len(mark)] = mark.encode()
    for number in range(2, 10):
        label = f"block {number}".encode()
        image[number * BLOCK_BYTES:number * BLOCK_BYTES + len(label)] = label
    path.write_bytes(bytes(image))


def disk_block_starts(path: Path, expected: str) -> bool:
    """Whether the image has a block starting with text, for an expectation written as N=text."""
    number, _, text = expected.partition("=")
    image = path.read_bytes()
    start = int(number) * BLOCK_BYTES
    return image[start:start + len(text)] == text.encode()


def main() -> int:
    parser = argparse.ArgumentParser(description="Boots a kernel in QEMU through Limine.")
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--kernel", type=Path, help="the kernel's ELF")
    source.add_argument("--package", type=Path, help="a kernel package to build first (default: SlopOS's, through src/build)")
    parser.add_argument("--programs", type=Path, help="a folder of programs to carry as modules (default: SlopOS's, built, without --kernel)")
    parser.add_argument("--linker-script", type=Path, help="the linker script, with --package")
    parser.add_argument("--command-line", default="test_exit", help="the kernel's command line")
    parser.add_argument("--cpu", default=DEFAULT_CPU, help="QEMU's CPU model")
    parser.add_argument("--expect", type=int, help="the exit code the kernel should write; exits 0 if it does")
    parser.add_argument("--expect-line", action="append", default=[],
                        help="a line the serial output should contain, with --expect; may be repeated")
    parser.add_argument("--timeout", type=float, default=30, help="seconds before giving up")
    parser.add_argument("--uefi", action="store_true", help="boot with UEFI firmware instead of BIOS")
    parser.add_argument("--arch", choices=["x86_64", "aarch64"], default="x86_64", help="the architecture to build and boot for")
    parser.add_argument("--no-kaslr", action="store_true", help="the same addresses every boot: no random kernel base or direct map")
    parser.add_argument("--no-iommu", action="store_true",
                        help="no IOMMU: by default q35 has VT-d and virt an SMMUv3, and virtio devices this adds go through it")
    parser.add_argument("--serial", type=Path, help="also keep the serial output in this file")
    parser.add_argument("--console-input", action="append", default=[],
                        help="a line to type into a virtio console, which this adds, once it shows its banner; may be repeated")
    parser.add_argument("--expect-console-line", action="append", default=[],
                        help="a line the virtio console should show, with --expect; may be repeated")
    parser.add_argument("--keyboard-input", action="append", default=[],
                        help="a line to type on a virtio keyboard, which this adds with a virtio console, once the console "
                             "shows its banner; may be repeated")
    parser.add_argument("--disk", help="add a virtio block device, a disk image with this mark in block 0 (make_disk)")
    parser.add_argument("--expect-disk-block", action="append", default=[],
                        help="N=TEXT: block N of the --disk image starts with TEXT once the kernel has stopped, with --expect; "
                             "may be repeated")
    parser.add_argument("qemu_arguments", nargs="*", help="more arguments for QEMU, after --")
    arguments = parser.parse_args()

    qemu = find_tool("QEMU", ["qemu-system-x86_64.exe", "qemu-system-x86_64"], [Path(r"C:\Program Files\qemu")])
    aarch64 = arguments.arch == "aarch64"
    if aarch64:
        qemu = find_tool("QEMU_AARCH64", ["qemu-system-aarch64.exe", "qemu-system-aarch64"], [qemu.parent, Path(r"C:\Program Files\qemu")])
    limine = find_limine()
    xorriso = find_tool("XORRISO", ["xorriso.exe", "xorriso"], [])
    with tempfile.TemporaryDirectory(prefix="slopos-boot-") as temporary:
        folder = Path(temporary)
        kernel = arguments.kernel
        if kernel is None:
            kernel = folder / "kernel.elf"
            if arguments.package is None:
                build_slopos_kernel(kernel, arguments.arch)
            elif arguments.linker_script is None:
                parser.error("--package needs --linker-script")
            else:
                build_kernel(arguments.package.resolve(), arguments.linker_script.resolve(), kernel)
        programs_folder = arguments.programs
        if programs_folder is None and arguments.kernel is None and arguments.package is None:
            programs_folder = folder / "programs"
            build_slopos_programs(programs_folder, arguments.arch)
        programs = sorted(programs_folder.glob("*.elf"), key=lambda path: (path.name != "root_task.elf", path.name))             if programs_folder is not None else []
        # The kernel's own regions follow its command line; the image and the direct map, Limine's configuration
        command_line = arguments.command_line + (" no_kaslr" if arguments.no_kaslr else "")
        image = make_image(kernel.resolve(), [program.resolve() for program in programs], limine, xorriso, folder, command_line,
                           not arguments.no_kaslr)
        serial = folder / "serial.txt"
        extra = (X86_IOMMU if not aarch64 and not arguments.no_iommu else []) + list(arguments.qemu_arguments)
        console = None
        disk = folder / "disk.img"
        if arguments.disk is not None:
            make_disk(disk, arguments.disk)
            extra += ["-drive", f"file={disk},if=none,id=disk,format=raw", "-device", "virtio-blk-pci,drive=disk,disable-legacy=on,iommu_platform=on"]
        keyboard = None
        if arguments.keyboard_input:
            keyboard = Keyboard()
            extra += keyboard.qemu_arguments()
        if arguments.console_input or arguments.expect_console_line or arguments.keyboard_input:
            console = ConsoleLink(arguments.console_input, arguments.keyboard_input, keyboard)
            extra += console.qemu_arguments()
            console.thread.start()
        if aarch64:
            code = run_aarch64(image, qemu, serial, arguments.timeout, arguments.cpu, extra, not arguments.no_iommu)
        else:
            code = run(image, qemu, serial, arguments.timeout, arguments.uefi, arguments.cpu, extra)
        if console is not None:
            console.thread.join(timeout=5)
        output = serial.read_text(errors="replace") if serial.exists() else ""
        unwritten = [expected for expected in arguments.expect_disk_block if not disk.exists() or not disk_block_starts(disk, expected)]
        if arguments.serial is not None:
            arguments.serial.write_text(output)
    sys.stdout.write(output)
    if console is not None:
        for line in console.lines():
            if line:
                print(f"[console] {line}")
    description = {TIMED_OUT: "timed out", NO_EXIT_CODE: "ended without an exit code"}.get(code, f"exited with {code}")
    print(f"boot.py: the kernel {description}", file=sys.stderr)
    if arguments.expect is not None:
        lines = output.splitlines()
        missing = [line for line in arguments.expect_line if line not in lines]
        for line in missing:
            print(f"boot.py: the serial output has no line {line!r}", file=sys.stderr)
        shown = console.lines() if console is not None else []
        missing_shown = [line for line in arguments.expect_console_line if line not in shown]
        for line in missing_shown:
            print(f"boot.py: the virtio console showed no line {line!r}", file=sys.stderr)
        for expected in unwritten:
            print(f"boot.py: the disk has no block {expected!r}", file=sys.stderr)
        return 0 if code == arguments.expect and not missing and not missing_shown and not unwritten else 1
    return code


if __name__ == "__main__":
    sys.exit(main())
