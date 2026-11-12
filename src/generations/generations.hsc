/**
 * System generations (roadmap 9d1, decisions/0113, design/software.md §5): what boots, as a record on the EFI system
 * partition. A generation is numbered, and names its kernel, its boot set (each file by the name the kernel gives its
 * module and by its BLAKE3-256 hash), the bundle store's root it boots with, and its kernel's command line; it's
 * tentative until it's reported healthy, then permanent, or it's the recovery generation.
 *
 * On the ESP, every boot-set file and kernel is an object named by its hash, boot/objects/<hex>, shared by every
 * generation that has it; and each generation's record is boot/generations/<number>, which SlopOS's bootloader boots
 * the newest it can of (decisions/0133, 0134). The generation builder (src/tools/generation_builder) writes them for
 * the image builder, and the update service on the device (9d3).
 *
 * A record is fixed-size plain data, so whatever reads one, a hosted tool or the root task, checks its bytes (check)
 * before trusting them.
 */
package generations

import bundle from "../bundle"

/** The first 8 bytes of every generation's record: "SLOPGEN1" in ASCII, read as a little-endian u64. */
MAGIC : u64 : 0x314e4547504f4c53
/**
 * The most files a generation's boot set may have. Every program an ISO boots with is in its generation's boot set
 * (decisions/0135), so this bounds what an ISO can boot with.
 */
MAX_BOOT_FILES :: 128
/** The bytes a boot-set file's name takes in a record, its terminating zero included: names are 31 bytes at most. */
NAME_BYTES :: 32
/** The bytes a kernel's command line takes in a record, its terminating zero included: 511 bytes of text at most. */
COMMAND_LINE_BYTES :: 512

/** The boots a tentative generation is given to come up healthy in (tries_left): its record's largest tries_left. */
TRIES : u8 : 3

// What a generation is: booted only as a trial until it's reported healthy, kept for good, or the recovery generation
/** A generation's state: tentative, booted only as a trial, TRIES times at most, until it's reported healthy. */
STATE_TENTATIVE : u8 : 0
/** A generation's state: permanent, reported healthy and kept for good; its tries_left is 0. */
STATE_PERMANENT : u8 : 1
/** A generation's state: the recovery generation, numbered RECOVERY_NUMBER, and the only one that is. */
STATE_RECOVERY : u8 : 2
/**
 * The recovery generation's number, and only its (roadmap 9d5, decisions/0118): written once, beside the first, pinned,
 * never collected, and booting the boot set and the console only.
 */
RECOVERY_NUMBER : u64 : 0xffffffff

/** A boot-set file: the name the kernel gives its module, and its hash, which names its object. */
BootFile :: struct {
    /**
     * The name the kernel gives the file's module, ended by a zero within its bytes, zeros after; never empty in a
     * checked record. The first file's is root_task.elf.
     */
    name : u8[NAME_BYTES],
    /** The file's BLAKE3-256 hash, which names its object on the ESP (object_path). */
    hash : bundle.Hash,
}

/**
 * A generation's record, exactly as it's stored on the ESP at boot/generations/<number>: fixed-size plain data, read
 * and written as its bytes (bytes_of, generation_of), so its layout is the format and isn't changed lightly.
 */
Generation :: struct {
    /** MAGIC, marking the bytes as a generation's record. */
    magic : u64,
    /**
     * The generation's number, its record's name; never 0. Newer generations have larger numbers, and
     * RECOVERY_NUMBER is the recovery generation's alone.
     */
    number : u64,
    /** What the generation is: STATE_TENTATIVE, STATE_PERMANENT or STATE_RECOVERY. */
    state : u8,
    /** Whether the bootloader lays the kernel and the direct map out at random (decisions/0021): 1 if so, 0 if not. */
    kaslr : u8,
    /**
     * A tentative generation's boots left before it's given up on (roadmap B3, decisions/0131), 0 to TRIES: the update
     * service installs it with TRIES, SlopOS's bootloader takes one each time it boots it, and one with none left isn't
     * booted again, the one before it booted instead; 0 for a permanent one, which never runs out.
     */
    tries_left : u8,
    /**
     * Whether it was built for development (decisions/0181, F7, design/lessons.md §1.5): 1 if so, when the bootloader
     * lets its command line be edited before it boots; 0 if not, when it boots only with the command line it was built
     * with.
     */
    development : u8,
    /** Zeros, keeping kernel 8-byte aligned; not checked. */
    padding : u8[4],
    /** The kernel's BLAKE3-256 hash, which names its object on the ESP (object_path). */
    kernel : bundle.Hash,
    /** The hash of the bundle store's root the generation boots with. */
    store_root : bundle.Hash,
    /** How many of files are the boot set, 0 to MAX_BOOT_FILES; 0 for a kernel booted alone. */
    file_count : u32,
    /**
     * When it was built, in seconds since 1970-01-01T00:00:00Z, which the clock starts no earlier than (decisions/0188,
     * 13e): 0 if it isn't known, as in a record written before it was kept. Not checked.
     */
    built : u32,
    /** The boot set, its first file_count entries, the first the root task's; the rest are zeros, not checked. */
    files : BootFile[MAX_BOOT_FILES],
    /**
     * Its kernel's command line, to which the bootloader adds generation=<number> (bootloader.write_command_line):
     * text ended by a zero within its bytes, zeros after.
     */
    command_line : u8[COMMAND_LINE_BYTES],
}

/* Where the ESP keeps objects and generations' records. */
/** The ESP's directory of objects, each a kernel or boot-set file named by its hash in hex (object_path). */
OBJECTS :: "boot/objects"
/** The ESP's directory of generations' records, each named by its generation's number in decimal (record_path). */
RECORDS :: "boot/generations"

/**
 * Check whether a generation's record is one, before anything trusts it.
 *
 * A record is one when it has its magic and a number, a state it can have, a kaslr of 0 or 1, tries_left at most
 * TRIES, RECOVERY_NUMBER exactly when it's the recovery generation, its files within its array and each named, the
 * first the root task's, and its command line ended within its bytes. A kernel alone, with no boot set, is one, as
 * tests of the kernel boot it (decisions/0135). The paddings, the hashes, the files past file_count, and whether a
 * permanent generation's tries_left is 0 aren't checked.
 *
 * @param generation The record, which isn't changed.
 * @return Null if it's a generation's record, or why it isn't: a constant phrase to follow "the record", such as
 *     "has no number".
 */
check :: fn(generation: ptr[Generation]) -> string? {
    if generation.magic != MAGIC {
        return "isn't a generation's record"
    }
    if generation.number == 0 {
        return "has no number"
    }
    if generation.state > STATE_RECOVERY || generation.kaslr > 1 || generation.tries_left > TRIES || generation.development > 1 {
        return "has a state or a flag that isn't one"
    }
    if (generation.state == STATE_RECOVERY) != (generation.number == RECOVERY_NUMBER) {
        return "is numbered as the recovery generation and isn't it, or is it and isn't numbered as it"
    }
    if generation.file_count > MAX_BOOT_FILES {
        return "has more files than there's room for"
    }
    for i in cast[usize](0)..<generation.files.count {
        if i >= cast[usize](generation.file_count) {
            break
        }
        if text_of(&generation.files[i].name).count == 0 || !ended(&generation.files[i].name) {
            return "has a boot-set file without a name"
        }
    }
    if generation.file_count > 0 && text_of(&generation.files[0].name) != "root_task.elf" {
        return "doesn't start with the root task"
    }
    if !ended_line(&generation.command_line) {
        return "has a command line that doesn't end"
    }
    return null
}

/**
 * Read a generation from its record's bytes, and check it.
 *
 * @param bytes The record's bytes, exactly size_of(Generation) of them; copied, not kept.
 * @return A copy of the generation, or null if bytes are another size or check refuses them.
 */
generation_of :: fn(bytes: u8[]) -> Generation? {
    if bytes.count != size_of(Generation) {
        return null
    }
    made := Generation.{}
    copy_into(view_of(cast[ptr[mut u8]](&made), size_of(Generation)), bytes)
    if check(&made) is_some {
        return null
    }
    return made
}

/**
 * View a generation as the bytes its record holds, for writing it.
 *
 * @param generation The generation; it's not copied.
 * @return Its size_of(Generation) bytes, a view of generation itself, good as long as it is.
 */
bytes_of :: fn(generation: ptr[Generation]) -> u8[] {
    return view_of(cast[ptr[u8]](generation), size_of(Generation))
}

/**
 * Make the ESP path of an object: boot/objects/<hex>, the hash in 64 hex digits (bundle.hex).
 *
 * @param hash The kernel's or boot-set file's BLAKE3-256 hash.
 * @param storage Where the path's bytes are written: 77 of them, the rest left as they were.
 * @return The path, a view of storage, good as long as storage is and isn't written again.
 */
object_path :: fn(hash: bundle.Hash, storage: ptr[mut u8[128]]) -> string {
    hex_storage : u8[64]
    return joined(OBJECTS, "/", bundle.hex(hash, &hex_storage), storage)
}

/**
 * Make the ESP path of a generation's record: boot/generations/<number>, the number in decimal.
 *
 * @param number The generation's number; any, 0 giving boot/generations/0.
 * @param storage Where the path's bytes are written: 18 to 37 of them, the rest left as they were.
 * @return The path, a view of storage, good as long as storage is and isn't written again.
 */
record_path :: fn(number: u64, storage: ptr[mut u8[128]]) -> string {
    digits : u8[20]
    return joined(RECORDS, "/", decimal(number, &digits), storage)
}

/**
 * Give a boot-set file's name as text.
 *
 * @param name A boot-set file's name field, as a record holds it; only read, and not checked to be ended (ended does
 *     that).
 * @return Its bytes up to the first zero, all NAME_BYTES of them if there's none, as a view of name, good as long as
 *     name is; empty if the first byte is zero.
 */
text_of :: fn(name: ptr[u8[NAME_BYTES]]) -> string {
    count := cast[usize](0)
    for byte in name^ {
        if byte == 0 {
            break
        }
        count += 1
    }
    return if count > 0 { string_of(&name^[0], count) } else { "" }
}

/**
 * Give a kernel's command line as text.
 *
 * @param line The command line's bytes.
 * @return Its bytes up to the first zero, all COMMAND_LINE_BYTES of them if there's none, as a view of line, good as
 *     long as line is; empty if the first byte is zero.
 */
line_of :: fn(line: ptr[u8[COMMAND_LINE_BYTES]]) -> string {
    count := cast[usize](0)
    for byte in line^ {
        if byte == 0 {
            break
        }
        count += 1
    }
    return if count > 0 { string_of(&line^[0], count) } else { "" }
}

/**
 * Set a boot-set file's name from text, zeros after it.
 *
 * @param name The name's bytes, all overwritten: with text and zeros, or with zeros alone if text doesn't fit.
 * @param text The name, at most NAME_BYTES - 1 bytes, so a zero follows it; its bytes are copied as they are.
 * @return True if text fit, false if it's NAME_BYTES or more bytes long, leaving name all zeros.
 */
set_name :: fn(name: ptr[mut u8[NAME_BYTES]], text: string) -> bool {
    for i in cast[usize](0)..<name.count {
        name^[i] = 0
    }
    if text.count >= NAME_BYTES {
        return false
    }
    for character, i in text {
        if i < name.count {
            name^[i] = cast[u8](character)
        }
    }
    return true
}

/**
 * Set a kernel's command line from text, zeros after it.
 *
 * @param line The command line's bytes, all overwritten: with text and zeros, or with zeros alone if text doesn't fit.
 * @param text The command line, at most COMMAND_LINE_BYTES - 1 bytes, so a zero follows it; copied as it is.
 * @return True if text fit, false if it's COMMAND_LINE_BYTES or more bytes long, leaving line all zeros.
 */
set_line :: fn(line: ptr[mut u8[COMMAND_LINE_BYTES]], text: string) -> bool {
    for i in cast[usize](0)..<line.count {
        line^[i] = 0
    }
    if text.count >= COMMAND_LINE_BYTES {
        return false
    }
    for character, i in text {
        if i < line.count {
            line^[i] = cast[u8](character)
        }
    }
    return true
}

/**
 * Tell whether a boot-set file's name is ended by a zero within its bytes.
 *
 * @param name A boot-set file's name field, as a record holds it; only read, all NAME_BYTES of it.
 * @return True if any of its bytes is zero.
 */
ended :: fn(name: ptr[u8[NAME_BYTES]]) -> bool {
    for byte in name^ {
        if byte == 0 {
            return true
        }
    }
    return false
}

/**
 * Tell whether a kernel's command line is ended by a zero within its bytes.
 *
 * @param line The command line's bytes.
 * @return True if any of its bytes is zero.
 */
ended_line :: fn(line: ptr[u8[COMMAND_LINE_BYTES]]) -> bool {
    for byte in line^ {
        if byte == 0 {
            return true
        }
    }
    return false
}

/**
 * Copy bytes into a view, as many as both have.
 *
 * @param into Where the bytes go; bytes past from's count are left as they were.
 * @param from The bytes copied; those past into's count aren't copied. It mustn't overlap into.
 */
copy_into :: fn(into: mut u8[], from: u8[]) {
    for i in 0..<into.count {
        if i < from.count {
            into[i] = from[i]
        }
    }
}

/**
 * Write a number in decimal, without leading zeros.
 *
 * @param value The number; 0 gives "0".
 * @param digits Where the digits are written, 1 to 20 of them, the rest left as they were.
 * @return The digits, a view of digits, good as long as digits is and isn't written again.
 */
decimal :: fn(value: u64, digits: ptr[mut u8[20]]) -> string {
    reversed : u8[20]
    count := cast[usize](0)
    left := value
    loop {
        if count < reversed.count {
            reversed[count] = cast[u8](48 + left % 10)
            count += 1
        }
        left /= 10
    }
    while left != 0
    for i in cast[usize](0)..<count {
        at :: count - 1 - i
        if i < digits.count && at < reversed.count {
            digits^[i] = reversed[at]
        }
    }
    return string_of(&digits^[0], count)
}

/**
 * Join three strings into storage, one after another.
 *
 * @param a The first string, any length, "" for none; its bytes are copied first, so it needn't outlive the call.
 * @param b The second string, after a.
 * @param c The third string, after b.
 * @param storage Where the joined bytes are written; what doesn't fit in its 128 bytes is silently left out.
 * @return The joined text, at most 128 bytes, a view of storage, good as long as storage is and isn't written again;
 *     empty if all three are.
 */
joined :: fn(a: string, b: string, c: string, storage: ptr[mut u8[128]]) -> string {
    count := cast[usize](0)
    for text in string.[a, b, c] {
        for character in text {
            if count < storage.count {
                storage^[count] = cast[u8](character)
                count += 1
            }
        }
    }
    return if count > 0 { string_of(&storage^[0], count) } else { "" }
}
