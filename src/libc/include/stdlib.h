/*
 * stdlib.h, SlopOS's libc (decisions/0201, 20l): memory from the program's Hemera heap (memory.hsc), numbers from text
 * (numbers.hsc), and in C (stdlib.c) sorting and searching, random numbers, and the program's end: exit flushes
 * every stream after running what atexit registered. There's no environment on SlopOS, so getenv always gives NULL,
 * and no shell to run, so system says there's none.
 */
#ifndef _STDLIB_H
#define _STDLIB_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define EXIT_SUCCESS 0
#define EXIT_FAILURE 1
#define RAND_MAX 0x7fffffff
/* Bytes in a character at most: only the C locale, whose characters are bytes. */
#define MB_CUR_MAX 1

typedef struct {
    int quot;
    int rem;
} div_t;
typedef struct {
    long quot;
    long rem;
} ldiv_t;
typedef struct {
    long long quot;
    long long rem;
} lldiv_t;

void *malloc(size_t size);
void *calloc(size_t count, size_t size);
void *realloc(void *block, size_t size);
void free(void *block);
void *aligned_alloc(size_t alignment, size_t size);
int posix_memalign(void **made, size_t alignment, size_t size);

int atoi(const char *text);
long atol(const char *text);
long long atoll(const char *text);
double atof(const char *text);
long strtol(const char *text, char **end, int base);
long long strtoll(const char *text, char **end, int base);
unsigned long strtoul(const char *text, char **end, int base);
unsigned long long strtoull(const char *text, char **end, int base);
double strtod(const char *text, char **end);
float strtof(const char *text, char **end);

int abs(int value);
long labs(long value);
long long llabs(long long value);
div_t div(int numerator, int denominator);
ldiv_t ldiv(long numerator, long denominator);
lldiv_t lldiv(long long numerator, long long denominator);

void qsort(void *items, size_t count, size_t size, int (*compare)(const void *, const void *));
void *bsearch(const void *key, const void *items, size_t count, size_t size, int (*compare)(const void *, const void *));

int rand(void);
void srand(unsigned int seed);

__attribute__((noreturn)) void exit(int code);
__attribute__((noreturn)) void _Exit(int code);
__attribute__((noreturn)) void abort(void);
int atexit(void (*function)(void));
char *getenv(const char *name);
int system(const char *command);

#ifdef __cplusplus
}
#endif

#endif
