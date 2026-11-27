package libc

/*
 * time.h's clocks and dates (decisions/0201, 20l): the wall clock and the monotonic one of the context run called C
 * with, and dates on the proleptic Gregorian calendar by std's time. Local time is UTC, as SlopOS gives a program no
 * time zone; time.c's gmtime, localtime, mktime and strftime are over these.
 */

import runtime from "base:runtime"
import time as std_time from "std:time"

/** clock_gettime's CLOCK_REALTIME: the wall clock. */
CLOCK_REALTIME : i32 : 0
/** clock_gettime's CLOCK_MONOTONIC: a clock that only goes forward. */
CLOCK_MONOTONIC : i32 : 1
/** clock_gettime's CLOCK_PROCESS_CPUTIME_ID: the time since the program's C started, as clock measures it. */
CLOCK_PROCESS_CPUTIME_ID : i32 : 2

/** C's struct timespec. */
Timespec :: struct {
    /** Whole seconds: since the epoch for the wall clock, since the clock's own start for the others. */
    seconds : i64,
    /** Nanoseconds past them, 0 to 999,999,999. */
    nanoseconds : i64,
}

#assert size_of(Timespec) == 16

/** The nine fields of C's struct tm that every C has, in its order; time.c sets the two after. */
BrokenDown :: struct {
    /** Seconds after the minute, 0 to 59 (60 for a leap second, which UTC here never has). */
    second : i32,
    /** Minutes after the hour, 0 to 59. */
    minute : i32,
    /** Hours since midnight, 0 to 23. */
    hour : i32,
    /** The day of the month, 1 to 31. */
    day : i32,
    /** Months since January, 0 to 11. */
    month : i32,
    /** Years since 1900. */
    year : i32,
    /** Days since Sunday, 0 to 6. */
    weekday : i32,
    /** Days since January 1st, 0 to 365. */
    year_day : i32,
    /** Whether summer time is in effect: never in UTC, so 0. */
    summer : i32,
}

#assert size_of(BrokenDown) == 36

/**
 * Read the wall clock, in whole seconds since the epoch.
 *
 * @param now Where to write it too, or NULL.
 * @return The seconds since 1970-01-01T00:00:00Z; -1 if the clock can't be read or hasn't been set.
 */
time #export #calling_convention(.c) :: fn(now : ptr[mut i64]?) -> i64 {
    seconds :: match std_time.now() {
        case Ok(instant) => instant.seconds
        case Error(error) => cast[i64](-1)
    }
    match now {
        case Some(place) => place^ = seconds
        case None => {}
    }
    return seconds
}

/**
 * Measure the time the program's C has had, in microseconds: SlopOS gives no processor time, so it's the time since
 * run started C.
 *
 * @return Microseconds since C started, CLOCKS_PER_SEC a second.
 */
clock #export #calling_convention(.c) :: fn() -> i64 {
    state :: state_of() or_return 0
    taken :: std_time.since(state.started)
    return taken.seconds * 1_000_000 + cast[i64](taken.nanos / 1000)
}

/**
 * Read a clock, to the nanosecond.
 *
 * @param clock CLOCK_REALTIME, CLOCK_MONOTONIC or CLOCK_PROCESS_CPUTIME_ID.
 * @param now Where the reading goes.
 * @return 0 once it's read; -1 with errno EINVAL for another clock, or EIO for a wall clock that can't be read.
 */
clock_gettime #export #calling_convention(.c) :: fn(clock : i32, now : ptr[mut Timespec]) -> i32 {
    if clock == CLOCK_REALTIME {
        match std_time.now() {
            case Ok(instant) => {
                now^ = Timespec.{seconds = instant.seconds, nanoseconds = cast[i64](instant.nanos)}
                return 0
            }
            case Error(error) => {
                set_errno(E_IO)
                return -1
            }
        }
    }
    if clock == CLOCK_MONOTONIC {
        reading :: cast[i64](std_time.monotonic())
        now^ = Timespec.{seconds = reading / 1_000_000_000, nanoseconds = reading % 1_000_000_000}
        return 0
    }
    if clock == CLOCK_PROCESS_CPUTIME_ID {
        state :: state_of() or_return -1
        taken :: std_time.since(state.started)
        now^ = Timespec.{seconds = taken.seconds, nanoseconds = cast[i64](taken.nanos)}
        return 0
    }
    set_errno(E_INVAL)
    return -1
}

/**
 * Break a moment down into UTC's calendar date and time of day, as gmtime_r does (time.c).
 *
 * @param moment Seconds since the epoch, of either sign.
 * @param into Where its nine fields go; the rest of C's struct tm isn't touched.
 * @return 0 once written; -1 with errno EOVERFLOW's stand-in ERANGE when its year doesn't fit in an int.
 */
slopos_libc_break_down #export #calling_convention(.c) :: fn(moment : i64, into : ptr[mut BrokenDown]) -> i32 {
    days :: std_time.floor_divide(moment, std_time.SECONDS_PER_DAY)
    seconds :: moment - days * std_time.SECONDS_PER_DAY
    year, month, day :: std_time.civil_from_days(days)
    since_1900 :: year - 1900
    if since_1900 > 2147483647 || since_1900 < -2147483647 - 1 {
        set_errno(E_RANGE)
        return -1
    }
    into^ = BrokenDown.{
        second = cast[i32](seconds % 60),
        minute = cast[i32]((seconds / 60) % 60),
        hour = cast[i32](seconds / 3600),
        day = cast[i32](day),
        month = cast[i32](month - 1),
        year = cast[i32](since_1900),
        // 1970-01-01 was a Thursday, day 4 from Sunday
        weekday = cast[i32](days - 7 * std_time.floor_divide(days + 4, 7) + 4),
        year_day = cast[i32](days - std_time.days_from_civil(year, 1, 1)),
        summer = 0,
    }
    return 0
}

/**
 * Put a UTC date and time back together into a moment, as timegm does: each field may be out of its range, and is
 * carried into the next, so day 0 is the month before's last, and month 12 next year's January.
 *
 * @param from The nine fields; only second, minute, hour, day, month and year are read.
 * @return Seconds since the epoch.
 */
slopos_libc_put_together #export #calling_convention(.c) :: fn(from : ptr[BrokenDown]) -> i64 {
    months :: cast[i64](from.year) * 12 + cast[i64](from.month)
    years :: std_time.floor_divide(months, 12)
    month :: months - years * 12
    days :: std_time.days_from_civil(years + 1900, cast[int](month) + 1, 1) + cast[i64](from.day) - 1
    clock :: cast[i64](from.hour) * 3600 + cast[i64](from.minute) * 60 + cast[i64](from.second)
    return days * std_time.SECONDS_PER_DAY + clock
}
