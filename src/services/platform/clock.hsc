package platform

import slop_os from "std/os"
import devicetree from "../../devicetree"
import log_line from "../../log_line"
import pci from "../../pci"
import platform as protocol from "../../protocols/platform"

/*
 * The real-time clock (roadmap 9a, decisions/0093), for the clock service, its driver. On x86-64 it's the MC146818 at
 * I/O ports 0x70 and 0x71, unless ACPI's FADT says there's no CMOS RTC. On AArch64 it's the device tree's PL031,
 * disabled or not: UEFI's runtime services keep it for themselves, but SlopOS doesn't call them.
 */
//SPEC: ACPI 6.5, §5.2.9 (FADT: IAPC_BOOT_ARCH's CMOS RTC Not Present)
//SPEC: Linux's arm,pl031 binding

/** The MC146818's first I/O port, its index register; its data register is the next. */
RTC_PORTS : u32 : 0x70
/** How many I/O ports the MC146818 has from RTC_PORTS: its index register and its data register. */
RTC_PORT_COUNT : u32 : 2
/** The byte offset of IAPC_BOOT_ARCH, a u16, in ACPI's FADT. */
FADT_IAPC_BOOT_ARCH : u64 : 109
/** IAPC_BOOT_ARCH's CMOS RTC Not Present flag: set, there's no MC146818 to drive. */
IAPC_NO_CMOS_RTC : u16 : 1 << 5
/** The bytes of a PL031's registers, one page, given to its driver as device memory. */
PL031_SIZE : u64 : 4096

/** Where the real-time clock is, as the firmware tables say, found once at the platform service's start. */
Clock :: struct {
    /** Which clock it is, and so which of its ports or its registers its driver is given. */
    kind : protocol.ClockKind,
    /** A PL031's registers' physical address, PL031_SIZE bytes from it; unused, 0, for an MC146818. */
    registers : u64,
}

/**
 * Find the real-time clock the firmware tables describe.
 *
 * On x86-64 it's the MC146818 unless the FADT says there's no CMOS RTC; without a FADT, one is taken to be there. On
 * AArch64 it's the device tree's first arm,pl031, even one marked disabled, since UEFI marks the one its runtime
 * services use so.
 *
 * @param tables Where the firmware tables' copy is mapped, readable, in the platform service's address space.
 * @param size The firmware tables' copy's size in bytes; nothing past it is read.
 * @return The clock, or null if there's none: the FADT says so, or on AArch64 there's no device tree, no PL031 in it,
 *     or no registers for it.
 */
find_clock :: fn(tables: u64, size: u64) -> Clock? {
    #if TARGET_ARCH == .x86_64 {
        match pci.firmware_table(tables, size, "FACP") {
            case Some(fadt) => {
                if fadt.size >= FADT_IAPC_BOOT_ARCH + 2 && (pci.read_u16(fadt.address, FADT_IAPC_BOOT_ARCH) & IAPC_NO_CMOS_RTC) != 0 {
                    return null
                }
            }
            case None => {}
        }
        return Clock.{kind = .Mc146818}
    }
    #else {
        blob :: pci.firmware_table(tables, size, "DTB ") or_return null
        tree := devicetree.open(blob.address) or_return null
        // UEFI marks it disabled, as its runtime services use it
        rtc := devicetree.find_compatible_even_disabled(&tree, "arm,pl031") or_return null
        region :: devicetree.reg(&tree, &rtc, 0) or_return null
        return Clock.{kind = .Pl031, registers = region.address}
    }
}

/**
 * Give a client the real-time clock: its I/O ports, or its registers, made anew each time it's asked, since what it
 * held may have died with its driver.
 *
 * The first client to claim it keeps it: only that client is given it again. Its claim is noted only when it's given.
 *
 * @param to The debug log the platform service writes to, NO_HANDLE for none; a failure to make the ports or the
 *     registers is logged there, and so is the first claim.
 * @param platform The platform capability, which the ports or the registers are made with.
 * @param state The platform service's state: its clock is read, and its clock_claimed and clock_claimer set.
 * @param client The asking client, by its index in the platform service's clients.
 * @return ClaimedClock with the clock's kind and the new ports or registers (NO_HANDLE for the other), which move to
 *     the client with the response; or NoDevice if there's no clock, another client claimed it, or its ports or
 *     registers couldn't be made.
 */
claim_clock :: fn(to: slop_os.DebugLog, platform: slop_os.Platform, state: ptr[mut Platform], client: usize) -> protocol.Response {
    clock :: state.clock or_return .NoDevice
    if state.clock_claimed && state.clock_claimer != client {
        return .NoDevice
    }
    block :: slop_os.startup_block()
    result := protocol.RealTimeClock.{kind = clock.kind, ports = cast[slop_os.IoPortRange](slop_os.NO_HANDLE),
        registers = cast[slop_os.Memory](slop_os.NO_HANDLE)}
    match clock.kind {
        case .Mc146818 => {
            match slop_os.io_ports_create(platform, block.budget, RTC_PORTS, RTC_PORT_COUNT) {
                case Ok(ports) => result.ports = ports
                case Error(error) => {
                    log_line.write(to, "platform: the real-time clock's ports can't be given out: %", error)
                    return .NoDevice
                }
            }
        }
        case .Pl031 => {
            match slop_os.memory_create_physical(platform, block.budget, clock.registers, PL031_SIZE, .Device) {
                case Ok(registers) => result.registers = registers
                case Error(error) => {
                    log_line.write(to, "platform: the real-time clock's registers at %{#018x} can't be given out: %", clock.registers, error)
                    return .NoDevice
                }
            }
        }
    }
    if !state.clock_claimed {
        log_line.write(to, "platform: the real-time clock (%) claimed", clock.kind)
    }
    state.clock_claimed = true
    state.clock_claimer = client
    return .ClaimedClock(result)
}
