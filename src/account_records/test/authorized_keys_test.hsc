/*
 * An account's keys: lines added, written again in OpenSSH's form with their comments cleaned, the same key refused
 * twice, a line that isn't a key refused, no more than MAX_KEYS, and keys removed by their fingerprints.
 */
package account_records_test

import ssh from "std"
import testing from "std"
import account_records from ".."

/** A key ssh-keygen -t ed25519 made, and its fingerprint as ssh-keygen -l gave it. */
KEY_LINE :: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEcZuugWDi2tmrSEzD5Z5J/QRht6pS6sXCdzeUW6qJY2 vector@test"
KEY_FINGERPRINT :: "SHA256:bBEtczzyIjtfN3fYz88H8A1mtM1727e1zgfHXEs8XyI"
/** Another, ECDSA P-256's. */
OTHER_LINE :: "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEm6YXN8tw6nd5mlHvEDMpgXCx7QWtXDBDIOCU+0w36H1g1E2XJKtYiPv6mRb6ofhbZy3Yac/rf4VhfdK8OVYmA="

/** The keys' text after adding a line to it: empty if it isn't added. */
added :: fn(keys: u8[], line: string, into: mut u8[]) -> u8[] {
    match account_records.add_key(keys, text(line), into) {
        case Added(length) => return if length <= into.count { into[0..<length] } else { into[0..<0] }
        case _ => return into[0..<0]
    }
}

/** Whether a text is one line, and its line break. */
is_line :: fn(bytes: u8[], line: string) -> bool {
    expected :: text(line)
    if bytes.count != expected.count + 1 || bytes[expected.count] != 0x0a {
        return false
    }
    for byte, i in expected {
        if i < bytes.count && bytes[i] != byte {
            return false
        }
    }
    return true
}

adds_and_removes_keys #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    first : u8[account_records.KEYS_TEXT_BYTES]
    // Blanks around it, a tab between its parts, a character past ASCII in its comment
    one :: added(u8.[], "  ssh-ed25519\tAAAAC3NzaC1lZDI1NTE5AAAAIEcZuugWDi2tmrSEzD5Z5J/QRht6pS6sXCdzeUW6qJY2  vector@teést \r\n", first[0..<first.count])
    testing.expect(t, is_line(one, KEY_LINE), "it's written in OpenSSH's form, its comment cleaned")
    testing.expect_eq(t, account_records.key_count(one), 1, "one key")
    second : u8[account_records.KEYS_TEXT_BYTES]
    two :: added(one, OTHER_LINE, second[0..<second.count])
    testing.expect_eq(t, account_records.key_count(two), 2, "an ECDSA key's added after it")
    third : u8[account_records.KEYS_TEXT_BYTES]
    match account_records.add_key(two, text("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEcZuugWDi2tmrSEzD5Z5J/QRht6pS6sXCdzeUW6qJY2 another"), third[0..<third.count]) {
        case AlreadyThere => {}
        case _ => testing.fail(t, "the same key with another comment is refused as there already")
    }
    match account_records.add_key(two, text("ssh-ed25519 AAAA not a key"), third[0..<third.count]) {
        case NotAKey => {}
        case _ => testing.fail(t, "a line that isn't a key is refused")
    }
    match account_records.add_key(two, text("ssh-rsa AAAAC3NzaC1lZDI1NTE5AAAAIEcZuugWDi2tmrSEzD5Z5J/QRht6pS6sXCdzeUW6qJY2"), third[0..<third.count]) {
        case NotAKey => {}
        case _ => testing.fail(t, "nor one whose name isn't its key's")
    }
    testing.expect(t, account_records.has_key_line(two, text(KEY_LINE)), "the keys have the first key")
    // Removed by its fingerprint
    fourth : u8[account_records.KEYS_TEXT_BYTES]
    removed :: account_records.remove_key(two, text(KEY_FINGERPRINT), fourth[0..<fourth.count])
    testing.require(t, removed != null, "a key's removed by its fingerprint")?
    left :: ssh.range(fourth[0..<fourth.count], 0, removed or_else 0)
    testing.expect_eq(t, account_records.key_count(left), 1, "one's left")
    testing.expect(t, !account_records.has_key_line(left, text(KEY_LINE)), "and it isn't the one removed")
    testing.expect(t, account_records.remove_key(left, text(KEY_FINGERPRINT), third[0..<third.count]) == null,
        "a fingerprint no key has removes nothing")
    return .Ok
}

holds_at_most_max_keys #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    // MAX_KEYS lines of the same key make a full list, as far as counting goes
    full : u8[account_records.KEYS_TEXT_BYTES]
    at := cast[usize](0)
    for i in 0..<account_records.MAX_KEYS {
        at = account_records.put(full[0..<full.count], at, text(OTHER_LINE))
    }
    testing.expect_eq(t, account_records.key_count(ssh.range(full[0..<full.count], 0, at)), account_records.MAX_KEYS, "MAX_KEYS keys")
    into : u8[account_records.KEYS_TEXT_BYTES]
    match account_records.add_key(ssh.range(full[0..<full.count], 0, at), text(KEY_LINE), into[0..<into.count]) {
        case Full => {}
        case _ => testing.fail(t, "another's refused as too many")
    }
    return .Ok
}
