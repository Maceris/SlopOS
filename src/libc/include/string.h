/*
 * string.h, SlopOS's libc (decisions/0201, 20l): byte and C string functions, written in Hemera (src/libc/strings.hsc)
 * but for strtok and strerror (c/errno.c). memcpy, memmove, memset and memcmp are the ones every Hemera program has
 * already, which its compiler defines.
 */
#ifndef _STRING_H
#define _STRING_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

void *memcpy(void *to, const void *from, size_t count);
void *memmove(void *to, const void *from, size_t count);
void *memset(void *to, int byte, size_t count);
int memcmp(const void *a, const void *b, size_t count);
void *memchr(const void *bytes, int byte, size_t count);
size_t strlen(const char *text);
size_t strnlen(const char *text, size_t most);
int strcmp(const char *a, const char *b);
int strncmp(const char *a, const char *b, size_t most);
/* As strcmp: SlopOS's C has only the C locale. */
int strcoll(const char *a, const char *b);
size_t strxfrm(char *to, const char *from, size_t size);
char *strcpy(char *to, const char *from);
char *strncpy(char *to, const char *from, size_t count);
char *strcat(char *to, const char *from);
char *strncat(char *to, const char *from, size_t most);
char *strchr(const char *text, int c);
char *strrchr(const char *text, int c);
char *strstr(const char *text, const char *part);
size_t strspn(const char *text, const char *accepted);
size_t strcspn(const char *text, const char *rejected);
char *strpbrk(const char *text, const char *wanted);
char *strtok(char *text, const char *separators);
char *strtok_r(char *text, const char *separators, char **saved);
char *strdup(const char *text);
char *strndup(const char *text, size_t most);
char *strerror(int number);
int strcasecmp(const char *a, const char *b);
int strncasecmp(const char *a, const char *b, size_t most);

#ifdef __cplusplus
}
#endif

#endif
