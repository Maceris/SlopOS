/**
 * greeting (roadmap 9e1, decisions/0119, 0120): a small typed library for testing libraries on SlopOS, which
 * test_libraries calls through its exports, bound before its main.
 */
package greeting

import runtime from "base"

/**
 * Add two integers, through the library, for a test that an export's call and result cross it.
 *
 * @param a One integer.
 * @param b The other integer, any value.
 * @return Their sum, wrapping as int's does.
 */
add #export :: fn(a: int, b: int) -> int {
    return a + b
}

/**
 * Repeat text, made with the caller's context, which allocates it, for a test that the context crosses the library.
 *
 * @param text The text repeated, which isn't kept.
 * @param times How many times; 0 or fewer gives empty text.
 * @return text that many times over, from the caller's context's allocator, the caller's to free.
 */
repeat #export :: fn(text: string, times: int) -> string {
    bytes : u8[..]
    for i in 0..<times {
        for byte in string_bytes(text) {
            runtime.array_add(&bytes, byte)
        }
    }
    return bit_cast[string](bytes[0..<bytes.count])
}

/**
 * Give a constant from the library's data, for a test that its relocations point to it.
 *
 * @return "hello from a library", static text in the library, good while it's loaded.
 */
greeting #export :: fn() -> string {
    return "hello from a library"
}
