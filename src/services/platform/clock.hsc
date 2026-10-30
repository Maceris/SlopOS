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

RTC_PORTS : u32 : 0x70
RTC_PORT_COUNT : u32 : 2
FADT_IAPC_BOOT_ARCH : u64 : 109
IAPC_NO_CMOS_RTC : u16 : 1 << 5
PL031_SIZE : u64 : 4096

// Where the real-time clock is.
Clock :: struct {
    kind : protocol.ClockKind,
    // A PL031's registers
    registers : u64,
}

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

/*
 * The real-time clock for client, made anew each time it's asked, since what it held may have died with its driver;
 * NoDevice if there's none, or another client claimed it.
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
