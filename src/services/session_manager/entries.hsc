package session_manager

import runtime from "base"
import os from "std"
import schema from "std"
import slop_os from "std/os"
import config from "../../protocols/config"
import bundle from "../../bundle"
import system_records from "../../system_records"

/*
 * What an installation is given (decisions/0181, F3), from its program's manifest: a parameter of type AppData its
 * data directory, apps/<name> in the session's apps directory; one of a Config[T] its value of that parameter's name in
 * the config store, of its owner, user:<user>:<name>, which the program declares; the clock and the locale as every
 * program the session manager starts has them. Any other parameter has to be optional, and is given nothing: the
 * program asks the powerbox for more as it runs. A program with another parameter it can't go without isn't
 * installed.
 */

/** The most Config parameters an installation's entry has that are given their values. */
MAX_SETTINGS :: 8

/** What an installation's entry takes, as its manifest says, and its program. */
EntryPlan :: struct {
    /** Its program, paged memory from the bundle store, the caller's to launch or close. */
    program : slop_os.Memory,
    /** Its AppData parameter's name, its data directory's label; empty for none. */
    data : string,
    /** Its Config parameters' names, each its value's label and name; the first settings_count of them. */
    settings : string[MAX_SETTINGS],
    /** How many of settings there are. */
    settings_count : usize,
}

/** Why a bundle can't be installed. */
EntryProblem :: union {
    /** The bundle, its program or its manifest couldn't be read, or the manifest isn't an entry's. */
    Unreadable,
    /** A parameter it can't go without isn't one an installation is given: its name, on the heap. */
    Needs(string),
}

/**
 * Read a bundle's program and what its entry takes, as an installation would be given it.
 *
 * @param sessions The session manager, whose bundle store gives the bundle, its program and its manifest.
 * @param bundle_hash The bundle's hash.
 * @return The plan, its program the caller's; Unreadable, or Needs with the first parameter that can't be given.
 */
entry_plan :: fn(sessions: ptr[mut Manager], bundle_hash: bundle.Hash) -> Result[EntryPlan, EntryProblem] {
    record :: stored_object(sessions, bundle_hash) or_return .Error(.Unreadable)
    referred : bundle.Hash[..]
    defer runtime.array_free(&referred)
    read :: bundle.bundle_refers(record.bytes, &referred) or_else false
    let_go_of_object(record)
    if !read || referred.count < 2 {
        return .Error(.Unreadable)
    }
    manifest_object :: stored_object(sessions, referred[1 % referred.count]) or_return .Error(.Unreadable)
    parsed := schema.parse(manifest_object.bytes)
    let_go_of_object(manifest_object)
    manifest := parsed or_return .Error(.Unreadable)
    defer schema.free(&manifest)
    entry :: schema.type_in(&manifest, 0) or_return .Error(.Unreadable)
    if entry.kind != .Function {
        return .Error(.Unreadable)
    }
    plan := EntryPlan.{}
    for input in entry.inputs {
        held, optional :: held_of(&manifest, input.type)
        name :: schema.type_in(&manifest, held) or_return .Error(.Unreadable)
        if name.name == "AppData" && plan.data.count == 0 {
            plan.data = copied_name(input.name)
            continue
        }
        if starts_with_bytes(name.name, "Config[") && plan.settings_count < plan.settings.count {
            plan.settings[plan.settings_count] = copied_name(input.name)
            plan.settings_count += 1
            continue
        }
        if !optional {
            return .Error(.Needs(copied_name(input.name)))
        }
    }
    match store_request(sessions, .Get(referred[0])) {
        case Got(object) => plan.program = object.memory
        case _ => return .Error(.Unreadable)
    }
    return .Ok(plan)
}

/**
 * Launch an installation by its plan: its data directory and settings made and given by their parameters' names.
 *
 * @param sessions The session manager, which launches it and keeps it.
 * @param number The session's number, whose apps directory holds its data, and whose user owns its settings.
 * @param name The installation's name.
 * @param plan Its plan, whose program moves to the launch, or is closed if it doesn't start.
 * @return Whether it started; not without a data directory it asks for, or room for another program, or if the launch
 *     failed. Each is logged.
 */
launch_installation :: fn(sessions: ptr[mut Manager], number: u32, name: string, plan #escaping : EntryPlan) -> bool {
    grants : os.NamedGrant[..]
    defer runtime.array_free(&grants)
    if plan.data.count > 0 {
        data := NONE
        if cast[usize](number) < sessions.sessions.count && sessions.sessions[cast[usize](number)].apps != NONE {
            data = opened_directory(sessions.sessions[cast[usize](number)].apps, name, true) or_else NONE
        }
        if data == NONE {
            runtime.log_info("installation %: no data directory for it", name)
            _ = slop_os.handle_close(cast[slop_os.Handle](plan.program))
            return false
        }
        runtime.array_add(&grants, os.NamedGrant.{label = plan.data, handle = cast[slop_os.Handle](data)})
    }
    for label, i in plan.settings {
        if i >= plan.settings_count {
            break
        }
        match settings_value(sessions, number, name, label) {
            case Some(end) => runtime.array_add(&grants, os.NamedGrant.{label = label, handle = cast[slop_os.Handle](end)})
            case None => {}
        }
    }
    prepared :: match prepare(sessions, number, name) {
        case Some(made) => made
        case None => {
            _ = slop_os.handle_close(cast[slop_os.Handle](plan.program))
            for grant in grants {
                _ = slop_os.handle_close(grant.handle)
            }
            return false
        }
    }
    no_values : os.NamedValue[1]
    return placed(sessions, number, name, prepared, os.launch_named(sessions.manager, sessions.manager_port, name, plan.program,
        INSTALLATION_BUDGET, grants[0..<grants.count], no_values[0..<0], prepared.options), true)
}

/**
 * Open a connection to one of an installation's values in the config store: of its owner (owner_of), by a name.
 *
 * @param sessions The session manager, whose config store is asked, waiting for its answer.
 * @param number The session's number, whose user owns the installation's values.
 * @param name The installation's name.
 * @param value The value's name: its Config parameter's.
 * @return The connection's end, the caller's to give; null without the store, for a number past MAX_SESSIONS, or if
 *     the store didn't open it.
 */
settings_value :: fn(sessions: ptr[mut Manager], number: u32, name: string, value: string) -> slop_os.Channel? {
    if sessions.settings_end == NONE || cast[usize](number) >= sessions.sessions.count {
        return null
    }
    made :: &sessions.sessions[cast[usize](number)]
    owner : u8[OWNER_BYTES]
    count :: owner_of(user_of(made), name, &owner)
    out := os.Outgoing.{}
    request :: os.begin[config.Request](&out)
    request^ = .ValueFor(config.ValueFor.{owner = os.append(&out, owner[0..<count]), name = os.append(&out, string_bytes(value))})
    into := os.Incoming.{}
    return match config.ask(sessions.settings_end, sessions.settings_port, &out, &into) {
        case Opened(opened) => opened.end
        case _ => null
    }
}

/**
 * Find the type a parameter holds: an optional's Some type, or the parameter's own.
 *
 * @param manifest The manifest.
 * @param place The parameter's type's place.
 * @return held The place of the type it holds.
 * @return optional Whether it's an optional, which can go without.
 */
held_of :: fn(manifest: ptr[schema.Schema], place: usize) -> (held: usize, optional: bool) {
    type :: match schema.type_in(manifest, place) {
        case Some(found) => found
        case None => return place, false
    }
    if type.kind != .Union || type.null_is_none || type.variants.count != 2 {
        return place, false
    }
    for variant in type.variants {
        if variant.name == "Some" && variant.held.count == 1 {
            for each in variant.held {
                return each.type, true
            }
        }
    }
    return place, false
}

/**
 * Copy a name out of a manifest, which is freed after.
 *
 * @param name The name, a view of the manifest.
 * @return A copy, on the heap, never freed.
 */
copied_name :: fn(name: string) -> string {
    kept : u8[..]
    for byte in string_bytes(name) {
        runtime.array_add(&kept, byte)
    }
    if kept.count == 0 {
        return ""
    }
    return string_of(&kept[0], kept.count)
}

/**
 * Tell whether text starts with a prefix.
 *
 * @param text The text.
 * @param prefix The prefix.
 * @return True if text's first bytes are prefix's.
 */
starts_with_bytes :: fn(text: string, prefix: string) -> bool {
    bytes :: string_bytes(text)
    if bytes.count < prefix.count || prefix.count == 0 {
        return prefix.count == 0
    }
    return string_of(&bytes[0], prefix.count) == prefix
}
