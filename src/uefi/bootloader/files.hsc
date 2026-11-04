package bootloader

import runtime from "base"
import uefi from "std/os"

/*
 * The ESP, through the firmware's file system protocol on the device the bootloader was loaded from: whole files read
 * into pages, and a folder's names listed. FAT is the firmware's to read, so the bootloader parses none of it.
 */

/** A file's bytes, in pages of a memory kind the bootloader chose, which stay where they are. */
Pages :: struct {
    /** The physical address of the first page, 4096-aligned; identity-mapped while boot services run. */
    address : u64,
    /** The file's size in bytes; the pages hold it rounded up to 4096, at least one page, zeroed past it. */
    size : u64,
}

/**
 * Open the root folder of the volume the bootloader was loaded from, the ESP.
 *
 * Boot services have to be running: it asks the firmware for the loaded image's device and its simple file system.
 *
 * @return The root folder, open, which the caller may keep open for the bootloader's run; null if the image's device
 *     has no file system protocol or the volume couldn't be opened.
 */
esp_root :: fn() -> ptr[uefi.File]? {
    loaded :: uefi.protocol_of[uefi.LoadedImage](uefi.image(), uefi.LOADED_IMAGE_GUID) or_return null
    file_system :: uefi.protocol_of[uefi.SimpleFileSystem](loaded.device, uefi.SIMPLE_FILE_SYSTEM_GUID) or_return null
    root : rawptr = null
    if file_system.open_volume(file_system, &root) != uefi.SUCCESS || root == null {
        return null
    }
    return cast[ptr[uefi.File]](root)
}

/**
 * Write a path into storage in UTF-16 as the firmware takes it, folders separated by backslashes, ending in a zero.
 *
 * Each byte of text becomes one UTF-16 unit as it is, so the path should be ASCII; each forward slash becomes a
 * backslash.
 *
 * @param text The path, ASCII, with folders separated by forward slashes or backslashes.
 * @param storage Where the UTF-16 path goes; it's left unchanged when text doesn't fit.
 * @return True if text fit with its terminating zero, at most 255 bytes; false otherwise.
 */
path16 :: fn(text: string, storage: ptr[mut u16[256]]) -> bool {
    if text.count + 1 > storage^.count {
        return false
    }
    for character, i in string_bytes(text) {
        if i < storage^.count {
            storage^[i] = if character == cast[u8]('/') { cast[u16]('\\') } else { cast[u16](character) }
        }
    }
    if text.count < storage^.count {
        storage^[text.count] = 0
    }
    return true
}

/**
 * Open the file or folder at a path to read.
 *
 * @param root The folder path is relative to, usually esp_root's.
 * @param path The path, ASCII, at most 255 bytes, folders separated by slashes.
 * @return The file, open, which the caller closes; null if path is too long, or isn't there, or couldn't be opened.
 */
open_file :: fn(root: ptr[uefi.File], path: string) -> ptr[uefi.File]? {
    name : u16[256]
    if !path16(path, &name) {
        return null
    }
    opened : rawptr = null
    if root.open(root, &opened, &name[0], uefi.FILE_READ, 0) != uefi.SUCCESS || opened == null {
        return null
    }
    return cast[ptr[uefi.File]](opened)
}

/**
 * Read a file's size from the firmware's information on it.
 *
 * The information has to fit in 512 bytes with the file's name, which a file on the ESP's short names does.
 *
 * @param file The file, open.
 * @return The file's size in bytes; null if the firmware couldn't give its information, as when it didn't fit.
 */
file_size :: fn(file: ptr[uefi.File]) -> u64? {
    // The information, then its name, which a file's on the ESP keeps short
    buffer : u64[64]
    size := cast[usize](buffer.count * 8)
    info_guid := uefi.FILE_INFO_GUID
    if file.get_info(file, &info_guid, &size, cast[rawptr](&buffer[0])) != uefi.SUCCESS {
        return null
    }
    return cast[ptr[uefi.FileInfo]](cast[rawptr](&buffer[0])).file_size
}

/**
 * Read the whole file at a path into newly allocated pages.
 *
 * The pages are zeroed past the file's end, and an empty file still gets one page. They're not freed if reading fails
 * part way.
 *
 * @param root The folder path is relative to, usually esp_root's.
 * @param path The file's path, ASCII, at most 255 bytes, folders separated by slashes.
 * @param memory_kind The UEFI memory type the pages are allocated as (UEFI specification, EFI_MEMORY_TYPE), which says
 *     whether they outlive boot services.
 * @return The file's pages and its size; null if it isn't there, its size couldn't be read, pages couldn't be had, or
 *     a read failed or returned nothing before the end.
 */
read_file :: fn(root: ptr[uefi.File], path: string, memory_kind: u32) -> Pages? {
    file :: open_file(root, path) or_return null
    defer _ = file.close(file)
    size :: file_size(file) or_return null
    address :: allocate_pages(memory_kind, if size == 0 { cast[u64](1) } else { size }) or_return null
    done := cast[u64](0)
    loop {
        if done >= size {
            break
        }
        chunk := cast[usize](size - done)
        if file.read(file, &chunk, cast[rawptr](address + done)) != uefi.SUCCESS || chunk == 0 {
            return null
        }
        done += cast[u64](chunk)
    }
    return Pages.{address = address, size = size}
}

/**
 * Write bytes over the start of the file at a path, making it if it isn't there, and flush it.
 *
 * The file isn't truncated: what was past bytes' end stays. What's written here, a generation's record or the seed, is
 * always the same size, so nothing's left past it.
 *
 * @param root The folder path is relative to, usually esp_root's.
 * @param path The file's path, ASCII, at most 255 bytes, folders separated by slashes; its folder has to exist.
 * @param bytes What to write; it can't be empty.
 * @return True if every byte was written and the file flushed; false if bytes was empty, path too long, or the file
 *     couldn't be opened, written whole or flushed.
 */
write_file :: fn(root: ptr[uefi.File], path: string, bytes: u8[]) -> bool {
    name : u16[256]
    if !path16(path, &name) || bytes.count == 0 {
        return false
    }
    opened : rawptr = null
    if root.open(root, &opened, &name[0], uefi.FILE_READ | uefi.FILE_WRITE | uefi.FILE_CREATE, 0) != uefi.SUCCESS || opened == null {
        return false
    }
    file :: cast[ptr[uefi.File]](opened)
    defer _ = file.close(file)
    if file.set_position(file, 0) != uefi.SUCCESS {
        return false
    }
    size := bytes.count
    if file.write(file, &size, cast[rawptr](&bytes[0])) != uefi.SUCCESS || size != bytes.count {
        return false
    }
    return file.flush(file) == uefi.SUCCESS
}

/**
 * List the names in the folder at a path.
 *
 * Names are kept as ASCII, each other character as a question mark, and cut at 200 characters; the entries the
 * firmware gives, such as "." and "..", are all listed. Listing stops at an entry whose information doesn't fit in
 * 1024 bytes, or at a read that fails.
 *
 * @param root The folder path is relative to, usually esp_root's.
 * @param path The folder's path, ASCII, at most 255 bytes, folders separated by slashes.
 * @return The names, in the firmware's order, the array and each name allocated with context's allocator for the
 *     caller to free; null if the folder couldn't be opened.
 */
folder_names :: fn(root: ptr[uefi.File], path: string) -> string[..]? {
    folder :: open_file(root, path) or_return null
    defer _ = folder.close(folder)
    names : string[..]
    loop {
        buffer : u64[128]
        size := cast[usize](buffer.count * 8)
        if folder.read(folder, &size, cast[rawptr](&buffer[0])) != uefi.SUCCESS || size == 0 {
            break
        }
        // The name, in UTF-16 after the information, as ASCII, which generations' and objects' names are
        name_at :: cast[u64](cast[rawptr](&buffer[0])) + cast[u64](size_of(uefi.FileInfo))
        text : u8[..]
        for i in cast[u64](0)..<200 {
            character :: cast[ptr[u16]](cast[rawptr](name_at + i * 2))^
            if character == 0 || name_at + i * 2 + 2 > cast[u64](cast[rawptr](&buffer[0])) + cast[u64](size) {
                break
            }
            runtime.array_add(&text, if character < 0x80 { cast[u8](character) } else { cast[u8]('?') })
        }
        runtime.array_add(&names, bit_cast[string](text[0..<text.count]))
    }
    return names
}

/**
 * Allocate zeroed pages from the firmware, anywhere in memory.
 *
 * Boot services have to be running.
 *
 * @param memory_kind The UEFI memory type the pages are allocated as (UEFI specification, EFI_MEMORY_TYPE).
 * @param count How many bytes the pages have to hold, rounded up to whole 4096-byte pages.
 * @return The first page's physical address, 4096-aligned; null if boot services are gone or the firmware refused.
 */
allocate_pages :: fn(memory_kind: u32, count: u64) -> u64? {
    services :: uefi.boot_services() or_return null
    pages :: (count + 4095) / 4096
    address : u64 = 0
    if services.allocate_pages(cast[u32](uefi.AllocateKind.AnyPages), memory_kind, cast[usize](pages), &address) != uefi.SUCCESS {
        return null
    }
    zero(address, pages * 4096)
    return address
}

/**
 * Zero memory a 64-bit word at a time.
 *
 * @param address The physical address to start at, identity-mapped and 8-aligned.
 * @param size How many bytes to zero; only whole 8-byte words are, so a remainder past the last multiple of 8 isn't.
 */
zero :: fn(address: u64, size: u64) {
    for i in cast[u64](0)..<size / 8 {
        cast[ptr[mut u64]](cast[rawptr](address + i * 8))^ = 0
    }
}
