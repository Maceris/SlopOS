package boot_info

/*
 * The panic record (roadmap B3, decisions/0131, 0134): a page of RAM that SlopOS's bootloader keeps at the same place
 * every boot, out of what the kernel uses (BootInfo.panic_record). The kernel writes its fatal lines there and seals it
 * when it stops for a fault; a warm reset keeps RAM, so the next boot's bootloader finds it sealed, keeps its text on
 * the ESP and hands it to the root task as the module LAST_PANIC_MODULE, and starts it empty again.
 */

PANIC_RECORD_MAGIC : u64 : 0x434e4150504f4c53
PANIC_TEXT_BYTES :: 4064
/** The module the bootloader hands the boot after a panic its record's text in */
LAST_PANIC_MODULE :: "last_panic"

PanicRecord :: struct {
    /** PANIC_RECORD_MAGIC once sealed; anything else is a record still being written, or RAM the reset didn't keep */
    magic : u64,
    // The kernel's StopReason
    reason : u64,
    length : u64,
    // check_of's, so a record a reset half kept isn't believed
    check : u64,
    text : u8[PANIC_TEXT_BYTES],
}

#assert size_of(PanicRecord) == 4096

/** text added to an unsealed record, as much as there's room for. */
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

/** The record sealed, with why the kernel stopped. */
panic_record_seal :: fn(record: ptr[mut PanicRecord], reason: u64) {
    record.reason = reason
    if record.length > cast[u64](PANIC_TEXT_BYTES) {
        record.length = 0
    }
    record.check = check_of(record)
    record.magic = PANIC_RECORD_MAGIC
}

/** A sealed record's text, or null if the record isn't one. */
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

/** FNV-1a over the reason, the length and the text. */
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
