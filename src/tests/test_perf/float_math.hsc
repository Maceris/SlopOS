package test_perf

import intrinsics from "base"
import math from "std"
import slop_os from "std/os"
import fast from "std/math"
import testing from "std"
import test_kit from "../../test_kit"

/*
 * Float math's tiers (decisions/0190), each "perf: math_<function>_<tier> <nanoseconds>" for a thousand values from
 * -10 to 10, as a renderer's shading gives them: std/math's f32 one at a time (f32), eight at a time (f32x8),
 * std/math/fast's eight at a time (fast_f32x8), and the same in f64 with four lanes (f64, f64x4, fast_f64x4). Under
 * -icount they're instruction counts, which only arithmetic moves: each tier runs once before it's measured, so its
 * code's pages are touched and their faults aren't counted.
 */

/** How many values each tier is measured on. */
MATH_VALUES :: 1024

/** The values: -10 to 10, none 0, so log takes their magnitudes. */
math_values :: fn() -> f32[MATH_VALUES] {
    values : f32[MATH_VALUES]
    for &value, i in values {
        value^ = (cast[f32](i) - 511.5) / 51.2
    }
    return values
}

/** Keep a result from being left out as unused. */
keep :: fn(value: f64) {
    sink := value
    intrinsics.volatile_store_u64(cast[ptr[mut u64]](&sink), bit_cast[u64](value))
}

/**
 * Time a function of f32 one value at a time, and log it.
 *
 * @param log The debug log the line goes to.
 * @param name The line's name.
 * @param values The arguments.
 * @param function The function.
 */
time_f32 :: fn(log: slop_os.DebugLog, name: string, values: ptr[f32[MATH_VALUES]], function: (fn(x: f32) -> f32)) {
    sum := 0.0
    for value in values^ {
        sum += cast[f64](function(value))
    }
    start :: test_kit.clock_now()
    for value in values^ {
        sum += cast[f64](function(value))
    }
    took :: test_kit.clock_now() - start
    keep(sum)
    report(log, name, took * 1000 / MATH_VALUES)
}

/** The same eight at a time. */
time_f32x8 :: fn(log: slop_os.DebugLog, name: string, values: ptr[f32[MATH_VALUES]],
    function: (fn(x: vector[f32, 8]) -> vector[f32, 8])) {

    sum := 0.0
    start := test_kit.clock_now()
    for pass in 0..<2 {
        if pass == 1 {
            start = test_kit.clock_now()
        }
        for i in 0..<MATH_VALUES / 8 {
            results :: bit_cast[f32[8]](function(bit_cast[vector[f32, 8]](cast[ptr[f32[8]]](&values[i * 8])^)))
            sum += cast[f64](results[0] + results[7])
        }
    }
    took :: test_kit.clock_now() - start
    keep(sum)
    report(log, name, took * 1000 / MATH_VALUES)
}

/** The same in f64, one value at a time. */
time_f64 :: fn(log: slop_os.DebugLog, name: string, values: ptr[f32[MATH_VALUES]], function: (fn(x: f64) -> f64)) {
    sum := 0.0
    for value in values^ {
        sum += function(cast[f64](value))
    }
    start :: test_kit.clock_now()
    for value in values^ {
        sum += function(cast[f64](value))
    }
    took :: test_kit.clock_now() - start
    keep(sum)
    report(log, name, took * 1000 / MATH_VALUES)
}

/** The same in f64, four at a time. */
time_f64x4 :: fn(log: slop_os.DebugLog, name: string, values: ptr[f32[MATH_VALUES]],
    function: (fn(x: vector[f64, 4]) -> vector[f64, 4])) {

    sum := 0.0
    start := test_kit.clock_now()
    for pass in 0..<2 {
        if pass == 1 {
            start = test_kit.clock_now()
        }
        for i in 0..<MATH_VALUES / 4 {
            narrow :: bit_cast[vector[f32, 4]](cast[ptr[f32[4]]](&values[i * 4])^)
            results :: bit_cast[f64[4]](function(cast[vector[f64, 4]](narrow)))
            sum += results[0] + results[3]
        }
    }
    took :: test_kit.clock_now() - start
    keep(sum)
    report(log, name, took * 1000 / MATH_VALUES)
}

/* log on the values' magnitudes, in each tier */
log_f32 :: fn(x: f32) -> f32 { return math.log(abs(x)) }
log_f32x8 :: fn(x: vector[f32, 8]) -> vector[f32, 8] {
    return math.log(bit_cast[vector[f32, 8]](bit_cast[vector[u32, 8]](x) & 0x7fff_ffff))
}
fast_log_f32x8 :: fn(x: vector[f32, 8]) -> vector[f32, 8] {
    return fast.log(bit_cast[vector[f32, 8]](bit_cast[vector[u32, 8]](x) & 0x7fff_ffff))
}
log_f64 :: fn(x: f64) -> f64 { return math.log(abs(x)) }
log_f64x4 :: fn(x: vector[f64, 4]) -> vector[f64, 4] {
    return math.log(bit_cast[vector[f64, 4]](bit_cast[vector[u64, 4]](x) & 0x7fff_ffff_ffff_ffff))
}
fast_log_f64x4 :: fn(x: vector[f64, 4]) -> vector[f64, 4] {
    return fast.log(bit_cast[vector[f64, 4]](bit_cast[vector[u64, 4]](x) & 0x7fff_ffff_ffff_ffff))
}

/**
 * Measure sin, exp and log in each of float math's tiers, and log each as "perf: math_<function>_<tier> <nanoseconds>"
 * for a thousand values.
 *
 * @param t The test's state.
 * @return Ok once they're measured and logged.
 */
float_math_is_measured #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    given :: test_kit.given(t, Given)?
    values := math_values()
    time_f32(given.log, "math_sin_f32", &values, math.sin[f32])
    time_f32x8(given.log, "math_sin_f32x8", &values, math.sin[vector[f32, 8]])
    time_f32x8(given.log, "math_sin_fast_f32x8", &values, fast.sin[vector[f32, 8]])
    time_f64(given.log, "math_sin_f64", &values, math.sin[f64])
    time_f64x4(given.log, "math_sin_f64x4", &values, math.sin[vector[f64, 4]])
    time_f64x4(given.log, "math_sin_fast_f64x4", &values, fast.sin[vector[f64, 4]])
    time_f32(given.log, "math_exp_f32", &values, math.exp[f32])
    time_f32x8(given.log, "math_exp_f32x8", &values, math.exp[vector[f32, 8]])
    time_f32x8(given.log, "math_exp_fast_f32x8", &values, fast.exp[vector[f32, 8]])
    time_f64(given.log, "math_exp_f64", &values, math.exp[f64])
    time_f64x4(given.log, "math_exp_f64x4", &values, math.exp[vector[f64, 4]])
    time_f64x4(given.log, "math_exp_fast_f64x4", &values, fast.exp[vector[f64, 4]])
    time_f32(given.log, "math_log_f32", &values, log_f32)
    time_f32x8(given.log, "math_log_f32x8", &values, log_f32x8)
    time_f32x8(given.log, "math_log_fast_f32x8", &values, fast_log_f32x8)
    time_f64(given.log, "math_log_f64", &values, log_f64)
    time_f64x4(given.log, "math_log_f64x4", &values, log_f64x4)
    time_f64x4(given.log, "math_log_fast_f64x4", &values, fast_log_f64x4)
    return .Ok
}
