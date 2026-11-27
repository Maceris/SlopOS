/*
 * ctype.h, SlopOS's libc (decisions/0201, 20l): ASCII character classes, in the C locale, the only one; written in
 * Hemera (src/libc/characters.hsc). Each takes an unsigned char's value or EOF, and is false for EOF and bytes above
 * 0x7f.
 */
#ifndef _CTYPE_H
#define _CTYPE_H

#ifdef __cplusplus
extern "C" {
#endif

int isalnum(int c);
int isalpha(int c);
int isblank(int c);
int iscntrl(int c);
int isdigit(int c);
int isgraph(int c);
int islower(int c);
int isprint(int c);
int ispunct(int c);
int isspace(int c);
int isupper(int c);
int isxdigit(int c);
int tolower(int c);
int toupper(int c);

#ifdef __cplusplus
}
#endif

#endif
