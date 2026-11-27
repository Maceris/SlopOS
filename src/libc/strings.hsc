package libc

/*
 * string.h's byte and C string functions (decisions/0201, 20l), called from C. Each is #no_context, as none needs
 * the runtime, but strdup and strndup, which allocate from the program's heap. A C string is a run of bytes ended by a
 * 0 byte, which every function here reads up to and no further; NULL is never valid where C says a string or block
 * must be given. memcpy, memmove, memset and memcmp aren't here: the compiler defines them in every Hemera program.
 */

import runtime from "base:runtime"

/**
 * Read the byte at an offset from a C pointer.
 *
 * @param base Where the bytes start.
 * @param offset How far from base, in bytes; base to base + offset must be readable.
 * @return The byte there.
 */
byte_at #no_context :: fn(base : ptr[u8], offset : usize) -> u8 {
    return cast[ptr[u8]](cast[usize](base) + offset)^
}

/**
 * Write the byte at an offset from a C pointer.
 *
 * @param base Where the bytes start.
 * @param offset How far from base, in bytes; base + offset must be writable.
 * @param value The byte written there.
 */
set_byte #no_context :: fn(base : ptr[u8], offset : usize, value : u8) {
    cast[ptr[mut u8]](cast[usize](base) + offset)^ = value
}

/**
 * Point offset bytes past a C pointer.
 *
 * @param base Where the bytes start.
 * @param offset How far, in bytes.
 * @return base + offset, which may be one past the end of what base points into, as C allows.
 */
at_offset #no_context :: fn(base : ptr[u8], offset : usize) -> ptr[mut u8] {
    return cast[ptr[mut u8]](cast[usize](base) + offset)
}

/**
 * Count a C string's bytes before its 0 byte.
 *
 * @param text The string, readable up to and including its 0 byte.
 * @return How many bytes come before the 0 byte: 0 for "".
 */
strlen #export #calling_convention(.c) #no_context :: fn(text : ptr[u8]) -> usize {
    count : usize = 0
    loop {
        if byte_at(text, count) == 0 {
            return count
        }
        count += 1
    }
}

/**
 * Count a C string's bytes before its 0 byte, looking at no more than most of them.
 *
 * @param text The string, readable up to its 0 byte or most bytes, whichever comes first.
 * @param most The most bytes looked at.
 * @return How many bytes come before the 0 byte, or most if there's none among the first most.
 */
strnlen #export #calling_convention(.c) #no_context :: fn(text : ptr[u8], most : usize) -> usize {
    for count in cast[usize](0)..<most {
        if byte_at(text, count) == 0 {
            return count
        }
    }
    return most
}

/**
 * Find a byte among the first count bytes of a block.
 *
 * @param bytes The block, readable for count bytes.
 * @param byte The byte, as an int whose low 8 bits are compared.
 * @param count How many bytes are looked at.
 * @return The first place it's at; NULL if it's not among them.
 */
memchr #export #calling_convention(.c) #no_context :: fn(bytes : ptr[u8], byte : i32, count : usize) -> ptr[mut u8]? {
    wanted :: cast[u8](byte & 0xff)
    for i in cast[usize](0)..<count {
        if byte_at(bytes, i) == wanted {
            return at_offset(bytes, i)
        }
    }
    return null
}

/**
 * Compare two C strings, byte by byte as unsigned chars.
 *
 * @param a One string.
 * @param b The other.
 * @return Below 0, 0 or above 0 as a sorts before, the same as or after b: the difference of the first bytes that
 *     differ, a shorter string sorting first.
 */
strcmp #export #calling_convention(.c) #no_context :: fn(a : ptr[u8], b : ptr[u8]) -> i32 {
    i : usize = 0
    loop {
        x :: byte_at(a, i)
        y :: byte_at(b, i)
        if x != y || x == 0 {
            return cast[i32](x) - cast[i32](y)
        }
        i += 1
    }
}

/**
 * Compare at most the first most bytes of two C strings, as strcmp does.
 *
 * @param a One string.
 * @param b The other.
 * @param most The most bytes compared: 0 always gives 0.
 * @return As strcmp's, for the first most bytes.
 */
strncmp #export #calling_convention(.c) #no_context :: fn(a : ptr[u8], b : ptr[u8], most : usize) -> i32 {
    for i in cast[usize](0)..<most {
        x :: byte_at(a, i)
        y :: byte_at(b, i)
        if x != y || x == 0 {
            return cast[i32](x) - cast[i32](y)
        }
    }
    return 0
}

/**
 * Compare two C strings in the locale's order: the C locale's, the only one, which is strcmp's.
 *
 * @param a One string.
 * @param b The other.
 * @return As strcmp's.
 */
strcoll #export #calling_convention(.c) #no_context :: fn(a : ptr[u8], b : ptr[u8]) -> i32 {
    return strcmp(a, b)
}

/**
 * Transform a C string so strcmp of two transforms orders them as strcoll would: in the C locale, a copy.
 *
 * @param to Where the transform goes, size bytes, its 0 byte included; may be NULL when size is 0.
 * @param from The string.
 * @param size How many bytes to has room for.
 * @return from's length; when that's size or more, to's contents aren't the whole transform.
 */
strxfrm #export #calling_convention(.c) #no_context :: fn(to : ptr[mut u8]?, from : ptr[u8], size : usize) -> usize {
    count :: strlen(from)
    match to {
        case Some(into) => if count < size {
            for i in cast[usize](0)..<count + 1 {
                set_byte(into, i, byte_at(from, i))
            }
        }
        case None => {}
    }
    return count
}

/**
 * Copy a C string, its 0 byte too.
 *
 * @param to Where it goes, with room for strlen(from) + 1 bytes, not overlapping from.
 * @param from The string.
 * @return to.
 */
strcpy #export #calling_convention(.c) #no_context :: fn(to : ptr[mut u8], from : ptr[u8]) -> ptr[mut u8] {
    i : usize = 0
    loop {
        byte :: byte_at(from, i)
        set_byte(to, i, byte)
        if byte == 0 {
            return to
        }
        i += 1
    }
}

/**
 * Copy at most count bytes of a C string, padding with 0 bytes to count: a string of count bytes or more isn't
 * 0-terminated.
 *
 * @param to Where it goes, with room for count bytes, not overlapping from.
 * @param from The string.
 * @param count How many bytes are written to to, exactly.
 * @return to.
 */
strncpy #export #calling_convention(.c) #no_context :: fn(to : ptr[mut u8], from : ptr[u8], count : usize) -> ptr[mut u8] {
    ended := false
    for i in cast[usize](0)..<count {
        byte :: if ended { cast[u8](0) } else { byte_at(from, i) }
        if byte == 0 {
            ended = true
        }
        set_byte(to, i, byte)
    }
    return to
}

/**
 * Append a C string to another.
 *
 * @param to The string appended to, with room for both and a 0 byte, not overlapping from.
 * @param from The string appended.
 * @return to.
 */
strcat #export #calling_convention(.c) #no_context :: fn(to : ptr[mut u8], from : ptr[u8]) -> ptr[mut u8] {
    strcpy(at_offset(to, strlen(to)), from)
    return to
}

/**
 * Append at most most bytes of a C string to another, then a 0 byte.
 *
 * @param to The string appended to, with room for it, most more bytes and a 0 byte.
 * @param from The string appended, of which at most most bytes are.
 * @param most The most bytes of from appended.
 * @return to.
 */
strncat #export #calling_convention(.c) #no_context :: fn(to : ptr[mut u8], from : ptr[u8], most : usize) -> ptr[mut u8] {
    end :: strlen(to)
    count :: strnlen(from, most)
    for i in cast[usize](0)..<count {
        set_byte(to, end + i, byte_at(from, i))
    }
    set_byte(to, end + count, 0)
    return to
}

/**
 * Find a byte's first place in a C string.
 *
 * @param text The string.
 * @param c The byte, as an int whose low 8 bits are looked for; 0 finds the string's 0 byte.
 * @return Where it first is; NULL if it isn't there.
 */
strchr #export #calling_convention(.c) #no_context :: fn(text : ptr[u8], c : i32) -> ptr[mut u8]? {
    wanted :: cast[u8](c & 0xff)
    i : usize = 0
    loop {
        byte :: byte_at(text, i)
        if byte == wanted {
            return at_offset(text, i)
        }
        if byte == 0 {
            return null
        }
        i += 1
    }
}

/**
 * Find a byte's last place in a C string.
 *
 * @param text The string.
 * @param c The byte, as an int whose low 8 bits are looked for; 0 finds the string's 0 byte.
 * @return Where it last is; NULL if it isn't there.
 */
strrchr #export #calling_convention(.c) #no_context :: fn(text : ptr[u8], c : i32) -> ptr[mut u8]? {
    wanted :: cast[u8](c & 0xff)
    found : ptr[mut u8]? = null
    i : usize = 0
    loop {
        byte :: byte_at(text, i)
        if byte == wanted {
            found = at_offset(text, i)
        }
        if byte == 0 {
            return found
        }
        i += 1
    }
}

/**
 * Find a C string's first place in another.
 *
 * @param text The string looked in.
 * @param part The string looked for; "" is found at text's start.
 * @return Where part first starts in text; NULL if it isn't there.
 */
strstr #export #calling_convention(.c) #no_context :: fn(text : ptr[u8], part : ptr[u8]) -> ptr[mut u8]? {
    count :: strlen(part)
    i : usize = 0
    loop {
        if strncmp(at_offset(text, i), part, count) == 0 {
            return at_offset(text, i)
        }
        if byte_at(text, i) == 0 {
            return null
        }
        i += 1
    }
}

/**
 * Tell whether a byte is in a C string, its 0 byte not counted.
 *
 * @param set The string of bytes.
 * @param byte The byte.
 * @return True if it's one of set's.
 */
in_set #no_context :: fn(set : ptr[u8], byte : u8) -> bool {
    i : usize = 0
    loop {
        each :: byte_at(set, i)
        if each == 0 {
            return false
        }
        if each == byte {
            return true
        }
        i += 1
    }
}

/**
 * Count how many of a C string's first bytes are in a set.
 *
 * @param text The string.
 * @param accepted The set, as a C string of its bytes.
 * @return The length of text's longest start of bytes all in accepted.
 */
strspn #export #calling_convention(.c) #no_context :: fn(text : ptr[u8], accepted : ptr[u8]) -> usize {
    i : usize = 0
    loop {
        byte :: byte_at(text, i)
        if byte == 0 || !in_set(accepted, byte) {
            return i
        }
        i += 1
    }
}

/**
 * Count how many of a C string's first bytes aren't in a set.
 *
 * @param text The string.
 * @param rejected The set, as a C string of its bytes.
 * @return The length of text's longest start of bytes none in rejected: strlen(text) if it has none of them.
 */
strcspn #export #calling_convention(.c) #no_context :: fn(text : ptr[u8], rejected : ptr[u8]) -> usize {
    i : usize = 0
    loop {
        byte :: byte_at(text, i)
        if byte == 0 || in_set(rejected, byte) {
            return i
        }
        i += 1
    }
}

/**
 * Find the first byte of a C string that's in a set.
 *
 * @param text The string.
 * @param wanted The set, as a C string of its bytes.
 * @return Where it is; NULL if text has none of them.
 */
strpbrk #export #calling_convention(.c) #no_context :: fn(text : ptr[u8], wanted : ptr[u8]) -> ptr[mut u8]? {
    at :: strcspn(text, wanted)
    return if byte_at(text, at) == 0 { null } else { at_offset(text, at) }
}

/**
 * Split a C string into tokens, one a call, writing a 0 byte over the separator after each; strtok is this with
 * a saved place of its own (c/errno.c).
 *
 * @param text The string, the first call; NULL to go on from saved.
 * @param separators The bytes between tokens, as a C string; it may differ from call to call.
 * @param saved Where the place to go on from is kept between calls; set to NULL once the string's used up.
 * @return The next token, a view into the string; NULL once there are none left.
 */
strtok_r #export #calling_convention(.c) #no_context :: fn(
    text #escaping : ptr[mut u8]?,
    separators : ptr[u8],
    saved : ptr[mut ptr[mut u8]?]
) -> ptr[mut u8]? {
    start :: match text {
        case Some(given) => given
        case None => saved^ or_return null
    }
    first :: at_offset(start, strspn(start, separators))
    if byte_at(first, 0) == 0 {
        saved^ = null
        return null
    }
    length :: strcspn(first, separators)
    if byte_at(first, length) == 0 {
        saved^ = null
    }
    else {
        set_byte(first, length, 0)
        saved^ = at_offset(first, length + 1)
    }
    return first
}

/**
 * Lower an ASCII letter, for the comparisons that ignore case.
 *
 * @param byte A byte.
 * @return Its lower case for A to Z; itself for any other.
 */
lowered #no_context :: fn(byte : u8) -> u8 {
    return if byte >= cast[u8]('A') && byte <= cast[u8]('Z') { byte + 32 } else { byte }
}

/**
 * Compare two C strings as strcmp does, ASCII letters' case ignored.
 *
 * @param a One string.
 * @param b The other.
 * @return As strcmp's, of the strings lowered.
 */
strcasecmp #export #calling_convention(.c) #no_context :: fn(a : ptr[u8], b : ptr[u8]) -> i32 {
    return strncasecmp(a, b, ~cast[usize](0))
}

/**
 * Compare at most most bytes of two C strings as strncmp does, ASCII letters' case ignored.
 *
 * @param a One string.
 * @param b The other.
 * @param most The most bytes compared.
 * @return As strncmp's, of the strings lowered.
 */
strncasecmp #export #calling_convention(.c) #no_context :: fn(a : ptr[u8], b : ptr[u8], most : usize) -> i32 {
    for i in cast[usize](0)..<most {
        x :: lowered(byte_at(a, i))
        y :: lowered(byte_at(b, i))
        if x != y || x == 0 {
            return cast[i32](x) - cast[i32](y)
        }
    }
    return 0
}

/**
 * Copy a C string to the program's heap.
 *
 * @param text The string.
 * @return The copy, 0-terminated, which free gives back; NULL, errno ENOMEM (malloc's), without the memory.
 */
strdup #export #calling_convention(.c) :: fn(text : ptr[u8]) -> ptr[mut u8]? {
    return strndup(text, ~cast[usize](0))
}

/**
 * Copy at most most bytes of a C string to the program's heap, then a 0 byte.
 *
 * @param text The string.
 * @param most The most bytes copied.
 * @return The copy, 0-terminated, which free gives back; NULL, errno ENOMEM, without the memory.
 */
strndup #export #calling_convention(.c) :: fn(text : ptr[u8], most : usize) -> ptr[mut u8]? {
    count :: strnlen(text, most)
    made :: malloc(count + 1) or_return null
    for i in cast[usize](0)..<count {
        set_byte(made, i, byte_at(text, i))
    }
    set_byte(made, count, 0)
    return made
}
