/*
 * sys/stat.h, SlopOS's libc (decisions/0201, 20l): what a path or a file descriptor is, and its size. SlopOS keeps no
 * permissions, owners or times for C to see, so st_mode is the kind with 0644 for a file and 0755 for a directory, and
 * the rest are 0.
 */
#ifndef _SYS_STAT_H
#define _SYS_STAT_H

#include <sys/types.h>
#include <time.h>

#ifdef __cplusplus
extern "C" {
#endif

#define S_IFMT 0170000
#define S_IFDIR 0040000
#define S_IFCHR 0020000
#define S_IFREG 0100000
#define S_IFLNK 0120000
#define S_ISDIR(mode) (((mode) & S_IFMT) == S_IFDIR)
#define S_ISREG(mode) (((mode) & S_IFMT) == S_IFREG)
#define S_ISCHR(mode) (((mode) & S_IFMT) == S_IFCHR)
#define S_ISLNK(mode) (((mode) & S_IFMT) == S_IFLNK)
#define S_IRWXU 0700
#define S_IRUSR 0400
#define S_IWUSR 0200
#define S_IXUSR 0100
#define S_IRWXG 070
#define S_IRGRP 040
#define S_IWGRP 020
#define S_IXGRP 010
#define S_IRWXO 07
#define S_IROTH 04
#define S_IWOTH 02
#define S_IXOTH 01

struct stat {
    dev_t st_dev;
    ino_t st_ino;
    mode_t st_mode;
    nlink_t st_nlink;
    uid_t st_uid;
    gid_t st_gid;
    off_t st_size;
    blksize_t st_blksize;
    blkcnt_t st_blocks;
    time_t st_atime;
    time_t st_mtime;
    time_t st_ctime;
};

int stat(const char *path, struct stat *into);
int fstat(int fd, struct stat *into);
int lstat(const char *path, struct stat *into);
int mkdir(const char *path, mode_t mode);

#ifdef __cplusplus
}
#endif

#endif
