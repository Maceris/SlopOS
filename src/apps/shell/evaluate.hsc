package shell

import runtime from "base"
import language from "../../shell_language"
import text_buffer from "std"

/*
 * Evaluating the shell language: each statement's tree to a value, or an error that stops what follows
 * (design/shell.md §5) unless `or { ... }` handles it. Names are the shell's own, bound by let, never given to
 * programs.
 */

/**
 * An error, and where in the line it is. One a shell function's body met in a statement without ? is fatal once it
 * leaves the function: it ends what's running, and nothing handles it (design/shell.md §5); ? marks it passed, the
 * function's own error, which its caller can handle. A return is carried out of the function's body as one too.
 */
EvalError :: struct {
    /** What went wrong, a sentence for a person: a literal, or made by message on the heap. */
    message : string,
    /** Where in the line, in bytes from 0, for the error's ^ to point at. */
    at : usize,
    /** Whether it left a shell function without ?, so nothing handles it and it ends what's running. */
    fatal : bool,
    /** Whether ? passed it on: the function's own error, which its caller can handle. */
    passed : bool,
    /** Whether it's a return carrying the function's value (in the shell's returned) out of its body, not an error. */
    returning : bool,
}

/**
 * Tell whether an error is one `or` and try/catch handle.
 *
 * @param error The error met; only its fatal and returning flags are looked at, so a passed one is handled too.
 * @return False for a fatal one and for a return, which go on out; true otherwise.
 */
handles :: fn(error: EvalError) -> bool {
    return !error.fatal && !error.returning
}

/**
 * Make an evaluation's error result: not fatal, not passed, not a return.
 *
 * @param at Where in the line, in bytes from 0.
 * @param message What went wrong, kept by the error, so a literal or a message's.
 * @return The error, as a result.
 */
error_at :: fn(at: usize, message: string) -> Result[Value, EvalError] {
    return .Error(EvalError.{message = message, at = at})
}

/**
 * Evaluate a node of a parsed line: a statement, a pipeline, or an expression, binding names and running programs and
 * functions as it says.
 *
 * Statements run in turn, the first error stopping the rest. A Return sets the shell's returned and comes back as an
 * error with returning set, for the function it's in to take.
 *
 * On an error, the EvalError says what went wrong and where, and whether it's fatal, passed by ?, or a return.
 *
 * @param shell The shell, whose scope, directory and programs it uses and changes.
 * @param tree The node, kept by functions it defines, so it has to live as long as the shell.
 * @return The node's value: the last statement's for Statements, Null for a statement without one.
 */
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
        case .Background => return start_job(shell, tree)
        case .Parameter => return error_at(tree.at, "a parameter is a function's")
        // A script's first statement, which running it binds (scripts.hsc); anywhere else, it's out of place
        case .Param => return error_at(tree.at, "param is a script's first line: name.shell, run as a command, takes what it says")
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
        case .Interpolated => return .Ok(.Text(interpolate(shell.scope, tree.text)))
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

/**
 * Index a value: a list by an integer, from 0, or a record by a field's name.
 *
 * It fails when there's no such item or field, the index is the wrong kind, or base can't be indexed.
 *
 * @param at Where the index is in the line, for an error.
 * @param base The value indexed: a List or a Record; any other kind fails.
 * @param index An Int for a list, from 0, a negative one or one past its items failing; a Text naming a field for a
 *     record. Any other kind fails.
 * @return The item or field, sharing any list or record in it with base.
 */
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

/**
 * Evaluate a unary operator: not of a bool, or - of an integer or a duration.
 *
 * It fails with the operand's error, or when the operand is the wrong kind.
 *
 * @param shell The shell, which evaluates the operand, as evaluate does, in its scope.
 * @param tree The Unary node, its operator in its text: "not", or anything else taken as "-"; its operand its child.
 * @return A Bool for not; the operand negated, an Int or a Duration, for -. The smallest i64, which has no positive
 *     counterpart, fails as too big.
 */
unary_value :: fn(shell: ptr[mut Shell], tree: ptr[Node]) -> Result[Value, EvalError] {
    operand :: evaluate(shell, first_child(tree) or_return error_at(tree.at, "an operator needs a value"))?
    if tree.text == "not" {
        match operand {
            case Bool(truth) => return .Ok(.Bool(!truth))
            case _ => return error_at(tree.at, message("not takes a bool, not %", type_name(operand)))
        }
    }
    match operand {
        case Int(number) => return .Ok(.Int(subtracted(0, number) or_return too_big(tree.at)))
        case Duration(nanos) => return .Ok(.Duration(subtracted(0, nanos) or_return too_big(tree.at)))
        case _ => {}
    }
    return error_at(tree.at, message("- takes a number, not %", type_name(operand)))
}

/**
 * Make the error arithmetic gives when its result is past what a value holds.
 *
 * @param at Where the operator is in the line, for the error.
 * @return The error, as a result.
 */
too_big :: fn(at: usize) -> Result[Value, EvalError] {
    return error_at(at, language.TOO_BIG)
}

/**
 * Evaluate a binary operator: and and or of bools, the right only if the left doesn't decide it; comparisons of two
 * values of a kind; and arithmetic.
 *
 * It fails with an operand's error, or when the operands can't be compared, or the arithmetic can't be done.
 *
 * @param shell The shell, which evaluates the operands, as evaluate does, in its scope; the right one not at all when
 *     and or or is decided by the left.
 * @param tree The Binary node, its operator in its text, its operands its children.
 * @return The result: a Bool for and, or and comparisons.
 */
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

/**
 * Do + - * / on two values, as language.calculate does, its error at the operator.
 *
 * @param at Where the operator is in the line, for an error.
 * @param operator The operator: "+", "-", "*" or "/".
 * @param left The operator's left operand, of any kind; language.calculate says which it takes.
 * @param right Its right operand.
 * @return The result, as language.calculate gives it; its error as the evaluation's, at at.
 */
arithmetic :: fn(at: usize, operator: string, left: Value, right: Value) -> Result[Value, EvalError] {
    return match language.calculate(operator, left, right) {
        case Ok(value) => .Ok(value)
        case Error(problem) => error_at(at, problem)
    }
}

/**
 * Evaluate a call: a name bound by let, alone, is its value; print writes its arguments, exit ends the shell, cd
 * changes its directory, help says what a command does, view gives a file as a value (viewing.hsc), jobs, wait and
 * stop work on jobs in the background, and processes, end, install, uninstall, installations and grants on the
 * session (system.hsc); a
 * shell function's name calls it; anything else is a program, through its manifest
 * (decisions/0170).
 *
 * It fails for a variable or exit given arguments or a pipeline's stage used alone, or with an argument's error, or
 * the function's or program's.
 *
 * @param shell The shell: its scope and functions are looked in, its terminal is written to by print and help, exit
 *     sets its exiting, and cd changes its directory.
 * @param tree The Call node, kept by what it runs as long as that needs it.
 * @return The call's value: the variable's, the function's, the program's, or for wait the job's; Null for print, exit,
 *     cd, help, jobs and stop.
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
        if tree.children.count > 0 {
            return error_at(tree.at, "exit takes nothing")
        }
        shell.exiting = true
        return .Ok(.Null)
    }
    if tree.text == "cd" {
        return change_directory(shell, tree)
    }
    if tree.text == "help" {
        return show_help(shell, tree)
    }
    if tree.text == "jobs" {
        return list_jobs(shell, tree)
    }
    if tree.text == "wait" {
        return wait_job(shell, tree)
    }
    if tree.text == "stop" {
        return stop_job(shell, tree)
    }
    if tree.text == "view" {
        return view_file(shell, tree)
    }
    // The system, as the session sees it (system.hsc)
    if tree.text == "processes" {
        return list_processes(shell, tree)
    }
    if tree.text == "end" {
        return end_installation(shell, tree)
    }
    if tree.text == "install" {
        return install_program(shell, tree)
    }
    if tree.text == "uninstall" {
        return uninstall_installation(shell, tree)
    }
    if tree.text == "installations" {
        return list_installations(shell, tree)
    }
    if tree.text == "grants" {
        return kept_grants(shell, tree)
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
