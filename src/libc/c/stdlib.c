/*
 * stdlib.c, SlopOS's libc (decisions/0201, 20l): sorting and searching, whose comparisons are C's own functions, so
 * they're called from C and never cross into Hemera; random numbers, whose state is C's; and the div family, which
 * give structs.
 */
#include <stdint.h>
#include <stdlib.h>

/* Swap two items of size bytes. */
static void swap_items(unsigned char *a, unsigned char *b, size_t size) {
    for (size_t i = 0; i < size; i++) {
        unsigned char kept = a[i];
        a[i] = b[i];
        b[i] = kept;
    }
}

/* Sift the item at root down the heap of count items, so it's above both its children. */
static void sift_down(unsigned char *items, size_t root, size_t count, size_t size,
                      int (*compare)(const void *, const void *)) {
    for (;;) {
        size_t child = 2 * root + 1;
        if (child >= count) {
            return;
        }
        if (child + 1 < count && compare(items + child * size, items + (child + 1) * size) < 0) {
            child++;
        }
        if (compare(items + root * size, items + child * size) >= 0) {
            return;
        }
        swap_items(items + root * size, items + child * size, size);
        root = child;
    }
}

/*
 * Sort by heapsort: n log n comparisons at most whatever the order, and no recursion, so no stack to run out of. It
 * isn't stable, which C doesn't ask of qsort.
 */
void qsort(void *base, size_t count, size_t size, int (*compare)(const void *, const void *)) {
    unsigned char *items = base;
    if (count < 2 || size == 0) {
        return;
    }
    for (size_t root = count / 2; root-- > 0;) {
        sift_down(items, root, count, size, compare);
    }
    for (size_t end = count - 1; end > 0; end--) {
        swap_items(items, items + end * size, size);
        sift_down(items, 0, end, size, compare);
    }
}

void *bsearch(const void *key, const void *base, size_t count, size_t size, int (*compare)(const void *, const void *)) {
    const unsigned char *items = base;
    size_t low = 0;
    size_t high = count;
    while (low < high) {
        size_t middle = low + (high - low) / 2;
        const void *item = items + middle * size;
        int order = compare(key, item);
        if (order == 0) {
            return (void *)item;
        }
        if (order < 0) {
            high = middle;
        } else {
            low = middle + 1;
        }
    }
    return NULL;
}

/* rand's state: a 64-bit linear congruential generator's, seeded 1 as C says until srand. */
static uint64_t random_state = 1;

int rand(void) {
    random_state = random_state * 6364136223846793005u + 1442695040888963407u;
    /* The high bits are the generator's best */
    return (int)(random_state >> 33);
}

void srand(unsigned int seed) {
    random_state = seed;
}

div_t div(int numerator, int denominator) {
    div_t result = {numerator / denominator, numerator % denominator};
    return result;
}

ldiv_t ldiv(long numerator, long denominator) {
    ldiv_t result = {numerator / denominator, numerator % denominator};
    return result;
}

lldiv_t lldiv(long long numerator, long long denominator) {
    lldiv_t result = {numerator / denominator, numerator % denominator};
    return result;
}
