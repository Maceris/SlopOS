/*
 * FAT32 (roadmap 8b, decisions/0085, 0087): a volume on a device of 512-byte sectors, read and written through
 * functions, with long names. It's a portable package: the FAT server serves a partition with it, and its tests run
 * hosted over a buffer standing in for a disk.
 *
 * A volume is its boot sector's layout: reserved sectors, then each FAT, then clusters from 2, the root directory a
 * cluster chain like any other. A directory is known by its first cluster, and an entry by where its short entry is.
 * Names are UTF-8, as long names' UTF-16 converts to, compared without regard to ASCII case, as FAT compares them; a
 * name that isn't an upper-case 8.3 name gets long-name entries before a short alias made as Windows makes them
 * ("LONGNA~1.TXT"). An entry's times are the volume's stamp, which its user sets from the wall clock (stamp_of), or
 * 1980-01-01 without one: made, it has it as its creation, write and access times; written to, as its write and
 * access times. Reading changes no time. Every FAT is written alike. FAT12 and FAT16, which a volume of fewer than
 * 65525 clusters is by the specification, aren't read.
 *
 * FSInfo's free count and next free cluster are read at mount, if its signatures are there and they fit the volume;
 * the count is kept as clusters are taken and freed, and written back with write_info (decisions/0101). A volume whose
 * count is unknown counts its free clusters the first time free_clusters is asked.
 *
 * A write the device fails (decisions/0112, after fsyncgate) marks the volume failed, which every Sync after it
 * reports, not only the first, and its sectors are remembered: a read of them is refused, since what's there isn't
 * what was written, until a later write of all of each succeeds; a write of part of one, which needs what's there, is
 * refused too.
 */
/**
 * Read and write FAT32 volumes, with long names, through functions that read and write a device's sectors.
 *
 * SPEC: Microsoft Extensible Firmware Initiative FAT32 File System Specification, version 1.03 (2000): §3 (the boot
 * SPEC: sector and BPB), §4 (the FAT), §5 (FSInfo), §6 (directories), §7 (long names); UEFI Specification 2.10 §13.3.
 */
package fat

/** The size of a sector, in bytes: the only sector size a volume may have (the BPB's bytes per sector). */
SECTOR_BYTES : u64 : 512
/** The size of a directory slot, in bytes: one short entry or one long-name entry. */
ENTRY_BYTES : u64 : 32
/** The most UTF-16 code units a name may have, as FAT allows. */
MAX_NAME_UNITS :: 255
/** The most bytes a name takes as UTF-8: MAX_NAME_UNITS units of at most 3 bytes each. */
NAME_BYTES :: 765
/** The most long-name entries one name has: 13 code units each, so 20 hold MAX_NAME_UNITS. */
MAX_LONG_ENTRIES :: 20

/** A short entry's attribute bit: its file may only be read, as FAT has it; kept and listed, not enforced here. */
READ_ONLY : u8 : 0x01
/** A short entry's attribute bit: it's hidden from ordinary listings; kept and listed, not acted on here. */
HIDDEN : u8 : 0x02
/** A short entry's attribute bit: it belongs to the system; kept and listed, not acted on here. */
SYSTEM : u8 : 0x04
/** A short entry's attribute bit: it's the volume's label, not a file; listings leave it out. */
VOLUME_ID : u8 : 0x08
/** A short entry's attribute bit: it's a directory, its cluster chain holding its slots. */
DIRECTORY : u8 : 0x10
/** A short entry's attribute bit: its file has changed since it was backed up; set on every file made here. */
ARCHIVE : u8 : 0x20
/** The attributes of a long-name entry (read-only, hidden, system and volume ID together), in its low six bits. */
LONG_NAME : u8 : 0x0f
/** A slot's first byte when its entry has been removed, so the slot is free. */
DELETED : u8 : 0xe5
/** A slot's first byte when it has never been used, so it and every slot after it in the directory are free. */
END : u8 : 0x00
/** A FAT entry's value for a free cluster. */
FREE_CLUSTER : u32 : 0
/** The least FAT entry value, of its 28 bits, that ends a chain: any value from it up does. */
END_OF_CHAIN : u32 : 0x0ffffff8
/** The value written to a FAT entry to end a chain. */
CHAIN_END_MARK : u32 : 0x0fffffff
/** The 28 bits of a FAT entry that are its value; the top 4 are reserved, kept as they are when an entry is written. */
CLUSTER_MASK : u32 : 0x0fffffff
/**
 * The most slots in a directory: 65536, as FAT has it, 2 MiB of entries; a chain longer than that isn't read past
 * it, so even one that loops ends.
 */
MAX_DIRECTORY_SLOTS : u32 : 65536
/** The fewest clusters a FAT32 volume has, by the specification; fewer is FAT12 or FAT16. */
MIN_CLUSTERS : u32 : 65525

/** Why a volume operation failed. */
FatError :: enum {
    /** Not a FAT32 volume: no boot sector, another FAT, or a layout that doesn't fit the device. */
    NotFat,
    /** No entry has the name, or the entry looked for has been removed. */
    NotFound,
    /** A path's component before its last is a file, not a directory. */
    NotADirectory,
    /** A file's operation was asked of a directory. */
    IsADirectory,
    /** An entry with the name is already in the directory. */
    AlreadyExists,
    /** A directory to remove has entries in it besides "." and "..". */
    DirectoryNotEmpty,
    /**
     * A name FAT can't hold: empty, too long, a character it refuses, or ending in a space or a dot; also a path with
     * an empty, "." or ".." component, a move that would put a directory beneath itself, and a format's bad cluster
     * size.
     */
    InvalidName,
    /** No free cluster, no free slots in a directory at its most, no free alias tail, or a file past 4 GiB - 1. */
    NoSpace,
    /** The device couldn't be read or written, or a read was of a sector a failed write was for. */
    DeviceError,
    /** A chain or a directory that doesn't hold together: a link outside the volume, a loop, or a chain too short. */
    Corrupt,
    /** The device is read-only, so nothing may be written. */
    ReadOnly,
}

/** A device to read and write: a partition or disk of SECTOR_BYTES sectors, through its functions. */
Device :: struct #scoped {
    /** What read and write are given back as their context, the caller's own; never read here. */
    context : rawptr,
    /** The device's size in sectors; a volume's layout has to fit in it. */
    sector_count : u64,
    /**
     * Read count sectors, from sector first, into into, which holds at least count * SECTOR_BYTES bytes; true if they
     * were read, false if the device couldn't read them.
     */
    read : fn(context: rawptr, first: u64, count: u64, into: mut u8[]) -> bool,
    /**
     * Write count sectors, from sector first, from from's first count * SECTOR_BYTES bytes; true if they were
     * written, false if the device couldn't write them, which leaves what's in them unknown.
     */
    write : fn(context: rawptr, first: u64, count: u64, from: u8[]) -> bool,
    /**
     * Whether the device may only be read: every operation that would write fails with ReadOnly, and write_info
     * writes nothing. format doesn't look at it.
     */
    read_only : bool,
}

/** FSInfo's count of free clusters when it's unknown, as a volume's free_count is until it's counted. */
UNKNOWN_FREE : u32 : 0xffffffff

/**
 * A mounted volume: its device, its layout, and where the next free cluster is likely to be.
 *
 * Its fields are this package's to keep, all but stamp, which its user sets; a caller reads them at most. A volume
 * holds nothing that needs freeing.
 */
Volume :: struct #scoped {
    /** The device the volume is on, read and written through its functions. */
    device : Device,
    /** The sectors in a cluster, a power of two. */
    sectors_per_cluster : u64,
    /** The bytes in a cluster: sectors_per_cluster * SECTOR_BYTES. */
    cluster_bytes : u64,
    /** The sectors before the first FAT, from the volume's start; the boot sector and FSInfo are among them. */
    reserved_sectors : u64,
    /** How many FATs the volume has, at least 1; every one is written alike, and the first is the one read. */
    fat_count : u64,
    /** The sectors in each FAT. */
    fat_sectors : u64,
    /** The first sector of cluster 2, after the reserved sectors and every FAT. */
    first_data_sector : u64,
    /** How many clusters there are, numbered from 2 to cluster_count + 1: at least MIN_CLUSTERS. */
    cluster_count : u32,
    /** The root directory's first cluster, from the BPB. */
    root_cluster : u32,
    /** FSInfo's sector, from the BPB; 0, or one not among the reserved sectors, when the volume has none. */
    info_sector : u64,
    /** The cluster to start looking for a free one at: a hint, not a promise that it's free. */
    next_free : u32,
    /** How many clusters are free, kept as clusters are taken and freed; UNKNOWN_FREE until it's read or counted. */
    free_count : u32,
    /** Whether free_count or next_free changed since FSInfo was written, so write_info has something to write. */
    info_changed : bool,
    /**
     * The date, in its high 16 bits, and time, in its low, that an entry made or written to now gets, as FAT holds
     * them (stamp_of); EPOCH_STAMP until its user sets it.
     */
    stamp : u32,
    /** The volume's label from the boot sector: 11 bytes, space-padded, as they are there. */
    label : u8[11],
    /*
     * Where a walk along a directory's chain last was: its first cluster, how many clusters in, and that cluster, so a
     * directory read slot by slot follows its chain once, not from its start for each slot, even a chain that loops.
     */
    /** The first cluster of the directory last walked; FREE_CLUSTER when no walk is kept, as after the FAT changes. */
    chain_first : u32,
    /** How many clusters into the walked directory's chain chain_cluster is, from 0. */
    chain_index : u64,
    /** The cluster chain_index clusters into the walked directory's chain. */
    chain_cluster : u32,
    /** Whether a write has failed since the volume was mounted; once set, it stays set. */
    failed : bool,
    /** The sectors failed writes were for, not written whole since; the first failed_count are used. */
    failed_sectors : u64[MAX_FAILED_SECTORS],
    /** How many of failed_sectors are used; past MAX_FAILED_SECTORS, some weren't kept, so every read is refused. */
    failed_count : u32,
}

/** The most sectors of failed writes a volume remembers; past it, every read is refused. */
MAX_FAILED_SECTORS :: 32

/**
 * Read sectors from the volume's device, unless a failed write was for one of them.
 *
 * @param volume The volume, as mount made it; reads go through its record of failed writes.
 * @param first The first sector, from the volume's start.
 * @param count How many sectors.
 * @param into Where they go, at least count * SECTOR_BYTES bytes.
 * @return True if they were read; false if the device couldn't read them, or one is a sector a failed write was for
 *     (or more than MAX_FAILED_SECTORS were), since what's there isn't what was written.
 */
read_sectors :: fn(volume: ptr[mut Volume], first: u64, count: u64, into: mut u8[]) -> bool {
    if volume.failed_count > MAX_FAILED_SECTORS {
        return false
    }
    for sector, i in volume.failed_sectors {
        if i < cast[usize](volume.failed_count) && sector >= first && sector - first < count {
            return false
        }
    }
    return volume.device.read(volume.device.context, first, count, into)
}

/**
 * Write sectors to the volume's device, keeping track of failed writes.
 *
 * A write that fails marks the volume failed for good and remembers its sectors, so reads of them are refused; one
 * that succeeds forgets its sectors' earlier failures, since they now hold what was written.
 *
 * @param volume The volume, as mount made it; reads go through its record of failed writes.
 * @param first The first sector, from the volume's start.
 * @param count How many sectors.
 * @param from Their bytes, at least count * SECTOR_BYTES.
 * @return True if they were written; false if the device couldn't write them.
 */
write_sectors :: fn(volume: ptr[mut Volume], first: u64, count: u64, from: u8[]) -> bool {
    wrote :: volume.device.write(volume.device.context, first, count, from)
    for sector in first..<first + count {
        note_sector(volume, sector, !wrote)
    }
    if !wrote {
        volume.failed = true
    }
    return wrote
}

/**
 * Note that a write of a whole sector failed or succeeded.
 *
 * @param volume The volume; once more than MAX_FAILED_SECTORS sectors have failed, nothing more is noted.
 * @param sector The sector the write was for, from the volume's start.
 * @param failed True if the write failed, so the sector is remembered; false if it succeeded, so it's forgotten.
 */
note_sector :: fn(volume: ptr[mut Volume], sector: u64, failed: bool) {
    if volume.failed_count > MAX_FAILED_SECTORS {
        return void
    }
    for i in cast[usize](0)..<volume.failed_sectors.count {
        if i < cast[usize](volume.failed_count) && volume.failed_sectors[i] == sector {
            if !failed {
                last :: cast[usize](volume.failed_count) - 1
                if last < volume.failed_sectors.count {
                    volume.failed_sectors[i] = volume.failed_sectors[last]
                }
                volume.failed_count -= 1
            }
            return void
        }
    }
    if !failed {
        return void
    }
    at :: cast[usize](volume.failed_count)
    if at < volume.failed_sectors.count {
        volume.failed_sectors[at] = sector
    }
    volume.failed_count += 1
}

/** Where an entry's short entry is: its directory's first cluster, and its slot in that directory. */
Place :: struct {
    /** The first cluster of the directory the entry is in. */
    directory : u32,
    /** The short entry's slot in the directory, from 0, ENTRY_BYTES each, below MAX_DIRECTORY_SLOTS. */
    slot : u32,
    /** How many long-name entries come right before the short entry, 0 if it has no long name. */
    long_entries : u32,
}

/**
 * An entry of a directory, as read or made: its name as UTF-8, its short name, its attributes, its first cluster and
 * size, and where it is.
 *
 * It's a copy: it doesn't change when the volume does, and its place stays good only until its entry is removed or
 * renamed.
 */
Entry :: struct {
    /** The name as UTF-8, its first name_length bytes used: the long name, or the short name as text. */
    name : u8[NAME_BYTES],
    /** How many bytes of name are used, 1 to NAME_BYTES. */
    name_length : u32,
    /** The short name as it is on the volume: 8 bytes of base, 3 of extension, space-padded, upper-case. */
    short_name : u8[11],
    /** The entry's attribute bits (DIRECTORY, ARCHIVE and the rest). */
    attributes : u8,
    /** The first cluster of its chain; 0 for an empty file with none, or for ".." of the root's directories. */
    first_cluster : u32,
    /** The file's size in bytes, at most 4 GiB - 1; 0 for a directory. */
    size : u32,
    /** Where its short entry is. */
    place : Place,
    /** When it was last written to: the date in the high 16 bits, the time in the low, as stamp_of makes them. */
    written : u32,
}

/** A short directory entry, as it is on the volume: 32 bytes, little-endian. */
ShortEntry :: struct #packed {
    /** The 8.3 name: 8 bytes of base, 3 of extension, space-padded; a first byte of DELETED or END marks it free. */
    name : u8[11],
    /** The attribute bits. */
    attributes : u8,
    /** LOWER_BASE and LOWER_EXTENSION, for an 8.3 name kept in lower case without a long name; otherwise 0. */
    case_flags : u8,
    /** The creation time's hundredths of a second, 0 to 199; always 0 here. */
    created_tenths : u8,
    /** The creation time: seconds / 2, minutes and hours, in bits 0-4, 5-10 and 11-15. */
    created_time : u16le,
    /** The creation date: day, month and years since 1980, in bits 0-4, 5-8 and 9-15. */
    created_date : u16le,
    /** The last access date, as created_date. */
    accessed_date : u16le,
    /** The first cluster's high 16 bits. */
    cluster_high : u16le,
    /** The last write's time, as created_time. */
    written_time : u16le,
    /** The last write's date, as created_date. */
    written_date : u16le,
    /** The first cluster's low 16 bits. */
    cluster_low : u16le,
    /** The file's size in bytes; 0 for a directory. */
    size : u32le,
}

#assert size_of(ShortEntry) == 32

/**
 * A long-name entry, 13 of the name's UTF-16 code units; a name's long-name entries come right before its short
 * entry, its last part first.
 */
LongEntry :: struct #packed {
    /** The entry's part of the name, 1 to MAX_LONG_ENTRIES in its low 5 bits, with LAST_LONG_ENTRY on the last part. */
    order : u8,
    /** Code units 1 to 5 of the entry's 13. */
    name1 : u16le[5],
    /** LONG_NAME. */
    attributes : u8,
    /** The entry's kind; 0 for a part of a name. */
    kind : u8,
    /** The short name's checksum (short_checksum), the same in each of a name's long-name entries. */
    checksum : u8,
    /** Code units 6 to 11. */
    name2 : u16le[6],
    /** Zero. */
    cluster : u16le,
    /** Code units 12 and 13. After the name's end come one zero unit, then 0xffff units. */
    name3 : u16le[2],
}

#assert size_of(LongEntry) == 32

/** The date of 1980-01-01, the earliest FAT holds, as an entry's date: day 1, month 1, year 0. */
EPOCH_DATE : u16 : (1 << 5) | 1
/** 1980-01-01 at midnight as a stamp, as stamp_of makes one: what a volume's stamp is until its user sets it. */
EPOCH_STAMP : u32 : cast[u32](EPOCH_DATE) << 16

/**
 * Make a date and time into a stamp as FAT holds them, for a volume's stamp.
 *
 * @param year The year, 1980 to 2107.
 * @param month The month, 1 to 12.
 * @param day The day of the month, 1 to 31; not checked against the month's length.
 * @param hour The hour, 0 to 23.
 * @param minute The minute, 0 to 59.
 * @param second The second, 0 to 59; FAT keeps only even seconds, so an odd one is rounded down.
 * @return The date in the high 16 bits (day, month, years since 1980) and the time in the low (seconds / 2, minutes,
 *     hours); EPOCH_STAMP if any part is out of its range.
 */
stamp_of :: fn(year: i64, month: int, day: int, hour: int, minute: int, second: int) -> u32 {
    if year < 1980 || year > 2107 || month < 1 || month > 12 || day < 1 || day > 31 || hour < 0 || hour > 23 || minute < 0
        || minute > 59 || second < 0 || second > 59 {
        return EPOCH_STAMP
    }
    date :: cast[u32](year - 1980) << 9 | cast[u32](month) << 5 | cast[u32](day)
    time :: cast[u32](hour) << 11 | cast[u32](minute) << 5 | cast[u32](second / 2)
    return date << 16 | time
}
/** A case flag: the 8.3 name's base is all lower case, kept so without a long name. */
LOWER_BASE : u8 : 0x08
/** A case flag: the 8.3 name's extension is all lower case, kept so without a long name. */
LOWER_EXTENSION : u8 : 0x10
/** The bit of a long-name entry's order that marks the name's last part, the first of its entries in the directory. */
LAST_LONG_ENTRY : u8 : 0x40

// Mounting

/**
 * Mount the FAT32 volume on a device, checking its boot sector.
 *
 * Nothing is written. FSInfo's free count and next free cluster are taken if its signatures are there and they fit
 * the volume; otherwise the free count is UNKNOWN_FREE until free_clusters counts it.
 *
 * @param device The device, its first sector the volume's boot sector; the volume keeps a copy of it.
 * @return The volume, its stamp EPOCH_STAMP until its user sets it.
 * @error DeviceError The boot sector couldn't be read.
 * @error NotFat The boot sector isn't a FAT32 one: no boot signature, sectors other than 512 bytes, a cluster that
 *     isn't a power of two of sectors, a fixed root directory or 16-bit counts, too few clusters for FAT32 or too
 *     many for its FAT, a root cluster outside the volume, or a layout bigger than the device.
 */
mount :: fn(device: Device) -> Result[Volume, FatError] {
    sector : u8[512]
    if !device.read(device.context, 0, 1, sector) {
        return .Error(.DeviceError)
    }
    if get_u8(sector, 510) != 0x55 || get_u8(sector, 511) != 0xaa || cast[u64](get_u16(sector, 11)) != SECTOR_BYTES {
        return .Error(.NotFat)
    }
    per_cluster :: cast[u64](get_u8(sector, 13))
    reserved :: cast[u64](get_u16(sector, 14))
    fats :: cast[u64](get_u8(sector, 16))
    root_entries :: get_u16(sector, 17)
    small_total :: get_u16(sector, 19)
    small_fat :: get_u16(sector, 22)
    total :: cast[u64](get_u32(sector, 32))
    fat_sectors :: cast[u64](get_u32(sector, 36))
    root :: get_u32(sector, 44)
    info :: cast[u64](get_u16(sector, 48))
    if per_cluster == 0 || per_cluster & (per_cluster - 1) != 0 || reserved == 0 || fats == 0 || root_entries != 0 || small_total != 0
        || small_fat != 0 || fat_sectors == 0 || total > device.sector_count {
        return .Error(.NotFat)
    }
    first_data :: reserved + fats * fat_sectors
    if first_data >= total {
        return .Error(.NotFat)
    }
    clusters :: (total - first_data) / per_cluster
    // Each FAT has an entry for every cluster, from 2
    if clusters < cast[u64](MIN_CLUSTERS) || clusters > cast[u64](CLUSTER_MASK) - 16 || (clusters + 2) * 4 > fat_sectors * SECTOR_BYTES
        || root < 2 || cast[u64](root) >= clusters + 2 {
        return .Error(.NotFat)
    }
    volume := Volume.{device = device, sectors_per_cluster = per_cluster, cluster_bytes = per_cluster * SECTOR_BYTES, reserved_sectors = reserved,
        fat_count = fats, fat_sectors = fat_sectors, first_data_sector = first_data, cluster_count = cast[u32](clusters), root_cluster = root,
        info_sector = info, next_free = 2, free_count = UNKNOWN_FREE, stamp = EPOCH_STAMP}
    for i in 0..<cast[usize](11) {
        volume.label[i] = get_u8(sector, 71 + i)
    }
    read_info(&volume)
    return .Ok(volume)
}

/**
 * Take FSInfo's free count and next free cluster, where its signatures are and they fit the volume.
 *
 * A missing or unreadable FSInfo, or a value that doesn't fit, leaves the volume's free_count and next_free as they
 * were.
 *
 * @param volume The volume, just mounted.
 */
read_info :: fn(volume: ptr[mut Volume]) {
    if volume.info_sector == 0 || volume.info_sector >= volume.reserved_sectors {
        return void
    }
    info : u8[512]
    if !read_sectors(volume, volume.info_sector, 1, info) || get_u32(info, 0) != 0x41615252
        || get_u32(info, 484) != 0x61417272 || get_u32(info, 508) != 0xaa550000 {
        return void
    }
    free :: get_u32(info, 488)
    if free <= volume.cluster_count {
        volume.free_count = free
    }
    next :: get_u32(info, 492)
    if is_cluster(volume, next) {
        volume.next_free = next
    }
}

/**
 * Write the free count and next free cluster to FSInfo, and to its backup after the backup boot sector, if they
 * changed and the volume has an FSInfo.
 *
 * They're only a hint to whoever mounts the volume next, so a crash before they're written loses nothing but the
 * hint. Nothing is written for a read-only device, an unchanged count, no FSInfo, or an FSInfo whose signatures
 * aren't there.
 *
 * @param volume The volume; its info_changed is cleared once both copies are written.
 * @return Null if they were written, or there was nothing to write; DeviceError if FSInfo couldn't be read or
 *     written, info_changed left set so a later call tries again.
 */
write_info :: fn(volume: ptr[mut Volume]) -> FatError? {
    if !volume.info_changed || volume.device.read_only || volume.info_sector == 0 || volume.info_sector >= volume.reserved_sectors {
        return null
    }
    info : u8[512]
    if !read_sectors(volume, volume.info_sector, 1, info) {
        return FatError.DeviceError
    }
    if get_u32(info, 0) != 0x41615252 || get_u32(info, 484) != 0x61417272 {
        return null
    }
    put_u32(info, 488, volume.free_count)
    put_u32(info, 492, volume.next_free)
    // The backup boot sector, at 6 as the BPB says, has FSInfo's backup after it
    backup :: cast[u64](6) + volume.info_sector
    for at in u64.[volume.info_sector, backup] {
        if at < volume.reserved_sectors && !write_sectors(volume, at, 1, info) {
            return FatError.DeviceError
        }
    }
    volume.info_changed = false
    return null
}

/**
 * Get how many clusters are free: FSInfo's count as kept since mounting, or counted through the FAT the first time
 * it isn't known.
 *
 * A count made is kept from then on, and marked to be written to FSInfo by write_info.
 *
 * @param volume The volume, as mount made it; reads go through its record of failed writes.
 * @return The free clusters, 0 to cluster_count; each is cluster_bytes bytes.
 * @error DeviceError The FAT couldn't be read to count them.
 */
free_clusters :: fn(volume: ptr[mut Volume]) -> Result[u32, FatError] {
    if volume.free_count == UNKNOWN_FREE {
        volume.free_count = count_free(volume)?
        volume.info_changed = true
    }
    return .Ok(volume.free_count)
}

/**
 * Count the clusters the first FAT has free, reading it a sector at a time.
 *
 * @param volume The volume, as mount made it; reads go through its record of failed writes.
 * @return The free clusters among 2 to cluster_count + 1, so 0 to cluster_count.
 * @error DeviceError A sector of the FAT couldn't be read.
 */
count_free :: fn(volume: ptr[mut Volume]) -> Result[u32, FatError] {
    free : u32 = 0
    sector : u8[512]
    entries_per_sector :: SECTOR_BYTES / 4
    last :: cast[u64](volume.cluster_count) + 2
    at := cast[u64](0)
    loop {
        if at >= last {
            break
        }
        if !read_sectors(volume, volume.reserved_sectors + at / entries_per_sector, 1, sector) {
            return .Error(.DeviceError)
        }
        for index in 0..<entries_per_sector {
            cluster :: at + index
            if cluster >= 2 && cluster < last && get_u32(sector, cast[usize](index * 4)) & CLUSTER_MASK == FREE_CLUSTER {
                free += 1
            }
        }
        at += entries_per_sector
    }
    return .Ok(free)
}

/**
 * Get the root directory's first cluster, the directory to give resolve, lookup, next_entry and create.
 *
 * @param volume The volume, as mount made it; only its layout is used, nothing is read.
 * @return The root's first cluster, from the BPB.
 */
root_of :: fn(volume: ptr[mut Volume]) -> u32 {
    return volume.root_cluster
}

// Clusters and the FAT

/**
 * Get the first sector of a cluster.
 *
 * @param volume The volume, as mount made it; only its layout is used, nothing is read.
 * @param cluster The cluster, 2 or more; not checked, so the caller checks it with is_cluster.
 * @return The cluster's first sector, from the volume's start.
 */
sector_of :: fn(volume: ptr[mut Volume], cluster: u32) -> u64 {
    return volume.first_data_sector + cast[u64](cluster - 2) * volume.sectors_per_cluster
}

/**
 * Tell whether a number is one of the volume's clusters.
 *
 * @param volume The volume, as mount made it; only its layout is used, nothing is read.
 * @param cluster The number, as a FAT entry or a directory entry has it.
 * @return True if it's from 2 to cluster_count + 1.
 */
is_cluster :: fn(volume: ptr[mut Volume], cluster: u32) -> bool {
    return cluster >= 2 && cluster < volume.cluster_count + 2
}

/**
 * Read a cluster's FAT entry from the first FAT.
 *
 * @param volume The volume, as mount made it; reads go through its record of failed writes.
 * @param cluster The cluster, one of the volume's; not checked.
 * @return The entry's 28 bits: FREE_CLUSTER, the next cluster, or END_OF_CHAIN or more for a chain's end.
 * @error DeviceError The FAT's sector couldn't be read.
 */
fat_entry :: fn(volume: ptr[mut Volume], cluster: u32) -> Result[u32, FatError] {
    offset :: cast[u64](cluster) * 4
    sector : u8[512]
    if !read_sectors(volume, volume.reserved_sectors + offset / SECTOR_BYTES, 1, sector) {
        return .Error(.DeviceError)
    }
    return .Ok(get_u32(sector, cast[usize](offset % SECTOR_BYTES)) & CLUSTER_MASK)
}

/**
 * Set a cluster's FAT entry in every FAT, its top four bits kept.
 *
 * The FATs are written one after another, so a failure partway leaves them differing; the first is the one read.
 * Any walk along a directory's chain kept in the volume is dropped, since a chain may have changed.
 *
 * @param volume The volume, as mount made it; reads go through its record of failed writes.
 * @param cluster The cluster whose entry is set.
 * @param value The new value, its low 28 bits used: FREE_CLUSTER, the next cluster, or CHAIN_END_MARK.
 * @return Null if every FAT was written; ReadOnly for a read-only device, nothing written; DeviceError if a FAT's
 *     sector couldn't be read or written.
 */
set_fat_entry :: fn(volume: ptr[mut Volume], cluster: u32, value: u32) -> FatError? {
    if volume.device.read_only {
        return FatError.ReadOnly
    }
    // A chain may have changed, so a walk along one starts again
    volume.chain_first = FREE_CLUSTER
    offset :: cast[u64](cluster) * 4
    for copy in 0..<volume.fat_count {
        at :: volume.reserved_sectors + copy * volume.fat_sectors + offset / SECTOR_BYTES
        sector : u8[512]
        if !read_sectors(volume, at, 1, sector) {
            return FatError.DeviceError
        }
        within :: cast[usize](offset % SECTOR_BYTES)
        put_u32(sector, within, (get_u32(sector, within) & ~CLUSTER_MASK) | (value & CLUSTER_MASK))
        if !write_sectors(volume, at, 1, sector) {
            return FatError.DeviceError
        }
    }
    return null
}

/**
 * Get the cluster after one in its chain.
 *
 * @param volume The volume, as mount made it; reads go through its record of failed writes.
 * @param cluster The cluster, one of the volume's.
 * @return The next cluster, one of the volume's; null if cluster ends its chain.
 * @error DeviceError The FAT couldn't be read.
 * @error Corrupt The FAT entry is neither a chain's end nor one of the volume's clusters, as a free cluster's is.
 */
next_cluster :: fn(volume: ptr[mut Volume], cluster: u32) -> Result[u32?, FatError] {
    entry :: fat_entry(volume, cluster)?
    if entry >= END_OF_CHAIN {
        return .Ok(null)
    }
    if !is_cluster(volume, entry) {
        return .Error(.Corrupt)
    }
    return .Ok(entry)
}

/**
 * Take a free cluster: marked as a chain's end, zeroed, and linked after another unless that's 0.
 *
 * The search starts at next_free and goes around the volume once. The cluster is marked taken before it's zeroed
 * and linked, so a failure or a crash after that loses it (taken, but in no chain) rather than giving it out twice.
 *
 * @param volume The volume; its next_free and free count are updated.
 * @param previous The cluster to link the new one after, which should end its chain; 0 to start a new chain.
 * @return The cluster taken, zeroed, ending its chain.
 * @error ReadOnly The device is read-only.
 * @error NoSpace No cluster is free.
 * @error DeviceError The FAT couldn't be read or written, or the cluster couldn't be zeroed.
 */
allocate_cluster :: fn(volume: ptr[mut Volume], previous: u32) -> Result[u32, FatError] {
    if volume.device.read_only {
        return .Error(.ReadOnly)
    }
    start := volume.next_free
    if !is_cluster(volume, start) {
        start = 2
    }
    for step in 0..<volume.cluster_count {
        cluster :: 2 + ((start - 2 + step) % volume.cluster_count)
        if fat_entry(volume, cluster)? != FREE_CLUSTER {
            continue
        }
        if set_fat_entry(volume, cluster, CHAIN_END_MARK) is_some {
            return .Error(.DeviceError)
        }
        zero_cluster(volume, cluster)?
        if previous != 0 {
            match set_fat_entry(volume, previous, cluster) {
                case Some(error) => return .Error(error)
                case None => {}
            }
        }
        volume.next_free = cluster + 1
        if volume.free_count != UNKNOWN_FREE && volume.free_count > 0 {
            volume.free_count -= 1
        }
        volume.info_changed = true
        return .Ok(cluster)
    }
    return .Error(.NoSpace)
}

/**
 * Write zeros over every sector of a cluster.
 *
 * @param volume The volume, as mount made it; reads go through its record of failed writes.
 * @param cluster The cluster, one of the volume's.
 * @error DeviceError A sector couldn't be written; the sectors before it are zero.
 */
zero_cluster :: fn(volume: ptr[mut Volume], cluster: u32) -> Result[void, FatError] {
    zeros : u8[512]
    first :: sector_of(volume, cluster)
    for i in 0..<volume.sectors_per_cluster {
        if !write_sectors(volume, first + i, 1, zeros) {
            return .Error(.DeviceError)
        }
    }
    return .Ok
}

/**
 * Free every cluster of a chain, first to last.
 *
 * Each cluster is freed in every FAT before the next is looked at, so a failure partway leaves the chain's start
 * free and its rest taken but in no chain, lost until the volume is checked.
 *
 * @param volume The volume; its next_free and free count are updated.
 * @param first The chain's first cluster; a number that isn't a cluster frees nothing.
 * @return Null once the chain's end is freed; DeviceError if the FAT couldn't be read or written; Corrupt if a link
 *     leads outside the volume or the chain is longer than the volume (a loop), or for a read-only device.
 */
free_chain :: fn(volume: ptr[mut Volume], first: u32) -> FatError? {
    cluster := first
    for step in 0..<volume.cluster_count {
        if !is_cluster(volume, cluster) {
            return null
        }
        following := cast[u32](0)
        match next_cluster(volume, cluster) {
            case Ok(next) => following = next or_else 0
            case Error(error) => return error
        }
        if set_fat_entry(volume, cluster, FREE_CLUSTER) is_some {
            return FatError.DeviceError
        }
        if cluster < volume.next_free {
            volume.next_free = cluster
        }
        if volume.free_count != UNKNOWN_FREE && volume.free_count < volume.cluster_count {
            volume.free_count += 1
        }
        volume.info_changed = true
        if following == 0 {
            return null
        }
        cluster = following
    }
    return FatError.Corrupt
}

/**
 * Find a cluster some way along a chain.
 *
 * @param volume The volume, as mount made it; reads go through its record of failed writes.
 * @param first The chain's first cluster.
 * @param index How many clusters along, 0 for first itself.
 * @return The cluster; null if the chain is shorter, or first isn't a cluster (as an empty file's 0 isn't).
 * @error DeviceError The FAT couldn't be read.
 * @error Corrupt A link leads outside the volume.
 */
cluster_at :: fn(volume: ptr[mut Volume], first: u32, index: u64) -> Result[u32?, FatError] {
    cluster := first
    for step in 0..<index {
        step_result :: next_cluster(volume, cluster)?
        match step_result {
            case Some(next) => cluster = next
            case None => return .Ok(null)
        }
    }
    return .Ok(if is_cluster(volume, cluster) { cluster } else { cast[u32?](null) })
}

// Directory slots

/** Where a directory slot's ENTRY_BYTES bytes are on the device. */
SlotAt :: struct {
    /** The sector the slot is in, from the volume's start. */
    sector : u64,
    /** The slot's offset in its sector, in bytes, a multiple of ENTRY_BYTES below SECTOR_BYTES. */
    offset : usize,
}

/**
 * Find where a directory's slot is on the device.
 *
 * The walk along the directory's chain starts from where the volume's last one was, if that's the same directory and
 * not past the slot, so reading a directory slot by slot follows its chain once.
 *
 * @param volume The volume; its kept walk is updated.
 * @param directory The directory's first cluster.
 * @param slot The slot, from 0.
 * @return Where the slot is; null if it's past the directory's chain's end or at MAX_DIRECTORY_SLOTS or more.
 * @error DeviceError The FAT couldn't be read.
 * @error Corrupt A link in the chain leads outside the volume.
 */
slot_at :: fn(volume: ptr[mut Volume], directory: u32, slot: u32) -> Result[SlotAt?, FatError] {
    per_cluster :: volume.cluster_bytes / ENTRY_BYTES
    // A directory ends at FAT's most slots, wherever its chain does, so one that loops ends too
    if slot >= MAX_DIRECTORY_SLOTS || per_cluster == 0 {
        return .Ok(null)
    }
    index :: cast[u64](slot) / per_cluster
    if volume.chain_first != directory || volume.chain_index > index || directory == FREE_CLUSTER {
        volume.chain_first = directory
        volume.chain_index = 0
        volume.chain_cluster = directory
    }
    for step in volume.chain_index..<index {
        step_result :: next_cluster(volume, volume.chain_cluster)?
        match step_result {
            case Some(next) => {
                volume.chain_cluster = next
                volume.chain_index += 1
            }
            case None => return .Ok(null)
        }
    }
    cluster :: volume.chain_cluster
    if !is_cluster(volume, cluster) {
        return .Ok(null)
    }
    within :: (cast[u64](slot) % per_cluster) * ENTRY_BYTES
    return .Ok(SlotAt.{sector = sector_of(volume, cluster) + within / SECTOR_BYTES, offset = cast[usize](within % SECTOR_BYTES)})
}

/**
 * Read a directory slot's bytes.
 *
 * @param volume The volume, as mount made it; reads go through its record of failed writes.
 * @param at Where the slot is, from slot_at.
 * @param into Where its 32 bytes go.
 * @return Null if it was read; DeviceError if its sector couldn't be.
 */
read_slot :: fn(volume: ptr[mut Volume], at: SlotAt, into: ptr[mut u8[32]]) -> FatError? {
    sector : u8[512]
    if !read_sectors(volume, at.sector, 1, sector) {
        return FatError.DeviceError
    }
    for i in 0..<cast[usize](32) {
        into^[i] = get_u8(sector, at.offset + i)
    }
    return null
}

/**
 * Write a directory slot's bytes, the rest of its sector kept.
 *
 * @param volume The volume, as mount made it; reads go through its record of failed writes.
 * @param at Where the slot is, from slot_at.
 * @param from Its 32 new bytes.
 * @return Null if it was written; ReadOnly for a read-only device; DeviceError if its sector couldn't be read or
 *     written.
 */
write_slot :: fn(volume: ptr[mut Volume], at: SlotAt, from: ptr[u8[32]]) -> FatError? {
    if volume.device.read_only {
        return FatError.ReadOnly
    }
    sector : u8[512]
    if !read_sectors(volume, at.sector, 1, sector) {
        return FatError.DeviceError
    }
    for byte, i in from^ {
        put_u8(sector, at.offset + i, byte)
    }
    if !write_sectors(volume, at.sector, 1, sector) {
        return FatError.DeviceError
    }
    return null
}

// Listing

/** An entry listed, and the slot to list from next. */
Listed :: struct {
    /** The entry. */
    entry : Entry,
    /** The slot after the entry's short entry, to give next_entry to list the one after it. */
    next : u32,
}

/**
 * List the entry at or after a slot in a directory.
 *
 * An entry's name is its long name where its long-name entries are whole and match its checksum, otherwise its short
 * name as text. Volume labels, "." and ".." are left out, and broken long-name entries are skipped.
 *
 * @param volume The volume, as mount made it; reads go through its record of failed writes.
 * @param directory The directory's first cluster.
 * @param slot The slot to start at: 0 for the directory's first entry, or a Listed's next for the one after it.
 * @return The entry and the slot after it; null at the directory's end (an END slot, its chain's end, or
 *     MAX_DIRECTORY_SLOTS).
 * @error DeviceError The directory or the FAT couldn't be read.
 * @error Corrupt The directory's chain leads outside the volume.
 */
next_entry :: fn(volume: ptr[mut Volume], directory: u32, slot: u32) -> Result[Listed?, FatError] {
    units : u16[MAX_NAME_UNITS + 13]
    long_count := cast[u32](0)
    expected := cast[u8](0)
    checksum := cast[u8](0)
    at_slot := slot
    for step in 0..<MAX_DIRECTORY_SLOTS {
        place :: slot_at(volume, directory, at_slot)? or_return .Ok(null)
        bytes : u8[32]
        match read_slot(volume, place, &bytes) {
            case Some(error) => return .Error(error)
            case None => {}
        }
        current :: at_slot
        at_slot += 1
        first :: bytes[0]
        if first == END {
            return .Ok(null)
        }
        if first == DELETED {
            long_count = 0
            expected = 0
            continue
        }
        attributes :: bytes[11]
        if attributes & 0x3f == LONG_NAME {
            order :: first & 0x1f
            if first & LAST_LONG_ENTRY != 0 {
                expected = order
                long_count = cast[u32](order)
                checksum = bytes[13]
                for &unit in units {
                    unit^ = 0
                }
            }
            else if order == 0 || order != expected || bytes[13] != checksum {
                long_count = 0
                expected = 0
                continue
            }
            if order == 0 || cast[usize](order) > MAX_LONG_ENTRIES {
                long_count = 0
                expected = 0
                continue
            }
            // This entry's 13 code units go at (order - 1) * 13
            base :: (cast[usize](order) - 1) * 13
            positions :: usize.[1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30]
            for position, k in positions {
                index :: base + k
                if index < units.count {
                    units[index] = cast[u16](bytes[position % 32]) | cast[u16](bytes[(position + 1) % 32]) << 8
                }
            }
            expected = order - 1
            continue
        }
        if attributes & VOLUME_ID != 0 {
            long_count = 0
            continue
        }
        entry := Entry.{attributes = attributes}
        for i in 0..<cast[usize](11) {
            entry.short_name[i] = bytes[i]
        }
        entry.first_cluster = cast[u32](get_u16(bytes, 20)) << 16 | cast[u32](get_u16(bytes, 26))
        entry.size = get_u32(bytes, 28)
        entry.written = cast[u32](get_u16(bytes, 24)) << 16 | cast[u32](get_u16(bytes, 22))
        entry.place = Place.{directory = directory, slot = current, long_entries = 0}
        if long_count != 0 && expected == 0 && short_checksum(&entry.short_name) == checksum {
            entry.name_length = utf8_of_units(view_of(&units[0], cast[usize](long_count) * 13), &entry.name)
            entry.place.long_entries = long_count
        }
        else {
            entry.name_length = name_of_short(&entry.short_name, bytes[12], &entry.name)
        }
        long_count = 0
        expected = 0
        // "." and "..": no long name, and a short name of dots
        if entry.short_name[0] == cast[u8]('.') {
            continue
        }
        return .Ok(Listed.{entry = entry, next = at_slot})
    }
    return .Error(.Corrupt)
}

/**
 * Read again the entry whose short entry is at a place, as it is now, so connections to one file see what each
 * writes.
 *
 * @param volume The volume, as mount made it; reads go through its record of failed writes.
 * @param place Where the short entry was, from an Entry got earlier.
 * @param name The entry's name, copied into the result as it is, not read again.
 * @return The entry, its size, first cluster and written time as they are now.
 * @error NotFound The slot is past the directory's end, free, or a long-name entry: the entry has been removed. A
 *     slot reused by another entry since isn't told apart.
 * @error DeviceError The directory or the FAT couldn't be read.
 * @error Corrupt The directory's chain leads outside the volume.
 */
entry_at :: fn(volume: ptr[mut Volume], place: Place, name: string) -> Result[Entry, FatError] {
    at :: slot_at(volume, place.directory, place.slot)? or_return .Error(.NotFound)
    bytes : u8[32]
    match read_slot(volume, at, &bytes) {
        case Some(error) => return .Error(error)
        case None => {}
    }
    if bytes[0] == END || bytes[0] == DELETED || bytes[11] & 0x3f == LONG_NAME {
        return .Error(.NotFound)
    }
    entry := Entry.{attributes = bytes[11], place = place}
    for i in 0..<cast[usize](11) {
        entry.short_name[i] = bytes[i]
    }
    entry.first_cluster = cast[u32](get_u16(bytes, 20)) << 16 | cast[u32](get_u16(bytes, 26))
    entry.size = get_u32(bytes, 28)
    entry.written = cast[u32](get_u16(bytes, 24)) << 16 | cast[u32](get_u16(bytes, 22))
    entry.name_length = copy_name(name, &entry.name)
    return .Ok(entry)
}

/**
 * Look up an entry in a directory by its name, compared without regard to ASCII case (same_name).
 *
 * Only the name next_entry lists is compared: the long name where there is one, not the short alias besides.
 *
 * @param volume The volume, as mount made it; reads go through its record of failed writes.
 * @param directory The directory's first cluster.
 * @param name The name, UTF-8, without '/'.
 * @return The entry, a copy, with the name as the directory holds it, which may differ in case from the name asked for.
 * @error NotFound No entry has the name.
 * @error DeviceError The directory or the FAT couldn't be read.
 * @error Corrupt The directory doesn't hold together (see next_entry).
 */
lookup :: fn(volume: ptr[mut Volume], directory: u32, name: string) -> Result[Entry, FatError] {
    slot := cast[u32](0)
    loop {
        found :: next_entry(volume, directory, slot)? or_return .Error(.NotFound)
        if same_name(name_of(&found.entry), name) {
            return .Ok(found.entry)
        }
        slot = found.next
    }
}

/**
 * Resolve a path beneath a directory to its entry.
 *
 * "." and ".." aren't components, so nothing leads above the directory (decisions/0046).
 *
 * @param volume The volume, as mount made it; reads go through its record of failed writes.
 * @param directory The first cluster of the directory the path starts at.
 * @param path The path: components separated by single '/', none empty, no leading or trailing '/'.
 * @return The entry the last component names, a file or a directory.
 * @error InvalidName The path is empty, or has an empty, "." or ".." component.
 * @error NotFound A component isn't in its directory.
 * @error NotADirectory A component before the last is a file.
 * @error DeviceError A directory or the FAT couldn't be read.
 * @error Corrupt A directory doesn't hold together.
 */
resolve :: fn(volume: ptr[mut Volume], directory: u32, path: string) -> Result[Entry, FatError] {
    if path.count == 0 {
        return .Error(.InvalidName)
    }
    current := directory
    start : usize = 0
    for i in 0..<path.count + 1 {
        if i < path.count && path[i] != '/' {
            continue
        }
        component :: string_of(cast[ptr[u8]](cast[u64](path.data) + cast[u64](start)), i - start)
        start = i + 1
        if component.count == 0 || component == "." || component == ".." {
            return .Error(.InvalidName)
        }
        found :: lookup(volume, current, component)?
        if i >= path.count {
            return .Ok(found)
        }
        if found.attributes & DIRECTORY == 0 {
            return .Error(.NotADirectory)
        }
        current = directory_cluster(volume, &found)
    }
    return .Error(.InvalidName)
}

/**
 * Get the first cluster of a directory entry's directory.
 *
 * @param volume The volume, as mount made it; only its layout is used, nothing is read.
 * @param entry An entry with DIRECTORY in its attributes, as lookup or next_entry gives it; that isn't checked, so an
 *     empty file's entry, cluster 0, would give the root's.
 * @return Its first cluster; the root's for an entry whose cluster is 0 ("..", to the root).
 */
directory_cluster :: fn(volume: ptr[mut Volume], entry: ptr[Entry]) -> u32 {
    return if entry.first_cluster == 0 { volume.root_cluster } else { entry.first_cluster }
}

// Reading and writing files

/**
 * Read bytes of a file.
 *
 * Nothing is written: reading changes no time.
 *
 * @param volume The volume, as mount made it; reads go through its record of failed writes.
 * @param entry The file's entry, as got; its size is the one read to, so a size changed since through another Entry
 *     isn't seen (entry_at gets it again).
 * @param offset The byte offset in the file to read from; at or past its size, nothing is read.
 * @param into Where the bytes go; at most its count are read.
 * @return How many bytes were read: fewer than into holds only at the file's end, 0 at or past it.
 * @error IsADirectory The entry is a directory.
 * @error DeviceError The file's sectors or the FAT couldn't be read, or a sector is one a failed write was for.
 * @error Corrupt The file's chain is shorter than its size, or leads outside the volume.
 */
read :: fn(volume: ptr[mut Volume], entry: ptr[Entry], offset: u64, into: mut u8[]) -> Result[u64, FatError] {
    if entry.attributes & DIRECTORY != 0 {
        return .Error(.IsADirectory)
    }
    size :: cast[u64](entry.size)
    if offset >= size || into.count == 0 {
        return .Ok(0)
    }
    wanted :: if size - offset < cast[u64](into.count) { size - offset } else { cast[u64](into.count) }
    done := cast[u64](0)
    cluster := cluster_at(volume, entry.first_cluster, offset / volume.cluster_bytes)? or_return .Error(.Corrupt)
    within := offset % volume.cluster_bytes
    sector : u8[512]
    loop {
        if done >= wanted {
            break
        }
        at :: sector_of(volume, cluster) + within / SECTOR_BYTES
        if !read_sectors(volume, at, 1, sector) {
            return .Error(.DeviceError)
        }
        from :: within % SECTOR_BYTES
        count :: if SECTOR_BYTES - from < wanted - done { SECTOR_BYTES - from } else { wanted - done }
        for i in 0..<count {
            target :: cast[usize](done + i)
            if target < into.count {
                into[target] = get_u8(sector, cast[usize](from + i))
            }
        }
        done += count
        within += count
        if within >= volume.cluster_bytes && done < wanted {
            cluster = next_cluster(volume, cluster)? or_return .Error(.Corrupt)
            within = 0
        }
    }
    return .Ok(done)
}

/**
 * Write bytes into a file, its chain grown to hold them and its size grown to their end.
 *
 * Clusters added are zeroed first, and a gap past the file's old end is zeroed in its old last cluster, so the whole
 * gap reads as zeros. Sectors are written in order, then the directory entry,
 * with the new size and the volume's stamp, if the size grew; a write within the file's size changes no time. A crash
 * partway leaves some sectors written and the size as it was. A sector written only in part is read first, so one a
 * failed write was for can't be written in part.
 *
 * @param volume The volume, as mount made it; reads go through its record of failed writes.
 * @param entry The file's entry; its first cluster, size and written time are updated when they change.
 * @param offset The byte offset in the file to write at; past the file's end, the file grows to it.
 * @param from The bytes; none writes nothing.
 * @return How many bytes were written, all of from's.
 * @error IsADirectory The entry is a directory.
 * @error ReadOnly The device is read-only.
 * @error NoSpace The file would end past 4 GiB - 1, or the volume has no free cluster; clusters taken before it
 *     ran out stay in the file's chain.
 * @error DeviceError The device couldn't be read or written.
 * @error Corrupt The file's chain doesn't hold together, or its entry's slot is past its directory's end.
 */
write :: fn(volume: ptr[mut Volume], entry: ptr[mut Entry], offset: u64, from: u8[]) -> Result[u64, FatError] {
    if entry.attributes & DIRECTORY != 0 {
        return .Error(.IsADirectory)
    }
    if volume.device.read_only {
        return .Error(.ReadOnly)
    }
    end :: offset + cast[u64](from.count)
    if end > 0xffffffff {
        return .Error(.NoSpace)
    }
    if from.count == 0 {
        return .Ok(0)
    }
    grow(volume, entry, end)?
    /*
     * A gap from the old end: the clusters grow added are zeroed, but the old last cluster past the old size may hold
     * old bytes, which would show
     */
    if offset > cast[u64](entry.size) {
        old_end :: cast[u64](entry.size)
        cluster_end :: (old_end + volume.cluster_bytes - 1) / volume.cluster_bytes * volume.cluster_bytes
        zero_range(volume, entry, old_end, if offset < cluster_end { offset } else { cluster_end })?
    }
    done := cast[u64](0)
    cluster := cluster_at(volume, entry.first_cluster, offset / volume.cluster_bytes)? or_return .Error(.Corrupt)
    within := offset % volume.cluster_bytes
    sector : u8[512]
    loop {
        if done >= cast[u64](from.count) {
            break
        }
        at :: sector_of(volume, cluster) + within / SECTOR_BYTES
        start :: within % SECTOR_BYTES
        count :: if SECTOR_BYTES - start < cast[u64](from.count) - done { SECTOR_BYTES - start } else { cast[u64](from.count) - done }
        if start != 0 || count != SECTOR_BYTES {
            if !read_sectors(volume, at, 1, sector) {
                return .Error(.DeviceError)
            }
        }
        for i in 0..<count {
            source :: cast[usize](done + i)
            if source < from.count {
                put_u8(sector, cast[usize](start + i), from[source])
            }
        }
        if !write_sectors(volume, at, 1, sector) {
            return .Error(.DeviceError)
        }
        done += count
        within += count
        if within >= volume.cluster_bytes && done < cast[u64](from.count) {
            cluster = next_cluster(volume, cluster)? or_return .Error(.Corrupt)
            within = 0
        }
    }
    if end > cast[u64](entry.size) {
        entry.size = cast[u32](end)
        update_entry(volume, entry)?
    }
    return .Ok(done)
}

/**
 * Make a file's chain long enough for a size: clusters added, zeroed, after its last, or its first made.
 *
 * The entry's size isn't changed. A file given its first cluster has its directory entry written with it at once.
 *
 * @param volume The volume, as mount made it; reads go through its record of failed writes.
 * @param entry The file's entry, its first_cluster set if it had none.
 * @param size The bytes the chain has to hold; 0 needs nothing.
 * @error ReadOnly The device is read-only.
 * @error NoSpace The volume ran out of free clusters; those added before stay in the chain.
 * @error DeviceError The device couldn't be read or written.
 * @error Corrupt The chain doesn't hold together, or the entry's slot is past its directory's end.
 */
grow :: fn(volume: ptr[mut Volume], entry: ptr[mut Entry], size: u64) -> Result[void, FatError] {
    needed :: (size + volume.cluster_bytes - 1) / volume.cluster_bytes
    if needed == 0 {
        return .Ok
    }
    if entry.first_cluster == 0 {
        entry.first_cluster = allocate_cluster(volume, 0)?
        update_entry(volume, entry)?
    }
    have := cast[u64](1)
    last := entry.first_cluster
    loop {
        step_result :: next_cluster(volume, last)?
        match step_result {
            case Some(next) => {
                last = next
                have += 1
            }
            case None => break
        }
    }
    loop {
        if have >= needed {
            break
        }
        last = allocate_cluster(volume, last)?
        have += 1
    }
    return .Ok
}

/**
 * Set a file's size: shorter, its chain cut after the clusters it still needs, or all of it freed for 0; longer, its
 * chain grown, and every byte past the old size zeroed.
 *
 * The chain changes first, then the directory entry, with the new size and the volume's stamp. A crash between them
 * leaves a shortened chain under the old size (Corrupt when read past it) or a grown chain under the old size (its
 * clusters taken, unused).
 *
 * @param volume The volume, as mount made it; reads go through its record of failed writes.
 * @param entry The file's entry; its first cluster, size and written time are updated.
 * @param size The new size in bytes, at most 4 GiB - 1.
 * @error IsADirectory The entry is a directory.
 * @error ReadOnly The device is read-only.
 * @error NoSpace The size is past 4 GiB - 1, or the volume ran out of free clusters growing it.
 * @error DeviceError The device couldn't be read or written.
 * @error Corrupt The chain is shorter than the clusters to keep, or doesn't hold together.
 */
set_size :: fn(volume: ptr[mut Volume], entry: ptr[mut Entry], size: u64) -> Result[void, FatError] {
    if entry.attributes & DIRECTORY != 0 {
        return .Error(.IsADirectory)
    }
    if volume.device.read_only {
        return .Error(.ReadOnly)
    }
    if size > 0xffffffff {
        return .Error(.NoSpace)
    }
    if size > cast[u64](entry.size) {
        grow(volume, entry, size)?
        // What was past the old size in its last cluster may hold old bytes: zeroed
        zero_range(volume, entry, cast[u64](entry.size), size)?
    }
    else {
        keep :: (size + volume.cluster_bytes - 1) / volume.cluster_bytes
        if keep == 0 && entry.first_cluster != 0 {
            match free_chain(volume, entry.first_cluster) {
                case Some(error) => return .Error(error)
                case None => {}
            }
            entry.first_cluster = 0
        }
        else if keep != 0 {
            last :: cluster_at(volume, entry.first_cluster, keep - 1)? or_return .Error(.Corrupt)
            following :: next_cluster(volume, last)?
            match following {
                case Some(rest) => {
                    match set_fat_entry(volume, last, CHAIN_END_MARK) {
                        case Some(error) => return .Error(error)
                        case None => {}
                    }
                    match free_chain(volume, rest) {
                        case Some(error) => return .Error(error)
                        case None => {}
                    }
                }
                case None => {}
            }
        }
    }
    entry.size = cast[u32](size)
    update_entry(volume, entry)?
    return .Ok
}

/**
 * Write zeros over a range of a file's bytes, a sector at a time.
 *
 * @param volume The volume, as mount made it; reads go through its record of failed writes.
 * @param entry The file's entry, its chain already holding the range.
 * @param start The range's first byte offset in the file.
 * @param end The byte offset just past the range; at or before start, nothing is written.
 * @error DeviceError A sector couldn't be read or written.
 * @error Corrupt The chain is shorter than the range.
 */
zero_range :: fn(volume: ptr[mut Volume], entry: ptr[mut Entry], start: u64, end: u64) -> Result[void, FatError] {
    if end <= start {
        return .Ok
    }
    at := start
    loop {
        if at >= end {
            break
        }
        count :: if end - at < SECTOR_BYTES - at % SECTOR_BYTES { end - at } else { SECTOR_BYTES - at % SECTOR_BYTES }
        cluster :: cluster_at(volume, entry.first_cluster, at / volume.cluster_bytes)? or_return .Error(.Corrupt)
        sector_at :: sector_of(volume, cluster) + (at % volume.cluster_bytes) / SECTOR_BYTES
        sector : u8[512]
        if !read_sectors(volume, sector_at, 1, sector) {
            return .Error(.DeviceError)
        }
        for i in 0..<count {
            put_u8(sector, cast[usize](at % SECTOR_BYTES + i), 0)
        }
        if !write_sectors(volume, sector_at, 1, sector) {
            return .Error(.DeviceError)
        }
        at += count
    }
    return .Ok
}

/**
 * Write an entry's first cluster and size back to its short entry, with the volume's stamp as its write and access
 * times.
 *
 * @param volume The volume, as mount made it; reads go through its record of failed writes.
 * @param entry The entry; its written time is set to the stamp. A directory's size is written as 0.
 * @error ReadOnly The device is read-only.
 * @error DeviceError The slot couldn't be read or written.
 * @error Corrupt The entry's slot is past its directory's end.
 */
update_entry :: fn(volume: ptr[mut Volume], entry: ptr[mut Entry]) -> Result[void, FatError] {
    at :: slot_at(volume, entry.place.directory, entry.place.slot)? or_return .Error(.Corrupt)
    bytes : u8[32]
    match read_slot(volume, at, &bytes) {
        case Some(error) => return .Error(error)
        case None => {}
    }
    put_u16(bytes, 20, cast[u16](entry.first_cluster >> 16))
    put_u16(bytes, 26, cast[u16](entry.first_cluster & 0xffff))
    put_u32(bytes, 28, if entry.attributes & DIRECTORY != 0 { cast[u32](0) } else { entry.size })
    put_u16(bytes, 18, cast[u16](volume.stamp >> 16))
    put_u16(bytes, 22, cast[u16](volume.stamp & 0xffff))
    put_u16(bytes, 24, cast[u16](volume.stamp >> 16))
    entry.written = volume.stamp
    match write_slot(volume, at, &bytes) {
        case Some(error) => return .Error(error)
        case None => return .Ok
    }
}

// Making, removing and renaming

/**
 * Make a new file or directory in a directory.
 *
 * Its long-name entries and its short entry go in a run of free slots, the directory grown by a cluster if it has
 * none; a directory gets a cluster of its own with "." and "..". Its times are the volume's stamp. A file starts
 * empty, with no cluster. The slots are written long-name entries first, so a crash partway leaves long-name entries
 * without their short entry, which listing skips; a directory's cluster is taken before its entries are written, so
 * a crash or failure then loses it.
 *
 * @param volume The volume, as mount made it; reads go through its record of failed writes.
 * @param directory The first cluster of the directory to make it in.
 * @param name The name, UTF-8: not empty, at most MAX_NAME_UNITS UTF-16 units, none of the characters FAT refuses,
 *     not ending in a space or a dot. An 8.3 name in one case is kept as a short entry alone; any other gets long-name
 *     entries and a short alias.
 * @param is_directory True to make a directory, false a file.
 * @return The new entry, its name as given.
 * @error ReadOnly The device is read-only.
 * @error InvalidName FAT can't hold the name.
 * @error AlreadyExists An entry of the name, compared without regard to ASCII case, is in the directory.
 * @error NoSpace The directory is at its most slots, the volume has no free cluster, or no alias tail is free.
 * @error DeviceError The device couldn't be read or written.
 * @error Corrupt The directory doesn't hold together.
 */
create :: fn(volume: ptr[mut Volume], directory: u32, name: string, is_directory: bool) -> Result[Entry, FatError] {
    if volume.device.read_only {
        return .Error(.ReadOnly)
    }
    match lookup(volume, directory, name) {
        case Ok(found) => return .Error(.AlreadyExists)
        case Error(error) => {
            if error != .NotFound {
                return .Error(error)
            }
        }
    }
    return make_entry(volume, directory, name, is_directory)
}

/**
 * Make a new entry in a directory, without looking for one already of its name; create looks first, and rename makes
 * a new name for an entry whose old one differs only in case.
 *
 * @param volume The volume, as mount made it; reads go through its record of failed writes.
 * @param directory The first cluster of the directory to make it in.
 * @param name The name, as create takes one.
 * @param is_directory True for a directory, given a zeroed cluster with "." and ".."; false for an empty file, given
 *     none.
 * @return The entry as made: its place, name and short name, its attributes, and its first cluster.
 * @error InvalidName FAT can't hold the name.
 * @error NoSpace The directory has no free slots and can't grow, no alias tail is free, or no cluster is free.
 * @error DeviceError The device couldn't be read or written.
 * @error Corrupt The directory's chain doesn't hold together.
 */
make_entry :: fn(volume: ptr[mut Volume], directory: u32, name: string, is_directory: bool) -> Result[Entry, FatError] {
    units : u16[MAX_NAME_UNITS]
    unit_count :: units_of_name(name, &units) or_return .Error(.InvalidName)
    entry := Entry.{attributes = if is_directory { DIRECTORY } else { ARCHIVE }, written = volume.stamp}
    needs_long :: !short_name_exactly(name, &entry.short_name)
    if needs_long {
        make_alias(volume, directory, name, &entry.short_name)?
    }
    long_count :: if needs_long { cast[u32]((unit_count + 12) / 13) } else { cast[u32](0) }
    first_slot :: free_slots(volume, directory, long_count + 1)?
    if is_directory {
        entry.first_cluster = allocate_cluster(volume, 0)?
    }
    // The long-name entries, last first, then the short one
    checksum :: short_checksum(&entry.short_name)
    for k in 0..<long_count {
        order :: long_count - k
        bytes : u8[32]
        bytes[0] = cast[u8](order) | (if k == 0 { LAST_LONG_ENTRY } else { cast[u8](0) })
        bytes[11] = LONG_NAME
        bytes[13] = checksum
        positions :: usize.[1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30]
        for position, j in positions {
            index :: (cast[usize](order) - 1) * 13 + j
            unit : u16 = if index < unit_count { units[index % units.count] } else if index == unit_count { cast[u16](0) } else { cast[u16](0xffff) }
            put_u16(bytes, position, unit)
        }
        at :: slot_at(volume, directory, first_slot + k)? or_return .Error(.Corrupt)
        match write_slot(volume, at, &bytes) {
            case Some(error) => return .Error(error)
            case None => {}
        }
    }
    entry.place = Place.{directory = directory, slot = first_slot + long_count, long_entries = long_count}
    short :: short_entry_of(&entry, if needs_long { cast[u8](0) } else { case_flags_of(name) })
    at :: slot_at(volume, directory, entry.place.slot)? or_return .Error(.Corrupt)
    match write_slot(volume, at, &short) {
        case Some(error) => return .Error(error)
        case None => {}
    }
    if is_directory {
        make_dots(volume, entry.first_cluster, directory)?
    }
    entry.name_length = copy_name(name, &entry.name)
    return .Ok(entry)
}

/**
 * Write a new directory's "." and ".." into its first two slots.
 *
 * @param volume The volume, as mount made it; reads go through its record of failed writes.
 * @param cluster The new directory's first cluster, zeroed.
 * @param parent The first cluster of the directory it's in; ".." names cluster 0 when that's the root, as FAT has it.
 * @error ReadOnly The device is read-only.
 * @error DeviceError A slot couldn't be read or written.
 * @error Corrupt The cluster isn't one of the volume's.
 */
make_dots :: fn(volume: ptr[mut Volume], cluster: u32, parent: u32) -> Result[void, FatError] {
    for which in 0..<cast[u32](2) {
        dots := Entry.{attributes = DIRECTORY, written = volume.stamp, first_cluster = if which == 0 { cluster } else if parent == volume.root_cluster { cast[u32](0) } else { parent }}
        for i in 0..<cast[usize](11) {
            dots.short_name[i] = if i == 0 || (i == 1 && which == 1) { cast[u8]('.') } else { cast[u8](' ') }
        }
        bytes :: short_entry_of(&dots, 0)
        at :: slot_at(volume, cluster, which)? or_return .Error(.Corrupt)
        match write_slot(volume, at, &bytes) {
            case Some(error) => return .Error(error)
            case None => {}
        }
    }
    return .Ok
}

/**
 * Make an entry's short entry, as its 32 bytes on the volume.
 *
 * @param entry The entry: its short name, attributes, first cluster, size (written as 0 for a directory), and its
 *     written stamp, which becomes its creation, write and access times; a stamp of 0 is taken as EPOCH_STAMP.
 * @param case_flags LOWER_BASE and LOWER_EXTENSION for an 8.3 name kept in lower case; 0 otherwise.
 * @return The short entry's bytes.
 */
short_entry_of :: fn(entry: ptr[Entry], case_flags: u8) -> u8[32] {
    bytes : u8[32]
    for byte, i in entry.short_name {
        bytes[i] = byte
    }
    bytes[11] = entry.attributes
    bytes[12] = case_flags
    // Made, written to and read now: entry.written, the epoch for an entry that has none
    stamp :: if entry.written == 0 { EPOCH_STAMP } else { entry.written }
    put_u16(bytes, 14, cast[u16](stamp & 0xffff))
    put_u16(bytes, 16, cast[u16](stamp >> 16))
    put_u16(bytes, 18, cast[u16](stamp >> 16))
    put_u16(bytes, 20, cast[u16](entry.first_cluster >> 16))
    put_u16(bytes, 22, cast[u16](stamp & 0xffff))
    put_u16(bytes, 24, cast[u16](stamp >> 16))
    put_u16(bytes, 26, cast[u16](entry.first_cluster & 0xffff))
    put_u32(bytes, 28, if entry.attributes & DIRECTORY != 0 { cast[u32](0) } else { entry.size })
    return bytes
}

/**
 * Find a run of free slots in a directory, growing it by zeroed clusters until it has one.
 *
 * Slots are free when their first byte is DELETED or END. The clusters added stay in the directory, even when the
 * caller then fails.
 *
 * @param volume The volume, as mount made it; reads go through its record of failed writes.
 * @param directory The directory's first cluster.
 * @param count How many slots in a row, 1 to MAX_LONG_ENTRIES + 1.
 * @return The run's first slot.
 * @error NoSpace The directory would need slots past MAX_DIRECTORY_SLOTS, or the volume has no free cluster.
 * @error ReadOnly The device is read-only, and the directory has to grow.
 * @error DeviceError The device couldn't be read or written.
 * @error Corrupt The directory's chain doesn't hold together.
 */
free_slots :: fn(volume: ptr[mut Volume], directory: u32, count: u32) -> Result[u32, FatError] {
    run_start := cast[u32](0)
    run := cast[u32](0)
    slot := cast[u32](0)
    for step in 0..<MAX_DIRECTORY_SLOTS {
        at := slot_at(volume, directory, slot)?
        if at is_none {
            if slot >= MAX_DIRECTORY_SLOTS {
                return .Error(.NoSpace)
            }
            // Past the chain: a new cluster at its end, whose slots are all free
            last :: last_cluster(volume, directory)?
            _ = allocate_cluster(volume, last)?
            at = slot_at(volume, directory, slot)?
        }
        place :: at or_return .Error(.Corrupt)
        bytes : u8[32]
        match read_slot(volume, place, &bytes) {
            case Some(error) => return .Error(error)
            case None => {}
        }
        if bytes[0] == END || bytes[0] == DELETED {
            if run == 0 {
                run_start = slot
            }
            run += 1
            if run >= count {
                return .Ok(run_start)
            }
        }
        else {
            run = 0
        }
        slot += 1
    }
    return .Error(.NoSpace)
}

/**
 * Find the last cluster of a chain.
 *
 * @param volume The volume, as mount made it; reads go through its record of failed writes.
 * @param first The chain's first cluster, one of the volume's.
 * @return The cluster that ends the chain.
 * @error DeviceError The FAT couldn't be read.
 * @error Corrupt A link leads outside the volume, or the chain is longer than the volume (a loop).
 */
last_cluster :: fn(volume: ptr[mut Volume], first: u32) -> Result[u32, FatError] {
    cluster := first
    for step in 0..<volume.cluster_count {
        step_result :: next_cluster(volume, cluster)?
        match step_result {
            case Some(next) => cluster = next
            case None => return .Ok(cluster)
        }
    }
    return .Error(.Corrupt)
}

/**
 * Mark an entry's slots free: its long-name entries, then its short one, each set to DELETED.
 *
 * Its clusters are left as they are.
 *
 * @param volume The volume, as mount made it; reads go through its record of failed writes.
 * @param entry The entry, its place as it is now.
 * @error ReadOnly The device is read-only.
 * @error DeviceError A slot couldn't be read or written; the slots before it are free.
 * @error Corrupt A slot is past its directory's end.
 */
free_entry_slots :: fn(volume: ptr[mut Volume], entry: ptr[Entry]) -> Result[void, FatError] {
    first :: entry.place.slot - entry.place.long_entries
    for slot in first..<entry.place.slot + 1 {
        at :: slot_at(volume, entry.place.directory, slot)? or_return .Error(.Corrupt)
        bytes : u8[32]
        match read_slot(volume, at, &bytes) {
            case Some(error) => return .Error(error)
            case None => {}
        }
        bytes[0] = DELETED
        match write_slot(volume, at, &bytes) {
            case Some(error) => return .Error(error)
            case None => {}
        }
    }
    return .Ok
}

/**
 * Remove an entry, its clusters freed.
 *
 * Its slots are freed first, then its chain, so a crash between them loses the clusters (taken, but in no chain)
 * rather than leaving an entry pointing at free ones.
 *
 * @param volume The volume, as mount made it; reads go through its record of failed writes.
 * @param entry The entry, its place as it is now; it isn't changed, but no longer names anything.
 * @error ReadOnly The device is read-only.
 * @error DirectoryNotEmpty The entry is a directory with entries in it besides "." and "..".
 * @error DeviceError The device couldn't be read or written.
 * @error Corrupt The entry's directory or its chain doesn't hold together.
 */
remove :: fn(volume: ptr[mut Volume], entry: ptr[Entry]) -> Result[void, FatError] {
    if volume.device.read_only {
        return .Error(.ReadOnly)
    }
    if entry.attributes & DIRECTORY != 0 {
        if next_entry(volume, directory_cluster(volume, entry), 0)? is_some {
            return .Error(.DirectoryNotEmpty)
        }
    }
    free_entry_slots(volume, entry)?
    if entry.first_cluster != 0 {
        match free_chain(volume, entry.first_cluster) {
            case Some(error) => return .Error(error)
            case None => {}
        }
    }
    return .Ok
}

/**
 * Move an entry to a name in a directory, which may be its own.
 *
 * An entry already of that name there, if it's a file and so is the one moved, is replaced: its short entry is
 * rewritten in one slot write to name the moved one's clusters, which is how a file's contents are replaced as
 * atomically as FAT can, then the moved one's old slots are freed, then the replaced clusters. Otherwise a new entry
 * for its clusters is made there (a name differing from the entry's own only in case among them), then its old slots
 * are freed, then a moved directory's ".." is pointed at its new parent. It's best effort, but never loses both: a
 * crash before the new name is written leaves the old name and the target as they were; one after it and before the
 * old slots are freed leaves both names on one chain; one before the replaced clusters are freed loses only those
 * clusters, taken but in no chain.
 *
 * @param volume The volume, as mount made it; reads go through its record of failed writes.
 * @param entry The entry to move, its place as it is now; it no longer names anything once this succeeds.
 * @param directory The first cluster of the directory to move it to.
 * @param name The new name, as create takes one.
 * @return The entry as moved, its new place and name, its attributes, clusters and size the old one's.
 * @error ReadOnly The device is read-only.
 * @error InvalidName FAT can't hold the name, or a directory would go beneath itself.
 * @error AlreadyExists An entry of the name is there, not the entry itself, and it or the one moved is a directory.
 * @error NoSpace The directory has no free slots and can't grow, or no alias tail is free.
 * @error DeviceError The device couldn't be read or written.
 * @error Corrupt A directory or chain doesn't hold together, or ".." of the parents doesn't lead to the root.
 */
rename :: fn(volume: ptr[mut Volume], entry: ptr[Entry], directory: u32, name: string) -> Result[Entry, FatError] {
    if volume.device.read_only {
        return .Error(.ReadOnly)
    }
    // A directory can't go beneath itself
    if entry.attributes & DIRECTORY != 0 && is_beneath(volume, directory, entry.first_cluster)? {
        return .Error(.InvalidName)
    }
    old := entry^
    // A file it replaces, whose clusters are freed once nothing names them
    replaced : Entry? = null
    match lookup(volume, directory, name) {
        case Ok(existing) => {
            if existing.place.directory == entry.place.directory && existing.place.slot == entry.place.slot {
                // The same entry, by another case: a new entry of the new name, made below
            }
            else if existing.attributes & DIRECTORY != 0 || entry.attributes & DIRECTORY != 0 {
                return .Error(.AlreadyExists)
            }
            else {
                replaced = existing
            }
        }
        case Error(error) => {
            if error != .NotFound {
                return .Error(error)
            }
        }
    }
    /*
     * The entry that will name it: the replaced one's own slots, or a new entry made as a file so no cluster is
     * allocated. Either way it's then given the old one's clusters in a single slot write
     */
    moved := match replaced {
        case Some(target) => target
        case None => make_entry(volume, directory, name, false)?
    }
    moved.attributes = old.attributes
    moved.first_cluster = old.first_cluster
    moved.size = old.size
    rewritten :: short_entry_of(&moved, 0)
    at :: slot_at(volume, directory, moved.place.slot)? or_return .Error(.Corrupt)
    // The case flags, if create set them, stay
    current : u8[32]
    match read_slot(volume, at, &current) {
        case Some(error) => return .Error(error)
        case None => {}
    }
    final := rewritten
    final[12] = current[12]
    match write_slot(volume, at, &final) {
        case Some(error) => return .Error(error)
        case None => {}
    }
    free_entry_slots(volume, &old)?
    match replaced {
        case Some(target) => {
            if target.first_cluster != 0 {
                match free_chain(volume, target.first_cluster) {
                    case Some(error) => return .Error(error)
                    case None => {}
                }
            }
        }
        case None => {}
    }
    if old.attributes & DIRECTORY != 0 && old.first_cluster != 0 && old.place.directory != directory {
        // Its ".." is its second slot
        dots := Entry.{attributes = DIRECTORY, written = volume.stamp, first_cluster = if directory == volume.root_cluster { cast[u32](0) } else { directory }}
        for i in 0..<cast[usize](11) {
            dots.short_name[i] = if i < 2 { cast[u8]('.') } else { cast[u8](' ') }
        }
        bytes :: short_entry_of(&dots, 0)
        dot_dot :: slot_at(volume, old.first_cluster, 1)? or_return .Error(.Corrupt)
        match write_slot(volume, dot_dot, &bytes) {
            case Some(error) => return .Error(error)
            case None => {}
        }
    }
    return .Ok(moved)
}

/**
 * Tell whether a directory is another, or beneath it, by following "..".
 *
 * @param volume The volume, as mount made it; reads go through its record of failed writes.
 * @param directory The first cluster of the directory to start at.
 * @param ancestor The first cluster of the directory looked for.
 * @return True if directory is ancestor or beneath it; false once the root, or a number that isn't a cluster, is
 *     reached without it.
 * @error DeviceError A directory or the FAT couldn't be read.
 * @error Corrupt The ".." links go 4096 deep without reaching the root, as a loop does, or a chain leads outside the
 *     volume.
 */
is_beneath :: fn(volume: ptr[mut Volume], directory: u32, ancestor: u32) -> Result[bool, FatError] {
    current := directory
    for step in 0..<cast[u32](4096) {
        if current == ancestor {
            return .Ok(true)
        }
        if current == volume.root_cluster || !is_cluster(volume, current) {
            return .Ok(false)
        }
        at :: slot_at(volume, current, 1)? or_return .Ok(false)
        bytes : u8[32]
        match read_slot(volume, at, &bytes) {
            case Some(error) => return .Error(error)
            case None => {}
        }
        parent :: cast[u32](get_u16(bytes, 20)) << 16 | cast[u32](get_u16(bytes, 26))
        current = if parent == 0 { volume.root_cluster } else { parent }
    }
    return .Error(.Corrupt)
}

// Names

/**
 * Get an entry's name as text.
 *
 * @param entry The entry, as next_entry, lookup, entry_at or create gave it.
 * @return Its name, UTF-8: a view into the entry's name, good as long as the entry is.
 */
name_of :: fn(entry: ptr[Entry]) -> string {
    return string_of(&entry.name[0], cast[usize](if entry.name_length > NAME_BYTES { cast[u32](NAME_BYTES) } else { entry.name_length }))
}

/**
 * Tell whether two names are the same to FAT: byte for byte but for ASCII letters' case.
 *
 * @param a One name, UTF-8.
 * @param b The other, UTF-8.
 * @return True if they're the same length and differ only in ASCII letters' case; other letters' case counts.
 */
same_name :: fn(a: string, b: string) -> bool {
    if a.count != b.count {
        return false
    }
    for character, i in a {
        if i >= b.count || upper(cast[u8](character)) != upper(cast[u8](b[i])) {
            return false
        }
    }
    return true
}

/**
 * Upper-case an ASCII letter.
 *
 * @param byte A byte.
 * @return The upper-case letter for 'a' to 'z'; any other byte as it is.
 */
upper :: fn(byte: u8) -> u8 {
    return if byte >= cast[u8]('a') && byte <= cast[u8]('z') { byte - 32 } else { byte }
}

/**
 * Lower-case an ASCII letter.
 *
 * @param byte A byte.
 * @return The lower-case letter for 'A' to 'Z'; any other byte as it is.
 */
lower :: fn(byte: u8) -> u8 {
    return if byte >= cast[u8]('A') && byte <= cast[u8]('Z') { byte + 32 } else { byte }
}

/**
 * Make a short name into text: its base and extension, trimmed, lower-cased where its case flags say, a dot between.
 *
 * A first byte of 0x05 stands for 0xe5, as FAT has it.
 *
 * @param short The short name as on the volume.
 * @param case_flags The short entry's case flags.
 * @param into Where the text goes, from its start.
 * @return The text's length in bytes, at most 12; 0 for a name of spaces.
 */
name_of_short :: fn(short: ptr[u8[11]], case_flags: u8, into: ptr[mut u8[NAME_BYTES]]) -> u32 {
    length : usize = 0
    for i in 0..<cast[usize](8) {
        byte := short^[i]
        if byte == cast[u8](' ') {
            break
        }
        // 0x05 stands for a first byte of 0xe5
        if i == 0 && byte == 0x05 {
            byte = 0xe5
        }
        length = put_name_byte(into, length, if case_flags & LOWER_BASE != 0 { lower(byte) } else { byte })
    }
    if short^[8] != cast[u8](' ') {
        length = put_name_byte(into, length, cast[u8]('.'))
        for i in 8..<cast[usize](11) {
            byte :: short^[i]
            if byte == cast[u8](' ') {
                break
            }
            length = put_name_byte(into, length, if case_flags & LOWER_EXTENSION != 0 { lower(byte) } else { byte })
        }
    }
    return cast[u32](length)
}

/**
 * Put a byte into a name buffer, if it fits.
 *
 * @param into Where the byte goes, a name buffer of NAME_BYTES.
 * @param at The byte offset to put it at.
 * @param byte The byte, any value; it isn't checked as UTF-8.
 * @return Where the next byte goes: at + 1, or at if it didn't fit.
 */
put_name_byte :: fn(into: ptr[mut u8[NAME_BYTES]], at: usize, byte: u8) -> usize {
    if at < into^.count {
        into^[at] = byte
        return at + 1
    }
    return at
}

/**
 * Compute the checksum of a short name that its long-name entries carry, as the specification defines it.
 *
 * @param short The short name as on the volume.
 * @return The checksum: each byte added to the sum rotated right by one bit, over all 11 bytes.
 */
short_checksum :: fn(short: ptr[u8[11]]) -> u8 {
    sum := cast[u8](0)
    for byte in short^ {
        sum = ((sum & 1) << 7) + (sum >> 1) + byte
    }
    return sum
}

/**
 * Convert a name to UTF-16 code units, if FAT can hold it.
 *
 * FAT can hold a name that isn't empty, takes at most MAX_NAME_UNITS units, has no control characters and none of
 * the characters FAT refuses (double quote, asterisk, slash, colon, angle brackets, question mark, backslash, bar),
 * and doesn't end in a space or a dot. UTF-8 is decoded leniently: continuation bytes aren't checked, and a sequence
 * cut short at the name's end is taken as a shorter one.
 *
 * @param name The name, UTF-8.
 * @param units Where the units go, from the start.
 * @return How many units, 1 to MAX_NAME_UNITS; null if FAT can't hold the name, or a byte isn't UTF-8's.
 */
units_of_name :: fn(name: string, units: ptr[mut u16[MAX_NAME_UNITS]]) -> usize? {
    if name.count == 0 {
        return null
    }
    last :: name[name.count - 1]
    if last == ' ' || last == '.' {
        return null
    }
    count : usize = 0
    i : usize = 0
    loop {
        if i >= name.count {
            break
        }
        byte :: cast[u32](cast[u8](name[i]))
        code := byte
        width : usize = 1
        if byte >= 0xf0 && i + 3 < name.count {
            code = ((byte & 7) << 18) | ((cast[u32](cast[u8](name[i + 1])) & 0x3f) << 12) | ((cast[u32](cast[u8](name[i + 2])) & 0x3f) << 6)
                | (cast[u32](cast[u8](name[i + 3])) & 0x3f)
            width = 4
        }
        else if byte >= 0xe0 && i + 2 < name.count {
            code = ((byte & 0xf) << 12) | ((cast[u32](cast[u8](name[i + 1])) & 0x3f) << 6) | (cast[u32](cast[u8](name[i + 2])) & 0x3f)
            width = 3
        }
        else if byte >= 0xc0 && i + 1 < name.count {
            code = ((byte & 0x1f) << 6) | (cast[u32](cast[u8](name[i + 1])) & 0x3f)
            width = 2
        }
        else if byte >= 0x80 {
            return null
        }
        if code < 0x20 || code == 0x22 || code == 0x2a || code == 0x2f || code == 0x3a || code == 0x3c || code == 0x3e || code == 0x3f
            || code == cast[u32]('\\') || code == cast[u32]('|') {
            return null
        }
        if code >= 0x10000 {
            if count + 2 > MAX_NAME_UNITS {
                return null
            }
            reduced :: code - 0x10000
            high :: count
            low :: count + 1
            if high < units^.count && low < units^.count {
                units^[high] = cast[u16](0xd800 + (reduced >> 10))
                units^[low] = cast[u16](0xdc00 + (reduced & 0x3ff))
            }
            count += 2
        }
        else {
            if count >= units^.count {
                return null
            }
            units^[count] = cast[u16](code)
            count += 1
        }
        i += width
    }
    return count
}

/**
 * Convert UTF-16 code units, up to the first zero, to UTF-8.
 *
 * @param units The units, as long-name entries hold them.
 * @param into Where the UTF-8 goes, from its start; a code point that wouldn't fit is left out.
 * @return The UTF-8 length in bytes, 0 to NAME_BYTES. An unpaired surrogate becomes '?'.
 */
utf8_of_units :: fn(units: u16[], into: ptr[mut u8[NAME_BYTES]]) -> u32 {
    length : usize = 0
    i : usize = 0
    loop {
        if i >= units.count || units[i] == 0 {
            break
        }
        unit :: cast[u32](units[i])
        i += 1
        code := unit
        if unit >= 0xd800 && unit < 0xdc00 && i < units.count && cast[u32](units[i]) >= 0xdc00 && cast[u32](units[i]) < 0xe000 {
            code = 0x10000 + ((unit - 0xd800) << 10) + (cast[u32](units[i]) - 0xdc00)
            i += 1
        }
        else if unit >= 0xd800 && unit < 0xe000 {
            code = cast[u32]('?')
        }
        length = put_utf8(into, length, code)
    }
    return cast[u32](length)
}

/**
 * Put a code point as UTF-8 into a name buffer, if all its bytes fit.
 *
 * @param into Where the UTF-8 goes, a name buffer of NAME_BYTES.
 * @param at The byte offset to put it at, 0 to NAME_BYTES.
 * @param code The code point, at most 0x10ffff.
 * @return Where the next code point goes: at plus its 1 to 4 bytes, or at if they didn't fit, so nothing was written.
 */
put_utf8 :: fn(into: ptr[mut u8[NAME_BYTES]], at: usize, code: u32) -> usize {
    bytes : u8[4]
    count : usize = 0
    if code < 0x80 {
        bytes[0] = cast[u8](code)
        count = 1
    }
    else if code < 0x800 {
        bytes[0] = cast[u8](0xc0 | (code >> 6))
        bytes[1] = cast[u8](0x80 | (code & 0x3f))
        count = 2
    }
    else if code < 0x10000 {
        bytes[0] = cast[u8](0xe0 | (code >> 12))
        bytes[1] = cast[u8](0x80 | ((code >> 6) & 0x3f))
        bytes[2] = cast[u8](0x80 | (code & 0x3f))
        count = 3
    }
    else {
        bytes[0] = cast[u8](0xf0 | (code >> 18))
        bytes[1] = cast[u8](0x80 | ((code >> 12) & 0x3f))
        bytes[2] = cast[u8](0x80 | ((code >> 6) & 0x3f))
        bytes[3] = cast[u8](0x80 | (code & 0x3f))
        count = 4
    }
    if at + count > NAME_BYTES {
        return at
    }
    for byte, j in bytes {
        k :: at + j
        if j < count && k < into^.count {
            into^[k] = byte
        }
    }
    return at + count
}

/**
 * Copy a name into a name buffer, as much as fits.
 *
 * @param name The name, UTF-8.
 * @param into Where it goes, from the start.
 * @return How many bytes were copied: the name's length, or NAME_BYTES if it's longer, cut there.
 */
copy_name :: fn(name: string, into: ptr[mut u8[NAME_BYTES]]) -> u32 {
    count : usize = 0
    for character, i in name {
        if i < into^.count {
            into^[i] = cast[u8](character)
            count = i + 1
        }
    }
    return cast[u32](count)
}

/**
 * Tell whether a name is an 8.3 name as it is, so it needs no long name, and make its short name.
 *
 * It is when its base is 1 to 8 short characters (is_short_character), with at most one dot and then 1 to 3 more,
 * and neither part mixes upper and lower case; a part all in lower case is kept by the case flags (case_flags_of).
 *
 * @param name The name, UTF-8.
 * @param short Where the short name goes, upper-case and space-padded; filled in part when it isn't one.
 * @return True if it's an 8.3 name; false if it needs a long name and an alias.
 */
short_name_exactly :: fn(name: string, short: ptr[mut u8[11]]) -> bool {
    for &byte in short^ {
        byte^ = cast[u8](' ')
    }
    base := cast[usize](0)
    extension := cast[usize](0)
    in_extension := false
    lower_base := false
    upper_base := false
    lower_extension := false
    upper_extension := false
    for character, i in name {
        byte :: cast[u8](character)
        if byte == cast[u8]('.') {
            if in_extension || i == 0 {
                return false
            }
            in_extension = true
            continue
        }
        if !is_short_character(byte) {
            return false
        }
        is_lower :: byte >= cast[u8]('a') && byte <= cast[u8]('z')
        is_upper :: byte >= cast[u8]('A') && byte <= cast[u8]('Z')
        if in_extension {
            if extension >= 3 {
                return false
            }
            short^[8 + extension] = upper(byte)
            extension += 1
            lower_extension = lower_extension || is_lower
            upper_extension = upper_extension || is_upper
        }
        else {
            if base >= 8 {
                return false
            }
            short^[base] = upper(byte)
            base += 1
            lower_base = lower_base || is_lower
            upper_base = upper_base || is_upper
        }
    }
    if base == 0 || (in_extension && extension == 0) {
        return false
    }
    // Mixed case in either part needs a long name; all lower is kept by the case flags
    return !(lower_base && upper_base) && !(lower_extension && upper_extension)
}

/**
 * Get the case flags an 8.3 name with no long name keeps its lower case in.
 *
 * @param name The name, one short_name_exactly took.
 * @return LOWER_BASE if its base has a lower-case letter, LOWER_EXTENSION if its extension does, or both, or 0.
 */
case_flags_of :: fn(name: string) -> u8 {
    flags := cast[u8](0)
    in_extension := false
    for character in name {
        byte :: cast[u8](character)
        if byte == cast[u8]('.') {
            in_extension = true
        }
        else if byte >= cast[u8]('a') && byte <= cast[u8]('z') {
            flags |= if in_extension { LOWER_EXTENSION } else { LOWER_BASE }
        }
    }
    return flags
}

/**
 * Tell whether a byte may be in a short name: an ASCII letter, which it holds in upper case, a digit, or one of
 * $%'-_@~`!(){}^#&.
 *
 * @param byte A byte of a name's UTF-8, any value.
 * @return True if it may; false for anything else, every non-ASCII byte included.
 */
is_short_character :: fn(byte: u8) -> bool {
    if (byte >= cast[u8]('A') && byte <= cast[u8]('Z')) || (byte >= cast[u8]('a') && byte <= cast[u8]('z')) || (byte >= cast[u8]('0') && byte <= cast[u8]('9')) || byte >= 0x80 {
        return byte < 0x80
    }
    for allowed in "$%'-_@~`!(){}^#&" {
        if byte == cast[u8](allowed) {
            return true
        }
    }
    return false
}

/**
 * Make a short alias for a long name, as Windows makes one.
 *
 * The name's characters are upper-cased, those a short name can't hold made '_', spaces and dots dropped; the part
 * after its last dot is the extension, cut to 3, and the rest the base, cut so "~N" fits after it within 8, N the
 * least from 1 that no alias of the same base and extension in the directory has (found in one pass over it).
 *
 * @param volume The volume, as mount made it; reads go through its record of failed writes.
 * @param directory The first cluster of the directory the alias goes in.
 * @param name The long name, UTF-8.
 * @param short Where the alias goes, space-padded.
 * @error NoSpace Every tail from 1 to MAX_TAILS is taken.
 * @error DeviceError The directory or the FAT couldn't be read.
 * @error Corrupt The directory doesn't hold together.
 */
make_alias :: fn(volume: ptr[mut Volume], directory: u32, name: string, short: ptr[mut u8[11]]) -> Result[void, FatError] {
    for &byte in short^ {
        byte^ = cast[u8](' ')
    }
    last_dot := name.count
    for character, i in name {
        if character == '.' && i > 0 {
            last_dot = i
        }
    }
    base : u8[8]
    base_count : usize = 0
    for character, i in name {
        if i >= last_dot {
            break
        }
        byte :: cast[u8](character)
        if byte == cast[u8](' ') || byte == cast[u8]('.') {
            continue
        }
        if base_count < base.count {
            base[base_count] = if is_short_character(byte) { upper(byte) } else { cast[u8]('_') }
            base_count += 1
        }
    }
    if base_count == 0 {
        base[0] = cast[u8]('_')
        base_count = 1
    }
    extension_count : usize = 0
    for character, i in name {
        if i <= last_dot || last_dot == name.count {
            continue
        }
        byte :: cast[u8](character)
        if byte == cast[u8](' ') {
            continue
        }
        if extension_count < 3 {
            short^[8 + extension_count] = if is_short_character(byte) { upper(byte) } else { cast[u8]('_') }
            extension_count += 1
        }
    }
    // The tails this base's aliases already have in the directory, found in one pass, and the first free one taken
    taken : u64[MAX_TAILS / 64 + 1]
    slot := cast[u32](0)
    loop {
        found :: next_entry(volume, directory, slot)? or_break
        tail :: tail_of(&found.entry.short_name, short, &base, base_count)
        word :: cast[usize](tail / 64)
        if tail > 0 && tail <= MAX_TAILS && word < taken.count {
            taken[word] = taken[word] | cast[u64](1) << cast[u64](tail % 64)
        }
        slot = found.next
    }
    for tail in 1..=MAX_TAILS {
        word :: cast[usize](tail / 64)
        if word < taken.count && taken[word] & (cast[u64](1) << cast[u64](tail % 64)) != 0 {
            continue
        }
        put_alias(short, &base, base_count, tail)
        return .Ok
    }
    return .Error(.NoSpace)
}

/** The most alias tails tried: one more than a directory has slots, so one is always free. */
MAX_TAILS : u32 : 65537

/**
 * Make a short name a base's alias with a tail: as much of the base as fits before "~" and the tail's digits.
 *
 * @param short The short name, its extension already set and kept.
 * @param base The alias's base, upper-case.
 * @param base_count How many bytes of base are used, 1 to 8.
 * @param tail The tail, 1 to MAX_TAILS.
 */
put_alias :: fn(short: ptr[mut u8[11]], base: ptr[u8[8]], base_count: usize, tail: u32) {
    digits : u8[7]
    digit_count : usize = 0
    value := tail
    loop #at_least_once {
        if digit_count < digits.count {
            digits[digit_count] = cast[u8]('0') + cast[u8](value % 10)
            digit_count += 1
        }
        value /= 10
    }
    while value != 0
    keep :: alias_keep(base_count, digit_count)
    for i in 0..<cast[usize](8) {
        short^[i] = cast[u8](' ')
    }
    for i in 0..<keep {
        if i < base^.count {
            short^[i] = base^[i]
        }
    }
    short^[keep % 8] = cast[u8]('~')
    for d in 0..<digit_count {
        at :: keep + 1 + d
        from :: digit_count - 1 - d
        if at < 8 && from < digits.count {
            short^[at] = digits[from]
        }
    }
}

/**
 * Work out how much of a base an alias keeps, so "~" and the tail's digits fit after it within 8 bytes.
 *
 * @param base_count How many bytes the base has, 1 to 8.
 * @param digit_count How many digits the tail has, 1 to 6.
 * @return The bytes of the base kept: all of them, or 7 - digit_count.
 */
alias_keep :: fn(base_count: usize, digit_count: usize) -> usize {
    return if base_count + digit_count + 1 > 8 { 8 - digit_count - 1 } else { base_count }
}

/**
 * Get the tail of a short name, if it's an alias of a base with an extension.
 *
 * It is when it has the extension, and as much of the base as fits, "~", 1 to 6 digits and spaces.
 *
 * @param name The short name, as in the directory.
 * @param extension A short name whose extension (its last 3 bytes) is the alias's.
 * @param base The alias's base, upper-case.
 * @param base_count How many bytes of base are used.
 * @return The tail, the number after "~"; 0 if the name isn't such an alias.
 */
tail_of :: fn(name: ptr[u8[11]], extension: ptr[u8[11]], base: ptr[u8[8]], base_count: usize) -> u32 {
    for i in 8..<cast[usize](11) {
        if name^[i] != extension^[i] {
            return 0
        }
    }
    tilde : usize = 8
    for i in 1..<cast[usize](8) {
        if name^[i] == cast[u8]('~') {
            tilde = i
            break
        }
    }
    if tilde >= 7 {
        return 0
    }
    value : u32 = 0
    digit_count : usize = 0
    for i in tilde + 1..<cast[usize](8) {
        byte :: name^[i]
        if byte == cast[u8](' ') {
            break
        }
        if byte < cast[u8]('0') || byte > cast[u8]('9') || digit_count >= 6 {
            return 0
        }
        value = value * 10 + cast[u32](byte - cast[u8]('0'))
        digit_count += 1
    }
    if digit_count == 0 || tilde != alias_keep(base_count, digit_count) {
        return 0
    }
    for i in 0..<tilde {
        if i >= base^.count || name^[i] != base^[i] {
            return 0
        }
    }
    return value
}

// Formatting

/**
 * Format a new, empty FAT32 volume onto a device.
 *
 * It has 32 reserved sectors, with the boot sector at 0 and its copy at 6 and FSInfo after each, two FATs, and the
 * root directory, one zeroed cluster, at cluster 2. Everything from the volume's start to the root's cluster's end is
 * zeroed first; the rest of the device is left as it was. It writes straight to the device, not looking at its
 * read_only, and a failure partway leaves a volume that may not mount.
 *
 * @param device The device; its first sectors are written whatever its read_only says.
 * @param sector_count The volume's size in sectors, at most the device's and at most 0xffffffff.
 * @param sectors_per_cluster The sectors in a cluster: a power of two from 1 to 128.
 * @param label The volume's label, its first 11 bytes upper-cased, space-padded.
 * @return Null if the volume was written; InvalidName if sectors_per_cluster isn't a power of two up to 128 or
 *     sector_count is more than the device has; NoSpace if the volume would have fewer than MIN_CLUSTERS clusters to
 *     be FAT32; DeviceError if the device couldn't be written.
 */
format :: fn(device: Device, sector_count: u64, sectors_per_cluster: u64, label: string) -> FatError? {
    if sectors_per_cluster == 0 || sectors_per_cluster & (sectors_per_cluster - 1) != 0 || sectors_per_cluster > 128 || sector_count > device.sector_count {
        return FatError.InvalidName
    }
    reserved :: cast[u64](32)
    // Each FAT's sectors: enough for an entry for every cluster the rest can hold
    data_guess :: sector_count - reserved
    clusters_guess :: data_guess / sectors_per_cluster
    fat_sectors :: ((clusters_guess + 2) * 4 + SECTOR_BYTES - 1) / SECTOR_BYTES
    first_data :: reserved + 2 * fat_sectors
    if first_data >= sector_count {
        return FatError.NoSpace
    }
    clusters :: (sector_count - first_data) / sectors_per_cluster
    if clusters < cast[u64](MIN_CLUSTERS) {
        return FatError.NoSpace
    }
    zeros : u8[512]
    for sector in 0..<first_data + sectors_per_cluster {
        if !device.write(device.context, sector, 1, zeros) {
            return FatError.DeviceError
        }
    }
    boot : u8[512]
    boot[0] = 0xeb
    boot[1] = 0x58
    boot[2] = 0x90
    for character, i in "SLOPOS  " {
        put_u8(boot, 3 + i, cast[u8](character))
    }
    put_u16(boot, 11, cast[u16](SECTOR_BYTES))
    put_u8(boot, 13, cast[u8](sectors_per_cluster))
    put_u16(boot, 14, cast[u16](reserved))
    put_u8(boot, 16, 2)
    put_u8(boot, 21, 0xf8)
    put_u16(boot, 24, 63)
    put_u16(boot, 26, 255)
    put_u32(boot, 32, cast[u32](sector_count))
    put_u32(boot, 36, cast[u32](fat_sectors))
    put_u32(boot, 44, 2)
    put_u16(boot, 48, 1)
    put_u16(boot, 50, 6)
    put_u8(boot, 64, 0x80)
    put_u8(boot, 66, 0x29)
    put_u32(boot, 67, 0x534c4f50)
    for i in 0..<cast[usize](11) {
        put_u8(boot, 71 + i, if i < label.count { upper(cast[u8](label[i])) } else { cast[u8](' ') })
    }
    for character, i in "FAT32   " {
        put_u8(boot, 82 + i, cast[u8](character))
    }
    put_u8(boot, 510, 0x55)
    put_u8(boot, 511, 0xaa)
    // FSInfo: its signatures, every cluster but the root's free, and the next after it
    info : u8[512]
    put_u32(info, 0, 0x41615252)
    put_u32(info, 484, 0x61417272)
    put_u32(info, 488, cast[u32](clusters) - 1)
    put_u32(info, 492, 3)
    put_u32(info, 508, 0xaa550000)
    // Each FAT's first sector: the media byte, the end marker, and the root's one cluster
    fat : u8[512]
    put_u32(fat, 0, 0x0ffffff8)
    put_u32(fat, 4, 0x0fffffff)
    put_u32(fat, 8, CHAIN_END_MARK)
    for at in u64.[0, 6] {
        if !device.write(device.context, at, 1, boot) || !device.write(device.context, at + 1, 1, info) {
            return FatError.DeviceError
        }
    }
    for copy in 0..<cast[u64](2) {
        if !device.write(device.context, reserved + copy * fat_sectors, 1, fat) {
            return FatError.DeviceError
        }
    }
    return null
}

// Little-endian bytes in a buffer, where they fit.

/**
 * Get a byte from a buffer.
 *
 * @param bytes The bytes read from, as a rule a sector's or a slot's.
 * @param at The byte's offset from the buffer's start; any value, as one past the end reads 0.
 * @return The byte; 0 if at is past the buffer's end.
 */
get_u8 :: fn(bytes: u8[], at: usize) -> u8 {
    return if at < bytes.count { bytes[at] } else { cast[u8](0) }
}

/**
 * Get a little-endian u16 from a buffer.
 *
 * @param bytes The bytes read from, as a rule a sector's or a slot's.
 * @param at Its first byte's offset.
 * @return The value, any byte past the buffer's end taken as 0.
 */
get_u16 :: fn(bytes: u8[], at: usize) -> u16 {
    return cast[u16](get_u8(bytes, at)) | cast[u16](get_u8(bytes, at + 1)) << 8
}

/**
 * Get a little-endian u32 from a buffer.
 *
 * @param bytes The bytes read from: a sector's or a slot's, or a buffer of 4 or more.
 * @param at Its first byte's offset.
 * @return The value, any byte past the buffer's end taken as 0.
 */
get_u32 :: fn(bytes: u8[], at: usize) -> u32 {
    return cast[u32](get_u16(bytes, at)) | cast[u32](get_u16(bytes, at + 2)) << 16
}

/**
 * Put a byte into a buffer, if it's within it.
 *
 * @param bytes The bytes written to, as a rule a sector's or a slot's.
 * @param at The byte's offset; past the buffer's end, nothing is written.
 * @param value The byte, any value.
 */
put_u8 :: fn(bytes: mut u8[], at: usize, value: u8) {
    if at < bytes.count {
        bytes[at] = value
    }
}

/**
 * Put a little-endian u16 into a buffer, each byte only if it's within it.
 *
 * @param bytes The bytes written to, as a rule a sector's or a slot's.
 * @param at Its first byte's offset.
 * @param value The value, any u16, written low byte first.
 */
put_u16 :: fn(bytes: mut u8[], at: usize, value: u16) {
    put_u8(bytes, at, cast[u8](value & 0xff))
    put_u8(bytes, at + 1, cast[u8](value >> 8))
}

/**
 * Put a little-endian u32 into a buffer, each byte only if it's within it.
 *
 * @param bytes The bytes written to, as a rule a sector's or a slot's.
 * @param at Its first byte's offset.
 * @param value The value, any u32, written low byte first.
 */
put_u32 :: fn(bytes: mut u8[], at: usize, value: u32) {
    put_u16(bytes, at, cast[u16](value & 0xffff))
    put_u16(bytes, at + 2, cast[u16](value >> 16))
}
