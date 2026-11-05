/**
 * The keymaps' tests, a test program (tools/unit_tests.py, decisions/0175). The US layout types letters, digits and
 * punctuation with and without shift, Enter and Tab their characters, and Escape and Backspace nothing; the UK layout
 * its own shifted keys, £ among them; and the layouts go round.
 */
package keymaps_test

import testing from "std"
import keymaps from ".."

the_us_layout_types_letters_and_digits #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    us :: testing.require_some(t, keymaps.find("us"), "the US layout is one of the keymaps")?
    testing.expect_eq(t, keymaps.typed(us, 0x04, false), "a", "usage 0x04 is A, lower case without shift")
    testing.expect_eq(t, keymaps.typed(us, 0x1d, true), "Z", "usage 0x1d is Z, upper case with shift")
    testing.expect_eq(t, keymaps.typed(us, 0x1e, false), "1", "usage 0x1e is the 1 key")
    testing.expect_eq(t, keymaps.typed(us, 0x1e, true), "!", "shifted 1 is ! on a US keyboard")
    testing.expect_eq(t, keymaps.typed(us, 0x27, false), "0", "usage 0x27 is the 0 key, after 9")
    return .Ok
}

the_us_layout_types_space_and_punctuation #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    us :: testing.require_some(t, keymaps.find("us"), "the US layout is one of the keymaps")?
    testing.expect_eq(t, keymaps.typed(us, 0x2c, false), " ", "usage 0x2c is the space bar")
    testing.expect_eq(t, keymaps.typed(us, 0x38, true), "?", "shifted / is ? on a US keyboard")
    testing.expect_eq(t, keymaps.typed(us, 0x34, true), "\"", "shifted ' is \" on a US keyboard")
    testing.expect_eq(t, keymaps.typed(us, 0x64, false), "\\", "the ISO key by left shift is backslash on the US layout")
    return .Ok
}

control_keys_type_their_characters_or_nothing #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    us :: testing.require_some(t, keymaps.find("us"), "the US layout is one of the keymaps")?
    testing.expect_eq(t, keymaps.typed(us, 0x28, false), "\n", "Enter types a newline")
    testing.expect_eq(t, keymaps.typed(us, 0x2b, false), "\t", "Tab types a tab")
    testing.expect_eq(t, keymaps.typed(us, 0x29, false), "", "Escape types nothing; the terminal handles it")
    testing.expect_eq(t, keymaps.typed(us, 0x2a, false), "", "Backspace types nothing; the line editor handles it")
    testing.expect_eq(t, keymaps.typed(us, 0x4f, false), "", "the right arrow is outside the typing table")
    return .Ok
}

digit_of_gives_only_digits #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    us :: testing.require_some(t, keymaps.find("us"), "the US layout is one of the keymaps")?
    three :: testing.require_some(t, keymaps.digit_of(us, 0x20), "usage 0x20 is the 3 key, a digit")?
    testing.expect_eq(t, three, 3, "usage 0x20 is the 3 key")
    testing.expect_none(t, keymaps.digit_of(us, 0x04), "the A key isn't a digit")
    return .Ok
}

find_finds_only_layouts_that_exist #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    testing.expect(t, keymaps.find("dvorak") is_none, "there's no Dvorak layout")
    return .Ok
}

the_uk_layout_types_its_own_keys #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    uk :: testing.require_some(t, keymaps.find("uk"), "the UK layout is one of the keymaps")?
    testing.expect_eq(t, keymaps.typed(uk, 0x1f, true), "\"", "shifted 2 is \" on a UK keyboard")
    testing.expect_eq(t, keymaps.typed(uk, 0x20, true), "£", "shifted 3 is £ on a UK keyboard")
    testing.expect_eq(t, keymaps.typed(uk, 0x34, true), "@", "shifted ' is @ on a UK keyboard")
    testing.expect_eq(t, keymaps.typed(uk, 0x32, false), "#", "the key by Enter is # on a UK keyboard")
    testing.expect_eq(t, keymaps.typed(uk, 0x32, true), "~", "shifted, the key by Enter is ~ on a UK keyboard")
    testing.expect_eq(t, keymaps.typed(uk, 0x04, false), "a", "letters are where they are on the US layout")
    testing.expect_eq(t, keymaps.typed(uk, 0x64, true), "|", "the ISO key by left shift is | shifted on the UK layout")
    return .Ok
}

the_layouts_go_round #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    testing.expect_eq(t, keymaps.next("us").name, "uk", "the UK layout follows the US one")
    testing.expect_eq(t, keymaps.next("uk").name, "us", "the US layout follows the UK one, the last, going round")
    return .Ok
}
