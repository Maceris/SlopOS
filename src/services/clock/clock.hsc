/**
 * The clock service (roadmap 9a, decisions/0093): the real-time clock's driver, which keeps the clock page every
 * program reads the time from (base's runtime.SlopOsClockPage, given to each as its grant "clock").
 *
 * It reads the clock when it starts, and puts that time on the page at the monotonic reading it was read at; from
 * there base's runtime counts on with the monotonic clock. Who holds a connection to its listener (the clock_setting
 * protocol) can set the time, which it writes to the real-time clock and the page together. It logs through base's
 * logger, to the events service.
 *
 * The clock is x86's MC146818, through its two I/O ports, or Arm's PL031, through its registers (the platform
 * protocol's RealTimeClock), each to the second. An MC146818 counts years to 99: its century is read from register
 * 0x32, where PCs keep it, if what's there is a century from 19 to 21, or taken as 20.
 */
//SPEC: Motorola MC146818A data sheet (registers 0x00 to 0x0b, update-in-progress, SET, DM and 24/12)
//SPEC: Arm PrimeCell Real Time Clock (PL031) Technical Reference Manual, §3 (RTCDR, RTCLR, RTCCR)
package clock

import intrinsics from "base"
import runtime from "base"
import os from "std"
import time from "std"
import slop_os from "std/os"
import text_buffer from "std"
import service_kit from "../../libraries/service_kit"
import clock_setting from "../../protocols/clock_setting"

/** Nanoseconds in a second, what the clock page's time is counted in. */
NANOSECONDS : i64 : 1_000_000_000
/** A page's size in bytes: the clock page's, and a PL031's registers' mapping. */
PAGE : u64 : 4096

// The MC146818's registers, through its index port (offset 0) and its data port (offset 1)
/** The MC146818's seconds register, 0 to 59. */
CMOS_SECONDS : u32 : 0x00
/** The MC146818's minutes register, 0 to 59. */
CMOS_MINUTES : u32 : 0x02
/** The MC146818's hours register, 0 to 23, or 1 to 12 with HOURS_PM in 12-hour mode. */
CMOS_HOURS : u32 : 0x04
/** The MC146818's day of the month register, 1 to 31. */
CMOS_DAY : u32 : 0x07
/** The MC146818's month register, 1 to 12. */
CMOS_MONTH : u32 : 0x08
/** The MC146818's year register, the year of the century, 0 to 99. */
CMOS_YEAR : u32 : 0x09
/** The MC146818's status register A, which says whether it's updating. */
CMOS_STATUS_A : u32 : 0x0a
/** The MC146818's status register B, which says how its fields are stored, and holds SET. */
CMOS_STATUS_B : u32 : 0x0b
/** Where PCs keep the century, beside the MC146818's own registers; not every PC does. */
CMOS_CENTURY : u32 : 0x32
/** Status register A's update-in-progress bit: set, the fields are passing from one second to the next. */
STATUS_A_UPDATING : u32 : 0x80
/** Status register B's SET bit: set, the clock doesn't update, so its fields can be written. */
STATUS_B_SET : u32 : 0x80
/** Status register B's DM bit: set, the fields are binary, and clear, BCD. */
STATUS_B_BINARY : u32 : 0x04
/** Status register B's 24/12 bit: set, hours are 0 to 23, and clear, 1 to 12 with HOURS_PM. */
STATUS_B_24_HOUR : u32 : 0x02
/** The hours register's PM bit, in 12-hour mode. */
HOURS_PM : u32 : 0x80

// The PL031's registers
/** The PL031's data register, RTCDR: its count of seconds, read only. */
PL031_DATA : u64 : 0x000
/** The PL031's load register, RTCLR: written, the count starts again from it. */
PL031_LOAD : u64 : 0x008
/** The PL031's control register, RTCCR. */
PL031_CONTROL : u64 : 0x00c
/** RTCCR's start bit: set, the PL031 counts; it can't be stopped once started. */
PL031_START : u32 : 1

// The years an MC146818 holds without a century register, and the most a PL031's 32 bits of seconds reach
/** The first year the time can be set to: an MC146818 without a century register holds 2000 to 2099. */
FIRST_YEAR : i64 : 2000
/** The last year the time can be set to, for either clock. */
LAST_YEAR : i64 : 2099

/** The real-time clock: its ports, or its registers. */
Rtc :: struct {
    /** An MC146818's I/O ports, its index port then its data port; None for a PL031. */
    ports : slop_os.IoPortRange?,
    /** Where a PL031's registers are mapped, readable and writable; 0 for an MC146818. */
    registers : u64,
}

/** The clock service's state. */
Clock :: struct {
    /** The real-time clock it drives. */
    rtc : Rtc,
    /** The clock page, mapped readable and writable; it's the only writer, every program a reader. */
    page : ptr[mut runtime.SlopOsClockPage],
}

/**
 * Drive the real-time clock: put the time it reads on the clock page every program reads the time from, and set it
 * for those allowed to.
 *
 * It needs one of rtc_ports and rtc_registers; given both, it uses the ports. If the clock holds no time it can read,
 * the page is left as it was, and the service serves still, so the time can be set.
 *
 * @param rtc_ports An MC146818's two I/O ports, its index port then its data port, for x86's real-time clock.
 * @param rtc_registers A PL031's registers, one page of device memory, for Arm's; it's started counting if it wasn't.
 * @param clock_page The clock page, mapped readable and writable for the service's life; every program is given it
 *     read-only, as its grant "clock".
 * @param clients The listener of the clock_setting protocol its first client connects on; who holds a connection can
 *     set the time, and further clients come as Connect requests.
 * @return Only on failing to start: 1 if the clock page can't be mapped, 2 if the PL031's registers can't be, 3 without
 *     a real-time clock, 4 without a port, and 5 if its first client can't be added. Serving, it doesn't return.
 */
main :: fn(rtc_ports: slop_os.IoPortRange?, rtc_registers: slop_os.Memory?, clock_page: slop_os.Memory,
    clients: os.Listener[clock_setting.ClockSetting]) -> int {
    block :: slop_os.startup_block()
    service := Clock.{}
    service.rtc.ports = rtc_ports
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    page_address :: runtime.reserve_addresses(cast[usize](PAGE)) or_return 1
    slop_os.memory_map(clock_page, block.space, page_address, 0, PAGE, read_write) or_return 1
    service.page = cast[ptr[mut runtime.SlopOsClockPage]](page_address)
    match rtc_registers {
        case Some(registers) => {
            address :: runtime.reserve_addresses(cast[usize](PAGE)) or_return 2
            slop_os.memory_map(registers, block.space, address, 0, PAGE, read_write) or_return 2
            service.rtc.registers = address
            // Counting, if it wasn't
            write_register(address, PL031_CONTROL, PL031_START)
        }
        case None => {}
    }
    if (service.rtc.ports is_none) && service.rtc.registers == 0 {
        runtime.log_error("no real-time clock")
        return 3
    }
    match read_rtc(&service.rtc) {
        case Some(seconds) => {
            publish(service.page, seconds * NANOSECONDS, slop_os.clock_monotonic() or_else 0)
            storage : u8[32]
            shown := text_buffer.make(storage)
            append_time(&shown, seconds)
            runtime.log_info("the real-time clock reads %", text_buffer.as_string(&shown))
        }
        case None => runtime.log_warn("the real-time clock holds no time it can read")
    }

    port :: slop_os.port_create(block.budget) or_return 4
    connected := service_kit.Clients.{}
    if !service_kit.add_client(&connected, port, clients.end) {
        return 5
    }
    runtime.log_info("serving")
    into := os.Incoming.{}
    loop {
        with {
            i : usize = 0
        }
        loop {
            serve(&service, &connected, i, port, &into)
            i += 1
        }
        while i < connected.count
        packets : slop_os.Packet[8]
        _ = slop_os.port_wait(port, packets, slop_os.NO_DEADLINE)
    }
}

/**
 * Answer every request a client has sent, until there are none left, or it's gone.
 *
 * Set is answered Done or Refused; Connect adds the client whose end it brings, closing that end if there's no room for
 * it; an unknown request is answered Unsupported, and one that's invalid or of another protocol is skipped. A client
 * whose channel fails is dropped.
 *
 * @param service The clock service's state, its clock and page changed by Set.
 * @param connected The clients; a new one is added, a failed one dropped.
 * @param index The client to serve, by its index in connected; one past them, or a dropped one, does nothing.
 * @param port The port every client's end is bound to.
 * @param into Where each request is received; overwritten by each.
 */
serve :: fn(service: ptr[mut Clock], connected: ptr[mut service_kit.Clients], index: usize, port: slop_os.Port, into: ptr[mut os.Incoming]) {
    if index >= connected.ends.count {
        return void
    }
    end :: connected.ends[index]
    if cast[slop_os.Handle](end) == slop_os.NO_HANDLE {
        return void
    }
    loop {
        match clock_setting.receive_request(end, port, into, false) {
            case Received => {}
            case Empty => return void
            case Unsupported => {
                _ = clock_setting.answer_unsupported(end, port)
                continue
            }
            case _ => {
                service_kit.drop_client(connected, index)
                return void
            }
        }
        match os.message_of[clock_setting.Request](into)^ {
            case Set(utc) => {
                out := os.Outgoing.{}
                response :: os.begin[clock_setting.Response](&out)
                response^ = if set(service, utc) { .Done } else { .Refused }
                _ = clock_setting.send_response(end, port, &out)
            }
            case Connect(connection) => {
                if !service_kit.add_client(connected, port, connection.end) {
                    _ = slop_os.handle_close(cast[slop_os.Handle](connection.end))
                }
            }
        }
    }
}

/**
 * Set the time: the real-time clock to its second, then the page, to the nanosecond, at the monotonic reading it was
 * written at.
 *
 * The clock is read back after, and a warning logged if it doesn't read what was set, or the second after; the time
 * is set all the same.
 *
 * @param service The clock service's state.
 * @param utc The time, in nanoseconds since 1970 UTC; its year has to be from FIRST_YEAR to LAST_YEAR.
 * @return True if it's set; false, logged, with nothing changed, if the year is out of range or the clock wouldn't take
 *     it.
 */
set :: fn(service: ptr[mut Clock], utc: i64) -> bool {
    seconds :: time.floor_divide(utc, NANOSECONDS)
    year :: time.utc(time.Instant.{seconds = seconds}).year
    if year < FIRST_YEAR || year > LAST_YEAR || !write_rtc(&service.rtc, seconds) {
        storage : u8[32]
        shown := text_buffer.make(storage)
        append_time(&shown, seconds)
        runtime.log_warn("can't set the real-time clock to %", text_buffer.as_string(&shown))
        return false
    }
    publish(service.page, utc, slop_os.clock_monotonic() or_else 0)
    // Read back: the second it's on may have passed since
    back :: read_rtc(&service.rtc) or_else 0
    storage : u8[32]
    shown := text_buffer.make(storage)
    append_time(&shown, seconds)
    if back >= seconds && back - seconds <= 1 {
        runtime.log_info("set to %, and the real-time clock reads it back", text_buffer.as_string(&shown))
    }
    else {
        other : u8[32]
        read := text_buffer.make(other)
        append_time(&read, back)
        runtime.log_warn("set to %, but the real-time clock reads %", text_buffer.as_string(&shown), text_buffer.as_string(&read))
    }
    return true
}

/**
 * Put a time on the clock page, under its sequence (runtime.SlopOsClockPage): odd while it's written, so a reader that
 * sees it change, or odd, reads again.
 *
 * @param page The clock page, written only by this service.
 * @param utc The time, in nanoseconds since 1970 UTC.
 * @param at The monotonic clock's reading, in nanoseconds, that utc was the time at; readers count on from it.
 */
publish :: fn(page: ptr[mut runtime.SlopOsClockPage], utc: i64, at: u64) {
    sequence :: intrinsics.atomic_load_u64_no_fence(&page.sequence)
    // Odd while it's written; from 0 to 1 the first time
    writing :: if (sequence & 1) == 0 { sequence + 1 } else { sequence + 2 }
    intrinsics.atomic_store_u64_no_fence(&page.sequence, writing)
    intrinsics.fence_release()
    intrinsics.atomic_store_i64_no_fence(&page.utc, utc)
    intrinsics.atomic_store_u64_no_fence(&page.at, at)
    intrinsics.atomic_store_u64_release(&page.sequence, writing + 1)
}

// ---- The real-time clock

/**
 * Read the real-time clock's time.
 *
 * @param rtc The clock read: an MC146818 through its ports when it has them, else a PL031 at its mapped registers.
 * @return Its time in seconds since 1970 UTC; or null, only for an MC146818, if its ports fail, it's always updating,
 *     its reads never agree, or it holds no date and time. A PL031's count is always taken as it is.
 */
read_rtc :: fn(rtc: ptr[Rtc]) -> i64? {
    match rtc.ports {
        case Some(ports) => return read_mc146818(ports)
        case None => return cast[i64](read_register(rtc.registers, PL031_DATA))
    }
}

/**
 * Set the real-time clock's time.
 *
 * @param rtc The clock set: an MC146818 through its ports when it has them, else a PL031 at its mapped registers.
 * @param seconds The time, in seconds since 1970 UTC, within what the clock can hold: for a PL031, 0 to 0xffffffff,
 *     and for an MC146818, a year it can hold (the caller keeps it to FIRST_YEAR to LAST_YEAR).
 * @return True if the clock took it; false if it's out of a PL031's range, or an MC146818's ports failed, which may
 *     leave some of its fields written.
 */
write_rtc :: fn(rtc: ptr[Rtc], seconds: i64) -> bool {
    match rtc.ports {
        case Some(ports) => return write_mc146818(ports, seconds)
        case None => {
            if seconds < 0 || seconds > 0xffffffff {
                return false
            }
            write_register(rtc.registers, PL031_LOAD, cast[u32](seconds))
            return true
        }
    }
}

/** The MC146818's fields, which hold a date and time, each as read: BCD or binary, as status register B says. */
Fields :: struct {
    second : u32, /**< The second, 0 to 59. */
    minute : u32, /**< The minute, 0 to 59. */
    hour : u32, /**< The hour, 0 to 23, or 1 to 12 with HOURS_PM in 12-hour mode. */
    day : u32, /**< The day of the month, 1 to 31. */
    month : u32, /**< The month, 1 to 12. */
    year : u32, /**< The year of the century, 0 to 99. */
    century : u32, /**< What register 0x32 holds: the century on PCs that keep it there, anything on others. */
}

/**
 * Read an MC146818's time, outside an update, until two reads in a row agree, so no field was read on either side of a
 * second's turn.
 *
 * Its fields are taken as stored, BCD or binary, 12 or 24 hours, as status register B says. It waits for an update to
 * end by polling status register A, up to 100,000 times a read, and tries 10 reads.
 *
 * @param ports The MC146818's index port then its data port.
 * @return Its time in seconds since 1970 UTC; null if a port fails, no two reads agree, or what it holds isn't a date
 *     and time.
 */
read_mc146818 :: fn(ports: slop_os.IoPortRange) -> i64? {
    status :: cmos_read(ports, CMOS_STATUS_B) or_return null
    last := Fields.{}
    for attempt in 0..<10 {
        // While it's updating its fields are passing from one second to the next
        for wait in 0..<100_000 {
            if ((cmos_read(ports, CMOS_STATUS_A) or_return null) & STATUS_A_UPDATING) == 0 {
                break
            }
        }
        fields :: read_fields(ports) or_return null
        if attempt > 0 && fields == last {
            return seconds_of(fields, status)
        }
        last = fields
    }
    return null
}

/**
 * Read an MC146818's fields, as they're stored, and the century register's.
 *
 * @param ports The MC146818's index port then its data port.
 * @return The fields, or null if a port fails.
 */
read_fields :: fn(ports: slop_os.IoPortRange) -> Fields? {
    return Fields.{
        second = cmos_read(ports, CMOS_SECONDS) or_return null,
        minute = cmos_read(ports, CMOS_MINUTES) or_return null,
        hour = cmos_read(ports, CMOS_HOURS) or_return null,
        day = cmos_read(ports, CMOS_DAY) or_return null,
        month = cmos_read(ports, CMOS_MONTH) or_return null,
        year = cmos_read(ports, CMOS_YEAR) or_return null,
        century = cmos_read(ports, CMOS_CENTURY) or_return null,
    }
}

/**
 * Translate an MC146818's fields to seconds since 1970.
 *
 * @param fields The time's fields as read_fields reads them, each its register's raw value: BCD or binary, and the
 *     hour 12 or 24 hours with its PM bit, as status says.
 * @param status Status register B, which says whether they're BCD or binary, and 12 or 24 hours.
 * @return Their time in seconds since 1970 UTC, the century as century_of says; null if a field isn't valid BCD, or
 *     isn't in its range (the day isn't checked against its month).
 */
seconds_of :: fn(fields: Fields, status: u32) -> i64? {
    binary :: (status & STATUS_B_BINARY) != 0
    pm :: (status & STATUS_B_24_HOUR) == 0 && (fields.hour & HOURS_PM) != 0
    hour := decode(fields.hour & ~HOURS_PM, binary) or_return null
    if (status & STATUS_B_24_HOUR) == 0 {
        // 12 is midnight, or noon
        hour = hour % 12 + (if pm { cast[u32](12) } else { cast[u32](0) })
    }
    century :: century_of(fields.century, binary)
    moment :: time.DateTime.{
        year = cast[i64](century) * 100 + cast[i64](decode(fields.year, binary) or_return null),
        month = cast[int](decode(fields.month, binary) or_return null),
        day = cast[int](decode(fields.day, binary) or_return null),
        hour = cast[int](hour),
        minute = cast[int](decode(fields.minute, binary) or_return null),
        second = cast[int](decode(fields.second, binary) or_return null),
    }
    if moment.month < 1 || moment.month > 12 || moment.day < 1 || moment.day > 31 || moment.hour > 23 || moment.minute > 59
        || moment.second > 59 {
        return null
    }
    return time.from_utc(moment).seconds
}

/**
 * Read the century from what the century register holds.
 *
 * @param stored The century register's value as read.
 * @param binary Whether the fields are binary, not BCD.
 * @return The century, 19 to 21, if that's what it holds; 20 otherwise, as for a PC without a century register.
 */
century_of :: fn(stored: u32, binary: bool) -> u32 {
    century :: decode(stored, binary) or_return 20
    return if century >= 19 && century <= 21 { century } else { cast[u32](20) }
}

/**
 * Set an MC146818 to a time, in the format status register B says, with SET held so it doesn't update while its fields
 * are written.
 *
 * The century register is written only if it held a century already, from 19 to 21, so one that's something else on
 * this PC isn't overwritten. SET is cleared after, whether the fields were written or not.
 *
 * @param ports The MC146818's index port then its data port.
 * @param seconds The time, in seconds since 1970 UTC, in a year from 1900 to 2199 at most, 2000 to 2099 without a
 *     century register.
 * @return True if every field was written; false if a port failed, which may leave some written.
 */
write_mc146818 :: fn(ports: slop_os.IoPortRange, seconds: i64) -> bool {
    status :: cmos_read(ports, CMOS_STATUS_B) or_return false
    binary :: (status & STATUS_B_BINARY) != 0
    moment :: time.utc(time.Instant.{seconds = seconds})
    hour := cast[u32](moment.hour)
    if (status & STATUS_B_24_HOUR) == 0 {
        // 1 to 12, and the PM bit after noon
        twelve :: if hour % 12 == 0 { cast[u32](12) } else { hour % 12 }
        hour = encode(twelve, binary) | (if hour >= 12 { HOURS_PM } else { cast[u32](0) })
    }
    else {
        hour = encode(hour, binary)
    }
    stored_century :: cmos_read(ports, CMOS_CENTURY) or_return false
    keeps_century :: century_of(stored_century, binary) == (decode(stored_century, binary) or_else 0)
    cmos_write(ports, CMOS_STATUS_B, status | STATUS_B_SET) or_return false
    written :: (cmos_write(ports, CMOS_SECONDS, encode(cast[u32](moment.second), binary)) is_ok)
        && (cmos_write(ports, CMOS_MINUTES, encode(cast[u32](moment.minute), binary)) is_ok)
        && (cmos_write(ports, CMOS_HOURS, hour) is_ok)
        && (cmos_write(ports, CMOS_DAY, encode(cast[u32](moment.day), binary)) is_ok)
        && (cmos_write(ports, CMOS_MONTH, encode(cast[u32](moment.month), binary)) is_ok)
        && (cmos_write(ports, CMOS_YEAR, encode(cast[u32](moment.year % 100), binary)) is_ok)
        && (!keeps_century || (cmos_write(ports, CMOS_CENTURY, encode(cast[u32](moment.year / 100), binary)) is_ok))
    _ = cmos_write(ports, CMOS_STATUS_B, status & ~STATUS_B_SET)
    return written
}

/**
 * Decode an MC146818 field's value.
 *
 * @param stored A field's raw register value: two BCD digits, 0x00 to 0x99, or binary as it is.
 * @param binary Whether it's binary, kept as it is, not BCD.
 * @return Its value; null for BCD with a digit above 9.
 */
decode :: fn(stored: u32, binary: bool) -> u32? {
    if binary {
        return stored
    }
    if (stored & 0x0f) > 9 || (stored >> 4) > 9 {
        return null
    }
    return (stored >> 4) * 10 + (stored & 0x0f)
}

/**
 * Encode a value as an MC146818 field.
 *
 * @param value The value, 0 to 99.
 * @param binary Whether it's stored binary, as it is, not BCD.
 * @return What's written to the field.
 */
encode :: fn(value: u32, binary: bool) -> u32 {
    return if binary { value } else { (value / 10) << 4 | value % 10 }
}

/**
 * Read an MC146818 register, selecting it through the index port and reading the data port.
 *
 * @param ports The MC146818's index port then its data port.
 * @param index The register's index, CMOS_SECONDS to CMOS_CENTURY.
 * @return The register's byte, or null if a port fails.
 */
cmos_read :: fn(ports: slop_os.IoPortRange, index: u32) -> u32? {
    if (slop_os.io_port_write(ports, 0, 1, index) is_error) {
        return null
    }
    return slop_os.io_port_read(ports, 1, 1) or_return null
}

/**
 * Write an MC146818 register, selecting it through the index port and writing the data port.
 *
 * @param ports The MC146818's index port then its data port.
 * @param index The register's index, CMOS_SECONDS to CMOS_CENTURY.
 * @param value The byte to write; only its low 8 bits are.
 * @return Ok once the index and the byte are written; the first port that fails stops it.
 * @error InvalidHandle The ports' handle isn't the service's, or was closed.
 * @error MissingRight The ports' handle can't access them.
 */
cmos_write :: fn(ports: slop_os.IoPortRange, index: u32, value: u32) -> Result[void, slop_os.DeviceError] {
    slop_os.io_port_write(ports, 0, 1, index)?
    return slop_os.io_port_write(ports, 1, 1, value)
}

/**
 * Read a PL031 register.
 *
 * @param base Where the PL031's registers are mapped.
 * @param offset The register's offset in bytes, PL031_DATA to PL031_CONTROL.
 * @return The register's 32 bits as the device gives them; for PL031_DATA, the time in seconds since 1970 UTC.
 */
read_register :: fn(base: u64, offset: u64) -> u32 {
    return intrinsics.volatile_load_u32(cast[ptr[u32]](base + offset))
}

/**
 * Write a PL031 register.
 *
 * @param base Where the PL031's registers are mapped.
 * @param offset The register's offset in bytes, PL031_DATA to PL031_CONTROL.
 * @param value The 32 bits written, as the register takes them; for PL031_LOAD, the time in seconds since 1970 UTC.
 */
write_register :: fn(base: u64, offset: u64, value: u32) {
    intrinsics.volatile_store_u32(cast[ptr[mut u32]](base + offset), value)
}

/**
 * Append a time as a UTC date and time, like 2030-01-02 03:04:05 UTC.
 *
 * @param line Where it's appended; what doesn't fit is cut off, as text_buffer cuts it.
 * @param seconds The time, in seconds since 1970 UTC.
 */
append_time :: fn(line: ptr[mut text_buffer.TextBuffer], seconds: i64) {
    moment :: time.utc(time.Instant.{seconds = seconds})
    text_buffer.append_format(line, "%-", moment.year)
    append_two_digits(line, moment.month)
    text_buffer.append_format(line, "-")
    append_two_digits(line, moment.day)
    text_buffer.append_format(line, " ")
    append_two_digits(line, moment.hour)
    text_buffer.append_format(line, ":")
    append_two_digits(line, moment.minute)
    text_buffer.append_format(line, ":")
    append_two_digits(line, moment.second)
    text_buffer.append_format(line, " UTC")
}

/**
 * Append a field of a date or time as two digits, with a 0 in front of it below 10.
 *
 * @param line Where it's appended.
 * @param value The field, 0 or more; one above 99 is appended whole.
 */
append_two_digits :: fn(line: ptr[mut text_buffer.TextBuffer], value: int) {
    if value < 10 {
        text_buffer.append_format(line, "0")
    }
    text_buffer.append_format(line, "%", value)
}
