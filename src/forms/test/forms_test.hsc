/**
 * forms' tests, a test program (tools/unit_tests.py, decisions/0175): what a form's field gives the shell bare, and
 * what it quotes, so a value typed in a field is read as that field's value and nothing more.
 */
package forms_test

import testing from "std:testing"
import forms from ".."

/** Numbers, paths and plain names go bare, as the shell reads them as they are. */
gives_numbers_and_paths_bare #test :: fn(t : ptr[mut testing.T]) -> testing.Outcome {
    for value in string.["42", "-3", "1.5", "notes.txt", "a/b/c", "~/x", "user@host", "12:30", "x+y", "a_b-c"] {
        // ~ isn't bare: it starts a home path only where the shell says so
        bare :: value != "~/x"
        testing.expect(t, forms.is_plain_word(string_bytes(value)) == bare, value)
    }
    return .Ok
}

/**
 * What would be read as something else is quoted: a comment, a try, a keyword alone or before a dot, a flag, an
 * expression's start, spaces and control characters, and text that isn't ASCII.
 */
quotes_what_the_shell_would_read_otherwise #test :: fn(t : ptr[mut testing.T]) -> testing.Outcome {
    for value in string.[
        "",
        "#rest",
        "?x",
        "or",
        "or.txt",
        "true",
        "null",
        "try",
        "--force",
        "a b",
        "$x",
        "(1)",
        "[a]; rm",
        "a;b",
        "a|b",
        "x\"y",
        "back\\slash",
        "tab\there",
        "café"
    ] {
        testing.expect(t, !forms.is_plain_word(string_bytes(value)), value)
    }
    return .Ok
}
