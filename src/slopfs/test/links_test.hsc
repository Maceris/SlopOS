package slopfs_test

import testing from "std"
import slopfs from ".."

/*
 * Stored links (roadmap 8f, slopfs/links.hsc): one volume issues links to a directory and a file, another keeps a link
 * to each; a path walks up to its first link and no further, a link isn't a file or a directory to anything that
 * doesn't follow it, and what was issued is listed, revoked, kept across a mount, and gone with the link's removal. A
 * clone's copies of its origin's issued records issue nothing.
 */

/** Two volumes, one issuing links to a directory and a file, the other keeping a link to each, all committed. */
Linked :: struct {
    /** The disk, of 4096 blocks, freed by free_linked. */
    device : slopfs.Device,
    /** The container, mounted while mounted is true. */
    container : ptr[mut slopfs.Container],
    /** Whether container is mounted, so free_linked unmounts it. */
    mounted : bool,
    /** The container's ID, which every link names. */
    id : u8[16],
    /** The volume "home", which keeps the links, open in container. */
    home : ptr[mut slopfs.Volume],
    /** home's ID. */
    home_id : u64,
    /** The volume "shared", which issued the links, open in container. */
    shared : ptr[mut slopfs.Volume],
    /** shared's ID. */
    shared_id : u64,
    /** The directory "docs", in shared's root. */
    docs : u64,
    /** The file "docs/note", in shared, holding "shared text". */
    note : u64,
    /** The number shared issued for docs, with write: the first, 1. */
    first : u64,
    /** The number shared issued for note, read-only: the second, 2. */
    second : u64,
    /** The directory "links", in home's root. */
    links : u64,
    /** The link "links/docs", in home, to docs. */
    docs_link : u64,
}

/**
 * Format a container of 4096 blocks with two volumes, "home" and "shared": shared issues links, to its directory docs
 * with write and to docs/note without, to home, which keeps them as links/docs and links/note; all committed.
 *
 * @param t The test's state, which a failure is recorded in.
 * @return The volumes and links, the caller's to free with free_linked; Error if any of it failed, the failure
 *     recorded and nothing left to free.
 */
linked :: fn(t: ptr[mut testing.T]) -> Result[Linked, testing.Stopped] {
    device :: formatted(t, 4096, 0xb0)?
    made := Linked.{device = device}
    for &byte, i in made.id {
        byte^ = 0xb0 + cast[u8](i)
    }
    if link(t, &made) is_error {
        free_linked(&made)
        return .Error(.Failed)
    }
    return .Ok(made)
}

/**
 * Do linked's work on its formatted disk.
 *
 * @param t The test's state, which a failure is recorded in.
 * @param made The disk, formatted, and the container's ID; the rest is set here.
 * @return Ok if it's all done; Error(Failed), the failure recorded, if not.
 */
link :: fn(t: ptr[mut testing.T], made: ptr[mut Linked]) -> testing.Outcome {
    mounting :: slopfs.mount(made.device)
    made.container = testing.require_ok(t, mounting, "a formatted disk mounts")?
    made.mounted = true
    making_home :: slopfs.create_volume(made.container, "home", key_of_volume(), 1)
    made.home = testing.require_ok(t, making_home, "a new container has room for a volume")?
    making_shared :: slopfs.create_volume(made.container, "shared", key_of_volume(), 1)
    made.shared = testing.require_ok(t, making_shared, "a new container has room for a second volume")?
    made.home_id = made.home.id
    made.shared_id = made.shared.id
    making_docs :: slopfs.create(made.shared, slopfs.ROOT_OBJECT, "docs", .Directory)
    made.docs = testing.require_ok(t, making_docs, "a directory is made in the root")?
    making_note :: slopfs.create(made.shared, made.docs, "note", .File)
    made.note = testing.require_ok(t, making_note, "a file is made in the directory")?
    writing :: slopfs.write(made.shared, made.note, 0, name_bytes("shared text"))
    require_done(t, writing, "the file is written")?

    // Issued by the shared volume, to home
    issuing_first :: slopfs.issue(made.shared, made.docs, true, made.id, made.home_id)
    made.first = testing.require_ok(t, issuing_first, "a volume issues a link to its directory")?
    issuing_second :: slopfs.issue(made.shared, made.note, false, made.id, made.home_id)
    made.second = testing.require_ok(t, issuing_second, "a volume issues a link to its file")?
    testing.expect_eq(t, made.first, 1, "a volume's first link issued is numbered 1")
    testing.expect_eq(t, made.second, 2, "a volume's links issued are numbered on")
    to_docs := slopfs.LinkRecord.{container = made.id, volume = cast[u64le](made.shared_id), number = cast[u64le](made.first), write = 1}
    to_note := slopfs.LinkRecord.{container = made.id, volume = cast[u64le](made.shared_id), number = cast[u64le](made.second)}
    making_links :: slopfs.create(made.home, slopfs.ROOT_OBJECT, "links", .Directory)
    made.links = testing.require_ok(t, making_links, "a directory for the links is made")?
    keeping_docs :: slopfs.create_link(made.home, made.links, "docs", &to_docs)
    made.docs_link = testing.require_ok(t, keeping_docs, "a volume keeps a link to a directory")?
    keeping_note :: slopfs.create_link(made.home, made.links, "note", &to_note)
    require_done(t, keeping_note, "a volume keeps a link to a file")?
    require_commit(t, made.container, "the links issued and kept commit")?
    return .Ok
}

/**
 * Mount a linked container again, from what it last committed, and open both volumes again.
 *
 * @param t The test's state, which a failure is recorded in.
 * @param made The container, mounted; unmounted and mounted again, its container and volumes replaced.
 * @return Ok if it mounted and both volumes opened; Error(Failed), the failure recorded, if not.
 */
remount_linked :: fn(t: ptr[mut testing.T], made: ptr[mut Linked]) -> testing.Outcome {
    slopfs.unmount(made.container)
    made.mounted = false
    mounting :: slopfs.mount(made.device)
    made.container = testing.require_ok(t, mounting, "a container mounts again from what it committed")?
    made.mounted = true
    opening_home :: slopfs.open_volume(made.container, made.home_id)
    made.home = testing.require_ok(t, opening_home, "home opens again")?
    opening_shared :: slopfs.open_volume(made.container, made.shared_id)
    made.shared = testing.require_ok(t, opening_shared, "shared opens again")?
    return .Ok
}

/**
 * Give back what linked made: the container unmounted if it's mounted, and the disk freed.
 *
 * @param made What linked made, which isn't used after.
 */
free_linked :: fn(made: ptr[mut Linked]) {
    if made.mounted {
        slopfs.unmount(made.container)
    }
    free_device(made.device)
}

a_path_walks_up_to_its_first_link_and_no_further #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made := linked(t)?
    defer free_linked(&made)
    home :: made.home
    through :: slopfs.walk(home, slopfs.ROOT_OBJECT, "links/docs/note")
    walked := testing.require_ok(t, through, "a path through a link walks")?
    testing.expect(t, walked.link, "a path through a link stops at the link")
    testing.expect_eq(t, walked.object, made.docs_link, "the link a path stops at is the one it names")
    testing.expect(t, same_text(walked.rest, "note"), "what's past the link is the link's to follow")
    to :: slopfs.walk(home, slopfs.ROOT_OBJECT, "links/docs")
    walked = testing.require_ok(t, to, "a path to a link walks")?
    testing.expect(t, walked.link, "a path ending at a link stops at the link")
    testing.expect_eq(t, walked.rest.count, 0, "a path ending at a link leaves nothing past it")
    before :: slopfs.walk(home, slopfs.ROOT_OBJECT, "links")
    walked = testing.require_ok(t, before, "a path short of a link walks")?
    testing.expect(t, !walked.link, "a path short of any link isn't stopped by one")
    testing.expect_eq(t, walked.object, made.links, "a path short of any link walks to what it names")
    reading :: slopfs.link_of(home, made.docs_link)
    found :: testing.require_ok(t, reading, "a link's record reads")?
    testing.expect_eq(t, cast[u64](found.volume), made.shared_id, "a link names the volume that issued it")
    testing.expect_eq(t, cast[u64](found.number), made.first, "a link names the number it was issued")
    testing.expect(t, found.container == made.id, "a link names the container of the volume that issued it")
    return .Ok
}

a_link_isnt_a_file_or_directory_to_what_doesnt_follow_it #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made := linked(t)?
    defer free_linked(&made)
    home :: made.home
    resolving :: slopfs.resolve(home, slopfs.ROOT_OBJECT, "links/docs/note")
    testing.expect_error(t, resolving, .IsALink, "resolving doesn't follow links, so a path through one is refused")
    scratch : u8[16]
    reading :: slopfs.read(home, made.docs_link, 0, scratch)
    testing.expect_error(t, reading, .IsALink, "a link has no bytes to read")
    name : u8[slopfs.NAME_BYTES]
    listing :: slopfs.list(home, made.links, 0, name)
    listed :: testing.require_ok(t, listing, "a directory of links lists")?
    entry :: testing.require_some(t, listed, "a directory of links has entries")?
    testing.expect_eq(t, entry.kind, .Link, "a link is listed as a link")
    return .Ok
}

issued_links_are_listed_and_revoked_once #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made := linked(t)?
    defer free_linked(&made)
    shared :: made.shared
    reading :: slopfs.issued(shared, made.first)
    issued := testing.require_ok(t, reading, "what was issued reads")?
    record :: testing.require_some(t, issued, "what was issued is recorded")?
    testing.expect_eq(t, cast[u64](record.object), made.docs, "an issued record names the object issued")
    testing.expect_eq(t, record.write, 1, "an issued record says it was issued with write")
    testing.expect_eq(t, cast[u64](record.recipient_volume), made.home_id, "an issued record names the volume it was issued to")
    testing.expect(t, record.recipient_container == made.id, "an issued record names the container it was issued to")
    listing :: slopfs.next_issued(shared, 0)
    listed := testing.require_ok(t, listing, "what was issued lists")?
    lowest :: testing.require_some(t, listed, "something was issued")?
    testing.expect_eq(t, lowest.number, made.first, "issued records list in number order")
    revoking :: slopfs.revoke(shared, made.first)
    revoked :: testing.require_ok(t, revoking, "an issued link is revoked")?
    testing.expect(t, revoked, "revoking what was issued finds it")
    revoking_again :: slopfs.revoke(shared, made.first)
    again :: testing.require_ok(t, revoking_again, "a revoked link is revoked again")?
    testing.expect(t, !again, "revoking twice finds nothing the second time")
    reading_revoked :: slopfs.issued(shared, made.first)
    issued = testing.require_ok(t, reading_revoked, "a revoked number reads")?
    testing.expect(t, issued is_none, "a revoked link's record is gone")
    listing_after :: slopfs.next_issued(shared, 0)
    listed = testing.require_ok(t, listing_after, "what's still issued lists")?
    remaining :: testing.require_some(t, listed, "something is still issued")?
    testing.expect_eq(t, remaining.number, made.second, "a revoked record isn't listed")
    listing_past :: slopfs.next_issued(shared, made.second + 1)
    listed = testing.require_ok(t, listing_past, "what's issued lists past the last")?
    testing.expect(t, listed is_none, "nothing is issued past the last number")
    issuing :: slopfs.issue(shared, made.docs, false, made.id, made.home_id)
    third :: testing.require_ok(t, issuing, "a volume issues another link")?
    testing.expect_eq(t, third, 3, "numbers go on past a revoked one, never reused")
    _ = commits(t, made.container, "a revocation and a new link commit")
    return .Ok
}

links_issued_and_kept_last_across_a_mount #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made := linked(t)?
    defer free_linked(&made)
    revoking :: slopfs.revoke(made.shared, made.first)
    require_done(t, revoking, "an issued link is revoked")?
    require_commit(t, made.container, "a revocation commits")?
    remount_linked(t, &made)?
    walking :: slopfs.walk(made.home, slopfs.ROOT_OBJECT, "links/note")
    walked :: testing.require_ok(t, walking, "a path to a kept link walks after a mount")?
    reading :: slopfs.link_of(made.home, walked.object)
    kept :: testing.require_ok(t, reading, "a kept link's record reads after a mount")?
    testing.expect_eq(t, cast[u64](kept.number), made.second, "a kept link names the number it was issued after a mount")
    testing.expect_eq(t, kept.write, 0, "a link kept without write has none after a mount")
    reading_second :: slopfs.issued(made.shared, made.second)
    second :: testing.require_ok(t, reading_second, "an issued number reads after a mount")?
    testing.expect_some(t, second, "an issued record is kept across a mount")
    reading_first :: slopfs.issued(made.shared, made.first)
    first :: testing.require_ok(t, reading_first, "a revoked number reads after a mount")?
    testing.expect_none(t, first, "a revocation is kept across a mount")
    return .Ok
}

a_clones_copies_of_its_origins_issued_records_issue_nothing #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made := linked(t)?
    defer free_linked(&made)
    container :: made.container
    issuing :: slopfs.issue(made.shared, made.docs, false, made.id, made.home_id)
    third :: testing.require_ok(t, issuing, "a volume issues a third link")?
    testing.expect_eq(t, third, 3, "a volume's links issued are numbered on")
    require_commit(t, container, "the third link commits")?
    taking :: slopfs.take_snapshot(container, made.shared_id, name_bytes("then"), 2)
    require_done(t, taking, "a volume that issued links takes a snapshot")?
    require_commit(t, container, "the snapshot commits")?
    cloning :: slopfs.clone_snapshot(container, made.shared_id, name_bytes("then"), name_bytes("copy"), 3)
    clone_id :: testing.require_ok(t, cloning, "the snapshot is cloned")?
    require_commit(t, container, "the clone commits")?
    opening :: slopfs.open_volume(container, clone_id)
    clone :: testing.require_ok(t, opening, "the clone opens")?
    reading :: slopfs.issued(clone, made.second)
    issued :: testing.require_ok(t, reading, "a clone's issued records read")?
    testing.expect_none(t, issued, "a clone's copy of its origin's issued record issues nothing: the link was its origin's")
    listing :: slopfs.next_issued(clone, 0)
    listed :: testing.require_ok(t, listing, "a clone's issued records list")?
    testing.expect_none(t, listed, "a clone lists nothing issued of its origin's")
    issuing_own :: slopfs.issue(clone, slopfs.ROOT_OBJECT, false, made.id, made.home_id)
    own :: testing.require_ok(t, issuing_own, "a clone issues a link of its own")?
    testing.expect_eq(t, own, 4, "a clone's own numbers follow its origin's, so no number means two things")
    return .Ok
}

a_link_removed_takes_its_record_with_it #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made := linked(t)?
    defer free_linked(&made)
    home :: made.home
    walking :: slopfs.walk(home, slopfs.ROOT_OBJECT, "links/note")
    walked :: testing.require_ok(t, walking, "a path to a kept link walks")?
    removing :: slopfs.remove(home, made.links, "note")
    require_done(t, removing, "a link is removed")?
    looking :: slopfs.tree_has(home.nodes, &home.tree, slopfs.key_of(walked.object, .Link, 0))
    still :: testing.require_ok(t, looking, "the volume's tree is looked in")?
    testing.expect(t, !still, "a link removed takes its record with it")
    _ = commits(t, made.container, "a link's removal commits")
    return .Ok
}

/**
 * Tell whether two strings are the same.
 *
 * @param a A string, of any length, compared byte for byte.
 * @param b The other string, of any length.
 * @return True if they're the same length and byte for byte alike.
 */
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
