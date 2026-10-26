package fat_test

import runtime from "base"
import os from "std"
import fat from ".."

/*
 * The fuzzer for FAT's mount path (design/storage.md §9): a volume with directories and files, damaged where its
 * structure is, in its boot sectors, its FATs and its directories, each round mounted and used as far as it goes:
 * every directory walked and every file read, a file made, written, cut, renamed and removed. Nothing may crash or
 * hang; errors are expected. Each round's damage and writes are put back before the next. SLOPOS_FUZZ_ROUNDS asks for
 * more rounds than the default. Checks from 100.
 */

FUZZ_ROUNDS :: 400

check_fuzz :: fn(image: ptr[mut Image], device: fat.Device) -> int {
    volume := fat.mount(device) or_return 100
    root :: fat.root_of(&volume)
    efi := fat.create(&volume, root, "EFI", true) or_return 101
    boot := fat.create(&volume, fat.directory_cluster(&volume, &efi), "BOOT", true) or_return 102
    boot_cluster :: fat.directory_cluster(&volume, &boot)
    data : u8[40000]
    for i in 0..<data.count {
        data[i] = cast[u8](i % 253)
    }
    for name in string.["BOOTX64.EFI", "A long name for a loader.efi", "config.txt", "Another long one, with spaces.conf"] {
        file := fat.create(&volume, boot_cluster, name, false) or_return 103
        if (fat.write(&volume, &file, 0, data) or_else 0) != 40000 {
            return 104
        }
    }
    for i in 0..<30 {
        name : u8[12]
        prefix :: "file-"
        for character, j in prefix {
            if j < name.count {
                name[j] = cast[u8](character)
            }
        }
        name[5] = cast[u8]('a') + cast[u8](i % 26)
        name[6] = cast[u8]('a') + cast[u8](i / 26)
        file := fat.create(&volume, root, string_of(&name[0], 7), false) or_return 105
        _ = fat.write(&volume, &file, 0, data[0..<700])
    }
    rounds : u64 = FUZZ_ROUNDS
    match os.get_environment("SLOPOS_FUZZ_ROUNDS") {
        case Ok(text) => rounds = number_of(text) or_else rounds
        case Error(failure) => {}
    }
    // Where the structure is: the boot sector, the start of each FAT, where the clusters in use are, and the first
    // data clusters, where the directories and the files' first clusters are
    fat_sectors :: volume.fat_sectors
    regions := u64.[0, 1, 32, 2, 32 + fat_sectors, 2, volume.first_data_sector, 120]
    random := Random.{state = 0xfa7fa7fa7fa7fa7f}
    image.undoing = true
    mounted : u64 = 0
    for round in 0..<rounds {
        flips :: next_random(&random) % 6 + 1
        for flip_index in 0..<flips {
            region :: cast[usize](next_random(&random) % 4) * 2
            if region + 1 >= regions.count {
                continue
            }
            sector :: regions[region] + next_random(&random) % regions[region + 1]
            at :: sector * fat.SECTOR_BYTES + next_random(&random) % fat.SECTOR_BYTES
            change :: cast[u8](next_random(&random) % 255 + 1)
            save_sector(image, sector)
            index :: cast[usize](at)
            if index < image.bytes.count {
                image.bytes[index] = image.bytes[index] ~ change
            }
        }
        if exercise(device) {
            mounted += 1
        }
        restore(image)
    }
    image.undoing = false
    runtime.log_info("fuzz: % rounds, % mounted", rounds, mounted)
    return 0
}

// A sector's bytes kept, the first time a round changes it.
save_sector :: fn(image: ptr[mut Image], sector: u64) {
    for each in image.undo {
        if each.sector == sector {
            return void
        }
    }
    runtime.array_add(&image.undo, Undo.{sector = sector, at = image.saved.count})
    start :: cast[usize](sector * fat.SECTOR_BYTES)
    for i in 0..<cast[usize](fat.SECTOR_BYTES) {
        at :: start + i
        if at < image.bytes.count {
            runtime.array_add(&image.saved, image.bytes[at])
        }
    }
}

// Every sector a round changed, as it was.
restore :: fn(image: ptr[mut Image]) {
    for each in image.undo {
        start :: cast[usize](each.sector * fat.SECTOR_BYTES)
        for i in 0..<cast[usize](fat.SECTOR_BYTES) {
            at :: start + i
            from :: each.at + i
            if at < image.bytes.count && from < image.saved.count {
                image.bytes[at] = image.saved[from]
            }
        }
    }
    runtime.array_reset(&image.undo)
    runtime.array_reset(&image.saved)
}

// A damaged volume mounted and used as far as it goes; whether it mounted.
exercise :: fn(device: fat.Device) -> bool {
    volume := fat.Volume.{device = device}
    match fat.mount(device) {
        case Ok(mounted) => volume = mounted
        case Error(failure) => return false
    }
    root :: fat.root_of(&volume)
    walk(&volume, root, 0)
    match fat.create(&volume, root, "fuzzed file.txt", false) {
        case Ok(made) => {
            file := made
            bytes : u8[3000]
            _ = fat.write(&volume, &file, 2000, bytes)
            _ = fat.set_size(&volume, &file, 10)
            match fat.rename(&volume, &file, root, "fuzzed again.txt") {
                case Ok(renamed) => {
                    moved := renamed
                    _ = fat.remove(&volume, &moved)
                }
                case Error(failure) => {}
            }
        }
        case Error(failure) => {}
    }
    _ = fat.resolve(&volume, root, "EFI/BOOT/BOOTX64.EFI")
    return true
}

// Every entry of a directory, a few levels down, and every file read.
walk :: fn(volume: ptr[mut fat.Volume], directory: u32, depth: int) {
    buffer : u8[4096]
    slot : u32 = 0
    for step in 0..<300 {
        listed := fat.Listed.{}
        match fat.next_entry(volume, directory, slot) {
            case Ok(found) => listed = found or_break
            case Error(failure) => return void
        }
        entry := listed.entry
        if entry.attributes & fat.DIRECTORY != 0 {
            if depth < 4 {
                walk(volume, fat.directory_cluster(volume, &entry), depth + 1)
            }
        }
        else {
            _ = fat.read(volume, &entry, 0, buffer)
            _ = fat.read(volume, &entry, cast[u64](entry.size / 2), buffer)
        }
        slot = listed.next
    }
}

// xorshift64*, as slopfs's tests have it.
Random :: struct {
    state : u64,
}

next_random :: fn(random: ptr[mut Random]) -> u64 {
    x := random.state
    x = x ~ (x >> 12)
    x = x ~ (x << 25)
    x = x ~ (x >> 27)
    random.state = x
    return x * 0x2545f4914f6cdd1d
}

number_of :: fn(text: string) -> u64? {
    value : u64 = 0
    if text.count == 0 {
        return null
    }
    for character in text {
        if character < '0' || character > '9' {
            return null
        }
        value = value * 10 + cast[u64](cast[u8](character) - cast[u8]('0'))
    }
    return value
}
