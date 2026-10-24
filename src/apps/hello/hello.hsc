package hello

import runtime from "base"

/*
 * The first SlopOS program (roadmap M6): it fills memory from its heap and ends with a code that says
 * whether the heap worked, 0 if it did.
 */
main :: fn() -> int {
    values, error :: runtime.new_array(u64, 1000)
    if error != null {
        return 1
    }
    defer runtime.free_array(values)
    for &value, i in values {
        value^ = cast[u64](i) * 3
    }
    total : u64 = 0
    for value in values {
        total += value
    }
    // 3 × (0 + 1 + ... + 999)
    return if total == 1498500 { 0 } else { 2 }
}
