package shell

import runtime from "base"
import strings from "std"
import text_buffer from "std"

/*
 * Evaluating the shell language: each statement's tree to a value, or an error that stops what follows (design/shell.md
 * §5) unless `or { ... }` handles it. Names are the shell's own, bound by let, never given to programs.
 */

/**
 * An error, and where in the line it is. One a shell function's body met in a statement without ? is fatal once it
 * leaves the function: it ends what's running, and nothing handles it (design/shell.md §5); ? marks it passed, the
 * function's own error, which its caller can handle. A return is carried out of the function's body as one too.
 */
EvalError :: struct {
    message : string,
    at : usize,
    fatal : bool,
    passed : bool,
    returning : bool,
}

/** The shell's names and their values: a function's call has its own, in the scope it was called from. */
Scope :: struct {
    names : string[..],
    values : Value[..],
    parent : ptr[Scope]?,
}

lookup :: fn(scope: ptr[Scope], name: string) -> Value? {
    for each, i in scope.names {
        if each == name && i < scope.values.count {
            return scope.values[i]
        }
    }
    match scope.parent {
        case Some(outer) => return lookup(outer, name)
        case None => return null
    }
}

/** Whether an error is one or and try/catch handle: not a fatal one, and not a return. */
handles :: fn(error: EvalError) -> bool {
    return !error.fatal && !error.returning
}

bind :: fn(scope: ptr[mut Scope], name #escaping : string, value #escaping : Value) {
    for each, i in scope.names {
        if each == name && i < scope.values.count {
            scope.values[i] = value
            return void
        }
    }
    runtime.array_add(&scope.names, name)
    runtime.array_add(&scope.values, value)
}

error_at :: fn(at: usize, message: string) -> Result[Value, EvalError] {
    return .Error(EvalError.{message = message, at = at})
}

/** A message with values put in for each %, as the shell's errors say what they found. */
message :: fn(format: string, values: any...) -> string {
    return strings.format(format, values) or_else format
}

evaluate :: fn(shell: ptr[mut Shell], tree #escaping : ptr[Node]) -> Result[Value, EvalError] {
    match tree.kind {
        case .Statements => {
            last := Value.Null
            for child in tree.children {
                last = evaluate(shell, child)?
            }
            return .Ok(last)
        }
        case .Let => {
            value :: evaluate(shell, first_child(tree) or_return error_at(tree.at, "let needs a value"))?
            bind(shell.scope, tree.text, value)
            return .Ok(.Null)
        }
        case .Pipeline => return pipeline(shell, tree)
        case .Try => {
            match evaluate(shell, first_child(tree) or_return error_at(tree.at, "? needs something before it")) {
                case Ok(value) => return .Ok(value)
                case Error(error) => {
                    passed := error
                    passed.passed = true
                    return .Error(passed)
                }
            }
        }
        case .Or => {
            handled :: child(tree, 0) or_return error_at(tree.at, "or needs something before it")
            handler :: child(tree, 1) or_return error_at(tree.at, "or needs a block")
            match evaluate(shell, handled) {
                case Ok(value) => return .Ok(value)
                case Error(error) => {
                    if !handles(error) {
                        return .Error(error)
                    }
                    return evaluate(shell, handler)
                }
            }
        }
        case .TryCatch => {
            tried :: child(tree, 0) or_return error_at(tree.at, "try needs a block")
            handler :: child(tree, 1) or_return error_at(tree.at, "try needs catch and a block")
            match evaluate(shell, tried) {
                case Ok(value) => return .Ok(value)
                case Error(error) => {
                    if !handles(error) {
                        return .Error(error)
                    }
                    if tree.text.count > 0 {
                        bind(shell.scope, tree.text, error_record(error))
                    }
                    return evaluate(shell, handler)
                }
            }
        }
        case .Function => return define(shell, tree)
        case .Parameter => return error_at(tree.at, "a parameter is a function's")
        case .Return => {
            shell.returned = .Null
            match first_child(tree) {
                case Some(value) => shell.returned = evaluate(shell, value)?
                case None => {}
            }
            return .Error(EvalError.{message = "return is a function's", at = tree.at, returning = true})
        }
        case .Call => return call(shell, tree)
        case .Word => return .Ok(.Text(tree.text))
        case .Named => return error_at(tree.at, message("--% is a call's", tree.text))
        case .Literal => return .Ok(tree.value)
        case .Interpolated => return .Ok(.Text(interpolate(shell, tree.text)))
        case .Variable => {
            found :: lookup(shell.scope, tree.text) or_return error_at(tree.at, message("there's no variable named %", tree.text))
            return .Ok(found)
        }
        case .List => {
            made :: new_list()
            for child in tree.children {
                runtime.array_add(&made.items, evaluate(shell, child)?)
            }
            return .Ok(.List(made))
        }
        case .Record => {
            made :: new_record()
            at : usize = 0
            loop {
                key :: child(tree, at) or_break
                inner :: child(tree, at + 1) or_break
                value :: evaluate(shell, inner)?
                set_field(made, key.text, value)
                at += 2
            }
            return .Ok(.Record(made))
        }
        case .Field => {
            base :: evaluate(shell, first_child(tree) or_return error_at(tree.at, "a field needs a record"))?
            match base {
                case Record(record) => {
                    found :: field(record, tree.text) or_return error_at(tree.at, message("this record has no field %", tree.text))
                    return .Ok(found)
                }
                case _ => return error_at(tree.at, message("% has no fields: it's %", tree.text, type_name(base)))
            }
        }
        case .Index => {
            base :: evaluate(shell, child(tree, 0) or_return error_at(tree.at, "an index needs a value"))?
            index :: evaluate(shell, child(tree, 1) or_return error_at(tree.at, "an index needs a value"))?
            return indexed(tree.at, base, index)
        }
        case .Unary => return unary_value(shell, tree)
        case .Binary => return binary_value(shell, tree)
    }
}

first_child :: fn(tree: ptr[Node]) -> ptr[mut Node]? {
    return child(tree, 0)
}

child :: fn(tree: ptr[Node], index: usize) -> ptr[mut Node]? {
    return if index < tree.children.count { tree.children[index] } else { null }
}

item :: fn(list: ptr[ValueList], index: usize) -> Value? {
    return if index < list.items.count { list.items[index] } else { null }
}

indexed :: fn(at: usize, base: Value, index: Value) -> Result[Value, EvalError] {
    match base {
        case List(list) => match index {
            case Int(position) => {
                found :: (if position < 0 { null } else { item(list, cast[usize](position)) })
                    or_return error_at(at, message("there's no item % in a list of %", position, list.items.count))
                return .Ok(found)
            }
            case _ => return error_at(at, message("a list's index is an integer, not %", type_name(index)))
        }
        case Record(record) => match index {
            case Text(name) => {
                found :: field(record, name) or_return error_at(at, message("this record has no field %", name))
                return .Ok(found)
            }
            case _ => return error_at(at, message("a record's index is a field's name, not %", type_name(index)))
        }
        case _ => {}
    }
    return error_at(at, message("% can't be indexed", type_name(base)))
}

unary_value :: fn(shell: ptr[mut Shell], tree: ptr[Node]) -> Result[Value, EvalError] {
    operand :: evaluate(shell, first_child(tree) or_return error_at(tree.at, "an operator needs a value"))?
    if tree.text == "not" {
        match operand {
            case Bool(truth) => return .Ok(.Bool(!truth))
            case _ => return error_at(tree.at, message("not takes a bool, not %", type_name(operand)))
        }
    }
    match operand {
        case Int(number) => return .Ok(.Int(0 - number))
        case Duration(nanos) => return .Ok(.Duration(0 - nanos))
        case _ => {}
    }
    return error_at(tree.at, message("- takes a number, not %", type_name(operand)))
}

binary_value :: fn(shell: ptr[mut Shell], tree: ptr[Node]) -> Result[Value, EvalError] {
    left_tree :: child(tree, 0) or_return error_at(tree.at, "an operator needs two values")
    right_tree :: child(tree, 1) or_return error_at(tree.at, "an operator needs two values")
    operator :: tree.text
    left :: evaluate(shell, left_tree)?
    // and, or: the right only if the left doesn't decide it
    if operator == "and" || operator == "or" {
        truth :: match left {
            case Bool(found) => found
            case _ => return error_at(tree.at, message("% takes bools, not %", operator, type_name(left)))
        }
        if (operator == "and" && !truth) || (operator == "or" && truth) {
            return .Ok(.Bool(truth))
        }
        right :: evaluate(shell, right_tree)?
        match right {
            case Bool(found) => return .Ok(.Bool(found))
            case _ => return error_at(tree.at, message("% takes bools, not %", operator, type_name(right)))
        }
    }
    right :: evaluate(shell, right_tree)?
    if operator == "==" || operator == "!=" || operator == "<" || operator == "<=" || operator == ">" || operator == ">=" {
        order :: compare(left, right) or_return error_at(tree.at, message("% and % can't be compared", type_name(left), type_name(right)))
        result :: if operator == "==" { order == 0 } else if operator == "!=" { order != 0 } else if operator == "<" { order < 0 }
            else if operator == "<=" { order <= 0 } else if operator == ">" { order > 0 } else { order >= 0 }
        return .Ok(.Bool(result))
    }
    return arithmetic(tree.at, operator, left, right)
}

/** Two values' order: below 0, 0 or above; null if they aren't of a kind with one. */
compare :: fn(left: Value, right: Value) -> int? {
    match left {
        case Int(a) => match right {
            case Int(b) => return if a < b { -1 } else if a > b { 1 } else { 0 }
            case _ => return null
        }
        case Size(a) => match right {
            case Size(b) => return if a < b { -1 } else if a > b { 1 } else { 0 }
            case _ => return null
        }
        case Duration(a) => match right {
            case Duration(b) => return if a < b { -1 } else if a > b { 1 } else { 0 }
            case _ => return null
        }
        case Text(a) => match right {
            case Text(b) => return text_order(a, b)
            case _ => return null
        }
        case Path(a) => match right {
            case Path(b) => return text_order(a, b)
            case _ => return null
        }
        case Bool(a) => match right {
            case Bool(b) => return if a == b { 0 } else if a { 1 } else { -1 }
            case _ => return null
        }
        case Null => match right {
            case Null => return 0
            case _ => return null
        }
        case _ => {}
    }
    return null
}

text_order :: fn(a: string, b: string) -> int {
    left :: string_bytes(a)
    right :: string_bytes(b)
    for byte, i in left {
        if i >= right.count {
            return 1
        }
        if byte != right[i] {
            return if byte < right[i] { -1 } else { 1 }
        }
    }
    return if left.count < right.count { -1 } else { 0 }
}

/** + - * /: integers, sizes and durations of one kind, either scaled by an integer, and strings joined by +. */
arithmetic :: fn(at: usize, operator: string, left: Value, right: Value) -> Result[Value, EvalError] {
    match left {
        case Int(a) => match right {
            case Int(b) => {
                if operator == "/" && b == 0 {
                    return error_at(at, "dividing by zero")
                }
                return .Ok(.Int(if operator == "+" { a + b } else if operator == "-" { a - b } else if operator == "*" { a * b } else { a / b }))
            }
            case Size(b) => if operator == "*" && a >= 0 {
                return .Ok(.Size(cast[u64](a) * b))
            }
            case Duration(b) => if operator == "*" {
                return .Ok(.Duration(a * b))
            }
            case _ => {}
        }
        case Size(a) => match right {
            case Size(b) => {
                if operator == "+" {
                    return .Ok(.Size(a + b))
                }
                if operator == "-" {
                    return if b > a { error_at(at, "a size can't be less than none") } else { Result[Value, EvalError].Ok(.Size(a - b)) }
                }
            }
            case Int(b) => {
                if operator == "*" && b >= 0 {
                    return .Ok(.Size(a * cast[u64](b)))
                }
                if operator == "/" && b > 0 {
                    return .Ok(.Size(a / cast[u64](b)))
                }
            }
            case _ => {}
        }
        case Duration(a) => match right {
            case Duration(b) => {
                if operator == "+" {
                    return .Ok(.Duration(a + b))
                }
                if operator == "-" {
                    return .Ok(.Duration(a - b))
                }
            }
            case Int(b) => {
                if operator == "*" {
                    return .Ok(.Duration(a * b))
                }
                if operator == "/" && b != 0 {
                    return .Ok(.Duration(a / b))
                }
            }
            case _ => {}
        }
        case Text(a) => match right {
            case Text(b) => if operator == "+" {
                return .Ok(.Text(joined(a, b)))
            }
            case _ => {}
        }
        case _ => {}
    }
    return error_at(at, message("% can't be % %", type_name(left), operator, type_name(right)))
}

joined :: fn(a: string, b: string) -> string {
    made : u8[..]
    for byte in string_bytes(a) {
        runtime.array_add(&made, byte)
    }
    for byte in string_bytes(b) {
        runtime.array_add(&made, byte)
    }
    return if made.count > 0 { string_of(&made[0], made.count) } else { "" }
}

/** A string's $names filled in with their values, as rendered; one that isn't bound left as it was written. */
interpolate :: fn(shell: ptr[mut Shell], text: string) -> string {
    bytes :: string_bytes(text)
    made : u8[..]
    at : usize = 0
    loop {
        if at >= bytes.count {
            break
        }
        byte :: bytes[at]
        if byte == 0 {
            // An escaped $
            runtime.array_add(&made, cast[u8]('$'))
            at += 1
            continue
        }
        if byte == cast[u8]('$') && at + 1 < bytes.count && is_letter(bytes[at + 1]) {
            start :: at + 1
            end := start
            loop {
                if end >= bytes.count || (!is_letter(bytes[end]) && !is_digit(bytes[end])) {
                    break
                }
                end += 1
            }
            name :: if start <= end && end <= bytes.count { string_of(&bytes[start % bytes.count], end - start) } else { "" }
            match lookup(shell.scope, name) {
                case Some(value) => {
                    storage : u8[1024]
                    out := text_buffer.make(storage)
                    render(&out, value)
                    for rendered in string_bytes(text_buffer.as_string(&out)) {
                        runtime.array_add(&made, rendered)
                    }
                }
                case None => {
                    for kept in bytes[at..<end] {
                        runtime.array_add(&made, kept)
                    }
                }
            }
            at = end
            continue
        }
        runtime.array_add(&made, byte)
        at += 1
    }
    return if made.count > 0 { string_of(&made[0], made.count) } else { "" }
}

/**
 * A call: a name bound by let, alone, is its value; print writes its arguments, exit ends the shell and cd changes its
 * directory; a shell function's name calls it; anything else is a program, through its manifest (decisions/0170).
 */
call :: fn(shell: ptr[mut Shell], tree #escaping : ptr[Node]) -> Result[Value, EvalError] {
    match lookup(shell.scope, tree.text) {
        case Some(value) => {
            if tree.children.count > 0 {
                return error_at(tree.at, message("% is a variable, so it takes no arguments", tree.text))
            }
            return .Ok(value)
        }
        case None => {}
    }
    if tree.text == "print" {
        storage : u8[4096]
        out := text_buffer.make(storage)
        for child, i in tree.children {
            if i > 0 {
                text_buffer.append(&out, " ")
            }
            render(&out, evaluate(shell, child)?)
        }
        say(shell, text_buffer.as_string(&out))
        return .Ok(.Null)
    }
    if tree.text == "exit" {
        shell.exiting = true
        return .Ok(.Null)
    }
    if tree.text == "cd" {
        return change_directory(shell, tree)
    }
    if is_stage(tree) {
        return error_at(tree.at, message("% works on what comes before it in a pipeline", tree.text))
    }
    match function_named(shell, tree.text) {
        case Some(function) => return call_function(shell, function, tree)
        case None => {}
    }
    return run_program(shell, tree)
}
