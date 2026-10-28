package slopfs_test

import slopfs from ".."

/*
 * Stored links (roadmap 8f, slopfs/links.hsc): one volume issues links to a directory and a file, another keeps a link
 * to each; a path walks up to its first link and no further, a link isn't a file or a directory to anything that
 * doesn't follow it, and what was issued is listed, revoked, kept across a mount, and gone with the link's removal. A
 * clone's copies of its origin's issued records issue nothing. Checks from 1200.
 */

check_links :: fn() -> int {
    device :: new_device_of(4096) or_return 1200
    defer free_device(device)
    id : u8[16]
    for i in 0..<id.count {
        id[i] = cast[u8](0xb0 + i)
    }
    slopfs.format(device, id) or_return 1201
    container := slopfs.mount(device) or_return 1202
    home := slopfs.create_volume(container, "home", key_of_volume(), 1) or_return 1203
    shared := slopfs.create_volume(container, "shared", key_of_volume(), 1) or_return 1204
    home_id :: home.id
    shared_id :: shared.id
    docs :: slopfs.create(shared, slopfs.ROOT_OBJECT, "docs", .Directory) or_return 1205
    note :: slopfs.create(shared, docs, "note", .File) or_return 1206
    slopfs.write(shared, note, 0, name_bytes("shared text")) or_return 1207

    // Issued by the shared volume, to home
    first :: slopfs.issue(shared, docs, true, id, home_id) or_return 1208
    second :: slopfs.issue(shared, note, false, id, home_id) or_return 1209
    if first != 1 || second != 2 {
        return 1210
    }
    to_docs := slopfs.LinkRecord.{container = id, volume = cast[u64le](shared_id), number = cast[u64le](first), write = 1}
    to_note := slopfs.LinkRecord.{container = id, volume = cast[u64le](shared_id), number = cast[u64le](second)}
    links :: slopfs.create(home, slopfs.ROOT_OBJECT, "links", .Directory) or_return 1211
    docs_link :: slopfs.create_link(home, links, "docs", &to_docs) or_return 1212
    slopfs.create_link(home, links, "note", &to_note) or_return 1213
    if commit_failed(container) {
        return 1214
    }

    // A path walks up to its first link, and the rest is the link's to follow
    walked := slopfs.walk(home, slopfs.ROOT_OBJECT, "links/docs/note") or_return 1215
    if !walked.link || walked.object != docs_link || !same_text(walked.rest, "note") {
        return 1216
    }
    walked = slopfs.walk(home, slopfs.ROOT_OBJECT, "links/docs") or_return 1217
    if !walked.link || walked.rest.count != 0 {
        return 1218
    }
    walked = slopfs.walk(home, slopfs.ROOT_OBJECT, "links") or_return 1219
    if walked.link || walked.object != links {
        return 1220
    }
    found :: slopfs.link_of(home, docs_link) or_return 1221
    if cast[u64](found.volume) != shared_id || cast[u64](found.number) != first || found.container != id {
        return 1222
    }
    // A link isn't a directory or a file to what doesn't follow it, and isn't listed as either
    if !refused_as(slopfs.resolve(home, slopfs.ROOT_OBJECT, "links/docs/note"), .IsALink) {
        return 1223
    }
    scratch : u8[16]
    match slopfs.read(home, docs_link, 0, scratch) {
        case Ok(_) => return 1224
        case Error(error) => {
            if error != .IsALink {
                return 1224
            }
        }
    }
    name : u8[slopfs.NAME_BYTES]
    listed :: slopfs.list(home, links, 0, name) or_return 1225
    if (listed or_return 1225).kind != .Link {
        return 1226
    }

    // What was issued, listed and revoked
    issued := slopfs.issued(shared, first) or_return 1227
    record :: issued or_return 1228
    if cast[u64](record.object) != docs || record.write != 1 || cast[u64](record.recipient_volume) != home_id || record.recipient_container != id {
        return 1229
    }
    listing := slopfs.next_issued(shared, 0) or_return 1230
    if (listing or_return 1231).number != first {
        return 1231
    }
    if !(slopfs.revoke(shared, first) or_return 1232) {
        return 1233
    }
    again :: slopfs.revoke(shared, first) or_return 1234
    if again {
        return 1235
    }
    issued = slopfs.issued(shared, first) or_return 1236
    if issued is_some {
        return 1237
    }
    listing = slopfs.next_issued(shared, 0) or_return 1238
    if (listing or_return 1239).number != second {
        return 1239
    }
    listing = slopfs.next_issued(shared, second + 1) or_return 1240
    if listing is_some {
        return 1241
    }
    third :: slopfs.issue(shared, docs, false, id, home_id) or_return 1242
    if third != 3 || commit_failed(container) {
        return 1243
    }

    // Kept across a mount
    slopfs.unmount(container)
    container = slopfs.mount(device) or_return 1244
    home = slopfs.open_volume(container, home_id) or_return 1245
    shared = slopfs.open_volume(container, shared_id) or_return 1246
    walked = slopfs.walk(home, slopfs.ROOT_OBJECT, "links/note") or_return 1247
    kept :: slopfs.link_of(home, walked.object) or_return 1248
    if cast[u64](kept.number) != second || kept.write != 0 {
        return 1249
    }
    issued = slopfs.issued(shared, second) or_return 1250
    if issued is_none {
        return 1251
    }
    issued = slopfs.issued(shared, first) or_return 1252
    if issued is_some {
        return 1253
    }

    // A clone's copies issue nothing, and its own numbers follow its origin's
    slopfs.take_snapshot(container, shared_id, name_bytes("then"), 2) or_return 1254
    if commit_failed(container) {
        return 1255
    }
    clone_id :: slopfs.clone_snapshot(container, shared_id, name_bytes("then"), name_bytes("copy"), 3) or_return 1256
    if commit_failed(container) {
        return 1257
    }
    clone := slopfs.open_volume(container, clone_id) or_return 1258
    issued = slopfs.issued(clone, second) or_return 1259
    if issued is_some {
        return 1260
    }
    listing = slopfs.next_issued(clone, 0) or_return 1261
    if listing is_some {
        return 1262
    }
    if (slopfs.issue(clone, slopfs.ROOT_OBJECT, false, id, home_id) or_return 1263) != 4 {
        return 1264
    }

    // Removed, a link takes its record with it
    slopfs.remove(home, links, "note") or_return 1265
    still :: slopfs.tree_has(home.nodes, &home.tree, slopfs.key_of(walked.object, .Link, 0)) or_return 1266
    if still {
        return 1267
    }
    if commit_failed(container) {
        return 1268
    }
    slopfs.unmount(container)
    return 0
}

same_text :: fn(a: string, b: string) -> bool {
    if a.count != b.count {
        return false
    }
    for character, i in a {
        if i < b.count && character != b[i] {
            return false
        }
    }
    return true
}

refused_as :: fn(result: Result[u64, slopfs.Error], expected: slopfs.Error) -> bool {
    return match result {
        case Ok(_) => false
        case Error(error) => error == expected
    }
}
