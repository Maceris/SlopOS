/**
 * account_records' tests, as a hosted program (tools/unit_tests.py): main returns 0 if everything worked, or the number of
 * the first check that failed. Names and passwords held to their rules; the common list searched; a record's home secret
 * unsealed by its password and its recovery code and by nothing else, and by a new password once it's changed; a
 * recovery code shown and read back, however it's typed.
 */
package account_records_test

import compiler from "base"
import crypto from "std"
import account_records from ".."

/** Argon2id kept cheap for the tests */
TEST_ARGON2 :: crypto.Argon2Parameters.{memory_kib = 64, passes = 1, lanes = 1}

text :: fn(value: string) -> u8[] {
    return string_bytes(value)
}

problem_is :: fn(name: string, password: string, expected: account_records.PasswordProblem) -> bool {
    match account_records.password_problem(text(name), text(password)) {
        case Some(found) => return found == expected
        case None => return false
    }
}

fine :: fn(name: string, password: string) -> bool {
    return account_records.password_problem(text(name), text(password)) is_none
}

same_key #constant_time :: fn(a: ptr[crypto.Key256], b: ptr[crypto.Key256]) -> bool {
    difference := compiler.secret(cast[u8](0))
    for i in cast[usize](0)..<32 {
        difference = difference | (a[i] ~ b[i])
    }
    return compiler.declassify(difference == 0)
}

same_code #constant_time :: fn(a: ptr[account_records.RecoveryCode], b: ptr[account_records.RecoveryCode]) -> bool {
    difference := compiler.secret(cast[u8](0))
    for i in cast[usize](0)..<16 {
        difference = difference | (a[i] ~ b[i])
    }
    return compiler.declassify(difference == 0)
}

main :: fn() -> int {
    // Names
    if !account_records.valid_name(text("admin")) || !account_records.valid_name(text("a-b_9")) || account_records.valid_name(text(""))
        || account_records.valid_name(text("9lives")) || account_records.valid_name(text("Admin")) || account_records.valid_name(text("a b"))
        || account_records.valid_name(text("abcdefghijklmnopqrstuvwxyzabcdefg")) {
        return 1
    }
    // Passwords: length in code points, the common list in any case, the name
    if !problem_is("admin", "short", .TooShort) || !problem_is("admin", "ééééééé", .TooShort) || !fine("admin", "éééééééé") {
        return 2
    }
    long : u8[account_records.MAX_PASSWORD_BYTES + 1]
    for i in 0..<long.count {
        long[i] = cast[u8]('q')
    }
    if !(match account_records.password_problem(text("admin"), long) { case Some(found) => found == .TooLong case None => false }) {
        return 3
    }
    if !problem_is("admin", "password", .Common) || !problem_is("admin", "PassWord", .Common) || !problem_is("admin", "12345678", .Common) {
        return 4
    }
    if !problem_is("administrator", "AdminIstrator", .IsName) || !fine("admin", "correct horse battery staple") {
        return 5
    }
    // The table's first and last, and one between that isn't there
    first :: account_records.COMMON_PASSWORDS[0]
    last :: account_records.COMMON_PASSWORDS[account_records.COMMON_PASSWORDS.count - 1]
    if !account_records.is_common(string_bytes(first)) || !account_records.is_common(string_bytes(last)) || account_records.is_common(text("not a common one")) {
        return 6
    }

    // A record: its home secret unsealed by the password and the recovery code, and by nothing else
    home := account_records.random_key()
    code := account_records.new_recovery_code()
    record := account_records.new_record(text("admin"), true, 7, text("correct horse battery staple"), TEST_ARGON2, &home, &code) or_return 10
    if !account_records.is_administrator(&record) || compiler.declassify(account_records.name_of(&record).count) != 5 {
        return 11
    }
    unlocked := account_records.unlock_home(&record, text("correct horse battery staple")) or_return 12
    if !same_key(&unlocked, &home) {
        return 13
    }
    if account_records.unlock_home(&record, text("correct horse battery stapler")) is_some {
        return 14
    }
    recovered := account_records.recover_home(&record, &code) or_return 15
    if !same_key(&recovered, &home) {
        return 16
    }
    other := account_records.new_recovery_code()
    if account_records.recover_home(&record, &other) is_some {
        return 17
    }
    // Bound to its name: the same record under another can't be opened
    renamed := record
    renamed.name[0] = cast[u8]('b')
    if account_records.unlock_home(&renamed, text("correct horse battery staple")) is_some {
        return 18
    }
    // A new password: the old one no longer opens it
    if !account_records.set_password(&record, &home, text("a different long passphrase"), TEST_ARGON2) {
        return 19
    }
    if account_records.unlock_home(&record, text("correct horse battery staple")) is_some {
        return 20
    }
    again := account_records.unlock_home(&record, text("a different long passphrase")) or_return 21
    if !same_key(&again, &home) {
        return 22
    }

    // The recovery code shown, and read back as typed: in lowercase, without hyphens, with O for 0 and L for 1
    shown := account_records.recovery_text(&code)
    if shown[5] != cast[u8]('-') || shown[11] != cast[u8]('-') || shown[23] != cast[u8]('-') {
        return 30
    }
    read := account_records.parse_recovery(shown) or_return 31
    if !same_code(&read, &code) {
        return 32
    }
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
        return 33
    }
    typed_back := account_records.parse_recovery(typed[0..<count]) or_return 33
    if !same_code(&typed_back, &code) {
        return 34
    }
    if account_records.parse_recovery(shown[0..<28]) is_some {
        return 35
    }
    if account_records.parse_recovery(text("UUUUU-UUUUU-UUUUU-UUUUU-UUUUU")) is_some {
        return 36
    }
    return 0
}
