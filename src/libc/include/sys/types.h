/*
 * sys/types.h, SlopOS's libc (decisions/0201, 20l): the POSIX types its headers use, each 64 bits wide where POSIX
 * lets it be, as SlopOS's files and clocks are.
 */
#ifndef _SYS_TYPES_H
#define _SYS_TYPES_H

#include <stddef.h>
#include <stdint.h>

/* A byte count or -1 for an error, as read and write give. */
typedef long ssize_t;
/* An offset in a file, in bytes. */
typedef int64_t off_t;
/* A file's kind and permission bits (sys/stat.h); SlopOS keeps no permissions, so only the kind is set. */
typedef unsigned int mode_t;
/* Seconds since 1970-01-01T00:00:00Z, leap seconds not counted. */
typedef int64_t time_t;
/* Processor time in CLOCKS_PER_SEC's units (time.h). */
typedef long clock_t;
/* A process's ID: SlopOS gives programs none, so getpid's is always 1. */
typedef int pid_t;
/* Users and groups, which SlopOS's files don't have; always 0. */
typedef unsigned int uid_t;
typedef unsigned int gid_t;
typedef unsigned long ino_t;
typedef unsigned long dev_t;
typedef unsigned long nlink_t;
typedef long blksize_t;
typedef long blkcnt_t;
/* Microseconds, for usleep. */
typedef unsigned int useconds_t;

#endif
