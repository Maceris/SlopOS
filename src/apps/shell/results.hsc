package shell

import runtime from "base"
import language from "../../shell_language"
import os from "std"
import schema from "std"
import text_buffer from "std"
import slop_os from "std/os"

/*
 * What a program's entry gives back (decisions/0179, Hemera's docs/compilation.md, Entry Results): a program whose
 * main gives back a value, most usefully a Result, writes it in memory the shell gives it as the grant "result", which
 * the shell reads once it's ended, by the manifest, where main's result type is. An Ok's value is the call's value; an
 * Error is the call's error, shown by its variant, the parameter it names (an os.ParameterName in it), and the hint its
 * @error documentation gives.
 */

/** How much memory a program's result is written in, in bytes: 64 KiB. */
RESULT_BYTES : u64 : 64 * 1024

/**
 * Find where a program's entry's result type is in its manifest, if it gives back more than an exit code.
 *
 * @param manifest The program's manifest, only read.
 * @return The result type's place; null for an entry that gives back an integer, or nothing.
 */
result_place :: fn(manifest: ptr[schema.Schema]) -> usize? {
    entry :: schema.type_in(manifest, 0) or_return null
    if entry.outputs.count != 1 {
        return null
    }
    for place in entry.outputs {
        given :: schema.type_in(manifest, schema.unaliased_place(manifest, place)) or_return null
        return if given.kind == .Integer { null } else { place }
    }
    return null
}

/**
 * Make the memory a call's program writes its result in, if its entry gives one back, and the handle the launch gives
 * it as the grant "result".
 *
 * @param call The call, prepared; its result is set to the memory, the call's own, which end_call closes.
 * @return The handle for the launch, which may only write the memory, and moves to the program; null for an entry
 *     without a result, or if the memory couldn't be made.
 */
result_grant :: fn(call: ptr[mut Call]) -> slop_os.Memory? {
    if result_place(&call.manifest) is_none {
        return null
    }
    budget :: slop_os.startup_block().budget
    memory :: slop_os.memory_create(budget, RESULT_BYTES) or_return null
    rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_WRITE) | cast[u32](slop_os.RIGHT_TRANSFER))
    given :: match slop_os.handle_duplicate(cast[slop_os.Handle](memory), rights) {
        case Ok(made) => made
        case Error(error) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](memory))
            return null
        }
    }
    call.result = memory
    call.has_result = true
    return cast[slop_os.Memory](given)
}

/**
 * Read what a call's program gave back, once it's ended: an Ok's value kept as the call's, or an Error made the
 * call's error.
 *
 * @param shell The shell, whose programs connection gives the program's documentation, for the hint.
 * @param call The call, its program ended; its returned is set from an Ok.
 * @param code The program's exit code; nothing's read for one that was killed.
 * @return The error, for a program that gave back an Error; null otherwise, and for one that gave back nothing, or
 *     what doesn't read as its manifest's result type.
 */
read_result :: fn(shell: ptr[mut Shell], call: ptr[mut Call], code: u64) -> EvalError? {
    if !call.has_result || code == slop_os.EXIT_KILLED {
        return null
    }
    place :: result_place(&call.manifest) or_return null
    given := os.entry_result(call.result) or_return null
    defer runtime.array_free(&given.value)
    if !same_hash(given.schema, schema.hash_rooted(&call.manifest, place)) {
        return null
    }
    value :: language.decode(&call.manifest, place, given.value[0..<given.value.count], 0, 0)
    held := value
    variant := ""
    // A Result reads as a record of its variant, Ok or Error, holding what it holds, or as the variant's name alone
    match value {
        case Record(record) => {
            for name, i in record.names {
                if i < record.values.count && (name == "Ok" || name == "Error") {
                    variant = name
                    held = record.values[i]
                }
            }
        }
        case Text(text) => if text == "Ok" || text == "Error" {
            variant = text
            held = .Null
        }
        case _ => {}
    }
    if !given.error {
        call.returned = held
        return null
    }
    return EvalError.{message = error_message(shell, call, place, held), at = call.tree.at}
}

/**
 * Say what a program's error is: its variant, the parameter it names, and its @error documentation's hint.
 *
 * @param shell The shell, whose programs connection gives the program's documentation.
 * @param call The call, whose manifest and name are used.
 * @param place The entry's result type's place in the manifest, a Result.
 * @param error What its Error held, as the shell reads it: an enum's member's or a union's variant's name, or a record
 *     of the variant, holding what it holds.
 * @return The message, on the heap: "name --parameter: Variant: hint", without what isn't there.
 */
error_message :: fn(shell: ptr[mut Shell], call: ptr[Call], place: usize, error: Value) -> string {
    variant := ""
    payload := Value.Null
    match error {
        case Text(text) => variant = text
        case Record(record) => {
            for name, i in record.names {
                if i == 0 && i < record.values.count {
                    variant = name
                    payload = record.values[i]
                }
            }
        }
        case _ => {}
    }
    parameter :: parameter_named(&call.manifest, place, variant, payload)
    hint := ""
    match program_documentation(shell, call.tree.text) {
        case Some(found) => {
            for each in found.errors {
                if each.name == variant {
                    hint = each.text
                }
            }
        }
        case None => {}
    }
    storage : u8[1024]
    out := text_buffer.make(storage)
    text_buffer.append(&out, call.tree.text)
    if parameter.count > 0 {
        text_buffer.append(&out, " --")
        text_buffer.append(&out, parameter)
    }
    if variant.count > 0 {
        text_buffer.append(&out, ": ")
        text_buffer.append(&out, variant)
    }
    if hint.count > 0 {
        text_buffer.append(&out, ": ")
        text_buffer.append(&out, hint)
    }
    return message("%", text_buffer.as_string(&out))
}

/**
 * Find the parameter an error names: the name in a field of the variant's payload whose type is std's
 * os.ParameterName.
 *
 * @param manifest The program's manifest, whose types say which field it is.
 * @param place The entry's result type's place, a Result whose Error holds the error.
 * @param variant The error's variant's name.
 * @param payload What the variant holds, as the shell reads it: a record of its fields.
 * @return The parameter's name; "" if the error names none.
 */
parameter_named :: fn(manifest: ptr[schema.Schema], place: usize, variant: string, payload: Value) -> string {
    record :: match payload {
        case Record(found) => found
        case _ => return ""
    }
    result :: schema.type_in(manifest, schema.unaliased_place(manifest, place)) or_return ""
    for each in result.variants {
        if each.name != "Error" {
            continue
        }
        for held in each.held {
            error_type :: schema.type_in(manifest, schema.unaliased_place(manifest, held.type)) or_return ""
            for chosen in error_type.variants {
                if chosen.name != variant {
                    continue
                }
                for inner in chosen.held {
                    payload_type :: schema.type_in(manifest, schema.unaliased_place(manifest, inner.type)) or_return ""
                    for member in payload_type.members {
                        member_type :: schema.type_in(manifest, member.type) or_continue
                        if member_type.name == "ParameterName" || member_type.name == "os.ParameterName" {
                            named :: field(record, member.name) or_return ""
                            inside :: match named {
                                case Record(found) => found
                                case _ => return ""
                            }
                            name :: field(inside, "name") or_else Value.Null
                            match name {
                                case Text(text) => return text
                                case _ => return ""
                            }
                        }
                    }
                }
            }
        }
    }
    return ""
}
