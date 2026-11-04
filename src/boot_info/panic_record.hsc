package boot_info

/*
 * The panic record (roadmap B3, decisions/0131, 0134): a page of RAM that SlopOS's bootloader keeps at the same place
 * every boot, out of what the kernel uses (BootInfo.panic_record). The kernel writes its fatal lines there and seals it
 * when it stops for a fault; a warm reset keeps RAM, so the next boot's bootloader finds it sealed, keeps its text on
 * the ESP and hands it to the root task as the module LAST_PANIC_MODULE, and starts it empty again.
 */

/** The value of a sealed record's magic: "SLOPPANC" in ASCII, read little-endian. */
PANIC_RECORD_MAGIC : u64 : 0x434e4150504f4c53
/** The bytes of text a record holds, what's left of its 4096-byte page after its four u64 fields. */
PANIC_TEXT_BYTES :: 4064
/** The name of the module the bootloader hands the boot after a panic, holding the panic record's text. */
LAST_PANIC_MODULE :: "last_panic"

/** The panic record's page, laid out exactly as the bootloader and the kernel both read it: 4096 bytes. */
PanicRecord :: struct {
    /** PANIC_RECORD_MAGIC once sealed; anything else is a record still being written, or RAM the reset didn't keep. */
    magic : u64,
    /** The kernel's StopReason, set when the record is sealed. */
    reason : u64,
    /** How many bytes of text are used, at most PANIC_TEXT_BYTES; a larger value is garbage, treated as 0. */
    length : u64,
    /** check_of's hash of reason, length and text, so a record a reset half kept isn't believed. */
    check : u64,
    /** The record's text, the kernel's fatal lines; only the first length bytes mean anything. */
    text : u8[PANIC_TEXT_BYTES],
}

#assert size_of(PanicRecord) == 4096

/**
 * Add text to an unsealed record, as much as there's room for.
 *
 * Each character is stored as one byte, truncated to u8. A length past PANIC_TEXT_BYTES, as RAM a reset scrambled
 * leaves, is reset to 0 first. Text past the record's end is dropped silently.
 *
 * @param record The record, through the direct map; its length and text change.
 * @param text The text to append.
 */
panic_record_add :: fn(record: ptr[mut PanicRecord], text: string) {
    if record.length > cast[u64](PANIC_TEXT_BYTES) {
        record.length = 0
    }
    for character in text {
        at :: cast[usize](record.length)
        if at >= record.text.count {
            break
        }
        record.text[at] = cast[u8](character)
        record.length += 1
    }
}

/**
 * Seal a record, so the next boot believes it.
 *
 * The check is computed before the magic is written, so a record stopped partway through sealing isn't taken as sealed.
 *
 * @param record The record, whose reason, check and magic are written (and its length reset to 0 if out of range).
 * @param reason Why the kernel stopped, its StopReason.
 */
panic_record_seal :: fn(record: ptr[mut PanicRecord], reason: u64) {
    record.reason = reason
    if record.length > cast[u64](PANIC_TEXT_BYTES) {
        record.length = 0
    }
    record.check = check_of(record)
    record.magic = PANIC_RECORD_MAGIC
}

/**
 * Read a sealed record's text.
 *
 * @param record The record, which isn't changed.
 * @return The text, a view into the record's own bytes that is valid as long as the record is; null when the record
 *     isn't sealed, its length is out of range, or its check doesn't match.
 */
panic_record_text :: fn(record #escaping : ptr[PanicRecord]) -> string? {
    if record.magic != PANIC_RECORD_MAGIC || record.length > cast[u64](PANIC_TEXT_BYTES) || record.check != check_of(record) {
        return null
    }
    count :: cast[usize](record.length)
    if count > record.text.count {
        return null
    }
    return bit_cast[string](record.text[0..<count])
}

/**
 * Hash a record's contents, for its check.
 *
 * @param record The record, which isn't changed.
 * @return The 64-bit FNV-1a hash of reason's and length's bytes, interleaved low byte first, then of the first length
 *     bytes of text (all of it, when length is larger).
 */
check_of :: fn(record: ptr[PanicRecord]) -> u64 {
    hash := cast[u64](0xcbf29ce484222325)
    for i in cast[u64](0)..<8 {
        hash = (hash ~ ((record.reason >> (i * 8)) & 0xff)) * 0x100000001b3
        hash = (hash ~ ((record.length >> (i * 8)) & 0xff)) * 0x100000001b3
    }
    for byte, i in record.text {
        if cast[u64](i) >= record.length {
            break
        }
        hash = (hash ~ cast[u64](byte)) * 0x100000001b3
    }
    return hash
}
