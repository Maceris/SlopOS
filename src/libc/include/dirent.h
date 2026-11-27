/*
 * dirent.h, SlopOS's libc (decisions/0201, 20l): a directory's entries, read a name at a time, beneath the working
 * directory as open's paths are. The listing is read whole when it's opened, so what changes after isn't seen.
 */
#ifndef _DIRENT_H
#define _DIRENT_H

#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

#define DT_UNKNOWN 0
#define DT_DIR 4
#define DT_REG 8

/* One entry: its name, NUL-terminated, and whether it's a directory (DT_DIR) or a file (DT_REG). */
struct dirent {
    ino_t d_ino;
    unsigned char d_type;
    char d_name[256];
};

/* An open directory's listing, which only the libc's files.c reaches into. */
typedef struct __libc_directory DIR;

DIR *opendir(const char *path);
struct dirent *readdir(DIR *directory);
int closedir(DIR *directory);
void rewinddir(DIR *directory);

#ifdef __cplusplus
}
#endif

#endif
