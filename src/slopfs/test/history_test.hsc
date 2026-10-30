package slopfs_test

import runtime from "base"
import slopfs from ".."

/*
 * What a volume server keeps beyond the volume (history.hsc), on a volume apart: its change history, read beneath a
 * directory and trimmed to its budget; files replaced whole through orphans, the old contents readable until they're
 * given back; and everything since a commit forgotten and undone, leaving nothing behind. Checks from 800.
 */
check_history :: fn() -> int {
    device :: new_device() or_return 800
    defer free_device(device)
    id : u8[16]
    slopfs.format(device, id) or_return 801
    container := slopfs.mount(device) or_return 802
    defer slopfs.unmount(container)
    slopfs.create_volume(container, "h", key_of_volume(), 1) or_return 803
    if commit_failed(container) {
        return 804
    }
    made :: apart(container, volume_id(container, "h")) or_return 805
    defer free_apart(made)
    volume :: made.volume
    volume.history_bytes = 4096
    root :: slopfs.ROOT_OBJECT
    name : u8[255]

    // A cursor from before anything is kept resyncs; then each change comes in order, and only those beneath
    start :: slopfs.changes_since(volume, root, 0, name) or_return 806
    if start.are != .Resync {
        return 807
    }
    cursor := start.next
    sub :: slopfs.create(volume, root, "sub", .Directory) or_return 808
    file :: slopfs.create(volume, sub, "f", .File) or_return 809
    slopfs.write(volume, file, 0, text_bytes("some bytes")) or_return 810
    slopfs.write(volume, file, 5, text_bytes("more")) or_return 811
    slopfs.rename(volume, sub, "f", root, "g") or_return 812
    expected :: slopfs.ChangeKind.[.Created, .Created, .Written, .MovedOut, .MovedIn]
    for kind, i in expected {
        found :: slopfs.changes_since(volume, root, cursor, name) or_return 813
        if found.are != .Found || found.kind != kind {
            return 814
        }
        cursor = found.next
    }
    last :: slopfs.changes_since(volume, root, cursor, name) or_return 815
    if last.are != .UpToDate {
        return 816
    }
    // Beneath sub, only what happened to its names
    in_sub := 0
    at := start.next
    loop {
        found :: slopfs.changes_since(volume, sub, at, name) or_return 817
        if found.are != .Found {
            break
        }
        in_sub += 1
        at = found.next
    }
    // f made in it, written in it, and moved out of it
    if in_sub != 3 {
        return 818
    }
    // Past the budget the oldest go, and a cursor from then resyncs
    for i in 0..<200 {
        text : u8[16]
        length :: name_of_number(text, i)
        slopfs.create(volume, root, string_of(&text[0], length), .File) or_return 819
    }
    trimmed :: slopfs.changes_since(volume, root, cursor, name) or_return 820
    if trimmed.are != .Resync {
        return 821
    }
    if !commit_apart(made) {
        return 822
    }

    // Replaced whole: the old file orphaned and still readable, until it's given back
    old :: slopfs.lookup(volume, root, "g") or_return 823
    replacement :: slopfs.create_orphan(volume, root) or_return 824
    slopfs.write(volume, replacement, 0, text_bytes("the new contents")) or_return 825
    swapped :: slopfs.install(volume, root, "g", replacement) or_return 826
    if (swapped or_else 0) != (old or_else 1) {
        return 827
    }
    back : u8[64]
    now :: slopfs.lookup(volume, root, "g") or_return 828
    read_now :: slopfs.read(volume, now or_else 0, 0, back) or_return 829
    if !same(slopfs.part(back, 0, read_now), text_bytes("the new contents")) {
        return 830
    }
    read_old :: slopfs.read(volume, old or_else 0, 0, back) or_return 831
    if !same(slopfs.part(back, 0, read_old), text_bytes("some mores")) {
        return 832
    }
    slopfs.release_orphan(volume, old or_else 0) or_return 833
    // An orphan left behind, as a crash would leave a replacement never installed, is swept
    _ = slopfs.create_orphan(volume, root) or_return 834
    swept :: slopfs.sweep_orphans(volume) or_return 835
    if swept != 1 {
        return 836
    }
    if !commit_apart(made) {
        return 837
    }
    committed :: slopfs.record_of(volume)

    // Everything since that commit forgotten, and undone in the container: nothing of it left, and nothing leaked
    lost :: slopfs.create(volume, root, "lost", .File) or_return 838
    data := runtime.new(Data)
    defer runtime.free(data)
    pattern(data.bytes, 9)
    slopfs.write(volume, lost, 0, data.bytes[0..<200000]) or_return 839
    slopfs.remove(volume, root, "g") or_return 840
    undone : slopfs.Change[..]
    defer runtime.array_free(&undone)
    slopfs.abandon_volume(container, made.side.id, &undone)
    slopfs.forget(volume, committed)
    still_lost :: slopfs.lookup(volume, root, "lost") or_return 841
    still_there :: slopfs.lookup(volume, root, "g") or_return 842
    if undone.count == 0 || (still_lost is_some) || (still_there is_none) {
        return 843
    }
    if !commit_apart(made) || !verified(container) {
        return 844
    }
    return 0
}

text_bytes :: fn(text: string) -> u8[] {
    return string_bytes(text)
}
