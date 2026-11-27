package libc

/*
 * ctype.h (decisions/0201, 20l): ASCII's character classes, the C locale's, the only one. Each takes an unsigned
 * char's value or EOF (-1), as C says, and answers nonzero for true; EOF and bytes from 0x80 are in no class, and
 * tolower and toupper give them back as they are.
 */

/**
 * Tell whether a character is between two, both included.
 *
 * @param c The character, an unsigned char's value or EOF.
 * @param low The first of the range.
 * @param high The last of the range.
 * @return True if low <= c <= high.
 */
between #no_context :: fn(c : i32, low : char, high : char) -> bool {
    return c >= cast[i32](low) && c <= cast[i32](high)
}

/**
 * Tell whether a character is a digit, 0 to 9.
 *
 * @param c An unsigned char's value or EOF.
 * @return 1 if it is; 0 if not.
 */
isdigit #export #calling_convention(.c) #no_context :: fn(c : i32) -> i32 {
    return if between(c, '0', '9') { 1 } else { 0 }
}

/**
 * Tell whether a character is a lowercase letter, a to z.
 *
 * @param c An unsigned char's value or EOF.
 * @return 1 if it is; 0 if not.
 */
islower #export #calling_convention(.c) #no_context :: fn(c : i32) -> i32 {
    return if between(c, 'a', 'z') { 1 } else { 0 }
}

/**
 * Tell whether a character is an uppercase letter, A to Z.
 *
 * @param c An unsigned char's value or EOF.
 * @return 1 if it is; 0 if not.
 */
isupper #export #calling_convention(.c) #no_context :: fn(c : i32) -> i32 {
    return if between(c, 'A', 'Z') { 1 } else { 0 }
}

/**
 * Tell whether a character is a letter.
 *
 * @param c An unsigned char's value or EOF.
 * @return 1 if it's a to z or A to Z; 0 if not.
 */
isalpha #export #calling_convention(.c) #no_context :: fn(c : i32) -> i32 {
    return islower(c) | isupper(c)
}

/**
 * Tell whether a character is a letter or a digit.
 *
 * @param c An unsigned char's value or EOF.
 * @return 1 if it is; 0 if not.
 */
isalnum #export #calling_convention(.c) #no_context :: fn(c : i32) -> i32 {
    return isalpha(c) | isdigit(c)
}

/**
 * Tell whether a character is a hexadecimal digit.
 *
 * @param c An unsigned char's value or EOF.
 * @return 1 for 0 to 9, a to f and A to F; 0 for anything else.
 */
isxdigit #export #calling_convention(.c) #no_context :: fn(c : i32) -> i32 {
    return if between(c, '0', '9') || between(c, 'a', 'f') || between(c, 'A', 'F') { 1 } else { 0 }
}

/**
 * Tell whether a character is white space: space, tab, line feed, vertical tab, form feed or carriage return.
 *
 * @param c An unsigned char's value or EOF.
 * @return 1 if it is; 0 if not.
 */
isspace #export #calling_convention(.c) #no_context :: fn(c : i32) -> i32 {
    return if c == 32 || (c >= 9 && c <= 13) { 1 } else { 0 }
}

/**
 * Tell whether a character is a blank: space or tab.
 *
 * @param c An unsigned char's value or EOF.
 * @return 1 if it is; 0 if not.
 */
isblank #export #calling_convention(.c) #no_context :: fn(c : i32) -> i32 {
    return if c == 32 || c == 9 { 1 } else { 0 }
}

/**
 * Tell whether a character is a control character: 0 to 31, and 127.
 *
 * @param c An unsigned char's value or EOF.
 * @return 1 if it is; 0 if not.
 */
iscntrl #export #calling_convention(.c) #no_context :: fn(c : i32) -> i32 {
    return if (c >= 0 && c < 32) || c == 127 { 1 } else { 0 }
}

/**
 * Tell whether a character is printable: space to tilde.
 *
 * @param c An unsigned char's value or EOF.
 * @return 1 if it is; 0 if not.
 */
isprint #export #calling_convention(.c) #no_context :: fn(c : i32) -> i32 {
    return if c >= 32 && c < 127 { 1 } else { 0 }
}

/**
 * Tell whether a character is printable and not a space: ! to tilde.
 *
 * @param c An unsigned char's value or EOF.
 * @return 1 if it is; 0 if not.
 */
isgraph #export #calling_convention(.c) #no_context :: fn(c : i32) -> i32 {
    return if c > 32 && c < 127 { 1 } else { 0 }
}

/**
 * Tell whether a character is punctuation: printable, not a space, a letter or a digit.
 *
 * @param c An unsigned char's value or EOF.
 * @return 1 if it is; 0 if not.
 */
ispunct #export #calling_convention(.c) #no_context :: fn(c : i32) -> i32 {
    return if isgraph(c) != 0 && isalnum(c) == 0 { 1 } else { 0 }
}

/**
 * Lower a letter.
 *
 * @param c An unsigned char's value or EOF.
 * @return a to z for A to Z; c itself for anything else.
 */
tolower #export #calling_convention(.c) #no_context :: fn(c : i32) -> i32 {
    return if isupper(c) != 0 { c + 32 } else { c }
}

/**
 * Raise a letter.
 *
 * @param c An unsigned char's value or EOF.
 * @return A to Z for a to z; c itself for anything else.
 */
toupper #export #calling_convention(.c) #no_context :: fn(c : i32) -> i32 {
    return if islower(c) != 0 { c - 32 } else { c }
}
