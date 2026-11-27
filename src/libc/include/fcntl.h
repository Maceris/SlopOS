/*
 * fcntl.h, SlopOS's libc (decisions/0201, 20l): open's flags, with Linux's values. Paths are beneath the program's
 * working directory (its "here", or its working_directory grant): "/" is that directory itself, and ".." can't leave
 * it. SlopOS's files have no permissions, so open's mode is taken and not used; O_CLOEXEC and O_NONBLOCK change
 * nothing, as there's no exec and files never block.
 */
#ifndef _FCNTL_H
#define _FCNTL_H

#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

#define O_RDONLY 00
#define O_WRONLY 01
#define O_RDWR 02
#define O_ACCMODE 03
#define O_CREAT 0100
#define O_EXCL 0200
#define O_NOCTTY 0400
#define O_TRUNC 01000
#define O_APPEND 02000
#define O_NONBLOCK 04000
#define O_DIRECTORY 0200000
#define O_CLOEXEC 02000000
#define O_BINARY 0

/* fcntl's commands, Linux's values: F_GETFD and F_SETFD keep FD_CLOEXEC, which changes nothing, as there's no exec */
#define F_DUPFD 0
#define F_GETFD 1
#define F_SETFD 2
#define F_GETFL 3
#define F_SETFL 4
#define FD_CLOEXEC 1

int open(const char *path, int flags, ...);
/*
 * Ask about or change a descriptor: F_GETFD and F_SETFD its FD_CLOEXEC, F_GETFL its access mode and O_APPEND
 * (O_NONBLOCK, which F_SETFL takes and drops, never), and F_SETFL its O_APPEND. -1, errno EBADF for one that isn't
 * open, or EINVAL for another command, F_DUPFD's among them.
 */
int fcntl(int fd, int command, ...);
int creat(const char *path, mode_t mode);

#ifdef __cplusplus
}
#endif

#endif
