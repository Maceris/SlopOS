/**
 * account_records' tests, a test program (tools/unit_tests.py, decisions/0175). Names and passwords held to their
 * rules; the common list searched; a record's home secret unsealed by its password and its recovery code and by nothing
 * else, and by a new password once it's changed; a recovery code shown and read back, however it's typed.
 */
package account_records_test

import compiler from "base"
import crypto from "std"
import testing from "std"
import account_records from ".."

/** Argon2id kept cheap for the tests: 64 KiB, one pass, one lane. */
TEST_ARGON2 :: crypto.Argon2Parameters.{memory_kib = 64, passes = 1, lanes = 1}

/** The password account's record is made with. */
PASSWORD :: "correct horse battery staple"

/**
 * View a string's bytes.
 *
 * @param value Any text; not copied, so the view returned is of its bytes.
 * @return Its bytes, a view of the string's, good as long as it is.
 */
text :: fn(value: string) -> u8[] {
    return string_bytes(value)
}

/**
 * Check that password_problem finds a given problem with a password, reporting what it found if not.
 *
 * @param t The test's state, which a failure is recorded in.
 * @param name The account's name, which password_problem compares the password with, ignoring ASCII case.
 * @param password The password to check, as its UTF-8 bytes.
 * @param expected The problem the check passes on: TooShort, TooLong, Common or IsName.
 * @param message Why it's that problem, for whoever reads a failure.
 * @param location Where the check is; the caller's own.
 */
expect_problem :: fn(t: ptr[mut testing.T], name: string, password: u8[], expected: account_records.PasswordProblem, message: string,
        location := #caller_location) {
    match account_records.password_problem(text(name), password) {
        case Some(found) => {
            _ = testing.expect_eq(t, found, expected, message, location)
        }
        case None => testing.record(t, message, "no problem found", location)
    }
}

/**
 * Compare two keys in constant time.
 *
 * @param a A key, read only, compared with b through all 32 bytes.
 * @param b The key it's compared with, read only.
 * @return True if every byte is the same; only the answer is declassified.
 */
same_key #constant_time :: fn(a: ptr[crypto.Key256], b: ptr[crypto.Key256]) -> bool {
    difference := compiler.secret(cast[u8](0))
    for i in cast[usize](0)..<32 {
        difference = difference | (a[i] ~ b[i])
    }
    return compiler.declassify(difference == 0)
}

/**
 * Compare two recovery codes in constant time.
 *
 * @param a A recovery code, read only, compared with b through all 16 bytes.
 * @param b The code it's compared with, read only.
 * @return True if every byte is the same; only the answer is declassified.
 */
same_code #constant_time :: fn(a: ptr[account_records.RecoveryCode], b: ptr[account_records.RecoveryCode]) -> bool {
    difference := compiler.secret(cast[u8](0))
    for i in cast[usize](0)..<16 {
        difference = difference | (a[i] ~ b[i])
    }
    return compiler.declassify(difference == 0)
}

/** An account's record, made by account: what's sealed in it, and what unseals it. */
Account :: struct {
    /** The record, of admin, an administrator, created at 7, with PASSWORD as its password. */
    record : account_records.AccountRecord,
    /** The home secret sealed in it. */
    home : crypto.Key256,
    /** The recovery code that also unseals it. */
    code : account_records.RecoveryCode,
}

/**
 * Make a record of admin, an administrator, with a random home secret and recovery code, and PASSWORD.
 *
 * @param t The test's state, which a failure is recorded in.
 * @return The record, the secret and the code; Error if new_record refused it, the failure recorded.
 */
account :: fn(t: ptr[mut testing.T]) -> Result[Account, testing.Stopped] {
    home := account_records.random_key()
    code := account_records.new_recovery_code()
    made :: account_records.new_record(text("admin"), true, 7, text(PASSWORD), TEST_ARGON2, &home, &code)
    record :: testing.require_some(t, made, "a record of a valid name and a good password is made")?
    return .Ok(Account.{record = record, home = home, code = code})
}

names_are_held_to_their_rules #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    testing.expect(t, account_records.valid_name(text("admin")), "lowercase letters make a name")
    testing.expect(t, account_records.valid_name(text("a-b_9")), "hyphens, underscores and digits may follow the first letter")
    testing.expect(t, !account_records.valid_name(text("")), "a name has at least one character")
    testing.expect(t, !account_records.valid_name(text("9lives")), "a name starts with a letter")
    testing.expect(t, !account_records.valid_name(text("Admin")), "names are lowercase, so two can't differ only by case")
    testing.expect(t, !account_records.valid_name(text("a b")), "a name has no spaces")
    testing.expect(t, !account_records.valid_name(text("abcdefghijklmnopqrstuvwxyzabcdefg")), "33 characters is too long")
    return .Ok
}

passwords_are_held_to_their_rules #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    expect_problem(t, "admin", text("short"), .TooShort, "five characters are fewer than eight")
    expect_problem(t, "admin", text("ééééééé"), .TooShort, "length is in code points: 14 bytes, but 7 characters")
    testing.expect(t, account_records.password_problem(text("admin"), text("éééééééé")) is_none, "eight code points are enough")
    long : u8[account_records.MAX_PASSWORD_BYTES + 1]
    for i in 0..<long.count {
        long[i] = cast[u8]('q')
    }
    expect_problem(t, "admin", long, .TooLong, "one byte past MAX_PASSWORD_BYTES")
    expect_problem(t, "admin", text("password"), .Common, "password is on the common list")
    expect_problem(t, "admin", text("PassWord"), .Common, "the common list is searched ignoring case")
    expect_problem(t, "admin", text("12345678"), .Common, "12345678 is on the common list")
    expect_problem(t, "administrator", text("AdminIstrator"), .IsName, "the account's name, in any case, isn't a password")
    testing.expect(t, account_records.password_problem(text("admin"), text(PASSWORD)) is_none, "a long passphrase is fine")
    return .Ok
}

the_common_list_is_searched_from_end_to_end #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    first :: account_records.COMMON_PASSWORDS[0]
    last :: account_records.COMMON_PASSWORDS[account_records.COMMON_PASSWORDS.count - 1]
    testing.expect(t, account_records.is_common(string_bytes(first)), "the search reaches the table's first")
    testing.expect(t, account_records.is_common(string_bytes(last)), "and its last")
    testing.expect(t, !account_records.is_common(text("not a common one")), "and finds nothing between that isn't there")
    return .Ok
}

a_record_says_whose_it_is #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made :: account(t)?
    testing.expect(t, account_records.is_administrator(&made.record), "it was made an administrator's")
    testing.expect_eq(t, compiler.declassify(account_records.name_of(&made.record).count), 5, "admin, five bytes")
    return .Ok
}

the_password_and_the_recovery_code_unseal_the_home_secret #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made :: account(t)?
    unlocked :: testing.require_some(t, account_records.unlock_home(&made.record, text(PASSWORD)), "the password opens it")?
    testing.expect(t, same_key(&unlocked, &made.home), "to the home secret it was made with")
    recovered :: testing.require_some(t, account_records.recover_home(&made.record, &made.code), "the recovery code opens it")?
    testing.expect(t, same_key(&recovered, &made.home), "to the same home secret")
    return .Ok
}

nothing_else_unseals_the_home_secret #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made :: account(t)?
    testing.expect(t, account_records.unlock_home(&made.record, text("correct horse battery stapler")) is_none,
        "a password one letter longer is another password")
    other := account_records.new_recovery_code()
    testing.expect(t, account_records.recover_home(&made.record, &other) is_none, "another recovery code doesn't open it")
    // Bound to its name: the same record under another can't be opened
    renamed := made.record
    renamed.name[0] = cast[u8]('b')
    testing.expect(t, account_records.unlock_home(&renamed, text(PASSWORD)) is_none,
        "the name is bound to the sealed secret, so the record under another name can't be opened")
    return .Ok
}

a_new_password_replaces_the_old #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made := account(t)?
    testing.require(t, account_records.set_password(&made.record, &made.home, text("a different long passphrase"), TEST_ARGON2),
        "a good password can be set with the home secret")?
    testing.expect(t, account_records.unlock_home(&made.record, text(PASSWORD)) is_none, "the old password no longer opens it")
    again :: testing.require_some(t, account_records.unlock_home(&made.record, text("a different long passphrase")),
        "the new one does")?
    testing.expect(t, same_key(&again, &made.home), "to the same home secret")
    return .Ok
}

a_recovery_code_reads_back_however_it_is_typed #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    code := account_records.new_recovery_code()
    shown := account_records.recovery_text(&code)
    testing.expect_eq(t, shown[5], cast[u8]('-'), "groups of five, hyphens between them: the first")
    testing.expect_eq(t, shown[11], cast[u8]('-'), "the second hyphen, after the second group")
    testing.expect_eq(t, shown[23], cast[u8]('-'), "the fourth hyphen, after the fourth group")
    read :: testing.require_some(t, account_records.parse_recovery(shown), "a code reads back as it's shown")?
    testing.expect(t, same_code(&read, &code), "to the code shown")
    // Typed in lowercase, without hyphens, with O for 0 and L for 1
    typed : u8[account_records.RECOVERY_TEXT_BYTES]
    count : usize = 0
    for byte in shown {
        if byte == cast[u8]('-') {
            continue
        }
        swapped := if byte >= cast[u8]('A') && byte <= cast[u8]('Z') { byte + 32 } else { byte }
        if byte == cast[u8]('0') {
            swapped = cast[u8]('O')
        }
        if byte == cast[u8]('1') {
            swapped = cast[u8]('l')
        }
        if count < typed.count {
            typed[count] = swapped
            count += 1
        }
    }
    if count > typed.count {
        testing.fail(t, "the code typed without hyphens fits where it was shown")
        return .Ok
    }
    typed_back :: testing.require_some(t, account_records.parse_recovery(typed[0..<count]),
        "Crockford's base 32 reads lowercase, no hyphens, O as 0 and l as 1")?
    testing.expect(t, same_code(&typed_back, &code), "to the code shown")
    testing.expect(t, account_records.parse_recovery(shown[0..<28]) is_none, "a code with a character missing isn't one")
    testing.expect(t, account_records.parse_recovery(text("UUUUU-UUUUU-UUUUU-UUUUU-UUUUU")) is_none,
        "U isn't in Crockford's base 32")
    return .Ok
}
