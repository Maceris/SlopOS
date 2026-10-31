/*
 * greeting, changed (roadmap 9e1, decisions/0120): greeting's exports with add's type not the same, which the root
 * task gives test_libraries in greeting's place with test_changed_library, so its runtime refuses to bind it.
 */
package greeting_changed

import runtime from "base"

// A sum of other types than greeting's
add #export :: fn(a: i32, b: i32) -> i32 {
    return a + b
}

repeat #export :: fn(text: string, times: int) -> string {
    bytes : u8[..]
    for i in 0..<times {
        for byte in string_bytes(text) {
            runtime.array_add(&bytes, byte)
        }
    }
    return bit_cast[string](bytes[0..<bytes.count])
}

greeting #export :: fn() -> string {
    return "hello from a changed library"
}
