package libc

/*
 * stdlib.h's numbers from text (decisions/0201, 20l): strtol's family and strtod's, which read as much of a number as
 * there is after any white space, and say where they stopped; a number too big sets errno to ERANGE. Decimal floats are
 * read exactly by std's math, rounded once; hexadecimal ones, C99's 0x1.8p3, by hand, rounded once from 64 bits.
 */

import math from "std:math"

/** The biggest i64, which strtol gives for a number too big, and the end of what a positive one may be. */
I64_MAX : u64 : 0x7fff_ffff_ffff_ffff

/** What reading an integer found. */
Integer :: struct {
    /** The magnitude read, up to the first digit that would overflow a u64; ~0 then. */
    magnitude : u64,
    /** Whether a minus came before it. */
    negative : bool,
    /** Whether it didn't fit in a u64. */
    overflowed : bool,
    /** How many bytes of the text it took, white space and sign included; 0 if there was no number. */
    taken : usize,
}

/**
 * Find a digit's value in any base up to 36.
 *
 * @param byte The byte.
 * @return 0 to 9 for its digits, 10 to 35 for a to z or A to Z; 99 for anything else.
 */
digit_value :: fn(byte : u8) -> u64 {
    if byte >= cast[u8]('0') && byte <= cast[u8]('9') {
        return cast[u64](byte - cast[u8]('0'))
    }
    lower :: lowered(byte)
    if lower >= cast[u8]('a') && lower <= cast[u8]('z') {
        return cast[u64](lower - cast[u8]('a')) + 10
    }
    return 99
}

/**
 * Count the white space a C string starts with, as isspace says.
 *
 * @param text The string.
 * @return How many bytes of white space come first.
 */
leading_space :: fn(text : ptr[u8]) -> usize {
    i : usize = 0
    loop {
        if isspace(cast[i32](byte_at(text, i))) == 0 {
            return i
        }
        i += 1
    }
}

/**
 * Read an integer from a C string as strtoull does: white space, a sign, a 0x or 0 prefix as the base allows, then
 * digits.
 *
 * @param text The string.
 * @param base 2 to 36, or 0 for C's: 0x for 16, a leading 0 for 8, else 10. 16 takes a 0x too.
 * @return What it found; taken 0 if there were no digits, or the base isn't valid.
 */
read_integer :: fn(text : ptr[u8], base : i32) -> Integer {
    found := Integer.{}
    if base < 0 || base == 1 || base > 36 {
        return found
    }
    at := leading_space(text)
    sign :: byte_at(text, at)
    if sign == cast[u8]('-') || sign == cast[u8]('+') {
        found.negative = sign == cast[u8]('-')
        at += 1
    }
    radix := cast[u64](base)
    // A 0x only counts with a hexadecimal digit after it: "0x" alone is a 0, ended at its x
    hex_prefix :: byte_at(text, at) == cast[u8]('0') && lowered(byte_at(text, at + 1)) == cast[u8]('x')
        && digit_value(byte_at(text, at + 2)) < 16
    if (radix == 0 || radix == 16) && hex_prefix {
        radix = 16
        at += 2
    }
    else if radix == 0 {
        radix = if byte_at(text, at) == cast[u8]('0') { cast[u64](8) } else { cast[u64](10) }
    }
    digits := 0
    loop {
        value :: digit_value(byte_at(text, at))
        if value >= radix {
            break
        }
        if !found.overflowed {
            if found.magnitude > (~cast[u64](0) - value) / radix {
                found.overflowed = true
                found.magnitude = ~cast[u64](0)
            }
            else {
                found.magnitude = found.magnitude * radix + value
            }
        }
        digits += 1
        at += 1
    }
    found.taken = if digits > 0 { at } else { 0 }
    return found
}

/**
 * Say where reading stopped, for strtol's family's end.
 *
 * @param text The string read.
 * @param end Where the end goes, or NULL not to say.
 * @param taken How many bytes were read: 0 points end at text itself.
 */
set_end :: fn(text #escaping : ptr[u8], end : ptr[mut ptr[mut u8]]?, taken : usize) {
    match end {
        case Some(place) => place^ = at_offset(text, taken)
        case None => {}
    }
}

/**
 * Read a signed integer from a C string, clamped to an i64.
 *
 * @param text The string.
 * @param end Where to say reading stopped: after the number, or text itself without one; NULL not to say.
 * @param base As read_integer's.
 * @return The number; 0 without one, errno EINVAL for a base that isn't valid; the i64's limit past it, errno ERANGE.
 */
strtoll #export #calling_convention(.c) :: fn(text #escaping : ptr[u8], end : ptr[mut ptr[mut u8]]?, base : i32) -> i64 {
    found :: read_integer(text, base)
    set_end(text, end, found.taken)
    if base < 0 || base == 1 || base > 36 {
        set_errno(E_INVAL)
        return 0
    }
    limit :: if found.negative { I64_MAX + 1 } else { I64_MAX }
    if found.overflowed || found.magnitude > limit {
        set_errno(E_RANGE)
        return if found.negative { cast[i64](I64_MAX + 1) } else { cast[i64](I64_MAX) }
    }
    return if found.negative { -cast[i64](found.magnitude) } else { cast[i64](found.magnitude) }
}

/**
 * Read a signed long from a C string: on SlopOS's architectures a long is 64 bits, so it's strtoll.
 *
 * @param text The string.
 * @param end As strtoll's.
 * @param base As strtoll's.
 * @return As strtoll's.
 */
strtol #export #calling_convention(.c) :: fn(text #escaping : ptr[u8], end : ptr[mut ptr[mut u8]]?, base : i32) -> i64 {
    return strtoll(text, end, base)
}

/**
 * Read the largest signed integer, intmax_t, from a C string: strtoll.
 *
 * @param text The string.
 * @param end As strtoll's.
 * @param base As strtoll's.
 * @return As strtoll's.
 */
strtoimax #export #calling_convention(.c) :: fn(text #escaping : ptr[u8], end : ptr[mut ptr[mut u8]]?, base : i32) -> i64 {
    return strtoll(text, end, base)
}

/**
 * Read an unsigned integer from a C string; a minus negates it, wrapping, as C says.
 *
 * @param text The string.
 * @param end As strtoll's.
 * @param base As read_integer's.
 * @return The number; 0 without one, errno EINVAL for a base that isn't valid; ~0 past a u64, errno ERANGE.
 */
strtoull #export #calling_convention(.c) :: fn(text #escaping : ptr[u8], end : ptr[mut ptr[mut u8]]?, base : i32) -> u64 {
    found :: read_integer(text, base)
    set_end(text, end, found.taken)
    if base < 0 || base == 1 || base > 36 {
        set_errno(E_INVAL)
        return 0
    }
    if found.overflowed {
        set_errno(E_RANGE)
        return ~cast[u64](0)
    }
    return if found.negative { ~found.magnitude + 1 } else { found.magnitude }
}

/**
 * Read an unsigned long from a C string: 64 bits, so strtoull.
 *
 * @param text The string.
 * @param end As strtoull's.
 * @param base As strtoull's.
 * @return As strtoull's.
 */
strtoul #export #calling_convention(.c) :: fn(text #escaping : ptr[u8], end : ptr[mut ptr[mut u8]]?, base : i32) -> u64 {
    return strtoull(text, end, base)
}

/**
 * Read the largest unsigned integer, uintmax_t, from a C string: strtoull.
 *
 * @param text The string.
 * @param end As strtoull's.
 * @param base As strtoull's.
 * @return As strtoull's.
 */
strtoumax #export #calling_convention(.c) :: fn(text #escaping : ptr[u8], end : ptr[mut ptr[mut u8]]?, base : i32) -> u64 {
    return strtoull(text, end, base)
}

/**
 * Read a decimal int from a C string, as strtol does, cut to 32 bits.
 *
 * @param text The string.
 * @return The number, its low 32 bits; 0 without one.
 */
atoi #export #calling_convention(.c) :: fn(text #escaping : ptr[u8]) -> i32 {
    return cast[i32](strtoll(text, null, 10))
}

/**
 * Read a decimal long from a C string, as strtol does.
 *
 * @param text The string.
 * @return The number; 0 without one.
 */
atol #export #calling_convention(.c) :: fn(text #escaping : ptr[u8]) -> i64 {
    return strtoll(text, null, 10)
}

/**
 * Read a decimal long long from a C string, as strtoll does.
 *
 * @param text The string.
 * @return The number; 0 without one.
 */
atoll #export #calling_convention(.c) :: fn(text #escaping : ptr[u8]) -> i64 {
    return strtoll(text, null, 10)
}

/**
 * Tell whether a C string has a word at an offset, ASCII case ignored.
 *
 * @param text The string.
 * @param at Where the word would start.
 * @param word The word, lowercase.
 * @return True if the bytes from at are word's, whatever their case.
 */
has_word :: fn(text : ptr[u8], at : usize, word : string) -> bool {
    bytes :: string_bytes(word)
    for i in 0..<bytes.count {
        if lowered(byte_at(text, at + i)) != bytes[i] {
            return false
        }
    }
    return true
}

/**
 * Count the digits at an offset in a C string.
 *
 * @param text The string.
 * @param at Where to start.
 * @param radix 10 or 16: which digits count.
 * @return How many digits come there in a row.
 */
digits_at :: fn(text : ptr[u8], at : usize, radix : u64) -> usize {
    count : usize = 0
    loop {
        if digit_value(byte_at(text, at + count)) >= radix {
            return count
        }
        count += 1
    }
}

/**
 * Read a hexadecimal float's digits and exponent, C99's: hex digits with an optional point, then an optional p and a
 * signed decimal power of two.
 *
 * @param text The string.
 * @param at Where its first digit or point is, after the 0x.
 * @param negative Whether a minus came before it.
 * @return value The value, rounded once to the nearest double; 0 when there are no digits.
 * @return end Where it ended, in bytes from text: at itself when there are no digits.
 */
read_hex_float :: fn(text : ptr[u8], at : usize, negative : bool) -> (value : f64, end : usize) {
    mantissa : u64 = 0
    exponent : i64 = 0
    sticky := false
    digits := 0
    point := false
    i := at
    loop {
        byte :: byte_at(text, i)
        if byte == cast[u8]('.') && !point {
            point = true
            i += 1
            continue
        }
        value :: digit_value(byte)
        if value >= 16 {
            break
        }
        digits += 1
        if mantissa >> 60 == 0 {
            mantissa = mantissa * 16 + value
            if point {
                exponent -= 4
            }
        }
        else {
            // Past 64 bits: only whether anything's there counts, for rounding
            sticky = sticky || value != 0
            if !point {
                exponent += 4
            }
        }
        i += 1
    }
    if digits == 0 {
        return 0.0, at
    }
    if lowered(byte_at(text, i)) == cast[u8]('p') {
        sign_at := i + 1
        sign :: byte_at(text, sign_at)
        minus :: sign == cast[u8]('-')
        if minus || sign == cast[u8]('+') {
            sign_at += 1
        }
        count :: digits_at(text, sign_at, 10)
        if count > 0 {
            power : i64 = 0
            for k in 0..<count {
                if power < 100000 {
                    power = power * 10 + cast[i64](digit_value(byte_at(text, sign_at + k)))
                }
            }
            exponent += (if minus { -power } else { power })
            i = sign_at + count
        }
    }
    if sticky {
        mantissa |= 1
    }
    clamped :: if exponent > 10000 { cast[i64](10000) } else if exponent < -10000 { cast[i64](-10000) } else { exponent }
    value :: math.scale_by_power_of_two(cast[f64](mantissa), cast[i32](clamped))
    signed :: if negative { -value } else { value }
    return signed, i
}

/**
 * Read a double from a C string: white space, a sign, then decimal digits with an optional point and exponent, a
 * hexadecimal float, or inf, infinity or nan (a nan's parenthesized characters taken too), any case.
 *
 * @param text The string.
 * @param end Where to say reading stopped: after the number, or text itself without one; NULL not to say.
 * @return The number; 0 without one; ±HUGE_VAL past the largest double, and a zero below the least subnormal, each
 *     with errno ERANGE.
 */
strtod #export #calling_convention(.c) :: fn(text #escaping : ptr[u8], end : ptr[mut ptr[mut u8]]?) -> f64 {
    start :: leading_space(text)
    at := start
    sign :: byte_at(text, at)
    negative :: sign == cast[u8]('-')
    if negative || sign == cast[u8]('+') {
        at += 1
    }
    // inf, infinity and nan, and nan(...)
    if has_word(text, at, "infinity") || has_word(text, at, "inf") {
        set_end(text, end, at + (if has_word(text, at, "infinity") { cast[usize](8) } else { cast[usize](3) }))
        return if negative { -math.infinity[f64]() } else { math.infinity[f64]() }
    }
    if has_word(text, at, "nan") {
        after := at + 3
        if byte_at(text, after) == cast[u8]('(') {
            close := after + 1
            loop {
                byte :: byte_at(text, close)
                if byte == cast[u8](')') {
                    after = close + 1
                    break
                }
                if isalnum(cast[i32](byte)) == 0 && byte != cast[u8]('_') {
                    break
                }
                close += 1
            }
        }
        set_end(text, end, after)
        return if negative { -math.nan[f64]() } else { math.nan[f64]() }
    }
    if byte_at(text, at) == cast[u8]('0') && lowered(byte_at(text, at + 1)) == cast[u8]('x') {
        value, stop :: read_hex_float(text, at + 2, negative)
        if stop > at + 2 {
            set_end(text, end, stop)
            if math.is_infinite(value) {
                set_errno(E_RANGE)
            }
            return value
        }
        // "0x" without hex digits: the 0, ended at its x
        set_end(text, end, at + 1)
        return if negative { -0.0 } else { 0.0 }
    }
    whole :: digits_at(text, at, 10)
    i := at + whole
    fraction : usize = 0
    if byte_at(text, i) == cast[u8]('.') {
        fraction = digits_at(text, i + 1, 10)
        i += 1 + fraction
    }
    if whole == 0 && fraction == 0 {
        set_end(text, end, 0)
        return 0.0
    }
    if lowered(byte_at(text, i)) == cast[u8]('e') {
        sign_at := i + 1
        exponent_sign :: byte_at(text, sign_at)
        if exponent_sign == cast[u8]('-') || exponent_sign == cast[u8]('+') {
            sign_at += 1
        }
        count :: digits_at(text, sign_at, 10)
        if count > 0 {
            i = sign_at + count
        }
    }
    set_end(text, end, i)
    number :: string_of(at_offset(text, start), i - start)
    value :: math.parse[f64](number) or_else 0.0
    if math.is_infinite(value) {
        set_errno(E_RANGE)
    }
    else if value == 0.0 && has_nonzero_digit(text, at, i) {
        set_errno(E_RANGE)
    }
    return value
}

/**
 * Tell whether any of the digits of a number's mantissa isn't 0, to tell an underflow from a zero.
 *
 * @param text The string.
 * @param from Where the number's digits start.
 * @param to Where the number ends.
 * @return True if there's a digit 1 to 9 before the exponent.
 */
has_nonzero_digit :: fn(text : ptr[u8], from : usize, to : usize) -> bool {
    for i in from..<to {
        byte :: byte_at(text, i)
        if lowered(byte) == cast[u8]('e') {
            return false
        }
        if byte >= cast[u8]('1') && byte <= cast[u8]('9') {
            return true
        }
    }
    return false
}

/**
 * Read a float from a C string, as strtod, rounded to a float.
 *
 * @param text The string.
 * @param end As strtod's.
 * @return As strtod's, as a float: rounded twice, from the double.
 */
strtof #export #calling_convention(.c) :: fn(text #escaping : ptr[u8], end : ptr[mut ptr[mut u8]]?) -> f32 {
    return cast[f32](strtod(text, end))
}

/**
 * Read a double from a C string, as strtod does.
 *
 * @param text The string.
 * @return The number; 0 without one.
 */
atof #export #calling_convention(.c) :: fn(text #escaping : ptr[u8]) -> f64 {
    return strtod(text, null)
}

/**
 * Give an int's magnitude.
 *
 * @param value The int.
 * @return Its magnitude; INT_MIN's own, wrapped, as it has none.
 */
abs #export #calling_convention(.c) #no_context :: fn(value : i32) -> i32 {
    return if value < 0 { -value } else { value }
}

/**
 * Give a long's magnitude.
 *
 * @param value The long, 64 bits.
 * @return Its magnitude; LONG_MIN's own, wrapped.
 */
labs #export #calling_convention(.c) #no_context :: fn(value : i64) -> i64 {
    return if value < 0 { -value } else { value }
}

/**
 * Give a long long's magnitude.
 *
 * @param value The long long.
 * @return Its magnitude; LLONG_MIN's own, wrapped.
 */
llabs #export #calling_convention(.c) #no_context :: fn(value : i64) -> i64 {
    return if value < 0 { -value } else { value }
}
