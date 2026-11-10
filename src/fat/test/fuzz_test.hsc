package fat_test

import runtime from "base"
import os from "std"
import testing from "std"
import fat from ".."

/*
 * The fuzzer for FAT's mount path (design/storage.md §9): a volume with directories and files, damaged where its
 * structure is, in its boot sectors, its FATs and its directories, each round mounted and used as far as it goes:
 * every directory walked and every file read, a file made, written, cut, renamed and removed. Nothing may crash or
 * hang; errors are expected. Each round's damage and writes are put back before the next. SLOPOS_FUZZ_ROUNDS asks for
 * more rounds than the default.
 *
 * The same, as a property test hemera --fuzz guides by coverage (decisions/0186, He): each case's damage is drawn,
 * on a volume set up once (testing.fixture).
 */

/** How many rounds of damage the fuzzer runs unless SLOPOS_FUZZ_ROUNDS asks for another number. */
FUZZ_ROUNDS :: 400

a_volume_damaged_where_its_structure_is_is_used_as_far_as_it_goes_without_crashing #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made := formatted(t)?
    defer free_formatted(&made)
    return check_fuzz(t, made.image, made.device)
}

/** How many changes a property test's case makes at most. */
MOST_CHANGES :: 16

/**
 * Check that a volume damaged where its structure is, as the case draws, can be mounted and used without crashing or
 * hanging: up to MOST_CHANGES bytes changed in the boot sectors, the start of each FAT, or the first data clusters,
 * then exercise, then every sector the case changed put back.
 *
 * @param t The test's state.
 * @param source The case's source: each change's region, sector, byte and the bits it flips.
 * @return Ok once the case has run; Error(Failed) if the volume to damage couldn't be set up.
 */
a_volume_damaged_as_drawn_is_used_as_far_as_it_goes_without_crashing #test :: fn(t: ptr[mut testing.T], source: ptr[mut testing.Source])
    -> testing.Outcome {
    kept :: testing.fixture[FuzzVolume](source, make_fuzz_volume, free_fuzz_volume)
    volume :: testing.require_some(t, kept, "the volume to damage is set up")?
    image :: volume.image
    regions :: volume.regions
    image.undoing = true
    changes :: testing.draw_between(source, 1, MOST_CHANGES)
    for i in 0..<changes {
        region :: cast[usize](testing.draw_below(source, 4)) * 2
        if region >= regions.count - 1 {
            continue
        }
        sector :: regions[region] + testing.draw_below(source, regions[region + 1])
        at :: cast[usize](sector * fat.SECTOR_BYTES + testing.draw_below(source, fat.SECTOR_BYTES))
        change :: testing.draw_between(source, cast[u8](1), cast[u8](255))
        save_sector(image, sector)
        if at < image.bytes.count {
            image.bytes[at] = image.bytes[at] ~ change
        }
    }
    _ = exercise(device_of(image))
    restore(image)
    image.undoing = false
    return .Ok
}

/** What the property test damages: a volume set up as check_fuzz's, once, and where its structure is. */
FuzzVolume :: struct {
    /** The stand-in disk, from new_image's way, freed by free_fuzz_volume. */
    image : ptr[mut Image],
    /** Pairs of a first sector and how many sectors from it, as structure_regions gives them. */
    regions : u64[8],
}

/**
 * Make the property test's volume: a stand-in disk, formatted, mounted and populated as check_fuzz's.
 *
 * @return The volume, the fixture's, freed by free_fuzz_volume; null if any step failed, nothing left to free.
 */
make_fuzz_volume :: fn() -> FuzzVolume? {
    bytes, error :: runtime.new_array(u8, cast[usize](SECTORS * fat.SECTOR_BYTES))
    if error != null {
        return null
    }
    image := runtime.new(Image)
    image^ = Image.{bytes = bytes}
    device :: device_of(image)
    made := FuzzVolume.{image = image}
    ready := false
    if fat.format(device, SECTORS, 1, "slopos test") == null {
        match fat.mount(device) {
            case Ok(mounted) => {
                volume := mounted
                volume.stamp = fat.stamp_of(STAMP_YEAR, 10, 30, 12, 34, 56)
                ready = populate(&volume)
                made.regions = structure_regions(&volume)
            }
            case Error(failure) => {}
        }
    }
    if !ready {
        free_image(image)
        return null
    }
    return made
}

/**
 * Give back what make_fuzz_volume made.
 *
 * @param volume The volume, not used after.
 */
free_fuzz_volume :: fn(volume: ptr[mut FuzzVolume]) {
    free_image(volume.image)
}

/**
 * Make what the fuzzer damages, in a volume just formatted: EFI/BOOT with four files of short and long names, 40000
 * bytes each, and 30 files of 700 bytes in the root.
 *
 * @param volume The volume, mounted.
 * @return Whether it was all made.
 */
populate :: fn(volume: ptr[mut fat.Volume]) -> bool {
    root :: fat.root_of(volume)
    efi := fat.create(volume, root, "EFI", true) or_return false
    boot := fat.create(volume, fat.directory_cluster(volume, &efi), "BOOT", true) or_return false
    boot_cluster :: fat.directory_cluster(volume, &boot)
    data : u8[40000]
    for i in 0..<data.count {
        data[i] = cast[u8](i % 253)
    }
    for name in string.["BOOTX64.EFI", "A long name for a loader.efi", "config.txt", "Another long one, with spaces.conf"] {
        file := fat.create(volume, boot_cluster, name, false) or_return false
        if (fat.write(volume, &file, 0, data) or_else 0) != 40000 {
            return false
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
        file := fat.create(volume, root, string_of(&name[0], 7), false) or_return false
        _ = fat.write(volume, &file, 0, data[0..<700])
    }
    return true
}

/**
 * Say where a volume's structure is: the boot sector, the start of each FAT, where the clusters in use are, and the
 * first data clusters, where the directories and the files' first clusters are.
 *
 * @param volume The volume, mounted.
 * @return Pairs of a first sector and how many sectors from it.
 */
structure_regions :: fn(volume: ptr[fat.Volume]) -> u64[8] {
    return u64.[0, 1, 32, 2, 32 + volume.fat_sectors, 2, volume.first_data_sector, 120]
}

/**
 * Check that a volume damaged where its structure is can be mounted and used without crashing or hanging.
 *
 * It makes directories and files to damage, then runs the rounds: each flips 1 to 6 random bytes in the boot
 * sectors, the start of each FAT, or the first data clusters, runs exercise, and puts every sector the round changed
 * back. Errors from the volume are expected and ignored; only setting it up can fail.
 *
 * @param t The test's state, which a failure is recorded in.
 * @param image The stand-in disk, formatted; its undoing is set during the rounds and cleared after.
 * @param device The device over the image.
 * @return Ok once the rounds have run; Error(Failed), the failure recorded, if the volume to damage couldn't be set
 *     up.
 */
check_fuzz :: fn(t: ptr[mut testing.T], image: ptr[mut Image], device: fat.Device) -> testing.Outcome {
    mounting :: fat.mount(device)
    volume := testing.require_ok(t, mounting, "a formatted volume mounts")?
    testing.require(t, populate(&volume), "directories and files of short and long names are made on it")?
    rounds : u64 = FUZZ_ROUNDS
    match os.get_environment("SLOPOS_FUZZ_ROUNDS") {
        case Ok(text) => rounds = number_of(text) or_else rounds
        case Error(failure) => {}
    }
    regions :: structure_regions(&volume)
    random := Random.{state = 0xfa7fa7fa7fa7fa7f}
    image.undoing = true
    mounted : u64 = 0
    for round in 0..<rounds {
        flips :: next_random(&random) % 6 + 1
        for flip_index in 0..<flips {
            region :: cast[usize](next_random(&random) % 4) * 2
            if region >= regions.count - 1 {
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
    return .Ok
}

/**
 * Save a sector's bytes, the first time a round changes it, so restore can put them back.
 *
 * @param image The stand-in disk; its undo and saved grow, with context's allocator.
 * @param sector The sector; one already saved this round is left as it was saved.
 */
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

/**
 * Put back every sector a round changed, as it was before the round, and forget them.
 *
 * @param image The stand-in disk; its undo and saved are emptied.
 */
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

/**
 * Mount a damaged volume and use it as far as it goes: every directory walked and every file read, a file made,
 * written, cut, renamed and removed, and a path resolved. Every error is ignored.
 *
 * @param device The device over the damaged image.
 * @return True if the volume mounted; false if it didn't, so nothing else was tried.
 */
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

/**
 * Walk a directory: its first 300 entries listed, directories walked into up to 4 levels down, and each file read at
 * its start and its middle. Every error is ignored; a listing that fails ends the walk of that directory.
 *
 * @param volume The volume under test, mounted on the stand-in disk.
 * @param directory The directory's first cluster.
 * @param depth How many levels down it is, from 0 for the root.
 */
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

/** A random number generator, xorshift64*, as slopfs's tests have it: the same numbers for the same seed. */
Random :: struct {
    /** The generator's state; never 0, which would give only 0s. */
    state : u64,
}

/**
 * Get the next random number.
 *
 * @param random The generator, its state advanced.
 * @return A number, any u64.
 */
next_random :: fn(random: ptr[mut Random]) -> u64 {
    x := random.state
    x = x ~ (x >> 12)
    x = x ~ (x << 25)
    x = x ~ (x >> 27)
    random.state = x
    return x * 0x2545f4914f6cdd1d
}

/**
 * Read a decimal number, as SLOPOS_FUZZ_ROUNDS gives one.
 *
 * @param text The text, digits only.
 * @return The number; null if the text is empty or has anything but digits. Overflow isn't checked.
 */
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
