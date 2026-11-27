/*
 * time.c, SlopOS's libc (decisions/0201, 20l): broken-down times over the Hemera's calendar (times.hsc), UTC being
 * local time as SlopOS gives a program no zone, and strftime's formatting, in the C locale's English names.
 */
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

/* The Hemera's: the first nine fields of a struct tm for a moment, 0 or -1; and the moment of those fields. */
int slopos_libc_break_down(time_t moment, struct tm *into);
time_t slopos_libc_put_together(const struct tm *from);

/* What gmtime, localtime and asctime give, overwritten by the next call, as C allows. */
static struct tm broken_down;
static char ascii_time[32];

struct tm *gmtime_r(const time_t *moment, struct tm *into) {
    if (slopos_libc_break_down(*moment, into) != 0) {
        return NULL;
    }
    into->tm_gmtoff = 0;
    into->tm_zone = "UTC";
    return into;
}

struct tm *gmtime(const time_t *moment) {
    return gmtime_r(moment, &broken_down);
}

struct tm *localtime_r(const time_t *moment, struct tm *into) {
    return gmtime_r(moment, into);
}

struct tm *localtime(const time_t *moment) {
    return gmtime_r(moment, &broken_down);
}

time_t timegm(struct tm *moment) {
    time_t made = slopos_libc_put_together(moment);
    /* Every field brought back into its range, the weekday and the day of the year worked out, as C asks */
    if (gmtime_r(&made, moment) == NULL) {
        return (time_t)-1;
    }
    return made;
}

time_t mktime(struct tm *moment) {
    return timegm(moment);
}

double difftime(time_t end, time_t start) {
    return (double)(end - start);
}

int timespec_get(struct timespec *now, int base) {
    if (base != TIME_UTC || clock_gettime(CLOCK_REALTIME, now) != 0) {
        return 0;
    }
    return base;
}

static const char *const DAYS[] = {"Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"};
static const char *const MONTHS[] = {"January", "February", "March",     "April",   "May",      "June",
                                     "July",    "August",   "September", "October", "November", "December"};

/* A day's or month's name, or "?" for a number out of range. */
static const char *name_of(const char *const *names, int count, int index) {
    return index >= 0 && index < count ? names[index] : "?";
}

/* What strftime writes into, and how far it's got; full once it's run out of room. */
struct written {
    char *into;
    size_t size;
    size_t at;
    int full;
};

/* Add text, or note that it didn't fit, keeping room for the 0 byte. */
static void add_text(struct written *out, const char *text, size_t count) {
    if (out->at + count >= out->size) {
        out->full = 1;
        return;
    }
    memcpy(out->into + out->at, text, count);
    out->at += count;
}

/* Add a number, zero-padded to width digits. */
static void add_number(struct written *out, long value, int width) {
    char digits[24];
    int count = snprintf(digits, sizeof digits, "%0*ld", width, value);
    add_text(out, digits, (size_t)count);
}

/* The ISO 8601 week number of a broken-down time, 1 to 53, for %V, and its year, for %G. */
static int iso_week(const struct tm *moment, int *year) {
    int weekday = (moment->tm_wday + 6) % 7;
    int week = (moment->tm_yday - weekday + 10) / 7;
    *year = moment->tm_year + 1900;
    if (week < 1) {
        int before = *year - 1;
        int days = 365 + ((before % 4 == 0 && before % 100 != 0) || before % 400 == 0);
        week = (moment->tm_yday + days - weekday + 10) / 7;
        *year = before;
    } else {
        int days = 365 + ((*year % 4 == 0 && *year % 100 != 0) || *year % 400 == 0);
        if (moment->tm_yday - weekday + 3 >= days) {
            week = 1;
            *year += 1;
        }
    }
    return week;
}

size_t strftime(char *into, size_t size, const char *format, const struct tm *moment) {
    struct written out = {into, size, 0, 0};
    if (size == 0) {
        return 0;
    }
    for (const char *at = format; *at != '\0' && !out.full; at++) {
        if (*at != '%') {
            add_text(&out, at, 1);
            continue;
        }
        /* Where the conversion starts, its %, so one C hasn't is written whole, an E or O modifier with it */
        const char *directive = at;
        at++;
        /* C99's E and O modifiers change nothing in the C locale */
        if (*at == 'E' || *at == 'O') {
            at++;
        }
        int hour12 = moment->tm_hour % 12 == 0 ? 12 : moment->tm_hour % 12;
        const char *text = NULL;
        char made[64];
        switch (*at) {
        case 'a':
            add_text(&out, name_of(DAYS, 7, moment->tm_wday), strnlen(name_of(DAYS, 7, moment->tm_wday), 3));
            break;
        case 'A':
            text = name_of(DAYS, 7, moment->tm_wday);
            break;
        case 'b':
        case 'h':
            add_text(&out, name_of(MONTHS, 12, moment->tm_mon), strnlen(name_of(MONTHS, 12, moment->tm_mon), 3));
            break;
        case 'B':
            text = name_of(MONTHS, 12, moment->tm_mon);
            break;
        case 'c':
            strftime(made, sizeof made, "%a %b %e %H:%M:%S %Y", moment);
            text = made;
            break;
        case 'C':
            add_number(&out, (moment->tm_year + 1900) / 100, 2);
            break;
        case 'd':
            add_number(&out, moment->tm_mday, 2);
            break;
        case 'D':
            strftime(made, sizeof made, "%m/%d/%y", moment);
            text = made;
            break;
        case 'e':
            snprintf(made, sizeof made, "%2d", moment->tm_mday);
            text = made;
            break;
        case 'F':
            strftime(made, sizeof made, "%Y-%m-%d", moment);
            text = made;
            break;
        case 'g':
        case 'G': {
            int year;
            iso_week(moment, &year);
            if (*at == 'g') {
                add_number(&out, year % 100, 2);
            } else {
                add_number(&out, year, 4);
            }
            break;
        }
        case 'H':
            add_number(&out, moment->tm_hour, 2);
            break;
        case 'I':
            add_number(&out, hour12, 2);
            break;
        case 'j':
            add_number(&out, moment->tm_yday + 1, 3);
            break;
        case 'm':
            add_number(&out, moment->tm_mon + 1, 2);
            break;
        case 'M':
            add_number(&out, moment->tm_min, 2);
            break;
        case 'n':
            text = "\n";
            break;
        case 'p':
            text = moment->tm_hour < 12 ? "AM" : "PM";
            break;
        case 'r':
            strftime(made, sizeof made, "%I:%M:%S %p", moment);
            text = made;
            break;
        case 'R':
            strftime(made, sizeof made, "%H:%M", moment);
            text = made;
            break;
        case 's': {
            struct tm copy = *moment;
            snprintf(made, sizeof made, "%lld", (long long)timegm(&copy));
            text = made;
            break;
        }
        case 'S':
            add_number(&out, moment->tm_sec, 2);
            break;
        case 't':
            text = "\t";
            break;
        case 'T':
            strftime(made, sizeof made, "%H:%M:%S", moment);
            text = made;
            break;
        case 'u':
            add_number(&out, moment->tm_wday == 0 ? 7 : moment->tm_wday, 1);
            break;
        case 'U':
            add_number(&out, (moment->tm_yday + 7 - moment->tm_wday) / 7, 2);
            break;
        case 'V': {
            int year;
            add_number(&out, iso_week(moment, &year), 2);
            break;
        }
        case 'w':
            add_number(&out, moment->tm_wday, 1);
            break;
        case 'W':
            add_number(&out, (moment->tm_yday + 7 - (moment->tm_wday + 6) % 7) / 7, 2);
            break;
        case 'x':
            strftime(made, sizeof made, "%m/%d/%y", moment);
            text = made;
            break;
        case 'X':
            strftime(made, sizeof made, "%H:%M:%S", moment);
            text = made;
            break;
        case 'y':
            add_number(&out, (moment->tm_year + 1900) % 100, 2);
            break;
        case 'Y':
            add_number(&out, moment->tm_year + 1900L, 1);
            break;
        case 'z':
            text = "+0000";
            break;
        case 'Z':
            text = "UTC";
            break;
        case '%':
            text = "%";
            break;
        case '\0':
            /* A % at the end, or a modifier: written as it is */
            add_text(&out, directive, (size_t)(at - directive));
            at--;
            break;
        default:
            /* Not one C has: written as it is, from its % */
            add_text(&out, directive, (size_t)(at - directive) + 1);
            break;
        }
        if (text != NULL) {
            add_text(&out, text, strlen(text));
        }
    }
    if (out.full) {
        into[0] = '\0';
        return 0;
    }
    into[out.at] = '\0';
    return out.at;
}

char *asctime(const struct tm *moment) {
    snprintf(ascii_time, sizeof ascii_time, "%.3s %.3s%3d %.2d:%.2d:%.2d %d\n", name_of(DAYS, 7, moment->tm_wday),
             name_of(MONTHS, 12, moment->tm_mon), moment->tm_mday, moment->tm_hour, moment->tm_min, moment->tm_sec,
             moment->tm_year + 1900);
    return ascii_time;
}

char *ctime(const time_t *moment) {
    struct tm *broken = localtime(moment);
    return broken == NULL ? NULL : asctime(broken);
}
