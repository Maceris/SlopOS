/*
 * format.c, SlopOS's libc (decisions/0201, 20l): the printf family's formatting and sscanf's reading, in C as they're
 * variadic. printf's conversions are C99's: d i u o x X c s p n % and the floats f F e E g G a A, with the flags - + space
 * # 0, a width and a precision (either may be *), and the lengths hh h l ll j z t (L is taken as none: long double is
 * double's here). A float is written from its exact decimal value, worked out with a big integer, then rounded once,
 * halfway to even, as glibc does; a precision past 1000 is taken as 1000.
 */
#include <errno.h>
#include <limits.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* How many bytes a stream's formatting gathers before writing them, so even an unbuffered one gets a line at once. */
#define STAGED 256

/*
 * Where formatted text goes: a stream, through staged, or a buffer of size bytes, the last kept for the 0 byte.
 */
struct output {
    FILE *stream;
    char *buffer;
    size_t size;
    /* Bytes formatted so far, whether or not they fit */
    size_t count;
    int failed;
    char staged[STAGED];
    size_t staged_count;
};

/* Write what's staged to the stream. */
static void unstage(struct output *out) {
    if (out->staged_count > 0 && fwrite(out->staged, 1, out->staged_count, out->stream) != out->staged_count) {
        out->failed = 1;
    }
    out->staged_count = 0;
}

/* Put bytes out: to the stream, staged, or as much as fits in the buffer. */
static void put(struct output *out, const char *text, size_t count) {
    if (count == 0) {
        return;
    }
    if (out->stream != NULL) {
        if (out->staged_count + count > STAGED) {
            unstage(out);
        }
        if (count > STAGED) {
            if (fwrite(text, 1, count, out->stream) != count) {
                out->failed = 1;
            }
        } else {
            memcpy(out->staged + out->staged_count, text, count);
            out->staged_count += count;
        }
    } else if (out->buffer != NULL && out->count + 1 < out->size) {
        size_t room = out->size - 1 - out->count;
        memcpy(out->buffer + out->count, text, count < room ? count : room);
    }
    out->count += count;
}

/* Put a byte out count times. */
static void put_many(struct output *out, char byte, int count) {
    char run[32];
    memset(run, byte, sizeof run);
    while (count > 0) {
        int now = count < (int)sizeof run ? count : (int)sizeof run;
        put(out, run, (size_t)now);
        count -= now;
    }
}

/* A conversion's flags. */
#define LEFT 1
#define PLUS 2
#define SPACE 4
#define ALTERNATE 8
#define ZERO 16

/*
 * Put a converted value out within its width: the prefix (a sign, 0x), then zeros to its precision's digits, then
 * the body, padded with spaces, or with zeros between the prefix and the body for the 0 flag.
 */
static void put_padded(struct output *out, const char *prefix, int zeros, const char *body, size_t length, int width,
                       int flags) {
    int prefix_length = (int)strlen(prefix);
    int total = prefix_length + zeros + (int)length;
    int padding = width > total ? width - total : 0;
    if (!(flags & LEFT) && !(flags & ZERO)) {
        put_many(out, ' ', padding);
    }
    put(out, prefix, (size_t)prefix_length);
    if (!(flags & LEFT) && (flags & ZERO)) {
        put_many(out, '0', padding);
    }
    put_many(out, '0', zeros);
    put(out, body, length);
    if (flags & LEFT) {
        put_many(out, ' ', padding);
    }
}

/* Write an unsigned integer's digits in a base, at the end of a buffer: where they start. */
static char *digits_of(uintmax_t value, unsigned base, int upper, char *end) {
    const char *digits = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    char *at = end;
    do {
        *--at = digits[value % base];
        value /= base;
    } while (value != 0);
    return at;
}

/* Put an integer out: its magnitude, whether it's negative, and its conversion. */
static void put_integer(struct output *out, uintmax_t magnitude, int negative, char conversion, int flags, int width,
                        int precision) {
    char text[72];
    char *end = text + sizeof text;
    unsigned base = conversion == 'o' ? 8 : conversion == 'x' || conversion == 'X' || conversion == 'p' ? 16 : 10;
    char *start = digits_of(magnitude, base, conversion == 'X', end);
    size_t length = (size_t)(end - start);
    /* A precision of 0 writes nothing for 0 */
    if (precision == 0 && magnitude == 0) {
        length = 0;
    }
    const char *prefix = "";
    if (conversion == 'd' || conversion == 'i') {
        prefix = negative ? "-" : (flags & PLUS) ? "+" : (flags & SPACE) ? " " : "";
    } else if (conversion == 'p' || ((flags & ALTERNATE) && magnitude != 0 && (conversion == 'x' || conversion == 'X'))) {
        prefix = conversion == 'X' ? "0X" : "0x";
    }
    int zeros = precision > (int)length ? precision - (int)length : 0;
    if (conversion == 'o' && (flags & ALTERNATE) && zeros == 0 && (length == 0 || start[0] != '0')) {
        zeros = 1;
    }
    /* With a precision, the 0 flag is ignored */
    put_padded(out, prefix, zeros, start, length, width, precision >= 0 ? flags & ~ZERO : flags);
}

/* The most decimal digits a double's exact value has: 767 significant, with room. */
#define MOST_DIGITS 800
/* Limbs of 10^9 a double's exact value needs: m × 5^1074 has about 770 digits. */
#define LIMBS 100

/* A double's exact value as decimal digits: 0.d1 d2 ... dn × 10^point, no trailing zeros; count 0 for zero. */
struct decimal {
    char digits[MOST_DIGITS];
    int count;
    int point;
};

/* Multiply a big integer of limbs of 10^9 by a factor below 2^32: its new length. */
static int multiply(uint32_t *limbs, int length, uint32_t factor) {
    uint64_t carry = 0;
    for (int i = 0; i < length; i++) {
        uint64_t product = (uint64_t)limbs[i] * factor + carry;
        limbs[i] = (uint32_t)(product % 1000000000u);
        carry = product / 1000000000u;
    }
    while (carry != 0 && length < LIMBS) {
        limbs[length++] = (uint32_t)(carry % 1000000000u);
        carry /= 1000000000u;
    }
    return length;
}

/* Work out a finite, positive double's exact decimal value. */
static void exact_decimal(double x, struct decimal *out) {
    uint64_t bits;
    memcpy(&bits, &x, sizeof bits);
    int field = (int)((bits >> 52) & 0x7ff);
    uint64_t mantissa = bits & ((UINT64_C(1) << 52) - 1);
    int exponent;
    if (field == 0) {
        exponent = -1074;
    } else {
        mantissa |= UINT64_C(1) << 52;
        exponent = field - 1075;
    }
    out->count = 0;
    out->point = 0;
    if (mantissa == 0) {
        return;
    }
    while ((mantissa & 1) == 0 && exponent < 0) {
        mantissa >>= 1;
        exponent++;
    }
    uint32_t limbs[LIMBS];
    int length = 0;
    while (mantissa != 0) {
        limbs[length++] = (uint32_t)(mantissa % 1000000000u);
        mantissa /= 1000000000u;
    }
    int fraction_digits = 0;
    if (exponent > 0) {
        for (int left = exponent; left > 0; left -= 28) {
            length = multiply(limbs, length, UINT32_C(1) << (left < 28 ? left : 28));
        }
    } else {
        /* m / 2^k is m × 5^k / 10^k */
        fraction_digits = -exponent;
        for (int left = fraction_digits; left > 0; left -= 12) {
            uint32_t factor = 1;
            for (int i = 0; i < (left < 12 ? left : 12); i++) {
                factor *= 5;
            }
            length = multiply(limbs, length, factor);
        }
    }
    char text[LIMBS * 9 + 1];
    int count = snprintf(text, sizeof text, "%u", limbs[length - 1]);
    for (int i = length - 2; i >= 0; i--) {
        count += snprintf(text + count, sizeof text - (size_t)count, "%09u", limbs[i]);
    }
    while (count > 0 && text[count - 1] == '0') {
        count--;
        fraction_digits--;
    }
    int kept = count < MOST_DIGITS ? count : MOST_DIGITS;
    memcpy(out->digits, text, (size_t)kept);
    out->count = kept;
    /* text × 10^-fraction_digits is 0.text × 10^(count - fraction_digits); dropping a zero took one from each */
    out->point = count - fraction_digits;
}

/* A decimal's i'th digit, '0' past its end. */
static char digit_at(const struct decimal *value, int i) {
    return i >= 0 && i < value->count ? value->digits[i] : '0';
}

/* Round a decimal to its first keep digits, halfway to even; keep may be 0 or below, which round to 0 or 1 unit. */
static void round_to(struct decimal *value, int keep) {
    if (keep >= value->count) {
        return;
    }
    if (keep < 0) {
        value->count = 0;
        return;
    }
    char next = value->digits[keep];
    int beyond = 0;
    for (int i = keep + 1; i < value->count; i++) {
        beyond |= value->digits[i] != '0';
    }
    int odd = keep > 0 && ((value->digits[keep - 1] - '0') & 1);
    int up = next > '5' || (next == '5' && (beyond || odd));
    value->count = keep;
    if (up) {
        int i = keep - 1;
        while (i >= 0 && value->digits[i] == '9') {
            i--;
        }
        if (i < 0) {
            value->digits[0] = '1';
            value->count = 1;
            value->point++;
        } else {
            value->digits[i]++;
            value->count = i + 1;
        }
    }
    while (value->count > 0 && value->digits[value->count - 1] == '0') {
        value->count--;
    }
}

/* The most bytes a float's body takes: 309 digits before the point and 1000 after, with room. */
#define FLOAT_TEXT 1400
#define MOST_PRECISION 1000

/* Write a decimal as %f does, with precision digits after the point: its length. */
static size_t fixed_text(struct decimal *value, int precision, int alternate, char *text) {
    round_to(value, value->point + precision);
    size_t at = 0;
    if (value->count == 0 || value->point <= 0) {
        text[at++] = '0';
    } else {
        for (int i = 0; i < value->point; i++) {
            text[at++] = digit_at(value, i);
        }
    }
    if (precision > 0 || alternate) {
        text[at++] = '.';
    }
    for (int i = 0; i < precision; i++) {
        text[at++] = value->count == 0 ? '0' : digit_at(value, value->point + i);
    }
    return at;
}

/* Write a decimal as %e does, with precision digits after the point: its length. */
static size_t exponent_text(struct decimal *value, int precision, int alternate, int upper, char *text) {
    round_to(value, precision + 1);
    int exponent = value->count == 0 ? 0 : value->point - 1;
    size_t at = 0;
    text[at++] = value->count == 0 ? '0' : digit_at(value, 0);
    if (precision > 0 || alternate) {
        text[at++] = '.';
    }
    for (int i = 1; i <= precision; i++) {
        text[at++] = value->count == 0 ? '0' : digit_at(value, i);
    }
    at += (size_t)snprintf(text + at, 16, "%c%c%02d", upper ? 'E' : 'e', exponent < 0 ? '-' : '+',
                           exponent < 0 ? -exponent : exponent);
    return at;
}

/* Take the zeros off the end of a %g's fraction, and its point if nothing's left after it. */
static size_t without_trailing_zeros(char *text, size_t length) {
    char *point = memchr(text, '.', length);
    if (point == NULL) {
        return length;
    }
    char *exponent = NULL;
    for (size_t i = 0; i < length; i++) {
        if (text[i] == 'e' || text[i] == 'E') {
            exponent = text + i;
            break;
        }
    }
    size_t end = exponent != NULL ? (size_t)(exponent - text) : length;
    size_t kept = end;
    while (kept > (size_t)(point - text) + 1 && text[kept - 1] == '0') {
        kept--;
    }
    if (kept == (size_t)(point - text) + 1) {
        kept--;
    }
    memmove(text + kept, text + end, length - end);
    return kept + (length - end);
}

/* Write a double as %a does: hexadecimal, with precision hex digits, or as many as it needs with -1. */
static size_t hex_text(double x, int precision, int upper, char *text) {
    uint64_t bits;
    memcpy(&bits, &x, sizeof bits);
    int field = (int)((bits >> 52) & 0x7ff);
    uint64_t mantissa = bits & ((UINT64_C(1) << 52) - 1);
    int lead = field != 0;
    int exponent = field == 0 ? (mantissa == 0 ? 0 : -1022) : field - 1023;
    if (precision >= 0 && precision < 13) {
        int dropped = 4 * (13 - precision);
        uint64_t half = UINT64_C(1) << (dropped - 1);
        uint64_t rest = mantissa & ((UINT64_C(1) << dropped) - 1);
        mantissa >>= dropped;
        if (rest > half || (rest == half && (mantissa & 1))) {
            mantissa++;
            if (mantissa >> (4 * precision) != 0) {
                /* Carried into the leading digit */
                mantissa &= (UINT64_C(1) << (4 * precision)) - 1;
                lead++;
            }
        }
        mantissa <<= dropped;
    }
    const char *digits = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    size_t at = 0;
    text[at++] = '0';
    text[at++] = upper ? 'X' : 'x';
    text[at++] = digits[lead];
    int shown = precision;
    if (shown < 0) {
        shown = 13;
        while (shown > 0 && ((mantissa >> (4 * (13 - shown))) & 0xf) == 0) {
            shown--;
        }
    }
    if (shown > 0) {
        text[at++] = '.';
    }
    for (int i = 0; i < shown; i++) {
        text[at++] = i < 13 ? digits[(mantissa >> (48 - 4 * i)) & 0xf] : '0';
    }
    at += (size_t)snprintf(text + at, 16, "%c%+d", upper ? 'P' : 'p', exponent);
    return at;
}

/* Put a double out by its conversion: f F e E g G a A. */
static void put_float(struct output *out, double x, char conversion, int flags, int width, int precision) {
    char text[FLOAT_TEXT];
    int upper = conversion == 'F' || conversion == 'E' || conversion == 'G' || conversion == 'A';
    int negative = __builtin_signbit(x) != 0;
    const char *prefix = negative ? "-" : (flags & PLUS) ? "+" : (flags & SPACE) ? " " : "";
    double magnitude = negative ? -x : x;
    if (__builtin_isnan(x) || __builtin_isinf(x)) {
        const char *word = __builtin_isnan(x) ? (upper ? "NAN" : "nan") : (upper ? "INF" : "inf");
        put_padded(out, prefix, 0, word, 3, width, flags & ~ZERO);
        return;
    }
    if (precision > MOST_PRECISION) {
        precision = MOST_PRECISION;
    }
    size_t length;
    if (conversion == 'a' || conversion == 'A') {
        length = hex_text(magnitude, precision, upper, text);
    } else {
        struct decimal value;
        exact_decimal(magnitude, &value);
        if (precision < 0) {
            precision = 6;
        }
        if (conversion == 'f' || conversion == 'F') {
            length = fixed_text(&value, precision, flags & ALTERNATE, text);
        } else if (conversion == 'e' || conversion == 'E') {
            length = exponent_text(&value, precision, flags & ALTERNATE, upper, text);
        } else {
            /* %g: %e's exponent once rounded to precision digits picks %f or %e */
            int significant = precision == 0 ? 1 : precision;
            struct decimal rounded = value;
            round_to(&rounded, significant);
            int exponent = rounded.count == 0 ? 0 : rounded.point - 1;
            if (exponent < significant && exponent >= -4) {
                length = fixed_text(&value, significant - 1 - exponent, flags & ALTERNATE, text);
            } else {
                length = exponent_text(&value, significant - 1, flags & ALTERNATE, upper, text);
            }
            if (!(flags & ALTERNATE)) {
                length = without_trailing_zeros(text, length);
            }
        }
    }
    put_padded(out, prefix, 0, text, length, width, flags);
}

/* The lengths an integer conversion can have. */
enum length { PLAIN, CHAR_LENGTH, SHORT_LENGTH, LONG_LENGTH, LONG_LONG_LENGTH, MAX_LENGTH, SIZE_LENGTH, DIFFERENCE_LENGTH };

/* Format into out, as vfprintf does: how many bytes it made. */
static int format(struct output *out, const char *pattern, va_list arguments) {
    for (const char *at = pattern; *at != '\0'; at++) {
        if (*at != '%') {
            const char *start = at;
            while (at[1] != '\0' && at[1] != '%') {
                at++;
            }
            put(out, start, (size_t)(at - start + 1));
            continue;
        }
        const char *directive = at++;
        int flags = 0;
        for (;; at++) {
            if (*at == '-') {
                flags |= LEFT;
            } else if (*at == '+') {
                flags |= PLUS;
            } else if (*at == ' ') {
                flags |= SPACE;
            } else if (*at == '#') {
                flags |= ALTERNATE;
            } else if (*at == '0') {
                flags |= ZERO;
            } else {
                break;
            }
        }
        int width = 0;
        if (*at == '*') {
            width = va_arg(arguments, int);
            if (width < 0) {
                flags |= LEFT;
                width = -width;
            }
            at++;
        } else {
            while (*at >= '0' && *at <= '9') {
                width = width * 10 + (*at++ - '0');
            }
        }
        int precision = -1;
        if (*at == '.') {
            at++;
            precision = 0;
            if (*at == '*') {
                precision = va_arg(arguments, int);
                if (precision < 0) {
                    precision = -1;
                }
                at++;
            } else {
                while (*at >= '0' && *at <= '9') {
                    precision = precision * 10 + (*at++ - '0');
                }
            }
        }
        enum length length = PLAIN;
        switch (*at) {
        case 'h':
            length = at[1] == 'h' ? CHAR_LENGTH : SHORT_LENGTH;
            at += at[1] == 'h' ? 2 : 1;
            break;
        case 'l':
            length = at[1] == 'l' ? LONG_LONG_LENGTH : LONG_LENGTH;
            at += at[1] == 'l' ? 2 : 1;
            break;
        case 'j':
            length = MAX_LENGTH;
            at++;
            break;
        case 'z':
            length = SIZE_LENGTH;
            at++;
            break;
        case 't':
            length = DIFFERENCE_LENGTH;
            at++;
            break;
        case 'L':
            at++;
            break;
        default:
            break;
        }
        char conversion = *at;
        switch (conversion) {
        case 'd':
        case 'i': {
            intmax_t value;
            switch (length) {
            case CHAR_LENGTH:
                value = (signed char)va_arg(arguments, int);
                break;
            case SHORT_LENGTH:
                value = (short)va_arg(arguments, int);
                break;
            case LONG_LENGTH:
                value = va_arg(arguments, long);
                break;
            case LONG_LONG_LENGTH:
                value = va_arg(arguments, long long);
                break;
            case MAX_LENGTH:
                value = va_arg(arguments, intmax_t);
                break;
            case SIZE_LENGTH:
            case DIFFERENCE_LENGTH:
                value = va_arg(arguments, ptrdiff_t);
                break;
            default:
                value = va_arg(arguments, int);
                break;
            }
            uintmax_t magnitude = value < 0 ? -(uintmax_t)value : (uintmax_t)value;
            put_integer(out, magnitude, value < 0, conversion, flags, width, precision);
            break;
        }
        case 'u':
        case 'o':
        case 'x':
        case 'X': {
            uintmax_t value;
            switch (length) {
            case CHAR_LENGTH:
                value = (unsigned char)va_arg(arguments, unsigned);
                break;
            case SHORT_LENGTH:
                value = (unsigned short)va_arg(arguments, unsigned);
                break;
            case LONG_LENGTH:
                value = va_arg(arguments, unsigned long);
                break;
            case LONG_LONG_LENGTH:
                value = va_arg(arguments, unsigned long long);
                break;
            case MAX_LENGTH:
                value = va_arg(arguments, uintmax_t);
                break;
            case SIZE_LENGTH:
            case DIFFERENCE_LENGTH:
                value = va_arg(arguments, size_t);
                break;
            default:
                value = va_arg(arguments, unsigned);
                break;
            }
            put_integer(out, value, 0, conversion, flags, width, precision);
            break;
        }
        case 'p': {
            void *pointer = va_arg(arguments, void *);
            if (pointer == NULL) {
                put_padded(out, "", 0, "(nil)", 5, width, flags & ~ZERO);
            } else {
                put_integer(out, (uintptr_t)pointer, 0, 'p', flags, width, precision);
            }
            break;
        }
        case 'c': {
            char byte = (char)va_arg(arguments, int);
            put_padded(out, "", 0, &byte, 1, width, flags & ~ZERO);
            break;
        }
        case 's': {
            const char *text = va_arg(arguments, const char *);
            if (text == NULL) {
                text = "(null)";
            }
            size_t count = precision >= 0 ? strnlen(text, (size_t)precision) : strlen(text);
            put_padded(out, "", 0, text, count, width, flags & ~ZERO);
            break;
        }
        case 'f':
        case 'F':
        case 'e':
        case 'E':
        case 'g':
        case 'G':
        case 'a':
        case 'A':
            put_float(out, va_arg(arguments, double), conversion, flags, width, precision);
            break;
        case 'n': {
            void *place = va_arg(arguments, void *);
            switch (length) {
            case CHAR_LENGTH:
                *(signed char *)place = (signed char)out->count;
                break;
            case SHORT_LENGTH:
                *(short *)place = (short)out->count;
                break;
            case LONG_LENGTH:
            case LONG_LONG_LENGTH:
            case MAX_LENGTH:
            case SIZE_LENGTH:
            case DIFFERENCE_LENGTH:
                *(long *)place = (long)out->count;
                break;
            default:
                *(int *)place = (int)out->count;
                break;
            }
            break;
        }
        case '%':
            put(out, "%", 1);
            break;
        default:
            /* Not a conversion: written as it is, up to where it stopped */
            put(out, directive, (size_t)(at - directive) + (*at != '\0'));
            if (*at == '\0') {
                at--;
            }
            break;
        }
    }
    if (out->stream != NULL) {
        unstage(out);
    }
    if (out->failed) {
        return -1;
    }
    return out->count > INT_MAX ? INT_MAX : (int)out->count;
}

int vfprintf(FILE *stream, const char *pattern, va_list arguments) {
    struct output out = {stream, NULL, 0, 0, 0};
    return format(&out, pattern, arguments);
}

int vprintf(const char *pattern, va_list arguments) {
    return vfprintf(stdout, pattern, arguments);
}

int vsnprintf(char *into, size_t size, const char *pattern, va_list arguments) {
    struct output out = {NULL, into, size, 0, 0};
    int count = format(&out, pattern, arguments);
    if (size > 0) {
        into[out.count < size ? out.count : size - 1] = '\0';
    }
    return count;
}

int vsprintf(char *into, const char *pattern, va_list arguments) {
    return vsnprintf(into, SIZE_MAX, pattern, arguments);
}

int printf(const char *pattern, ...) {
    va_list arguments;
    va_start(arguments, pattern);
    int count = vfprintf(stdout, pattern, arguments);
    va_end(arguments);
    return count;
}

int fprintf(FILE *stream, const char *pattern, ...) {
    va_list arguments;
    va_start(arguments, pattern);
    int count = vfprintf(stream, pattern, arguments);
    va_end(arguments);
    return count;
}

int sprintf(char *into, const char *pattern, ...) {
    va_list arguments;
    va_start(arguments, pattern);
    int count = vsnprintf(into, SIZE_MAX, pattern, arguments);
    va_end(arguments);
    return count;
}

int snprintf(char *into, size_t size, const char *pattern, ...) {
    va_list arguments;
    va_start(arguments, pattern);
    int count = vsnprintf(into, size, pattern, arguments);
    va_end(arguments);
    return count;
}

/* Whether a byte is C's white space. */
static int is_space(char byte) {
    return byte == ' ' || (byte >= '\t' && byte <= '\r');
}

/* Store a scanned integer where its length says. */
static void store_integer(void *place, enum length length, uintmax_t value) {
    switch (length) {
    case CHAR_LENGTH:
        *(char *)place = (char)value;
        break;
    case SHORT_LENGTH:
        *(short *)place = (short)value;
        break;
    case LONG_LENGTH:
    case LONG_LONG_LENGTH:
    case MAX_LENGTH:
    case SIZE_LENGTH:
    case DIFFERENCE_LENGTH:
        *(long *)place = (long)value;
        break;
    default:
        *(int *)place = (int)value;
        break;
    }
}

/*
 * Read values from text as C's sscanf: d i u o x X p, the floats, s c [ n and %, with * to skip and a width, and the
 * lengths hh h l ll j z t (and L, for double, as printf takes it). How many were stored, or EOF if the text ended
 * before the first.
 */
int vsscanf(const char *text, const char *pattern, va_list arguments) {
    const char *in = text;
    int stored = 0;
    for (const char *at = pattern; *at != '\0'; at++) {
        if (is_space(*at)) {
            while (is_space(*in)) {
                in++;
            }
            continue;
        }
        if (*at != '%' || at[1] == '%') {
            if (*at == '%') {
                at++;
                while (is_space(*in)) {
                    in++;
                }
            }
            if (*in != *at) {
                return stored == 0 && *in == '\0' ? EOF : stored;
            }
            in++;
            continue;
        }
        at++;
        int skip = *at == '*';
        if (skip) {
            at++;
        }
        int width = 0;
        while (*at >= '0' && *at <= '9') {
            width = width * 10 + (*at++ - '0');
        }
        enum length length = PLAIN;
        if (*at == 'h') {
            length = at[1] == 'h' ? CHAR_LENGTH : SHORT_LENGTH;
            at += at[1] == 'h' ? 2 : 1;
        } else if (*at == 'l') {
            length = at[1] == 'l' ? LONG_LONG_LENGTH : LONG_LENGTH;
            at += at[1] == 'l' ? 2 : 1;
        } else if (*at == 'j' || *at == 'z' || *at == 't') {
            length = *at == 'j' ? MAX_LENGTH : *at == 'z' ? SIZE_LENGTH : DIFFERENCE_LENGTH;
            at++;
        } else if (*at == 'L') {
            at++;
        }
        char conversion = *at;
        if (conversion == '\0') {
            break;
        }
        if (conversion == 'n') {
            if (!skip) {
                store_integer(va_arg(arguments, void *), length, (uintmax_t)(in - text));
            }
            continue;
        }
        if (conversion != 'c' && conversion != '[') {
            while (is_space(*in)) {
                in++;
            }
        }
        if (*in == '\0') {
            return stored == 0 ? EOF : stored;
        }
        if (conversion == 'c') {
            int count = width == 0 ? 1 : width;
            char *into = skip ? NULL : va_arg(arguments, char *);
            for (int i = 0; i < count; i++) {
                if (in[i] == '\0') {
                    return stored;
                }
                if (into != NULL) {
                    into[i] = in[i];
                }
            }
            in += count;
            stored += !skip;
            continue;
        }
        if (conversion == 's' || conversion == '[') {
            char set[256] = {0};
            int inverted = 0;
            if (conversion == '[') {
                at++;
                if (*at == '^') {
                    inverted = 1;
                    at++;
                }
                /* A ] first is in the set */
                if (*at == ']') {
                    set[(unsigned char)']'] = 1;
                    at++;
                }
                while (*at != '\0' && *at != ']') {
                    if (at[1] == '-' && at[2] != ']' && at[2] != '\0') {
                        for (int c = (unsigned char)at[0]; c <= (unsigned char)at[2]; c++) {
                            set[c] = 1;
                        }
                        at += 3;
                    } else {
                        set[(unsigned char)*at++] = 1;
                    }
                }
                if (*at == '\0') {
                    return stored;
                }
            }
            char *into = skip ? NULL : va_arg(arguments, char *);
            int count = 0;
            while (in[count] != '\0' && (width == 0 || count < width)) {
                unsigned char byte = (unsigned char)in[count];
                int taken = conversion == 's' ? !is_space((char)byte) : (set[byte] != 0) != inverted;
                if (!taken) {
                    break;
                }
                if (into != NULL) {
                    into[count] = (char)byte;
                }
                count++;
            }
            if (count == 0) {
                return stored;
            }
            if (into != NULL) {
                into[count] = '\0';
            }
            in += count;
            stored += !skip;
            continue;
        }
        /* A number: as much of it as the width allows, read by strtoll, strtoull or strtod */
        char number[64];
        int most = width == 0 || width > (int)sizeof number - 1 ? (int)sizeof number - 1 : width;
        int count = 0;
        while (count < most && in[count] != '\0') {
            number[count] = in[count];
            count++;
        }
        number[count] = '\0';
        char *end = number;
        if (conversion == 'f' || conversion == 'e' || conversion == 'g' || conversion == 'a' || conversion == 'E' ||
            conversion == 'G' || conversion == 'F' || conversion == 'A') {
            double value = strtod(number, &end);
            if (end == number) {
                return stored;
            }
            if (!skip) {
                if (length == LONG_LENGTH || length == LONG_LONG_LENGTH) {
                    *va_arg(arguments, double *) = value;
                } else {
                    *va_arg(arguments, float *) = (float)value;
                }
            }
        } else {
            int base = conversion == 'd' || conversion == 'u' ? 10
                       : conversion == 'i'                     ? 0
                       : conversion == 'o'                     ? 8
                       : conversion == 'x' || conversion == 'X' || conversion == 'p' ? 16
                                                                                     : -1;
            if (base < 0) {
                return stored;
            }
            uintmax_t value = conversion == 'd' || conversion == 'i' ? (uintmax_t)strtoll(number, &end, base)
                                                                      : strtoull(number, &end, base);
            if (end == number) {
                return stored;
            }
            if (!skip) {
                if (conversion == 'p') {
                    *va_arg(arguments, void **) = (void *)(uintptr_t)value;
                } else {
                    store_integer(va_arg(arguments, void *), length, value);
                }
            }
        }
        in += end - number;
        stored += !skip;
    }
    return stored;
}

int sscanf(const char *text, const char *pattern, ...) {
    va_list arguments;
    va_start(arguments, pattern);
    int stored = vsscanf(text, pattern, arguments);
    va_end(arguments);
    return stored;
}
