/**
 * Forms from manifests (decisions/0192, 15g): a program's parameters as a form, the GUI's way to give what the shell's
 * command line gives (design/shell.md §8, display.md §6). Each parameter the shell takes from an argument is a field:
 * a bool a check box, anything else a text field read as the shell reads a bare word or a quoted string, labelled with
 * its name and its type as the shell names it. Those the shell gives without asking (its terminal, here, the powerbox,
 * the network, a pipeline's input and output) aren't asked for. What's filled in becomes a command line for the shell,
 * which reads it as it reads one typed, so a form can give no more than the shell would.
 */
package forms

import runtime from "base:runtime"
import schema from "std:schema"
import ui from "std:ui"
import shell_language as language from "../shell_language"

/** The most fields a form has; a program's parameters past them aren't asked for. */
MAX_FIELDS :: 16
/** The most bytes of a parameter's name, or a program's, kept; a longer one is cut. */
NAME_BYTES :: 64
/** The most bytes of a field's hint: its type, and an enum's members. */
HINT_BYTES :: 160

/** What a field asks for. */
FieldKind :: enum {
    /** Text, read as the shell reads an argument: a bare word by its type, or a string. */
    Text,
    /** A bool: given as --name alone when it's checked, and not at all when it isn't. */
    Flag,
}

/** A parameter asked for. */
Field :: struct {
    /** The parameter's name, the first name_count bytes, as the manifest has it. */
    name : u8[NAME_BYTES],
    /** How many bytes of name. */
    name_count : usize,
    /**
     * What it takes, as the shell names a type, with an enum's members, and ", needed" when it can't be left empty; the
     * first hint_count bytes.
     */
    hint : u8[HINT_BYTES],
    /** How many bytes of hint. */
    hint_count : usize,
    /** What it asks for. */
    kind : FieldKind,
    /** Whether it may be left empty: an optional's, or a bool's. */
    optional : bool,
    /** Whether its text is given as it's typed, in the shell's own syntax, as a list's is: [a, b]. */
    raw : bool,
    /** A Text field's text, edited by std/ui's text field, on the heap; freed by free_form. */
    text : u8[..],
    /** A Flag field's value. */
    checked : bool,
}

/** A program's form: its name, and a field for each parameter it's asked for. */
Form :: struct {
    /** The program's name, the first program_count bytes. */
    program : u8[NAME_BYTES],
    /** How many bytes of program. */
    program_count : usize,
    /** Its fields, the first field_count, in the entry's order. */
    fields : Field[MAX_FIELDS],
    /** How many fields. */
    field_count : usize,
    /**
     * Whether it needs a grant the shell can't make from a path (one of its parameters isn't optional and is Other), so
     * the shell would refuse it however it's filled in.
     */
    unfit : bool,
}

/**
 * Make a program's form from its manifest.
 *
 * @param manifest The program's manifest, its entry the type at place 0; only read, and nothing of it kept, so it can
 *     be freed after.
 * @param program The program's name, as the shell runs it; copied, cut at NAME_BYTES.
 * @return The form, its fields empty and unchecked; null if the manifest's first type isn't an entry's (a function).
 */
form_of :: fn(manifest : ptr[schema.Schema], program : u8[]) -> Form? {
    entry :: schema.type_in(manifest, 0) or_return null
    if entry.kind != .Function {
        return null
    }
    form := Form.{}
    form.program_count = copy_into(&form.program, program)
    for input in entry.inputs {
        held := input.type
        optional := false
        match language.some_of(manifest, input.type) {
            case Some(inner) => {
                held = inner
                optional = true
            }
            case None => {}
        }
        giving :: language.giving_of(manifest, held)
        asked :: giving == .Value
            || (giving == .Dir && input.name != "here")
            || giving == .File
            || giving == .ReadOnlyFile
        if !asked {
            if giving == .Other && !optional {
                form.unfit = true
            }
            continue
        }
        if form.field_count >= form.fields.count {
            break
        }
        field := Field.{optional = optional}
        field.name_count = copy_into(&field.name, string_bytes(input.name))
        type :: schema.type_in(manifest, schema.unaliased_place(manifest, held))
        is_bool :: match type {
            case Some(found) => found.kind == .Boolean
            case None => false
        }
        if giving == .Value && is_bool {
            field.kind = .Flag
            field.optional = true
        }
        hint :: match giving {
            case .Dir => "a directory's path"
            case .File => "a file's path"
            case .ReadOnlyFile => "a file's path, read"
            case _ => language.type_text(manifest, held)
        }
        field.hint_count = copy_into(&field.hint, string_bytes(hint))
        match type {
            case Some(found) => if found.kind == .Array {
                field.raw = true
                field.hint_count += copy_into_at(&field.hint, field.hint_count, string_bytes(", as [a, b]"))
            }
            else if found.kind == .Enum && found.constants.count > 0 {
                field.hint_count += copy_into_at(&field.hint, field.hint_count, string_bytes(": "))
                field.hint_count += copy_into_at(
                    &field.hint,
                    field.hint_count,
                    string_bytes(language.members_text(found))
                )
            }
            case None => {}
        }
        if !field.optional {
            field.hint_count += copy_into_at(&field.hint, field.hint_count, string_bytes(", needed"))
        }
        if form.field_count < form.fields.count {
            form.fields[form.field_count] = field
            form.field_count += 1
        }
    }
    return form
}

/**
 * Let go of what a form holds: its fields' text.
 *
 * @param form The form, whose fields' text is freed and emptied; it can be shown again, empty.
 */
free_form :: fn(form : ptr[mut Form]) {
    for i in cast[usize](0)..<form.fields.count {
        runtime.array_free(&form.fields[i].text)
    }
}

/**
 * Show a form: a row for each field, its name and what it takes over a check box or a text field, and a Run button.
 *
 * @param u The UI, inside a node the form's laid out in, top to bottom.
 * @param form The form, whose fields std/ui's widgets edit.
 * @return Whether Run was clicked this frame; never while the form's unfit, when it says why in place of the button.
 */
show_form :: fn(u : ptr[mut ui.Ui], form : ptr[mut Form]) -> bool {
    if form.field_count == 0 {
        _ = ui.label(u, "It takes nothing to be asked for.")
    }
    for i in cast[usize](0)..<form.fields.count {
        if i >= form.field_count {
            break
        }
        field :: &form.fields[i]
        name :: text_of(filled(&field.name, field.name_count))
        hint :: text_of(filled(&field.hint, field.hint_count))
        _ = ui.open(u, "field", ui.Box.{width = ui.grow(), gap = 4, key = cast[u64](i)})
        match field.kind {
            case .Flag => _ = ui.checkbox(u, name, &field.checked, key = cast[u64](i))
            case .Text => {
                _ = ui.label(u, name, ui.TextStyle.{size = 15})
                _ = ui.text_field(u, name, &field.text, key = cast[u64](i))
            }
        }
        _ = ui.label(u, hint, ui.TextStyle.{size = 12})
        ui.close(u)
    }
    if form.unfit {
        _ = ui.label(u, "It needs something the shell can't give from a form.")
        return false
    }
    return ui.button(u, "Run")
}

/**
 * Make the command line a form's filled in as: the program's name, then --name and its value for each field that's
 * filled in, and --name alone for each check box that's checked. A value that's a word the shell reads bare (no
 * spaces, quotes, $ or the shell's punctuation) is given bare, so a number, size, duration or enum member is read by
 * its type; any other is given as a string, its " \ and $ escaped.
 *
 * @param form The form; only read.
 * @return The command line, on the heap, the caller's to free (runtime.free_array of its bytes); empty fields aren't
 *     given, so the shell says which needed one's missing.
 */
command_line :: fn(form : ptr[Form]) -> string {
    line : u8[..]
    add_bytes(&line, program_of(form))
    for i in cast[usize](0)..<form.fields.count {
        if i >= form.field_count {
            break
        }
        field :: &form.fields[i]
        given :: match field.kind {
            case .Flag => field.checked
            case .Text => field.text.count > 0
        }
        if !given {
            continue
        }
        add_bytes(&line, string_bytes(" --"))
        // As the shell matches --name, a _ typed as a -
        for byte in filled(&field.name, field.name_count) {
            runtime.array_add(&line, if byte == cast[u8]('_') { cast[u8]('-') } else { byte })
        }
        if field.kind == .Text {
            runtime.array_add(&line, cast[u8](' '))
            if field.raw {
                add_bytes(&line, ui.contents(&field.text))
            }
            else {
                add_argument(&line, ui.contents(&field.text))
            }
        }
    }
    if line.count == 0 {
        return ""
    }
    return string_of(&line[0], line.count)
}

/**
 * Add a value to a command line as the shell reads it: bare if it's a plain word, else a quoted string.
 *
 * @param line The command line, grown.
 * @param value The value's bytes, UTF-8, as typed.
 */
add_argument :: fn(line : ptr[mut u8[..]], value : u8[]) {
    if is_plain_word(value) {
        add_bytes(line, value)
        return void
    }
    runtime.array_add(line, cast[u8]('"'))
    for byte in value {
        if byte == cast[u8]('"') || byte == cast[u8]('\\') || byte == cast[u8]('$') {
            runtime.array_add(line, cast[u8]('\\'))
        }
        // A line break can't be typed in a field, but one pasted is given as \n
        if byte == 10 {
            add_bytes(line, string_bytes("\\n"))
            continue
        }
        runtime.array_add(line, byte)
    }
    runtime.array_add(line, cast[u8]('"'))
}

/**
 * Tell whether a value is a word the shell reads bare, as a number or a path is: only ASCII letters, digits and
 * _ . / : + @ -, not starting with --, and not a keyword, alone or ahead of a dot (or.txt reads as or). Anything else
 * is
 * quoted, which the shell reads as text whatever it holds, so a value can't start a comment (#), make the line a try
 * (?), or end the word for something after it.
 *
 * @param value The value's bytes.
 * @return True if it can be given bare.
 */
is_plain_word :: fn(value : u8[]) -> bool {
    if value.count == 0 {
        return false
    }
    if value.count >= 2 && value[0] == cast[u8]('-') && value[1] == cast[u8]('-') {
        return false
    }
    for byte in value {
        letter :: (byte >= cast[u8]('a') && byte <= cast[u8]('z')) || (byte >= cast[u8]('A') && byte <= cast[u8]('Z'))
        digit :: byte >= cast[u8]('0') && byte <= cast[u8]('9')
        other :: byte == cast[u8]('_')
            || byte == cast[u8]('.')
            || byte == cast[u8]('/')
            || byte == cast[u8](':')
            || byte == cast[u8]('+')
            || byte == cast[u8]('@')
            || byte == cast[u8]('-')
        if !letter && !digit && !other {
            return false
        }
    }
    // The word before any dot, which the shell may read as a keyword
    word_end := value.count
    for byte, i in value {
        if byte == cast[u8]('.') && word_end == value.count {
            word_end = i
        }
    }
    word :: value[0..<word_end]
    for keyword in KEYWORDS {
        if same_bytes(word, string_bytes(keyword)) {
            return false
        }
    }
    return true
}

/** The shell's keywords, and the names it reads as values, which a bare word mustn't be. */
KEYWORDS :: string.["catch", "false", "fn", "let", "not", "null", "or", "param", "return", "true", "try"]

/** Tell whether two byte slices hold the same bytes. */
same_bytes :: fn(a : u8[], b : u8[]) -> bool {
    if a.count != b.count {
        return false
    }
    for byte, i in a {
        if i >= b.count || b[i] != byte {
            return false
        }
    }
    return true
}

/** Add bytes to the end of an array. */
add_bytes :: fn(line : ptr[mut u8[..]], bytes : u8[]) {
    for byte in bytes {
        runtime.array_add(line, byte)
    }
}

/**
 * Copy bytes into a fixed buffer from its start, cut at its end.
 *
 * @return How many were copied.
 */
copy_into :: fn[N : usize](into : ptr[mut u8[N]], bytes : u8[]) -> usize {
    return copy_into_at(into, 0, bytes)
}

/**
 * Copy bytes into a fixed buffer from an offset, cut at its end.
 *
 * @return How many were copied; 0 for an offset past its end.
 */
copy_into_at :: fn[N : usize](into : ptr[mut u8[N]], at : usize, bytes : u8[]) -> usize {
    copied := cast[usize](0)
    for byte in bytes {
        if at + copied >= into.count {
            break
        }
        into[at + copied] = byte
        copied += 1
    }
    return copied
}

/**
 * The bytes of a fixed buffer that are filled.
 *
 * @param bytes The buffer.
 * @param count How many of its bytes, from its start, are filled; past its end, all of it.
 * @return A view of the first count bytes.
 */
filled :: fn[N : usize](bytes : ptr[u8[N]], count : usize) -> u8[] {
    kept :: bytes[0..<N]
    return if count <= kept.count { kept[0..<count] } else { kept }
}

/** A form's program's name, a view of it. */
program_of :: fn(form : ptr[Form]) -> u8[] {
    return filled(&form.program, form.program_count)
}

/** Bytes as text, a view of them. */
text_of :: fn(bytes : u8[]) -> string {
    return if bytes.count > 0 { string_of(&bytes[0], bytes.count) } else { "" }
}
