/*
 * test_callbacks's C (decisions/0201, 20k): a sort that calls back into Hemera for each comparison, as qsort does,
 * with the carrier register spoiled first, as C may use it for its own (it's callee-saved, so only kept across C's
 * own calls), so the callback's shim has to find its carrier block itself. Built freestanding by a stock clang.
 */
#include <stddef.h>
#include <stdint.h>

/* What a comparison is given: two items and the caller's data; below 0, 0 or above for less, equal or more. */
typedef int (*compare_items)(const int64_t *a, const int64_t *b, void *data);

/* Overwrite the register Hemera keeps its carrier block in, which C needn't keep while it runs. */
static inline void spoil_carrier(void) {
#if defined(__x86_64__)
    __asm__ volatile("movq $0x5555, %%r14" ::: "r14");
#elif defined(__aarch64__)
    __asm__ volatile("mov x28, #0x5555" ::: "x28");
#elif defined(__riscv)
    __asm__ volatile("li s11, 0x5555" ::: "s11");
#endif
}

/*
 * Sort count items in place by insertion, calling compare for each comparison, with data; gives how many comparisons
 * were made.
 */
size_t sort_items(int64_t *items, size_t count, compare_items compare, void *data) {
    size_t comparisons = 0;
    for (size_t i = 1; i < count; i++) {
        int64_t item = items[i];
        size_t at = i;
        while (at > 0) {
            spoil_carrier();
            comparisons++;
            if (compare(&items[at - 1], &item, data) <= 0) {
                break;
            }
            items[at] = items[at - 1];
            at--;
        }
        items[at] = item;
    }
    return comparisons;
}
