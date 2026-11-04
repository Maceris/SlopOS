/**
 * greeting, changed (roadmap 9e1, decisions/0120): greeting's exports with add's type not the same, which the root
 * task gives test_libraries in greeting's place with test_changed_library, so its runtime refuses to bind it.
 */
package greeting_changed

import runtime from "base"

/**
 * Add two integers, of other types than greeting's add takes, so the export's type isn't greeting's.
 *
 * @param a One integer, an i32 where greeting's is an int.
 * @param b The other, an i32.
 * @return Their sum, wrapping as i32's does.
 */
add #export :: fn(a: i32, b: i32) -> i32 {
    return a + b
}

/**
 * Repeat text, made with the caller's context, which allocates it, as greeting's repeat does.
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
 * Give a constant from the library's data, as greeting's greeting does, with other words.
 *
 * @return "hello from a changed library", static text in the library, good while it's loaded.
 */
greeting #export :: fn() -> string {
    return "hello from a changed library"
}
