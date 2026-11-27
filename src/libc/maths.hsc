package libc

/*
 * math.h (decisions/0201, 20l): C's math functions over base's rounding instructions, which are exact and need no
 * context, and std's math for the rest, within an ulp or two of the exact result. A domain error gives NaN and an
 * overflow ±infinity, as IEEE 754 says; errno isn't set, as math_errhandling is MATH_ERREXCEPT. The float forms work
 * in double and round once at the end where std's do.
 */

import intrinsics from "base:intrinsics"
import math from "std:math"

/**
 * Give a double's magnitude.
 *
 * @param x The double.
 * @return x without its sign: +0 for -0, +infinity for -infinity, a NaN for a NaN.
 */
fabs #export #calling_convention(.c) #no_context :: fn(x : f64) -> f64 {
    return intrinsics.copy_sign(x, 1.0)
}

/**
 * Round a double down to a whole number.
 *
 * @param x The double.
 * @return The greatest whole number not above x; x itself for ±0, ±infinity and NaN.
 */
floor #export #calling_convention(.c) #no_context :: fn(x : f64) -> f64 {
    return intrinsics.floor(x)
}

/**
 * Round a double up to a whole number.
 *
 * @param x The double.
 * @return The least whole number not below x; x itself for ±0, ±infinity and NaN.
 */
ceil #export #calling_convention(.c) #no_context :: fn(x : f64) -> f64 {
    return intrinsics.ceil(x)
}

/**
 * Round a double toward zero to a whole number.
 *
 * @param x The double.
 * @return x without its fraction, of x's sign; x itself for ±0, ±infinity and NaN.
 */
trunc #export #calling_convention(.c) #no_context :: fn(x : f64) -> f64 {
    return intrinsics.trunc(x)
}

/**
 * Round a double to the nearest whole number, halfway away from zero.
 *
 * @param x The double.
 * @return The nearest whole number, 2.5 giving 3 and -2.5 giving -3; x itself for ±0, ±infinity and NaN.
 */
round #export #calling_convention(.c) #no_context :: fn(x : f64) -> f64 {
    whole :: intrinsics.trunc(x)
    // The fraction is exact, so 0.49999999999999994 stays below a half
    if intrinsics.copy_sign(x - whole, 1.0) >= 0.5 {
        return whole + intrinsics.copy_sign(1.0, x)
    }
    return whole
}

/**
 * Round a double to the nearest whole number, halfway to even, as the current rounding mode, the only one, does.
 *
 * @param x The double.
 * @return The nearest whole number, 2.5 giving 2; x itself for ±0, ±infinity and NaN.
 */
rint #export #calling_convention(.c) #no_context :: fn(x : f64) -> f64 {
    return intrinsics.round_even(x)
}

/**
 * Round a double as rint does, without raising inexact.
 *
 * @param x The double.
 * @return As rint's.
 */
nearbyint #export #calling_convention(.c) #no_context :: fn(x : f64) -> f64 {
    return intrinsics.round_even(x)
}

/**
 * Round a double as round does, to a long.
 *
 * @param x The double, whose rounding fits in a long.
 * @return The rounding; for a NaN or one that doesn't fit, whatever the conversion gives.
 */
lround #export #calling_convention(.c) #no_context :: fn(x : f64) -> i64 {
    return cast[i64](round(x))
}

/**
 * Round a double as round does, to a long long.
 *
 * @param x The double, whose rounding fits in a long long.
 * @return As lround's.
 */
llround #export #calling_convention(.c) #no_context :: fn(x : f64) -> i64 {
    return cast[i64](round(x))
}

/**
 * Round a double as rint does, to a long.
 *
 * @param x The double, whose rounding fits in a long.
 * @return As lround's, halfway to even.
 */
lrint #export #calling_convention(.c) #no_context :: fn(x : f64) -> i64 {
    return cast[i64](intrinsics.round_even(x))
}

/**
 * Give a double's square root, correctly rounded.
 *
 * @param x The double.
 * @return √x; -0 for -0; NaN below 0.
 */
sqrt #export #calling_convention(.c) #no_context :: fn(x : f64) -> f64 {
    return intrinsics.square_root(x)
}

/**
 * Multiply and add, rounding once.
 *
 * @param x One factor.
 * @param y The other.
 * @param z What's added.
 * @return x × y + z, rounded once.
 */
fma #export #calling_convention(.c) #no_context :: fn(x : f64, y : f64, z : f64) -> f64 {
    return intrinsics.fused_multiply_add(x, y, z)
}

/**
 * Give a double's magnitude with another's sign.
 *
 * @param magnitude Where all but the sign come from.
 * @param sign Where the sign comes from.
 * @return magnitude with sign's sign bit.
 */
copysign #export #calling_convention(.c) #no_context :: fn(magnitude : f64, sign : f64) -> f64 {
    return intrinsics.copy_sign(magnitude, sign)
}

/**
 * Give the lesser of two doubles, C's way: a NaN loses to a number.
 *
 * @param x One double.
 * @param y The other.
 * @return The lesser; the other when one is a NaN; a NaN only if both are.
 */
fmin #export #calling_convention(.c) #no_context :: fn(x : f64, y : f64) -> f64 {
    if x != x {
        return y
    }
    if y != y {
        return x
    }
    return intrinsics.minimum(x, y)
}

/**
 * Give the greater of two doubles, C's way: a NaN loses to a number.
 *
 * @param x One double.
 * @param y The other.
 * @return The greater; the other when one is a NaN; a NaN only if both are.
 */
fmax #export #calling_convention(.c) #no_context :: fn(x : f64, y : f64) -> f64 {
    if x != x {
        return y
    }
    if y != y {
        return x
    }
    return intrinsics.maximum(x, y)
}

/**
 * Give how far one double is above another, or 0.
 *
 * @param x One double.
 * @param y The other.
 * @return x - y when x > y; +0 when it isn't; NaN if either is.
 */
fdim #export #calling_convention(.c) #no_context :: fn(x : f64, y : f64) -> f64 {
    if x != x || y != y {
        return x + y
    }
    return if x > y { x - y } else { 0.0 }
}

/**
 * Give the remainder of a division whose quotient is cut toward zero.
 *
 * @param x The dividend.
 * @param y The divisor.
 * @return x - n × y, n the quotient cut to a whole number: of x's sign, below |y|; NaN for a y of 0 or an infinite x.
 */
fmod #export #calling_convention(.c) :: fn(x : f64, y : f64) -> f64 {
    return math.truncated_remainder(x, y)
}

/**
 * Give IEEE 754's remainder, the quotient rounded to nearest, halfway to even.
 *
 * @param x The dividend.
 * @param y The divisor.
 * @return x - n × y, at most |y| / 2; NaN for a y of 0 or an infinite x.
 */
remainder #export #calling_convention(.c) :: fn(x : f64, y : f64) -> f64 {
    return math.remainder(x, y)
}

/**
 * Split a double into its whole part and its fraction, both of its sign.
 *
 * @param x The double.
 * @param whole Where the whole part goes: trunc(x).
 * @return The fraction, x - trunc(x); ±0 for ±infinity, whose whole part is itself; NaN for NaN, whole a NaN too.
 */
modf #export #calling_convention(.c) #no_context :: fn(x : f64, whole : ptr[mut f64]) -> f64 {
    cut :: intrinsics.trunc(x)
    whole^ = cut
    if x - x != 0.0 && x == x {
        // ±infinity: no fraction
        return intrinsics.copy_sign(0.0, x)
    }
    return intrinsics.copy_sign(x - cut, x)
}

/**
 * Split a double into a fraction from 1/2 to 1 and a power of two.
 *
 * @param x The double.
 * @param exponent Where the power goes: e with x = f × 2^e; 0 for ±0, ±infinity and NaN.
 * @return f, of x's sign; x itself for ±0, ±infinity and NaN.
 */
frexp #export #calling_convention(.c) :: fn(x : f64, exponent : ptr[mut i32]) -> f64 {
    fraction, power :: math.fraction_and_exponent(x)
    exponent^ = power
    return fraction
}

/**
 * Multiply a double by a power of two.
 *
 * @param x The double.
 * @param exponent The power of two.
 * @return x × 2^exponent, rounded once; ±infinity past the largest, ±0 below the least.
 */
ldexp #export #calling_convention(.c) :: fn(x : f64, exponent : i32) -> f64 {
    return math.scale_by_power_of_two(x, exponent)
}

/**
 * Multiply a double by a power of two, as ldexp does.
 *
 * @param x The double.
 * @param exponent The power of two.
 * @return As ldexp's.
 */
scalbn #export #calling_convention(.c) :: fn(x : f64, exponent : i32) -> f64 {
    return math.scale_by_power_of_two(x, exponent)
}

/**
 * Give a double's binary exponent, as an int.
 *
 * @param x The double.
 * @return e with 1 <= |x| / 2^e < 2; INT_MIN for 0, as Linux's FP_ILOGB0, and INT_MAX for ±infinity and NaN, as
 *     its FP_ILOGBNAN.
 */
ilogb #export #calling_convention(.c) :: fn(x : f64) -> i32 {
    if x == 0.0 {
        return -2147483647 - 1
    }
    if x - x != 0.0 {
        return 2147483647
    }
    fraction, power :: math.fraction_and_exponent(x)
    return power - 1
}

/**
 * Give a double's binary exponent, as a double.
 *
 * @param x The double.
 * @return e as ilogb gives it; -infinity for 0, +infinity for ±infinity, NaN for NaN.
 */
logb #export #calling_convention(.c) :: fn(x : f64) -> f64 {
    if x == 0.0 {
        return -math.infinity[f64]()
    }
    if x != x {
        return x
    }
    if x - x != 0.0 {
        return math.infinity[f64]()
    }
    return cast[f64](ilogb(x))
}

/**
 * Give the cube root.
 *
 * @param x The double, of any sign.
 * @return ∛x, of x's sign.
 */
cbrt #export #calling_convention(.c) :: fn(x : f64) -> f64 {
    return math.cube_root(x)
}

/**
 * Give the hypotenuse, without overflowing on the way.
 *
 * @param x One side.
 * @param y The other.
 * @return √(x² + y²); +infinity if either is infinite, even with a NaN.
 */
hypot #export #calling_convention(.c) :: fn(x : f64, y : f64) -> f64 {
    return math.hypotenuse(x, y)
}

/**
 * Give e to a power.
 *
 * @param x The power.
 * @return eˣ; +infinity past about 709.78, +0 below about -745.13.
 */
exp #export #calling_convention(.c) :: fn(x : f64) -> f64 {
    return math.exp(x)
}

/**
 * Give 2 to a power.
 *
 * @param x The power.
 * @return 2ˣ; +infinity from 1024, +0 below -1074.
 */
exp2 #export #calling_convention(.c) :: fn(x : f64) -> f64 {
    return math.exp2(x)
}

/**
 * Give e to a power, less 1, precise near 0.
 *
 * @param x The power.
 * @return eˣ - 1; -1 for large negative x.
 */
expm1 #export #calling_convention(.c) :: fn(x : f64) -> f64 {
    return math.exp_minus_one(x)
}

/**
 * Give the natural logarithm.
 *
 * @param x The double.
 * @return ln x; -infinity for ±0; NaN below 0.
 */
log #export #calling_convention(.c) :: fn(x : f64) -> f64 {
    return math.log(x)
}

/**
 * Give the base 2 logarithm.
 *
 * @param x The double.
 * @return log₂ x, exact for powers of two; -infinity for ±0; NaN below 0.
 */
log2 #export #calling_convention(.c) :: fn(x : f64) -> f64 {
    return math.log2(x)
}

/**
 * Give the base 10 logarithm.
 *
 * @param x The double.
 * @return log₁₀ x; -infinity for ±0; NaN below 0.
 */
log10 #export #calling_convention(.c) :: fn(x : f64) -> f64 {
    return math.log10(x)
}

/**
 * Give the natural logarithm of 1 plus a double, precise near 0.
 *
 * @param x The double.
 * @return ln(1 + x); -infinity for -1; NaN below -1.
 */
log1p #export #calling_convention(.c) :: fn(x : f64) -> f64 {
    return math.log_one_plus(x)
}

/**
 * Raise a double to a power, as C's pow, IEEE 754's special cases and all.
 *
 * @param x The base.
 * @param y The power.
 * @return xʸ: 1 for any x when y is ±0, and for x 1 whatever y; NaN for a negative x and a y that isn't whole.
 */
pow #export #calling_convention(.c) :: fn(x : f64, y : f64) -> f64 {
    return math.power(x, y)
}

/**
 * Give the sine.
 *
 * @param x An angle, in radians.
 * @return sin x; NaN for ±infinity.
 */
sin #export #calling_convention(.c) :: fn(x : f64) -> f64 {
    return math.sin(x)
}

/**
 * Give the cosine.
 *
 * @param x An angle, in radians.
 * @return cos x; NaN for ±infinity.
 */
cos #export #calling_convention(.c) :: fn(x : f64) -> f64 {
    return math.cos(x)
}

/**
 * Give the tangent.
 *
 * @param x An angle, in radians.
 * @return tan x; NaN for ±infinity.
 */
tan #export #calling_convention(.c) :: fn(x : f64) -> f64 {
    return math.tan(x)
}

/**
 * Give the arcsine.
 *
 * @param x From -1 to 1.
 * @return The angle from -π/2 to π/2 whose sine is x; NaN outside -1 to 1.
 */
asin #export #calling_convention(.c) :: fn(x : f64) -> f64 {
    return math.asin(x)
}

/**
 * Give the arccosine.
 *
 * @param x From -1 to 1.
 * @return The angle from 0 to π whose cosine is x; NaN outside -1 to 1.
 */
acos #export #calling_convention(.c) :: fn(x : f64) -> f64 {
    return math.acos(x)
}

/**
 * Give the arctangent.
 *
 * @param x Any double.
 * @return The angle from -π/2 to π/2 whose tangent is x.
 */
atan #export #calling_convention(.c) :: fn(x : f64) -> f64 {
    return math.atan(x)
}

/**
 * Give the angle of a point, from the x axis.
 *
 * @param y The point's y.
 * @param x The point's x.
 * @return The angle from -π to π, by both signs' quadrant.
 */
atan2 #export #calling_convention(.c) :: fn(y : f64, x : f64) -> f64 {
    return math.atan2(y, x)
}

/**
 * Give the hyperbolic sine.
 *
 * @param x Any double.
 * @return sinh x; ±infinity past about ±710.
 */
sinh #export #calling_convention(.c) :: fn(x : f64) -> f64 {
    return math.sinh(x)
}

/**
 * Give the hyperbolic cosine.
 *
 * @param x Any double.
 * @return cosh x, at least 1; +infinity past about ±710.
 */
cosh #export #calling_convention(.c) :: fn(x : f64) -> f64 {
    return math.cosh(x)
}

/**
 * Give the hyperbolic tangent.
 *
 * @param x Any double.
 * @return tanh x, from -1 to 1.
 */
tanh #export #calling_convention(.c) :: fn(x : f64) -> f64 {
    return math.tanh(x)
}

/**
 * Give the inverse hyperbolic sine.
 *
 * @param x Any double.
 * @return asinh x.
 */
asinh #export #calling_convention(.c) :: fn(x : f64) -> f64 {
    return math.asinh(x)
}

/**
 * Give the inverse hyperbolic cosine.
 *
 * @param x At least 1.
 * @return acosh x, at least 0; NaN below 1.
 */
acosh #export #calling_convention(.c) :: fn(x : f64) -> f64 {
    return math.acosh(x)
}

/**
 * Give the inverse hyperbolic tangent.
 *
 * @param x From -1 to 1.
 * @return atanh x; ±infinity for ±1; NaN outside.
 */
atanh #export #calling_convention(.c) :: fn(x : f64) -> f64 {
    return math.atanh(x)
}

/**
 * Give the error function.
 *
 * @param x Any double.
 * @return erf x, from -1 to 1.
 */
erf #export #calling_convention(.c) :: fn(x : f64) -> f64 {
    return math.erf(x)
}

/**
 * Give the complementary error function, precise where erf is near 1.
 *
 * @param x Any double.
 * @return 1 - erf x, from 0 to 2.
 */
erfc #export #calling_convention(.c) :: fn(x : f64) -> f64 {
    return math.erfc(x)
}

/**
 * Give the gamma function.
 *
 * @param x Any double.
 * @return Γ(x); ±infinity at ±0, NaN at the negative whole numbers; +infinity past about 171.6.
 */
tgamma #export #calling_convention(.c) :: fn(x : f64) -> f64 {
    return math.gamma(x)
}

/**
 * Give the natural logarithm of the gamma function's magnitude.
 *
 * @param x Any double.
 * @return ln |Γ(x)|; +infinity at 0 and the negative whole numbers. signgam isn't set.
 */
lgamma #export #calling_convention(.c) :: fn(x : f64) -> f64 {
    return math.log_gamma(x)
}

/**
 * Give the next double after one, toward another.
 *
 * @param x Where it starts.
 * @param toward Which way: up if above x, down if below.
 * @return The neighbouring double; toward itself when it's equal to x; NaN if either is.
 */
nextafter #export #calling_convention(.c) :: fn(x : f64, toward : f64) -> f64 {
    if x != x || toward != toward {
        return x + toward
    }
    if x == toward {
        return toward
    }
    return if toward > x { math.next_up(x) } else { math.next_down(x) }
}

/**
 * Give a float's magnitude.
 *
 * @param x The float.
 * @return As fabs's, as a float.
 */
fabsf #export #calling_convention(.c) #no_context :: fn(x : f32) -> f32 {
    return intrinsics.copy_sign(x, cast[f32](1.0))
}

/**
 * Round a float down.
 *
 * @param x The float.
 * @return As floor's.
 */
floorf #export #calling_convention(.c) #no_context :: fn(x : f32) -> f32 {
    return intrinsics.floor(x)
}

/**
 * Round a float up.
 *
 * @param x The float.
 * @return As ceil's.
 */
ceilf #export #calling_convention(.c) #no_context :: fn(x : f32) -> f32 {
    return intrinsics.ceil(x)
}

/**
 * Round a float toward zero.
 *
 * @param x The float.
 * @return As trunc's.
 */
truncf #export #calling_convention(.c) #no_context :: fn(x : f32) -> f32 {
    return intrinsics.trunc(x)
}

/**
 * Round a float to nearest, halfway away from zero.
 *
 * @param x The float.
 * @return As round's, exact in double.
 */
roundf #export #calling_convention(.c) #no_context :: fn(x : f32) -> f32 {
    return cast[f32](round(cast[f64](x)))
}

/**
 * Give a float's square root.
 *
 * @param x The float.
 * @return As sqrt's, correctly rounded.
 */
sqrtf #export #calling_convention(.c) #no_context :: fn(x : f32) -> f32 {
    return intrinsics.square_root(x)
}

/**
 * Give a float's magnitude with another's sign.
 *
 * @param magnitude Where all but the sign come from.
 * @param sign Where the sign comes from.
 * @return As copysign's.
 */
copysignf #export #calling_convention(.c) #no_context :: fn(magnitude : f32, sign : f32) -> f32 {
    return intrinsics.copy_sign(magnitude, sign)
}

/**
 * Give the lesser of two floats, a NaN losing.
 *
 * @param x One float.
 * @param y The other.
 * @return As fmin's.
 */
fminf #export #calling_convention(.c) #no_context :: fn(x : f32, y : f32) -> f32 {
    return cast[f32](fmin(cast[f64](x), cast[f64](y)))
}

/**
 * Give the greater of two floats, a NaN losing.
 *
 * @param x One float.
 * @param y The other.
 * @return As fmax's.
 */
fmaxf #export #calling_convention(.c) #no_context :: fn(x : f32, y : f32) -> f32 {
    return cast[f32](fmax(cast[f64](x), cast[f64](y)))
}

/**
 * Give a float division's remainder, the quotient cut toward zero.
 *
 * @param x The dividend.
 * @param y The divisor.
 * @return As fmod's.
 */
fmodf #export #calling_convention(.c) :: fn(x : f32, y : f32) -> f32 {
    return math.truncated_remainder(x, y)
}

/**
 * Raise a float to a power.
 *
 * @param x The base.
 * @param y The power.
 * @return As pow's.
 */
powf #export #calling_convention(.c) :: fn(x : f32, y : f32) -> f32 {
    return math.power(x, y)
}

/**
 * Give e to a power, as a float.
 *
 * @param x The power.
 * @return As exp's.
 */
expf #export #calling_convention(.c) :: fn(x : f32) -> f32 {
    return math.exp(x)
}

/**
 * Give a float's natural logarithm.
 *
 * @param x The float.
 * @return As log's.
 */
logf #export #calling_convention(.c) :: fn(x : f32) -> f32 {
    return math.log(x)
}

/**
 * Give a float's sine.
 *
 * @param x An angle, in radians.
 * @return As sin's.
 */
sinf #export #calling_convention(.c) :: fn(x : f32) -> f32 {
    return math.sin(x)
}

/**
 * Give a float's cosine.
 *
 * @param x An angle, in radians.
 * @return As cos's.
 */
cosf #export #calling_convention(.c) :: fn(x : f32) -> f32 {
    return math.cos(x)
}

/**
 * Give a float's tangent.
 *
 * @param x An angle, in radians.
 * @return As tan's.
 */
tanf #export #calling_convention(.c) :: fn(x : f32) -> f32 {
    return math.tan(x)
}

/**
 * Give a point's angle, as floats.
 *
 * @param y The point's y.
 * @param x The point's x.
 * @return As atan2's.
 */
atan2f #export #calling_convention(.c) :: fn(y : f32, x : f32) -> f32 {
    return math.atan2(y, x)
}

/**
 * Multiply a float by a power of two.
 *
 * @param x The float.
 * @param exponent The power of two.
 * @return As ldexp's, rounded once to a float.
 */
ldexpf #export #calling_convention(.c) :: fn(x : f32, exponent : i32) -> f32 {
    return math.scale_by_power_of_two(x, exponent)
}

/**
 * Split a float into a fraction from 1/2 to 1 and a power of two.
 *
 * @param x The float.
 * @param exponent Where the power goes.
 * @return As frexp's.
 */
frexpf #export #calling_convention(.c) :: fn(x : f32, exponent : ptr[mut i32]) -> f32 {
    fraction, power :: math.fraction_and_exponent(x)
    exponent^ = power
    return fraction
}
