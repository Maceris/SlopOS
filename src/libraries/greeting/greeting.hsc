/**
 * greeting (roadmap 9e1, decisions/0119, 0120): a small typed library for testing libraries on SlopOS, which
 * test_libraries calls through its exports, bound before its main.
 */
package greeting

import runtime from "base"

/** A sum, through the library */
add #export :: fn(a: int, b: int) -> int {
    return a + b
}

/** Text made with the caller's context, which allocates it */
repeat #export :: fn(text: string, times: int) -> string {
    bytes : u8[..]
    for i in 0..<times {
        for byte in string_bytes(text) {
            runtime.array_add(&bytes, byte)
        }
    }
    return bit_cast[string](bytes[0..<bytes.count])
}

/** A constant from the library's data, which its relocations point to */
greeting #export :: fn() -> string {
    return "hello from a library"
}
