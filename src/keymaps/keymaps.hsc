/**
 * Keyboard layouts (decisions/0136, 0138, 0150): what a key, by its USB HID usage (page 7), types with and without
 * shift. The input service types through one, which the login screen lets be chosen. A layout is data, a table of the
 * main block's keys, so another is a table more.
 */
package keymaps

// The usages a layout's table covers: from A (0x04) to slash (0x38), the main block's printing keys
FIRST_USAGE : u16 : 0x04
LAST_USAGE : u16 : 0x38
USAGE_ENTER : u16 : 0x28
USAGE_ESCAPE : u16 : 0x29
USAGE_BACKSPACE : u16 : 0x2a
USAGE_TAB : u16 : 0x2b
USAGE_SPACE : u16 : 0x2c
// The ISO keyboard's key beside left shift, outside the table: a backslash on both layouts
USAGE_NON_US_BACKSLASH : u16 : 0x64
KEYS :: 53

Keymap :: struct {
    name : string,
    /** What it's called on the status line */
    title : string,
    // From FIRST_USAGE to LAST_USAGE, what each types, then with shift, UTF-8: "" for a key that types nothing
    plain : string[KEYS],
    shifted : string[KEYS],
}

/**
 * The US layout. From 0x04: a to z, 1 to 0, Enter, Escape, Backspace, Tab, Space, then minus to slash (0x2d to 0x38),
 * where 0x32, the non-US hash key, types what an ISO layout's does. Enter, Escape, Backspace and Tab are typed by
 * typed, not the table.
 */
US :: Keymap.{name = "us", title = "US",
    plain = string.["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v",
        "w", "x", "y", "z", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "", "", "", "", " ", "-", "=", "[", "]", "\\", "#",
        ";", "'", "`", ",", ".", "/"],
    shifted = string.["A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V",
        "W", "X", "Y", "Z", "!", "@", "#", "$", "%", "^", "&", "*", "(", ")", "", "", "", "", " ", "_", "+", "{", "}", "|", "~",
        ":", "\"", "~", "<", ">", "?"]}

/**
 * The UK layout: as the US one but for shifted 2 and 3, the quote key's shift, grave's shift, and hash and tilde by Enter.
 */
UK :: Keymap.{name = "uk", title = "UK",
    plain = string.["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v",
        "w", "x", "y", "z", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "", "", "", "", " ", "-", "=", "[", "]", "#", "#",
        ";", "'", "`", ",", ".", "/"],
    shifted = string.["A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V",
        "W", "X", "Y", "Z", "!", "\"", "£", "$", "%", "^", "&", "*", "(", ")", "", "", "", "", " ", "_", "+", "{", "}", "~", "~",
        ":", "@", "¬", "<", ">", "?"]}

/** Every layout, in the order the login screen goes through them. */
LAYOUTS :: Keymap.[US, UK]

/** The layout named name, or null. */
find :: fn(name: string) -> Keymap? {
    for layout in LAYOUTS {
        if layout.name == name {
            return layout
        }
    }
    return null
}

/** The layout after the one named name, going round; the first for a name that isn't one. */
next :: fn(name: string) -> Keymap {
    for layout, i in LAYOUTS {
        if layout.name == name {
            return LAYOUTS[(i + 1) % LAYOUTS.count]
        }
    }
    return LAYOUTS[0]
}

/**
 * What a key types on keymap: the bytes of its text (UTF-8), or none for one that types nothing. Enter types a line
 * break and Tab a tab; Escape and Backspace type nothing, and are known by their usage.
 */
typed :: fn(keymap: Keymap, usage: u16, shifted: bool) -> string {
    if usage == USAGE_ENTER {
        return "\n"
    }
    if usage == USAGE_TAB {
        return "\t"
    }
    if usage == USAGE_NON_US_BACKSLASH {
        return if shifted { "|" } else { "\\" }
    }
    if usage == USAGE_ESCAPE || usage == USAGE_BACKSPACE || usage < FIRST_USAGE || usage > LAST_USAGE {
        return ""
    }
    index :: cast[usize](usage - FIRST_USAGE)
    table :: if shifted { keymap.shifted } else { keymap.plain }
    return if index < table.count { table[index] } else { "" }
}

/** The digit a key types without shift, or null: what a keyboard's code is typed with. */
digit_of :: fn(keymap: Keymap, usage: u16) -> u32? {
    bytes :: string_bytes(typed(keymap, usage, false))
    if bytes.count == 1 && bytes[0] >= cast[u8]('0') && bytes[0] <= cast[u8]('9') {
        return cast[u32](bytes[0] - cast[u8]('0'))
    }
    return null
}
