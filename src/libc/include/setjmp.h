/*
 * setjmp.h, SlopOS's libc (decisions/0201, 20l): non-local jumps (setjmp.c, assembly for each architecture), which keep
 * the callee-saved registers, the stack pointer, the return address and the shadow stack's pointer (x86-64's CET
 * shadow stack, AArch64's Guarded Control Stack, RISC-V's Zicfiss), so a longjmp back up the stack unwinds the shadow
 * stack too. There are no signals, so the sig and underscore forms are the same.
 */
#ifndef _SETJMP_H
#define _SETJMP_H

#ifdef __cplusplus
extern "C" {
#endif

/* The registers setjmp keeps: at most 32 words on any architecture, 16-byte aligned. */
typedef long jmp_buf[32] __attribute__((aligned(16)));
typedef jmp_buf sigjmp_buf;

__attribute__((returns_twice)) int setjmp(jmp_buf where);
__attribute__((noreturn)) void longjmp(jmp_buf where, int value);
#define _setjmp(where) setjmp(where)
#define _longjmp(where, value) longjmp(where, value)
#define sigsetjmp(where, save_mask) setjmp(where)
#define siglongjmp(where, value) longjmp(where, value)

#ifdef __cplusplus
}
#endif

#endif
