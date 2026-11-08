/**
 * test_debug (decisions/0185, 12e): a program for the debugger's lines and values. It makes a struct, an optional, a
 * union and a view, reads each through a volatile load so the optimizer keeps them in memory where the DWARF says,
 * and then adds what it read, on the line the boot test breaks at by its file and line, and prints them from there.
 * Given a crash, it writes through a bad pointer instead, for a crash report with lines.
 */
package test_debug

import intrinsics from "base"
import runtime from "base"

/** A struct the debugger shows with its members. */
Point :: struct {
    /** Across. */
    x : i32,
    /** Down. */
    y : i32,
    /** What it's called. */
    label : string,
}

/** A union the debugger shows by its variant. */
Shape :: union {
    /** A circle of a radius. */
    Circle(u32),
    /** A box of a width and a height. */
    Box(u32, u32),
    /** Nothing. */
    Empty,
}

/**
 * Make the values, keep them in memory, and end with 0.
 *
 * @param crash Any number to crash instead, writing through a bad pointer; none to make the values.
 * @return 0, or 1 if what was read was nothing, which can't be.
 */
main :: fn(crash: u64?) -> int {
    if crash is_some {
        write_through(cast[ptr[u64]](cast[uintptr](8)))
    }
    point := Point.{x = 3, y = -4, label = "corner"}
    maybe : u32? = 7
    shape := Shape.Box(2, 5)
    // On the heap, as a view of the stack can't be read through a pointer cast
    numbers, failed :: runtime.new_array(u64, 3)
    if failed != null {
        return 1
    }
    defer runtime.free_array(numbers)
    for &number, i in numbers {
        number^ = cast[u64](i + 1) * 10
    }
    view := numbers
    // Every word of each read through memory, so all of each stays there, where the debugger reads it
    read := words_of(cast[ptr[u64]](&point), 3)
    read += words_of(cast[ptr[u64]](&maybe), 1)
    read += words_of(cast[ptr[u64]](&shape), 1) + cast[u64](intrinsics.volatile_load_u32(cast[ptr[u32]](cast[uintptr](&shape) + 8)))
    read += words_of(cast[ptr[u64]](&view), 2)
    return if read == 0 { 1 } else { 0 } // test_debug's breakpoint line, BREAK_LINE in boot_tests.py
}

/**
 * Add up words through volatile loads, so what holds them stays in memory.
 *
 * @param first The first word.
 * @param count How many words, one after another.
 * @return Their sum.
 */
words_of :: fn(first: ptr[u64], count: usize) -> u64 {
    sum : u64 = 0
    for i in cast[usize](0)..<count {
        sum += intrinsics.volatile_load_u64(cast[ptr[u64]](cast[uintptr](first) + cast[uintptr](i * 8)))
    }
    return sum
}

/**
 * Write through a pointer, volatile, so the write is where its line is.
 *
 * @param target Where it writes: a bad address, for a crash.
 */
write_through :: fn(target: ptr[u64]) {
    intrinsics.volatile_store_u64(cast[ptr[mut u64]](target), 1) // TEST_DEBUG_CRASH_LINE in boot_tests.py
}
