/*
 * The clock service (roadmap 9a, decisions/0093): the real-time clock's driver, which keeps the clock page every
 * program reads the time from (base's runtime.SlopOsClockPage, given to each as its grant "clock"). It reads the clock
 * when it starts, and puts that time on the page at the monotonic reading it was read at; from there base's runtime
 * counts on with the monotonic clock. Who holds a connection to its listener (the clock_setting protocol) can set the
 * time, which it writes to the real-time clock and the page together. It logs through base's logger, to the events
 * service.
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
import service_kit from "../../service_kit"
import clock_setting from "../../protocols/clock_setting"

NANOSECONDS : i64 : 1_000_000_000
PAGE : u64 : 4096

// The MC146818's registers, through its index port (offset 0) and its data port (offset 1)
CMOS_SECONDS : u32 : 0x00
CMOS_MINUTES : u32 : 0x02
CMOS_HOURS : u32 : 0x04
CMOS_DAY : u32 : 0x07
CMOS_MONTH : u32 : 0x08
CMOS_YEAR : u32 : 0x09
CMOS_STATUS_A : u32 : 0x0a
CMOS_STATUS_B : u32 : 0x0b
CMOS_CENTURY : u32 : 0x32
STATUS_A_UPDATING : u32 : 0x80
STATUS_B_SET : u32 : 0x80
STATUS_B_BINARY : u32 : 0x04
STATUS_B_24_HOUR : u32 : 0x02
HOURS_PM : u32 : 0x80

// The PL031's registers
PL031_DATA : u64 : 0x000
PL031_LOAD : u64 : 0x008
PL031_CONTROL : u64 : 0x00c
PL031_START : u32 : 1

// The years an MC146818 holds without a century register, and the most a PL031's 32 bits of seconds reach
FIRST_YEAR : i64 : 2000
LAST_YEAR : i64 : 2099

// The real-time clock: its ports, or its registers mapped at registers
Rtc :: struct {
    ports : slop_os.IoPortRange?,
    registers : u64,
}

Clock :: struct {
    rtc : Rtc,
    page : ptr[mut runtime.SlopOsClockPage],
}

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

// Every request client index has sent, until there are none left, or it's gone.
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
            case Invalid => continue
            case WrongProtocol => continue
            case Failed(error) => {
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

/*
 * The time set to utc, nanoseconds since 1970: the real-time clock to its second, then the page, to the nanosecond, at
 * the monotonic reading it was written at. False, with nothing changed, if the clock can't hold it.
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

// The page's time made utc at the monotonic reading at, under its sequence (runtime.SlopOsClockPage).
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

// The clock's time, in seconds since 1970, or null if it holds none that can be read.
read_rtc :: fn(rtc: ptr[Rtc]) -> i64? {
    match rtc.ports {
        case Some(ports) => return read_mc146818(ports)
        case None => return cast[i64](read_register(rtc.registers, PL031_DATA))
    }
}

// The clock set to seconds since 1970, which it can hold: whether it took them.
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

// The MC146818's fields, which hold a date and time.
Fields :: struct {
    second : u32,
    minute : u32,
    hour : u32,
    day : u32,
    month : u32,
    year : u32,
    century : u32,
}

/*
 * Its time, read outside an update, twice, until two reads agree, so no field was read on either side of a second's
 * turn; as stored, BCD or binary, 12 or 24 hours (status register B).
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

// What the fields hold, stored as status register B says, in seconds since 1970; null if it isn't a date and time.
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

// The century in register 0x32, if it holds one from 19 to 21, or 20.
century_of :: fn(stored: u32, binary: bool) -> u32 {
    century :: decode(stored, binary) or_return 20
    return if century >= 19 && century <= 21 { century } else { cast[u32](20) }
}

/*
 * The clock set to seconds since 1970, in the format status register B says, with SET held so it doesn't update
 * while its fields are written; the century register only if it holds a century.
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

// A field's value, from BCD unless it's binary; null for BCD that isn't.
decode :: fn(stored: u32, binary: bool) -> u32? {
    if binary {
        return stored
    }
    if (stored & 0x0f) > 9 || (stored >> 4) > 9 {
        return null
    }
    return (stored >> 4) * 10 + (stored & 0x0f)
}

encode :: fn(value: u32, binary: bool) -> u32 {
    return if binary { value } else { (value / 10) << 4 | value % 10 }
}

cmos_read :: fn(ports: slop_os.IoPortRange, index: u32) -> u32? {
    if (slop_os.io_port_write(ports, 0, 1, index) is_error) {
        return null
    }
    return slop_os.io_port_read(ports, 1, 1) or_return null
}

cmos_write :: fn(ports: slop_os.IoPortRange, index: u32, value: u32) -> Result[void, slop_os.DeviceError] {
    slop_os.io_port_write(ports, 0, 1, index)?
    return slop_os.io_port_write(ports, 1, 1, value)
}

read_register :: fn(base: u64, offset: u64) -> u32 {
    return intrinsics.volatile_load_u32(cast[ptr[u32]](base + offset))
}

write_register :: fn(base: u64, offset: u64, value: u32) {
    intrinsics.volatile_store_u32(cast[ptr[mut u32]](base + offset), value)
}

// Seconds since 1970 as a UTC date and time, like 2030-01-02 03:04:05 UTC, appended to line.
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

// A field of a date or time, with a 0 in front of it below 10.
append_two_digits :: fn(line: ptr[mut text_buffer.TextBuffer], value: int) {
    if value < 10 {
        text_buffer.append_format(line, "0")
    }
    text_buffer.append_format(line, "%", value)
}
