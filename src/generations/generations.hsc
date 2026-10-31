/*
 * System generations (roadmap 9d1, decisions/0113, design/software.md §5): what boots, as a record on the EFI system
 * partition. A generation is numbered, and names its kernel, its boot set (each file by the name the kernel gives its
 * module and by its BLAKE3-256 hash), the bundle store's root it boots with, and its kernel's command line; it's
 * tentative until it's reported healthy, then permanent, or it's the recovery generation.
 *
 * On the ESP, every boot-set file and kernel is an object named by its hash, boot/objects/<hex>, shared by every
 * generation that has it; each generation's record is boot/generations/<number>; and boot/limine/limine.conf has an
 * entry for each kept generation, newest first and the default, the recovery generation last. The generation builder
 * (src/tools/generation_builder) writes them for the image builder, and the update service on the device (9d3).
 *
 * A record is fixed-size plain data, so whatever reads one, a hosted tool or the root task, checks its bytes (check)
 * before trusting them.
 */
package generations

import runtime from "base"
import bundle from "../bundle"

MAGIC : u64 : 0x314e4547504f4c53
MAX_BOOT_FILES :: 32
NAME_BYTES :: 32
COMMAND_LINE_BYTES :: 512

// What a generation is: booted only as a trial until it's reported healthy, kept for good, or the recovery generation
STATE_TENTATIVE : u8 : 0
STATE_PERMANENT : u8 : 1
STATE_RECOVERY : u8 : 2

// A boot-set file: the name the kernel gives its module (Limine's module_cmdline), and its hash, which names its object.
BootFile :: struct {
    name : u8[NAME_BYTES],
    hash : bundle.Hash,
}

Generation :: struct {
    magic : u64,
    number : u64,
    state : u8,
    // Whether Limine lays the kernel and the direct map out at random (decisions/0021)
    kaslr : u8,
    padding : u8[6],
    kernel : bundle.Hash,
    store_root : bundle.Hash,
    file_count : u32,
    padding_after : u32,
    files : BootFile[MAX_BOOT_FILES],
    // Its kernel's command line, to which Limine's entry adds generation=<number>
    command_line : u8[COMMAND_LINE_BYTES],
}

// Where the ESP keeps objects, generations' records, and Limine's configuration.
OBJECTS :: "boot/objects"
RECORDS :: "boot/generations"
LIMINE_CONF :: "boot/limine/limine.conf"

/*
 * Whether a generation's record is one: its magic, a state it can have, flags that are flags, its files within its
 * array and named, the first the root task's, and its command line ended within its bytes.
 */
check :: fn(generation: ptr[Generation]) -> string? {
    if generation.magic != MAGIC {
        return "isn't a generation's record"
    }
    if generation.number == 0 {
        return "has no number"
    }
    if generation.state > STATE_RECOVERY || generation.kaslr > 1 {
        return "has a state or a flag that isn't one"
    }
    if generation.file_count == 0 || generation.file_count > MAX_BOOT_FILES {
        return "has no boot set, or more files than there's room for"
    }
    for i in cast[usize](0)..<generation.files.count {
        if i >= cast[usize](generation.file_count) {
            break
        }
        if text_of(&generation.files[i].name).count == 0 || !ended(&generation.files[i].name) {
            return "has a boot-set file without a name"
        }
    }
    if text_of(&generation.files[0].name) != "root_task.elf" {
        return "doesn't start with the root task"
    }
    if !ended_line(&generation.command_line) {
        return "has a command line that doesn't end"
    }
    return null
}

// A record's bytes as a generation, checked: null if they aren't one.
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

// A generation's bytes, as its record holds them.
bytes_of :: fn(generation: ptr[Generation]) -> u8[] {
    return view_of(cast[ptr[u8]](generation), size_of(Generation))
}

// boot/objects/<hex>, into storage.
object_path :: fn(hash: bundle.Hash, storage: ptr[mut u8[128]]) -> string {
    hex_storage : u8[64]
    return joined(OBJECTS, "/", bundle.hex(hash, &hex_storage), storage)
}

// boot/generations/<number>, into storage.
record_path :: fn(number: u64, storage: ptr[mut u8[128]]) -> string {
    digits : u8[20]
    return joined(RECORDS, "/", decimal(number, &digits), storage)
}

/*
 * limine.conf for generations, in the order given, the first the default: an entry each, loading its kernel and its
 * boot set by their objects, each module named for the kernel by its module_cmdline; timeout seconds at the menu.
 */
limine_conf :: fn(generations: Generation[], timeout: u64, into: ptr[mut u8[..]]) {
    digits : u8[20]
    add(into, "timeout: ")
    add(into, decimal(timeout, &digits))
    add(into, "\n")
    for at in cast[usize](0)..<generations.count {
        generation :: &generations[at]
        add(into, "\n/SlopOS generation ")
        add(into, decimal(generation.number, &digits))
        add(into, if generation.state == STATE_RECOVERY { " (recovery)" } else if generation.state == STATE_TENTATIVE { " (trial)" } else { "" })
        add(into, "\n    protocol: limine\n    kaslr: ")
        kaslr :: if generation.kaslr == 1 { "yes" } else { "no" }
        add(into, kaslr)
        add(into, "\n    randomise_hhdm_base: ")
        add(into, kaslr)
        add(into, "\n    path: boot():/")
        storage : u8[128]
        add(into, object_path(generation.kernel, &storage))
        add(into, "\n    cmdline: ")
        add(into, line_of(&generation.command_line))
        add(into, " generation=")
        add(into, decimal(generation.number, &digits))
        // The bundle store's root it boots with, which the supervisor loads programs by
        if !bundle.same(generation.store_root, bundle.Hash.{}) {
            hex_storage : u8[64]
            add(into, " store_root=")
            add(into, bundle.hex(generation.store_root, &hex_storage))
        }
        add(into, "\n")
        for i in cast[usize](0)..<generation.files.count {
            if i >= cast[usize](generation.file_count) {
                break
            }
            file :: &generation.files[i]
            add(into, "    module_path: boot():/")
            add(into, object_path(file.hash, &storage))
            add(into, "\n    module_cmdline: ")
            add(into, text_of(&file.name))
            add(into, "\n")
        }
    }
}

// A name's text: its bytes up to the first zero.
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

// A command line's text: its bytes up to the first zero.
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

// A name's bytes from text, zeros after it: false if it doesn't fit, with room for its zero.
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

// A command line's bytes from text, zeros after it: false if it doesn't fit, with room for its zero.
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

ended :: fn(name: ptr[u8[NAME_BYTES]]) -> bool {
    for byte in name^ {
        if byte == 0 {
            return true
        }
    }
    return false
}

ended_line :: fn(line: ptr[u8[COMMAND_LINE_BYTES]]) -> bool {
    for byte in line^ {
        if byte == 0 {
            return true
        }
    }
    return false
}

add :: fn(into: ptr[mut u8[..]], text: string) {
    for character in text {
        runtime.array_add(into, cast[u8](character))
    }
}

copy_into :: fn(into: mut u8[], from: u8[]) {
    for i in 0..<into.count {
        if i < from.count {
            into[i] = from[i]
        }
    }
}

// A number in decimal, into digits.
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

// a, b and c, one after another, into storage.
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
