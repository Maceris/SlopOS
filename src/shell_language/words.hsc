package shell_language

/*
 * Bare words read by a shell function's parameter's type, and the types a parameter can have.
 */

/** The types a function's parameters can have. */
TYPE_NAMES :: string.["int", "size", "duration", "bool", "string", "path", "list", "record"]

/**
 * Read a bare word as a parameter's type: a number, a size or a duration as they're written in expressions, a bool,
 * or text.
 *
 * @param type The type's name, "" for any; for any, string, list and record the word is text, and for path a path.
 * @param word The word, as written.
 * @return The value; null if the word isn't one of the type, like a bool other than true or false. For int, size and
 *     duration, any number literal is given, of whatever kind it is, for the caller to check.
 */
word_as :: fn(type: string, word: string) -> Value? {
    if type == "" || type == "string" || type == "list" || type == "record" {
        return .Text(word)
    }
    if type == "path" {
        return .Path(word)
    }
    if type == "bool" {
        return if word == "true" { Value.Bool(true) } else if word == "false" { Value.Bool(false) } else { null }
    }
    // A number, with its unit if it has one, read as a literal
    match parse(word) {
        case Ok(tree) => {
            literal :: first_child(tree) or_return null
            if literal.kind != .Literal || tree.children.count != 1 {
                return null
            }
            return literal.value
        }
        case Error(error) => return null
    }
}

/**
 * Tell whether a value is of a parameter's type: text and a path are each of the other's type, and anything is of no
 * type.
 *
 * @param type The type's name, "" for any; a name not in TYPE_NAMES takes nothing.
 * @param value The value checked; only its kind is looked at, so any Int is an int and any list a list.
 * @return True if the parameter takes it; Null is taken only by "", any type.
 */
of_type :: fn(type: string, value: Value) -> bool {
    return match value {
        case Null => type == ""
        case Bool(_) => type == "" || type == "bool"
        case Int(_) => type == "" || type == "int"
        case Size(_) => type == "" || type == "size"
        case Duration(_) => type == "" || type == "duration"
        case Text(_) => type == "" || type == "string" || type == "path"
        case Path(_) => type == "" || type == "path" || type == "string"
        case List(_) => type == "" || type == "list"
        case Record(_) => type == "" || type == "record"
        case Handle(handle) => type == "" || type == handle_type(handle.kind)
    }
}

/**
 * Name a handle's kind as a script's parameter's type is written.
 *
 * @param kind The kind.
 * @return "Dir", "File" or "ReadOnlyFile".
 */
handle_type :: fn(kind: HandleKind) -> string {
    return match kind {
        case .Dir => "Dir"
        case .File => "File"
        case .ReadOnlyFile => "ReadOnlyFile"
    }
}

/**
 * Make text a path.
 *
 * @param value Any value; a Text's string is shared by the Path made, not copied.
 * @return A Path of the same text for Text; any other value as it is.
 */
as_path :: fn(value: Value) -> Value {
    return match value {
        case Text(text) => Value.Path(text)
        case _ => value
    }
}

/**
 * Name what a parameter's type takes, as errors say it.
 *
 * @param type The type's name, one of TYPE_NAMES or a script's handle's (Dir, File, ReadOnlyFile), or "" for any; any
 *     other name is said as "text".
 * @return Its name with an article, like "an integer"; "text" for string, any or an unknown name.
 */
type_article :: fn(type: string) -> string {
    return if type == "int" { "an integer" } else if type == "size" { "a size" } else if type == "duration" { "a duration" }
        else if type == "bool" { "true or false" } else if type == "path" { "a path" } else if type == "list" { "a list" }
        else if type == "record" { "a record" } else if type == "Dir" { "a directory" } else if type == "File" { "a file" }
        else if type == "ReadOnlyFile" { "a file to read" } else { "text" }
}
