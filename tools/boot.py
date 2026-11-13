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
import ssl
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
# The TLS boot tests' test authority (decisions/0188, 13f): its root, and the peers' chains and keys
TLS_PEERS = ROOT / "tools" / "tls_peers"
# The Linux test VM chrony serves NTS on for the NTS boot tests (13g, --nts-server), as ssh reaches it, its key, and its
# address, which nts.slopos.test is
NTS_HOST = os.environ.get("SLOPOS_NTS_HOST", "claude@192.168.159.128")
NTS_KEY = Path(os.environ.get("SLOPOS_NTS_KEY", str(Path.home() / ".ssh" / "hemera_linux_vm")))
NTS_ADDRESS = os.environ.get("SLOPOS_NTS_ADDRESS", NTS_HOST.rpartition("@")[2])
# chrony's configuration there, run unprivileged: NTS-KE on 4460 with nts.slopos.test's certificate, NTP on an
# unprivileged port its NTS-KE names, serving its own clock as stratum 3, and setting nothing
CHRONY_CONF = """pidfile {home}/chronyd.pid
driftfile {home}/drift
ntsdumpdir {home}
ntsservercert {home}/nts.crt
ntsserverkey {home}/nts.key
ntsport 4460
port 11123
cmdport 0
allow all
local stratum 3
"""
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
               command_line: str, kaslr: bool, development: bool = True) -> Path:
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
    generated = subprocess.run([str(generation_builder), *(["--development"] if development else []), str(esp), str(store), "1",
                                "yes" if kaslr else "no", command_line, str(kernel)]
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


# Where each CPU was when a boot timed out, from QEMU (run_watched), printed with the failure: one entry a timeout
CPU_STATES: list[str] = []


def run_watched(command: list[str], timeout: float) -> int | None:
    """
    Runs QEMU until it ends or timeout passes, with a machine protocol socket of its own on the loopback. On a timeout
    every CPU's registers are asked for through it (info registers -a), kept in CPU_STATES, before QEMU is killed, so a
    hang says where each CPU was. Gives QEMU's exit code, or None for a timeout.
    """
    port = free_port()
    process = subprocess.Popen(command + ["-qmp", f"tcp:127.0.0.1:{port},server=on,wait=off"])
    try:
        return process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        CPU_STATES.append(cpu_states(port))
        process.kill()
        process.wait()
        return None


def cpu_states(port: int) -> str:
    """Every CPU's registers, as QEMU's monitor shows them, through the machine protocol on port; why not, if it can't."""
    monitor = Keyboard()
    monitor.port = port
    try:
        if not monitor.connect():
            return "QEMU's machine protocol didn't answer"
        message = {"execute": "human-monitor-command", "arguments": {"command-line": "info registers -a"}}
        monitor.connection.sendall(json.dumps(message).encode() + b"\n")
        while True:
            while b"\n" not in monitor.replies:
                data = monitor.connection.recv(65536)
                if not data:
                    return "QEMU's machine protocol closed"
                monitor.replies += data
            line, _, monitor.replies = monitor.replies.partition(b"\n")
            reply = json.loads(line)
            if "return" in reply:
                return str(reply["return"])
            if "error" in reply:
                return f"QEMU's monitor refused: {reply['error']}"
    except (OSError, ValueError) as error:
        return f"QEMU's machine protocol failed: {error}"


def run(image: Path | None, qemu: Path, serial: Path, timeout: float, cpu: str, extra: list[str],
        keys: "SerialKeys | None" = None, reboot: bool = False) -> int:
    """Boots the image, or with none the disk in extra, by UEFI, and gives the code the kernel wrote to the debug exit device."""
    if KVM_HOST is not None:
        if keys is not None:
            sys.exit("boot.py: --kvm can't hold a key down as the machine starts")
        return run_kvm(KVM_HOST, image, serial, timeout, extra, reboot)
    boot = ["-cdrom", str(image)] if image is not None else []
    command = [
        str(qemu), "-M", "q35", "-m", "512M", "-cpu", cpu, *boot,
        *serial_arguments(serial, keys), "-display", "none", "-nic", "none", *([] if reboot else ["-no-reboot"]),
        "-device", "isa-debug-exit,iobase=0xf4,iosize=0x04",
    ]
    firmware = find_tool("OVMF", ["edk2-x86_64-code.fd", "OVMF_CODE.fd", "OVMF.fd"], [qemu.parent / "share"])
    command += ["-drive", f"if=pflash,format=raw,readonly=on,file={firmware}"]
    if keys is not None:
        keys.thread.start()
    try:
        returncode = run_watched(command + extra, timeout)
    finally:
        if keys is not None:
            keys.thread.join(timeout=5)
    if returncode is None:
        return TIMED_OUT
    # An odd code came from the debug exit device; anything else is QEMU's own (a reset, a crash)
    return returncode >> 1 if returncode % 2 == 1 else NO_EXIT_CODE


# --kvm's Linux machine, user@address, when x86-64 boots there instead of here (decisions/0186)
KVM_HOST: str | None = None
# Its firmware, as Debian's ovmf package puts it
KVM_FIRMWARE = "/usr/share/OVMF/OVMF_CODE_4M.fd"


def run_kvm(host: str, image: Path | None, serial: Path, timeout: float, extra: list[str], reboot: bool) -> int:
    """
    Boots as run does, but in QEMU with KVM on host, a Linux machine, with the host's CPU, so a guest gets what the host
    gives it, as CET's shadow stacks (decisions/0186). The image, and every local file a QEMU argument names (file=...),
    are copied there first, and those files and the serial output copied back after, so a disk keeps what the boot
    wrote. Sockets the console uses aren't reachable there: a boot with them is refused.
    """
    key = os.environ.get("SLOPOS_KVM_KEY", str(Path.home() / ".ssh" / "hemera_linux_vm"))
    ssh = ["ssh", "-i", key, "-o", "BatchMode=yes", host]
    folder = f"/tmp/slopos-kvm-{os.getpid()}-{int(time.monotonic() * 1000)}"
    if any("socket," in argument for argument in extra):
        sys.exit("boot.py: --kvm can't take the console's input or read its screen")
    if subprocess.run(ssh + [f"mkdir -p {folder}"]).returncode != 0:
        sys.exit(f"boot.py: can't reach {host} for --kvm")
    copied: list[tuple[Path, str]] = []

    def remote(local: Path) -> str:
        """Copies a local file there once, giving its path there."""
        for already, there in copied:
            if already == local:
                return there
        there = f"{folder}/{len(copied)}-{local.name}"
        if subprocess.run(["scp", "-q", "-i", key, str(local), f"{host}:{there}"]).returncode != 0:
            sys.exit(f"boot.py: can't copy {local} to {host}")
        copied.append((local, there))
        return there

    def moved(argument: str) -> str:
        """The argument with each local file it names as file=... replaced by its copy there."""
        def replace(match: "re.Match[str]") -> str:
            local = Path(match.group(1))
            return f"file={remote(local)}" if local.is_file() else match.group(0)
        return re.sub(r"file=([^,]+)", replace, argument)

    boot = ["-cdrom", remote(image)] if image is not None else []
    there = [moved(argument) for argument in extra]
    # An IOMMU with interrupt remapping needs KVM's interrupt controller split
    machine = "q35,kernel-irqchip=split" if any("intel-iommu" in argument for argument in there) else "q35"
    command = [
        "qemu-system-x86_64", "-accel", "kvm", "-M", machine, "-m", "512M", "-cpu", "host", *boot,
        "-serial", f"file:{folder}/serial.txt", "-display", "none", "-nic", "none", *([] if reboot else ["-no-reboot"]),
        "-device", "isa-debug-exit,iobase=0xf4,iosize=0x04", "-drive", f"if=pflash,format=raw,readonly=on,file={KVM_FIRMWARE}",
        *there,
    ]
    quoted = " ".join(f"'{part}'" for part in command)
    result = subprocess.run(ssh + [f"timeout {int(timeout)} {quoted} < /dev/null; echo \"exit $?\""], capture_output=True, text=True)
    subprocess.run(["scp", "-q", "-i", key, f"{host}:{folder}/serial.txt", str(serial)], capture_output=True)
    for local, there_path in copied:
        if local != image:
            subprocess.run(["scp", "-q", "-i", key, f"{host}:{there_path}", str(local)])
    subprocess.run(ssh + [f"rm -rf {folder}"])
    ended = re.search(r"exit (\d+)", result.stdout)
    code = int(ended.group(1)) if ended else -1
    if code == 124:
        return TIMED_OUT
    return code >> 1 if code % 2 == 1 else NO_EXIT_CODE


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
        str(qemu), "-M", machine, "-m", "512M", "-cpu", cpu,
        *(["-global", "arm-smmuv3.stage=2"] if iommu else []),
        "-drive", f"if=pflash,format=raw,readonly=on,file={firmware}", *cd,
        *serial_arguments(serial, keys), "-display", "none", "-nic", "none", *([] if reboot else ["-no-reboot"]),
        "-semihosting-config", "enable=on,target=native",
    ]
    if keys is not None:
        keys.thread.start()
    try:
        returncode = run_watched(command + extra, timeout)
    finally:
        if keys is not None:
            keys.thread.join(timeout=5)
    if returncode is None:
        return TIMED_OUT
    # As with the debug exit device, the kernel's test_exit ends QEMU with (code << 1) | 1
    return returncode >> 1 if returncode % 2 == 1 else NO_EXIT_CODE


def serial_arguments(serial: Path, keys: "SerialKeys | None") -> list[str]:
    """The serial port's output kept in the file, or with keys, going through them."""
    return keys.qemu_arguments() if keys is not None else ["-serial", f"file:{serial}"]


class SerialKeys:
    """
    The serial port on a TCP socket QEMU serves on the loopback, in place of a file, for a key held down as the
    machine starts (--recovery-key): the firmware's console takes what arrives on the serial port as typed, so this
    sends the key over and over until the bootloader says what it boots, and keeps the output in the serial file.
    """

    def __init__(self, serial: Path, key: str, then: str = ""):
        self.port = free_port()
        self.serial = serial
        self.key = key.encode()
        # Typed once the bootloader's command line editor shows its prompt (--bootloader-edit)
        self.then = then.encode()
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
        typed = False
        with connection, self.serial.open("wb") as out:
            while True:
                answered = b"bootloader: booting generation" in shown or b"bootloader: editing the command line" in shown \
                    or b"isn't built for development" in shown
                held = not answered
                try:
                    if held:
                        connection.sendall(self.key)
                    elif self.then and not typed and b"bootloader: > " in shown:
                        connection.sendall(self.then)
                        typed = True
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


def boot_only(arguments, boot: int) -> list[str]:
    """The arguments for QEMU that --boot-qemu-argument gives one boot, by its number from 1."""
    return [each.split(":", 1)[1] for each in arguments.boot_qemu_argument if each.split(":", 1)[0] == str(boot)]


class NetworkPeers:
    """
    Peers on the development machine for the network's tests (decisions/0188, 13c), reached from the machine through
    QEMU's user-mode network at 10.0.2.2: a TCP echo server, a UDP echo server and a TCP sink, which reads everything
    and closes once its peer has finished, each on a free loopback port, which replace {tcp_echo}, {udp_echo} and
    {tcp_sink} in the kernel's command line and what's typed and expected; and a forward from a free loopback port to the
    machine's port 7, which this connects to once the serial output says the machine listens there, sending bytes and
    checking they come back. A virtio NIC on that network is added to QEMU's arguments.

    And a DNS server (13e), on a free loopback UDP port that replaces {dns}: peer.slopos.test is the development
    machine, 10.0.2.2 and QEMU's fec0::2 for it; any other name doesn't exist. QEMU's own DNS at 10.0.2.3 isn't used,
    as it asks the Internet.

    And TLS (13f): a TLS 1.3 echo server on a free loopback port that replaces {tls}, serving the certificate of the name
    the client asks for (SNI) from tools/tls_peers' test authority: rsa, ecdsa, wrong, expired and stranger.slopos.test,
    which the DNS peer gives as 10.0.2.2; and a forward to the machine's port 443, which this connects to once the serial
    output says the machine serves TLS there, checking machine.slopos.test's certificate against the authority's root
    and the echo of what it sends.

    And NTS (13g): a forging NTS server, forged.slopos.test, its NTS-KE on a free port that replaces {nts_forged}, which
    gives keys and cookies honestly over TLS, but answers NTP with authenticators it can't make, as it hasn't the key; and
    nts.slopos.test, the address of the NTS server chrony serves on the Linux test VM (NTS_ADDRESS, --nts-server).

    And SSH (decisions/0191, 14d): a forward to the machine's port 22, which, once the serial output says the SSH
    service listens there and a key's been added, this logs in to with the development machine's OpenSSH, as admin: a
    command run with the password, a wrong password refused, a command run with SSH_KEY, a shell on a terminal, a file
    put, listed and got with sftp and copied there and back with scp (14e), and last a command that fails (ssh_checks),
    whose end the SSH service logs.
    """

    LISTENING = "[user] test_network: listening on 7"
    SENT = 40000
    SERVING_TLS = "[user] test_network: serving TLS on 443"
    TLS_SENT = b"hello from the development machine"
    TLS_NAMES = ["rsa", "ecdsa", "wrong", "expired", "stranger"]
    SSH_LISTENING = "[user] ssh_service: listening on 22"
    SSH_KEY_ADDED = "[user] terminal: keys: added a key"
    SSH_CALLED = "{0}{1}"

    def __init__(self, serial: Path):
        self.serial = serial
        self.problem = None
        self.tcp = socket.socket()
        self.tcp.bind(("127.0.0.1", 0))
        self.tcp.listen()
        self.udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.udp.bind(("127.0.0.1", 0))
        self.sink = socket.socket()
        self.sink.bind(("127.0.0.1", 0))
        self.sink.listen()
        self.dns = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.dns.bind(("127.0.0.1", 0))
        self.forward = free_port()
        self.tls = socket.socket()
        self.tls.bind(("127.0.0.1", 0))
        self.tls.listen()
        self.tls_forward = free_port()
        self.ssh_forward = free_port()
        self.tls_contexts = {}
        for peer in self.TLS_NAMES:
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.minimum_version = ssl.TLSVersion.TLSv1_3
            context.load_cert_chain(TLS_PEERS / f"{peer}.pem")
            self.tls_contexts[f"{peer}.slopos.test"] = context
        self.tls_context = self.tls_contexts["ecdsa.slopos.test"]
        self.tls_context.sni_callback = self.choose_certificate
        self.nts_ke = socket.socket()
        self.nts_ke.bind(("127.0.0.1", 0))
        self.nts_ke.listen()
        self.nts_ntp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.nts_ntp.bind(("127.0.0.1", 0))
        self.nts_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.nts_context.minimum_version = ssl.TLSVersion.TLSv1_3
        self.nts_context.load_cert_chain(TLS_PEERS / "forged.pem")
        self.nts_context.set_alpn_protocols(["ntske/1"])
        for serve in (self.serve_tcp, self.serve_udp, self.serve_sink, self.serve_dns, self.connect_in, self.serve_tls,
                      self.connect_in_tls, self.serve_nts_ke, self.serve_forged_ntp, self.ssh_checks):
            threading.Thread(target=serve, daemon=True).start()

    def words(self, command_line: str) -> str:
        return command_line.replace("{tcp_echo}", str(self.tcp.getsockname()[1])).replace("{udp_echo}", str(self.udp.getsockname()[1])) \
            .replace("{tcp_sink}", str(self.sink.getsockname()[1])).replace("{dns}", str(self.dns.getsockname()[1])) \
            .replace("{tls}", str(self.tls.getsockname()[1])).replace("{nts_forged}", str(self.nts_ke.getsockname()[1]))

    def qemu_arguments(self) -> list[str]:
        return ["-netdev", f"user,id=n0,hostfwd=tcp:127.0.0.1:{self.forward}-:7,hostfwd=tcp:127.0.0.1:{self.tls_forward}-:443,"
                f"hostfwd=tcp:127.0.0.1:{self.ssh_forward}-:22",
                "-device", "virtio-net-pci,netdev=n0,disable-legacy=on,iommu_platform=on"]

    def serve_tcp(self) -> None:
        while True:
            try:
                connection, _ = self.tcp.accept()
            except OSError:
                return
            threading.Thread(target=self.echo, args=(connection,), daemon=True).start()

    @staticmethod
    def echo(connection: socket.socket) -> None:
        with connection:
            try:
                while True:
                    data = connection.recv(65536)
                    if not data:
                        break
                    connection.sendall(data)
                connection.shutdown(socket.SHUT_WR)
            except OSError:
                pass

    def serve_sink(self) -> None:
        while True:
            try:
                connection, _ = self.sink.accept()
            except OSError:
                return
            threading.Thread(target=self.drain, args=(connection,), daemon=True).start()

    @staticmethod
    def drain(connection: socket.socket) -> None:
        with connection:
            try:
                while connection.recv(1 << 20):
                    pass
                connection.shutdown(socket.SHUT_WR)
            except OSError:
                pass

    def serve_udp(self) -> None:
        while True:
            try:
                data, sender = self.udp.recvfrom(65536)
                self.udp.sendto(data, sender)
            except OSError:
                return

    # The names the DNS peer knows: each kind's records' data
    NAMES = {"peer.slopos.test": {1: [bytes([10, 0, 2, 2])], 28: [bytes([0xfe, 0xc0] + [0] * 13 + [2])]},
             **{f"{peer}.slopos.test": {1: [bytes([10, 0, 2, 2])]} for peer in TLS_NAMES},
             "forged.slopos.test": {1: [bytes([10, 0, 2, 2])]},
             "nts.slopos.test": {1: [bytes(int(part) for part in NTS_ADDRESS.split("."))]}}

    def serve_dns(self) -> None:
        while True:
            try:
                query, sender = self.dns.recvfrom(512)
            except OSError:
                return
            answer = self.answer_dns(query)
            if answer is not None:
                self.dns.sendto(answer, sender)

    @classmethod
    def answer_dns(cls, query: bytes) -> bytes | None:
        """An answer to a query of one question: its records from NAMES, or NXDOMAIN; None for one that isn't read."""
        if len(query) < 12:
            return None
        labels, at = [], 12
        while at < len(query) and query[at] != 0:
            length = query[at]
            labels.append(query[at + 1:at + 1 + length].decode("ascii", "replace").lower())
            at += 1 + length
        end = at + 5
        if end > len(query):
            return None
        kind = int.from_bytes(query[at + 1:at + 3], "big")
        records = cls.NAMES.get(".".join(labels))
        code = 0 if records is not None else 3
        found = records.get(kind, []) if records is not None else []
        header = query[0:2] + bytes([0x81, 0x80 | code]) + (1).to_bytes(2, "big") + len(found).to_bytes(2, "big") + bytes(4)
        answers = b"".join(b"\xc0\x0c" + kind.to_bytes(2, "big") + (1).to_bytes(2, "big") + (300).to_bytes(4, "big")
                           + len(data).to_bytes(2, "big") + data for data in found)
        return header + query[12:end] + answers

    def choose_certificate(self, connection: ssl.SSLObject, name: str | None, _: ssl.SSLContext) -> None:
        connection.context = self.tls_contexts.get(name or "", self.tls_context)

    def serve_tls(self) -> None:
        while True:
            try:
                connection, _ = self.tls.accept()
            except OSError:
                return
            threading.Thread(target=self.echo_tls, args=(connection,), daemon=True).start()

    def echo_tls(self, connection: socket.socket) -> None:
        """Echo over TLS until the client's close_notify, then send one; a client that refuses the handshake ends it."""
        try:
            with self.tls_context.wrap_socket(connection, server_side=True) as secure:
                while True:
                    data = secure.recv(65536)
                    if not data:
                        break
                    secure.sendall(data)
                secure.unwrap()
        except (OSError, ssl.SSLError):
            pass

    @staticmethod
    def ke_record(kind: int, body: bytes) -> bytes:
        return kind.to_bytes(2, "big") + len(body).to_bytes(2, "big") + body

    def serve_nts_ke(self) -> None:
        while True:
            try:
                connection, _ = self.nts_ke.accept()
            except OSError:
                return
            threading.Thread(target=self.forge_keys, args=(connection,), daemon=True).start()

    def forge_keys(self, connection: socket.socket) -> None:
        """NTS-KE, honestly: NTPv4, AES-SIV-CMAC-256, eight cookies, and this machine's forging NTP server."""
        try:
            with self.nts_context.wrap_socket(connection, server_side=True) as secure:
                asked = b""
                # The client's records, to its End
                while not any(asked[at:at + 4] == b"\x80\x00\x00\x00" for at in range(0, len(asked), 2)):
                    data = secure.recv(4096)
                    if not data:
                        return
                    asked += data
                answer = self.ke_record(0x8001, bytes(2)) + self.ke_record(0x8004, (15).to_bytes(2, "big"))
                answer += b"".join(self.ke_record(5, os.urandom(64)) for _ in range(8))
                answer += self.ke_record(0x8006, b"10.0.2.2") + self.ke_record(0x8007, self.nts_ntp.getsockname()[1].to_bytes(2, "big"))
                answer += self.ke_record(0x8000, b"")
                secure.sendall(answer)
                secure.unwrap()
        except (OSError, ssl.SSLError):
            pass

    def serve_forged_ntp(self) -> None:
        """Answer NTS's NTP as a forger does: the request's origin and identifier echoed, the authenticator made up."""
        while True:
            try:
                request, sender = self.nts_ntp.recvfrom(2048)
            except OSError:
                return
            if len(request) < 48:
                continue
            identifier, at = b"", 48
            while at + 4 <= len(request):
                kind, length = int.from_bytes(request[at:at + 2], "big"), int.from_bytes(request[at + 2:at + 4], "big")
                if length < 4:
                    break
                if kind == 0x0104:
                    identifier = request[at + 4:at + length]
                at += length
            now = int((time.time() + 2208988800) * (1 << 32)).to_bytes(8, "big")
            header = bytes([0x24, 2, 6, 0xec]) + bytes(8) + b"FRGD" + now + request[40:48] + now + now
            fields = (0x0104).to_bytes(2, "big") + (4 + len(identifier)).to_bytes(2, "big") + identifier
            fields += (0x0404).to_bytes(2, "big") + (56).to_bytes(2, "big") + (16).to_bytes(2, "big") + (32).to_bytes(2, "big")
            fields += os.urandom(48)
            self.nts_ntp.sendto(header + fields, sender)

    def connect_in_tls(self) -> None:
        while True:
            written = self.serial.read_text(errors="replace").splitlines() if self.serial.exists() else []
            if self.SERVING_TLS in written:
                break
            time.sleep(0.2)
        context = ssl.create_default_context(cafile=str(TLS_PEERS / "root.pem"))
        context.minimum_version = ssl.TLSVersion.TLSv1_3
        try:
            with socket.create_connection(("127.0.0.1", self.tls_forward), timeout=60) as connection:
                with context.wrap_socket(connection, server_hostname="machine.slopos.test") as secure:
                    secure.sendall(self.TLS_SENT)
                    back = bytearray()
                    while len(back) < len(self.TLS_SENT):
                        data = secure.recv(65536)
                        if not data:
                            break
                        back += data
                    secure.unwrap()
            if bytes(back) != self.TLS_SENT:
                self.problem = f"the machine's TLS echo on port 443 gave {len(back)} bytes back of {len(self.TLS_SENT)}, or other bytes"
        except (OSError, ssl.SSLError) as error:
            self.problem = f"the machine's TLS on port 443 failed: {error}"

    def ssh_checks(self) -> None:
        """Log in to the machine over SSH with the development machine's OpenSSH, once it listens and has the key."""
        while True:
            written = self.serial.read_text(errors="replace").splitlines() if self.serial.exists() else []
            if self.SSH_LISTENING in written and self.SSH_KEY_ADDED in written:
                break
            time.sleep(0.5)
        ssh = shutil.which("ssh") or "C:/Windows/System32/OpenSSH/ssh.exe"
        with tempfile.TemporaryDirectory(prefix="slopos-ssh-") as temporary:
            folder = Path(temporary)
            for name, password in (("right", "correct horse battery staple"), ("wrong", "not the password")):
                (folder / f"{name}.cmd").write_text(f"@echo {password}\r\n", encoding="ascii")
            key = folder / "key"
            key.write_text(SSH_KEY, encoding="ascii", newline="\n")
            base = [ssh, "-F", "none", "-p", str(self.ssh_forward), "-o", f"UserKnownHostsFile={folder / 'known_hosts'}",
                    "-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=60", "-o", "LogLevel=ERROR"]
            password = ["-o", "PreferredAuthentications=password", "-o", "PubkeyAuthentication=no", "-o", "NumberOfPasswordPrompts=1"]

            def run(arguments: list[str], askpass: str = "right", given: str | None = None) -> subprocess.CompletedProcess:
                environment = dict(os.environ, SSH_ASKPASS=str(folder / f"{askpass}.cmd"), SSH_ASKPASS_REQUIRE="force", DISPLAY="none")
                return subprocess.run(base + arguments, input=given, capture_output=True, text=True, timeout=240, env=environment)

            try:
                ran = run(password + ["admin@127.0.0.1", "test_shell_calls 3 after"])
                if ran.returncode != 0 or self.SSH_CALLED.format("after", 3) not in ran.stdout:
                    self.problem = f"a command run with the password gave {ran.returncode}: {ran.stdout!r} {ran.stderr!r}"
                    return
                ran = run(password + ["admin@127.0.0.1", "test_shell_calls 3 after"], askpass="wrong")
                if ran.returncode != 255:
                    self.problem = f"a wrong password gave {ran.returncode}: {ran.stdout!r} {ran.stderr!r}"
                    return
                ran = run(["-i", str(key), "-o", "IdentitiesOnly=yes", "-o", "PreferredAuthentications=publickey",
                           "admin@127.0.0.1", "test_shell_calls 4 key"])
                if ran.returncode != 0 or self.SSH_CALLED.format("key", 4) not in ran.stdout:
                    self.problem = f"a command run with the key gave {ran.returncode}: {ran.stdout!r} {ran.stderr!r}"
                    return
                ran = run(password + ["-tt", "admin@127.0.0.1"], given="test_shell_calls 5 shell\rexit\r")
                if self.SSH_CALLED.format("shell", 5) not in ran.stdout:
                    self.problem = f"a shell on a terminal gave {ran.returncode}: {ran.stdout!r} {ran.stderr!r}"
                    return
                # SFTP (14e): a file put, listed, got back, a directory made, the file moved into it; then scp both ways
                sent = os.urandom(300000)
                (folder / "sent.bin").write_bytes(sent)
                (folder / "batch").write_text("put sent.bin\nls\nget sent.bin back.bin\nmkdir folder\nrename sent.bin folder/moved.bin\n"
                                              "ls folder\n", encoding="ascii")
                sftp = shutil.which("sftp") or "C:/Windows/System32/OpenSSH/sftp.exe"
                scp = shutil.which("scp") or "C:/Windows/System32/OpenSSH/scp.exe"
                options = ["-F", "none", "-P", str(self.ssh_forward), "-o", f"UserKnownHostsFile={folder / 'known_hosts'}",
                           "-o", "StrictHostKeyChecking=accept-new", "-o", "LogLevel=ERROR"] + password
                environment = dict(os.environ, SSH_ASKPASS=str(folder / "right.cmd"), SSH_ASKPASS_REQUIRE="force", DISPLAY="none")
                # The commands on its input: -b would be batch mode, which asks for no password
                ran = subprocess.run([sftp, *options, "admin@127.0.0.1"], cwd=folder, capture_output=True,
                                     input=(folder / "batch").read_text(encoding="ascii"),
                                     text=True, timeout=240, env=environment)
                back = (folder / "back.bin").read_bytes() if (folder / "back.bin").exists() else b""
                if ran.returncode != 0 or back != sent or "moved.bin" not in ran.stdout:
                    self.problem = f"sftp gave {ran.returncode}, {len(back)} bytes back: {ran.stdout!r} {ran.stderr!r}"
                    return
                ran = subprocess.run([scp, "-s", *options, str(folder / "sent.bin"), "admin@127.0.0.1:copied.bin"], cwd=folder,
                                     capture_output=True, text=True, timeout=240, env=environment)
                if ran.returncode == 0:
                    ran = subprocess.run([scp, "-s", *options, "admin@127.0.0.1:copied.bin", str(folder / "again.bin")], cwd=folder,
                                         capture_output=True, text=True, timeout=240, env=environment)
                again = (folder / "again.bin").read_bytes() if (folder / "again.bin").exists() else b""
                if ran.returncode != 0 or again != sent:
                    self.problem = f"scp gave {ran.returncode}, {len(again)} bytes back: {ran.stdout!r} {ran.stderr!r}"
                    return
                # Last, so its end in the serial output says every check's run
                ran = run(password + ["admin@127.0.0.1", "no_such_program"])
                if ran.returncode != 1:
                    self.problem = f"a command that fails gave {ran.returncode}: {ran.stdout!r} {ran.stderr!r}"
                    return
                print("ssh: logged in with a password and a key, ran commands, and a shell on a terminal", flush=True)
            except (OSError, subprocess.TimeoutExpired) as error:
                self.problem = f"OpenSSH couldn't log in: {error}"
            if self.problem is not None:
                print(f"ssh: {self.problem}", flush=True)

    def connect_in(self) -> None:
        while True:
            written = self.serial.read_text(errors="replace").splitlines() if self.serial.exists() else []
            if self.LISTENING in written:
                break
            time.sleep(0.2)
        sent = bytes((i * 7 + 3) & 0xff for i in range(self.SENT))
        try:
            with socket.create_connection(("127.0.0.1", self.forward), timeout=20) as connection:
                connection.sendall(sent)
                connection.shutdown(socket.SHUT_WR)
                back = bytearray()
                while True:
                    data = connection.recv(65536)
                    if not data:
                        break
                    back += data
            if bytes(back) != sent:
                self.problem = f"the machine's echo on port 7 gave {len(back)} bytes back of {len(sent)}, or other bytes"
        except OSError as error:
            self.problem = f"the machine's port 7 couldn't be reached through the forward: {error}"


# The private key of the key boot_tests.py's SSH test types into key.pub on the machine (ssh-keygen -t ed25519 made it,
# for the tests only)
SSH_KEY = """-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACBHGbroFg4trZq0hMw+WeSf0EYbeqUurFwnc3lFuqiWNgAAAJDAYp01wGKd
NQAAAAtzc2gtZWQyNTUxOQAAACBHGbroFg4trZq0hMw+WeSf0EYbeqUurFwnc3lFuqiWNg
AAAEAkFA+yIfbogRYAP7cVmJVXuby0PjtTmg7ZIWYdCPhJ8EcZuugWDi2tmrSEzD5Z5J/Q
Rht6pS6sXCdzeUW6qJY2AAAAC3ZlY3RvckB0ZXN0AQI=
-----END OPENSSH PRIVATE KEY-----
"""


class PowerButton(Keyboard):
    """
    The machine's power button, pressed through QEMU's machine protocol (system_powerdown) once the serial output has a
    line: an ACPI power button event on x86-64's q35, a GPIO key on AArch64's virt (decisions/0182, P3).
    """

    def __init__(self, serial: Path, after: str):
        super().__init__()
        self.serial = serial
        self.after = after
        self.thread = threading.Thread(target=self.press_when_ready, daemon=True)

    def qemu_arguments(self) -> list[str]:
        return ["-qmp", f"tcp:127.0.0.1:{self.port},server=on,wait=off"]

    def press_when_ready(self) -> None:
        while True:
            written = self.serial.read_text(errors="replace").splitlines() if self.serial.exists() else []
            if self.after in written:
                break
            time.sleep(0.2)
        try:
            # A second for what follows the line, as the system settles
            time.sleep(1)
            if self.connect():
                self.command("system_powerdown")
        except OSError:
            pass


class ConsoleLink:
    """
    A virtio console whose other end is a TCP socket QEMU serves on the loopback (a file can't be typed into on
    Windows): this connects to it, waits for the console's banner, types input into it, and keeps what it shows. QEMU
    waits for the connection before it starts the machine, since what's written with nothing connected is lost. The
    i-th line typed is typed at the i-th banner, so a console that's connected again gets the next; lines for a
    keyboard are typed at the first banner, once the serial lines have been.
    """

    def __init__(self, typed: list[str], keyed: list[str], keyboard: "Keyboard | None", screen_after: str | None = None,
                 screenshot: Path | None = None, typed_after: list[str] | None = None, done_when: list[str] | None = None,
                 serial_done: Path | None = None, serial_done_when: list[str] | None = None, done_key: bytes = b"p"):
        self.port = free_port()
        self.typed = typed
        # With --shut-down-when-done, the lines whose showing, once the first line's typed, has it shut the system down;
        # None without it
        self.done_when = done_when
        # And the serial output's file, and the lines it has to have first: the expected ones but those of a run's end
        self.serial_done = serial_done
        self.serial_done_when = serial_done_when or []
        # The key typed after the secure attention key once it's done: P shuts down, R restarts (decisions/0182)
        self.done_key = done_key
        self.typed_first = threading.Event()
        # The first line is typed once the console shows the first of these too, so what's typed doesn't land in the middle
        # of it; or, with \\w in it, from the banner, each \\w waiting for the next of them
        self.typed_after = typed_after or []
        self.waits = 0
        # Where in what's shown the last wait ended: the next looks only at what's shown after it, so a line waited for
        # again waits for its next showing, not one from before
        self.waited_to = 0
        self.keyed = keyed
        self.keyboard = keyboard
        # Once the console shows this line, the screen's taken through the machine protocol into screenshot
        self.screen_after = screen_after
        self.screenshot = screenshot
        self.screen_taken = False
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
                    if banners == 0 and self.typed and self.typed_after:
                        # A line that waits partway (\w) starts at the banner; any other, once typed_after shows
                        target = self.type_waiting if "\\w" in self.typed[0] else self.type_after
                        threading.Thread(target=target, args=(connection,), daemon=True).start()
                    elif banners < len(self.typed):
                        type_into(connection, self.typed[banners])
                        if banners == 0:
                            self.typed_first.set()
                    if banners == 0 and not self.typed:
                        self.typed_first.set()
                    if banners == 0 and self.done_when is not None:
                        threading.Thread(target=self.shut_down_when_done, args=(connection,), daemon=True).start()
                    if banners == 0 and self.keyboard is not None and (self.keyed or self.screen_after):
                        threading.Thread(target=self.type_keys, daemon=True).start()
                    banners += 1

    def type_after(self, connection: socket.socket) -> None:
        """The first line, typed once the console shows typed_after."""
        self.wait_for_after()
        try:
            type_into(connection, self.typed[0])
        except OSError:
            pass
        self.typed_first.set()

    def type_waiting(self, connection: socket.socket) -> None:
        """The first line, typed now, waiting where it has \\w until the console shows typed_after."""
        try:
            type_into(connection, self.typed[0], self.wait_for_after)
        except OSError:
            pass
        self.typed_first.set()

    def shut_down_when_done(self, connection: socket.socket) -> None:
        """
        Once the first line's typed, every line of done_when is shown, and every line of serial_done_when is in the serial
        output, the secure attention key and done_key, P, which shuts the system down (decisions/0180), or R, which
        restarts it (decisions/0182): a second apart, as the terminal service takes the key apart from what follows it.
        """
        self.typed_first.wait()
        while True:
            shown = self.lines()
            written = self.serial_done.read_text(errors="replace").splitlines() \
                if self.serial_done is not None and self.serial_done.exists() else []
            if all(line in shown for line in self.done_when) and all(line in written for line in self.serial_done_when):
                break
            time.sleep(0.2)
        try:
            time.sleep(1)
            connection.sendall(b"\x1b[3;7~")
            time.sleep(1)
            connection.sendall(self.done_key)
        except OSError:
            pass

    def wait_for_after(self) -> None:
        """Until the console shows the next line to wait for, after where the last wait ended."""
        if self.waits >= len(self.typed_after):
            return
        line = self.typed_after[self.waits]
        self.waits += 1
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            shown = self.shown
            if line in [each.rstrip("\r") for each in plain_text(shown[self.waited_to:]).split("\n")]:
                self.waited_to = len(shown)
                return
            time.sleep(0.05)

    def type_keys(self) -> None:
        """
        The keyboard's lines, typed in turn; the line \\code types the code the terminal service's status line shows for a
        new keyboard (src/services/input_service), once it shows one, and waits a second for it to be taken.
        """
        try:
            if not self.keyboard.connect():
                return
            for line in self.keyed:
                if line != "\\code":
                    self.keyboard.type_line(line)
                    continue
                deadline = time.monotonic() + 30
                found = None
                while found is None and time.monotonic() < deadline:
                    found = KEYBOARD_CODE.search(self.shown)
                    time.sleep(0.1)
                if found is not None:
                    self.keyboard.type_line(found.group(1))
                    time.sleep(1)
            if self.screen_after is not None:
                deadline = time.monotonic() + 30
                while self.screen_after not in self.lines() and time.monotonic() < deadline:
                    time.sleep(0.1)
                # Time for the terminal service to draw what it showed on the serial line
                time.sleep(0.5)
                self.keyboard.command("screendump", {"filename": str(self.screenshot)})
                self.screen_taken = True
        except OSError:
            pass

    def lines(self) -> list[str]:
        return [line.rstrip("\r") for line in plain_text(self.shown).split("\n")]


def console_drawn(screenshot: Path) -> str | None:
    """
    Whether a screenshot (QEMU's screendump, a PPM) shows the console drawn by the terminal service: a status line, a
    band a cell tall mostly lit (it's inverse) and as wide as 80 cells (of 12 pixels, or 8 on a framebuffer narrower
    than 960), with text lit below it. None if it does, or what's wrong.
    """
    data = screenshot.read_bytes()
    # SLOPOS_SCREENSHOT=<path> keeps it, to look at
    if os.environ.get("SLOPOS_SCREENSHOT"):
        Path(os.environ["SLOPOS_SCREENSHOT"]).write_bytes(data)
    parts = data.split(b"\n", 3)
    if len(parts) < 4 or parts[0] != b"P6":
        return "the screenshot isn't a PPM"
    width, height = (int(value) for value in parts[1].split())
    pixels = parts[3]

    def lit(x: int, y: int) -> bool:
        at = (y * width + x) * 3
        return max(pixels[at:at + 3]) >= 0x80

    cell_width, cell_height = (12, 24) if width >= 960 and height >= 576 else (8, 16)
    # Its letters are dark on it, so most of the band, not all of it
    wide = 80 * cell_width * 6 // 10
    lit_rows = [y for y in range(height) if sum(lit(x, y) for x in range(0, width, 4)) * 4 >= wide]
    if len(lit_rows) < cell_height - 4:
        return "no status line: no band of lit rows as wide as the console"
    top = lit_rows[0]
    below = sum(lit(x, y) for y in range(top + cell_height, min(height, top + cell_height * 24)) for x in range(0, width, 2))
    if below < 200:
        return "nothing drawn below the status line"
    return None


# The starts of the serial lines a run says only as it ends, which --shut-down-when-done doesn't wait for, as they come
# after the shutdown it brings
RUN_END_LINES = ("[info] root task ended", "[info] objects left", "[user] root task: shutting down", "[user] supervisor: the console asked",
                 "[user] root task: restarting", "[user] root task: the machine can't", "[info] turning the machine off",
                 "[info] restarting the machine", "[user] supervisor: stopped", "[user] supervisor: killed")

# What the status line says while a new keyboard waits for its code
KEYBOARD_CODE = re.compile("a new keyboard: type ([0-9]+) and Enter")


# The terminal service's status line, drawn between a saved and a restored cursor (ESC 7, ESC 8), and the other sequences
# the VT adapter sends (src/vt): CSI's, and OSC 8's links
STATUS_LINE = re.compile("\x1b7.*?\x1b8", re.DOTALL)
CURSOR_MOVE = re.compile("\x1b\\[[0-9;]*H")
CSI = re.compile("\x1b\\[[0-9;?<>=]*[ -/]*[@-~]")
OSC = re.compile("\x1b\\].*?(\x1b\\\\|\x07)", re.DOTALL)


def plain_text(shown: str) -> str:
    """What a terminal shows as lines of text: the status line left out, a cursor move a line break, sequences gone."""
    return CSI.sub("", CURSOR_MOVE.sub("\n", OSC.sub("", STATUS_LINE.sub("", shown))))


def type_into(connection: socket.socket, line: str, wait=None) -> None:
    """
    line typed, then a line break: escapes in it as Python writes them (\\e for ESC), \\p a second's pause, so a key
    the terminal service takes for itself arrives apart from what follows it, and \\w, with wait, waits for it.
    """
    parts = re.split(r"(\\p|\\w)", line.replace("\\e", "\\x1b"))
    for i, part in enumerate(parts):
        if part == "\\p":
            time.sleep(1)
            continue
        if part == "\\w":
            if wait is not None:
                wait()
            continue
        data = part.encode("latin-1", "backslashreplace").decode("unicode_escape")
        connection.sendall((data + ("\n" if i == len(parts) - 1 else "")).encode())


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
BOOT_DISK_SECTORS = 272384
# The programs the bootloader loads from the boot disk, enough to reach the system volume, which holds every program; the rest
# come from it (src/system_config's boot_set, decisions/0089)
BOOT_SET = ["root_task", "entropy", "process_manager", "scheduler", "platform", "supervisor", "events_service", "bundle_store_service", "clock", "acpi_service", "power_button", "virtio_blk", "storage_manager", "partition_server",
            "fat_server", "container_service", "volume_server"]
# The system configuration, which the build writes beside the programs
SYSTEM_RECORDS = "system.records"
BOOT_ESP_SECTORS = 131072
# 64 MiB: every program twice, as modules and in the bundle store, generation 1's objects and a staged generation's,
# with room to grow (31 MiB of 32 was full on 2026-11-11, and a staged generation didn't fit)
BOOT_SYSTEM_SECTORS = 131072
# With --debug-files, the system volume and the disk grow by this much for the programs' debug files (decisions/0185)
DEBUG_FILES_SECTORS = 98304


# The encrypted volume the image builder makes beside the system volume, and its passphrase, which the disk check
# unlocks it with (src/services/disk_check/sealed_check.hsc)
SEALED_VOLUME = "sealed"

# The time zones the system volume has in zoneinfo/, as std/time reads them (knowledge/decisions/0164), from Python's
# tzdata package: the common ones, for now
ZONES = ["UTC", "Etc/UTC", "Europe/London", "Europe/Dublin", "Europe/Lisbon", "Europe/Paris", "Europe/Berlin",
         "Europe/Madrid", "Europe/Rome", "Europe/Amsterdam", "Europe/Stockholm", "Europe/Warsaw", "Europe/Athens",
         "Europe/Helsinki", "Europe/Istanbul", "Europe/Moscow", "America/New_York", "America/Chicago", "America/Denver",
         "America/Phoenix", "America/Los_Angeles", "America/Anchorage", "America/Toronto", "America/Vancouver",
         "America/Mexico_City", "America/Sao_Paulo", "America/Argentina/Buenos_Aires", "Pacific/Honolulu",
         "Asia/Tokyo", "Asia/Seoul", "Asia/Shanghai", "Asia/Hong_Kong", "Asia/Singapore", "Asia/Kolkata", "Asia/Dubai",
         "Asia/Jakarta", "Australia/Sydney", "Australia/Melbourne", "Australia/Brisbane", "Australia/Adelaide",
         "Australia/Perth", "Pacific/Auckland", "Africa/Johannesburg", "Africa/Cairo", "Africa/Lagos", "Africa/Nairobi"]


def copy_zones(into: Path) -> None:
    """ZONES' TZif files, from Python's tzdata, into a folder that becomes the system volume's zoneinfo/."""
    try:
        import tzdata
    except ImportError:
        sys.exit("boot.py: the system volume's time zones come from Python's tzdata package: pip install tzdata")
    source = Path(tzdata.__file__).parent / "zoneinfo"
    for zone in ZONES:
        target = into / zone
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(source / zone, target)
SEALED_PASSPHRASE = "slopos test passphrase"


def make_boot_disk(path: Path, kernel: Path, programs: list[Path], bootloader: Path, image_builder: Path, folder: Path,
                   command_line: str, kaslr: bool, mark: str, staged: str | None = None, staged_next: Path | None = None,
                   development: bool = True, debug_files: bool = False) -> None:
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
    copy_zones(system / "zoneinfo")
    # The trust store (decisions/0188, 13f), with the TLS boot tests' test root
    (system / "trust").mkdir()
    shutil.copy(TLS_PEERS / "root.pem", system / "trust" / "slopos_test_root.pem")
    # The bundle store, with a bundle for every program outside the boot set, which the supervisor loads from it, and
    # with debug_files each one's debug file too (decisions/0185), which a test that debugs asks for
    store_builder = next(image_builder.parent.glob("store_builder*"))
    with_debug = ["--debug-files"] if debug_files else []
    stored = subprocess.run([str(store_builder), *with_debug, str(system / "store")] + [str(program) for program in programs
                                                                           if program.stem not in BOOT_SET and program.suffix == ".elf"],
                            capture_output=True, text=True)
    if stored.returncode != 0:
        sys.exit(f"boot.py: the store builder failed:\n{stored.stdout}{stored.stderr}")
    # Generation 1 (decisions/0113): the kernel and the boot set as objects named by their hashes, and its record, the
    # root task first
    boot_set = [program for program in programs if program.stem in BOOT_SET or program.name == SYSTEM_RECORDS or program.suffix == ".library"]
    generation_builder = next(image_builder.parent.glob("generation_builder*"))
    # The recovery generation beside it, of the same boot set (decisions/0118), which the recovery key boots
    generated = subprocess.run([str(generation_builder), "--recovery", *(["--development"] if development else []), str(esp),
                                str(system / "store"), "1", "yes" if kaslr else "no",
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
            shutil.copy(staged_next.with_suffix(".docs"), renamed / "hello.docs")
            stored = subprocess.run([str(store_builder), *with_debug, str(system / "store")] + [
                str(renamed / "hello.elf") if program.stem == "hello" else str(program) for program in programs
                if program.stem not in BOOT_SET and program.suffix == ".elf"], capture_output=True, text=True)
            if stored.returncode != 0:
                sys.exit(f"boot.py: the store builder failed on the next build:\n{stored.stdout}{stored.stderr}")
        staging = subprocess.run([str(generation_builder), "--stage", str(system), str(system / "store"), "2", "yes" if kaslr else "no",
                                  staged, str(kernel)] + [str(program) for program in boot_set], capture_output=True, text=True)
        if staging.returncode != 0:
            sys.exit(f"boot.py: the generation builder couldn't stage generation 2:\n{staging.stdout}{staging.stderr}")
    more = DEBUG_FILES_SECTORS if debug_files else 0
    built = subprocess.run([str(image_builder), str(path), str(BOOT_DISK_SECTORS + more), f"--sealed={SEALED_VOLUME}:{SEALED_PASSPHRASE}",
                            f"test,{PARTITIONS[0][0]},{PARTITIONS[0][2]}",
                            f"test,{PARTITIONS[1][0]},{PARTITIONS[1][2]}",
                            f"esp,EFI system partition,{BOOT_ESP_SECTORS},{esp}", f"slopfs,SlopOS system,{BOOT_SYSTEM_SECTORS + more},{system}"],
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


def start_nts_server() -> None:
    """
    Start chrony on the Linux test VM as the NTS server nts.slopos.test, if it isn't running there with this test
    authority's certificate already: its certificate, key and configuration copied to ~/slopos-nts, and chronyd run
    unprivileged (-U), setting no clock (-x). Two boots at once may ask; a lock there makes one start it.
    """
    home = "$HOME/slopos-nts"
    files = {"nts.crt": (TLS_PEERS / "nts.crt").read_text(), "nts.key": (TLS_PEERS / "nts.key").read_text(),
             "chrony.conf": CHRONY_CONF.format(home=f"/home/{NTS_HOST.partition('@')[0]}/slopos-nts")}
    script = [f"set -e; mkdir -p {home}; cd {home}"]
    for name, text in files.items():
        script.append(f"cat > {name}.new <<'SLOPOS_EOF'\n{text}SLOPOS_EOF")
    script.append("""chmod 600 nts.key.new
exec 9>lock
flock 9
if [ -f chronyd.pid ] && kill -0 "$(cat chronyd.pid)" 2>/dev/null; then
    if cmp -s nts.crt.new nts.crt && cmp -s chrony.conf.new chrony.conf; then exit 0; fi
    kill "$(cat chronyd.pid)"; sleep 1
fi
for name in nts.crt nts.key chrony.conf; do mv "$name.new" "$name"; done
# A copy of chronyd: AppArmor's profile for /usr/sbin/chronyd won't let it read a configuration in a home directory
cp /usr/sbin/chronyd chronyd
./chronyd -U -x -f "$PWD/chrony.conf" </dev/null >/dev/null 2>&1
sleep 1""")
    result = subprocess.run(["ssh", "-i", str(NTS_KEY), "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", NTS_HOST, "bash -s"],
                            input=("\n".join(script) + "\n").encode(), capture_output=True)
    # As bytes: in text, Windows would end each line with \r\n, and bash would take the \r as part of each word
    if result.returncode != 0:
        sys.exit(f"boot.py: chrony couldn't be started on {NTS_HOST}:\n"
                 f"{result.stdout.decode(errors='replace')}{result.stderr.decode(errors='replace')}")


def disk_block_starts(path: Path, expected: str) -> bool:
    """Whether the image has a block starting with text, for an expectation written as N=text, N counting the disk's blocks."""
    number, _, text = expected.partition("=")
    image = path.read_bytes()
    start = int(number) * BLOCK_BYTES
    return image[start:start + len(text)] == text.encode()


def main() -> int:
    # What a console shows may have characters the output's encoding hasn't, as Windows' code page lacks some: escaped
    sys.stdout.reconfigure(errors="backslashreplace")
    parser = argparse.ArgumentParser(description="Boots a kernel in QEMU through SlopOS's own bootloader.")
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--kernel", type=Path, help="the kernel's ELF")
    source.add_argument("--package", type=Path, help="a kernel package to build first (default: SlopOS's, through src/build)")
    parser.add_argument("--programs", type=Path, help="a folder of programs to carry as modules (default: SlopOS's, built, without --kernel)")
    parser.add_argument("--linker-script", type=Path, help="the linker script, with --package")
    parser.add_argument("--command-line", default="test_exit", help="the kernel's command line")
    parser.add_argument("--cpu", default=DEFAULT_CPU, help="QEMU's CPU model")
    parser.add_argument("--kvm", metavar="USER@ADDRESS",
                        help="boot x86-64 in QEMU with KVM on this Linux machine, with its CPU (-cpu host) rather than --cpu, as CET's "
                             "boot tests do (decisions/0186); SLOPOS_KVM_KEY is the SSH key (default ~/.ssh/hemera_linux_vm), and the "
                             "machine needs qemu-system-x86_64 and Debian's ovmf")
    parser.add_argument("--expect", type=int, help="the exit code the kernel should write; exits 0 if it does")
    parser.add_argument("--expect-line", action="append", default=[],
                        help="a line the serial output should contain, with --expect; may be repeated")
    parser.add_argument("--expect-line-start", action="append", default=[],
                        help="the start of a line the serial output should contain, for a line part of which changes from "
                        "boot to boot, with --expect; may be repeated")
    parser.add_argument("--timeout", type=float, default=30, help="seconds before giving up")
    parser.add_argument("--arch", choices=["x86_64", "aarch64"], default="x86_64", help="the architecture to build and boot for")
    parser.add_argument("--no-kaslr", action="store_true", help="the same addresses every boot: no random kernel base or direct map")
    parser.add_argument("--no-iommu", action="store_true",
                        help="no IOMMU: by default q35 has VT-d and virt an SMMUv3, and virtio devices this adds go through it")
    parser.add_argument("--serial", type=Path, help="also keep the serial output in this file")
    parser.add_argument("--console-input", action="append", default=[],
                        help="a line to type into a virtio console, which this adds, once it shows its banner; may be repeated. "
                        "Escapes are Python's (\\e is ESC, as \\e[3;7~ is Ctrl+Alt+Delete), \\p waits a second, and \\w waits for "
                        "--console-input-after's line, the first line then typed from the banner")
    parser.add_argument("--console-input-after", action="append", default=[],
                        help="type the first --console-input once the virtio console shows this line too, not only its banner; "
                        "may be repeated, each \\w in the line waiting for the next")
    parser.add_argument("--expect-console-line", action="append", default=[],
                        help="a line the virtio console should show, with --expect; may be repeated")
    parser.add_argument("--screen-after",
                        help="once the virtio console shows this line, take the screen and check the console's drawn on it, "
                        "with --expect; adds a virtio keyboard for the machine protocol, and on AArch64 a ramfb framebuffer")
    parser.add_argument("--expect-console-start", action="append", default=[],
                        help="the start of a line the virtio console should show, for a line part of which changes from boot "
                        "to boot, with --expect; may be repeated. Unlike --expect-console-line, it isn't waited for")
    parser.add_argument("--expect-console-end", action="append", default=[],
                        help="the end of a line the virtio console should show, for a line whose start changes from boot to "
                        "boot, with --expect; may be repeated, and isn't waited for")
    parser.add_argument("--expect-console-contains", action="append", default=[],
                        help="text a line the virtio console shows should have somewhere in it, with --expect; may be "
                        "repeated, and isn't waited for")
    parser.add_argument("--refuse-console-line", action="append", default=[],
                        help="a line the virtio console mustn't show, with --expect; may be repeated")
    parser.add_argument("--shut-down-when-done", action="store_true",
                        help="once every --expect-console-line is shown and every --console-input typed, type the secure "
                        "attention key and P, which shuts the system down (decisions/0180), rather than waiting out its settle")
    parser.add_argument("--nts-server", action="store_true",
                        help="start chrony on the Linux test VM (SLOPOS_NTS_HOST) as the NTS server nts.slopos.test, "
                        "with the test authority's certificate (decisions/0188, 13g)")
    parser.add_argument("--network-peers", action="store_true",
                        help="a virtio NIC on QEMU's user-mode network, and echo peers on this machine for test_network: "
                        "{tcp_echo} and {udp_echo} in the command line are their ports, and port 7 on the machine is "
                        "connected to and checked once it listens (decisions/0188)")
    parser.add_argument("--power-button-after",
                        help="press the machine's power button, through QEMU's machine protocol, once the serial output has "
                        "this line (decisions/0182)")
    parser.add_argument("--restart-when-done", action="store_true",
                        help="as --shut-down-when-done, but R, which restarts the system (decisions/0182); with test_power on "
                        "the command line the machine resets, which QEMU, without --allow-reboot, takes as its end")
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
    parser.add_argument("--boot-qemu-argument", action="append", default=[],
                        help="<boot>:<argument>, an argument for QEMU in that boot only, from 1, after the others, as -rtc's "
                        "differing from boot to boot")
    parser.add_argument("--expect-boot-line-start", action="append", default=[],
                        help="with --boots: <boot>:<start>, the start of a line that boot's serial output must have, from 2")
    parser.add_argument("--stage-generation",
                        help="with --boot-disk: stage generation 2 on the system volume, the same programs with this command line, "
                             "for the update service to install (decisions/0116)")
    parser.add_argument("--stage-next-hello", action="store_true",
                        help="with --stage-generation: generation 2's store root has hello's next build (hello_next.elf) as hello's "
                             "bundle, so it changes only a service, which the supervisor applies live (decisions/0126)")
    parser.add_argument("--kernel-alone", action="store_true",
                        help="boot the kernel with no modules, its generation's boot set empty; --programs still gives the bootloader")
    parser.add_argument("--debug-files", action="store_true",
                        help="with --boot-disk: put each program's debug file in the bundle store, for the debugger and "
                             "crash reports' lines (decisions/0185)")
    parser.add_argument("--release-generation", action="store_true",
                        help="build the generation as a release one, not for development, so the bootloader won't let its "
                             "command line be edited (decisions/0181, F7)")
    parser.add_argument("--bootloader-edit",
                        help="press the bootloader's edit key, e, as the machine starts, and type this after the command line it "
                             "shows, then Enter (decisions/0181, F7); the first boot only")
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
    global KVM_HOST
    KVM_HOST = arguments.kvm
    if KVM_HOST is not None and arguments.arch == "aarch64":
        sys.exit("boot.py: --kvm boots x86-64 only")

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
        serial = folder / "serial.txt"
        if arguments.nts_server:
            start_nts_server()
        peers = NetworkPeers(serial) if arguments.network_peers else None
        if peers is not None:
            command_line = peers.words(command_line)
            # What's typed, and what's expected, name the peers' ports too
            for name in ("console_input", "expect_line", "expect_line_start", "expect_console_line", "expect_console_start",
                         "expect_console_contains", "console_input_after"):
                setattr(arguments, name, [peers.words(each) for each in getattr(arguments, name)])
        image = None
        if not arguments.boot_disk:
            image = make_image(kernel.resolve(), [program.resolve() for program in programs], bootloader, image_builder, xorriso, folder,
                               command_line, not arguments.no_kaslr, not arguments.release_generation)
        extra = (X86_IOMMU if not aarch64 and not arguments.no_iommu else []) + list(arguments.qemu_arguments)
        if peers is not None:
            extra += peers.qemu_arguments()
        console = None
        disk = folder / "disk.img"
        # How long each phase takes, said at the end, to see where a test's time goes
        phases = []
        phase_started = time.monotonic()
        if arguments.boot_disk:
            make_boot_disk(disk, kernel.resolve(), [program.resolve() for program in programs], bootloader, image_builder, folder,
                           command_line, not arguments.no_kaslr, arguments.disk or "", arguments.stage_generation,
                           (programs_folder / "hello_next.elf").resolve() if arguments.stage_next_hello else None,
                           development=not arguments.release_generation, debug_files=arguments.debug_files)
            extra += ["-drive", f"file={disk},if=none,id=disk,format=raw",
                      "-device", "virtio-blk-pci,drive=disk,disable-legacy=on,iommu_platform=on,bootindex=0"]
            phases.append(("making the disk", time.monotonic() - phase_started))
        elif arguments.disk is not None:
            make_disk(disk, arguments.disk)
            extra += ["-drive", f"file={disk},if=none,id=disk,format=raw", "-device", "virtio-blk-pci,drive=disk,disable-legacy=on,iommu_platform=on"]
        if arguments.power_button_after is not None:
            button = PowerButton(serial, arguments.power_button_after)
            extra += button.qemu_arguments()
            button.thread.start()
        keyboard = None
        if arguments.keyboard_input or arguments.screen_after:
            keyboard = Keyboard()
            extra += keyboard.qemu_arguments()
        screenshot = folder / "screen.ppm"
        if arguments.screen_after and aarch64:
            # virt has no display of its own; AAVMF gives a framebuffer on QEMU's ramfb
            extra += ["-device", "ramfb"]
        if arguments.console_input or arguments.expect_console_line or arguments.keyboard_input or arguments.refuse_console_line \
                or arguments.expect_console_start or arguments.expect_console_end or arguments.expect_console_contains \
                or arguments.screen_after:
            console = ConsoleLink(arguments.console_input, arguments.keyboard_input, keyboard, arguments.screen_after, screenshot,
                              arguments.console_input_after,
                              arguments.expect_console_line if arguments.shut_down_when_done or arguments.restart_when_done else None,
                              serial, [line for line in arguments.expect_line if not line.startswith(RUN_END_LINES)],
                              b"r" if arguments.restart_when_done else b"p")
            extra += console.qemu_arguments()
            console.thread.start()
        booting_started = time.monotonic()
        keys = SerialKeys(serial, "r") if arguments.recovery_key else None
        if arguments.bootloader_edit is not None:
            keys = SerialKeys(serial, "e", arguments.bootloader_edit + "\r")
        if aarch64:
            code = run_aarch64(image, qemu, serial, arguments.timeout, arguments.cpu, extra + boot_only(arguments, 1), not arguments.no_iommu, keys,
                               arguments.allow_reboot)
        else:
            code = run(image, qemu, serial, arguments.timeout, arguments.cpu, extra + boot_only(arguments, 1), keys,
                       arguments.allow_reboot)
        phases.append(("boot 1", time.monotonic() - booting_started))
        # Read while the folder it's in is still there
        screen_wrong = None
        if arguments.screen_after:
            screen_wrong = console_drawn(screenshot) if console is not None and console.screen_taken and screenshot.exists() \
                else "the screen wasn't taken"
        if console is not None:
            console.thread.join(timeout=5)
        output = serial.read_text(errors="replace") if serial.exists() else ""
        # The same disk booted again, as a reboot would, for what the boots before wrote onto it (decisions/0116)
        later = []
        for boot in range(2, arguments.boots + 1):
            serial.unlink(missing_ok=True)
            booting_started = time.monotonic()
            if aarch64:
                again = run_aarch64(image, qemu, serial, arguments.timeout, arguments.cpu, extra + boot_only(arguments, boot), not arguments.no_iommu)
            else:
                again = run(image, qemu, serial, arguments.timeout, arguments.cpu, extra + boot_only(arguments, boot))
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
    for states in CPU_STATES:
        print("boot.py: where each CPU was when it timed out:", file=sys.stderr)
        sys.stderr.write(states.replace("\r\n", "\n"))
    print("boot.py: took " + ", ".join(f"{seconds:.1f} s {phase}" for phase, seconds in phases), file=sys.stderr)
    if arguments.expect is not None:
        lines = output.splitlines()
        missing = [line for line in arguments.expect_line if line not in lines]
        for line in missing:
            print(f"boot.py: the serial output has no line {line!r}", file=sys.stderr)
        missing_starts = [start for start in arguments.expect_line_start if not any(line.startswith(start) for line in lines)]
        for start in missing_starts:
            print(f"boot.py: the serial output has no line starting {start!r}", file=sys.stderr)
        missing += missing_starts
        missing += failed_tests(output)
        shown = console.lines() if console is not None else []
        missing_shown = [line for line in arguments.expect_console_line if line not in shown]
        missing_shown += [line for line in arguments.refuse_console_line if line in shown]
        for line in missing_shown:
            seen = "showed the line" if line in shown else "showed no line"
            print(f"boot.py: the virtio console {seen} {line!r}", file=sys.stderr)
        for start in arguments.expect_console_start:
            if not any(line.startswith(start) for line in shown):
                print(f"boot.py: the virtio console showed no line starting {start!r}", file=sys.stderr)
                missing_shown.append(start)
        for end in arguments.expect_console_end:
            if not any(line.endswith(end) for line in shown):
                print(f"boot.py: the virtio console showed no line ending {end!r}", file=sys.stderr)
                missing_shown.append(end)
        for part in arguments.expect_console_contains:
            if not any(part in line for line in shown):
                print(f"boot.py: the virtio console showed no line with {part!r}", file=sys.stderr)
                missing_shown.append(part)
        if screen_wrong is not None:
            print(f"boot.py: the framebuffer: {screen_wrong}", file=sys.stderr)
            missing_shown.append(screen_wrong)
        if peers is not None and peers.problem is not None:
            print(f"boot.py: the network peers: {peers.problem}", file=sys.stderr)
            missing_shown.append(peers.problem)
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
            starts = [line.split(":", 1)[1] for line in arguments.expect_boot_line_start if line.split(":", 1)[0] == str(boot)]
            for start in starts:
                if not any(line.startswith(start) for line in text.splitlines()):
                    print(f"boot.py: boot {boot}'s serial output has no line starting {start!r}", file=sys.stderr)
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
    failed = failed_tests(output)
    return 0 if code == arguments.expect and not missing and not failed else 1


# A test that failed, as Hemera's testing reports it (docs/testing.md), after a program's name or the kernel's tag
FAILED_TEST = re.compile(r": test \S+ \.\.\. FAILED$")


def failed_tests(output: str) -> list:
    """The lines of output that report a failed test, each said on standard error with what follows it."""
    lines = output.splitlines()
    failed = []
    for i, line in enumerate(lines):
        if FAILED_TEST.search(line):
            failed.append(line)
            print(f"boot.py: {line}", file=sys.stderr)
            # Its failures, indented beneath it
            for following in lines[i + 1:]:
                if ":     " not in following:
                    break
                print(f"boot.py: {following}", file=sys.stderr)
    return failed


def description_of(code: int) -> str:
    """How a boot ended, as boot.py says it."""
    return {TIMED_OUT: "timed out", NO_EXIT_CODE: "ended without an exit code"}.get(code, f"exited with {code}")


if __name__ == "__main__":
    sys.exit(main())
