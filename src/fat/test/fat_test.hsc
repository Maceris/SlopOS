/**
 * The FAT package's tests, as a hosted program (tools/unit_tests.py, decisions/0175): main runs them and returns how
 * many failed. A volume formatted in a buffer standing in for a disk is mounted; files and directories are made with
 * short and long names, written across clusters, read back, resized, renamed and removed; a buffer that isn't FAT
 * isn't mounted; a write the disk fails is remembered, its sectors refused to reads until they're written again and
 * the volume failed for good (decisions/0112); and the volume, damaged many ways, is used without crashing
 * (fuzz_test.hsc).
 */
package fat_test

import compiler from "base"
import runtime from "base"
import testing from "std"
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

/** The year of the stamp the tests' volumes write with, which is 2026-10-30 12:34:56. */
STAMP_YEAR :: 2026

/** A stand-in disk, and a volume formatted on it and mounted, as most tests start from it. */
Formatted :: struct #scoped {
    /** The disk, from runtime.new, with its bytes; freed by free_formatted. */
    image : ptr[mut Image],
    /** The device over image. */
    device : fat.Device,
    /** The volume, mounted, writing entries with the stamp of 2026-10-30 12:34:56. */
    volume : fat.Volume,
}

/**
 * Make a stand-in disk of SECTORS sectors, nothing on it.
 *
 * @param t The test's state, which a failure is recorded in.
 * @return The disk, from runtime.new, the caller's to free with free_image; Error if its bytes couldn't be had, the
 *     failure recorded.
 */
new_image :: fn(t: ptr[mut testing.T]) -> Result[ptr[mut Image], testing.Stopped] {
    bytes, error :: runtime.new_array(u8, cast[usize](SECTORS * fat.SECTOR_BYTES))
    testing.require(t, error == null, "the stand-in disk's bytes are allocated")?
    image := runtime.new(Image)
    image^ = Image.{bytes = bytes}
    return .Ok(image)
}

/**
 * Give back a stand-in disk new_image made: its bytes, what it saved to undo, and itself.
 *
 * @param image The disk, which isn't used after.
 */
free_image :: fn(image: ptr[mut Image]) {
    runtime.free_array(image.bytes)
    runtime.array_free(&image.undo)
    runtime.array_free(&image.saved)
    runtime.free(image)
}

/**
 * Make a device over a stand-in disk.
 *
 * @param image The disk, which has to outlive the device.
 * @return The device, of SECTORS sectors.
 */
device_of :: fn(image: ptr[mut Image]) -> fat.Device {
    return fat.Device.{context = cast[rawptr](image), sector_count = SECTORS, read = read_sectors, write = write_sectors}
}

/**
 * Make a stand-in disk, format a volume of a sector a cluster on it, and mount it, writing with the tests' stamp.
 *
 * @param t The test's state, which a failure is recorded in.
 * @return The volume, the caller's to free with free_formatted; Error if any of it failed, the failure recorded and
 *     nothing left to free.
 */
formatted :: fn(t: ptr[mut testing.T]) -> Result[Formatted, testing.Stopped] {
    image :: new_image(t)?
    device :: device_of(image)
    formatting :: fat.format(device, SECTORS, 1, "slopos test")
    if !testing.expect_none(t, formatting, "a stand-in disk takes a FAT32 volume") {
        free_image(image)
        return .Error(.Failed)
    }
    mounting :: fat.mount(device)
    match mounting {
        case Ok(volume) => {
            made := Formatted.{image = image, device = device, volume = volume}
            made.volume.stamp = fat.stamp_of(STAMP_YEAR, 10, 30, 12, 34, 56)
            return .Ok(made)
        }
        case Error(failure) => {
            _ = testing.expect_ok(t, mounting, "a formatted volume mounts")
            free_image(image)
            return .Error(.Failed)
        }
    }
}

/**
 * Give back what formatted made.
 *
 * @param made The volume and its disk, which aren't used after.
 */
free_formatted :: fn(made: ptr[mut Formatted]) {
    free_image(made.image)
}

/**
 * Require a result to be Ok, as expect_ok checks, ending the test with ? if it isn't, its value dropped: for a step
 * whose value isn't wanted, which testing.require_ok would give.
 *
 * @param t The test's state, which a failure is recorded in.
 * @param result The result, of any Result type.
 * @param message Why it should succeed, for whoever reads a failure.
 * @param location Where the check is; the caller's own.
 * @return Ok if it was Ok; Error(Failed), the failure recorded with the error, if it was an Error.
 */
require_done :: fn[V, E](t: ptr[mut testing.T], result: Result[V, E], message: string, location := #caller_location) -> testing.Outcome {
    return testing.outcome_of(testing.expect_ok(t, result, message, location))
}

/** The bytes the kernel file is written with: byte i is i % 251, across six clusters of 512. */
KERNEL_BYTES :: 3000

/** A directory, "boot", and a file of KERNEL_BYTES beneath it, "kernel.elf", as made_kernel makes them. */
Kernel :: struct {
    /** The directory's entry, in the root. */
    boot : fat.Entry,
    /** The directory's first cluster. */
    boot_cluster : u32,
    /** The file's entry, in boot. */
    kernel : fat.Entry,
}

/**
 * Fill the kernel file's bytes.
 *
 * @return KERNEL_BYTES bytes, byte i being i % 251.
 */
kernel_bytes :: fn() -> u8[KERNEL_BYTES] {
    data : u8[KERNEL_BYTES]
    for &byte, i in data {
        byte^ = cast[u8](i % 251)
    }
    return data
}

/**
 * Make a directory, "boot", in a volume's root, and a file beneath it, "kernel.elf", written with kernel_bytes.
 *
 * @param t The test's state, which a failure is recorded in.
 * @param volume The volume, mounted.
 * @return The directory and file; Error if either couldn't be made or written, the failure recorded.
 */
made_kernel :: fn(t: ptr[mut testing.T], volume: ptr[mut fat.Volume]) -> Result[Kernel, testing.Stopped] {
    making_boot :: fat.create(volume, fat.root_of(volume), "boot", true)
    made := Kernel.{boot = testing.require_ok(t, making_boot, "a directory is made in the root")?}
    made.boot_cluster = fat.directory_cluster(volume, &made.boot)
    making_kernel :: fat.create(volume, made.boot_cluster, "kernel.elf", false)
    made.kernel = testing.require_ok(t, making_kernel, "a file is made beneath a directory")?
    data :: kernel_bytes()
    writing :: fat.write(volume, &made.kernel, 0, data)
    written_count :: testing.require_ok(t, writing, "a file is written across clusters")?
    testing.require_eq(t, written_count, KERNEL_BYTES, "a write across six clusters writes it all")?
    return .Ok(made)
}

an_empty_disk_isnt_mounted_and_a_formatted_one_is_with_every_cluster_free #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    image :: new_image(t)?
    defer free_image(image)
    device :: device_of(image)
    empty :: fat.mount(device)
    testing.expect(t, empty is_error, "zeros aren't a FAT volume")
    formatting :: fat.format(device, SECTORS, 1, "slopos test")
    testing.require_none(t, formatting, "a stand-in disk takes a FAT32 volume")?
    mounting :: fat.mount(device)
    volume := testing.require_ok(t, mounting, "a formatted volume mounts")?
    testing.expect_eq(t, next_name(&volume, fat.root_of(&volume), 0), "", "a new volume's root has no entries")
    counting :: fat.free_clusters(&volume)
    formatted_free :: testing.require_ok(t, counting, "a new volume's free clusters are counted")?
    testing.expect_eq(t, formatted_free, volume.cluster_count - 1, "formatted, every cluster but the root's is free, as FSInfo says")
    return .Ok
}

a_short_name_is_kept_in_its_case_found_in_any_case_and_stamped #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made := formatted(t)?
    defer free_formatted(&made)
    volume :: &made.volume
    root :: fat.root_of(volume)
    counting :: fat.free_clusters(volume)
    formatted_free :: testing.require_ok(t, counting, "a new volume's free clusters are counted")?
    creating :: fat.create(volume, root, "readme.txt", false)
    readme := testing.require_ok(t, creating, "a file of an 8.3 name in lower case is made")?
    testing.expect_eq(t, readme.place.long_entries, 0, "an 8.3 name in one case needs no long entries, its case in the flags")
    testing.expect(t, written(volume, &readme, 0, "hello, FAT"), "a file of an 8.3 name is written")
    looking :: fat.lookup(volume, root, "README.TXT")
    found := testing.require_ok(t, looking, "a short name is found in another case")?
    testing.expect_eq(t, fat.name_of(&found), "readme.txt", "a short name keeps the case it was made in")
    testing.expect_eq(t, found.size, 10, "a file is as long as was written")
    testing.expect_eq(t, read_back(volume, &found), "hello, FAT", "a file reads as written")
    stamp :: volume.stamp
    testing.expect_eq(t, found.written, stamp, "a file written has the volume's stamp")
    testing.expect_eq(t, stamp >> 16, 46 << 9 | 10 << 5 | 30, "a stamp's date: years from 1980, month and day")
    testing.expect_eq(t, stamp & 0xffff, 12 << 11 | 34 << 5 | 28, "a stamp's time: hours, minutes and two-second units")
    testing.expect_eq(t, fat.free_clusters(volume) or_else 0, formatted_free - 1, "the cluster a file's bytes took is counted")
    return .Ok
}

long_names_are_found_in_any_case_and_given_aliases #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made := formatted(t)?
    defer free_formatted(&made)
    volume :: &made.volume
    root :: fat.root_of(volume)
    making_first :: fat.create(volume, root, "A long file name.text", false)
    first :: testing.require_ok(t, making_first, "a file of a long name is made")?
    making_second :: fat.create(volume, root, "A long file name, again.text", false)
    second :: testing.require_ok(t, making_second, "a second file of a long name is made")?
    testing.expect_ne(t, first.place.long_entries, 0, "a long name is kept in long entries")
    testing.expect(t, first.short_name == short("ALONGF~1TEX"), "a long name's alias is its first six letters, ~1 and its extension")
    testing.expect(t, second.short_name == short("ALONGF~2TEX"), "a second long name with the same start takes ~2")
    looking :: fat.lookup(volume, root, "a LONG file NAME, again.TEXT")
    again := testing.require_ok(t, looking, "a long name is found in another case")?
    testing.expect_eq(t, fat.name_of(&again), "A long file name, again.text", "a long name keeps the case it was made in")
    same_name :: fat.create(volume, root, "A LONG FILE NAME.TEXT", false)
    testing.expect_error(t, same_name, .AlreadyExists, "names differing only in case are the same name")
    return .Ok
}

names_and_paths_that_arent_names_are_refused #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made := formatted(t)?
    defer free_formatted(&made)
    volume :: &made.volume
    root :: fat.root_of(volume)
    for refused in string.["", "trailing.", "a/b", "star*", "colon:"] {
        creating :: fat.create(volume, root, refused, false)
        testing.expect(t, creating is_error, "nothing, a trailing dot, a slash, a star and a colon aren't in a FAT name")
    }
    making_readme :: fat.create(volume, root, "readme.txt", false)
    require_done(t, making_readme, "a file is made in the root")?
    made_kernel(t, volume)?
    for refused in string.["boot/../readme.txt", "./readme.txt", "readme.txt/x", "nowhere/x"] {
        resolving :: fat.resolve(volume, root, refused)
        testing.expect(t, resolving is_error, "paths through dots, through a file, or through nothing don't resolve")
    }
    return .Ok
}

a_file_is_written_across_clusters_and_read_whole_and_from_its_middle #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made := formatted(t)?
    defer free_formatted(&made)
    volume :: &made.volume
    made_kernel(t, volume)?
    data :: kernel_bytes()
    resolving :: fat.resolve(volume, fat.root_of(volume), "boot/KERNEL.ELF")
    resolved := testing.require_ok(t, resolving, "a path resolves, in any case")?
    testing.expect_eq(t, resolved.size, KERNEL_BYTES, "a file is as long as was written")
    back : u8[KERNEL_BYTES]
    testing.expect_eq(t, fat.read(volume, &resolved, 0, back) or_else 0, KERNEL_BYTES, "a file across clusters reads whole")
    testing.expect(t, back == data, "a file across clusters reads as written")
    // From the middle, across a cluster's end
    middle : u8[700]
    testing.expect_eq(t, fat.read(volume, &resolved, 1000, middle) or_else 0, 700, "700 bytes within the file read whole")
    testing.expect_eq(t, middle[0], data[1000], "a read from the middle starts where it's asked to")
    testing.expect_eq(t, middle[699], data[1699], "a read from the middle goes on across a cluster's end")
    return .Ok
}

a_file_cut_and_grown_reads_zeros_where_it_grew #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made := formatted(t)?
    defer free_formatted(&made)
    volume :: &made.volume
    made_kernel(t, volume)?
    data :: kernel_bytes()
    resolving :: fat.resolve(volume, fat.root_of(volume), "boot/KERNEL.ELF")
    resolved := testing.require_ok(t, resolving, "a path resolves")?
    cutting :: fat.set_size(volume, &resolved, 100)
    require_done(t, cutting, "a file is cut")?
    growing :: fat.set_size(volume, &resolved, 2000)
    require_done(t, growing, "a cut file is grown")?
    resolving_again :: fat.resolve(volume, fat.root_of(volume), "boot/kernel.elf")
    resized := testing.require_ok(t, resolving_again, "a resized file's path resolves")?
    testing.expect_eq(t, resized.size, 2000, "a file grown is its new size")
    grown : u8[2000]
    testing.expect_eq(t, fat.read(volume, &resized, 0, grown) or_else 0, 2000, "a grown file reads whole")
    testing.expect_eq(t, grown[99], data[99], "what the cut kept is as it was")
    testing.expect_eq(t, grown[100], 0, "what was cut reads as zero once grown")
    testing.expect_eq(t, grown[1999], 0, "what was grown reads as zero to its end")
    return .Ok
}

entries_are_renamed_and_removed_but_not_a_directory_with_something_in_it #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made := formatted(t)?
    defer free_formatted(&made)
    volume :: &made.volume
    root :: fat.root_of(volume)
    making :: fat.create(volume, root, "A long file name.text", false)
    first := testing.require_ok(t, making, "a file of a long name is made")?
    kernel := made_kernel(t, volume)?
    // Renamed into the directory, over nothing
    renaming :: fat.rename(volume, &first, kernel.boot_cluster, "moved.text")
    require_done(t, renaming, "a file is renamed into a directory")?
    old_name :: fat.lookup(volume, root, "A long file name.text")
    testing.expect(t, old_name is_error, "a renamed file's old name is gone")
    looking :: fat.lookup(volume, kernel.boot_cluster, "moved.text")
    in_boot := testing.require_ok(t, looking, "a renamed file is found by its new name, where it went")?
    removing_boot :: fat.remove(volume, &kernel.boot)
    testing.expect_error(t, removing_boot, .DirectoryNotEmpty, "a directory with something in it isn't removed")
    removing_moved :: fat.remove(volume, &in_boot)
    testing.expect_ok(t, removing_moved, "a file renamed is removed by its new entry")
    removing_kernel :: fat.remove(volume, &kernel.kernel)
    testing.expect_ok(t, removing_kernel, "a file is removed")
    removing_empty :: fat.remove(volume, &kernel.boot)
    testing.expect_ok(t, removing_empty, "a directory emptied is removed")
    gone :: fat.lookup(volume, root, "boot")
    testing.expect(t, gone is_error, "a directory removed is gone")
    return .Ok
}

a_file_renamed_over_another_replaces_it_and_frees_its_cluster #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made := formatted(t)?
    defer free_formatted(&made)
    volume :: &made.volume
    root :: fat.root_of(volume)
    making_old :: fat.create(volume, root, "old.txt", false)
    old_file := testing.require_ok(t, making_old, "a file is made")?
    making_new :: fat.create(volume, root, "new.txt", false)
    new_file := testing.require_ok(t, making_new, "a second file is made")?
    testing.require(t, written(volume, &old_file, 0, "the old one"), "a file is written")?
    testing.require(t, written(volume, &new_file, 0, "the new one"), "a second file is written")?
    counting :: fat.free_clusters(volume)
    free_before_replacing :: testing.require_ok(t, counting, "free clusters are counted")?
    renaming :: fat.rename(volume, &new_file, root, "old.txt")
    replacing := testing.require_ok(t, renaming, "a file is renamed over another")?
    gone :: fat.lookup(volume, root, "new.txt")
    testing.expect(t, gone is_error, "a file renamed over another isn't under its old name")
    testing.expect_eq(t, read_back(volume, &replacing), "the new one", "the entry a rename gives reads as the file renamed")
    looking :: fat.lookup(volume, root, "old.txt")
    replaced := testing.require_ok(t, looking, "the name renamed over is found")?
    testing.expect_eq(t, read_back(volume, &replaced), "the new one", "a name renamed over names the file renamed")
    testing.expect_eq(t, fat.free_clusters(volume) or_else 0, free_before_replacing + 1, "the file replaced has its cluster freed")
    return .Ok
}

a_rename_changing_only_case_is_allowed #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made := formatted(t)?
    defer free_formatted(&made)
    volume :: &made.volume
    root :: fat.root_of(volume)
    making :: fat.create(volume, root, "old.txt", false)
    file := testing.require_ok(t, making, "a file is made")?
    testing.require(t, written(volume, &file, 0, "the new one"), "a file is written")?
    renaming :: fat.rename(volume, &file, root, "OLD.txt")
    recased := testing.require_ok(t, renaming, "a file renamed to its own name in another case is renamed, not refused")?
    looking :: fat.lookup(volume, root, "old.txt")
    looked := testing.require_ok(t, looking, "a file renamed in case is still found in any case")?
    testing.expect_eq(t, fat.name_of(&recased), "OLD.txt", "the entry a rename gives has the new case")
    testing.expect_eq(t, fat.name_of(&looked), "OLD.txt", "a file renamed in case keeps the new case")
    testing.expect_eq(t, read_back(volume, &looked), "the new one", "a file renamed in case reads as it did")
    return .Ok
}

a_write_past_the_end_reads_zeros_in_the_gap #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made := formatted(t)?
    defer free_formatted(&made)
    volume :: &made.volume
    root :: fat.root_of(volume)
    making :: fat.create(volume, root, "old.txt", false)
    file := testing.require_ok(t, making, "a file is made")?
    testing.require(t, written(volume, &file, 0, "the new one"), "a file is written")?
    // Cut short, its cluster keeps the old bytes past the cut; a write past the end reads zeros there all the same
    cutting :: fat.set_size(volume, &file, 3)
    require_done(t, cutting, "a file is cut")?
    testing.require(t, written(volume, &file, 20, "x"), "a file is written past its end")?
    gapped : u8[21]
    testing.expect_eq(t, fat.read(volume, &file, 0, gapped) or_else 0, 21, "a file written past its end grows to the write's end")
    testing.expect_eq(t, gapped[0], cast[u8]('t'), "what the cut kept is as it was")
    testing.expect_eq(t, gapped[20], cast[u8]('x'), "what was written past the end is there")
    for i in cast[usize](3)..<20 {
        testing.expect_eq(t, gapped[i], 0, "the gap a write past the end leaves reads as zeros, not the bytes cut")
    }
    removing :: fat.remove(volume, &file)
    testing.expect_ok(t, removing, "a file with a gap is removed")
    return .Ok
}

everything_is_as_it_was_mounted_again_with_fsinfos_count #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made := formatted(t)?
    defer free_formatted(&made)
    volume :: &made.volume
    root :: fat.root_of(volume)
    creating :: fat.create(volume, root, "readme.txt", false)
    readme := testing.require_ok(t, creating, "a file is made")?
    testing.require(t, written(volume, &readme, 0, "hello, FAT"), "a file is written")?
    made_kernel(t, volume)?
    counting :: fat.free_clusters(volume)
    free_before :: testing.require_ok(t, counting, "free clusters are counted")?
    testing.require_none(t, fat.write_info(volume), "FSInfo is written")?
    mounting :: fat.mount(made.device)
    remounted := testing.require_ok(t, mounting, "a volume mounts again")?
    looking :: fat.lookup(&remounted, fat.root_of(&remounted), "readme.txt")
    still := testing.require_ok(t, looking, "a file is there mounted again")?
    testing.expect_eq(t, read_back(&remounted, &still), "hello, FAT", "a file reads as written mounted again")
    testing.expect_eq(t, still.written, volume.stamp, "a file's stamp is kept mounted again")
    testing.expect_eq(t, remounted.free_count, free_before, "FSInfo's free count, once written, is what was counted")
    // Counted through the FAT, the same
    remounted.free_count = fat.UNKNOWN_FREE
    testing.expect_eq(t, fat.free_clusters(&remounted) or_else 0, free_before, "the FAT, counted, agrees with FSInfo")
    return .Ok
}

a_failed_write_fails_the_volume_and_refuses_what_it_was_to_change #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made := formatted(t)?
    defer free_formatted(&made)
    image :: made.image
    mounting :: fat.mount(made.device)
    volume := testing.require_ok(t, mounting, "a formatted volume mounts")?
    root :: fat.root_of(&volume)
    making_kept :: fat.create(&volume, root, "kept.txt", false)
    kept := testing.require_ok(t, making_kept, "a file is made")?
    making_lost :: fat.create(&volume, root, "lost.txt", false)
    lost := testing.require_ok(t, making_lost, "a second file is made")?
    testing.require(t, written(&volume, &kept, 0, "kept"), "a file is written")?
    testing.require(t, written(&volume, &lost, 0, "before"), "a second file is written")?
    testing.require(t, !volume.failed, "a volume whose writes all worked isn't failed")?
    image.failing = true
    refused :: written(&volume, &lost, 0, "after!")
    image.failing = false
    testing.expect(t, !refused, "a write the disk fails is refused")
    testing.expect(t, volume.failed, "a write the disk fails fails the volume")
    // Neither the old bytes nor the new: refused
    buffer : u8[16]
    reading :: fat.read(&volume, &lost, 0, buffer)
    testing.expect(t, reading is_error, "what a failed write was to change is refused to reads, being neither old nor new")
    testing.expect_eq(t, read_back(&volume, &kept), "kept", "a file the failed write wasn't for still reads")
    // Part of it can't be written, which would need what's there; written whole again, it reads, and the volume stays failed
    testing.expect(t, !written(&volume, &lost, 0, "again!"), "part of a refused sector can't be written, as the rest of it isn't known")
    whole : u8[512]
    for i in 0..<whole.count {
        whole[i] = cast[u8]('w')
    }
    testing.expect_eq(t, fat.write(&volume, &lost, 0, whole) or_else 0, 512, "a refused sector written whole is written")
    testing.expect_eq(t, read_back(&volume, &lost), "wwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwww",
        "a refused sector written whole reads again")
    testing.expect(t, volume.failed, "a volume stays failed, so every Sync after the failure fails")
    mounting_again :: fat.mount(made.device)
    remounted :: testing.require_ok(t, mounting_again, "the volume mounts afresh")?
    testing.expect(t, !remounted.failed, "a volume mounted afresh starts whole")
    return .Ok
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
 * Run the tests, reporting to standard output.
 *
 * @return How many failed: 0 when every one passed.
 */
run_tests :: fn() -> int {
    return cast[int](testing.run(#insert testing.tests_of(compiler.load_package(".")), testing.STANDARD_OUTPUT))
}

/**
 * Run the tests, with fault injection as SLOPOS_FAIL asks (robustness/hosted, tools/unit_tests.py --robustness).
 *
 * @return How many tests failed: 0 when every one passed.
 */
main :: fn() -> int {
    return hosted_faults.run(run_tests)
}
