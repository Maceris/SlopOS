package aml_test

import runtime from "base"

/*
 * A small AML assembler for the tests: each function writes one encoding, so a test writes its table as the ASL it
 * stands for, term by term. Every PkgLength is written in its four-byte form, which any length fits.
 */

/** AML being written. */
Assembler :: struct {
    /** The bytes so far. */
    bytes : u8[..],
}

/**
 * Write bytes as they are.
 *
 * @param a The assembler.
 * @param values The bytes.
 */
raw :: fn(a: ptr[mut Assembler], values: u8[]) {
    for value in values {
        runtime.array_add(&a.bytes, value)
    }
}

/**
 * Write one byte.
 *
 * @param a The assembler.
 * @param value The byte.
 */
op :: fn(a: ptr[mut Assembler], value: u8) {
    runtime.array_add(&a.bytes, value)
}

/**
 * Start a term with a PkgLength: its opcode bytes, then room for the length, which close fills in.
 *
 * @param a The assembler.
 * @param opcode The opcode's bytes.
 * @return Where the length is, for close.
 */
open :: fn(a: ptr[mut Assembler], opcode: u8[]) -> usize {
    raw(a, opcode)
    mark :: a.bytes.count
    raw(a, u8.[0, 0, 0, 0])
    return mark
}

/**
 * Fill in the PkgLength open made room for: from it to here.
 *
 * @param a The assembler.
 * @param mark What open gave.
 */
close :: fn(a: ptr[mut Assembler], mark: usize) {
    length :: a.bytes.count - mark
    encoded :: u8.[cast[u8](0xc0 | (length & 0x0f)), cast[u8]((length >> 4) & 0xff), cast[u8]((length >> 12) & 0xff),
        cast[u8]((length >> 20) & 0xff)]
    for byte, i in encoded {
        at :: mark + i
        if at < a.bytes.count {
            a.bytes[at] = byte
        }
    }
}

/**
 * Write a NameString from its ASL: `\`, `^`s, then segments separated by `.`, each padded with `_` to four.
 *
 * @param a The assembler.
 * @param text The name, as `\_SB.PCI0` or `^FOO` or `BAR`.
 */
name :: fn(a: ptr[mut Assembler], text: string) {
    bytes :: string_bytes(text)
    at : usize = 0
    loop {
        if at >= bytes.count || (bytes[at] != cast[u8]('\\') && bytes[at] != cast[u8]('^')) {
            break
        }
        op(a, bytes[at])
        at += 1
    }
    segments : u8[..]
    defer runtime.array_free(&segments)
    count : usize = 0
    loop {
        if at >= bytes.count {
            break
        }
        length : usize = 0
        loop {
            if at >= bytes.count || bytes[at] == cast[u8]('.') {
                break
            }
            runtime.array_add(&segments, bytes[at])
            length += 1
            at += 1
        }
        for padding in length..<4 {
            runtime.array_add(&segments, cast[u8]('_'))
        }
        count += 1
        if at < bytes.count {
            at += 1
        }
    }
    if count == 0 {
        op(a, 0x00)
    }
    else if count == 2 {
        op(a, 0x2e)
    }
    else if count > 2 {
        op(a, 0x2f)
        op(a, cast[u8](count))
    }
    raw(a, segments[0..<segments.count])
}

/**
 * Write an integer, in its shortest form: Zero, One, Ones or a prefix and its bytes.
 *
 * @param a The assembler.
 * @param value The integer.
 */
integer :: fn(a: ptr[mut Assembler], value: u64) {
    if value == 0 {
        op(a, 0x00)
        return void
    }
    if value == 1 {
        op(a, 0x01)
        return void
    }
    count : u32 = 8
    prefix : u8 = 0x0e
    if value <= 0xff {
        count = 1
        prefix = 0x0a
    }
    else if value <= 0xffff {
        count = 2
        prefix = 0x0b
    }
    else if value <= 0xffffffff {
        count = 4
        prefix = 0x0c
    }
    op(a, prefix)
    for i in 0..<count {
        op(a, cast[u8]((value >> (8 * cast[u64](i))) & 0xff))
    }
}

/**
 * Write a string constant.
 *
 * @param a The assembler.
 * @param text Its text, ASCII.
 */
text :: fn(a: ptr[mut Assembler], text: string) {
    op(a, 0x0d)
    raw(a, string_bytes(text))
    op(a, 0x00)
}

/**
 * Wrap AML in a definition block's header.
 *
 * @param body The AML.
 * @param signature "DSDT" or "SSDT".
 * @param revision The header's revision: 2 or more makes a DSDT's integers 64 bits.
 * @return The table, on the heap, never freed.
 */
table :: fn(body: ptr[Assembler], signature: string = "DSDT", revision: u8 = 2) -> u8[] {
    made : u8[..]
    for character in string_bytes(signature) {
        runtime.array_add(&made, character)
    }
    length :: 36 + body.bytes.count
    for i in 0..<4 {
        runtime.array_add(&made, cast[u8]((cast[u64](length) >> (8 * cast[u64](i))) & 0xff))
    }
    runtime.array_add(&made, revision)
    for header_byte in 9..<36 {
        runtime.array_add(&made, 0)
    }
    for byte in body.bytes {
        runtime.array_add(&made, byte)
    }
    return made[0..<made.count]
}
