/*
 * The image builder (roadmap 8c, design/storage.md §9, decisions/0088): a hosted program that makes the disk image
 * SlopOS boots from, with the same packages SlopOS reads it with: a GPT (src/gpt), FAT32 partitions (src/fat) and
 * SlopOS containers (src/slopfs), each filled from a folder on the host. tools/boot.py runs it.
 *
 *     image_builder <output> <sectors> [--sealed=<name>:<passphrase>] <partition>...
 *
 * The image is sectors 512-byte sectors. Each partition is kind,name,sectors[,folder], placed in order from sector
 * 2048, each starting at a MiB, the folder last, so it may hold commas:
 * - bios: a BIOS boot partition, where `limine bios-install` puts Limine's second stage on a GPT disk
 * - esp: an EFI system partition, FAT32, holding the folder's tree
 * - data: a basic data partition, FAT32, holding the folder's tree
 * - test: SlopOS's test partition type, zeros, which whoever made the image marks
 * - slopfs: a SlopOS container, with a volume named "system" holding the folder's tree, checked whole once it's made
 * With --sealed, each container also has an encrypted volume of that name, unlocked by that passphrase, holding
 * sealed.txt (SEALED_TEXT), for the boot tests (roadmap 8e). Each partition is printed as "partition <index> <first> <count> <name>". The GUIDs, the container's ID and its
 * volume's name-hash key are random.
 */
package image_builder

import runtime from "base"
import io from "std"
import os from "std"
import random from "std"
import crypto from "std"
import strings from "std"
import text_buffer from "std"
import fat from "../../fat"
import gpt from "../../gpt"
import slopfs from "../../slopfs"

SECTOR_BYTES : u64 : 512
// Partitions start at a MiB, as every tool aligns them
ALIGN_SECTORS : u64 : 2048
MAX_PARTITIONS :: 16

// Partition types, as their bytes are on the disk
BIOS_BOOT_TYPE :: u8.[0x48, 0x61, 0x68, 0x21, 0x49, 0x64, 0x6f, 0x6e, 0x74, 0x4e, 0x65, 0x65, 0x64, 0x45, 0x46, 0x49]
ESP_TYPE :: u8.[0x28, 0x73, 0x2a, 0xc1, 0x1f, 0xf8, 0xd2, 0x11, 0xba, 0x4b, 0x00, 0xa0, 0xc9, 0x3e, 0xc9, 0x3b]
BASIC_DATA_TYPE :: u8.[0xa2, 0xa0, 0xd0, 0xeb, 0xe5, 0xb9, 0x33, 0x44, 0x87, 0xc0, 0x68, 0xb6, 0xb7, 0x26, 0x99, 0xc7]
// "SLOPOS TEST PART" and "SLOPOS CONTAINER", in ASCII
TEST_TYPE :: u8.[0x53, 0x4c, 0x4f, 0x50, 0x4f, 0x53, 0x20, 0x54, 0x45, 0x53, 0x54, 0x20, 0x50, 0x41, 0x52, 0x54]
CONTAINER_TYPE :: u8.[0x53, 0x4c, 0x4f, 0x50, 0x4f, 0x53, 0x20, 0x43, 0x4f, 0x4e, 0x54, 0x41, 0x49, 0x4e, 0x45, 0x52]

Kind :: enum {
    Bios,
    Esp,
    Data,
    Test,
    Slopfs,
}

// A partition asked for, and for a container, the encrypted volume asked for in it, if one was.
Wanted :: struct {
    kind : Kind,
    name : string,
    first : u64,
    count : u64,
    folder : string,
    sealed_name : string,
    sealed_passphrase : string,
}

// What an encrypted volume the image builder makes holds, in sealed.txt: in capitals, which the disk check, on the
// disk in the clear, holds only in small letters (sealed_check.hsc)
SEALED_TEXT :: "ONLY ITS PASSPHRASE OPENS THIS"
// Argon2id for its passphrase, kept within what a volume server is given room for (storage_manager.hsc)
SEALED_ARGON2 :: crypto.Argon2Parameters.{memory_kib = 1024, passes = 2, lanes = 1}
SEALED_OPTION :: "--sealed="

// What can go wrong filling a partition.
Failure :: enum {
    TooSmallForFat,
    NotMounted,
    Unlisted,
    Unread,
    NotMade,
    NotWritten,
    TooDeep,
    NotWholeBlocks,
    NotCommitted,
    NotChecked,
}

text_of :: fn(failure: Failure) -> string {
    return match failure {
        case .TooSmallForFat => "too small for FAT32, which needs 65525 clusters"
        case .NotMounted => "what it made doesn't mount"
        case .Unlisted => "a folder can't be listed"
        case .Unread => "a file can't be read"
        case .NotMade => "a file, directory or volume can't be made"
        case .NotWritten => "a file can't be written whole"
        case .TooDeep => "folders too deep"
        case .NotWholeBlocks => "a container's partition is in whole 4 KiB blocks"
        case .NotCommitted => "the container can't be committed"
        case .NotChecked => "the container it made doesn't check out"
    }
}

main :: fn() -> int {
    arguments :: os.arguments()
    if arguments.count < 4 {
        io.eprintln("usage: image_builder <output> <sectors> <kind,name,sectors[,folder]>...")
        return 2
    }
    output :: arguments[1]
    sectors :: number_of(arguments[2]) or_else 0
    if sectors < 4 * ALIGN_SECTORS {
        io.eprintln("image_builder: an image needs a number of sectors, at least 8192")
        return 2
    }
    wanted : Wanted[..]
    defer runtime.array_free(&wanted)
    next := ALIGN_SECTORS
    sealed_name : string = ""
    sealed_passphrase : string = ""
    for argument, index in arguments {
        if index < 3 {
            continue
        }
        prefix :: SEALED_OPTION.count
        if strings.starts_with(argument, SEALED_OPTION) && prefix <= argument.count {
            option :: argument[prefix..<argument.count]
            colon := option.count
            for character, i in option {
                if character == ':' && colon == option.count {
                    colon = i
                }
            }
            if colon == 0 || colon + 1 >= option.count {
                io.eprintln("image_builder: --sealed needs a name and a passphrase, as --sealed=<name>:<passphrase>")
                return 2
            }
            sealed_name = option[0..<colon]
            sealed_passphrase = option[colon + 1..<option.count]
            continue
        }
        partition := Wanted.{}
        match parse(argument) {
            case Some(parsed) => partition = parsed
            case None => {
                io.eprintf("image_builder: can't read the partition %\n", argument)
                return 2
            }
        }
        partition.first = next
        next = align(next + partition.count)
        runtime.array_add(&wanted, partition)
    }
    for &partition in wanted {
        if partition.kind == .Slopfs {
            partition.sealed_name = sealed_name
            partition.sealed_passphrase = sealed_passphrase
        }
    }
    if wanted.count > MAX_PARTITIONS || next > sectors - gpt.ENTRY_BLOCKS - 2 {
        io.eprintln("image_builder: the partitions don't fit")
        return 2
    }
    image, error :: runtime.new_array(u8, cast[usize](sectors * SECTOR_BYTES))
    if error != null || image.count == 0 {
        io.eprintln("image_builder: no memory for the image")
        return 3
    }
    defer runtime.free_array(image)
    for i in 0..<image.count {
        image[i] = 0
    }
    table : gpt.NewPartition[MAX_PARTITIONS]
    for partition, index in wanted {
        unique : gpt.Guid
        random.fill(unique)
        if index < table.count {
            table[index] = gpt.NewPartition.{first = partition.first, count = partition.count, type_guid = type_of(partition.kind),
                unique_guid = unique, name = partition.name}
        }
    }
    disk_guid : gpt.Guid
    random.fill(disk_guid)
    if wanted.count > table.count || !gpt.write_table(image, sectors, disk_guid, table[0..<wanted.count]) {
        io.eprintln("image_builder: the partition table couldn't be written")
        return 4
    }
    for item, index in wanted {
        partition := item
        match fill(image, &partition) {
            case Some(failure) => {
                io.eprintf("image_builder: partition % (%): %\n", index, partition.name, text_of(failure))
                return 5
            }
            case None => {}
        }
        io.printf("partition % % % %\n", index, partition.first, partition.count, partition.name)
    }
    if os.write_entire_file(output, string_of(&image[0], image.count)) != null {
        io.eprintf("image_builder: can't write %\n", output)
        return 6
    }
    return 0
}

align :: fn(sector: u64) -> u64 {
    return (sector + ALIGN_SECTORS - 1) / ALIGN_SECTORS * ALIGN_SECTORS
}

type_of :: fn(kind: Kind) -> gpt.Guid {
    return match kind {
        case .Bios => BIOS_BOOT_TYPE
        case .Esp => ESP_TYPE
        case .Data => BASIC_DATA_TYPE
        case .Test => TEST_TYPE
        case .Slopfs => CONTAINER_TYPE
    }
}

number_of :: fn(text: string) -> u64? {
    if text.count == 0 {
        return null
    }
    value : u64 = 0
    for character in text {
        if character < '0' || character > '9' {
            return null
        }
        value = value * 10 + cast[u64](cast[u8](character) - cast[u8]('0'))
    }
    return value
}

// kind,name,sectors[,folder]
parse :: fn(text: string) -> Wanted? {
    fields : string[4]
    count : usize = 0
    start : usize = 0
    for character, i in text {
        if character == ',' && count < 3 {
            if count < fields.count && start <= i {
                fields[count] = text[start..<i]
            }
            count += 1
            start = i + 1
        }
    }
    if count < fields.count && start <= text.count {
        fields[count] = text[start..<text.count]
    }
    count += 1
    if count < 3 {
        return null
    }
    kind := Kind.Bios
    match fields[0] {
        case "bios" => kind = .Bios
        case "esp" => kind = .Esp
        case "data" => kind = .Data
        case "test" => kind = .Test
        case "slopfs" => kind = .Slopfs
        case _ => return null
    }
    sectors :: number_of(fields[2]) or_return null
    if sectors == 0 || ((kind == .Esp || kind == .Data || kind == .Slopfs) && count < 4) {
        return null
    }
    return Wanted.{kind = kind, name = fields[1], count = sectors, folder = if count >= 4 { fields[3] } else { "" }}
}

// A partition's contents written into the image, or what went wrong.
fill :: fn(image #escaping : mut u8[], partition: ptr[Wanted]) -> Failure? {
    return match partition.kind {
        case .Bios => null
        case .Test => null
        case .Esp => fill_fat(image, partition)
        case .Data => fill_fat(image, partition)
        case .Slopfs => fill_slopfs(image, partition)
    }
}

// A partition's sectors in the image, as a device.
Region :: struct {
    image : mut u8[],
    first : u64,
    count : u64,
}

region_read :: fn(context: rawptr, first: u64, count: u64, into: mut u8[], unit: u64) -> bool {
    region :: cast[ptr[mut Region]](context)
    if (first + count) * unit > region.count * SECTOR_BYTES {
        return false
    }
    start :: cast[usize](region.first * SECTOR_BYTES + first * unit)
    length :: cast[usize](count * unit)
    for i in 0..<length {
        j :: start + i
        if j < region.image.count && i < into.count {
            into[i] = region.image[j]
        }
    }
    return length <= into.count
}

region_write :: fn(context: rawptr, first: u64, count: u64, from: u8[], unit: u64) -> bool {
    region :: cast[ptr[mut Region]](context)
    if (first + count) * unit > region.count * SECTOR_BYTES {
        return false
    }
    start :: cast[usize](region.first * SECTOR_BYTES + first * unit)
    length :: cast[usize](count * unit)
    for i in 0..<length {
        j :: start + i
        if j < region.image.count && i < from.count {
            region.image[j] = from[i]
        }
    }
    return length <= from.count
}

sector_read :: fn(context: rawptr, first: u64, count: u64, into: mut u8[]) -> bool {
    return region_read(context, first, count, into, SECTOR_BYTES)
}

sector_write :: fn(context: rawptr, first: u64, count: u64, from: u8[]) -> bool {
    return region_write(context, first, count, from, SECTOR_BYTES)
}

block_read :: fn(context: rawptr, first: u64, count: u64, into: mut u8[]) -> bool {
    return region_read(context, first, count, into, slopfs.BLOCK_BYTES)
}

block_write :: fn(context: rawptr, first: u64, count: u64, from: u8[]) -> bool {
    return region_write(context, first, count, from, slopfs.BLOCK_BYTES)
}

flushed :: fn(context: rawptr) -> bool {
    return true
}

// A FAT32 volume on the partition, with the folder's tree in it.
fill_fat :: fn(image #escaping : mut u8[], partition: ptr[Wanted]) -> Failure? {
    region := runtime.new(Region)
    defer runtime.free(region)
    region^ = Region.{image = image, first = partition.first, count = partition.count}
    device := fat.Device.{context = cast[rawptr](region), sector_count = partition.count, read = sector_read, write = sector_write}
    // A sector a cluster, or more for a bigger partition, keeping well past FAT32's fewest clusters
    per_cluster : u64 = 1
    loop {
        per_cluster *= 2
    }
    while per_cluster < 64 && partition.count / (per_cluster * 2) > cast[u64](fat.MIN_CLUSTERS) + 4096
    if fat.format(device, partition.count, per_cluster, partition.name) is_some {
        return .TooSmallForFat
    }
    volume := fat.mount(device) or_return .NotMounted
    copied :: copy_to_fat(&volume, fat.root_of(&volume), partition.folder, 0)
    if copied is_some {
        return copied
    }
    // FSInfo's free count, as the copies left it
    if fat.write_info(&volume) is_some {
        return .NotWritten
    }
    return null
}

// path/name, in a buffer.
joined :: fn(buffer: ptr[mut text_buffer.TextBuffer], path: string, name: string) -> string {
    text_buffer.clear(buffer)
    text_buffer.append(buffer, path)
    text_buffer.append(buffer, "/")
    text_buffer.append(buffer, name)
    return text_buffer.as_string(buffer)
}

copy_to_fat :: fn(volume: ptr[mut fat.Volume], directory: u32, folder: string, depth: int) -> Failure? {
    if depth > 16 {
        return .TooDeep
    }
    entries :: os.list_directory(folder) or_return .Unlisted
    defer os.free_directory_listing(entries)
    storage : u8[1024]
    path := text_buffer.make(storage)
    for entry in entries {
        source :: joined(&path, folder, entry.name)
        if entry.is_directory {
            made := fat.create(volume, directory, entry.name, true) or_return .NotMade
            failed :: copy_to_fat(volume, fat.directory_cluster(volume, &made), source, depth + 1)
            if failed is_some {
                return failed
            }
            continue
        }
        bytes :: os.read_entire_file(source) or_return .Unread
        defer runtime.free_array(bit_cast[u8[]](bytes))
        made := fat.create(volume, directory, entry.name, false) or_return .NotMade
        written :: fat.write(volume, &made, 0, view_of(cast[ptr[u8]](bytes.data), bytes.count)) or_return .NotWritten
        if written != cast[u64](bytes.count) {
            return .NotWritten
        }
    }
    return null
}

// A SlopOS container on the partition, with a volume named "system" holding the folder's tree, checked whole.
fill_slopfs :: fn(image #escaping : mut u8[], partition: ptr[Wanted]) -> Failure? {
    if partition.first % 8 != 0 || partition.count % 8 != 0 {
        return .NotWholeBlocks
    }
    region := runtime.new(Region)
    defer runtime.free(region)
    region^ = Region.{image = image, first = partition.first, count = partition.count}
    device := slopfs.Device.{context = cast[rawptr](region), block_count = partition.count / 8, read = block_read, write = block_write,
        flush = flushed}
    id : u8[16]
    random.fill(id)
    if slopfs.format(device, id) is_error {
        return .NotMade
    }
    container :: slopfs.mount(device) or_return .NotMounted
    defer slopfs.unmount(container)
    key : u8[32]
    random.fill(key)
    volume :: slopfs.create_volume(container, "system", key, 0) or_return .NotMade
    failed :: copy_to_slopfs(volume, slopfs.ROOT_OBJECT, partition.folder, 0)
    if failed is_some {
        return failed
    }
    if partition.sealed_name.count > 0 {
        sealed_key : u8[32]
        random.fill(sealed_key)
        passphrase :: view_of(cast[ptr[u8]](partition.sealed_passphrase.data), partition.sealed_passphrase.count)
        sealed :: slopfs.create_sealed_volume(container, partition.sealed_name, sealed_key, 0, .ChaCha20Poly1305, passphrase,
            SEALED_ARGON2) or_return .NotMade
        made :: slopfs.create(sealed, slopfs.ROOT_OBJECT, "sealed.txt", .File) or_return .NotMade
        if slopfs.write(sealed, made, 0, view_of(cast[ptr[u8]](SEALED_TEXT.data), SEALED_TEXT.count)) is_error {
            return .NotWritten
        }
    }
    if slopfs.commit(container) is_error {
        return .NotCommitted
    }
    if slopfs.verify(container) is_error {
        return .NotChecked
    }
    return null
}

copy_to_slopfs :: fn(volume: ptr[mut slopfs.Volume], directory: u64, folder: string, depth: int) -> Failure? {
    if depth > 16 {
        return .TooDeep
    }
    entries :: os.list_directory(folder) or_return .Unlisted
    defer os.free_directory_listing(entries)
    storage : u8[1024]
    path := text_buffer.make(storage)
    for entry in entries {
        source :: joined(&path, folder, entry.name)
        if entry.is_directory {
            made :: slopfs.create(volume, directory, entry.name, .Directory) or_return .NotMade
            failed :: copy_to_slopfs(volume, made, source, depth + 1)
            if failed is_some {
                return failed
            }
            continue
        }
        bytes :: os.read_entire_file(source) or_return .Unread
        defer runtime.free_array(bit_cast[u8[]](bytes))
        made :: slopfs.create(volume, directory, entry.name, .File) or_return .NotMade
        if slopfs.write(volume, made, 0, view_of(cast[ptr[u8]](bytes.data), bytes.count)) is_error {
            return .NotWritten
        }
    }
    return null
}
