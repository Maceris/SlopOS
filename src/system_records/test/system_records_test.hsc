/**
 * The system configuration's records' tests, a test program (tools/unit_tests.py, decisions/0175). Records of three
 * services stand in for the build's: a server with a listener, a client with a channel to it and an optional Config,
 * and the config store's listener.
 */
package system_records_test

import runtime from "base"
import testing from "std"
import system_records from ".."

/** The tag of the protocol the test's server serves and its client takes a channel to; any value but 0 would do. */
SERVED_TAG : u64 : 0x1234
/** The tag the test's config store listens for and its client's Config takes. */
CONFIG_TAG : u64 : 0x5678

/**
 * Make the test's records on the heap, as records makes them; they're too big for a test's stack beside a changed copy.
 *
 * @param t The test's state, which a failure is recorded in.
 * @return The records, from the context's allocator, which the caller frees with runtime.free; Error if there wasn't
 *     the memory for them, the failure recorded.
 */
made_records :: fn(t: ptr[mut testing.T]) -> Result[ptr[mut system_records.SystemRecords], testing.Stopped] {
    made, error :: runtime.new_aligned(system_records.SystemRecords, align_of(system_records.SystemRecords))
    testing.require(t, error == null, "there's the memory for the records")?
    made^ = records()
    return .Ok(made)
}

records_as_the_build_makes_them_are_taken #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made :: made_records(t)?
    defer runtime.free(made)
    testing.expect_none(t, system_records.check(made), "three well-formed services, each parameter's protocol served")
    return .Ok
}

broken_records_are_refused #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made :: made_records(t)?
    defer runtime.free(made)
    changed := made^
    changed.magic = 0
    testing.expect_some(t, system_records.check(&changed), "without their magic, they aren't system records")
    changed = made^
    changed.parameters[2].tag = 0x9999
    testing.expect_some(t, system_records.check(&changed), "a Config, even an optional one, of a protocol no service serves")
    changed = made^
    changed.services[1].budget = 0
    testing.expect_some(t, system_records.check(&changed), "a service with no budget can't be started")
    changed = made^
    changed.services[1].cpu = system_records.CpuRecord.{has = 1, priority = 1, period_ns = 10, time_ns = 11}
    testing.expect_some(t, system_records.check(&changed), "a CPU share of more time than its period")
    changed = made^
    changed.services[1].name[0] = 32
    testing.expect_some(t, system_records.check(&changed), "a name starting with a space isn't a service's")
    changed = made^
    _ = system_records.set_name(&changed.services[1].name, "server")
    testing.expect_some(t, system_records.check(&changed), "two services of one name")
    changed = made^
    changed.services[0].parameter_count = 200
    testing.expect_some(t, system_records.check(&changed), "parameters past the records' own")
    changed = made^
    changed.services[1].starter = 7
    testing.expect_some(t, system_records.check(&changed), "7 isn't a starter")
    return .Ok
}

an_overrides_tunables_are_applied #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made :: made_records(t)?
    defer runtime.free(made)
    overrides := system_records.SystemOverrides.{count = 1}
    overrides.tuned[0] = system_records.Tunables.{set = system_records.TUNE_BUDGET | system_records.TUNE_RESTART, budget = 4096,
        not_restarted = 1}
    _ = system_records.set_name(&overrides.tuned[0].name, "client")
    changed := made^
    testing.expect_none(t, system_records.apply(&changed, &overrides), "a budget and a restart policy for a service there is")
    testing.expect_eq(t, changed.services[1].budget, 4096, "the client's budget is the override's")
    testing.expect_eq(t, changed.services[1].not_restarted, 1, "and so is whether it's restarted")
    return .Ok
}

overrides_that_cannot_apply_are_refused_and_change_nothing #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made :: made_records(t)?
    defer runtime.free(made)
    overrides := system_records.SystemOverrides.{count = 1}
    overrides.tuned[0] = system_records.Tunables.{set = system_records.TUNE_BUDGET | system_records.TUNE_RESTART, budget = 0,
        not_restarted = 1}
    _ = system_records.set_name(&overrides.tuned[0].name, "client")
    changed := made^
    testing.expect_some(t, system_records.apply(&changed, &overrides), "a budget of 0 would leave the client unstartable")
    testing.expect_eq(t, changed.services[1].budget, made.services[1].budget, "a refused override changes nothing")
    overrides.tuned[0].budget = 4096
    _ = system_records.set_name(&overrides.tuned[0].name, "nothing")
    testing.expect_some(t, system_records.apply(&changed, &overrides), "there's no service named nothing to tune")
    _ = system_records.set_name(&overrides.tuned[0].name, "client")
    overrides.tuned[0].set = 16
    testing.expect_some(t, system_records.apply(&changed, &overrides), "16 isn't a tunable an override can set")
    overrides.count = system_records.MAX_TUNED + 1
    testing.expect_some(t, system_records.apply(&changed, &overrides), "more tuned services than the overrides hold")
    return .Ok
}

what_the_system_needs_cannot_require_what_only_a_late_service_serves #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made :: made_records(t)?
    defer runtime.free(made)
    changed := made^
    changed.services[0].late = 1
    testing.expect_some(t, system_records.check(&changed), "the client, started with the system, needs the late server")
    changed.services[1].late = 1
    testing.expect_none(t, system_records.check(&changed), "a late client may need a late server")
    return .Ok
}

installations_are_named_with_programs_and_no_two_of_one_name #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made :: made_records(t)?
    defer runtime.free(made)
    changed := made^
    changed.installations.count = 2
    _ = system_records.set_name(&changed.installations.entries[0].name, "counter")
    _ = system_records.set_name(&changed.installations.entries[0].program, "counter")
    _ = system_records.set_name(&changed.installations.entries[1].name, "other")
    _ = system_records.set_name(&changed.installations.entries[1].program, "counter")
    testing.expect_none(t, system_records.check(&changed), "two installations of one program, named differently")
    _ = system_records.set_name(&changed.installations.entries[1].name, "counter")
    testing.expect_some(t, system_records.check(&changed), "two installations of one name")
    changed.installations.count = system_records.MAX_INSTALLATIONS + 1
    testing.expect_some(t, system_records.installations_check(&changed.installations), "more installations than their array holds")
    return .Ok
}

a_protocols_tag_is_the_fnv_1a_of_its_name #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    // As std/os makes it
    testing.expect_eq(t, system_records.tag_of(""), 0xcbf29ce484222325, "FNV-1a's offset basis, for no bytes")
    testing.expect_eq(t, system_records.tag_of("a"), 0xaf63dc4c8601ec8c, "FNV-1a's published hash of a")
    return .Ok
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
