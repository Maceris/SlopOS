/**
 * The power button's driver where a GPIO controller's pin is wired to it (decisions/0182, P3): on AArch64's virt,
 * gpio-keys' KEY_POWER on a PL061. Started by the supervisor with a platform connection of its own, it claims the
 * button, which gives the PL061's registers, its IRQ and the pin; it takes the pin's rising edge as a press, and tells
 * the supervisor on its power connection, which shuts the system down. Where there's no such button, as where ACPI's
 * SCI brings it instead, it ends with 0, and isn't started again.
 */
//SPEC: Arm PrimeCell GPIO (PL061) Technical Reference Manual, §3.3 (GPIODIR, GPIOIS, GPIOIBE, GPIOIEV, GPIOIE, GPIOMIS, GPIOIC)
package power_button

import intrinsics from "base"
import runtime from "base"
import os from "std"
import slop_os from "std/os"
import service_kit from "../../libraries/service_kit"
import platform from "../../protocols/platform"
import power_protocol from "../../protocols/power"

/** The registers' bytes. */
REGISTERS : u64 : 4096
/** GPIODIR: a pin's bit set is an output; clear, an input. */
DIRECTION : u64 : 0x400
/** GPIOIS: a pin's bit set senses levels; clear, edges. */
SENSE : u64 : 0x404
/** GPIOIBE: a pin's bit set takes both edges; clear, GPIOIEV says which. */
BOTH_EDGES : u64 : 0x408
/** GPIOIEV: a pin's bit set takes a rising edge, or a high level. */
EVENT : u64 : 0x40c
/** GPIOIE: a pin's bit set lets its interrupt through. */
ENABLE : u64 : 0x410
/** GPIOMIS: the pins whose interrupts are pending and let through. */
MASKED_STATUS : u64 : 0x418
/** GPIOIC: writing a pin's bit clears its interrupt. */
CLEAR : u64 : 0x41c
/** The port key the PL061's interrupts come under. */
IRQ_KEY : u64 : 1

/**
 * Claim the power button, and tell the supervisor each time it's pressed, the first time only.
 *
 * @param platform_service A connection to the platform service of its own, on which the button is claimed.
 * @param power The power connection the pressing is told on; without one, it's only logged.
 * @return 0 where there's no such power button, so it isn't started again; on failing to start, 1 without a port, 2
 *     if the registers can't be mapped, 3 if the IRQ can't be waited for.
 */
main :: fn(platform_service: os.Channel[platform.Platform], power: os.Channel[power_protocol.Power]?) -> int {
    block :: slop_os.startup_block()
    port :: os.port_for(block.budget, platform_service.end) or_return 1
    out := os.Outgoing.{}
    request :: os.begin[platform.Request](&out)
    request^ = .ClaimPowerButton
    if platform.send_request(platform_service.end, port, &out) != null {
        return 1
    }
    into := os.Incoming.{}
    loop {
        match platform.receive_response(platform_service.end, port, &into, true) {
            case Received => break
            case _ => return 1
        }
    }
    button := platform.PowerButton.{}
    match os.message_of[platform.Response](&into)^ {
        case ClaimedPowerButton(claimed) => button = claimed
        case _ => {
            runtime.log_info("there's no power button on a GPIO pin here")
            return 0
        }
    }
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    registers :: runtime.reserve_addresses(cast[usize](REGISTERS)) or_return 2
    slop_os.memory_map(button.registers, block.space, registers, 0, REGISTERS, read_write) or_return 2
    // The pin an input, interrupting on its rising edge, anything pending cleared first
    bit :: cast[u32](1) << (button.pin & 7)
    write(registers, DIRECTION, read(registers, DIRECTION) & ~bit)
    write(registers, SENSE, read(registers, SENSE) & ~bit)
    write(registers, BOTH_EDGES, read(registers, BOTH_EDGES) & ~bit)
    write(registers, EVENT, read(registers, EVENT) | bit)
    write(registers, CLEAR, bit)
    write(registers, ENABLE, read(registers, ENABLE) | bit)
    events :: slop_os.port_create(block.budget) or_return 1
    _ = service_kit.watch_stop(events)
    if slop_os.port_bind(events, cast[slop_os.Handle](button.irq), cast[slop_os.Signals](0), IRQ_KEY, .Persistent) is_error {
        return 3
    }
    runtime.log_info("serving, the power button on pin %", button.pin)
    told := false
    loop {
        // Asked to stop, as the system shuts down (decisions/0182): what it was doing is done
        if service_kit.stopping() {
            return 0
        }
        packets : slop_os.Packet[4]
        taken :: slop_os.port_wait(events, packets, slop_os.NO_DEADLINE) or_else 0
        for packet, i in packets {
            if i >= cast[usize](taken) || packet.kind != .Irq {
                continue
            }
            if read(registers, MASKED_STATUS) & bit != 0 {
                write(registers, CLEAR, bit)
                runtime.log_info("the power button was pressed")
                if !told {
                    told = tell(power)
                }
            }
            _ = slop_os.irq_ack(button.irq)
        }
    }
}

/**
 * Tell the supervisor the power button was pressed.
 *
 * @param power The power connection; null for none.
 * @return True if it was told.
 */
tell :: fn(power: os.Channel[power_protocol.Power]?) -> bool {
    connection :: power or_return false
    port :: os.port_for(slop_os.startup_block().budget, connection.end) or_return false
    out := os.Outgoing.{}
    request :: os.begin[power_protocol.Request](&out)
    request^ = .PowerButton
    return power_protocol.send_request(connection.end, port, &out) == null
}

/**
 * Read a PL061 register.
 *
 * @param registers Where the registers are mapped.
 * @param offset The register's offset.
 * @return Its value; the PL061's are 8 bits, read as 32.
 */
read :: fn(registers: u64, offset: u64) -> u32 {
    return intrinsics.volatile_load_u32(cast[ptr[u32]](registers + offset))
}

/**
 * Write a PL061 register.
 *
 * @param registers Where the registers are mapped.
 * @param offset The register's offset.
 * @param value What's written; its low 8 bits are the PL061's.
 */
write :: fn(registers: u64, offset: u64, value: u32) {
    intrinsics.volatile_store_u32(cast[ptr[mut u32]](registers + offset), value)
}
