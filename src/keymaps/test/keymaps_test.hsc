/*
 * The keymaps' tests, as a hosted program (tools/unit_tests.py): main returns 0 if everything worked, or the number of
 * the first check that failed. The US layout types letters, digits and punctuation with and without shift, Enter and
 * Tab their characters, and Escape and Backspace nothing.
 */
package keymaps_test

import keymaps from ".."

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
    return 0
}
