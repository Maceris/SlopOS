/*
 * test_libc's C (decisions/0201, 20l): SlopOS's libc exercised from C, each part a test of many checks, reported on
 * stdout as Hemera's tests are: a line for each check that fails, then "N tests: P passed, F failed" and ", S skipped"
 * for the file test without a working directory. test_libc runs it from the root task, its stdout the debug log;
 * test_libc_files runs it from the shell beneath the shell's directory, where its file test runs too. main returns how
 * many tests failed; given --exit=-1, it runs none and calls exit(-1), for the exit status's 8 bits.
 */
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <locale.h>
#include <math.h>
#include <setjmp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

/* The test running, and how many of its checks failed. */
static const char *test_name;
static int test_failures;

/* Note a check: a line for one that failed, naming the test, the line and what it checked. */
static void note(int passed, const char *what, int line) {
    if (!passed) {
        test_failures++;
        printf("FAIL %s, line %d: %s\n", test_name, line, what);
    }
}

#define CHECK(condition) note((condition) != 0, #condition, __LINE__)
#define CHECK_TEXT(made, expected)                                                                                     \
    do {                                                                                                               \
        const char *made_text = (made);                                                                                \
        if (strcmp(made_text, (expected)) != 0) {                                                                      \
            test_failures++;                                                                                           \
            printf("FAIL %s, line %d: \"%s\", not \"%s\"\n", test_name, __LINE__, made_text, (expected));             \
        }                                                                                                              \
    } while (0)
#define CHECK_NEAR(value, expected, tolerance) note(fabs((value) - (expected)) <= (tolerance), #value, __LINE__)

/*
 * The bytes of a long double that hold its value: x86-64's 80-bit one has 6 of padding after them, which a store
 * needn't write. Long doubles are compared by them, as comparing AArch64's and RISC-V's quads would call compiler-rt.
 */
#define LONG_DOUBLE_BYTES (__LDBL_MANT_DIG__ == 64 ? 10 : 16)

/* 99 significant digits of pi, 100 bytes, longer than any buffer a scanned number could have been cut to. */
static const char LONG_PI[] =
    "3.14159265358979323846264338327950288419716939937510582097494459230781640628620899862803482534211706";

/* snprintf into a buffer of its own, for CHECK_TEXT. */
static char formatted[512];
#define FORMAT(...) (snprintf(formatted, sizeof formatted, __VA_ARGS__), formatted)

static void strings_test(void) {
    char buffer[64];
    CHECK(strlen("") == 0);
    CHECK(strlen("hello") == 5);
    CHECK(strnlen("hello", 3) == 3);
    CHECK(strcmp("abc", "abc") == 0);
    CHECK(strcmp("abc", "abd") < 0);
    CHECK(strcmp("abd", "abc") > 0);
    CHECK(strcmp("ab", "abc") < 0);
    CHECK(strcmp("\xff", "a") > 0);
    CHECK(strncmp("abcdef", "abcxyz", 3) == 0);
    CHECK(strncmp("abcdef", "abcxyz", 4) < 0);
    CHECK(strcasecmp("HeLLo", "hello") == 0);
    CHECK(strncasecmp("HELP", "helium", 3) == 0);
    CHECK_TEXT(strcpy(buffer, "copied"), "copied");
    CHECK_TEXT(strcat(buffer, " and joined"), "copied and joined");
    memset(buffer, 'x', sizeof buffer);
    strncpy(buffer, "ab", 5);
    CHECK(buffer[0] == 'a' && buffer[1] == 'b' && buffer[2] == 0 && buffer[4] == 0 && buffer[5] == 'x');
    strcpy(buffer, "start");
    CHECK_TEXT(strncat(buffer, "123456", 3), "start123");
    const char *text = "a/b/c.txt";
    CHECK(strchr(text, '/') == text + 1);
    CHECK(strrchr(text, '/') == text + 3);
    CHECK(strchr(text, 'z') == NULL);
    CHECK(strchr(text, '\0') == text + 9);
    CHECK(strstr(text, "c.t") == text + 4);
    CHECK(strstr(text, "") == text);
    CHECK(strstr(text, "nope") == NULL);
    CHECK(strspn("123abc", "0123456789") == 3);
    CHECK(strcspn("abc,def", ",;") == 3);
    CHECK(strpbrk("abc,def", ";,") == strchr("abc,def", ','));
    CHECK(memchr("abcdef", 'd', 6) != NULL && *(const char *)memchr("abcdef", 'd', 6) == 'd');
    CHECK(memchr("abcdef", 'd', 3) == NULL);
    CHECK(memcmp("abc", "abd", 3) < 0 && memcmp("abc", "abd", 2) == 0);
    strcpy(buffer, "0123456789");
    memmove(buffer + 2, buffer, 5);
    CHECK_TEXT(buffer, "0101234789");
    char words[] = "  one, two;;three  ";
    const char *found[4] = {0};
    int count = 0;
    for (char *token = strtok(words, " ,;"); token != NULL && count < 4; token = strtok(NULL, " ,;")) {
        found[count++] = token;
    }
    CHECK(count == 3);
    CHECK(count == 3 && strcmp(found[0], "one") == 0 && strcmp(found[1], "two") == 0 && strcmp(found[2], "three") == 0);
    char *copy = strdup("duplicated");
    CHECK(copy != NULL && strcmp(copy, "duplicated") == 0);
    free(copy);
    copy = strndup("duplicated", 3);
    CHECK(copy != NULL && strcmp(copy, "dup") == 0);
    free(copy);
    CHECK_TEXT(strerror(ENOENT), "No such file or directory");
    CHECK(strcoll("a", "b") < 0);
}

static void characters_test(void) {
    CHECK(isdigit('7') && !isdigit('a') && !isdigit(EOF));
    CHECK(isalpha('q') && isalpha('Q') && !isalpha('1'));
    CHECK(isalnum('z') && isalnum('5') && !isalnum('_'));
    CHECK(isspace(' ') && isspace('\n') && isspace('\t') && !isspace('x'));
    CHECK(isupper('A') && !isupper('a') && islower('a'));
    CHECK(isxdigit('f') && isxdigit('F') && isxdigit('9') && !isxdigit('g'));
    CHECK(ispunct('!') && !ispunct('a') && !ispunct(' '));
    CHECK(isprint(' ') && !isprint('\n') && iscntrl('\n') && isgraph('~') && !isgraph(' '));
    CHECK(tolower('A') == 'a' && tolower('a') == 'a' && toupper('z') == 'Z' && toupper('1') == '1');
    CHECK(!isalpha(0xe9));
}

static void formatting_test(void) {
    CHECK_TEXT(FORMAT("%d", -42), "-42");
    CHECK_TEXT(FORMAT("%i|%+d|% d", 7, 7, 7), "7|+7| 7");
    CHECK_TEXT(FORMAT("[%5d][%-5d][%05d]", 42, 42, -42), "[   42][42   ][-0042]");
    CHECK_TEXT(FORMAT("%.3d|%3.2d", 5, 5), "005| 05");
    CHECK_TEXT(FORMAT("%u", 4294967295u), "4294967295");
    CHECK_TEXT(FORMAT("%x %X %#x %#X %o %#o", 255, 255, 255, 255, 8, 8), "ff FF 0xff 0XFF 10 010");
    CHECK_TEXT(FORMAT("%lld %llu", LLONG_MIN, ULLONG_MAX), "-9223372036854775808 18446744073709551615");
    CHECK_TEXT(FORMAT("%ld %lx", -1L, 0xdeadbeefcafeL), "-1 deadbeefcafe");
    CHECK_TEXT(FORMAT("%zu %hhd %hu", (size_t)12, 300, 70000), "12 44 4464");
    CHECK_TEXT(FORMAT("%s|%.3s|%6s|%-6s|", "text", "abcdef", "ab", "ab"), "text|abc|    ab|ab    |");
    CHECK_TEXT(FORMAT("%c%c%%", 'o', 'k'), "ok%");
    CHECK_TEXT(FORMAT("%p", (void *)0x1000), "0x1000");
    CHECK_TEXT(FORMAT("%*d|%-*d|%.*f", 4, 1, 4, 2, 2, 3.14159), "   1|2   |3.14");
    CHECK_TEXT(FORMAT("%f", 3.14159), "3.141590");
    CHECK_TEXT(FORMAT("%.2f", 2.675), "2.67");
    CHECK_TEXT(FORMAT("%.0f %.0f %.0f %.0f", 0.5, 1.5, 2.5, 3.5), "0 2 2 4");
    CHECK_TEXT(FORMAT("%.1f", 0.05), "0.1");
    CHECK_TEXT(FORMAT("%8.3f|%-8.2f|%08.2f", 3.14159, 2.5, -2.5), "   3.142|2.50    |-0002.50");
    CHECK_TEXT(FORMAT("%f", 1e15), "1000000000000000.000000");
    CHECK_TEXT(FORMAT("%.20f", 1e-10), "0.00000000010000000000");
    CHECK_TEXT(FORMAT("%e", 12345.678), "1.234568e+04");
    CHECK_TEXT(FORMAT("%.3e %E", 0.0, 1e-300), "0.000e+00 1.000000E-300");
    CHECK_TEXT(FORMAT("%.2e", 9.995), "9.99e+00");
    CHECK_TEXT(FORMAT("%.2e", 9.996), "1.00e+01");
    CHECK_TEXT(FORMAT("%g %g %g %g", 0.0001, 0.00001, 123456789.0, 100000.0), "0.0001 1e-05 1.23457e+08 100000");
    CHECK_TEXT(FORMAT("%g %g %#g %G", 0.0, 1.5, 1.0, 1e-20), "0 1.5 1.00000 1E-20");
    CHECK_TEXT(FORMAT("%.14g %.17g", 0.1, 0.1), "0.1 0.10000000000000001");
    CHECK_TEXT(FORMAT("%.14g", 1.0 / 3.0), "0.33333333333333");
    CHECK_TEXT(FORMAT("%.14g", 2.0e20), "2e+20");
    CHECK_TEXT(FORMAT("%g %g %G %f", HUGE_VAL, -HUGE_VAL, HUGE_VAL, (double)NAN), "inf -inf INF nan");
    /* 1e300's exact value, as Python's '%.0f' % 1e300 gives it */
    CHECK_TEXT(FORMAT("%.0f", 1e300),
               "1000000000000000052504760255204420248704468581108159154915854115511802457988908195786371375080447864043704443832"
               "8838781769425232353604305756447921847867069828483872009265758037378302337947880900593689532349707999450811190389"
               "67640880074652742780142494579258788820056842838115669472196386865459400540160");
    CHECK_TEXT(FORMAT("%.3g", 5e-324), "4.94e-324");
    CHECK_TEXT(FORMAT("%a %a %.1a %A", 1.0, 0.5, 1.75, -3.0), "0x1p+0 0x1p-1 0x1.cp+0 -0X1.8P+1");
    /* The 0 flag's zeros come after the sign and 0x */
    CHECK_TEXT(FORMAT("%010a|%-10a|%+010A|%010a", 1.0, 1.0, 2.0, -0.5), "0x00001p+0|0x1p+0    |+0X0001P+1|-0x0001p-1");
    /* A long double, read as one, so what comes after it isn't shifted, and written as the double nearest it */
    CHECK_TEXT(FORMAT("%Lf %d %.3Le %La %s", 2.5L, 7, 0.125L, -3.0L, "after"), "2.500000 7 1.250e-01 -0x1.8p+1 after");
    CHECK_TEXT(FORMAT("%.17Lg %Lg %Lg %.3Lg", 0.1L, 1e400L, -1e-400L, 1e-310L), "0.10000000000000001 inf -0 1e-310");
    CHECK_TEXT(FORMAT("%Lg %LG", (long double)NAN, -(long double)INFINITY), "nan -INF");
    /* Past INT_MAX bytes: -1, EOVERFLOW */
    errno = 0;
    CHECK(snprintf(NULL, 0, "%*d%*d", INT_MAX, 1, INT_MAX, 1) == -1 && errno == EOVERFLOW);
    CHECK(snprintf(NULL, 0, "%*d", INT_MAX, 1) == INT_MAX);
    CHECK_TEXT(FORMAT("%5s|%-3c|", "", 'z'), "     |z  |");
    char small[6];
    CHECK(snprintf(small, sizeof small, "%s", "truncated") == 9);
    CHECK_TEXT(small, "trunc");
    CHECK(snprintf(NULL, 0, "%d", 12345) == 5);
    int written = 0;
    snprintf(formatted, sizeof formatted, "abc%n", &written);
    CHECK(written == 3);
    char sprinted[32];
    CHECK(sprintf(sprinted, "%s-%d", "x", 9) == 3);
    CHECK_TEXT(sprinted, "x-9");
    int number = 0;
    char word[16] = {0};
    double real = 0;
    unsigned hex = 0;
    CHECK(sscanf("  12 abc 3.5 ff", "%d %15s %lf %x", &number, word, &real, &hex) == 4);
    CHECK(number == 12 && strcmp(word, "abc") == 0 && real == 3.5 && hex == 0xff);
    char set[16] = {0};
    CHECK(sscanf("key=value;", "%15[^=]=", set) == 1);
    CHECK_TEXT(set, "key");
    CHECK(sscanf("", "%d", &number) == EOF);
    CHECK(sscanf("x", "%d", &number) == 0);
    /* %Lf stores a long double, and what follows it is read into its own */
    long double extended = 0;
    static const long double TWO_AND_A_HALF = 2.5L;
    static const long double LEAST = (long double)4.9406564584124654e-324;
    static const long double HUGE_LONG = (long double)HUGE_VAL;
    CHECK(sscanf("2.5 9", "%Lf %d", &extended, &number) == 2 && number == 9);
    CHECK(memcmp(&extended, &TWO_AND_A_HALF, LONG_DOUBLE_BYTES) == 0);
    CHECK(sscanf("4.9406564584124654e-324", "%Lg", &extended) == 1 && memcmp(&extended, &LEAST, LONG_DOUBLE_BYTES) == 0);
    CHECK(sscanf("1e999", "%Le", &extended) == 1 && memcmp(&extended, &HUGE_LONG, LONG_DOUBLE_BYTES) == 0);
    float single = 0;
    CHECK(sscanf("0.25", "%f", &single) == 1 && single == 0.25f);
    /* A number longer than 63 bytes is read whole, with or without a width, every digit counting */
    char long_field[160];
    snprintf(long_field, sizeof long_field, "%s 42", LONG_PI);
    real = 0;
    number = 0;
    CHECK(sscanf(long_field, "%lf %d", &real, &number) == 2 && real == M_PI && number == 42);
    int consumed = 0;
    real = 0;
    number = 0;
    CHECK(sscanf(long_field, "%100lf%n %d", &real, &consumed, &number) == 2 && real == M_PI && consumed == 100 &&
          number == 42);
    CHECK(sscanf(long_field, "%5lf%n", &real, &consumed) == 1 && real == 3.141 && consumed == 5);
    CHECK(sscanf("00000000000000000000000000000000000000000000000000000000000000000000000000000000042 x", "%d %c", &number,
                 word) == 2 &&
          number == 42 && word[0] == 'x');
}

static void memory_test(void) {
    char *block = malloc(10);
    CHECK(block != NULL);
    CHECK(((uintptr_t)block & 15) == 0);
    for (int i = 0; i < 10; i++) {
        block[i] = (char)('a' + i);
    }
    block = realloc(block, 100000);
    CHECK(block != NULL);
    int kept = 1;
    for (int i = 0; i < 10; i++) {
        kept &= block[i] == (char)('a' + i);
    }
    CHECK(kept);
    block[99999] = 'z';
    block = realloc(block, 5);
    CHECK(block != NULL && block[0] == 'a' && block[4] == 'e');
    free(block);
    free(NULL);
    int *zeros = calloc(1000, sizeof(int));
    int zeroed = zeros != NULL;
    for (int i = 0; zeros != NULL && i < 1000; i++) {
        zeroed &= zeros[i] == 0;
    }
    CHECK(zeroed);
    free(zeros);
    void *aligned = aligned_alloc(256, 1000);
    CHECK(aligned != NULL && ((uintptr_t)aligned & 255) == 0);
    free(aligned);
    void *posix = NULL;
    CHECK(posix_memalign(&posix, 64, 100) == 0 && posix != NULL && ((uintptr_t)posix & 63) == 0);
    free(posix);
    /* Small blocks of every size up to about 4 KiB, as a program the shell runs has 4 MiB for everything */
    void *many[200];
    int made = 1;
    for (int i = 0; i < 200; i++) {
        many[i] = malloc((size_t)(i * 21 + 1));
        made &= many[i] != NULL;
        if (many[i] != NULL) {
            memset(many[i], i, (size_t)(i * 21 + 1));
        }
    }
    for (int i = 0; i < 200; i++) {
        made &= many[i] == NULL || ((unsigned char *)many[i])[i * 21] == (unsigned char)i;
        free(many[i]);
    }
    CHECK(made);
    errno = 0;
    CHECK(malloc((size_t)-1 / 2) == NULL && errno == ENOMEM);
    /* Past the budget but within the address range, twice: neither takes addresses, so a block of its own still maps */
    CHECK(malloc((size_t)1 << 39) == NULL && malloc((size_t)1 << 39) == NULL);
    void *after = malloc(65536);
    CHECK(after != NULL);
    free(after);
    CHECK(calloc((size_t)1 << 40, (size_t)1 << 40) == NULL);
}

/* Compare ints, for qsort and bsearch. */
static int compare_ints(const void *a, const void *b) {
    int x = *(const int *)a;
    int y = *(const int *)b;
    return (x > y) - (x < y);
}

/* Compare C strings through pointers to them, for qsort. */
static int compare_strings(const void *a, const void *b) {
    return strcmp(*(const char *const *)a, *(const char *const *)b);
}

static void sorting_test(void) {
    int numbers[] = {5, -3, 12, 0, 7, 7, -40, 1, 99, 3};
    size_t count = sizeof numbers / sizeof numbers[0];
    qsort(numbers, count, sizeof numbers[0], compare_ints);
    int sorted = 1;
    for (size_t i = 1; i < count; i++) {
        sorted &= numbers[i - 1] <= numbers[i];
    }
    CHECK(sorted);
    CHECK(numbers[0] == -40 && numbers[count - 1] == 99);
    int key = 7;
    int *found = bsearch(&key, numbers, count, sizeof numbers[0], compare_ints);
    CHECK(found != NULL && *found == 7);
    key = 8;
    CHECK(bsearch(&key, numbers, count, sizeof numbers[0], compare_ints) == NULL);
    const char *names[] = {"pear", "apple", "fig", "banana"};
    qsort(names, 4, sizeof names[0], compare_strings);
    CHECK(strcmp(names[0], "apple") == 0 && strcmp(names[3], "pear") == 0);
    int many[1000];
    srand(42);
    for (int i = 0; i < 1000; i++) {
        many[i] = rand() % 500;
    }
    qsort(many, 1000, sizeof many[0], compare_ints);
    sorted = 1;
    for (int i = 1; i < 1000; i++) {
        sorted &= many[i - 1] <= many[i];
    }
    CHECK(sorted);
    srand(7);
    int first = rand();
    srand(7);
    CHECK(rand() == first);
    CHECK(first >= 0 && first <= RAND_MAX);
}

static void numbers_test(void) {
    char *end = NULL;
    CHECK(strtol("  -123abc", &end, 10) == -123 && strcmp(end, "abc") == 0);
    CHECK(strtol("0x1F", NULL, 0) == 31);
    CHECK(strtol("017", NULL, 0) == 15);
    CHECK(strtol("ff", NULL, 16) == 255 && strtol("0xff", NULL, 16) == 255);
    CHECK(strtol("z", NULL, 36) == 35);
    CHECK(strtol("0x", &end, 0) == 0 && *end == 'x');
    const char *none = "none";
    CHECK(strtol(none, &end, 10) == 0 && end == none);
    errno = 0;
    CHECK(strtol("99999999999999999999", NULL, 10) == LONG_MAX && errno == ERANGE);
    errno = 0;
    CHECK(strtol("-99999999999999999999", NULL, 10) == LONG_MIN && errno == ERANGE);
    errno = 0;
    CHECK(strtol("-9223372036854775808", NULL, 10) == LONG_MIN && errno == 0);
    CHECK(strtoul("-1", NULL, 10) == ULONG_MAX);
    CHECK(strtoull("18446744073709551615", NULL, 10) == ULLONG_MAX);
    CHECK(atoi("  42 ") == 42 && atol("-7") == -7 && atoll("123456789012") == 123456789012LL);
    CHECK(strtod("3.25e2", &end) == 325.0 && *end == '\0');
    CHECK(strtod("  .5x", &end) == 0.5 && *end == 'x');
    CHECK(strtod("0x1.8p1", NULL) == 3.0);
    CHECK(strtod("0x10", NULL) == 16.0);
    /* A hex float out of range: ERANGE both ways; a subnormal rounded once, not first to 53 bits and then again */
    errno = 0;
    CHECK(strtod("0x1p-1100", NULL) == 0.0 && errno == ERANGE);
    errno = 0;
    CHECK(strtod("-0x1p-1075", NULL) == 0.0 && signbit(strtod("-0x1p-1075", NULL)) && errno == ERANGE);
    errno = 0;
    CHECK(strtod("0x1p1024", NULL) == HUGE_VAL && errno == ERANGE);
    errno = 0;
    CHECK(strtod("0x1.fffffffffffffp1023", NULL) == 0x1.fffffffffffffp1023 && errno == 0);
    CHECK(strtod("0x1.fffffffffffff8p1023", NULL) == HUGE_VAL);
    errno = 0;
    CHECK(strtod("0x0p99999", NULL) == 0.0 && errno == 0);
    CHECK(strtod("0x1.7ffffffffffffffp-1074", NULL) == 0x1p-1074 && errno == 0);
    CHECK(strtod("0x1.8p-1074", NULL) == 0x1p-1073);
    CHECK(strtod("0x1.000001p-1075", NULL) == 0x1p-1074);
    CHECK(strtod("0x1.ffffffffffffffp-1023", NULL) == 0x1p-1022);
    CHECK(strtod("0x0.0000000000001p-1022", NULL) == 0x1p-1074);
    CHECK(strtod("1e", &end) == 1.0 && *end == 'e');
    CHECK(strtod("0.1", NULL) == 0.1);
    CHECK(strtod("2.2250738585072014e-308", NULL) == 2.2250738585072014e-308);
    CHECK(isinf(strtod("-Infinity", NULL)) && strtod("-inf", NULL) < 0);
    CHECK(isnan(strtod("nan(123)", &end)) && *end == '\0');
    errno = 0;
    CHECK(strtod("1e400", NULL) == HUGE_VAL && errno == ERANGE);
    errno = 0;
    CHECK(strtod("1e-400", NULL) == 0.0 && errno == ERANGE);
    CHECK(atof("-2.5") == -2.5);
    CHECK(strtof("0.5", NULL) == 0.5f);
    CHECK(abs(-5) == 5 && labs(-5L) == 5 && llabs(-5LL) == 5);
    div_t parts = div(17, 5);
    CHECK(parts.quot == 3 && parts.rem == 2);
}

static void math_test(void) {
    CHECK(floor(2.7) == 2.0 && floor(-2.5) == -3.0 && ceil(2.1) == 3.0 && ceil(-2.9) == -2.0);
    CHECK(trunc(-2.7) == -2.0 && round(2.5) == 3.0 && round(-2.5) == -3.0 && round(0.49999999999999994) == 0.0);
    CHECK(fabs(-3.5) == 3.5 && fmod(7.5, 2.0) == 1.5 && fmod(-7.5, 2.0) == -1.5);
    CHECK(sqrt(16.0) == 4.0 && isnan(sqrt(-1.0)));
    CHECK(pow(2.0, 10.0) == 1024.0 && pow(9.0, 0.5) == 3.0 && pow(-2.0, 3.0) == -8.0 && pow(0.0, 0.0) == 1.0);
    CHECK_NEAR(exp(1.0), 2.718281828459045, 1e-15);
    CHECK_NEAR(log(10.0), 2.302585092994046, 1e-15);
    CHECK(log2(8.0) == 3.0 && log10(1000.0) == 3.0);
    CHECK(log(0.0) == -HUGE_VAL && isnan(log(-1.0)));
    CHECK_NEAR(sin(M_PI / 6), 0.5, 1e-15);
    CHECK_NEAR(cos(M_PI / 3), 0.5, 1e-15);
    CHECK_NEAR(tan(M_PI / 4), 1.0, 1e-15);
    CHECK_NEAR(atan2(1.0, -1.0), 3 * M_PI / 4, 1e-15);
    CHECK_NEAR(asin(1.0), M_PI / 2, 1e-15);
    CHECK_NEAR(acos(0.0), M_PI / 2, 1e-15);
    CHECK_NEAR(atan(1.0), M_PI / 4, 1e-15);
    CHECK_NEAR(sinh(1.0), 1.1752011936438014, 1e-15);
    CHECK_NEAR(cosh(1.0), 1.5430806348152437, 1e-15);
    CHECK_NEAR(tanh(0.5), 0.46211715726000974, 1e-15);
    CHECK_NEAR(hypot(3.0, 4.0), 5.0, 1e-15);
    CHECK_NEAR(cbrt(-27.0), -3.0, 1e-15);
    int exponent = 0;
    CHECK(frexp(8.0, &exponent) == 0.5 && exponent == 4);
    CHECK(ldexp(0.75, 4) == 12.0);
    double whole = 0;
    CHECK(modf(3.25, &whole) == 0.25 && whole == 3.0);
    CHECK(modf(-3.25, &whole) == -0.25 && whole == -3.0);
    CHECK(HUGE_VAL > 1e308 && isinf(HUGE_VAL) && isnan(NAN) && !isfinite(INFINITY) && isfinite(1.0));
    CHECK(fmin(1.0, NAN) == 1.0 && fmax(NAN, 2.0) == 2.0 && copysign(3.0, -0.0) == -3.0);
    CHECK(floorf(2.5f) == 2.0f && sqrtf(9.0f) == 3.0f && fabsf(-1.5f) == 1.5f);
    CHECK_NEAR(powf(2.0f, 0.5f), 1.41421356, 1e-6);
    CHECK(fpclassify(0.0) == FP_ZERO && fpclassify(1.0) == FP_NORMAL && signbit(-0.0));
}

/* Where jumps go back to, and how deep the jumps went. */
static jmp_buf jump_back;
static int deepest;

/* Recurse to a depth, then jump all the way back out with a value. */
static void jump_from(int depth, int value) {
    volatile char frame[64];
    frame[0] = (char)depth;
    if (depth > deepest) {
        deepest = depth;
    }
    if (depth == 0) {
        longjmp(jump_back, value);
    }
    jump_from(depth - 1, value + frame[0] * 0);
}

static void jumps_test(void) {
    volatile int passes = 0;
    int value = setjmp(jump_back);
    passes++;
    if (value == 0) {
        jump_from(50, 7);
        CHECK(!"longjmp returned");
    }
    CHECK(value == 7);
    CHECK(passes == 2);
    CHECK(deepest == 50);
    jmp_buf inner;
    volatile int seen = 0;
    if (setjmp(inner) == 0) {
        seen = 1;
        longjmp(inner, 0);
    } else {
        seen += 10;
    }
    /* longjmp with 0 comes back as 1 */
    CHECK(seen == 11);
    int nested = 0;
    for (int i = 0; i < 3; i++) {
        jmp_buf each;
        if (setjmp(each) == 0) {
            longjmp(each, i + 1);
        }
        nested++;
    }
    CHECK(nested == 3);
}

static void time_test(void) {
    time_t moment = 0;
    struct tm *broken = gmtime(&moment);
    CHECK(broken != NULL);
    CHECK(broken != NULL && broken->tm_year == 70 && broken->tm_mon == 0 && broken->tm_mday == 1 && broken->tm_wday == 4);
    moment = 951782400; /* 2000-02-29 */
    struct tm day;
    CHECK(gmtime_r(&moment, &day) != NULL && day.tm_year == 100 && day.tm_mon == 1 && day.tm_mday == 29);
    CHECK(day.tm_yday == 59 && day.tm_wday == 2);
    moment = -86400;
    CHECK(gmtime_r(&moment, &day) != NULL && day.tm_year == 69 && day.tm_mon == 11 && day.tm_mday == 31);
    struct tm made = {0};
    made.tm_year = 124;
    made.tm_mon = 0;
    made.tm_mday = 32;
    made.tm_hour = 25;
    time_t together = mktime(&made);
    CHECK(made.tm_mon == 1 && made.tm_mday == 2 && made.tm_hour == 1);
    CHECK(together == timegm(&made));
    moment = 1700000000;
    gmtime_r(&moment, &day);
    char text[64];
    CHECK(strftime(text, sizeof text, "%Y-%m-%d %H:%M:%S %a %b %j %%", &day) > 0);
    CHECK_TEXT(text, "2023-11-14 22:13:20 Tue Nov 318 %");
    CHECK(strftime(text, sizeof text, "%A %B %e %I %p %y %Z %u %V", &day) > 0);
    CHECK_TEXT(text, "Tuesday November 14 10 PM 23 UTC 2 46");
    CHECK(strftime(text, 4, "%Y-%m", &day) == 0);
    /* A conversion C hasn't is written as it is, its % and any modifier with it */
    CHECK(strftime(text, sizeof text, "%Q|%EQ|%Oq|%E", &day) > 0);
    CHECK_TEXT(text, "%Q|%EQ|%Oq|%E");
    CHECK_TEXT(asctime(&day), "Tue Nov 14 22:13:20 2023\n");
    CHECK(difftime(100, 40) == 60.0);
    clock_t first = clock();
    clock_t second = clock();
    CHECK(first >= 0 && second >= first);
    struct timespec now;
    CHECK(clock_gettime(CLOCK_MONOTONIC, &now) == 0 && now.tv_nsec >= 0 && now.tv_nsec < 1000000000);
    CHECK(clock_gettime(99, &now) == -1 && errno == EINVAL);
}

/* How many times the atexit handler ran: checked by nothing here, as it runs after main, but it mustn't crash. */
static void at_exit_handler(void) {
    fflush(stdout);
}

/* Where abort's handler goes back to, and the signal it was called with. */
static jmp_buf abort_back;
static int abort_signal;

/* A SIGABRT handler that doesn't return, so abort doesn't end the test. */
static void on_abort(int number) {
    abort_signal = number;
    longjmp(abort_back, 1);
}

static void environment_test(void) {
    CHECK(getenv("PATH") == NULL);
    CHECK(system(NULL) == 0);
    CHECK(strcmp(setlocale(LC_ALL, ""), "C") == 0 && setlocale(LC_ALL, "fr_FR") == NULL);
    CHECK(localeconv()->decimal_point[0] == '.');
    CHECK(atexit(at_exit_handler) == 0);
    CHECK(signal(SIGINT, SIG_IGN) == SIG_DFL && raise(SIGINT) == 0);
    /* abort raises SIGABRT, its handler reset to SIG_DFL first */
    CHECK(signal(SIGABRT, on_abort) == SIG_DFL);
    if (setjmp(abort_back) == 0) {
        abort();
    }
    CHECK(abort_signal == SIGABRT && signal(SIGABRT, SIG_DFL) == SIG_DFL);
    CHECK(getpid() == 1);
    char place[8];
    CHECK(getcwd(place, sizeof place) != NULL && strcmp(place, "/") == 0);
    CHECK(isatty(99) == 0 && errno == EBADF);
    CHECK(write(1, "", 0) == 0);
    CHECK(read(1, place, 1) == -1 && errno == EBADF);
    CHECK(lseek(1, 0, SEEK_SET) == -1 && errno == ESPIPE);
    CHECK(close(99) == -1 && errno == EBADF);
    CHECK(fputs("", stderr) == 0);
    CHECK(printf("%s", "") == 0);
}

/* The file test's directory, beneath the working directory. */
#define FOLDER "libc_check"

/* Read a whole file into text, at most size - 1 bytes: how many, or -1. */
static long read_whole(const char *path, char *text, size_t size) {
    FILE *file = fopen(path, "r");
    if (file == NULL) {
        return -1;
    }
    size_t got = fread(text, 1, size - 1, file);
    text[got] = '\0';
    fclose(file);
    return (long)got;
}

static void files_test(void) {
    char text[256];
    rmdir(FOLDER "/inner");
    remove(FOLDER "/streams.txt");
    remove(FOLDER "/renamed.txt");
    remove(FOLDER "/descriptors.bin");
    rmdir(FOLDER);
    CHECK(mkdir(FOLDER, 0755) == 0);
    CHECK(mkdir(FOLDER, 0755) == -1 && errno == EEXIST);
    FILE *file = fopen(FOLDER "/streams.txt", "w");
    if (file == NULL) {
        test_failures++;
        printf("FAIL files, line %d: fopen: %s\n", __LINE__, strerror(errno));
        return;
    }
    CHECK(fprintf(file, "line %d\n", 1) == 7);
    CHECK(fputs("line two\n", file) == 0);
    CHECK(fputc('3', file) == '3');
    CHECK(fclose(file) == 0);
    CHECK(read_whole(FOLDER "/streams.txt", text, sizeof text) == 17);
    CHECK_TEXT(text, "line 1\nline two\n3");
    file = fopen(FOLDER "/streams.txt", "r");
    CHECK(file != NULL && fgets(text, sizeof text, file) != NULL);
    CHECK_TEXT(text, "line 1\n");
    CHECK(fgets(text, 5, file) != NULL);
    CHECK_TEXT(text, "line");
    CHECK(ftell(file) == 11);
    CHECK(fseek(file, -1, SEEK_END) == 0 && fgetc(file) == '3' && fgetc(file) == EOF && feof(file));
    rewind(file);
    CHECK(!feof(file) && fgetc(file) == 'l');
    CHECK(ungetc('L', file) == 'L' && fgetc(file) == 'L' && fgetc(file) == 'i');
    CHECK(fseek(file, 5, SEEK_SET) == 0 && fgetc(file) == '1' && ftell(file) == 6);
    /* ungetc's bytes count in a seek from where the stream is, as in ftell, and in a flush */
    rewind(file);
    CHECK(fgetc(file) == 'l' && fgetc(file) == 'i' && fgetc(file) == 'n' && ungetc('N', file) == 'N');
    CHECK(ftell(file) == 2 && fseek(file, 0, SEEK_CUR) == 0 && ftell(file) == 2 && fgetc(file) == 'n');
    CHECK(ungetc('E', file) == 'E' && ungetc('N', file) == 'N' && fseek(file, 1, SEEK_CUR) == 0 && fgetc(file) == 'n');
    CHECK(ungetc('X', file) == 'X' && fflush(file) == 0 && ftell(file) == 2 && fgetc(file) == 'n');
    /* fflush(NULL) leaves a reading stream as it is: what it read ahead, and ungetc's byte */
    CHECK(ungetc('Y', file) == 'Y' && fflush(NULL) == 0 && ftell(file) == 2 && fgetc(file) == 'Y' && fgetc(file) == 'e');
    fclose(file);
    /* Appending starts at the end, before anything's written */
    file = fopen(FOLDER "/streams.txt", "a");
    CHECK(file != NULL && ftell(file) == 17);
    CHECK(file != NULL && fputs("\nappended", file) == 0 && ftell(file) == 26 && fclose(file) == 0);
    int appending = open(FOLDER "/streams.txt", O_WRONLY | O_APPEND);
    CHECK(appending >= 3 && lseek(appending, 0, SEEK_CUR) == 26 && close(appending) == 0);
    CHECK(read_whole(FOLDER "/streams.txt", text, sizeof text) == 26);
    CHECK_TEXT(text, "line 1\nline two\n3\nappended");
    file = fopen(FOLDER "/streams.txt", "r+");
    CHECK(file != NULL && fseek(file, 0, SEEK_SET) == 0 && fputs("LINE", file) == 0 && fclose(file) == 0);
    CHECK(read_whole(FOLDER "/streams.txt", text, sizeof text) == 26 && strncmp(text, "LINE 1\n", 7) == 0);
    CHECK(fopen(FOLDER "/missing.txt", "r") == NULL && errno == ENOENT);
    CHECK(fopen(FOLDER "/streams.txt", "wx") == NULL && errno == EEXIST);
    /* Reading back what a "w+" stream wrote, and a short fread at the end counting only whole items */
    file = fopen(FOLDER "/both.txt", "w+");
    CHECK(file != NULL);
    if (file != NULL) {
        CHECK(fputs("0123456789", file) == 0 && fseek(file, 0, SEEK_SET) == 0 && fgets(text, sizeof text, file) != NULL);
        CHECK_TEXT(text, "0123456789");
        rewind(file);
        char items[12] = {0};
        CHECK(fread(items, 4, 3, file) == 2 && feof(file) && !ferror(file) && memcmp(items, "0123456789", 10) == 0);
        clearerr(file);
        CHECK(fseek(file, 8, SEEK_SET) == 0 && fread(items, 1, 5, file) == 2 && feof(file));
        CHECK(fread(items, 1, 5, file) == 0 && fclose(file) == 0);
    }
    /* A read error during fgets is NULL, even with a byte read: here a stream that only writes, a byte pushed back */
    file = fopen(FOLDER "/both.txt", "w");
    CHECK(file != NULL);
    if (file != NULL) {
        CHECK(ungetc('x', file) == 'x' && fgets(text, sizeof text, file) == NULL && ferror(file));
        CHECK(fclose(file) == 0);
    }
    CHECK(fdopen(99, "r") == NULL && errno == EBADF);
    CHECK(remove(FOLDER "/both.txt") == 0);
    int fd = open(FOLDER "/descriptors.bin", O_RDWR | O_CREAT | O_TRUNC, 0644);
    CHECK(fd >= 3);
    unsigned char bytes[300];
    for (int i = 0; i < 300; i++) {
        bytes[i] = (unsigned char)i;
    }
    CHECK(write(fd, bytes, sizeof bytes) == 300);
    CHECK(lseek(fd, 0, SEEK_CUR) == 300 && lseek(fd, 0, SEEK_END) == 300);
    CHECK(lseek(fd, 100, SEEK_SET) == 100);
    unsigned char back[10];
    CHECK(read(fd, back, sizeof back) == 10 && back[0] == 100 && back[9] == 109);
    CHECK(lseek(fd, -5, SEEK_END) == 295 && read(fd, back, sizeof back) == 5 && back[4] == (unsigned char)299);
    CHECK(read(fd, back, sizeof back) == 0);
    struct stat described;
    CHECK(fstat(fd, &described) == 0 && described.st_size == 300 && S_ISREG(described.st_mode));
    CHECK(ftruncate(fd, 50) == 0 && fstat(fd, &described) == 0 && described.st_size == 50);
    CHECK(lseek(fd, -1, SEEK_SET) == -1 && errno == EINVAL);
    CHECK(close(fd) == 0 && close(fd) == -1 && errno == EBADF);
    CHECK(stat(FOLDER "/descriptors.bin", &described) == 0 && described.st_size == 50);
    CHECK(stat(FOLDER, &described) == 0 && S_ISDIR(described.st_mode));
    CHECK(stat("./" FOLDER "//inner/../descriptors.bin", &described) == 0 && described.st_size == 50);
    CHECK(stat(FOLDER "/missing", &described) == -1 && errno == ENOENT);
    CHECK(access(FOLDER "/descriptors.bin", R_OK) == 0 && access(FOLDER "/nothing", F_OK) == -1);
    CHECK(rename(FOLDER "/streams.txt", FOLDER "/renamed.txt") == 0);
    CHECK(access(FOLDER "/streams.txt", F_OK) == -1 && access(FOLDER "/renamed.txt", F_OK) == 0);
    /* Renaming over a file replaces it */
    file = fopen(FOLDER "/replacing.txt", "w");
    CHECK(file != NULL && fputs("new", file) == 0 && fclose(file) == 0);
    file = fopen(FOLDER "/replaced.txt", "w");
    CHECK(file != NULL && fputs("old and longer", file) == 0 && fclose(file) == 0);
    CHECK(rename(FOLDER "/replacing.txt", FOLDER "/replaced.txt") == 0 && access(FOLDER "/replacing.txt", F_OK) == -1);
    CHECK(read_whole(FOLDER "/replaced.txt", text, sizeof text) == 3);
    CHECK_TEXT(text, "new");
    /*
     * Unlinking an open file takes its name away at once, and the file stays, as POSIX's does, for as long as it's
     * open: SlopOS keeps it as an orphan, which a volume server sweeps once nothing has it open (decisions/0089, 8d2).
     */
    fd = open(FOLDER "/replaced.txt", O_RDWR);
    CHECK(fd >= 3);
    if (fd >= 3) {
        CHECK(unlink(FOLDER "/replaced.txt") == 0 && access(FOLDER "/replaced.txt", F_OK) == -1);
        CHECK(read(fd, text, 3) == 3 && memcmp(text, "new", 3) == 0);
        CHECK(write(fd, "er", 2) == 2 && lseek(fd, 0, SEEK_SET) == 0 && read(fd, text, 10) == 5);
        CHECK(memcmp(text, "newer", 5) == 0 && fstat(fd, &described) == 0 && described.st_size == 5);
        CHECK(close(fd) == 0 && access(FOLDER "/replaced.txt", F_OK) == -1);
    }
    CHECK(mkdir(FOLDER "/inner", 0755) == 0);
    DIR *directory = opendir(FOLDER);
    CHECK(directory != NULL);
    int names = 0;
    int saw_inner = 0;
    int saw_renamed = 0;
    for (struct dirent *entry = directory ? readdir(directory) : NULL; entry != NULL; entry = readdir(directory)) {
        names++;
        saw_inner |= strcmp(entry->d_name, "inner") == 0 && entry->d_type == DT_DIR;
        saw_renamed |= strcmp(entry->d_name, "renamed.txt") == 0 && entry->d_type == DT_REG;
    }
    CHECK(names == 3 && saw_inner && saw_renamed);
    if (directory != NULL) {
        rewinddir(directory);
        CHECK(readdir(directory) != NULL);
        CHECK(closedir(directory) == 0);
    }
    CHECK(opendir(FOLDER "/renamed.txt") == NULL);
    CHECK(rmdir(FOLDER) == -1 && errno == ENOTEMPTY);
    CHECK(unlink(FOLDER "/inner") == -1 && errno == EISDIR);
    CHECK(remove(FOLDER "/inner") == 0);
    CHECK(unlink(FOLDER "/descriptors.bin") == 0 && unlink(FOLDER "/descriptors.bin") == -1 && errno == ENOENT);
    CHECK(remove(FOLDER "/renamed.txt") == 0);
    CHECK(rmdir(FOLDER) == 0 && access(FOLDER, F_OK) == -1);
    /* One left for the C tool's boot test to count: 3 lines, 6 words, 28 bytes */
    file = fopen("libc_words.txt", "w");
    CHECK(file != NULL && fputs("one two three\nfour five\nsix\n", file) == 0 && fclose(file) == 0);
}

/* A test: its name and what runs it. */
struct test {
    const char *name;
    void (*run)(void);
};

int main(int argc, char **argv) {
    /* Given --exit=-1, it only exits with -1, which the program's exit status is 255 of, as POSIX's */
    if (argc == 2 && strcmp(argv[1], "--exit=-1") == 0) {
        exit(-1);
    }
    static const struct test TESTS[] = {
        {"strings", strings_test},     {"characters", characters_test}, {"formatting", formatting_test},
        {"memory", memory_test},       {"sorting", sorting_test},       {"numbers", numbers_test},
        {"math", math_test},           {"jumps", jumps_test},           {"time", time_test},
        {"environment", environment_test},
    };
    int count = (int)(sizeof TESTS / sizeof TESTS[0]);
    int failed = 0;
    for (int i = 0; i < count; i++) {
        test_name = TESTS[i].name;
        test_failures = 0;
        TESTS[i].run();
        failed += test_failures > 0;
    }
    /* Files only beneath a working directory, which a program the root task runs hasn't */
    int skipped = 0;
    struct stat here;
    if (stat("/", &here) == 0) {
        test_name = "files";
        test_failures = 0;
        files_test();
        failed += test_failures > 0;
    } else {
        skipped = 1;
    }
    int total = count + 1;
    if (skipped > 0) {
        printf("%d tests: %d passed, %d failed, %d skipped\n", total, total - failed - skipped, failed, skipped);
    } else {
        printf("%d tests: %d passed, %d failed\n", total, total - failed, failed);
    }
    return failed;
}
