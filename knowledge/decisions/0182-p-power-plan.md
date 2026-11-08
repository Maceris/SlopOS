# 0182: P, Power, Planned

Status: accepted, chosen with the project's owner; not started
Date: 2026-11-07
Related: `0039` (the AML service), `0074` (x86-64's PCI windows guessed), `0101` (`_CRS` placed in P), `0134`
(the panic record, boot counting), `0139` (the lifecycle channel's `Stop`), `0160` (elevation), `0180` (shutting down
when asked), `0181` (Before P), `../design/lessons.md` §5 and §6.2, `../roadmap.md` P

## Context
SlopOS can't turn a machine off. `0180`'s shutdown commits the volumes and ends the root task. The kernel then halts
every CPU, and under `test_exit` it asks QEMU to exit; on real hardware the machine stays on, halted. Restarting
exists only as the kernel's own reset after a panic (`panic_reset`). Services end however they're running when the
root task does: none acts on its lifecycle channel's `Stop` (`0139`) but the powerbox and two test programs.

What the machine needs differs by architecture:
- **AArch64** boots from a devicetree (`acpi=off` on QEMU's virt). PSCI's `SYSTEM_OFF` and `SYSTEM_RESET` need only
  the conduit the kernel already finds. The power button is a `gpio-keys` key on a PL061 GPIO controller.
- **x86-64** needs ACPI:
  - Turning off writes `\_S5`'s sleep type to the PM1 control registers. `\_S5` is AML, an object in the DSDT.
  - Restarting uses the FADT's reset register, or `0xcf9`, which the kernel uses today.
  - The power button is a fixed event in PM1's status, or a control method's `Notify` on its device.
  - The PCI windows are in the host bridge's `_CRS`, which is AML too. Until there's an interpreter, they're guessed from
    the memory map's gaps (`0074`).

QEMU's tables keep `\_S5` and `_CRS` as plain data; real firmware computes them in methods that read chipset
registers.

## Decision
Chosen with the project's owner:
- **The AML interpreter runs methods**, not only data objects. It covers:
  - the namespace, with names, packages, buffers, fields, operation regions, mutexes, events and every control-flow
    opcode;
  - operation regions in `SystemMemory`, `SystemIO` and `PCI_Config`.

  It is bounded, since the bytecode isn't trusted: a step budget per evaluation, a call depth and a memory budget. A
  method that passes any of them fails, and nothing else does. The embedded controller's region, batteries and
  thermal zones wait for the hardware that needs them.
- **The power button shuts the system down cleanly**, at once, exactly as P on the secure attention key's screen
  does. Holding it in still cuts the power in hardware.
- **Who may shut down or restart**:
  - whoever is at the console: P (shut down) and the new R (restart) on the secure attention key's screen, and the
    power button;
  - an administrator: the shell's `shut-down` and `restart`. The shell asks the powerbox for the power capability,
    an administrator's capability, so the trusted path asks for an administrator's credentials, as for making an
    account (`0160`).

Five parts, each with an as-built record:
- **P1, the kernel's power capability.**
  - A new kernel object, `PowerControl`, holds how this machine turns off and restarts: PSCI's conduit on AArch64; on
    x86-64, the PM1a and PM1b control registers with `\_S5`'s sleep types and the FADT's reset register.
  - The root task holds it from boot. On x86-64 the sleep types are given to it later, by the ACPI service through
    the platform capability (P3). Until then it can restart but not turn off, and asking for that is refused, so a
    caller can fall back to halting.
  - Ending the root task with a power request (`power_off` or `restart`) does what the kernel's stop does now: it
    stops every other CPU and logs the objects left. Then, instead of halting, it turns the machine off or resets it.
    Under `test_exit` it still exits QEMU with its code, so boot tests keep their checks.
  - Tested with a boot test without `test_exit` that turns QEMU off, on both architectures, and one that restarts into
    the next boot.
- **P2, the AML interpreter** (`src/aml`): a library with no authority of its own.
  - It loads the DSDT and SSDTs into a namespace and evaluates objects and methods. Every access to an operation
    region goes through an interface its user supplies, so it runs hosted.
  - Tested hosted, on tables built by a small AML assembler in its tests, and on QEMU's own DSDT, saved once from the
    firmware tables as test data. The tests cover the opcodes and the bounds: a method that never ends, one that
    calls itself and one that allocates without end all fail with their reasons.
- **P3, the ACPI service** (x86-64; `services.md`'s ACPI service).
  - **What it holds**: the firmware tables, and the I/O ports and memory of its regions and the PM1 and GPE blocks.
    It's restartable and less trusted than the platform service, which it doesn't hold.
  - **At start**: it enters ACPI mode, runs `_INI` and `_STA`, and evaluates `\_S5`. It gives `\_S5`'s sleep types to
    the kernel's `PowerControl`, and the host bridge's `_CRS` windows to the platform service, which places BARs in
    them instead of the gaps (`0074`).
  - **Events**: it serves the SCI, which carries the fixed power button event and general-purpose events. A GPE runs
    its `_Lxx` or `_Exx` method, and a `Notify` of the power button's device, `0x80`, counts as the button. The button
    goes to the supervisor on the power protocol.
  - **On AArch64** the supervisor starts a small PL061 driver for the devicetree's `gpio-keys`, which reports the same
    event the same way. `_PRT` is evaluated and logged; nothing routes legacy interrupts by it until a device needs
    them.
- **P4, a graceful shutdown.** The supervisor stops services in reverse dependency order, then commits volumes, then
  kills what's left:
  - **Stopping:** each service is sent `Stop` on its lifecycle channel, with a 2 s deadline each and 20 s in all. The
    order is the reverse of the order they start in:
    1. sessions and their programs;
    2. the trusted path;
    3. the other services;
    4. the volumes are committed;
    5. the storage stack: the volume servers, the container services and the partition servers;
    6. the drivers.
  - **What services do:** `service_kit` gains a helper that stops a service taking new clients and finishes what it's
    doing, and the service then ends with 0. Every service uses it.
  - **Killing:** what's still running when its deadline passes is killed, and the log names it.
  - **The end:** the root task ends with the power request, and P1 does the rest.
  - **The power protocol** gains `Restart`, and the power button's event, which the ACPI service or the PL061 driver
    sends.
  - **Tests:** a boot test shuts down with nothing killed, and another with a test program that ignores `Stop`, which
    is killed and named.
- **P5, the hardware watchdog** (`../design/lessons.md` §6.2):
  - **The driver:** an `i6300esb` driver for QEMU's PCI watchdog, on both architectures. Its one client is the
    supervisor, which pets it only while the services it supervises answer `Ping`.
  - **Timeouts:** 30 s in a release generation, and 60 s in a development one, so a debugger's pause doesn't reset
    the machine.
  - **When it fires:** the machine resets, and boot counting (`0134`) does the rest.
  - **Tests:** a robustness test hangs the supervisor's pinging and sees the machine reset and the next boot report
    it. The watchdog is added to QEMU only for the tests that use it.

## Alternatives
- **Data objects only**: much smaller and enough for QEMU, but on real hardware `\_S5` and `_CRS` would come back as
  guesses or not at all.
- **`\_S5` read by scanning the DSDT's bytes** for its package, as small kernels do: no interpreter, but it breaks on
  firmware that computes `\_S5`, and `_CRS` would still be guessed.
- **The ACPI service powering off itself**, holding PM1's ports: no kernel object, but it would have to outlive every
  other service, and the kernel's stop, which already stops the CPUs, is the place that knows it's last.
- **The power button asking first on the console**: safer against a bumped button, but every other system turns
  off, and a person at the machine can cut its power anyway.
- **The console alone shutting down**: everything on the trusted path, but an administrator in their own session
  couldn't restart without the secure attention key, and elevation already asks for their credentials.
- **The SBSA generic watchdog on AArch64**: what real Arm servers have, but QEMU's virt machine has none; the
  `i6300esb` is a PCI device both machines take.

## Consequences
- `0074`'s guessed windows are kept only for when the ACPI service hasn't answered, or isn't there, as with AArch64's
  devicetree, which has its own `ranges`.
- The supervisor's start order becomes its stop order, so it says what it means: a service starts after what it uses.
- `../design/services.md`'s ACPI service row is built, and the power protocol is no longer the terminal service's
  alone.
- `0180`'s shutdown, which committed volumes and ended the root task, becomes P4's first step after stopping the
  sessions.
- Suspend stays after P (`../design/lessons.md` §5).

## As Built, P1 (2026-11-07)
- **The platform capability, not a new object**: `PowerControl` was planned as a kernel object of its own, but its
  holders are the platform capability's, the root task and the platform service, so the three new calls take that
  capability as their authority instead:
  - `power_set_off` keeps x86-64's PM1a and PM1b control ports and `\_S5`'s sleep types;
  - `power_set_reset` keeps the FADT's reset register, when it's an I/O port;
  - `power_end_with` keeps what the root task's end does, a `PowerAction`: `Halt`, `Off` or `Restart`. `Off` is
    refused with the new error `NoPowerOff` while the kernel can't turn the machine off.

  Each setting is one atomic word in the kernel (`src/kernel/power.hsc`), so no lock is taken. Calls 78 to 80, error
  47.
- **The kernel's stop**: for `RootTaskEnded`, after the other CPUs have stopped and the objects left are logged, it
  turns the machine off or resets it:
  - **Off:** by PSCI's `SYSTEM_OFF` on AArch64, or on x86-64 by PM1's control registers, each read, its SLP_TYP
    replaced and SLP_EN set, PM1b before PM1a.
  - **Restart:** the reset register first where it's known, then the architecture's own reset. A panic's reset
    (`panic_reset`) uses the same path.
  - **Under `test_exit`:** QEMU is still asked to exit with the reason's code, unless `test_power` is on the command
    line too.
  - **Arch interface:** `reset_method` and `reset` were declared in it at last, beside the new `can_power_off` and
    `power_off`.
- **Restart, from P4, early, so P1 could be tested**:
  - The power protocol's `Restart` and the supervision report's `Restart`; the supervisor commits the volumes for
    either.
  - R on the secure attention key's screen, which now says "P shuts the system down, R restarts it."
  - On `ShutDown` the root task asks for `Off`; refused, it logs that the machine can't be turned off yet, and halts
    as before. On `Restart` it asks for `Restart`.
- **The platform service** gives the kernel the FADT's reset register when RESET_REG_SUP says it's there (QEMU's q35:
  `0xcf9`, written with `0x0f`). `\_S5` waits for P3, so x86-64 can't turn off yet.
- **Tests**: `boot.py --restart-when-done` types the secure attention key and R, as `--shut-down-when-done` types P.
  - Restart, on both architectures: QEMU, without `--allow-reboot`, ends at the reset without an exit code (125).
  - Turning off, on AArch64 alone until P3: PSCI's `SYSTEM_OFF` ends QEMU the same way.
  - The other shutdown tests, under `test_exit` alone, still end with 7.
