/*
 * FAT32 (roadmap 8b, decisions/0085, 0087): a volume on a device of 512-byte sectors, read and written through
 * functions, with long names. It's a portable package: the FAT server serves a partition with it, and its tests run
 * hosted over a buffer standing in for a disk.
 *
 * A volume is its boot sector's layout: reserved sectors, then each FAT, then clusters from 2, the root directory a
 * cluster chain like any other. A directory is known by its first cluster, and an entry by where its short entry is.
 * Names are UTF-8, as long names' UTF-16 converts to, compared without regard to ASCII case, as FAT compares them; a
 * name that isn't an upper-case 8.3 name gets long-name entries before a short alias made as Windows makes them
 * ("LONGNA~1.TXT"). There are no access or modification times written (SlopOS has no wall clock yet): every time is
 * 1980-01-01. Every FAT is written alike. FAT12 and FAT16, which a volume of fewer than 65525 clusters is by the
 * specification, aren't read.
 */
//SPEC: Microsoft Extensible Firmware Initiative FAT32 File System Specification, version 1.03 (2000): §3 (the boot
//SPEC: sector and BPB), §4 (the FAT), §5 (FSInfo), §6 (directories), §7 (long names); UEFI Specification 2.10 §13.3
package fat

SECTOR_BYTES : u64 : 512
ENTRY_BYTES : u64 : 32
// A name's UTF-16 code units at most, and the most bytes it takes as UTF-8
MAX_NAME_UNITS :: 255
NAME_BYTES :: 765
// Long-name entries for one name at most: 13 code units each
MAX_LONG_ENTRIES :: 20

// Attributes of a short entry
READ_ONLY : u8 : 0x01
HIDDEN : u8 : 0x02
SYSTEM : u8 : 0x04
VOLUME_ID : u8 : 0x08
DIRECTORY : u8 : 0x10
ARCHIVE : u8 : 0x20
LONG_NAME : u8 : 0x0f
// A short entry's first byte for a free one, and for one never used (and all after it)
DELETED : u8 : 0xe5
END : u8 : 0x00
// The FAT's entries: free, and the end of a chain (anything from END_OF_CHAIN up), of 28 bits
FREE_CLUSTER : u32 : 0
END_OF_CHAIN : u32 : 0x0ffffff8
CHAIN_END_MARK : u32 : 0x0fffffff
CLUSTER_MASK : u32 : 0x0fffffff
// The fewest clusters a FAT32 volume has
MIN_CLUSTERS : u32 : 65525

FatError :: enum {
    // Not a FAT32 volume: no boot sector, another FAT, or a layout that doesn't fit the device
    NotFat,
    NotFound,
    NotADirectory,
    IsADirectory,
    AlreadyExists,
    DirectoryNotEmpty,
    // A name FAT can't hold: empty, too long, a character it refuses, or ending in a space or a dot
    InvalidName,
    NoSpace,
    // The device couldn't be read or written
    DeviceError,
    // A chain or a directory that doesn't hold together
    Corrupt,
    ReadOnly,
}

// A device to read and write: count sectors from first into into, or from from, true if it could.
Device :: struct #scoped {
    context : rawptr,
    sector_count : u64,
    read : fn(context: rawptr, first: u64, count: u64, into: mut u8[]) -> bool,
    write : fn(context: rawptr, first: u64, count: u64, from: u8[]) -> bool,
    read_only : bool,
}

// A mounted volume: its device, its layout, and where the next free cluster is likely to be.
Volume :: struct #scoped {
    device : Device,
    sectors_per_cluster : u64,
    cluster_bytes : u64,
    reserved_sectors : u64,
    fat_count : u64,
    fat_sectors : u64,
    first_data_sector : u64,
    cluster_count : u32,
    root_cluster : u32,
    info_sector : u64,
    next_free : u32,
    label : u8[11],
}

// Where an entry's short entry is: its directory's first cluster, and its slot in that directory, from 0.
Place :: struct {
    directory : u32,
    slot : u32,
    // Its long-name entries, which come right before it
    long_entries : u32,
}

// An entry of a directory: its name as UTF-8, its short name, its attributes, its first cluster and size, and where it is.
Entry :: struct {
    name : u8[NAME_BYTES],
    name_length : u32,
    short_name : u8[11],
    attributes : u8,
    first_cluster : u32,
    size : u32,
    place : Place,
}

// A short directory entry, as it is on the volume.
ShortEntry :: struct #packed {
    name : u8[11],
    attributes : u8,
    case_flags : u8,
    created_tenths : u8,
    created_time : u16le,
    created_date : u16le,
    accessed_date : u16le,
    cluster_high : u16le,
    written_time : u16le,
    written_date : u16le,
    cluster_low : u16le,
    size : u32le,
}

#assert size_of(ShortEntry) == 32

// A long-name entry, 13 of the name's code units, last first.
LongEntry :: struct #packed {
    order : u8,
    name1 : u16le[5],
    attributes : u8,
    kind : u8,
    checksum : u8,
    name2 : u16le[6],
    cluster : u16le,
    name3 : u16le[2],
}

#assert size_of(LongEntry) == 32

// 1980-01-01, the earliest date FAT holds: day 1, month 1, year 0
EPOCH_DATE : u16 : (1 << 5) | 1
// The case flags: an all-lower-case base name, or extension, kept in an 8.3 name with no long name
LOWER_BASE : u8 : 0x08
LOWER_EXTENSION : u8 : 0x10
LAST_LONG_ENTRY : u8 : 0x40

// Mounting

/*
 * The FAT32 volume on device: its boot sector checked (512-byte sectors, a power of two of them to a cluster, no
 * fixed root directory, enough clusters to be FAT32, and a layout inside the device).
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
        info_sector = info, next_free = 2}
    for i in 0..<cast[usize](11) {
        volume.label[i] = get_u8(sector, 71 + i)
    }
    return .Ok(volume)
}

// The root directory's first cluster.
root_of :: fn(volume: ptr[Volume]) -> u32 {
    return volume.root_cluster
}

// Clusters and the FAT

// The first sector of a cluster.
sector_of :: fn(volume: ptr[Volume], cluster: u32) -> u64 {
    return volume.first_data_sector + cast[u64](cluster - 2) * volume.sectors_per_cluster
}

is_cluster :: fn(volume: ptr[Volume], cluster: u32) -> bool {
    return cluster >= 2 && cluster < volume.cluster_count + 2
}

// The FAT's entry for a cluster, from the first FAT.
fat_entry :: fn(volume: ptr[Volume], cluster: u32) -> Result[u32, FatError] {
    offset :: cast[u64](cluster) * 4
    sector : u8[512]
    if !volume.device.read(volume.device.context, volume.reserved_sectors + offset / SECTOR_BYTES, 1, sector) {
        return .Error(.DeviceError)
    }
    return .Ok(get_u32(sector, cast[usize](offset % SECTOR_BYTES)) & CLUSTER_MASK)
}

// A cluster's FAT entry set, in every FAT, its top four bits kept.
set_fat_entry :: fn(volume: ptr[mut Volume], cluster: u32, value: u32) -> FatError? {
    if volume.device.read_only {
        return FatError.ReadOnly
    }
    offset :: cast[u64](cluster) * 4
    for copy in 0..<volume.fat_count {
        at :: volume.reserved_sectors + copy * volume.fat_sectors + offset / SECTOR_BYTES
        sector : u8[512]
        if !volume.device.read(volume.device.context, at, 1, sector) {
            return FatError.DeviceError
        }
        within :: cast[usize](offset % SECTOR_BYTES)
        put_u32(sector, within, (get_u32(sector, within) & ~CLUSTER_MASK) | (value & CLUSTER_MASK))
        if !volume.device.write(volume.device.context, at, 1, sector) {
            return FatError.DeviceError
        }
    }
    return null
}

// The cluster after one in its chain, or null at its end.
next_cluster :: fn(volume: ptr[Volume], cluster: u32) -> Result[u32?, FatError] {
    entry :: fat_entry(volume, cluster)?
    if entry >= END_OF_CHAIN {
        return .Ok(null)
    }
    if !is_cluster(volume, entry) {
        return .Error(.Corrupt)
    }
    return .Ok(entry)
}

/*
 * A free cluster, zeroed, marked as a chain's end, and linked after previous unless it's 0: from where the last was
 * found, around the volume once.
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
        return .Ok(cluster)
    }
    return .Error(.NoSpace)
}

zero_cluster :: fn(volume: ptr[Volume], cluster: u32) -> Result[void, FatError] {
    zeros : u8[512]
    first :: sector_of(volume, cluster)
    for i in 0..<volume.sectors_per_cluster {
        if !volume.device.write(volume.device.context, first + i, 1, zeros) {
            return .Error(.DeviceError)
        }
    }
    return .Ok
}

// Every cluster of a chain from first, free again.
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
        if following == 0 {
            return null
        }
        cluster = following
    }
    return FatError.Corrupt
}

// The index-th cluster of a chain from first, or null if it's shorter.
cluster_at :: fn(volume: ptr[Volume], first: u32, index: u64) -> Result[u32?, FatError] {
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

// A directory slot's 32 bytes, read; and where its sector is, and its offset in it.
SlotAt :: struct {
    sector : u64,
    offset : usize,
}

// Where a directory's slot is, or null past its chain's end.
slot_at :: fn(volume: ptr[Volume], directory: u32, slot: u32) -> Result[SlotAt?, FatError] {
    per_cluster :: volume.cluster_bytes / ENTRY_BYTES
    cluster :: cluster_at(volume, directory, cast[u64](slot) / per_cluster)? or_return .Ok(null)
    within :: (cast[u64](slot) % per_cluster) * ENTRY_BYTES
    return .Ok(SlotAt.{sector = sector_of(volume, cluster) + within / SECTOR_BYTES, offset = cast[usize](within % SECTOR_BYTES)})
}

read_slot :: fn(volume: ptr[Volume], at: SlotAt, into: ptr[mut u8[32]]) -> FatError? {
    sector : u8[512]
    if !volume.device.read(volume.device.context, at.sector, 1, sector) {
        return FatError.DeviceError
    }
    for i in 0..<cast[usize](32) {
        into^[i] = get_u8(sector, at.offset + i)
    }
    return null
}

write_slot :: fn(volume: ptr[Volume], at: SlotAt, from: ptr[u8[32]]) -> FatError? {
    if volume.device.read_only {
        return FatError.ReadOnly
    }
    sector : u8[512]
    if !volume.device.read(volume.device.context, at.sector, 1, sector) {
        return FatError.DeviceError
    }
    for byte, i in from^ {
        put_u8(sector, at.offset + i, byte)
    }
    if !volume.device.write(volume.device.context, at.sector, 1, sector) {
        return FatError.DeviceError
    }
    return null
}

// Listing

// An entry listed, and the slot to list from next.
Listed :: struct {
    entry : Entry,
    next : u32,
}

/*
 * The entry at or after slot in directory, and the slot after it, or null at the directory's end: its long name where
 * its long-name entries are whole and match its checksum, otherwise its short name. Volume labels and "." and ".."
 * are left out.
 */
next_entry :: fn(volume: ptr[Volume], directory: u32, slot: u32) -> Result[Listed?, FatError] {
    units : u16[MAX_NAME_UNITS + 13]
    long_count := cast[u32](0)
    expected := cast[u8](0)
    checksum := cast[u8](0)
    at_slot := slot
    for step in 0..<cast[u32](0x200000) {
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

/*
 * The entry whose short entry is at place, as it is now, its name as given, so connections to one file see what each
 * writes; NotFound if it's been removed since.
 */
entry_at :: fn(volume: ptr[Volume], place: Place, name: string) -> Result[Entry, FatError] {
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
    entry.name_length = copy_name(name, &entry.name)
    return .Ok(entry)
}

// The entry named name in directory, compared without regard to ASCII case, or NotFound.
lookup :: fn(volume: ptr[Volume], directory: u32, name: string) -> Result[Entry, FatError] {
    slot := cast[u32](0)
    loop {
        found :: next_entry(volume, directory, slot)? or_return .Error(.NotFound)
        if same_name(name_of(&found.entry), name) {
            return .Ok(found.entry)
        }
        slot = found.next
    }
}

/*
 * The entry at path beneath directory, its components separated by '/': each but the last a directory. "." and ".."
 * aren't components, so nothing leads above directory (decisions/0046).
 */
resolve :: fn(volume: ptr[Volume], directory: u32, path: string) -> Result[Entry, FatError] {
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

// The first cluster of a directory entry's directory: the root's, for an entry whose cluster is 0 ("..", to the root).
directory_cluster :: fn(volume: ptr[Volume], entry: ptr[Entry]) -> u32 {
    return if entry.first_cluster == 0 { volume.root_cluster } else { entry.first_cluster }
}

// Reading and writing files

// Bytes of a file from offset into into: how many, fewer at its end.
read :: fn(volume: ptr[Volume], entry: ptr[Entry], offset: u64, into: mut u8[]) -> Result[u64, FatError] {
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
        if !volume.device.read(volume.device.context, at, 1, sector) {
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

/*
 * Bytes into a file from offset, its chain grown to hold them and any gap before them zeroed, and its size, in its
 * directory entry, grown to their end: how many.
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
            if !volume.device.read(volume.device.context, at, 1, sector) {
                return .Error(.DeviceError)
            }
        }
        for i in 0..<count {
            source :: cast[usize](done + i)
            if source < from.count {
                put_u8(sector, cast[usize](start + i), from[source])
            }
        }
        if !volume.device.write(volume.device.context, at, 1, sector) {
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

// A file's chain long enough for size bytes: clusters added, zeroed, after its last, or its first made.
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

/*
 * A file's size set: shorter, its chain cut after the clusters it still needs, or all of it freed for 0; longer, its
 * chain grown, zeroed.
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

// A file's bytes from start to end, zeroed, its chain holding them already.
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
        if !volume.device.read(volume.device.context, sector_at, 1, sector) {
            return .Error(.DeviceError)
        }
        for i in 0..<count {
            put_u8(sector, cast[usize](at % SECTOR_BYTES + i), 0)
        }
        if !volume.device.write(volume.device.context, sector_at, 1, sector) {
            return .Error(.DeviceError)
        }
        at += count
    }
    return .Ok
}

// An entry's first cluster and size, written back to its short entry.
update_entry :: fn(volume: ptr[Volume], entry: ptr[Entry]) -> Result[void, FatError] {
    at :: slot_at(volume, entry.place.directory, entry.place.slot)? or_return .Error(.Corrupt)
    bytes : u8[32]
    match read_slot(volume, at, &bytes) {
        case Some(error) => return .Error(error)
        case None => {}
    }
    put_u16(bytes, 20, cast[u16](entry.first_cluster >> 16))
    put_u16(bytes, 26, cast[u16](entry.first_cluster & 0xffff))
    put_u32(bytes, 28, if entry.attributes & DIRECTORY != 0 { cast[u32](0) } else { entry.size })
    match write_slot(volume, at, &bytes) {
        case Some(error) => return .Error(error)
        case None => return .Ok
    }
}

// Making, removing and renaming

/*
 * A new file, or directory, named name in directory: its long-name entries and its short entry in a run of free
 * slots, the directory grown by a cluster if it has none; a directory gets a cluster of its own with "." and "..".
 */
create :: fn(volume: ptr[mut Volume], directory: u32, name: string, is_directory: bool) -> Result[Entry, FatError] {
    if volume.device.read_only {
        return .Error(.ReadOnly)
    }
    units : u16[MAX_NAME_UNITS]
    unit_count :: units_of_name(name, &units) or_return .Error(.InvalidName)
    match lookup(volume, directory, name) {
        case Ok(found) => return .Error(.AlreadyExists)
        case Error(error) => {
            if error != .NotFound {
                return .Error(error)
            }
        }
    }
    entry := Entry.{attributes = if is_directory { DIRECTORY } else { ARCHIVE }}
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

// A directory's "." and "..", in its first cluster: ".." of the root's directories is cluster 0.
make_dots :: fn(volume: ptr[mut Volume], cluster: u32, parent: u32) -> Result[void, FatError] {
    for which in 0..<cast[u32](2) {
        dots := Entry.{attributes = DIRECTORY, first_cluster = if which == 0 { cluster } else if parent == volume.root_cluster { cast[u32](0) } else { parent }}
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

short_entry_of :: fn(entry: ptr[Entry], case_flags: u8) -> u8[32] {
    bytes : u8[32]
    for byte, i in entry.short_name {
        bytes[i] = byte
    }
    bytes[11] = entry.attributes
    bytes[12] = case_flags
    put_u16(bytes, 16, EPOCH_DATE)
    put_u16(bytes, 18, EPOCH_DATE)
    put_u16(bytes, 20, cast[u16](entry.first_cluster >> 16))
    put_u16(bytes, 24, EPOCH_DATE)
    put_u16(bytes, 26, cast[u16](entry.first_cluster & 0xffff))
    put_u32(bytes, 28, if entry.attributes & DIRECTORY != 0 { cast[u32](0) } else { entry.size })
    return bytes
}

// The first of count free slots in a row in directory, the directory grown by clusters, zeroed, until it has them.
free_slots :: fn(volume: ptr[mut Volume], directory: u32, count: u32) -> Result[u32, FatError] {
    run_start := cast[u32](0)
    run := cast[u32](0)
    slot := cast[u32](0)
    for step in 0..<cast[u32](0x200000) {
        at := slot_at(volume, directory, slot)?
        if at is_none {
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

last_cluster :: fn(volume: ptr[Volume], first: u32) -> Result[u32, FatError] {
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

// An entry's slots, its long-name entries and its short one, marked free.
free_entry_slots :: fn(volume: ptr[Volume], entry: ptr[Entry]) -> Result[void, FatError] {
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

// An entry removed, its clusters freed: a directory only if it has nothing in it but "." and "..".
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

/*
 * An entry moved to name in directory, which may be its own: new entries for its clusters there, then its old ones
 * freed, and a moved directory's ".." pointed at its new parent. An entry already named name there is replaced, if
 * it's a file and so is the one moved, which is how a file's contents are replaced as atomically as FAT can (best
 * effort: a crash between the two leaves both names).
 */
rename :: fn(volume: ptr[mut Volume], entry: ptr[Entry], directory: u32, name: string) -> Result[Entry, FatError] {
    if volume.device.read_only {
        return .Error(.ReadOnly)
    }
    // A directory can't go beneath itself
    if entry.attributes & DIRECTORY != 0 && is_beneath(volume, directory, entry.first_cluster)? {
        return .Error(.InvalidName)
    }
    match lookup(volume, directory, name) {
        case Ok(existing) => {
            if existing.place.directory == entry.place.directory && existing.place.slot == entry.place.slot {
                // The same entry, by another case: its name changes in place, through a new entry
            }
            else if existing.attributes & DIRECTORY != 0 || entry.attributes & DIRECTORY != 0 {
                return .Error(.AlreadyExists)
            }
            else {
                replaced := existing
                remove(volume, &replaced)?
            }
        }
        case Error(error) => {
            if error != .NotFound {
                return .Error(error)
            }
        }
    }
    old := entry^
    // The new entry, made as a file so no cluster is allocated, then given the old one's
    moved := create(volume, directory, name, false)?
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
    if old.attributes & DIRECTORY != 0 && old.first_cluster != 0 && old.place.directory != directory {
        // Its ".." is its second slot
        dots := Entry.{attributes = DIRECTORY, first_cluster = if directory == volume.root_cluster { cast[u32](0) } else { directory }}
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

// Whether directory is ancestor, or beneath it, by following "..".
is_beneath :: fn(volume: ptr[Volume], directory: u32, ancestor: u32) -> Result[bool, FatError] {
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

// An entry's name, as text.
name_of :: fn(entry: ptr[Entry]) -> string {
    return string_of(&entry.name[0], cast[usize](if entry.name_length > NAME_BYTES { cast[u32](NAME_BYTES) } else { entry.name_length }))
}

// Whether two names are the same to FAT: byte for byte but for ASCII letters' case.
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

upper :: fn(byte: u8) -> u8 {
    return if byte >= cast[u8]('a') && byte <= cast[u8]('z') { byte - 32 } else { byte }
}

lower :: fn(byte: u8) -> u8 {
    return if byte >= cast[u8]('A') && byte <= cast[u8]('Z') { byte + 32 } else { byte }
}

// A short name as text: its base and extension, trimmed, lower-cased where its case flags say, a dot between.
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

// A byte at at in a name, if it fits: where the next goes.
put_name_byte :: fn(into: ptr[mut u8[NAME_BYTES]], at: usize, byte: u8) -> usize {
    if at < into^.count {
        into^[at] = byte
        return at + 1
    }
    return at
}

// The checksum of a short name that its long-name entries carry.
short_checksum :: fn(short: ptr[u8[11]]) -> u8 {
    sum := cast[u8](0)
    for byte in short^ {
        sum = ((sum & 1) << 7) + (sum >> 1) + byte
    }
    return sum
}

/*
 * A name as UTF-16 code units, if FAT can hold it: not empty, at most 255 units, no control characters, none of the
 * characters FAT refuses (double quote, asterisk, slash, colon, angle brackets, question mark, backslash, bar), and
 * not ending in a space or a dot. Its count.
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

// UTF-16 code units, up to the first zero, as UTF-8 into into: its length. Unpaired surrogates become '?'.
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

// Whether a name is an 8.3 name as it is, so it needs no long name: its short name, upper-case, into short.
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

// The case flags an 8.3 name with no long name keeps its lower case in.
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

// The characters a short name may have, besides letters, which it holds in upper case.
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

/*
 * A short alias for a long name, as Windows makes one: the name's short characters upper-cased, the last dot's part
 * as its extension, its base cut to 6 with "~N" after it, N from 1 until no entry in directory has it.
 */
make_alias :: fn(volume: ptr[Volume], directory: u32, name: string, short: ptr[mut u8[11]]) -> Result[void, FatError] {
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
    for tail in 1..<cast[u32](1000000) {
        digits : u8[7]
        digit_count : usize = 0
        value := tail
        loop {
            if digit_count < digits.count {
                digits[digit_count] = cast[u8]('0') + cast[u8](value % 10)
                digit_count += 1
            }
            value /= 10
        }
        while value != 0
        keep :: if base_count + digit_count + 1 > 8 { 8 - digit_count - 1 } else { base_count }
        for i in 0..<cast[usize](8) {
            short^[i] = cast[u8](' ')
        }
        for i in 0..<keep {
            if i < base.count {
                short^[i] = base[i]
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
        if !alias_taken(volume, directory, short)? {
            return .Ok
        }
    }
    return .Error(.NoSpace)
}

alias_taken :: fn(volume: ptr[Volume], directory: u32, short: ptr[u8[11]]) -> Result[bool, FatError] {
    slot := cast[u32](0)
    loop {
        found :: next_entry(volume, directory, slot)? or_return .Ok(false)
        if found.entry.short_name == short^ {
            return .Ok(true)
        }
        slot = found.next
    }
}

// Formatting

/*
 * A new, empty FAT32 volume on a device of sector_count sectors: 32 reserved sectors with the boot sector and its
 * copy at 6 and FSInfo at 1, two FATs, clusters of sectors_per_cluster, and the root directory at cluster 2. Labelled
 * label, up to 11 characters. NoSpace if it would have too few clusters to be FAT32.
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
    // FSInfo: its signatures, and free counts unknown
    info : u8[512]
    put_u32(info, 0, 0x41615252)
    put_u32(info, 484, 0x61417272)
    put_u32(info, 488, 0xffffffff)
    put_u32(info, 492, 0xffffffff)
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

get_u8 :: fn(bytes: u8[], at: usize) -> u8 {
    return if at < bytes.count { bytes[at] } else { cast[u8](0) }
}

get_u16 :: fn(bytes: u8[], at: usize) -> u16 {
    return cast[u16](get_u8(bytes, at)) | cast[u16](get_u8(bytes, at + 1)) << 8
}

get_u32 :: fn(bytes: u8[], at: usize) -> u32 {
    return cast[u32](get_u16(bytes, at)) | cast[u32](get_u16(bytes, at + 2)) << 16
}

put_u8 :: fn(bytes: mut u8[], at: usize, value: u8) {
    if at < bytes.count {
        bytes[at] = value
    }
}

put_u16 :: fn(bytes: mut u8[], at: usize, value: u16) {
    put_u8(bytes, at, cast[u8](value & 0xff))
    put_u8(bytes, at + 1, cast[u8](value >> 8))
}

put_u32 :: fn(bytes: mut u8[], at: usize, value: u32) {
    put_u16(bytes, at, cast[u16](value & 0xffff))
    put_u16(bytes, at + 2, cast[u16](value >> 16))
}
