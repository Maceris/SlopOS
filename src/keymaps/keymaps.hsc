/*
 * Keyboard layouts (decisions/0136, 0138): what a key, by its USB HID usage (page 7), types with and without shift. The
 * input service types through one; 10c's login screen lets the layout be chosen. A layout is data, a table of the
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

Keymap :: struct {
    name : string,
    // From FIRST_USAGE to LAST_USAGE, what each types, then with shift: 0 for a key that types nothing
    plain : string,
    shifted : string,
}

/*
 * The US layout. From 0x04: a to z, 1 to 0, Enter, Escape, Backspace, Tab, Space, then minus to slash (0x2d to 0x38),
 * where 0x32, the non-US hash key, types what an ISO layout's does. Enter, Escape, Backspace and Tab are filled in by
 * typed, not the table, so they're spaces here.
 */
US :: Keymap.{name = "us",
    plain = "abcdefghijklmnopqrstuvwxyz1234567890     -=[]\\#;'`,./",
    shifted = "ABCDEFGHIJKLMNOPQRSTUVWXYZ!@#$%^&*()     _+{}|~:\"~<>?"}

// The layout named name, or null.
find :: fn(name: string) -> Keymap? {
    if name == US.name {
        return US
    }
    return null
}

/*
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
    if usage == USAGE_ESCAPE || usage == USAGE_BACKSPACE || usage < FIRST_USAGE || usage > LAST_USAGE {
        return ""
    }
    table :: if shifted { keymap.shifted } else { keymap.plain }
    index :: cast[usize](usage - FIRST_USAGE)
    if index >= table.count {
        return ""
    }
    // Space stands for itself only at Space's own place
    if table[index] == ' ' && usage != USAGE_SPACE {
        return ""
    }
    return table[index..<index + 1]
}

// The digit a key types without shift, or null: what a keyboard's code is typed with.
digit_of :: fn(keymap: Keymap, usage: u16) -> u32? {
    bytes :: string_bytes(typed(keymap, usage, false))
    if bytes.count == 1 && bytes[0] >= cast[u8]('0') && bytes[0] <= cast[u8]('9') {
        return cast[u32](bytes[0] - cast[u8]('0'))
    }
    return null
}
