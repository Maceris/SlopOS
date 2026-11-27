/*
 * wc's C (decisions/0201, 20l): a C tool on SlopOS's libc, as a ported one would be. It counts each file's lines,
 * words and bytes, as POSIX's wc, its files beneath the shell's directory, or stdin, the terminal, without any; with
 * -l, -w or -c only those counts. More than one file ends with a total. It ends with 1 if a file couldn't be read.
 */
#include <ctype.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>

/* What's counted of a file. */
struct counts {
    long lines;
    long words;
    long bytes;
};

/* Which counts are shown, from the options: all three without any. */
static int show_lines, show_words, show_bytes;

/* Count a stream's lines, words and bytes, adding to counts; 0, or -1 if it couldn't be read. */
static int count_stream(FILE *stream, struct counts *counts) {
    int in_word = 0;
    int c;
    while ((c = getc(stream)) != EOF) {
        counts->bytes++;
        if (c == '\n') {
            counts->lines++;
        }
        if (isspace(c)) {
            in_word = 0;
        } else if (!in_word) {
            in_word = 1;
            counts->words++;
        }
    }
    return ferror(stream) ? -1 : 0;
}

/* Show counts, then the name, if there is one. */
static void show(const struct counts *counts, const char *name) {
    if (show_lines) {
        printf("%7ld ", counts->lines);
    }
    if (show_words) {
        printf("%7ld ", counts->words);
    }
    if (show_bytes) {
        printf("%7ld ", counts->bytes);
    }
    printf("%s\n", name != NULL ? name : "");
}

int main(int argc, char **argv) {
    int first = 1;
    for (; first < argc && argv[first][0] == '-' && argv[first][1] != '\0'; first++) {
        for (const char *option = argv[first] + 1; *option != '\0'; option++) {
            if (*option == 'l') {
                show_lines = 1;
            } else if (*option == 'w') {
                show_words = 1;
            } else if (*option == 'c') {
                show_bytes = 1;
            } else {
                fprintf(stderr, "wc: no option -%c; it takes -l, -w and -c\n", *option);
                return 2;
            }
        }
    }
    if (!show_lines && !show_words && !show_bytes) {
        show_lines = show_words = show_bytes = 1;
    }
    if (first == argc) {
        struct counts counts = {0, 0, 0};
        count_stream(stdin, &counts);
        show(&counts, NULL);
        return 0;
    }
    struct counts total = {0, 0, 0};
    int failed = 0;
    for (int i = first; i < argc; i++) {
        FILE *file = fopen(argv[i], "r");
        if (file == NULL) {
            fprintf(stderr, "wc: %s: %s\n", argv[i], strerror(errno));
            failed = 1;
            continue;
        }
        struct counts counts = {0, 0, 0};
        if (count_stream(file, &counts) != 0) {
            fprintf(stderr, "wc: %s: %s\n", argv[i], strerror(errno));
            failed = 1;
        }
        fclose(file);
        show(&counts, argv[i]);
        total.lines += counts.lines;
        total.words += counts.words;
        total.bytes += counts.bytes;
    }
    if (argc - first > 1) {
        show(&total, "total");
    }
    return failed;
}
