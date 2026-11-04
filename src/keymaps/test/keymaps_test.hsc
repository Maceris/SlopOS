/**
 * The keymaps' tests, as a hosted program (tools/unit_tests.py): main returns 0 if everything worked, or the number of
 * the first check that failed. The US layout types letters, digits and punctuation with and without shift, Enter and
 * Tab their characters, and Escape and Backspace nothing; the UK layout its own shifted keys, £ among them; and the
 * layouts go round.
 */
package keymaps_test

import keymaps from ".."

/**
 * Check the keymaps.
 *
 * @return 0 if every check passed; otherwise the first that failed: 1 if there's no US layout; 2 if its letters, 3
 *     its digits, 4 its space and punctuation, 5 Enter, Tab, Escape, Backspace or a key outside the table, or 6
 *     digit_of, type wrongly; 7 if find finds a layout that doesn't exist; 8 if there's no UK layout; 9 if its own
 *     keys type wrongly; 10 if next doesn't go round, or the ISO backslash key types wrongly.
 */
main :: fn() -> int {
    us :: keymaps.find("us") or_return 1
    if keymaps.typed(us, 0x04, false) != "a" || keymaps.typed(us, 0x1d, true) != "Z" {
        return 2
    }
    if keymaps.typed(us, 0x1e, false) != "1" || keymaps.typed(us, 0x1e, true) != "!" || keymaps.typed(us, 0x27, false) != "0" {
        return 3
    }
    if keymaps.typed(us, 0x2c, false) != " " || keymaps.typed(us, 0x38, true) != "?" || keymaps.typed(us, 0x34, true) != "\"" {
        return 4
    }
    if keymaps.typed(us, 0x28, false) != "\n" || keymaps.typed(us, 0x2b, false) != "\t" || keymaps.typed(us, 0x29, false) != ""
        || keymaps.typed(us, 0x2a, false) != "" || keymaps.typed(us, 0x4f, false) != "" {
        return 5
    }
    if (keymaps.digit_of(us, 0x20) or_else 99) != 3 || keymaps.digit_of(us, 0x04) != null {
        return 6
    }
    if keymaps.find("dvorak") != null {
        return 7
    }
    // The UK layout: shifted 2 and 3, the quote key's shift, and hash and tilde by Enter
    uk :: keymaps.find("uk") or_return 8
    if keymaps.typed(uk, 0x1f, true) != "\"" || keymaps.typed(uk, 0x20, true) != "£" || keymaps.typed(uk, 0x34, true) != "@"
        || keymaps.typed(uk, 0x32, false) != "#" || keymaps.typed(uk, 0x32, true) != "~" || keymaps.typed(uk, 0x04, false) != "a" {
        return 9
    }
    // Going round them, and the ISO backslash key on both
    if keymaps.next("us").name != "uk" || keymaps.next("uk").name != "us" || keymaps.typed(uk, 0x64, true) != "|"
        || keymaps.typed(us, 0x64, false) != "\\" {
        return 10
    }
    return 0
}
