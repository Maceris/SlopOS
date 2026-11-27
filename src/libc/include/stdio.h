/*
 * stdio.h, SlopOS's libc (decisions/0201, 20l): buffered streams over file descriptors (stdio.c), and the printf
 * family's formatting (format.c). stdin reads the program's terminal; stdout and stderr write to it, or, for a program
 * given none, to its debug log or its logger a line at a time. Paths are beneath the program's working directory, as
 * fcntl.h's open takes them.
 */
#ifndef _STDIO_H
#define _STDIO_H

#include <stdarg.h>
#include <stddef.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/* A stream: its file descriptor, buffer and state, which only stdio.c reaches into. */
typedef struct __libc_file FILE;
/* A place in a stream, for fgetpos and fsetpos: its offset in bytes from the start. */
typedef struct {
    off_t offset;
} fpos_t;

extern FILE *const stdin;
extern FILE *const stdout;
extern FILE *const stderr;
#define stdin stdin
#define stdout stdout
#define stderr stderr

#define EOF (-1)
/* Each stream's buffer, in bytes. */
#define BUFSIZ 4096
#define FILENAME_MAX 4096
#define FOPEN_MAX 64
#define L_tmpnam 32
#define TMP_MAX 10000
#define _IOFBF 0
#define _IOLBF 1
#define _IONBF 2
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2

FILE *fopen(const char *path, const char *mode);
FILE *freopen(const char *path, const char *mode, FILE *stream);
FILE *fdopen(int fd, const char *mode);
int fclose(FILE *stream);
int fflush(FILE *stream);
int setvbuf(FILE *stream, char *buffer, int mode, size_t size);
void setbuf(FILE *stream, char *buffer);
size_t fread(void *into, size_t size, size_t count, FILE *stream);
size_t fwrite(const void *from, size_t size, size_t count, FILE *stream);
int fgetc(FILE *stream);
int getc(FILE *stream);
int getchar(void);
int ungetc(int c, FILE *stream);
char *fgets(char *into, int size, FILE *stream);
int fputc(int c, FILE *stream);
int putc(int c, FILE *stream);
int putchar(int c);
int fputs(const char *text, FILE *stream);
int puts(const char *text);
int fseek(FILE *stream, long offset, int whence);
int fseeko(FILE *stream, off_t offset, int whence);
long ftell(FILE *stream);
off_t ftello(FILE *stream);
void rewind(FILE *stream);
int fgetpos(FILE *stream, fpos_t *place);
int fsetpos(FILE *stream, const fpos_t *place);
int feof(FILE *stream);
int ferror(FILE *stream);
void clearerr(FILE *stream);
int fileno(FILE *stream);
void perror(const char *what);
int remove(const char *path);
int rename(const char *from, const char *to);
/* Always NULL with errno ENOSYS: SlopOS has no place for temporary files that isn't a program's own directory. */
FILE *tmpfile(void);
/* Always NULL: as tmpfile. */
char *tmpnam(char *name);

int printf(const char *format, ...) __attribute__((format(printf, 1, 2)));
int fprintf(FILE *stream, const char *format, ...) __attribute__((format(printf, 2, 3)));
int sprintf(char *into, const char *format, ...) __attribute__((format(printf, 2, 3)));
int snprintf(char *into, size_t size, const char *format, ...) __attribute__((format(printf, 3, 4)));
int vprintf(const char *format, va_list arguments) __attribute__((format(printf, 1, 0)));
int vfprintf(FILE *stream, const char *format, va_list arguments) __attribute__((format(printf, 2, 0)));
int vsprintf(char *into, const char *format, va_list arguments) __attribute__((format(printf, 2, 0)));
int vsnprintf(char *into, size_t size, const char *format, va_list arguments) __attribute__((format(printf, 3, 0)));
int sscanf(const char *text, const char *format, ...) __attribute__((format(scanf, 2, 3)));
int vsscanf(const char *text, const char *format, va_list arguments) __attribute__((format(scanf, 2, 0)));

#ifdef __cplusplus
}
#endif

#endif
