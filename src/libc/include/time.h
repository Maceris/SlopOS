/*
 * time.h, SlopOS's libc (decisions/0201, 20l): the wall clock and the monotonic one through the program's Hemera
 * context (src/libc/times.hsc), and dates on the proleptic Gregorian calendar. SlopOS gives a program no time zone, so
 * local time is UTC: localtime is gmtime, and mktime is timegm.
 */
#ifndef _TIME_H
#define _TIME_H

#include <stddef.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/* clock's units: microseconds. */
#define CLOCKS_PER_SEC 1000000L
#define CLOCK_REALTIME 0
#define CLOCK_MONOTONIC 1
#define CLOCK_PROCESS_CPUTIME_ID 2
#define TIME_UTC 1

typedef int clockid_t;

/* A broken-down time; the first nine are C's, then the offset from UTC and the zone's name, always 0 and "UTC". */
struct tm {
    int tm_sec;
    int tm_min;
    int tm_hour;
    int tm_mday;
    int tm_mon;
    int tm_year;
    int tm_wday;
    int tm_yday;
    int tm_isdst;
    long tm_gmtoff;
    const char *tm_zone;
};

struct timespec {
    time_t tv_sec;
    long tv_nsec;
};

time_t time(time_t *now);
clock_t clock(void);
double difftime(time_t end, time_t start);
int clock_gettime(clockid_t clock, struct timespec *now);
int timespec_get(struct timespec *now, int base);
struct tm *gmtime(const time_t *moment);
struct tm *gmtime_r(const time_t *moment, struct tm *into);
struct tm *localtime(const time_t *moment);
struct tm *localtime_r(const time_t *moment, struct tm *into);
time_t mktime(struct tm *moment);
time_t timegm(struct tm *moment);
size_t strftime(char *into, size_t size, const char *format, const struct tm *moment);
char *asctime(const struct tm *moment);
char *ctime(const time_t *moment);

#ifdef __cplusplus
}
#endif

#endif
