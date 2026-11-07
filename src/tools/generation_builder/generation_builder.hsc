/**
 * The generation builder (roadmap 9d1, decisions/0113): a hosted program that writes a generation onto an EFI system
 * partition's folder on the host, for the image builder to copy into the ESP, as the update service writes one on the
 * device: the kernel and every boot-set file as objects named by their hashes, and the generation's record, which
 * SlopOS's bootloader boots it by (decisions/0133). tools/boot.py runs it, for boot disks and ISOs.
 *
 *     generation_builder [--recovery] <esp folder> <store folder> <number> <yes|no, for KASLR> <command line> <kernel>
 *         [<file>...]
 *
 * With --recovery, the recovery generation is written beside it, of the same kernel and boot set and command line
 * (decisions/0118), as an installation writes it once.
 *
 * The files are the boot set, root_task.elf first, each named for the kernel by its file name; the store folder is the
 * store builder's, whose root its record names, and each typed library is put in its objects too. The generation is
 * permanent: one built on the host is what's known to boot.
 *
 * Staged instead (decisions/0116), it's an update for the update service to install: its objects put in the store
 * folder's objects, as the bundle store keeps them, and its record, tentative, as the system volume's updates/pending.
 *
 *     generation_builder --stage <system volume folder> <store folder> <number> <yes|no> <command line> <kernel>
 *         <file>...
 */
package generation_builder

import runtime from "base"
import os from "std"
import strings from "std"
import bundle from "../../bundle"
import generations from "../../generations"

/**
 * Write a generation onto an ESP's folder on the host, or, with --stage, stage one in a system volume's folder.
 *
 * Its arguments are as the package says: an optional --recovery, the ESP folder, the store folder, the generation's
 * number, yes or no for KASLR, the kernel's command line, the kernel, and the boot set's files. The ESP's boot,
 * objects and records folders are made if they aren't there.
 *
 * @return 0 once it's written; 1 for too few arguments, 2 if a folder couldn't be made, 3 for a number that isn't one
 *     or a command line too long, 4 if a file couldn't be read or put, 5 for too many boot-set files or too long a
 *     name, 6 if the generation doesn't check, 7 if its record couldn't be written; stage's for --stage.
 */
main :: fn() -> int {
    arguments :: os.arguments()
    if argument(arguments, 1) == "--stage" {
        return stage(arguments)
    }
    // The flags first, in any order, then the arguments from base
    recovery := false
    development := false
    base := cast[usize](1)
    loop {
        flag :: argument(arguments, base)
        if flag == "--recovery" {
            recovery = true
        }
        else if flag == "--development" {
            development = true
        }
        else {
            break
        }
        base += 1
    }
    if arguments.count < base + 6 {
        runtime.log_error("usage: generation_builder [--recovery] [--development] <esp folder> <store folder> <number> <yes|no> <command line> <kernel> <file>...")
        return 1
    }
    esp :: argument(arguments, base)
    for folder in string.["boot", generations.OBJECTS, generations.RECORDS] {
        storage : u8[1024]
        path :: joined(esp, "/", folder, &storage)
        if !os.is_directory(path) && os.make_directory(path) != null {
            runtime.log_error("generation_builder: can't make %", path)
            return 2
        }
    }
    made := generations.Generation.{magic = generations.MAGIC, state = generations.STATE_PERMANENT}
    made.number = number_of(argument(arguments, base + 2)) or_return 3
    made.kaslr = if argument(arguments, base + 3) == "yes" { 1 } else { 0 }
    made.development = if development { cast[u8](1) } else { cast[u8](0) }
    if !generations.set_line(&made.command_line, argument(arguments, base + 4)) {
        runtime.log_error("generation_builder: the command line is too long")
        return 3
    }
    // The store's root, which the store builder wrote as hex
    root_storage : u8[1024]
    root_text :: os.read_entire_file(joined(argument(arguments, base + 1), "/root", "", &root_storage)) or_else ""
    made.store_root = bundle.from_hex(root_text) or_else bundle.Hash.{}
    made.kernel = put(esp, argument(arguments, base + 5)) or_return 4
    for i in base + 6..<arguments.count {
        at :: cast[usize](made.file_count)
        if at >= made.files.count {
            runtime.log_error("generation_builder: more boot-set files than a generation has room for")
            return 5
        }
        hash :: put(esp, argument(arguments, i)) or_return 4
        if !generations.set_name(&made.files[at].name, file_name(argument(arguments, i))) {
            runtime.log_error("generation_builder: % has too long a name", argument(arguments, i))
            return 5
        }
        made.files[at].hash = hash
        made.file_count += 1
        // A typed library is in the store too, where a substitution names it by its hash, pinned so it's kept (decisions/0122)
        if strings.ends_with(argument(arguments, i), ".library") && !pin_library(argument(arguments, base + 1), argument(arguments, i)) {
            runtime.log_error("generation_builder: can't put % in the store", argument(arguments, i))
            return 4
        }
    }
    match generations.check(&made) {
        case Some(problem) => {
            runtime.log_error("generation_builder: the generation %", problem)
            return 6
        }
        case None => {}
    }
    record_storage : u8[128]
    path_storage : u8[1024]
    record :: generations.bytes_of(&made)
    if os.write_entire_file(joined(esp, "/", generations.record_path(made.number, &record_storage), &path_storage),
        bit_cast[string](record)) != null {
        return 7
    }
    if recovery {
        rescue := made
        rescue.state = generations.STATE_RECOVERY
        rescue.number = generations.RECOVERY_NUMBER
        if os.write_entire_file(joined(esp, "/", generations.record_path(rescue.number, &record_storage), &path_storage),
            bit_cast[string](generations.bytes_of(&rescue))) != null {
            return 7
        }
    }
    return 0
}

/**
 * Stage a generation as an update: its objects in the store folder's objects, and its record, tentative with
 * generations.TRIES tries, as the system volume folder's updates/pending, replacing one there.
 *
 * @param arguments The program's arguments: --stage, the system volume folder, the store folder, the number, yes or
 *     no for KASLR, the command line, the kernel, and at least one boot-set file.
 * @return 0 once it's staged; 1 for too few arguments, 3 for a number that isn't one or a command line too long, 4 if
 *     a file couldn't be read or put, 5 for too many boot-set files or too long a name, 6 if the generation doesn't
 *     check, 7 if its record couldn't be written.
 */
stage :: fn(arguments: string[]) -> int {
    if arguments.count < 9 {
        runtime.log_error("usage: generation_builder --stage <system volume folder> <store folder> <number> <yes|no> <command line> <kernel> <file>...")
        return 1
    }
    system :: argument(arguments, 2)
    store :: argument(arguments, 3)
    made := generations.Generation.{magic = generations.MAGIC, state = generations.STATE_TENTATIVE, tries_left = generations.TRIES}
    made.number = number_of(argument(arguments, 4)) or_return 3
    made.kaslr = if argument(arguments, 5) == "yes" { 1 } else { 0 }
    if !generations.set_line(&made.command_line, argument(arguments, 6)) {
        return 3
    }
    root_storage : u8[1024]
    made.store_root = bundle.from_hex(os.read_entire_file(joined(store, "/root", "", &root_storage)) or_else "") or_else bundle.Hash.{}
    // The store keeps objects as objects/<hex>, as the ESP does under boot/
    made.kernel = put_in(store, "/objects/", argument(arguments, 7)) or_return 4
    for i in cast[usize](8)..<arguments.count {
        at :: cast[usize](made.file_count)
        if at >= made.files.count {
            return 5
        }
        made.files[at].hash = put_in(store, "/objects/", argument(arguments, i)) or_return 4
        if !generations.set_name(&made.files[at].name, file_name(argument(arguments, i))) {
            return 5
        }
        made.file_count += 1
    }
    match generations.check(&made) {
        case Some(problem) => {
            runtime.log_error("generation_builder: the generation %", problem)
            return 6
        }
        case None => {}
    }
    path_storage : u8[1024]
    if os.write_entire_file(joined(system, "/updates/pending", "", &path_storage), bit_cast[string](generations.bytes_of(&made))) != null {
        return 7
    }
    runtime.log_info("generation_builder: generation % staged", made.number)
    return 0
}

/**
 * Put a file as an object in a folder's objects, named by its hash in hex.
 *
 * @param folder The folder, as the store folder.
 * @param objects The objects folder's path in it, separators at both ends, as "/objects/".
 * @param path The host path of the file, read whole; its bytes are hashed and written unchanged as the object.
 * @return Its hash; null if it couldn't be read or written, which isn't logged.
 */
put_in :: fn(folder: string, objects: string, path: string) -> bundle.Hash? {
    contents :: os.read_entire_file(path) or_return null
    hash :: bundle.hash_of(bit_cast[u8[]](contents))
    hex_storage : u8[64]
    folder_storage : u8[1024]
    path_storage : u8[1024]
    if os.write_entire_file(joined(joined(folder, objects, "", &folder_storage), bundle.hex(hash, &hex_storage), "", &path_storage), contents) != null {
        return null
    }
    return hash
}

/**
 * Put a typed library in the store folder's objects, and pin it there as library_<its name without .library>, as the
 * bundle store keeps pins (pins/<name>, its hash in hex), so collection keeps it.
 *
 * @param store The store folder, as the store builder wrote it; its pins folder is made if it isn't there.
 * @param path The library's path, its name ending in .library.
 * @return True once it's put and pinned; false if it couldn't be read or written, or pins/ couldn't be made.
 */
pin_library :: fn(store: string, path: string) -> bool {
    hash :: put_in(store, "/objects/", path) or_return false
    folder_storage : u8[1024]
    pins :: joined(store, "/pins", "", &folder_storage)
    if !os.is_directory(pins) && os.make_directory(pins) != null {
        return false
    }
    name :: file_name(path)
    stem :: name.count - ".library".count
    pin_storage : u8[1024]
    pin :: joined(pins, "/library_", if stem <= name.count { name[0..<stem] } else { name }, &pin_storage)
    hex_storage : u8[64]
    return os.write_entire_file(pin, bundle.hex(hash, &hex_storage)) == null
}

/**
 * Put a file as an object in the ESP's objects, at generations.object_path for its hash.
 *
 * @param esp The ESP folder, whose objects folder has to be there.
 * @param path The host path of the file, read whole; its bytes are hashed and written unchanged as the object.
 * @return Its hash; null, logged, if it couldn't be read or written.
 */
put :: fn(esp: string, path: string) -> bundle.Hash? {
    contents :: match os.read_entire_file(path) {
        case Ok(read) => read
        case Error(error) => {
            runtime.log_error("generation_builder: can't read %", path)
            return null
        }
    }
    hash :: bundle.hash_of(bit_cast[u8[]](contents))
    object_storage : u8[128]
    path_storage : u8[1024]
    if os.write_entire_file(joined(esp, "/", generations.object_path(hash, &object_storage), &path_storage), contents) != null {
        runtime.log_error("generation_builder: can't write %'s object", path)
        return null
    }
    return hash
}

/**
 * Give one of the program's arguments.
 *
 * @param arguments The program's arguments, the program's own name first.
 * @param index Which, from 0.
 * @return The argument; "" past the last.
 */
argument :: fn(arguments: string[], index: usize) -> string {
    return if index < arguments.count { arguments[index] } else { "" }
}

/**
 * Read a decimal number, as a generation's.
 *
 * @param text The digits, nothing else.
 * @return Its value, wrapping past a u64's largest, as it isn't checked; null if text is empty or isn't all digits.
 */
number_of :: fn(text: string) -> u64? {
    if text.count == 0 {
        return null
    }
    value := cast[u64](0)
    for character in text {
        if character < '0' || character > '9' {
            return null
        }
        value = value * 10 + cast[u64](character) - cast[u64]('0')
    }
    return value
}

/**
 * Give a path's last part, as a boot-set file's name.
 *
 * @param path The path, with / or \ separators.
 * @return What's after its last separator, a view into path; all of it without one.
 */
file_name :: fn(path: string) -> string {
    start := cast[usize](0)
    for character, i in path {
        if character == '/' || character == '\\' {
            start = i + 1
        }
    }
    return path[start..<path.count]
}

/**
 * Join three pieces of text, one after another, in storage.
 *
 * @param a The first piece, as a folder's path.
 * @param b The second piece; "" for none.
 * @param c The third; "" for none.
 * @param storage Where they're written; what's past its 1024 bytes is dropped.
 * @return The joined text, a view into storage, good while it is; empty if all are.
 */
joined :: fn(a: string, b: string, c: string, storage: ptr[mut u8[1024]]) -> string {
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
