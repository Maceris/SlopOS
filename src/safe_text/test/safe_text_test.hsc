/**
 * safe_text's tests, a test program (tools/unit_tests.py, decisions/0175). Printable text is shown as it is; controls,
 * bidirectional controls, invisible characters and bytes that aren't UTF-8 become visible substitutes; an emoji's ZWJ
 * and variation selector stay.
 */
package safe_text_test

import testing from "std"
import unicode from "std"
import safe_text from ".."

/**
 * Show the first cluster of a text, and check it shows as expected: its bytes and the columns it takes.
 *
 * @param t The test's state, which a failure is recorded in.
 * @param text The text; only its first grapheme cluster is shown.
 * @param expected The bytes it should show as.
 * @param columns The columns it should take.
 * @param message Why it should show so, for whoever reads a failure.
 * @param location Where the check is; the caller's own.
 */
expect_shows :: fn(t: ptr[mut testing.T], text: u8[], expected: string, columns: usize, message: string, location := #caller_location) {
    end :: unicode.grapheme_end(text, 0)
    shown := safe_text.Shown.{}
    safe_text.show(text, 0, end, &shown)
    if shown.count > shown.bytes.count {
        testing.record(t, message, "shown more bytes than Shown holds", location)
        return void
    }
    testing.expect_eq(t, string_of(&shown.bytes[0], shown.count), expected, message, location)
    testing.expect_eq(t, shown.columns, columns, message, location)
}

printable_text_is_shown_as_it_is #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    expect_shows(t, string_bytes("a"), "a", 1, "a letter is printable, one column")
    expect_shows(t, string_bytes("中"), "中", 2, "a wide character is printable, two columns")
    return .Ok
}

c0_controls_and_del_become_control_pictures #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    expect_shows(t, u8.[0x1b, 0x5b], "␛", 1, "ESC can't reach the terminal; its picture shows, and [ is a cluster after")
    expect_shows(t, u8.[0x07], "␇", 1, "BEL can't ring the terminal's bell; its picture shows")
    expect_shows(t, u8.[0x7f], "␡", 1, "DEL is a control too; its picture shows")
    return .Ok
}

invisible_and_bidirectional_characters_are_written_out #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    expect_shows(t, u8.[0xc2, 0x9b], "⟨U+009B⟩", 8, "a C1 control (CSI) has no picture, so it's written out")
    expect_shows(t, u8.[0xe2, 0x80, 0xae], "⟨U+202E⟩", 8, "RIGHT-TO-LEFT OVERRIDE could reorder what follows")
    expect_shows(t, u8.[0xe2, 0x80, 0x8b], "⟨U+200B⟩", 8, "a ZERO WIDTH SPACE is invisible, a cluster of its own")
    expect_shows(t, u8.[0x61, 0xe2, 0x80, 0x8d], "a⟨U+200D⟩", 9, "a ZWJ after a letter is in its cluster, not an emoji's")
    expect_shows(t, u8.[0xf3, 0xa0, 0x80, 0xa1], "⟨U+E0021⟩", 9, "a tag character is invisible")
    return .Ok
}

emoji_keep_their_joiners_and_selectors #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    family :: string_bytes("👨‍👩‍👧")
    expect_shows(t, family, "👨‍👩‍👧", 2, "a ZWJ sequence is one emoji, its joiners kept")
    expect_shows(t, u8.[0xe2, 0x9d, 0xa4, 0xef, 0xb8, 0x8f], "❤️", 2, "a variation selector gives the heart emoji presentation")
    return .Ok
}

bytes_that_are_not_utf8_become_replacement_characters #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    expect_shows(t, u8.[0xff], "�", 1, "0xff is never UTF-8, so it's U+FFFD")
    return .Ok
}
