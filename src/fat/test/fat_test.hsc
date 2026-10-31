/*
 * The FAT package's tests, as a hosted program (tools/unit_tests.py): main returns 0 if everything worked, or the
 * number of the first check that failed. A volume formatted in a buffer standing in for a disk is mounted; files and
 * directories are made with short and long names, written across clusters, read back, resized, renamed and removed;
 * a buffer that isn't FAT isn't mounted; a write the disk fails is remembered, its sectors refused to reads until
 * they're written again and the volume failed for good (decisions/0112); and the volume, damaged many ways, is used
 * without crashing (fuzz_test.hsc).
 */
package fat_test

import runtime from "base"
import fat from ".."
import hosted_faults from "../../robustness/hosted"

// 34 MiB of 512-byte sectors, a sector a cluster: just enough clusters to be FAT32
SECTORS : u64 : 69632

/*
 * A disk in memory. Undoing, it keeps each sector's bytes from before it's first written, so the fuzzer puts back
 * what a round changed without copying the whole image.
 */
Image :: struct {
    bytes : mut u8[],
    undoing : bool,
    undo : Undo[..],
    saved : u8[..],
    // Writes fail while it's set, writing nothing
    failing : bool,
}

// A sector's bytes from before a round wrote it, at `at` in saved.
Undo :: struct {
    sector : u64,
    at : usize,
}

checks :: fn() -> int {
    bytes, error :: runtime.new_array(u8, cast[usize](SECTORS * fat.SECTOR_BYTES))
    if error != null {
        return 1
    }
    defer runtime.free_array(bytes)
    image := Image.{bytes = bytes}
    device := fat.Device.{context = cast[rawptr](&image), sector_count = SECTORS, read = read_sectors, write = write_sectors}

    // Nothing there yet
    if fat.mount(device) is_ok {
        return 2
    }
    if fat.format(device, SECTORS, 1, "slopos test") is_some {
        return 3
    }
    volume := fat.mount(device) or_return 4
    root :: fat.root_of(&volume)
    if next_name(&volume, root, 0) != "" {
        return 5
    }
    // Formatted, every cluster but the root's is free, as FSInfo says
    formatted_free :: fat.free_clusters(&volume) or_return 40
    if formatted_free != volume.cluster_count - 1 {
        return 41
    }
    // Made and written to with a stamp, it has it
    stamp :: fat.stamp_of(2026, 10, 30, 12, 34, 56)
    volume.stamp = stamp

    // An 8.3 name in lower case, kept by its case flags, found in any case
    readme := fat.create(&volume, root, "readme.txt", false) or_return 6
    if readme.place.long_entries != 0 || !written(&volume, &readme, 0, "hello, FAT") {
        return 7
    }
    found := fat.lookup(&volume, root, "README.TXT") or_return 8
    if fat.name_of(&found) != "readme.txt" || found.size != 10 || read_back(&volume, &found) != "hello, FAT" {
        return 9
    }
    if found.written != stamp || stamp >> 16 != (46 << 9 | 10 << 5 | 30) || stamp & 0xffff != (12 << 11 | 34 << 5 | 28) {
        return 42
    }
    // A cluster taken for its bytes, counted
    if (fat.free_clusters(&volume) or_else 0) != formatted_free - 1 {
        return 43
    }

    // Long names, and their aliases
    first := fat.create(&volume, root, "A long file name.text", false) or_return 10
    second := fat.create(&volume, root, "A long file name, again.text", false) or_return 11
    if first.place.long_entries == 0 || first.short_name != short("ALONGF~1TEX") || second.short_name != short("ALONGF~2TEX") {
        return 12
    }
    again := fat.lookup(&volume, root, "a LONG file NAME, again.TEXT") or_return 13
    if fat.name_of(&again) != "A long file name, again.text" {
        return 14
    }
    match fat.create(&volume, root, "A LONG FILE NAME.TEXT", false) {
        case Ok(made) => return 15
        case Error(failure) => {
            if failure != .AlreadyExists {
                return 15
            }
        }
    }
    for refused in string.["", "trailing.", "a/b", "star*", "colon:"] {
        if fat.create(&volume, root, refused, false) is_ok {
            return 16
        }
    }

    // A directory, a file beneath it, and a path to it
    boot := fat.create(&volume, root, "boot", true) or_return 17
    boot_cluster :: fat.directory_cluster(&volume, &boot)
    kernel := fat.create(&volume, boot_cluster, "kernel.elf", false) or_return 18
    // 3000 bytes: six clusters of 512
    data : u8[3000]
    for &byte, i in data {
        byte^ = cast[u8](i % 251)
    }
    if (fat.write(&volume, &kernel, 0, data) or_else 0) != 3000 {
        return 19
    }
    resolved := fat.resolve(&volume, root, "boot/KERNEL.ELF") or_return 20
    if resolved.size != 3000 {
        return 21
    }
    back : u8[3000]
    if (fat.read(&volume, &resolved, 0, back) or_else 0) != 3000 || back != data {
        return 22
    }
    // From the middle, across a cluster's end
    middle : u8[700]
    if (fat.read(&volume, &resolved, 1000, middle) or_else 0) != 700 || middle[0] != data[1000] || middle[699] != data[1699] {
        return 23
    }
    for refused in string.["boot/../readme.txt", "./readme.txt", "readme.txt/x", "nowhere/x"] {
        if fat.resolve(&volume, root, refused) is_ok {
            return 24
        }
    }

    // Shorter, then longer, its new bytes zero
    if !done(fat.set_size(&volume, &resolved, 100)) || !done(fat.set_size(&volume, &resolved, 2000)) {
        return 25
    }
    resized := fat.resolve(&volume, root, "boot/kernel.elf") or_return 26
    grown : u8[2000]
    if resized.size != 2000 || (fat.read(&volume, &resized, 0, grown) or_else 0) != 2000 || grown[99] != data[99] || grown[100] != 0
        || grown[1999] != 0 {
        return 27
    }

    // Renamed into the directory, over nothing; then removed; a directory with something in it isn't
    _ = fat.rename(&volume, &first, boot_cluster, "moved.text") or_return 28
    if fat.lookup(&volume, root, "A long file name.text") is_ok {
        return 29
    }
    in_boot := fat.lookup(&volume, boot_cluster, "moved.text") or_return 30
    match fat.remove(&volume, &boot) {
        case Ok => return 31
        case Error(failure) => {
            if failure != .DirectoryNotEmpty {
                return 31
            }
        }
    }
    if !done(fat.remove(&volume, &in_boot)) || !done(fat.remove(&volume, &resized)) || !done(fat.remove(&volume, &boot)) {
        return 32
    }
    if fat.lookup(&volume, root, "boot") is_ok {
        return 33
    }

    // Mounted again, it's all as it was left, FSInfo's count with it once it's written
    free_before :: fat.free_clusters(&volume) or_return 44
    if fat.write_info(&volume) is_some {
        return 45
    }
    remounted := fat.mount(device) or_return 34
    still := fat.lookup(&remounted, fat.root_of(&remounted), "readme.txt") or_return 35
    if read_back(&remounted, &still) != "hello, FAT" || still.written != stamp {
        return 36
    }
    if remounted.free_count != free_before {
        return 46
    }
    // Counted through the FAT, the same
    remounted.free_count = fat.UNKNOWN_FREE
    if (fat.free_clusters(&remounted) or_else 0) != free_before {
        return 47
    }
    failed :: check_failed_writes(&image, device)
    if failed != 0 {
        return failed
    }
    return check_fuzz(&image, device)
}

/*
 * A write the disk fails (decisions/0112): refused, the volume failed from then on, and what it was to change refused
 * to reads rather than given as it was, while other files read; written whole again, it reads again, the volume still
 * failed. A volume mounted afresh starts whole.
 */
check_failed_writes :: fn(image: ptr[mut Image], device: fat.Device) -> int {
    volume := fat.mount(device) or_return 60
    root :: fat.root_of(&volume)
    kept := fat.create(&volume, root, "kept.txt", false) or_return 61
    lost := fat.create(&volume, root, "lost.txt", false) or_return 61
    if !written(&volume, &kept, 0, "kept") || !written(&volume, &lost, 0, "before") || volume.failed {
        return 62
    }
    image.failing = true
    if written(&volume, &lost, 0, "after!") || !volume.failed {
        image.failing = false
        return 63
    }
    image.failing = false
    // Neither the old bytes nor the new: refused
    buffer : u8[16]
    if fat.read(&volume, &lost, 0, buffer) is_ok {
        return 64
    }
    if read_back(&volume, &kept) != "kept" {
        return 65
    }
    // Part of it can't be written, which would need what's there; written whole again, it reads, and the volume stays
    // failed, so every Sync after the failure fails
    if written(&volume, &lost, 0, "again!") {
        return 66
    }
    whole : u8[512]
    for i in 0..<whole.count {
        whole[i] = cast[u8]('w')
    }
    if (fat.write(&volume, &lost, 0, whole) or_else 0) != 512 || !(read_back(&volume, &lost) == "wwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwww") || !volume.failed {
        return 69
    }
    remounted := fat.mount(device) or_return 67
    if remounted.failed {
        return 68
    }
    return 0
}

done :: fn(result: Result[void, fat.FatError]) -> bool {
    match result {
        case Ok => return true
        case Error(failure) => return false
    }
}

// The first entry's name in a directory, or "".
next_name :: fn(volume: ptr[mut fat.Volume], directory: u32, slot: u32) -> string {
    match fat.next_entry(volume, directory, slot) {
        case Ok(found) => {
            listed := found or_return ""
            return "something"
        }
        case Error(failure) => return "error"
    }
}

written :: fn(volume: ptr[mut fat.Volume], entry: ptr[mut fat.Entry], offset: u64, text: string) -> bool {
    return (fat.write(volume, entry, offset, string_bytes(text)) or_else 0) == cast[u64](text.count)
}

read_back :: fn(volume: ptr[mut fat.Volume], entry: ptr[fat.Entry]) -> string {
    buffer, error :: runtime.new_array(u8, 64)
    if error != null || buffer.count == 0 {
        return ""
    }
    count :: fat.read(volume, entry, 0, buffer) or_else 0
    return string_of(&buffer[0], cast[usize](count))
}

short :: fn(text: string) -> u8[11] {
    made : u8[11]
    for &byte, i in made {
        byte^ = if i < text.count { cast[u8](text[i]) } else { cast[u8](' ') }
    }
    return made
}

read_sectors :: fn(context: rawptr, first: u64, count: u64, into: mut u8[]) -> bool {
    image :: cast[ptr[Image]](context)
    start :: first * fat.SECTOR_BYTES
    bytes :: count * fat.SECTOR_BYTES
    if start + bytes > cast[u64](image.bytes.count) || bytes > cast[u64](into.count) {
        return false
    }
    for &byte, i in into {
        at :: cast[usize](start) + i
        if cast[u64](i) < bytes && at < image.bytes.count {
            byte^ = image.bytes[at]
        }
    }
    return true
}

write_sectors :: fn(context: rawptr, first: u64, count: u64, from: u8[]) -> bool {
    image :: cast[ptr[mut Image]](context)
    start :: first * fat.SECTOR_BYTES
    bytes :: count * fat.SECTOR_BYTES
    if start + bytes > cast[u64](image.bytes.count) || bytes > cast[u64](from.count) {
        return false
    }
    if image.failing {
        return false
    }
    if image.undoing {
        for sector in first..<first + count {
            save_sector(image, sector)
        }
    }
    for byte, i in from {
        at :: cast[usize](start) + i
        if cast[u64](i) < bytes && at < image.bytes.count {
            image.bytes[at] = byte
        }
    }
    return true
}

// The checks, with fault injection as SLOPOS_FAIL asks (robustness/hosted, tools/unit_tests.py --robustness)
main :: fn() -> int {
    return hosted_faults.run(checks)
}
