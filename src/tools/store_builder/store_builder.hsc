/*
 * The store builder (roadmap 9b, decisions/0094): a hosted program that writes a bundle store's directory on the host,
 * for the image builder to copy into the system volume, as the bundle store keeps it: each program given an object,
 * named by its BLAKE3-256 hash in hex under objects/, with a bundle naming it, and a boot root naming each bundle by the
 * program's file name without its extension, whose hash is in root. tools/boot.py runs it.
 *
 *     store_builder <store folder> <program>...
 *
 * A bundle's manifest is all zeros for now: nothing extracts a program's entry type's schema from its build yet
 * (decisions/0044).
 */
package store_builder

import runtime from "base"
import os from "std"
import bundle from "../../bundle"

main :: fn() -> int {
    arguments :: os.arguments()
    if arguments.count < 2 {
        runtime.log_error("usage: store_builder <store folder> <program>...")
        return 1
    }
    store :: arguments[1]
    objects_storage : u8[1024]
    objects :: joined(store, "/objects", &objects_storage)
    for folder in string.[store, objects] {
        if !os.is_directory(folder) && os.make_directory(folder) != null {
            runtime.log_error("store_builder: can't make %", folder)
            return 2
        }
    }
    entries : bundle.RootEntry[..]
    defer runtime.array_free(&entries)
    for i in cast[usize](2)..<arguments.count {
        path :: arguments[i]
        program :: match os.read_entire_file(path) {
            case Ok(read) => read
            case Error(error) => {
                runtime.log_error("store_builder: can't read %", path)
                return 3
            }
        }
        program_bytes :: bit_cast[u8[]](program)
        program_hash :: bundle.hash_of(program_bytes)
        put(objects, program_bytes) or_return 4
        made :: bundle.Bundle.{program = program_hash}
        record : u8[..]
        bundle.write(made, &record)
        bundle_hash :: put(objects, record) or_return 4
        runtime.array_add(&entries, bundle.RootEntry.{name = stem(path), bundle = bundle_hash})
    }
    root_record : u8[..]
    bundle.write(bundle.Root.{entries = entries}, &root_record)
    root_hash :: put(objects, root_record) or_return 4
    hex_storage : u8[64]
    root_storage : u8[1024]
    if os.write_entire_file(joined(store, "/root", &root_storage), bundle.hex(root_hash, &hex_storage)) != null {
        return 5
    }
    runtime.log_info("store_builder: % bundles, root %", entries.count, bundle.hex(root_hash, &hex_storage))
    return 0
}

// bytes written as an object in objects, named by their hash: the hash, or null if they couldn't be.
put :: fn(objects: string, bytes: u8[]) -> bundle.Hash? {
    hash :: bundle.hash_of(bytes)
    hex_storage : u8[64]
    name_storage : u8[1024]
    folder_storage : u8[1024]
    folder :: joined(objects, "/", &folder_storage)
    path :: joined(folder, bundle.hex(hash, &hex_storage), &name_storage)
    contents :: if bytes.count > 0 { string_of(&bytes[0], bytes.count) } else { "" }
    if os.write_entire_file(path, contents) != null {
        runtime.log_error("store_builder: can't write %", path)
        return null
    }
    return hash
}

// A path's last part, without its extension.
stem :: fn(path: string) -> string {
    start : usize = 0
    end := path.count
    for character, i in path {
        if character == '/' || character == '\\' {
            start = i + 1
            end = path.count
        }
        else if character == '.' {
            end = i
        }
    }
    return if end > start { string_of(cast[ptr[u8]](cast[uintptr](path.data) + cast[uintptr](start)), end - start) } else { "" }
}

joined :: fn(a: string, b: string, storage: ptr[mut u8[1024]]) -> string {
    count : usize = 0
    for text in string.[a, b] {
        for character in text {
            if count < storage.count {
                storage^[count] = cast[u8](character)
                count += 1
            }
        }
    }
    return if count > 0 { string_of(&storage^[0], count) } else { "" }
}
