/**
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

/** The stand-in disk's size in 512-byte sectors, 34 MiB: with a sector a cluster, just enough clusters to be FAT32. */
SECTORS : u64 : 69632

/**
 * A disk in memory. Undoing, it keeps each sector's bytes from before it's first written, so the fuzzer puts back
 * what a round changed without copying the whole image.
 */
Image :: struct {
    /** The disk's bytes, SECTORS * fat.SECTOR_BYTES of them, the test's own. */
    bytes : mut u8[],
    /** Whether a sector's bytes are saved before its first write (save_sector), so restore can put them back. */
    undoing : bool,
    /** The sectors saved this round, each once, with where their bytes are in saved. */
    undo : Undo[..],
    /** The saved sectors' bytes, fat.SECTOR_BYTES for each of undo, in its order. */
    saved : u8[..],
    /** Whether writes fail, writing nothing, as a failing disk's do. */
    failing : bool,
}

/** A sector's bytes from before a round wrote it, at `at` in saved. */
Undo :: struct {
    /** The sector saved. */
    sector : u64,
    /** Where its fat.SECTOR_BYTES bytes start in the Image's saved. */
    at : usize,
}

/**
 * Run the checks in order, stopping at the first that fails.
 *
 * They check that an empty buffer doesn't mount and a formatted one does, with FSInfo's free count; that 8.3 and long
 * names are made, found in any case, and given aliases; that refused names and paths are refused; that a file is
 * written across clusters, read back whole and from its middle, cut and grown with zeros; that entries are renamed
 * and removed, and a directory with something in it isn't; that a file renamed over another replaces it, a rename
 * that changes only case is allowed, and a write past the end reads zeros in the gap; that it all, and FSInfo's
 * count, is there mounted again; then check_failed_writes and check_fuzz.
 *
 * @return 0 if every check passed, or the number of the first that failed: 1 to 53 here, 60 to 69 from
 *     check_failed_writes, 100 and up from check_fuzz.
 */
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

    // Renamed over another file, it replaces it, the other's cluster freed
    old_file := fat.create(&volume, root, "old.txt", false) or_return 48
    new_file := fat.create(&volume, root, "new.txt", false) or_return 48
    if !written(&volume, &old_file, 0, "the old one") || !written(&volume, &new_file, 0, "the new one") {
        return 48
    }
    free_before_replacing :: fat.free_clusters(&volume) or_return 48
    replacing := fat.rename(&volume, &new_file, root, "old.txt") or_return 49
    if (fat.lookup(&volume, root, "new.txt") is_ok) || read_back(&volume, &replacing) != "the new one" {
        return 49
    }
    replaced := fat.lookup(&volume, root, "old.txt") or_return 50
    if read_back(&volume, &replaced) != "the new one" || (fat.free_clusters(&volume) or_else 0) != free_before_replacing + 1 {
        return 50
    }
    // Renamed to the same name in another case, it's renamed, not refused
    recased := fat.rename(&volume, &replaced, root, "OLD.txt") or_return 51
    looked := fat.lookup(&volume, root, "old.txt") or_return 51
    if fat.name_of(&recased) != "OLD.txt" || fat.name_of(&looked) != "OLD.txt" || read_back(&volume, &looked) != "the new one" {
        return 51
    }
    // Cut short, its cluster keeps the old bytes past the cut; a write past the end reads zeros there all the same
    if !done(fat.set_size(&volume, &looked, 3)) || !written(&volume, &looked, 20, "x") {
        return 52
    }
    gapped : u8[21]
    if (fat.read(&volume, &looked, 0, gapped) or_else 0) != 21 || gapped[0] != cast[u8]('t') || gapped[20] != cast[u8]('x') {
        return 53
    }
    for i in cast[usize](3)..<20 {
        if gapped[i] != 0 {
            return 53
        }
    }
    if !done(fat.remove(&volume, &looked)) {
        return 53
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

/**
 * Check what a write the disk fails does (decisions/0112): it's refused, the volume is failed from then on, and what
 * it was to change is refused to reads rather than given as it was, while other files read; written whole again, it
 * reads again, the volume still failed. A volume mounted afresh starts whole.
 *
 * @param image The stand-in disk, its failing set and cleared here.
 * @param device The device over the image, formatted.
 * @return 0 if every check passed, or the number of the first that failed, 60 to 69.
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

/**
 * Tell whether an operation succeeded.
 *
 * @param result What a fat operation with no value gave back, such as set_size's or remove's; its error, if any, is
 *     dropped, not reported.
 * @return True if it's Ok.
 */
done :: fn(result: Result[void, fat.FatError]) -> bool {
    match result {
        case Ok => return true
        case Error(failure) => return false
    }
}

/**
 * Tell whether a directory has an entry at or after a slot.
 *
 * @param volume The volume under test, mounted on the stand-in disk.
 * @param directory The directory's first cluster.
 * @param slot The slot to list from.
 * @return "something" if there's an entry, "" if there's none, "error" if listing failed; not the entry's name.
 */
next_name :: fn(volume: ptr[mut fat.Volume], directory: u32, slot: u32) -> string {
    match fat.next_entry(volume, directory, slot) {
        case Ok(found) => {
            listed := found or_return ""
            return "something"
        }
        case Error(failure) => return "error"
    }
}

/**
 * Write text into a file.
 *
 * @param volume The volume under test, mounted on the stand-in disk.
 * @param entry The file's entry, updated as fat.write updates it.
 * @param offset The byte offset to write at.
 * @param text The text, its bytes written as they are.
 * @return True if all of it was written; false on any error.
 */
written :: fn(volume: ptr[mut fat.Volume], entry: ptr[mut fat.Entry], offset: u64, text: string) -> bool {
    return (fat.write(volume, entry, offset, string_bytes(text)) or_else 0) == cast[u64](text.count)
}

/**
 * Read a file's first 64 bytes as text.
 *
 * @param volume The volume under test, mounted on the stand-in disk.
 * @param entry A file's entry, as lookup gives it, read from offset 0 up to its size; a directory's reads as "".
 * @return Up to 64 bytes read from its start, in a buffer from runtime.new_array that's never freed (it's a test);
 *     "" if it's empty, couldn't be read, or the buffer couldn't be had.
 */
read_back :: fn(volume: ptr[mut fat.Volume], entry: ptr[fat.Entry]) -> string {
    buffer, error :: runtime.new_array(u8, 64)
    if error != null || buffer.count == 0 {
        return ""
    }
    count :: fat.read(volume, entry, 0, buffer) or_else 0
    return string_of(&buffer[0], cast[usize](count))
}

/**
 * Make a short name as it is on the volume, to compare with an entry's.
 *
 * @param text Its 11 bytes, base and extension without a dot; fewer are padded with spaces, more are cut.
 * @return The 11 bytes, as a short entry's name field holds them.
 */
short :: fn(text: string) -> u8[11] {
    made : u8[11]
    for &byte, i in made {
        byte^ = if i < text.count { cast[u8](text[i]) } else { cast[u8](' ') }
    }
    return made
}

/**
 * Read sectors from the stand-in disk, as a fat.Device's read does.
 *
 * @param context The Image, as a rawptr.
 * @param first The first sector, from the image's start.
 * @param count How many sectors.
 * @param into Where they go, at least count * fat.SECTOR_BYTES bytes.
 * @return True if they were read; false if they run past the image's end or into is too small.
 */
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

/**
 * Write sectors to the stand-in disk, as a fat.Device's write does, saving each first if the image is undoing.
 *
 * @param context The Image, as a rawptr.
 * @param first The first sector, from the image's start.
 * @param count How many sectors.
 * @param from Their bytes, at least count * fat.SECTOR_BYTES.
 * @return True if they were written; false, writing nothing, if they run past the image's end, from is too small,
 *     or the image is failing.
 */
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

/**
 * Run the checks, with fault injection as SLOPOS_FAIL asks (robustness/hosted, tools/unit_tests.py --robustness).
 *
 * @return 0 if every check passed, or the number of the first that failed.
 */
main :: fn() -> int {
    return hosted_faults.run(checks)
}
