/**
 * test_shell_results (decisions/0179): a program whose entry gives back a Result, for the shell to show: a record of
 * what it was given, or an error, one naming the parameter it came from.
 */
package test_shell_results

import os from "std"

/** What it gives back when it's fine: what it was given. */
Summary :: struct {
    /** The count it was given. */
    count : u64,
    /** The label it was given. */
    label : string,
}

/** An error that names the parameter it came from, and why. */
Refusal :: struct {
    /** The parameter: label. */
    parameter : os.ParameterName,
    /** Why it's refused, in words. */
    why : string,
}

/** What it can give back as its error. */
ResultsError :: union {
    /** An error that holds nothing. */
    Plain,
    /** An error naming its parameter. */
    Refused(Refusal),
}

/** What it's asked to give back. */
Asked :: enum {
    /** A Summary. */
    Fine,
    /** The error Plain. */
    Plain,
    /** The error Refused, naming label. */
    Refused,
}

/**
 * Give back what it's asked to: a summary of what it was given, or an error.
 *
 * @param count A number, given back in the summary.
 * @param label A word, given back in the summary.
 * @param asked What to give back: Fine, the default, a Summary; Plain or Refused, that error.
 * @return A Summary of count and label.
 * @error Plain Something went wrong that says nothing more.
 * @error Refused The label isn't one it takes.
 */
main :: fn(count: u64, label: string, asked: Asked?) -> Result[Summary, ResultsError] {
    chosen :: asked or_else Asked.Fine
    match chosen {
        case .Plain => return .Error(.Plain)
        case .Refused => {
            refusal := Refusal.{why = label}
            refusal.parameter.name = "label"
            return .Error(.Refused(refusal))
        }
        case .Fine => return .Ok(Summary.{count = count, label = label})
    }
}
