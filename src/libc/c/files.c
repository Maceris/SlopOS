/*
 * files.c, SlopOS's libc (decisions/0201, 20l): what of the file descriptors is C's: open, as it's variadic, which
 * Hemera's exports can't be, and fcntl, for the same reason, and dirent.h's DIR, an open listing of the Hemera's (files.hsc) and the entry readdir
 * gives back. The rest of unistd.h, fcntl.h and sys/stat.h is the Hemera's own.
 */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdlib.h>
#include <sys/stat.h>

/* The Hemera's: open with the flags alone; and a listing's handle, its next entry, and its end. */
int slopos_libc_open(const char *path, int flags);
int slopos_libc_fcntl(int fd, int command, long argument);
int slopos_libc_opendir(const char *path);
int slopos_libc_readdir(int handle, struct dirent *into);
void slopos_libc_rewinddir(int handle);
int slopos_libc_closedir(int handle);

_Static_assert(sizeof(struct stat) == 88, "struct stat is as files.hsc's Stat");
_Static_assert(sizeof(struct dirent) == 272, "struct dirent is as files.hsc's Dirent");

int open(const char *path, int flags, ...) {
    /* A mode comes with O_CREAT, but SlopOS's files keep no permissions, so it's read past and dropped */
    if (flags & O_CREAT) {
        va_list arguments;
        va_start(arguments, flags);
        (void)va_arg(arguments, int);
        va_end(arguments);
    }
    return slopos_libc_open(path, flags);
}

int fcntl(int fd, int command, ...) {
    /* Only F_SETFD's and F_SETFL's argument is read, an int; the others take none */
    long argument = 0;
    if (command == F_SETFD || command == F_SETFL) {
        va_list arguments;
        va_start(arguments, command);
        argument = va_arg(arguments, int);
        va_end(arguments);
    }
    return slopos_libc_fcntl(fd, command, argument);
}

int creat(const char *path, mode_t mode) {
    (void)mode;
    return slopos_libc_open(path, O_WRONLY | O_CREAT | O_TRUNC);
}

/* An open directory: the Hemera's listing, and the entry readdir gave last. */
struct __libc_directory {
    int handle;
    struct dirent entry;
};

DIR *opendir(const char *path) {
    DIR *made = malloc(sizeof *made);
    if (made == NULL) {
        return NULL;
    }
    made->handle = slopos_libc_opendir(path);
    if (made->handle < 0) {
        int number = errno;
        free(made);
        errno = number;
        return NULL;
    }
    return made;
}

struct dirent *readdir(DIR *directory) {
    return slopos_libc_readdir(directory->handle, &directory->entry) == 1 ? &directory->entry : NULL;
}

void rewinddir(DIR *directory) {
    slopos_libc_rewinddir(directory->handle);
}

int closedir(DIR *directory) {
    int result = slopos_libc_closedir(directory->handle);
    free(directory);
    return result;
}
