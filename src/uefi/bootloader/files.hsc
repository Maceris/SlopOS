package bootloader

import runtime from "base"
import uefi from "std/os"

/*
 * The ESP, through the firmware's file system protocol on the device the bootloader was loaded from: whole files read
 * into pages, and a folder's names listed. FAT is the firmware's to read, so the bootloader parses none of it.
 */

// A file's bytes, in pages of a memory kind the bootloader chose, which stay where they are.
Pages :: struct {
    address : u64,
    size : u64,
}

// The ESP's root folder, or null.
esp_root :: fn() -> ptr[uefi.File]? {
    loaded :: uefi.protocol_of[uefi.LoadedImage](uefi.image(), uefi.LOADED_IMAGE_GUID) or_return null
    file_system :: uefi.protocol_of[uefi.SimpleFileSystem](loaded.device, uefi.SIMPLE_FILE_SYSTEM_GUID) or_return null
    root : rawptr = null
    if file_system.open_volume(file_system, &root) != uefi.SUCCESS || root == null {
        return null
    }
    return cast[ptr[uefi.File]](root)
}

// A path in UTF-16 as the firmware takes it, folders separated by backslashes, ending in a zero: into storage.
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

// The file at path, opened to read, or null.
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

// The size of a file, from its information, or null.
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

/*
 * The whole file at path, in pages of memory_kind, and its size; null if it isn't there or can't be read whole. Pages
 * are zeroed past its end.
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

/*
 * bytes written over the start of the file at path, made if it isn't there, and flushed: whether they all were. What's
 * written here, a generation's record or the seed, is always the same size, so nothing's left past it.
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

// The names in the folder at path, as text, which the caller frees, or null.
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

// count bytes' worth of pages of memory_kind, zeroed, or null.
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

// size bytes at address zeroed.
zero :: fn(address: u64, size: u64) {
    for i in cast[u64](0)..<size / 8 {
        cast[ptr[mut u64]](cast[rawptr](address + i * 8))^ = 0
    }
}
