/**
 * The system configuration's records' tests, as a hosted program (tools/unit_tests.py): main returns 0 if everything
 * worked, or the number of the first check that failed. Records of three services stand in for the build's: a server
 * with a listener, a client with a channel to it and an optional Config, and the config store's listener.
 */
package system_records_test

import runtime from "base"
import system_records from ".."

/** The tag of the protocol the test's server serves and its client takes a channel to; any value but 0 would do. */
SERVED_TAG : u64 : 0x1234
/** The tag the test's config store listens for and its client's Config takes. */
CONFIG_TAG : u64 : 0x5678

/**
 * Run the system records' tests: check and apply on records of three services, each change that should be refused
 * refused, and the protocol tag's hash.
 *
 * @return 0 if every check passed; otherwise the number of the first that failed, 1 to 20, or 99 if there wasn't the
 *     memory for the records.
 */
main :: fn() -> int {
    made, error :: runtime.new_aligned(system_records.SystemRecords, align_of(system_records.SystemRecords))
    if error != null {
        return 99
    }
    defer runtime.free(made)
    made^ = records()
    // Records as the build makes them are taken
    if system_records.check(made) is_some {
        return 1
    }
    // Each of these is refused
    changed := made^
    changed.magic = 0
    if system_records.check(&changed) is_none {
        return 2
    }
    changed = made^
    changed.parameters[2].tag = 0x9999
    if system_records.check(&changed) is_none {
        return 3
    }
    changed = made^
    changed.services[1].budget = 0
    if system_records.check(&changed) is_none {
        return 4
    }
    changed = made^
    changed.services[1].cpu = system_records.CpuRecord.{has = 1, priority = 1, period_ns = 10, time_ns = 11}
    if system_records.check(&changed) is_none {
        return 5
    }
    changed = made^
    changed.services[1].name[0] = 32
    if system_records.check(&changed) is_none {
        return 6
    }
    changed = made^
    _ = system_records.set_name(&changed.services[1].name, "server")
    if system_records.check(&changed) is_none {
        return 7
    }
    changed = made^
    changed.services[0].parameter_count = 200
    if system_records.check(&changed) is_none {
        return 8
    }
    changed = made^
    changed.services[1].starter = 7
    if system_records.check(&changed) is_none {
        return 9
    }
    // An override's tunables are applied, and checked
    overrides := system_records.SystemOverrides.{count = 1}
    overrides.tuned[0] = system_records.Tunables.{set = system_records.TUNE_BUDGET | system_records.TUNE_RESTART, budget = 4096,
        not_restarted = 1}
    _ = system_records.set_name(&overrides.tuned[0].name, "client")
    changed = made^
    if (system_records.apply(&changed, &overrides) is_some) || changed.services[1].budget != 4096 || changed.services[1].not_restarted != 1 {
        return 10
    }
    // One that leaves a budget of 0, names a service there isn't, or tunes what it can't, is refused, and changes nothing
    overrides.tuned[0].budget = 0
    changed = made^
    if (system_records.apply(&changed, &overrides) is_none) || changed.services[1].budget != made.services[1].budget {
        return 11
    }
    overrides.tuned[0].budget = 4096
    _ = system_records.set_name(&overrides.tuned[0].name, "nothing")
    if system_records.apply(&changed, &overrides) is_none {
        return 12
    }
    _ = system_records.set_name(&overrides.tuned[0].name, "client")
    overrides.tuned[0].set = 16
    if system_records.apply(&changed, &overrides) is_none {
        return 13
    }
    overrides.count = system_records.MAX_TUNED + 1
    if system_records.apply(&changed, &overrides) is_none {
        return 14
    }
    // What the system needs can't require what only a late service serves
    changed = made^
    changed.services[0].late = 1
    if system_records.check(&changed) is_none {
        return 16
    }
    changed.services[1].late = 1
    if system_records.check(&changed) is_some {
        return 17
    }
    // Installations: named, with programs, no two of one name, within their array
    changed = made^
    changed.installations.count = 2
    _ = system_records.set_name(&changed.installations.entries[0].name, "counter")
    _ = system_records.set_name(&changed.installations.entries[0].program, "counter")
    _ = system_records.set_name(&changed.installations.entries[1].name, "other")
    _ = system_records.set_name(&changed.installations.entries[1].program, "counter")
    if system_records.check(&changed) is_some {
        return 18
    }
    _ = system_records.set_name(&changed.installations.entries[1].name, "counter")
    if system_records.check(&changed) is_none {
        return 19
    }
    changed.installations.count = system_records.MAX_INSTALLATIONS + 1
    if system_records.installations_check(&changed.installations) is_none {
        return 20
    }
    // A protocol's tag is std/os's: FNV-1a of its name
    if system_records.tag_of("") != 0xcbf29ce484222325 || system_records.tag_of("a") != 0xaf63dc4c8601ec8c {
        return 15
    }
    return 0
}

/**
 * Make the test's records, which check takes: three services, server, with a listener for SERVED_TAG; client, with a
 * channel to it and an optional Config; config, with a listener for CONFIG_TAG.
 *
 * @return The records, with a default CPU share and no installations.
 */
records :: fn() -> system_records.SystemRecords {
    made := system_records.SystemRecords.{magic = system_records.MAGIC, service_count = 3, parameter_count = 4}
    made.default_cpu = system_records.CpuRecord.{has = 1, priority = 100, period_ns = 10000000, time_ns = 5000000}
    service(&made, 0, "server", 0, 1)
    service(&made, 1, "client", 1, 2)
    service(&made, 2, "config", 3, 1)
    parameter(&made, 0, "clients", system_records.KIND_LISTENER, SERVED_TAG, 0)
    parameter(&made, 1, "server", system_records.KIND_CHANNEL, SERVED_TAG, 0)
    parameter(&made, 2, "settings", system_records.KIND_CONFIG, CONFIG_TAG, 1)
    parameter(&made, 3, "admin", system_records.KIND_LISTENER, CONFIG_TAG, 0)
    return made
}

/**
 * Fill in a service's record: a well-formed one the supervisor starts through the process manager, with a 1 MiB
 * budget, from program.elf.
 *
 * @param records The records being made.
 * @param index Which service, below MAX_SERVICES; one past them is ignored.
 * @param name The service's name, set with set_name; one of NAME_BYTES or more leaves the name all zeros, which isn't
 *     reported.
 * @param first Its first parameter's index in the records' parameters.
 * @param count How many parameters it has.
 */
service :: fn(records: ptr[mut system_records.SystemRecords], index: usize, name: string, first: u32, count: u32) {
    if index >= records.services.count {
        return void
    }
    made :: &records.services[index]
    _ = system_records.set_name(&made.name, name)
    _ = system_records.set_name(&made.module, "program.elf")
    made.budget = 1024 * 1024
    made.starter = system_records.STARTER_SUPERVISOR
    made.by_manager = 1
    made.first_parameter = first
    made.parameter_count = count
}

/**
 * Fill in a parameter's record.
 *
 * @param records The records being made.
 * @param index Which parameter, below MAX_PARAMETERS; one past them is ignored.
 * @param name The parameter's name, the grant it's given, set with set_name; one of NAME_BYTES or more leaves the name
 *     all zeros, which isn't reported.
 * @param kind What it is, a KIND_ value.
 * @param tag Its protocol's tag.
 * @param optional 1 if it's optional, 0 if it's required.
 */
parameter :: fn(records: ptr[mut system_records.SystemRecords], index: usize, name: string, kind: u8, tag: u64, optional: u8) {
    if index >= records.parameters.count {
        return void
    }
    made :: &records.parameters[index]
    _ = system_records.set_name(&made.name, name)
    made.kind = kind
    made.tag = tag
    made.optional = optional
}
