/**
 * The generations package's tests, a test program (tools/unit_tests.py, decisions/0175). A generation's record is
 * checked, refused when it's broken, read back from its bytes, and a tentative one's tries left checked.
 */
package generations_test

import testing from "std"
import bundle from "../../bundle"
import generations from ".."

a_good_record_is_accepted #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made := generation(7, generations.STATE_PERMANENT)
    testing.expect_none(t, generations.check(&made), "a permanent generation of a kernel and two boot files")
    // A kernel alone, with no boot set, is one (decisions/0135)
    alone := made
    alone.file_count = 0
    testing.expect_none(t, generations.check(&alone), "a kernel alone, with no boot set, is a generation")
    return .Ok
}

broken_records_are_refused #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made := generation(7, generations.STATE_PERMANENT)
    broken := made
    broken.magic = 0
    testing.expect_some(t, generations.check(&broken), "without its magic, it isn't a generation's record")
    broken = made
    broken.state = 9
    testing.expect_some(t, generations.check(&broken), "9 isn't a state")
    broken = made
    broken.file_count = generations.MAX_BOOT_FILES + 1
    testing.expect_some(t, generations.check(&broken), "more boot files than the record has room for")
    broken = made
    _ = generations.set_name(&broken.files[0].name, "supervisor.elf")
    testing.expect_some(t, generations.check(&broken), "the first boot file has to be the root task")
    broken = made
    for i in 0..<broken.command_line.count {
        broken.command_line[i] = 65
    }
    testing.expect_some(t, generations.check(&broken), "a command line filling its bytes has no end")
    return .Ok
}

only_the_recovery_generation_is_numbered_as_it #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made := generation(7, generations.STATE_PERMANENT)
    broken := made
    broken.number = generations.RECOVERY_NUMBER
    testing.expect_some(t, generations.check(&broken), "a permanent generation can't take the recovery number")
    broken = made
    broken.state = generations.STATE_RECOVERY
    testing.expect_some(t, generations.check(&broken), "the recovery state goes only with the recovery number")
    return .Ok
}

a_record_reads_back_from_its_bytes #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made := generation(7, generations.STATE_PERMANENT)
    read :: generations.generation_of(generations.bytes_of(&made))
    back :: testing.require_some(t, read, "a record's own bytes read back")?
    testing.expect_eq(t, back.number, 7, "the number made")
    testing.expect_eq(t, generations.text_of(&back.files[1].name), "system.records", "the second boot file's name")
    testing.expect(t, generations.generation_of(view_of(cast[ptr[u8]](&made), 100)) is_none,
        "100 bytes aren't a record's size")
    return .Ok
}

a_tentative_generation_has_at_most_tries_tries #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    // A tentative generation's tries, up to TRIES (decisions/0134)
    tentative := generation(8, generations.STATE_TENTATIVE)
    tentative.tries_left = generations.TRIES
    testing.expect_none(t, generations.check(&tentative), "a tentative generation starts with TRIES tries")
    tentative.tries_left = generations.TRIES + 1
    testing.expect_some(t, generations.check(&tentative), "it never has more than TRIES")
    return .Ok
}

/**
 * Make a generation that check accepts: of the root task and the system records, with test_exit on its command line.
 *
 * @param number The generation's number; not 0 nor RECOVERY_NUMBER, for check to accept it.
 * @param state Its state, STATE_TENTATIVE or STATE_PERMANENT for check to accept it; its tries_left is left 0.
 * @return The generation, kaslr on, the hashes made from fixed text.
 */
generation :: fn(number: u64, state: u8) -> generations.Generation {
    made := generations.Generation.{magic = generations.MAGIC, number = number, state = state, kaslr = 1, file_count = 2}
    made.kernel = bundle.hash_of(string_bytes("a kernel"))
    _ = generations.set_name(&made.files[0].name, "root_task.elf")
    made.files[0].hash = bundle.hash_of(string_bytes("a root task"))
    _ = generations.set_name(&made.files[1].name, "system.records")
    made.files[1].hash = bundle.hash_of(string_bytes("system records"))
    _ = generations.set_line(&made.command_line, "test_exit")
    return made
}
