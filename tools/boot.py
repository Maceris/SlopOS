"""
Boots a kernel in QEMU through SlopOS's own bootloader, for end-to-end tests (knowledge/compiler-plan.md, Phase 6).

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

SlopOS's programs, each an ELF in --programs (built when there's none), are the boot set of the ISO's generation:
root_task.elf first, which the kernel starts as the root task, then the others in the order of their names.

The ISO boots by UEFI through El Torito (roadmap B4, decisions/0135): its EFI image is a FAT volume holding SlopOS's
bootloader (bootloader.efi, from --programs) as the firmware's default boot file and generation 1, the kernel and the
programs as objects with its record, which the generation builder writes and the image builder makes a volume of
(both built, as SlopOS's tools, unless --image-builder names them). QEMU boots it with the serial port captured.
--arch aarch64 builds SlopOS's kernel for AArch64 (the build package's arch setting) and boots it on QEMU's virt
machine, ending through semihosting instead of the debug exit device, with the same code. The bootloader randomizes
the kernel's base and its direct map (KASLR), unless --no-kaslr. A kernel ends the run by writing a code to QEMU's isa-debug-exit device at
port 0xf4; QEMU then exits with (code << 1) | 1, which this script turns back into the code. It
exits with that code, so --expect makes it a test: 0 if the kernel's code matched, 1 otherwise.

Tools are found from the environment, then the PATH:
    QEMU      qemu-system-x86_64, or its folder
    QEMU_AARCH64  qemu-system-aarch64, or its folder, for --arch aarch64 (default: next to qemu-system-x86_64)
    XORRISO   xorriso
    OVMF      UEFI firmware, if QEMU's own edk2-x86_64-code.fd isn't next to it
    AAVMF     UEFI firmware for --arch aarch64, if QEMU's own edk2-aarch64-code.fd isn't next to it
"""

import argparse
import json
import os
import re
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import zlib
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
    run_hemera([f"--setting=targets=kernel,kernel_output={output},arch={architecture}", str(BUILD_PACKAGE)],
               "SlopOS's kernel")


def build_slopos_tools(output: Path) -> None:
    """SlopOS's hosted tools, the image builder among them, for this machine, through its build package."""
    output.mkdir(parents=True, exist_ok=True)
    run_hemera([f"--setting=targets=tools,tools_output={output.as_posix()}", str(BUILD_PACKAGE)], "the tools")


def build_slopos_programs(output: Path, architecture: str = "x86_64") -> None:
    """Builds SlopOS's programs through its build package, into the folder output."""
    output.mkdir(parents=True, exist_ok=True)
    run_hemera([f"--setting=targets=programs,programs_output={output.as_posix()},arch={architecture}", str(BUILD_PACKAGE)],
               "SlopOS's programs")


# The ISO's EFI image: at least a FAT32 volume's fewest clusters of a sector, and room for what it holds
ISO_FAT_SECTORS = 69632


def make_image(kernel: Path, programs: list[Path], bootloader: Path, image_builder: Path, xorriso: Path, folder: Path,
               command_line: str, kaslr: bool) -> Path:
    """
    An ISO that boots kernel by UEFI through SlopOS's bootloader (decisions/0135): its El Torito EFI image a FAT volume
    with the bootloader as the default boot file and generation 1, of the kernel and every program, written by the
    generation builder.
    """
    esp = folder / "iso_esp"
    (esp / "EFI" / "BOOT").mkdir(parents=True)
    for name in ["BOOTX64.EFI", "BOOTAA64.EFI"]:
        shutil.copy(bootloader, esp / "EFI" / "BOOT" / name)
    # No bundle store: every program is in the boot set
    store = folder / "iso_store"
    (store / "objects").mkdir(parents=True)
    generation_builder = next(image_builder.parent.glob("generation_builder*"))
    generated = subprocess.run([str(generation_builder), str(esp), str(store), "1", "yes" if kaslr else "no", command_line, str(kernel)]
                               + [str(program) for program in programs], capture_output=True, text=True)
    if generated.returncode != 0:
        sys.exit(f"boot.py: the generation builder failed:\n{generated.stdout}{generated.stderr}")
    root = folder / "iso_root"
    root.mkdir()
    held = sum(path.stat().st_size for path in esp.rglob("*") if path.is_file())
    built = subprocess.run([str(image_builder), "--fat", str(root / "efi.img"), str(ISO_FAT_SECTORS + held // 512), str(esp)],
                           capture_output=True, text=True)
    if built.returncode != 0:
        sys.exit(f"boot.py: the image builder failed:\n{built.stdout}{built.stderr}")
    image = folder / "image.iso"
    subprocess.run([
        str(xorriso), "-as", "mkisofs", "-R", "-J",
        "--efi-boot", "efi.img", "-efi-boot-part", "--efi-boot-image", "--protective-msdos-label",
        "iso_root", "-o", "image.iso",
    ], cwd=folder, check=True, capture_output=True)
    return image


def run(image: Path | None, qemu: Path, serial: Path, timeout: float, cpu: str, extra: list[str],
        keys: "SerialKeys | None" = None, reboot: bool = False) -> int:
    """Boots the image, or with none the disk in extra, by UEFI, and gives the code the kernel wrote to the debug exit device."""
    boot = ["-cdrom", str(image)] if image is not None else []
    command = [
        str(qemu), "-M", "q35", "-m", "256M", "-cpu", cpu, *boot,
        *serial_arguments(serial, keys), "-display", "none", *([] if reboot else ["-no-reboot"]),
        "-device", "isa-debug-exit,iobase=0xf4,iosize=0x04",
    ]
    firmware = find_tool("OVMF", ["edk2-x86_64-code.fd", "OVMF_CODE.fd", "OVMF.fd"], [qemu.parent / "share"])
    command += ["-drive", f"if=pflash,format=raw,readonly=on,file={firmware}"]
    if keys is not None:
        keys.thread.start()
    try:
        result = subprocess.run(command + extra, timeout=timeout)
    except subprocess.TimeoutExpired:
        return TIMED_OUT
    finally:
        if keys is not None:
            keys.thread.join(timeout=5)
    # An odd code came from the debug exit device; anything else is QEMU's own (a reset, a crash)
    return result.returncode >> 1 if result.returncode % 2 == 1 else NO_EXIT_CODE


def run_aarch64(image: Path | None, qemu: Path, serial: Path, timeout: float, cpu: str, extra: list[str], iommu: bool,
                keys: "SerialKeys | None" = None, reboot: bool = False) -> int:
    """Boots the image, or with none the disk in extra, on QEMU's virt machine through UEFI, and gives the code the kernel ended with."""
    cd = ["-device", "virtio-scsi-pci", "-device", "scsi-cd,drive=cd", "-drive", f"if=none,id=cd,media=cdrom,format=raw,file={image}"] \
        if image is not None else []
    firmware = find_tool("AAVMF", ["edk2-aarch64-code.fd", "AAVMF_CODE.fd", "QEMU_EFI.fd"], [qemu.parent / "share"])
    # An SMMUv3 for the PCIe host bridge, with stage 2, the translation SlopOS's domains use (decisions/0079)
    machine = "virt,gic-version=3,acpi=off" + (",iommu=smmuv3" if iommu else "")
    command = [
        # GICv3, and the device tree rather than ACPI, which edk2 gives only with ACPI off
        str(qemu), "-M", machine, "-m", "256M", "-cpu", cpu,
        *(["-global", "arm-smmuv3.stage=2"] if iommu else []),
        "-drive", f"if=pflash,format=raw,readonly=on,file={firmware}", *cd,
        *serial_arguments(serial, keys), "-display", "none", *([] if reboot else ["-no-reboot"]),
        "-semihosting-config", "enable=on,target=native",
    ]
    if keys is not None:
        keys.thread.start()
    try:
        result = subprocess.run(command + extra, timeout=timeout)
    except subprocess.TimeoutExpired:
        return TIMED_OUT
    finally:
        if keys is not None:
            keys.thread.join(timeout=5)
    # As with the debug exit device, the kernel's test_exit ends QEMU with (code << 1) | 1
    return result.returncode >> 1 if result.returncode % 2 == 1 else NO_EXIT_CODE


def serial_arguments(serial: Path, keys: "SerialKeys | None") -> list[str]:
    """The serial port's output kept in the file, or with keys, going through them."""
    return keys.qemu_arguments() if keys is not None else ["-serial", f"file:{serial}"]


class SerialKeys:
    """
    The serial port on a TCP socket QEMU serves on the loopback, in place of a file, for a key held down as the
    machine starts (--recovery-key): the firmware's console takes what arrives on the serial port as typed, so this
    sends the key over and over until the bootloader says what it boots, and keeps the output in the serial file.
    """

    def __init__(self, serial: Path, key: str):
        self.port = free_port()
        self.serial = serial
        self.key = key.encode()
        self.thread = threading.Thread(target=self.talk, daemon=True)

    def qemu_arguments(self) -> list[str]:
        return ["-chardev", f"socket,id=serial,host=127.0.0.1,port={self.port},server=on,wait=on", "-serial", "chardev:serial"]

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
        connection.settimeout(0.1)
        shown = b""
        with connection, self.serial.open("wb") as out:
            while True:
                held = b"bootloader: booting generation" not in shown
                try:
                    if held:
                        connection.sendall(self.key)
                    data = connection.recv(4096)
                except socket.timeout:
                    continue
                except OSError:
                    return
                if not data:
                    return
                out.write(data)
                out.flush()
                shown += data


# On q35, VT-d with interrupt remapping (decisions/0079): before every other PCI device, as QEMU wants it
X86_IOMMU = ["-device", "intel-iommu,intremap=on"]

# The virtio console's banner, which says it's ready for what's typed into it (src/services/terminal_service)
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
DISK_BYTES = 38 << 20
BLOCK_BYTES = 512
DISK_BLOCKS = DISK_BYTES // BLOCK_BYTES
# A type GUID for test partitions, and the EFI system partition's (C12A7328-F81F-11D2-BA4B-00A0C93EC93B), in their bytes
TEST_TYPE = bytes.fromhex("534c4f50 4f532054 45535420 50415254".replace(" ", ""))
ESP_TYPE = bytes.fromhex("28732ac1 1ff8d211 ba4b00a0 c93ec93b".replace(" ", ""))
# Its GPT's partitions: the one the disk check checks and a spare, 1 MiB each, and an EFI system partition of 34 MiB,
# just enough clusters of a sector for FAT32 (src/services/disk_check)
CHECKED_FIRST = 2048
ESP_FIRST = 6144
ESP_SECTORS = 69632
PARTITIONS = [("SlopOS check", CHECKED_FIRST, 2048, TEST_TYPE), ("SlopOS spare", 4096, 2048, TEST_TYPE),
              ("EFI system partition", ESP_FIRST, ESP_SECTORS, ESP_TYPE)]
# What the EFI system partition holds, in EFI/SlopOS: one file with an 8.3 name, one with a long one
ESP_FILES = [("hello.txt", b"Hello from the host's FAT32"), ("A long name, from the host.txt", b"A long name, from the host")]
GPT_ENTRIES = 128
GPT_ENTRY_BYTES = 128
GPT_ENTRY_BLOCKS = GPT_ENTRIES * GPT_ENTRY_BYTES // BLOCK_BYTES


def gpt_header(at: int, alternate: int, entries_block: int, entries_crc: int) -> bytes:
    """A GPT header for block at (UEFI 2.10, 5.3.2), its CRC32 filled in."""
    first_usable = GPT_ENTRY_BLOCKS + 2
    last_usable = DISK_BLOCKS - GPT_ENTRY_BLOCKS - 2
    def pack(crc: int) -> bytes:
        return struct.pack("<8sIIIIQQQQ16sQIII", b"EFI PART", 0x00010000, 92, crc, 0, at, alternate, first_usable, last_usable,
                           bytes(range(16)), entries_block, GPT_ENTRIES, GPT_ENTRY_BYTES, entries_crc)
    return pack(zlib.crc32(pack(0)))


def make_disk(path: Path, mark: str) -> None:
    """
    A raw disk image with a GPT (a protective MBR, the primary header and entries, and the backup's at the end) of
    PARTITIONS: the checked one has mark at the start of its block 0 and "block N" at the start of its blocks 2 to 9.
    """
    image = bytearray(DISK_BYTES)
    entries = bytearray(GPT_ENTRIES * GPT_ENTRY_BYTES)
    for index, (name, first, count, kind) in enumerate(PARTITIONS):
        entry = struct.pack("<16s16sQQQ", kind, bytes([index + 1]) * 16, first, first + count - 1, 0) + name.encode("utf-16-le")
        entries[index * GPT_ENTRY_BYTES:index * GPT_ENTRY_BYTES + len(entry)] = entry
    entries_crc = zlib.crc32(entries)
    # The protective MBR: one partition of type 0xee from block 1 over the whole disk
    image[446:462] = struct.pack("<BBBBBBBBII", 0, 0, 2, 0, 0xee, 0xff, 0xff, 0xff, 1, DISK_BLOCKS - 1)
    image[510:512] = bytes([0x55, 0xaa])
    image[BLOCK_BYTES:BLOCK_BYTES + 92] = gpt_header(1, DISK_BLOCKS - 1, 2, entries_crc)
    image[2 * BLOCK_BYTES:2 * BLOCK_BYTES + len(entries)] = entries
    backup_entries = DISK_BLOCKS - GPT_ENTRY_BLOCKS - 1
    image[backup_entries * BLOCK_BYTES:backup_entries * BLOCK_BYTES + len(entries)] = entries
    last = (DISK_BLOCKS - 1) * BLOCK_BYTES
    image[last:last + 92] = gpt_header(DISK_BLOCKS - 1, 1, backup_entries, entries_crc)
    start = CHECKED_FIRST * BLOCK_BYTES
    image[start:start + len(mark)] = mark.encode()
    for number in range(2, 10):
        label = f"block {number}".encode()
        at = (CHECKED_FIRST + number) * BLOCK_BYTES
        image[at:at + len(label)] = label
    esp_start = ESP_FIRST * BLOCK_BYTES
    image[esp_start:esp_start + ESP_SECTORS * BLOCK_BYTES] = fat32_volume(ESP_SECTORS, ESP_FILES)
    path.write_bytes(bytes(image))


def short_checksum(short: bytes) -> int:
    """The checksum of an 8.3 name that its long-name entries carry (FAT32 1.03, 7.2)."""
    total = 0
    for byte in short:
        total = (((total & 1) << 7) + (total >> 1) + byte) & 0xff
    return total


def directory_entries(name: str, short: bytes, attributes: int, cluster: int, size: int, lower_case: int = 0) -> bytes:
    """A name's directory entries: its long-name ones, last first, unless it has none, then its short one."""
    entries = b""
    if name:
        units = list(name.encode("utf-16-le"))
        units = [units[i] | units[i + 1] << 8 for i in range(0, len(units), 2)]
        count = (len(units) + 12) // 13
        padded = units + [0] + [0xffff] * (count * 13 - len(units) - 1)
        checksum = short_checksum(short)
        for order in range(count, 0, -1):
            part = padded[(order - 1) * 13:order * 13]
            entries += struct.pack("<B5HBBB6HH2H", order | (0x40 if order == count else 0), *part[0:5], 0x0f, 0, checksum, *part[5:11], 0, *part[11:13])
    # 1980-01-01, day 1 of month 1
    date = 1 << 5 | 1
    entries += struct.pack("<11sBBBHHHHHHHI", short, attributes, lower_case, 0, 0, date, date, cluster >> 16, 0, date, cluster & 0xffff, size)
    return entries


def fat32_volume(sectors: int, files: list) -> bytes:
    """
    A FAT32 volume of sectors, a sector a cluster, as Microsoft's specification 1.03 lays it out, written here apart
    from src/fat, so each checks the other: EFI/SlopOS, a long name of its own, holding files, each in a cluster.
    """
    volume = bytearray(sectors * BLOCK_BYTES)
    reserved = 32
    fat_sectors = ((sectors - reserved + 2) * 4 + BLOCK_BYTES - 1) // BLOCK_BYTES
    first_data = reserved + 2 * fat_sectors
    clusters = sectors - first_data
    boot = bytearray(BLOCK_BYTES)
    boot[0:3] = b"\xebX\x90"
    boot[3:11] = b"MSWIN4.1"
    struct.pack_into("<HBHBHHBHHHII", boot, 11, BLOCK_BYTES, 1, reserved, 2, 0, 0, 0xf8, 0, 63, 255, 0, sectors)
    struct.pack_into("<IHHIHH", boot, 36, fat_sectors, 0, 0, 2, 1, 6)
    struct.pack_into("<BBBI11s8s", boot, 64, 0x80, 0, 0x29, 0x12345678, b"HOST ESP   ", b"FAT32   ")
    boot[510:512] = bytes([0x55, 0xaa])
    info = bytearray(BLOCK_BYTES)
    struct.pack_into("<I", info, 0, 0x41615252)
    struct.pack_into("<IIII", info, 484, 0x61417272, 0xffffffff, 0xffffffff, 0)
    struct.pack_into("<I", info, 508, 0xaa550000)
    for at in (0, 6):
        volume[at * BLOCK_BYTES:(at + 1) * BLOCK_BYTES] = boot
        volume[(at + 1) * BLOCK_BYTES:(at + 2) * BLOCK_BYTES] = info
    # Clusters: 2 the root, 3 EFI, 4 SlopOS, then each file's
    fat = [0x0ffffff8, 0x0fffffff, 0x0fffffff, 0x0fffffff, 0x0fffffff] + [0x0fffffff] * len(files)

    def cluster_bytes(cluster: int) -> int:
        return (first_data + cluster - 2) * BLOCK_BYTES

    def put_cluster(cluster: int, data: bytes) -> None:
        start = cluster_bytes(cluster)
        volume[start:start + len(data)] = data

    put_cluster(2, directory_entries("", b"EFI        ", 0x10, 3, 0))
    put_cluster(3, directory_entries("", b".          ", 0x10, 3, 0) + directory_entries("", b"..         ", 0x10, 0, 0)
                + directory_entries("SlopOS", b"SLOPOS     ", 0x10, 4, 0))
    listing = directory_entries("", b".          ", 0x10, 4, 0) + directory_entries("", b"..         ", 0x10, 3, 0)
    for index, (name, data) in enumerate(files):
        cluster = 5 + index
        if name == "hello.txt":
            # An 8.3 name, its base and extension lower case by its case flags
            listing += directory_entries("", b"HELLO   TXT", 0x20, cluster, len(data), 0x18)
        else:
            listing += directory_entries(name, b"ALONGN~1TXT", 0x20, cluster, len(data))
        put_cluster(cluster, data)
    put_cluster(4, listing)
    table = struct.pack(f"<{len(fat)}I", *fat)
    for copy in range(2):
        start = (reserved + copy * fat_sectors) * BLOCK_BYTES
        volume[start:start + len(table)] = table
    return bytes(volume)


# The disk the image builder makes to boot from, in 512-byte sectors (decisions/0088): the disk check's two partitions
# where make_disk has them, the EFI system partition with the bootloader, the generations, the modules and the disk
# check's files, and a SlopOS container whose system volume holds the modules
BOOT_DISK_SECTORS = 206848
# The programs the bootloader loads from the boot disk, enough to reach the system volume, which holds every program; the rest
# come from it (src/system_config's boot_set, decisions/0089)
BOOT_SET = ["root_task", "entropy", "process_manager", "scheduler", "platform", "supervisor", "events_service", "bundle_store_service", "clock", "virtio_blk", "storage_manager", "partition_server",
            "fat_server", "container_service", "volume_server"]
# The system configuration, which the build writes beside the programs
SYSTEM_RECORDS = "system.records"
BOOT_ESP_SECTORS = 131072
BOOT_SYSTEM_SECTORS = 65536


# The encrypted volume the image builder makes beside the system volume, and its passphrase, which the disk check
# unlocks it with (src/services/disk_check/sealed_check.hsc)
SEALED_VOLUME = "sealed"
SEALED_PASSPHRASE = "slopos test passphrase"


def make_boot_disk(path: Path, kernel: Path, programs: list[Path], bootloader: Path, image_builder: Path, folder: Path,
                   command_line: str, kaslr: bool, mark: str, staged: str | None = None, staged_next: Path | None = None) -> None:
    """
    A disk that boots kernel through SlopOS's bootloader, made by the image builder: the bootloader, generation 1 and
    the programs on its EFI system partition, as make_image puts them on the ISO, but only the boot set in the generation,
    and every program in the system volume of its SlopOS container, where the rest come from, with an encrypted volume
    beside it; the SlopOS check partition marked as make_disk marks it.
    """
    esp = folder / "boot_esp"
    for part in [esp / "EFI" / "BOOT", esp / "EFI" / "SlopOS", esp / "boot" / "modules"]:
        part.mkdir(parents=True)
    # Every program, as the disk check finds them there; the boot set boots from the generation's objects
    for program in programs:
        shutil.copy(program, esp / "boot" / "modules" / program.name)
    # SlopOS's own bootloader as the firmware's default boot file (decisions/0133)
    for name in ["BOOTX64.EFI", "BOOTAA64.EFI"]:
        shutil.copy(bootloader, esp / "EFI" / "BOOT" / name)
    for name, data in ESP_FILES:
        (esp / "EFI" / "SlopOS" / name).write_bytes(data)
    system = folder / "boot_system"
    (system / "modules").mkdir(parents=True)
    for program in programs:
        shutil.copy(program, system / "modules" / program.name)
    # The bundle store, with a bundle for every program outside the boot set, which the supervisor loads from it
    store_builder = next(image_builder.parent.glob("store_builder*"))
    stored = subprocess.run([str(store_builder), str(system / "store")] + [str(program) for program in programs
                                                                           if program.stem not in BOOT_SET and program.suffix == ".elf"],
                            capture_output=True, text=True)
    if stored.returncode != 0:
        sys.exit(f"boot.py: the store builder failed:\n{stored.stdout}{stored.stderr}")
    # Generation 1 (decisions/0113): the kernel and the boot set as objects named by their hashes, and its record, the
    # root task first
    boot_set = [program for program in programs if program.stem in BOOT_SET or program.name == SYSTEM_RECORDS or program.suffix == ".library"]
    generation_builder = next(image_builder.parent.glob("generation_builder*"))
    # The recovery generation beside it, of the same boot set (decisions/0118), which the recovery key boots
    generated = subprocess.run([str(generation_builder), "--recovery", str(esp), str(system / "store"), "1", "yes" if kaslr else "no",
                                command_line, str(kernel)] + [str(program) for program in boot_set], capture_output=True, text=True)
    if generated.returncode != 0:
        sys.exit(f"boot.py: the generation builder failed:\n{generated.stdout}{generated.stderr}")
    # Generation 2 staged, its objects in the store and its record in the system volume's updates directory
    if staged is not None:
        (system / "updates").mkdir(parents=True, exist_ok=True)
        # With hello's next build as hello's bundle: a store root that changes only a service (decisions/0126)
        if staged_next is not None:
            renamed = folder / "next_programs"
            renamed.mkdir(parents=True, exist_ok=True)
            shutil.copy(staged_next, renamed / "hello.elf")
            shutil.copy(staged_next.with_suffix(".manifest"), renamed / "hello.manifest")
            stored = subprocess.run([str(store_builder), str(system / "store")] + [
                str(renamed / "hello.elf") if program.stem == "hello" else str(program) for program in programs
                if program.stem not in BOOT_SET and program.suffix == ".elf"], capture_output=True, text=True)
            if stored.returncode != 0:
                sys.exit(f"boot.py: the store builder failed on the next build:\n{stored.stdout}{stored.stderr}")
        staging = subprocess.run([str(generation_builder), "--stage", str(system), str(system / "store"), "2", "yes" if kaslr else "no",
                                  staged, str(kernel)] + [str(program) for program in boot_set], capture_output=True, text=True)
        if staging.returncode != 0:
            sys.exit(f"boot.py: the generation builder couldn't stage generation 2:\n{staging.stdout}{staging.stderr}")
    built = subprocess.run([str(image_builder), str(path), str(BOOT_DISK_SECTORS), f"--sealed={SEALED_VOLUME}:{SEALED_PASSPHRASE}",
                            f"test,{PARTITIONS[0][0]},{PARTITIONS[0][2]}",
                            f"test,{PARTITIONS[1][0]},{PARTITIONS[1][2]}",
                            f"esp,EFI system partition,{BOOT_ESP_SECTORS},{esp}", f"slopfs,SlopOS system,{BOOT_SYSTEM_SECTORS},{system}"],
                           capture_output=True, text=True)
    if built.returncode != 0:
        sys.exit(f"boot.py: the image builder failed:\n{built.stdout}{built.stderr}")
    checked = [line.split() for line in built.stdout.splitlines() if line.startswith("partition 0 ")]
    if not checked or int(checked[0][2]) != CHECKED_FIRST:
        sys.exit(f"boot.py: the image builder put {PARTITIONS[0][0]} somewhere else:\n{built.stdout}")
    with path.open("r+b") as image:
        image.seek(CHECKED_FIRST * BLOCK_BYTES)
        image.write(mark.encode())
        for number in range(2, 10):
            image.seek((CHECKED_FIRST + number) * BLOCK_BYTES)
            image.write(f"block {number}".encode())


def disk_block_starts(path: Path, expected: str) -> bool:
    """Whether the image has a block starting with text, for an expectation written as N=text, N counting the disk's blocks."""
    number, _, text = expected.partition("=")
    image = path.read_bytes()
    start = int(number) * BLOCK_BYTES
    return image[start:start + len(text)] == text.encode()


def main() -> int:
    parser = argparse.ArgumentParser(description="Boots a kernel in QEMU through SlopOS's own bootloader.")
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
    parser.add_argument("--disk", help="add a virtio block device, a GPT disk image with this mark in its SlopOS check partition's block 0 (make_disk)")
    parser.add_argument("--boot-disk", action="store_true",
                        help="boot from a disk the image builder makes rather than from the ISO (make_boot_disk), the --disk mark in "
                             "its SlopOS check partition")
    parser.add_argument("--image-builder", type=Path,
                        help="the image builder, beside the generation builder and the store builder (default: SlopOS's, built)")
    parser.add_argument("--expect-disk-text", action="append", default=[],
                        help="TEXT: the --disk image holds TEXT somewhere once the kernel has stopped, with --expect; may be repeated")
    parser.add_argument("--refuse-disk-text", action="append", default=[],
                        help="TEXT: the --disk image holds TEXT nowhere once the kernel has stopped, with --expect, as an "
                             "encrypted volume's names and bytes aren't; may be repeated")
    parser.add_argument("--expect-disk-block", action="append", default=[],
                        help="N=TEXT: block N of the --disk image starts with TEXT once the kernel has stopped, with --expect; "
                             "may be repeated")
    parser.add_argument("--boots", type=int, default=1,
                        help="with --boot-disk: boot the same disk this many times, each after the last stopped, as a reboot would")
    parser.add_argument("--expect-boot-line", action="append", default=[],
                        help="with --boots: <boot>:<line>, a line that boot's serial output must have, from 2")
    parser.add_argument("--stage-generation",
                        help="with --boot-disk: stage generation 2 on the system volume, the same programs with this command line, "
                             "for the update service to install (decisions/0116)")
    parser.add_argument("--stage-next-hello", action="store_true",
                        help="with --stage-generation: generation 2's store root has hello's next build (hello_next.elf) as hello's "
                             "bundle, so it changes only a service, which the supervisor applies live (decisions/0126)")
    parser.add_argument("--kernel-alone", action="store_true",
                        help="boot the kernel with no modules, its generation's boot set empty; --programs still gives the bootloader")
    parser.add_argument("--recovery-key", action="store_true",
                        help="hold the bootloader's recovery key, r, on the serial console as the machine starts, "
                             "the first boot only (roadmap B3)")
    parser.add_argument("--allow-reboot", action="store_true",
                        help="let the first boot reset the machine and boot again in the same QEMU, which keeps RAM, as a warm "
                             "reset does, rather than ending QEMU (the panic record, decisions/0134)")
    parser.add_argument("--efi",
                        help="boot a UEFI program of SlopOS's build (src/uefi), NAME.efi, by itself under the firmware, rather than "
                             "the kernel: as EFI/BOOT/BOOTX64.EFI (or BOOTAA64.EFI) on a FAT drive; turning the machine off is "
                             "exit code 0 (roadmap B1, decisions/0132)")
    parser.add_argument("qemu_arguments", nargs="*", help="more arguments for QEMU, after --")
    arguments = parser.parse_args()

    qemu = find_tool("QEMU", ["qemu-system-x86_64.exe", "qemu-system-x86_64"], [Path(r"C:\Program Files\qemu")])
    aarch64 = arguments.arch == "aarch64"
    if aarch64:
        qemu = find_tool("QEMU_AARCH64", ["qemu-system-aarch64.exe", "qemu-system-aarch64"], [qemu.parent, Path(r"C:\Program Files\qemu")])
    if arguments.efi is not None:
        return run_efi(arguments, qemu, aarch64)
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
        # The bootloader is one of the programs, so there are always some
        if programs_folder is None:
            programs_folder = folder / "programs"
            build_slopos_programs(programs_folder, arguments.arch)
        # hello_next.elf is only ever a staged generation's hello (--stage-next-hello)
        programs = sorted([path for path in programs_folder.glob("*.elf") if path.name != "hello_next.elf"],
                          key=lambda path: (path.name != "root_task.elf", path.name))
        # The typed libraries the programs import, modules like them (decisions/0120)
        programs += sorted(programs_folder.glob("*.library"))
        # The system configuration as data, which the build writes beside the root task, a module of the boot set (decisions/0110)
        if (programs_folder / SYSTEM_RECORDS).exists():
            programs.append(programs_folder / SYSTEM_RECORDS)
        if arguments.kernel_alone:
            programs = []
        bootloader = (programs_folder / "bootloader.efi").resolve()
        image_builder = arguments.image_builder
        if image_builder is None:
            build_slopos_tools(folder / "tools")
            image_builder = next((folder / "tools").glob("image_builder*"))
        image_builder = image_builder.resolve()
        # The kernel's own regions follow its command line; the image and the direct map, the generation's kaslr
        command_line = arguments.command_line + (" no_kaslr" if arguments.no_kaslr else "")
        image = None
        if not arguments.boot_disk:
            image = make_image(kernel.resolve(), [program.resolve() for program in programs], bootloader, image_builder, xorriso, folder,
                               command_line, not arguments.no_kaslr)
        serial = folder / "serial.txt"
        extra = (X86_IOMMU if not aarch64 and not arguments.no_iommu else []) + list(arguments.qemu_arguments)
        console = None
        disk = folder / "disk.img"
        # How long each phase takes, said at the end, to see where a test's time goes
        phases = []
        phase_started = time.monotonic()
        if arguments.boot_disk:
            make_boot_disk(disk, kernel.resolve(), [program.resolve() for program in programs], bootloader, image_builder, folder,
                           command_line, not arguments.no_kaslr, arguments.disk or "", arguments.stage_generation,
                           (programs_folder / "hello_next.elf").resolve() if arguments.stage_next_hello else None)
            extra += ["-drive", f"file={disk},if=none,id=disk,format=raw",
                      "-device", "virtio-blk-pci,drive=disk,disable-legacy=on,iommu_platform=on,bootindex=0"]
            phases.append(("making the disk", time.monotonic() - phase_started))
        elif arguments.disk is not None:
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
        booting_started = time.monotonic()
        keys = SerialKeys(serial, "r") if arguments.recovery_key else None
        if aarch64:
            code = run_aarch64(image, qemu, serial, arguments.timeout, arguments.cpu, extra, not arguments.no_iommu, keys,
                               arguments.allow_reboot)
        else:
            code = run(image, qemu, serial, arguments.timeout, arguments.cpu, extra, keys,
                       arguments.allow_reboot)
        phases.append(("boot 1", time.monotonic() - booting_started))
        if console is not None:
            console.thread.join(timeout=5)
        output = serial.read_text(errors="replace") if serial.exists() else ""
        # The same disk booted again, as a reboot would, for what the boots before wrote onto it (decisions/0116)
        later = []
        for boot in range(2, arguments.boots + 1):
            serial.unlink(missing_ok=True)
            booting_started = time.monotonic()
            if aarch64:
                again = run_aarch64(image, qemu, serial, arguments.timeout, arguments.cpu, extra, not arguments.no_iommu)
            else:
                again = run(image, qemu, serial, arguments.timeout, arguments.cpu, extra)
            phases.append((f"boot {boot}", time.monotonic() - booting_started))
            later.append((boot, again, serial.read_text(errors="replace") if serial.exists() else ""))
        unwritten = [expected for expected in arguments.expect_disk_block if not disk.exists() or not disk_block_starts(disk, expected)]
        image_bytes = disk.read_bytes() if disk.exists() and (arguments.expect_disk_text or arguments.refuse_disk_text) else b""
        unwritten += [f"text {text}" for text in arguments.expect_disk_text if text.encode() not in image_bytes]
        leaked = [text for text in arguments.refuse_disk_text if text.encode() in image_bytes]
        if arguments.serial is not None:
            arguments.serial.write_text(output)
    sys.stdout.write(output)
    for boot, again, text in later:
        print(f"boot.py: boot {boot}")
        sys.stdout.write(text)
    if console is not None:
        for line in console.lines():
            if line:
                print(f"[console] {line}")
    description = {TIMED_OUT: "timed out", NO_EXIT_CODE: "ended without an exit code"}.get(code, f"exited with {code}")
    print(f"boot.py: the kernel {description}", file=sys.stderr)
    print("boot.py: took " + ", ".join(f"{seconds:.1f} s {phase}" for phase, seconds in phases), file=sys.stderr)
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
        for text in leaked:
            print(f"boot.py: the disk holds {text!r}, which it mustn't", file=sys.stderr)
        later_failed = False
        for boot, again, text in later:
            if again != arguments.expect:
                print(f"boot.py: boot {boot} {description_of(again)}", file=sys.stderr)
                later_failed = True
            wanted = [line.split(":", 1)[1] for line in arguments.expect_boot_line if line.split(":", 1)[0] == str(boot)]
            for line in wanted:
                if line not in text.splitlines():
                    print(f"boot.py: boot {boot}'s serial output has no line {line!r}", file=sys.stderr)
                    later_failed = True
        return 0 if code == arguments.expect and not missing and not missing_shown and not unwritten and not leaked and not later_failed else 1
    return code


# What the firmware's console writes besides text: ANSI escape sequences (CSI and the like), and carriage returns
TERMINAL_ESCAPES = re.compile(r"\x1b(\[[0-9;=?]*[A-Za-z]|[()][0-9A-Za-z]|[0-9A-Za-z])|\r")


def run_efi(arguments: argparse.Namespace, qemu: Path, aarch64: bool) -> int:
    """
    Boots a UEFI program of SlopOS's build by itself (--efi): the firmware starts it from a FAT drive as its default
    boot file. Exit code 0 if it turned the machine off, with --expect's lines in its output once the console's
    escape sequences are taken out.
    """
    with tempfile.TemporaryDirectory(prefix="slopos-efi-") as temporary:
        folder = Path(temporary)
        programs_folder = arguments.programs
        if programs_folder is None:
            programs_folder = folder / "programs"
            build_slopos_programs(programs_folder, arguments.arch)
        program = programs_folder / f"{arguments.efi}.efi"
        if not program.is_file():
            sys.exit(f"boot.py: there's no {program.name} in the build")
        drive = folder / "drive"
        (drive / "EFI" / "BOOT").mkdir(parents=True)
        shutil.copy(program, drive / "EFI" / "BOOT" / ("BOOTAA64.EFI" if aarch64 else "BOOTX64.EFI"))
        serial = folder / "serial.txt"
        fat = f"fat:rw:{drive}"
        if aarch64:
            code = run_aarch64(None, qemu, serial, arguments.timeout, arguments.cpu,
                               ["-drive", f"if=none,id=efi,file={fat},format=raw", "-device", "virtio-blk-pci,drive=efi",
                                *arguments.qemu_arguments], False)
        else:
            code = run(None, qemu, serial, arguments.timeout, arguments.cpu,
                       ["-drive", f"file={fat},format=raw", *arguments.qemu_arguments])
        output = TERMINAL_ESCAPES.sub("", serial.read_text(errors="replace") if serial.exists() else "")
    sys.stdout.write(output)
    # Turned off, the program's way to end, rather than an exit code
    code = 0 if code == NO_EXIT_CODE else code
    print(f"boot.py: the program {description_of(code)}", file=sys.stderr)
    if arguments.expect is None:
        return code
    missing = [line for line in arguments.expect_line if line not in output.splitlines()]
    for line in missing:
        print(f"boot.py: the serial output has no line {line!r}", file=sys.stderr)
    return 0 if code == arguments.expect and not missing else 1


def description_of(code: int) -> str:
    """How a boot ended, as boot.py says it."""
    return {TIMED_OUT: "timed out", NO_EXIT_CODE: "ended without an exit code"}.get(code, f"exited with {code}")


if __name__ == "__main__":
    sys.exit(main())
