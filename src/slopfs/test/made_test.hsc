package slopfs_test

import slopfs from ".."

/*
 * Volumes made at run time (decisions/0141), as the container service and a volume server make them between them: one
 * registered with nothing in it, which the same name can't be again; a sealed one's first keys made apart from the
 * container, which is given only the wrapped records, as the container service is; each filled with its root
 * directory, written, committed, and read back whole after a mount, the sealed one only with its passphrase. Checks
 * from 1300.
 */

/** What each volume made at run time is given to hold, in its file "made.txt". */
MADE_TEXT :: "made at run time"

/**
 * Check volumes made at run time (decisions/0141): one registered with nothing in it, which the same name can't be
 * again; a sealed one's first keys made apart from the container, which is given only the wrapped records; each filled
 * with its root directory, written, committed, and read back whole after a mount, the sealed one Locked without its
 * passphrase.
 *
 * @return 0 if every check passed, or the number of the first that failed, 1300 to 1327.
 */
check_made :: fn() -> int {
    device :: new_device_of(SEALED_BLOCKS) or_return 1300
    defer free_device(device)
    id : u8[16]
    for i in 0..<id.count {
        id[i] = cast[u8](0x6a + i)
    }
    slopfs.format(device, id) or_return 1301
    container := slopfs.mount(device) or_return 1302

    plain :: slopfs.register_volume(container, text_of("plain"), key_of_volume(), 5, .None) or_return 1303
    match slopfs.register_volume(container, text_of("plain"), key_of_volume(), 5, .None) {
        case Ok(again) => return 1304
        case Error(error) => {
            if error != .AlreadyExists {
                return 1305
            }
        }
    }
    sealed :: slopfs.register_volume(container, text_of("sealed"), key_of_volume(), 5, .Aes256Gcm) or_return 1306
    record := slopfs.volume_record(container, sealed) or_return 1307
    if !slopfs.is_unfilled(&record) {
        return 1308
    }
    // The volume server's part: its keys made from the passphrase, only the wrapped records handed over
    keys :: slopfs.new_keys(.Aes256Gcm) or_return 1309
    made :: slopfs.first_keys(keys, passphrase(), TEST_ARGON2, container.id, sealed, container.nodes.transaction) or_return 1310
    slopfs.free_keys(keys)
    slopfs.put_wrap(container, sealed, 0, &made.wrap) or_return 1311
    slopfs.put_generation(container, sealed, made.number, &made.generation) or_return 1312
    if commit_failed(container) {
        return 1313
    }

    // Each filled with its root directory, and written
    for which in u64.[plain, sealed] {
        volume :: (if which == sealed { slopfs.open_sealed_volume(container, which, passphrase()) } else { slopfs.open_volume(container, which) })
            or_return 1314
        slopfs.fill_volume(volume, 5) or_return 1315
        file :: slopfs.create(volume, slopfs.ROOT_OBJECT, "made.txt", .File) or_return 1316
        slopfs.write(volume, file, 0, text_of(MADE_TEXT)) or_return 1317
    }
    if commit_failed(container) {
        return 1318
    }
    slopfs.unmount(container)

    // Filled now, and read back; the sealed one locked without its passphrase
    container = slopfs.mount(device) or_return 1319
    match slopfs.open_volume(container, sealed) {
        case Ok(opened) => return 1320
        case Error(error) => {
            if error != .Locked {
                return 1321
            }
        }
    }
    for which in u64.[plain, sealed] {
        filled := slopfs.volume_record(container, which) or_return 1322
        if slopfs.is_unfilled(&filled) {
            return 1323
        }
        volume :: (if which == sealed { slopfs.open_sealed_volume(container, which, passphrase()) } else { slopfs.open_volume(container, which) })
            or_return 1324
        found :: slopfs.lookup(volume, slopfs.ROOT_OBJECT, "made.txt") or_return 1325
        file :: found or_return 1325
        back : u8[64]
        got :: slopfs.read(volume, file, 0, back) or_return 1326
        if got != MADE_TEXT.count || got > back.count || !same(back[0..<got], text_of(MADE_TEXT)) {
            return 1327
        }
    }
    slopfs.unmount(container)
    return 0
}
