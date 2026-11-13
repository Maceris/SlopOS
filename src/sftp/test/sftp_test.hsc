/*
 * sftp's tests, a test program (tools/unit_tests.py): paths made relative to the home, never above it; INIT answered
 * with version 3; a packet whose length can't be one refused.
 */
package sftp_test

import runtime from "base"
import os from "std"
import ssh from "std"
import testing from "std"
import sftp from ".."

/** A path normalized, as text; "!" if it's refused. */
normal :: fn(path: string, into: mut u8[]) -> string {
    count :: sftp.normalize(string_bytes(path), into) or_return "!"
    return if count > 0 && count <= into.count { string_of(&into[0], count) } else { "" }
}

keeps_paths_beneath_the_home #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    storage : u8[64]
    testing.expect_eq(t, normal("/", storage[0..<64]), "", "/ is the home")
    testing.expect_eq(t, normal(".", storage[0..<64]), "", ". is the home")
    testing.expect_eq(t, normal("/a/./b//c/", storage[0..<64]), "a/b/c", "dots and empty parts left out")
    testing.expect_eq(t, normal("a/b/../c", storage[0..<64]), "a/c", ".. takes the part before away")
    testing.expect_eq(t, normal("/../../etc/passwd", storage[0..<64]), "etc/passwd", "never above the home")
    testing.expect_eq(t, normal("a/../../..", storage[0..<64]), "", "nor by going up past it")
    nul : u8[3]
    nul[0] = 0x61
    nul[2] = 0x62
    testing.expect(t, sftp.normalize(nul[0..<3], storage[0..<64]) == null, "a 0 byte is refused")
    testing.expect_eq(t, normal("aaaaaaaaaa/bbbbbbbbbb/cccccccccc", storage[0..<16]), "!", "and a path too long")
    return .Ok
}

answers_init_and_refuses_a_bad_length #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    state :: sftp.start_sftp(os.Directory.{})
    defer runtime.free(state)
    // INIT, version 3: length 5, type 1, version
    init :: u8.[0, 0, 0, 5, 1, 0, 0, 0, 3]
    for byte, i in init {
        ssh.set_byte(state.inbox[0..<sftp.SFTP_PACKET_BYTES], i, byte)
    }
    state.inbox_count = init.count
    testing.require(t, sftp.serve(state), "INIT's served")?
    testing.expect_eq(t, state.inbox_count, cast[usize](0), "and taken")
    answer :: ssh.range(state.outbox[0..<sftp.OUTBOX_BYTES], 0, state.outbox_count)
    testing.expect(t, ssh.same(answer, u8.[0, 0, 0, 5, 2, 0, 0, 0, 3]), "VERSION 3's the answer")
    // A length past what a packet may be
    huge :: u8.[0x7f, 0, 0, 0, 1]
    for byte, i in huge {
        ssh.set_byte(state.inbox[0..<sftp.SFTP_PACKET_BYTES], i, byte)
    }
    state.inbox_count = huge.count
    testing.expect(t, !sftp.serve(state), "a packet too long ends the stream")
    return .Ok
}
