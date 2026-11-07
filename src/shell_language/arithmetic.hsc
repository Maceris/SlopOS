package shell_language

import runtime from "base"
import strings from "std"

/*
 * Arithmetic that says when it overflows, where Hemera's wraps. //STD(missing): checked arithmetic, like LLVM's
 * llvm.sadd.with.overflow, in base or std, which these would be.
 */

/** What arithmetic says when its result is past what its kind holds. */
TOO_BIG :: "that's too big: past what a 64-bit number holds"

/** The smallest i64, -2^63, which has no positive counterpart. */
SMALLEST :: cast[i64](cast[u64](1) << 63)

/**
 * Add two whole numbers, unless the sum is past an i64's range.
 *
 * @param a A number, any i64.
 * @param b The number added to it, any i64.
 * @return The sum; null if it's below -2^63 or above 2^63 - 1.
 */
added :: fn(a: i64, b: i64) -> i64? {
    sum :: a + b
    // Overflow made the sum's sign unlike both operands'
    return if (a ~ sum) & (b ~ sum) < 0 { null } else { sum }
}

/**
 * Subtract a whole number from another, unless the difference is past an i64's range.
 *
 * @param a The number subtracted from, any i64.
 * @param b The number subtracted, any i64.
 * @return The difference; null if it's below -2^63 or above 2^63 - 1.
 */
subtracted :: fn(a: i64, b: i64) -> i64? {
    difference :: a - b
    // Overflow needs operands of unlike signs, and gives a difference of b's sign
    return if (a ~ b) & (a ~ difference) < 0 { null } else { difference }
}

/**
 * Multiply two whole numbers, unless the product is past an i64's range.
 *
 * @param a A number, any i64.
 * @param b The number it's multiplied by, any i64.
 * @return The product; null if it's below -2^63 or above 2^63 - 1.
 */
multiplied :: fn(a: i64, b: i64) -> i64? {
    if a == 0 || b == 0 {
        return 0
    }
    if (a == -1 && b == SMALLEST) || (b == -1 && a == SMALLEST) {
        return null
    }
    product :: a * b
    return if product / b != a { null } else { product }
}

/**
 * Divide a whole number by another, unless the quotient is past an i64's range.
 *
 * @param a The number divided, any i64.
 * @param b The divisor, not 0.
 * @return The quotient, toward 0; null for the smallest i64 divided by -1, whose quotient is 2^63, or for b 0.
 */
divided :: fn(a: i64, b: i64) -> i64? {
    if b == 0 || (a == SMALLEST && b == -1) {
        return null
    }
    return a / b
}

/**
 * Add two sizes, unless the sum is past a u64's range.
 *
 * @param a A size, in bytes.
 * @param b The size added to it, in bytes.
 * @return The sum, in bytes; null if it's 2^64 or more.
 */
added_sizes :: fn(a: u64, b: u64) -> u64? {
    sum :: a + b
    return if sum < a { null } else { sum }
}

/**
 * Multiply a size by a count, unless the product is past a u64's range.
 *
 * @param a The size, in bytes, or a count.
 * @param b What it's multiplied by.
 * @return The product; null if it's 2^64 or more.
 */
multiplied_sizes :: fn(a: u64, b: u64) -> u64? {
    if a == 0 {
        return 0
    }
    product :: a * b
    return if product / a != b { null } else { product }
}

/**
 * Order two values of a kind: integers, sizes and durations by number, text and paths by their bytes, false before
 * true, and null equal to null.
 *
 * @param left The value ordered, of any kind; only those named above have an order.
 * @param right The value it's ordered against, of the same kind for there to be an order.
 * @return Below 0, 0 or above 0 as left is before, equal to or after right; null if they aren't of one kind with an
 *     order, like lists, records, or two kinds.
 */
compare :: fn(left: Value, right: Value) -> int? {
    match left {
        case Int(a) => match right {
            case Int(b) => return if a < b { -1 } else if a > b { 1 } else { 0 }
            case _ => return null
        }
        case Size(a) => match right {
            case Size(b) => return if a < b { -1 } else if a > b { 1 } else { 0 }
            case _ => return null
        }
        case Duration(a) => match right {
            case Duration(b) => return if a < b { -1 } else if a > b { 1 } else { 0 }
            case _ => return null
        }
        case Instant(a) => match right {
            case Instant(b) => return if a < b { -1 } else if a > b { 1 } else { 0 }
            case _ => return null
        }
        case Text(a) => match right {
            case Text(b) => return text_order(a, b)
            case _ => return null
        }
        case Path(a) => match right {
            case Path(b) => return text_order(a, b)
            case _ => return null
        }
        case Bool(a) => match right {
            case Bool(b) => return if a == b { 0 } else if a { 1 } else { -1 }
            case _ => return null
        }
        case Null => match right {
            case Null => return 0
            case _ => return null
        }
        case _ => {}
    }
    return null
}

/**
 * Order two strings by their bytes, a prefix before what it starts.
 *
 * @param a The string ordered, compared byte for byte, not by its characters.
 * @param b The string it's ordered against.
 * @return -1, 0 or 1 as a is before, equal to or after b.
 */
text_order :: fn(a: string, b: string) -> int {
    left :: string_bytes(a)
    right :: string_bytes(b)
    for byte, i in left {
        if i >= right.count {
            return 1
        }
        if byte != right[i] {
            return if byte < right[i] { -1 } else { 1 }
        }
    }
    return if left.count < right.count { -1 } else { 0 }
}

/**
 * Join two strings.
 *
 * @param a The string that comes first, copied; nothing of it is kept.
 * @param b The second, after it.
 * @return The two, on the heap, never freed; a literal "" when both are empty.
 */
joined :: fn(a: string, b: string) -> string {
    made : u8[..]
    for byte in string_bytes(a) {
        runtime.array_add(&made, byte)
    }
    for byte in string_bytes(b) {
        runtime.array_add(&made, byte)
    }
    return if made.count > 0 { string_of(&made[0], made.count) } else { "" }
}

/**
 * Make a message with values put in for each %, as the shell's errors say what they found.
 *
 * @param format The message, a % for each value.
 * @param values The values, in order, formatted as std's strings.format does.
 * @return The message, on the heap, never freed; format itself if it couldn't be made.
 */
message :: fn(format: string, values: any...) -> string {
    return strings.format(format, values) or_else format
}

/**
 * Do + - * / on two values: integers, sizes and durations of one kind, either scaled by an integer, and strings
 * joined by +.
 *
 * It fails for an integer divided by zero, a size made less than none, a result past what its kind holds (an i64,
 * or a u64 for a size), or operands the operator doesn't take (a size or duration divided by 0 or, for a size,
 * scaled by a negative integer, among them).
 *
 * @param operator The operator: "+", "-", "*" or "/".
 * @param left The operator's left operand, of any kind; only those named above can be.
 * @param right Its right operand: of left's kind, or an Int when left's a size or duration being scaled or divided.
 * @return The result, of left's kind, or right's for an integer times a size or a duration; why it can't be done
 *     otherwise, a sentence for a person, TOO_BIG for a result past its kind's range.
 */
calculate :: fn(operator: string, left: Value, right: Value) -> Result[Value, string] {
    match left {
        case Int(a) => match right {
            case Int(b) => {
                if operator == "/" && b == 0 {
                    return .Error("dividing by zero")
                }
                result :: if operator == "+" { added(a, b) } else if operator == "-" { subtracted(a, b) } else if operator == "*" { multiplied(a, b) }
                    else { divided(a, b) }
                return .Ok(.Int(result or_return .Error(TOO_BIG)))
            }
            case Size(b) => if operator == "*" && a >= 0 {
                return .Ok(.Size(multiplied_sizes(cast[u64](a), b) or_return .Error(TOO_BIG)))
            }
            case Duration(b) => if operator == "*" {
                return .Ok(.Duration(multiplied(a, b) or_return .Error(TOO_BIG)))
            }
            case _ => {}
        }
        case Size(a) => match right {
            case Size(b) => {
                if operator == "+" {
                    return .Ok(.Size(added_sizes(a, b) or_return .Error(TOO_BIG)))
                }
                if operator == "-" {
                    return if b > a { Result[Value, string].Error("a size can't be less than none") } else { Result[Value, string].Ok(.Size(a - b)) }
                }
            }
            case Int(b) => {
                if operator == "*" && b >= 0 {
                    return .Ok(.Size(multiplied_sizes(a, cast[u64](b)) or_return .Error(TOO_BIG)))
                }
                if operator == "/" && b > 0 {
                    return .Ok(.Size(a / cast[u64](b)))
                }
            }
            case _ => {}
        }
        case Duration(a) => match right {
            case Duration(b) => {
                if operator == "+" {
                    return .Ok(.Duration(added(a, b) or_return .Error(TOO_BIG)))
                }
                if operator == "-" {
                    return .Ok(.Duration(subtracted(a, b) or_return .Error(TOO_BIG)))
                }
            }
            case Int(b) => {
                if operator == "*" {
                    return .Ok(.Duration(multiplied(a, b) or_return .Error(TOO_BIG)))
                }
                if operator == "/" && b != 0 {
                    return .Ok(.Duration(divided(a, b) or_return .Error(TOO_BIG)))
                }
            }
            case _ => {}
        }
        case Text(a) => match right {
            case Text(b) => if operator == "+" {
                return .Ok(.Text(joined(a, b)))
            }
            case _ => {}
        }
        case _ => {}
    }
    return .Error(message("% can't be % %", type_name(left), operator, type_name(right)))
}
