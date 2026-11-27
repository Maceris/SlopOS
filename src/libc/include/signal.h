/*
 * signal.h, SlopOS's libc (decisions/0201, 20l): SlopOS has no signals, so a handler set with signal is kept but never
 * called by the system; raise calls it, as C allows, or for SIGABRT with the default ends the program as abort does.
 */
#ifndef _SIGNAL_H
#define _SIGNAL_H

#ifdef __cplusplus
extern "C" {
#endif

typedef int sig_atomic_t;
typedef void (*sighandler_t)(int);

#define SIG_DFL ((sighandler_t)0)
#define SIG_IGN ((sighandler_t)1)
#define SIG_ERR ((sighandler_t)-1)
#define SIGINT 2
#define SIGILL 4
#define SIGABRT 6
#define SIGFPE 8
#define SIGSEGV 11
#define SIGPIPE 13
#define SIGTERM 15
/* One past the highest signal number. */
#define NSIG 32

sighandler_t signal(int number, sighandler_t handler);
int raise(int number);

#ifdef __cplusplus
}
#endif

#endif
