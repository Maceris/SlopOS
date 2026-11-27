/*
 * stdio.c, SlopOS's libc (decisions/0201, 20l): buffered streams over file descriptors. A stream is reading or writing
 * at any moment, its buffer holding what's been read ahead or what's still to be written; a seek, a flush or the
 * other direction gives it back to its file descriptor first. stdout is line-buffered, stderr unbuffered and stdin
 * fully buffered; stdout is flushed before stdin reads, as a prompt should show before what's typed. There are
 * FOPEN_MAX streams besides the three.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* How many bytes ungetc can push back before a read. */
#define PUSHBACK 4

struct __libc_file {
    /* Whether it's open: a closed one is free for fopen */
    int open;
    int fd;
    int readable;
    int writable;
    /* _IOFBF, _IOLBF or _IONBF */
    int buffering;
    unsigned char *buffer;
    size_t size;
    /* Whether buffer is malloc's, freed when it's closed */
    int owns_buffer;
    /* Reading: the bytes from read_at to read_end are read ahead */
    size_t read_at;
    size_t read_end;
    /* Writing: the first written bytes of buffer are still to be written */
    size_t written;
    /* ungetc's bytes, the last pushed back at pushed - 1 */
    unsigned char pushback[PUSHBACK];
    int pushed;
    int at_end;
    int failed;
};

/* The standard streams' buffers, there before any memory is. */
static unsigned char input_buffer[BUFSIZ];
static unsigned char output_buffer[BUFSIZ];

static FILE standard[3] = {
    {1, 0, 1, 0, _IOFBF, input_buffer, BUFSIZ, 0, 0, 0, 0, {0}, 0, 0, 0},
    {1, 1, 0, 1, _IOLBF, output_buffer, BUFSIZ, 0, 0, 0, 0, {0}, 0, 0, 0},
    {1, 2, 0, 1, _IONBF, NULL, 0, 0, 0, 0, 0, {0}, 0, 0, 0},
};

FILE *const stdin = &standard[0];
FILE *const stdout = &standard[1];
FILE *const stderr = &standard[2];

/* The streams fopen gives. */
static FILE streams[FOPEN_MAX];

/* Write all of what a stream's buffer holds to its file descriptor: 0, or EOF with the stream failed. */
static int write_out(FILE *stream) {
    size_t done = 0;
    while (done < stream->written) {
        ssize_t moved = write(stream->fd, stream->buffer + done, stream->written - done);
        if (moved <= 0) {
            stream->failed = 1;
            /* What wasn't written stays, at the buffer's start */
            memmove(stream->buffer, stream->buffer + done, stream->written - done);
            stream->written -= done;
            return EOF;
        }
        done += (size_t)moved;
    }
    stream->written = 0;
    return 0;
}

/*
 * Give back what a reading stream read ahead, its file descriptor moved back to where the stream's reader is; for a
 * stream that can't seek, like stdin, it's dropped. ungetc's bytes are dropped too, as C says a seek does.
 */
static void give_back_read(FILE *stream) {
    size_t ahead = stream->read_end - stream->read_at;
    if (ahead > 0) {
        lseek(stream->fd, -(off_t)ahead, SEEK_CUR);
    }
    stream->read_at = stream->read_end = 0;
    stream->pushed = 0;
}

/* Make a stream's buffer, if it has none and buffers: 0, or EOF without the memory, when it goes unbuffered. */
static int ensure_buffer(FILE *stream) {
    if (stream->buffer != NULL || stream->buffering == _IONBF) {
        return 0;
    }
    stream->buffer = malloc(BUFSIZ);
    if (stream->buffer == NULL) {
        stream->buffering = _IONBF;
        return EOF;
    }
    stream->size = BUFSIZ;
    stream->owns_buffer = 1;
    return 0;
}

int fflush(FILE *stream) {
    if (stream == NULL) {
        int result = 0;
        for (int i = 0; i < 3; i++) {
            if (standard[i].open && fflush(&standard[i]) != 0) {
                result = EOF;
            }
        }
        for (int i = 0; i < FOPEN_MAX; i++) {
            if (streams[i].open && fflush(&streams[i]) != 0) {
                result = EOF;
            }
        }
        return result;
    }
    if (stream->written > 0) {
        return write_out(stream);
    }
    if (stream->read_end > stream->read_at || stream->pushed > 0) {
        give_back_read(stream);
    }
    return 0;
}

/* Parse fopen's mode into open's flags: 0, or -1 for a mode that isn't one, with errno EINVAL. */
static int flags_of(const char *mode, int *flags) {
    int made;
    switch (mode[0]) {
    case 'r':
        made = O_RDONLY;
        break;
    case 'w':
        made = O_WRONLY | O_CREAT | O_TRUNC;
        break;
    case 'a':
        made = O_WRONLY | O_CREAT | O_APPEND;
        break;
    default:
        errno = EINVAL;
        return -1;
    }
    for (const char *at = mode + 1; *at != '\0'; at++) {
        if (*at == '+') {
            made = (made & ~O_ACCMODE) | O_RDWR;
        } else if (*at == 'x') {
            made |= O_EXCL;
        }
    }
    *flags = made;
    return 0;
}

/* Set a stream up on an open file descriptor, as fopen's flags say. */
static void start_stream(FILE *stream, int fd, int flags) {
    memset(stream, 0, sizeof *stream);
    stream->open = 1;
    stream->fd = fd;
    stream->readable = (flags & O_ACCMODE) != O_WRONLY;
    stream->writable = (flags & O_ACCMODE) != O_RDONLY;
    stream->buffering = _IOFBF;
}

FILE *fopen(const char *path, const char *mode) {
    int flags;
    if (flags_of(mode, &flags) != 0) {
        return NULL;
    }
    FILE *stream = NULL;
    for (int i = 0; i < FOPEN_MAX; i++) {
        if (!streams[i].open) {
            stream = &streams[i];
            break;
        }
    }
    if (stream == NULL) {
        errno = EMFILE;
        return NULL;
    }
    int fd = open(path, flags, 0666);
    if (fd < 0) {
        return NULL;
    }
    start_stream(stream, fd, flags);
    return stream;
}

FILE *fdopen(int fd, const char *mode) {
    int flags;
    if (flags_of(mode, &flags) != 0) {
        return NULL;
    }
    for (int i = 0; i < FOPEN_MAX; i++) {
        if (!streams[i].open) {
            start_stream(&streams[i], fd, flags);
            return &streams[i];
        }
    }
    errno = EMFILE;
    return NULL;
}

/* Close a stream's file descriptor and give its buffer back, leaving it closed: 0, or EOF if a write failed. */
static int end_stream(FILE *stream) {
    int result = fflush(stream);
    if (close(stream->fd) != 0) {
        result = EOF;
    }
    if (stream->owns_buffer) {
        free(stream->buffer);
    }
    stream->buffer = NULL;
    stream->owns_buffer = 0;
    stream->open = 0;
    return result;
}

int fclose(FILE *stream) {
    return end_stream(stream);
}

FILE *freopen(const char *path, const char *mode, FILE *stream) {
    int flags;
    if (flags_of(mode, &flags) != 0) {
        return NULL;
    }
    if (path == NULL) {
        /* The same file in another mode: only what it reads and writes changes */
        fflush(stream);
        stream->readable = (flags & O_ACCMODE) != O_WRONLY;
        stream->writable = (flags & O_ACCMODE) != O_RDONLY;
        return stream;
    }
    end_stream(stream);
    int fd = open(path, flags, 0666);
    if (fd < 0) {
        return NULL;
    }
    int buffering = stream == stdout ? _IOLBF : stream == stderr ? _IONBF : _IOFBF;
    unsigned char *buffer = stream == stdin ? input_buffer : stream == stdout ? output_buffer : NULL;
    start_stream(stream, fd, flags);
    stream->buffering = buffering;
    stream->buffer = buffer;
    stream->size = buffer == NULL ? 0 : BUFSIZ;
    return stream;
}

int setvbuf(FILE *stream, char *buffer, int mode, size_t size) {
    if (mode != _IOFBF && mode != _IOLBF && mode != _IONBF) {
        return -1;
    }
    fflush(stream);
    if (stream->owns_buffer) {
        free(stream->buffer);
        stream->owns_buffer = 0;
        stream->buffer = NULL;
        stream->size = 0;
    }
    stream->buffering = mode;
    if (mode != _IONBF && buffer != NULL && size > 0) {
        stream->buffer = (unsigned char *)buffer;
        stream->size = size;
    } else if (mode != _IONBF && (stream == stdin || stream == stdout)) {
        stream->buffer = stream == stdin ? input_buffer : output_buffer;
        stream->size = BUFSIZ;
    }
    return 0;
}

void setbuf(FILE *stream, char *buffer) {
    setvbuf(stream, buffer, buffer == NULL ? _IONBF : _IOFBF, BUFSIZ);
}

/* Turn a stream to reading: what it has to write written first. 0, or EOF if it can't read or a write failed. */
static int to_reading(FILE *stream) {
    if (!stream->readable) {
        stream->failed = 1;
        errno = EBADF;
        return EOF;
    }
    if (stream->written > 0 && write_out(stream) != 0) {
        return EOF;
    }
    return 0;
}

/* Read more into a stream's buffer: how many bytes came, 0 at the end, with at_end set, or -1, with failed set. */
static ssize_t fill(FILE *stream) {
    if (stream == stdin) {
        fflush(stdout);
    }
    ensure_buffer(stream);
    if (stream->buffer == NULL) {
        return 0;
    }
    ssize_t got = read(stream->fd, stream->buffer, stream->size);
    if (got < 0) {
        stream->failed = 1;
        return -1;
    }
    if (got == 0) {
        stream->at_end = 1;
    }
    stream->read_at = 0;
    stream->read_end = (size_t)got;
    return got;
}

int fgetc(FILE *stream) {
    if (stream->pushed > 0) {
        return stream->pushback[--stream->pushed];
    }
    if (stream->read_at < stream->read_end) {
        return stream->buffer[stream->read_at++];
    }
    if (to_reading(stream) != 0) {
        return EOF;
    }
    if (stream->buffering == _IONBF || stream->buffer == NULL) {
        ensure_buffer(stream);
    }
    if (stream->buffer == NULL) {
        unsigned char byte;
        ssize_t got = read(stream->fd, &byte, 1);
        if (got <= 0) {
            stream->failed |= got < 0;
            stream->at_end |= got == 0;
            return EOF;
        }
        return byte;
    }
    if (fill(stream) <= 0) {
        return EOF;
    }
    return stream->buffer[stream->read_at++];
}

int getc(FILE *stream) {
    return fgetc(stream);
}

int getchar(void) {
    return fgetc(stdin);
}

int ungetc(int c, FILE *stream) {
    if (c == EOF || stream->pushed >= PUSHBACK) {
        return EOF;
    }
    stream->pushback[stream->pushed++] = (unsigned char)c;
    stream->at_end = 0;
    return (unsigned char)c;
}

char *fgets(char *into, int size, FILE *stream) {
    if (size <= 0) {
        return NULL;
    }
    int count = 0;
    while (count < size - 1) {
        int c = fgetc(stream);
        if (c == EOF) {
            break;
        }
        into[count++] = (char)c;
        if (c == '\n') {
            break;
        }
    }
    if (count == 0) {
        return NULL;
    }
    into[count] = '\0';
    return into;
}

size_t fread(void *into, size_t size, size_t count, FILE *stream) {
    size_t wanted = size * count;
    unsigned char *bytes = into;
    size_t got = 0;
    if (wanted == 0) {
        return 0;
    }
    while (got < wanted && stream->pushed > 0) {
        bytes[got++] = stream->pushback[--stream->pushed];
    }
    while (got < wanted) {
        size_t ahead = stream->read_end - stream->read_at;
        if (ahead > 0) {
            size_t taken = ahead < wanted - got ? ahead : wanted - got;
            memcpy(bytes + got, stream->buffer + stream->read_at, taken);
            stream->read_at += taken;
            got += taken;
            continue;
        }
        if (to_reading(stream) != 0) {
            break;
        }
        /* What's left being at least a buffer's worth, it's read straight in */
        if (wanted - got >= stream->size || ensure_buffer(stream) != 0 || stream->buffer == NULL) {
            if (stream == stdin) {
                fflush(stdout);
            }
            ssize_t moved = read(stream->fd, bytes + got, wanted - got);
            if (moved <= 0) {
                stream->failed |= moved < 0;
                stream->at_end |= moved == 0;
                break;
            }
            got += (size_t)moved;
            continue;
        }
        if (fill(stream) <= 0) {
            break;
        }
    }
    return got / size;
}

/* Turn a stream to writing: what it read ahead given back first. 0, or EOF if it can't write. */
static int to_writing(FILE *stream) {
    if (!stream->writable) {
        stream->failed = 1;
        errno = EBADF;
        return EOF;
    }
    if (stream->read_end > stream->read_at || stream->pushed > 0) {
        give_back_read(stream);
    }
    stream->read_at = stream->read_end = 0;
    return 0;
}

size_t fwrite(const void *from, size_t size, size_t count, FILE *stream) {
    size_t total = size * count;
    const unsigned char *bytes = from;
    if (total == 0) {
        return 0;
    }
    if (to_writing(stream) != 0) {
        return 0;
    }
    ensure_buffer(stream);
    if (stream->buffering == _IONBF || stream->buffer == NULL) {
        if (stream->written > 0 && write_out(stream) != 0) {
            return 0;
        }
        size_t done = 0;
        while (done < total) {
            ssize_t moved = write(stream->fd, bytes + done, total - done);
            if (moved <= 0) {
                stream->failed = 1;
                break;
            }
            done += (size_t)moved;
        }
        return done / size;
    }
    size_t done = 0;
    while (done < total) {
        if (stream->written == stream->size && write_out(stream) != 0) {
            return done / size;
        }
        size_t room = stream->size - stream->written;
        size_t taken = room < total - done ? room : total - done;
        memcpy(stream->buffer + stream->written, bytes + done, taken);
        stream->written += taken;
        done += taken;
    }
    if (stream->buffering == _IOLBF && memchr(bytes, '\n', total) != NULL && write_out(stream) != 0) {
        return 0;
    }
    return count;
}

int fputc(int c, FILE *stream) {
    unsigned char byte = (unsigned char)c;
    return fwrite(&byte, 1, 1, stream) == 1 ? byte : EOF;
}

int putc(int c, FILE *stream) {
    return fputc(c, stream);
}

int putchar(int c) {
    return fputc(c, stdout);
}

int fputs(const char *text, FILE *stream) {
    size_t count = strlen(text);
    return fwrite(text, 1, count, stream) == count ? 0 : EOF;
}

int puts(const char *text) {
    if (fputs(text, stdout) == EOF || fputc('\n', stdout) == EOF) {
        return EOF;
    }
    return 0;
}

int fseeko(FILE *stream, off_t offset, int whence) {
    if (fflush(stream) != 0) {
        return -1;
    }
    if (lseek(stream->fd, offset, whence) < 0) {
        return -1;
    }
    stream->at_end = 0;
    stream->pushed = 0;
    return 0;
}

int fseek(FILE *stream, long offset, int whence) {
    return fseeko(stream, offset, whence);
}

off_t ftello(FILE *stream) {
    off_t place = lseek(stream->fd, 0, SEEK_CUR);
    if (place < 0) {
        return -1;
    }
    return place - (off_t)(stream->read_end - stream->read_at) - stream->pushed + (off_t)stream->written;
}

long ftell(FILE *stream) {
    return ftello(stream);
}

void rewind(FILE *stream) {
    fseeko(stream, 0, SEEK_SET);
    stream->failed = 0;
}

int fgetpos(FILE *stream, fpos_t *place) {
    place->offset = ftello(stream);
    return place->offset < 0 ? -1 : 0;
}

int fsetpos(FILE *stream, const fpos_t *place) {
    return fseeko(stream, place->offset, SEEK_SET);
}

int feof(FILE *stream) {
    return stream->at_end;
}

int ferror(FILE *stream) {
    return stream->failed;
}

void clearerr(FILE *stream) {
    stream->at_end = 0;
    stream->failed = 0;
}

int fileno(FILE *stream) {
    return stream->fd;
}

void perror(const char *what) {
    const char *words = strerror(errno);
    if (what != NULL && what[0] != '\0') {
        fprintf(stderr, "%s: %s\n", what, words);
    } else {
        fprintf(stderr, "%s\n", words);
    }
}

int remove(const char *path) {
    if (unlink(path) == 0) {
        return 0;
    }
    return errno == EISDIR ? rmdir(path) : -1;
}

FILE *tmpfile(void) {
    errno = ENOSYS;
    return NULL;
}

char *tmpnam(char *name) {
    (void)name;
    return NULL;
}
