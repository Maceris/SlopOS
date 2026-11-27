/*
 * start.c, SlopOS's libc (decisions/0201, 20l): C's start and end. __libc_start, which the libc's Hemera run calls,
 * calls main, then what atexit registered, last first, then flushes every stream; exit does the same from anywhere,
 * then ends the program through the Hemera's slopos_libc_exit, which writes what stdout and stderr have of a line.
 * Also the environment (none on SlopOS), system (no shell to run), signals (none), and the C locale, the only one.
 */
#include <locale.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* The libc's Hemera: the program's end, after the last of stdout's and stderr's lines are written. */
__attribute__((noreturn)) void slopos_libc_exit(int code);

/* The most functions atexit takes: C's least. */
#define MOST_AT_EXIT 32

/* What atexit registered, in order, and how many. */
static void (*at_exit[MOST_AT_EXIT])(void);
static int at_exit_count;

/* Run what atexit registered, last first, each once, even if one of them calls exit. */
static void run_at_exit(void) {
    while (at_exit_count > 0) {
        void (*function)(void) = at_exit[--at_exit_count];
        function();
    }
}

int __libc_start(int argc, char **argv, int (*entry)(int, char **)) {
    int code = entry(argc, argv);
    run_at_exit();
    fflush(NULL);
    return code;
}

int atexit(void (*function)(void)) {
    if (at_exit_count >= MOST_AT_EXIT) {
        return -1;
    }
    at_exit[at_exit_count++] = function;
    return 0;
}

void exit(int code) {
    run_at_exit();
    fflush(NULL);
    slopos_libc_exit(code);
}

void _Exit(int code) {
    slopos_libc_exit(code);
}

void _exit(int code) {
    slopos_libc_exit(code);
}

/* Each signal's handler, which signal sets and raise and abort call. */
static sighandler_t handlers[NSIG];

/* abort's exit code: 128 and SIGABRT, as a shell reports a program that aborted, and as Hemera's assertions end. */
#define ABORT_CODE 134

/*
 * abort raises SIGABRT: a handler signal set is called, once, its own reset to SIG_DFL first, and may leave by
 * longjmp; one that returns, SIG_IGN or SIG_DFL ends the program with 134, its streams but stderr not flushed.
 */
void abort(void) {
    sighandler_t handler = handlers[SIGABRT];
    if (handler != SIG_DFL && handler != SIG_IGN) {
        handlers[SIGABRT] = SIG_DFL;
        handler(SIGABRT);
    }
    fflush(stderr);
    slopos_libc_exit(ABORT_CODE);
}

void __libc_assert_failed(const char *expression, const char *file, int line, const char *function) {
    fprintf(stderr, "%s:%d: %s: assertion failed: %s\n", file, line, function, expression);
    abort();
}

char *getenv(const char *name) {
    (void)name;
    return NULL;
}

int system(const char *command) {
    /* With NULL, C asks whether there's a shell to run commands: there isn't */
    if (command == NULL) {
        return 0;
    }
    return -1;
}

sighandler_t signal(int number, sighandler_t handler) {
    if (number <= 0 || number >= NSIG) {
        return SIG_ERR;
    }
    sighandler_t before = handlers[number];
    handlers[number] = handler;
    return before;
}

int raise(int number) {
    if (number <= 0 || number >= NSIG) {
        return -1;
    }
    sighandler_t handler = handlers[number];
    if (handler == SIG_IGN) {
        return 0;
    }
    if (handler == SIG_DFL) {
        fflush(NULL);
        slopos_libc_exit(128 + number);
    }
    handler(number);
    return 0;
}

/* The C locale's name. */
static char C_LOCALE[] = "C";

char *setlocale(int category, const char *name) {
    (void)category;
    if (name == NULL || name[0] == '\0' || strcmp(name, "C") == 0 || strcmp(name, "POSIX") == 0) {
        return C_LOCALE;
    }
    return NULL;
}

/* The C locale's conventions: a point, and nothing else; CHAR_MAX for what it doesn't say. */
static struct lconv C_CONVENTIONS = {
    ".", "", "", "", "", "", "", "", "", "", 127, 127, 127, 127, 127, 127, 127, 127,
};

struct lconv *localeconv(void) {
    return &C_CONVENTIONS;
}
