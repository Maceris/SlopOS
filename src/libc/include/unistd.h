/*
 * unistd.h, SlopOS's libc (decisions/0201, 20l): file descriptors over the program's files (src/libc/files.hsc), 0 to
 * 2 its terminal or log as stdio.h says. There's no fork, exec or pipe, so those aren't here; getpid is always 1 and
 * the user always 0. The working directory is fixed, as SlopOS gives a program one: getcwd always gives "/".
 */
#ifndef _UNISTD_H
#define _UNISTD_H

#include <stddef.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

#define STDIN_FILENO 0
#define STDOUT_FILENO 1
#define STDERR_FILENO 2
#define F_OK 0
#define X_OK 1
#define W_OK 2
#define R_OK 4
#ifndef SEEK_SET
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2
#endif

ssize_t read(int fd, void *into, size_t count);
ssize_t write(int fd, const void *from, size_t count);
int close(int fd);
off_t lseek(int fd, off_t offset, int whence);
int ftruncate(int fd, off_t size);
int fsync(int fd);
int unlink(const char *path);
int rmdir(const char *path);
int access(const char *path, int mode);
int isatty(int fd);
char *getcwd(char *into, size_t size);
int chdir(const char *path);
pid_t getpid(void);
uid_t getuid(void);
uid_t geteuid(void);
__attribute__((noreturn)) void _exit(int code);

#ifdef __cplusplus
}
#endif

#endif
