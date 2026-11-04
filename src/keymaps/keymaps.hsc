/**
 * Keyboard layouts (decisions/0136, 0138, 0150): what a key, by its USB HID usage (page 7), types with and without
 * shift. The input service types through one, which the login screen lets be chosen. A layout is data, a table of the
 * main block's keys, so another is a table more.
 */
package keymaps

/** The first usage a layout's table covers: A (0x04), the start of the main block's printing keys. */
FIRST_USAGE : u16 : 0x04
/** The last usage a layout's table covers: slash (0x38), the end of the main block's printing keys. */
LAST_USAGE : u16 : 0x38
/** Enter's usage, which types a line break on every layout. */
USAGE_ENTER : u16 : 0x28
/** Escape's usage, which types nothing; it's known by its usage. */
USAGE_ESCAPE : u16 : 0x29
/** Backspace's usage, which types nothing; it's known by its usage. */
USAGE_BACKSPACE : u16 : 0x2a
/** Tab's usage, which types a tab on every layout. */
USAGE_TAB : u16 : 0x2b
/** The space bar's usage. */
USAGE_SPACE : u16 : 0x2c
/** The ISO keyboard's key beside left shift, outside the table: a backslash, shifted a bar, on both layouts. */
USAGE_NON_US_BACKSLASH : u16 : 0x64
/** How many keys a layout's table has, one for each usage from FIRST_USAGE to LAST_USAGE. */
KEYS :: 53

/** A keyboard layout: what each key of the main block types, with and without shift. */
Keymap :: struct {
    /** Its name, lowercase, as find and next take it and a configuration names it, like "us". */
    name : string,
    /** What it's called on the status line, like "US". */
    title : string,
    /**
     * What each key types without shift, from FIRST_USAGE to LAST_USAGE, in UTF-8: "" for a key that types nothing
     * from the table, like Enter.
     */
    plain : string[KEYS],
    /** What each key types with shift, as plain is laid out. */
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
 * The UK layout: as the US one but for shifted 2 and 3, the quote key's shift, grave's shift, and hash and tilde by
 * Enter.
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

/**
 * Find a layout by its name.
 *
 * @param name The layout's name, as Keymap's name has it; it's compared exactly, so case matters.
 * @return The layout, or null if none has that name.
 */
find :: fn(name: string) -> Keymap? {
    for layout in LAYOUTS {
        if layout.name == name {
            return layout
        }
    }
    return null
}

/**
 * Give the layout after one, in LAYOUTS' order, as the login screen goes through them.
 *
 * @param name The current layout's name.
 * @return The layout after it, going round to the first after the last; the first, too, for a name no layout has.
 */
next :: fn(name: string) -> Keymap {
    for layout, i in LAYOUTS {
        if layout.name == name {
            return LAYOUTS[(i + 1) % LAYOUTS.count]
        }
    }
    return LAYOUTS[0]
}

/**
 * Tell what a key types on a layout.
 *
 * Enter types a line break and Tab a tab, and the ISO key beside left shift a backslash, on every layout; Escape and
 * Backspace type nothing, and are known by their usage.
 *
 * @param keymap The layout, one of LAYOUTS as find or next gives it; its tables are only read. Enter, Tab, Escape,
 *     Backspace and the ISO backslash key don't look at it.
 * @param usage The key, by its USB HID usage on the keyboard page (7).
 * @param shifted Whether shift is held.
 * @return The bytes of its text, UTF-8, a static string; empty for a key that types nothing, or one outside the
 *     layout's table.
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

/**
 * Tell which digit a key types without shift, as a keyboard's code is typed with.
 *
 * @param keymap The layout, one of LAYOUTS as find or next gives it, whose unshifted table says where the digits are.
 * @param usage The key, by its USB HID usage on the keyboard page (7).
 * @return The digit, 0 to 9, or null if the key doesn't type one without shift.
 */
digit_of :: fn(keymap: Keymap, usage: u16) -> u32? {
    bytes :: string_bytes(typed(keymap, usage, false))
    if bytes.count == 1 && bytes[0] >= cast[u8]('0') && bytes[0] <= cast[u8]('9') {
        return cast[u32](bytes[0] - cast[u8]('0'))
    }
    return null
}
