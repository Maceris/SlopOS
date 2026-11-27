/*
 * assert.h, SlopOS's libc (decisions/0201, 20l): assert, which says what failed and where on stderr, then aborts;
 * nothing with NDEBUG. Included again, it's defined again by NDEBUG then, as C says.
 */
#undef assert

#ifdef __cplusplus
extern "C" {
#endif

__attribute__((noreturn)) void __libc_assert_failed(const char *expression, const char *file, int line, const char *function);

#ifdef __cplusplus
}
#endif

#ifdef NDEBUG
#define assert(expression) ((void)0)
#else
#define assert(expression) ((expression) ? (void)0 : __libc_assert_failed(#expression, __FILE__, __LINE__, __func__))
#endif

#ifndef static_assert
#define static_assert _Static_assert
#endif
