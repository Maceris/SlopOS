/**
 * The driver of Intel's 6300ESB watchdog timer, which QEMU has as i6300esb (decisions/0182, P5): armed by the
 * supervisor, its one client, with a timeout, and reset while the supervisor keeps sending Pets; let run out, it resets
 * the machine. Its two stages, the first set to raise no interrupt, each count half the timeout at about 1 kHz.
 *
 * At its start it says whether the watchdog reset the machine the boot before, which its reload register keeps.
 */
//SPEC: Intel 6300ESB I/O Controller Hub datasheet, §15 (the watchdog timer); Linux's i6300esb.c
package i6300esb

import intrinsics from "base"
import runtime from "base"
import os from "std"
import slop_os from "std/os"
import driver_kit from "../../driver_kit"
import service_kit from "../../libraries/service_kit"
import watchdog from "../../protocols/watchdog"

/** The configuration register, in PCI configuration space: its interrupt type and clock. */
CONFIG : u64 : 0x60
/** The lock register, in PCI configuration space: enabling, and locking it on for good. */
LOCK : u64 : 0x68
/** The configuration: no interrupt on the first stage's end (bits 0 and 1), the clock at about 1 kHz (bit 2 clear). */
CONFIG_NO_INTERRUPT : u16 : 0x0003
/** The lock register's enable bit. */
ENABLE : u8 : 1 << 1
/** The first stage's preload, in the memory BAR. */
TIMER1 : u64 : 0x00
/** The second stage's preload. */
TIMER2 : u64 : 0x04
/** The reload register: unlocked by UNLOCK1 then UNLOCK2 before each write to it or the preloads. */
RELOAD : u64 : 0x0c
/** The reload register's bit that starts the stages again. */
RELOAD_NOW : u16 : 1 << 8
/** The reload register's bit that says the watchdog timed out, kept across the reset it brought. */
TIMED_OUT : u16 : 1 << 9
/** The first write that unlocks the registers. */
UNLOCK1 : u16 : 0x80
/** The second. */
UNLOCK2 : u16 : 0x86
/** The fewest seconds it's armed for. */
LEAST_SECONDS : u32 : 2
/** The most: each stage's preload has 20 bits, counted from the seconds shifted by 9. */
MOST_SECONDS : u32 : 2046

/** The driver's state. */
Driver :: struct {
    /** Where the device's configuration space is mapped. */
    config : u64,
    /** Where its memory BAR is mapped. */
    registers : u64,
    /** Whether it's armed. */
    armed : bool,
    /** The clients served, the supervisor's connection among them. */
    clients : service_kit.Clients,
    /** The port every client's end and the listener are bound to. */
    port : slop_os.Port,
}

/**
 * Serve the watchdog.
 *
 * @param log Unused: what it says goes to its log ring.
 * @param device The device.
 * @param config Its PCI configuration space.
 * @param bar0 Its memory BAR, the registers.
 * @param bar1 Unused.
 * @param bar2 Unused.
 * @param bar3 Unused.
 * @param bar4 Unused.
 * @param bar5 Unused.
 * @param domain Unused: it does no DMA.
 * @param clients The listener its client, the supervisor, connects on.
 * @return 0 once asked to stop, having disarmed it; on failing to start, 2 if its registers can't be mapped, 4
 *     without a port, 5 if the listener can't be served.
 */
main :: fn(log: slop_os.DebugLog?, device: slop_os.Device, config: slop_os.Memory, bar0: slop_os.Memory?, bar1: slop_os.Memory?,
    bar2: slop_os.Memory?, bar3: slop_os.Memory?, bar4: slop_os.Memory?, bar5: slop_os.Memory?, domain: slop_os.DmaDomain,
    clients: os.Listener[watchdog.Watchdog]) -> int {
    block :: slop_os.startup_block()
    driver := Driver.{}
    driver.config = driver_kit.map_device(config) or_return 2
    bars :: driver_kit.map_bars(bar0, bar1, bar2, bar3, bar4, bar5)
    driver.registers = bars[0]
    if driver.registers == 0 {
        return 2
    }
    // Disabled, no interrupt, the slow clock; and whether it reset the machine the boot before
    write_config_u16(driver.config, CONFIG, CONFIG_NO_INTERRUPT)
    write_config_u8(driver.config, LOCK, 0)
    unlock(driver.registers)
    fired :: read_u16(driver.registers, RELOAD) & TIMED_OUT != 0
    unlock(driver.registers)
    write_u16(driver.registers, RELOAD, TIMED_OUT | RELOAD_NOW)
    if fired {
        runtime.log_info("the watchdog reset the machine the boot before")
    }
    driver.port = slop_os.port_create(block.budget) or_return 4
    if !service_kit.add_client(&driver.clients, driver.port, clients.end) {
        return 5
    }
    _ = service_kit.watch_stop(driver.port)
    runtime.log_info("serving")
    into := os.Incoming.{}
    loop {
        with {
            i : usize = 0
        }
        loop {
            serve(&driver, i, &into)
            i += 1
        }
        while i < driver.clients.count
        // Asked to stop, as the system shuts down: disarmed, so the shutdown isn't cut short
        if service_kit.stopping() {
            disarm(&driver)
            return 0
        }
        packets : slop_os.Packet[8]
        _ = slop_os.port_wait(driver.port, packets, slop_os.NO_DEADLINE)
    }
}

/**
 * Answer every request a client has waiting, until it has none.
 *
 * @param driver The driver.
 * @param index The client, by its index; a dropped one does nothing.
 * @param into Where each request is received.
 */
serve :: fn(driver: ptr[mut Driver], index: usize, into: ptr[mut os.Incoming]) {
    if index >= driver.clients.ends.count {
        return void
    }
    end :: driver.clients.ends[index]
    if cast[slop_os.Handle](end) == slop_os.NO_HANDLE {
        return void
    }
    loop {
        match watchdog.receive_request(end, driver.port, into, false) {
            case Received => {}
            case Empty => return void
            case Unsupported => {
                _ = watchdog.answer_unsupported(end, driver.port)
                continue
            }
            case _ => {
                service_kit.drop_client(&driver.clients, index)
                return void
            }
        }
        out := os.Outgoing.{}
        response :: os.begin[watchdog.Response](&out)
        match os.message_of[watchdog.Request](into)^ {
            case Arm(seconds) => response^ = .Armed(arm(driver, seconds))
            case Pet => {
                if driver.armed {
                    unlock(driver.registers)
                    write_u16(driver.registers, RELOAD, RELOAD_NOW)
                    response^ = .Done
                }
                else {
                    response^ = .Refused
                }
            }
            case Disarm => {
                disarm(driver)
                response^ = .Done
            }
            case Connect(connection) => {
                if !service_kit.add_client(&driver.clients, driver.port, connection.end) {
                    _ = slop_os.handle_close(cast[slop_os.Handle](connection.end))
                }
                continue
            }
        }
        _ = watchdog.send_response(end, driver.port, &out)
    }
}

/**
 * Arm the watchdog: each stage set to half the timeout, its time started, and it enabled.
 *
 * @param driver The driver.
 * @param seconds The timeout asked for.
 * @return The timeout taken: seconds, between LEAST_SECONDS and MOST_SECONDS.
 */
arm :: fn(driver: ptr[mut Driver], seconds: u32) -> u32 {
    taken :: if seconds < LEAST_SECONDS { LEAST_SECONDS } else if seconds > MOST_SECONDS { MOST_SECONDS } else { seconds }
    // Each stage counts seconds << 9 ticks at about 1 kHz, half the timeout, as Linux's i6300esb.c sets them
    preload :: taken << 9
    unlock(driver.registers)
    write_u32(driver.registers, TIMER1, preload)
    unlock(driver.registers)
    write_u32(driver.registers, TIMER2, preload)
    unlock(driver.registers)
    write_u16(driver.registers, RELOAD, RELOAD_NOW)
    write_config_u8(driver.config, LOCK, ENABLE)
    driver.armed = true
    runtime.log_info("armed, % seconds", taken)
    return taken
}

/**
 * Disarm the watchdog, so it resets nothing.
 *
 * @param driver The driver.
 */
disarm :: fn(driver: ptr[mut Driver]) {
    write_config_u8(driver.config, LOCK, 0)
    if driver.armed {
        runtime.log_info("disarmed")
    }
    driver.armed = false
}

/**
 * Unlock the registers for one write, as each write to the reload register or a preload needs.
 *
 * @param registers Where the memory BAR is mapped.
 */
unlock :: fn(registers: u64) {
    write_u16(registers, RELOAD, UNLOCK1)
    write_u16(registers, RELOAD, UNLOCK2)
}

/** Read a 16-bit register of the memory BAR. */
read_u16 :: fn(registers: u64, offset: u64) -> u16 {
    return intrinsics.volatile_load_u16(cast[ptr[u16]](registers + offset))
}

/** Write a 16-bit register of the memory BAR. */
write_u16 :: fn(registers: u64, offset: u64, value: u16) {
    intrinsics.volatile_store_u16(cast[ptr[mut u16]](registers + offset), value)
}

/** Write a 32-bit register of the memory BAR. */
write_u32 :: fn(registers: u64, offset: u64, value: u32) {
    intrinsics.volatile_store_u32(cast[ptr[mut u32]](registers + offset), value)
}

/** Write a 16-bit register of the configuration space. */
write_config_u16 :: fn(config: u64, offset: u64, value: u16) {
    intrinsics.volatile_store_u16(cast[ptr[mut u16]](config + offset), value)
}

/** Write an 8-bit register of the configuration space. */
write_config_u8 :: fn(config: u64, offset: u64, value: u8) {
    intrinsics.volatile_store_u8(cast[ptr[mut u8]](config + offset), value)
}
