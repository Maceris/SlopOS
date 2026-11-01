/*
 * The generation builder (roadmap 9d1, decisions/0113): a hosted program that writes a generation onto an EFI system
 * partition's folder on the host, for the image builder to copy into the ESP, as the update service writes one on the
 * device: the kernel and every boot-set file as objects named by their hashes, the generation's record, and Limine's
 * configuration with an entry for every generation the folder has records of, newest first, the recovery generation
 * last. tools/boot.py runs it.
 *
 *     generation_builder [--recovery] [--boot-recovery] <esp folder> <store folder> <number> <timeout> <yes|no, for KASLR>
 *         <command line> <kernel> <file>...
 *
 * With --recovery, the recovery generation is written beside it, of the same kernel and boot set and command line
 * (decisions/0118), as an installation writes it once; with --boot-recovery, its entry is the one Limine boots.
 *
 * The files are the boot set, root_task.elf first, each named for the kernel by its file name; the store folder is the
 * store builder's, whose root its record names, and each typed library is put in its objects too. The generation is
 * permanent: one built on the host is what's known to boot.
 *
 * Staged instead (decisions/0116), it's an update for the update service to install: its objects put in the store
 * folder's objects, as the bundle store keeps them, and its record, tentative, as the system volume's updates/pending.
 *
 *     generation_builder --stage <system volume folder> <store folder> <number> <yes|no> <command line> <kernel> <file>...
 */
package generation_builder

import runtime from "base"
import os from "std"
import strings from "std"
import bundle from "../../bundle"
import generations from "../../generations"

main :: fn() -> int {
    arguments :: os.arguments()
    if argument(arguments, 1) == "--stage" {
        return stage(arguments)
    }
    // The flags first, then the arguments from base
    recovery := false
    boot_recovery := false
    base := cast[usize](1)
    loop {
        flag :: argument(arguments, base)
        if flag == "--recovery" {
            recovery = true
        }
        else if flag == "--boot-recovery" {
            boot_recovery = true
        }
        else {
            break
        }
        base += 1
    }
    if arguments.count < base + 8 {
        runtime.log_error("usage: generation_builder <esp folder> <store folder> <number> <timeout> <yes|no> <command line> <kernel> <file>...")
        return 1
    }
    esp :: argument(arguments, base)
    for folder in string.["boot", generations.OBJECTS, generations.RECORDS, "boot/limine"] {
        storage : u8[1024]
        path :: joined(esp, "/", folder, &storage)
        if !os.is_directory(path) && os.make_directory(path) != null {
            runtime.log_error("generation_builder: can't make %", path)
            return 2
        }
    }
    made := generations.Generation.{magic = generations.MAGIC, state = generations.STATE_PERMANENT}
    made.number = number_of(argument(arguments, base + 2)) or_return 3
    timeout :: number_of(argument(arguments, base + 3)) or_return 3
    made.kaslr = if argument(arguments, base + 4) == "yes" { 1 } else { 0 }
    if !generations.set_line(&made.command_line, argument(arguments, base + 5)) {
        runtime.log_error("generation_builder: the command line is too long")
        return 3
    }
    // The store's root, which the store builder wrote as hex
    root_storage : u8[1024]
    root_text :: os.read_entire_file(joined(argument(arguments, base + 1), "/root", "", &root_storage)) or_else ""
    made.store_root = bundle.from_hex(root_text) or_else bundle.Hash.{}
    made.kernel = put(esp, argument(arguments, base + 6)) or_return 4
    for i in base + 7..<arguments.count {
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
    return write_limine_conf(esp, timeout, boot_recovery)
}

/*
 * limine.conf, for every generation the ESP folder has a record of: the others by number, newest first, then the
 * recovery generation.
 */
write_limine_conf :: fn(esp: string, timeout: u64, boot_recovery: bool) -> int {
    folder_storage : u8[1024]
    listed :: os.list_directory(joined(esp, "/", generations.RECORDS, &folder_storage)) or_return 8
    defer os.free_directory_listing(listed)
    kept : generations.Generation[..]
    defer runtime.array_free(&kept)
    for entry in listed {
        storage : u8[1024]
        bytes :: os.read_entire_file(joined(esp, "/", joined_part(generations.RECORDS, entry.name), &storage)) or_continue
        found :: generations.generation_of(bit_cast[u8[]](bytes)) or_continue
        runtime.array_add(&kept, found)
    }
    sort(kept[0..<kept.count])
    text : u8[..]
    defer runtime.array_free(&text)
    // The recovery generation's entry is the last
    default_entry :: if boot_recovery { cast[u64](kept.count) } else { cast[u64](0) }
    generations.limine_conf(kept[0..<kept.count], timeout, default_entry, &text)
    path_storage : u8[1024]
    if os.write_entire_file(joined(esp, "/", generations.LIMINE_CONF, &path_storage), bit_cast[string](text[0..<text.count])) != null {
        return 9
    }
    runtime.log_info("generation_builder: % generations in limine.conf", kept.count)
    return 0
}

// Generations in limine.conf's order: newest first, the recovery generation after every other.
sort :: fn(items: mut generations.Generation[]) {
    for i in cast[usize](0)..<items.count {
        for j in cast[usize](0)..<items.count {
            if j > i && before(items[j], items[i]) {
                swapped :: items[i]
                items[i] = items[j]
                items[j] = swapped
            }
        }
    }
}

// Whether a comes before b in limine.conf.
before :: fn(a: generations.Generation, b: generations.Generation) -> bool {
    a_recovery :: a.state == generations.STATE_RECOVERY
    b_recovery :: b.state == generations.STATE_RECOVERY
    if a_recovery != b_recovery {
        return b_recovery
    }
    return a.number > b.number
}

// A generation staged in the system volume's folder, its objects in the store folder's.
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

// A file put in folder + objects, named by its hash in hex: the hash, or null if it couldn't be read or written.
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

/*
 * A library put in the store folder's objects, and pinned there as library_<its name without .library>, as the bundle
 * store keeps pins (pins/<name>, its hash in hex): whether it was.
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

// A file put in the ESP's objects, named by its hash: the hash, or null if it couldn't be read or written.
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

// The argument at index, or "" past the last.
argument :: fn(arguments: string[], index: usize) -> string {
    return if index < arguments.count { arguments[index] } else { "" }
}

// A decimal number, or null.
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

// A path's last part.
file_name :: fn(path: string) -> string {
    start := cast[usize](0)
    for character, i in path {
        if character == '/' || character == '\\' {
            start = i + 1
        }
    }
    return path[start..<path.count]
}

// folder/name, as a relative path.
joined_part :: fn(folder: string, name: string) -> string {
    storage := runtime.new(u8[1024])
    return joined(folder, "/", name, storage)
}

// a, b, c and d, one after another, into storage.
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
