/**
 * safe_text's tests, as a hosted program (tools/unit_tests.py): main returns 0 if everything worked, or the number of
 * the first check that failed. Printable text is shown as it is; controls, bidirectional controls, invisible characters
 * and bytes that aren't UTF-8 become visible substitutes; an emoji's ZWJ and variation selector stay.
 */
package safe_text_test

import unicode from "std"
import safe_text from ".."

/** The first cluster of text, shown, and whether it's expected, in columns too. */
shows :: fn(text: u8[], expected: string, columns: usize) -> bool {
    end :: unicode.grapheme_end(text, 0)
    shown := safe_text.Shown.{}
    safe_text.show(text, 0, end, &shown)
    if shown.count > shown.bytes.count {
        return false
    }
    return string_of(&shown.bytes[0], shown.count) == expected && shown.columns == columns
}

main :: fn() -> int {
    if !shows(string_bytes("a"), "a", 1) || !shows(string_bytes("中"), "中", 2) {
        return 1
    }
    // C0 controls as Control Pictures, DEL too
    if !shows(u8.[0x1b, 0x5b], "␛", 1) || !shows(u8.[0x07], "␇", 1) || !shows(u8.[0x7f], "␡", 1) {
        return 2
    }
    // A C1 control, written out
    if !shows(u8.[0xc2, 0x9b], "⟨U+009B⟩", 8) {
        return 3
    }
    // RIGHT-TO-LEFT OVERRIDE, written out
    if !shows(u8.[0xe2, 0x80, 0xae], "⟨U+202E⟩", 8) {
        return 4
    }
    // A ZERO WIDTH SPACE after a letter is in its cluster (it extends nothing, so it's a cluster of its own)
    if !shows(u8.[0xe2, 0x80, 0x8b], "⟨U+200B⟩", 8) {
        return 5
    }
    // A ZWJ after a letter is in the letter's cluster, and isn't part of an emoji there
    if !shows(u8.[0x61, 0xe2, 0x80, 0x8d], "a⟨U+200D⟩", 9) {
        return 6
    }
    // An emoji ZWJ sequence and a heart with emoji presentation keep theirs
    family :: string_bytes("👨‍👩‍👧")
    if !shows(family, "👨‍👩‍👧", 2) || !shows(u8.[0xe2, 0x9d, 0xa4, 0xef, 0xb8, 0x8f], "❤️", 2) {
        return 7
    }
    // Bytes that aren't UTF-8
    if !shows(u8.[0xff], "�", 1) {
        return 8
    }
    // A tag character (invisible), written out
    if !shows(u8.[0xf3, 0xa0, 0x80, 0xa1], "⟨U+E0021⟩", 9) {
        return 9
    }
    return 0
}
