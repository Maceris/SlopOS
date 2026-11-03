/**
 * The generations package's tests, as a hosted program (tools/unit_tests.py): main returns 0 if everything worked, or
 * the number of the first check that failed. A generation's record is checked, refused when it's broken, read back from
 * its bytes, and a tentative one's tries left checked.
 */
package generations_test

import bundle from "../../bundle"
import generations from ".."

main :: fn() -> int {
    made := generation(7, generations.STATE_PERMANENT)
    if generations.check(&made) is_some {
        return 1
    }
    // Each of these is refused
    broken := made
    broken.magic = 0
    if generations.check(&broken) is_none {
        return 2
    }
    broken = made
    broken.state = 9
    if generations.check(&broken) is_none {
        return 3
    }
    broken = made
    broken.file_count = generations.MAX_BOOT_FILES + 1
    if generations.check(&broken) is_none {
        return 4
    }
    // A kernel alone, with no boot set, is one (decisions/0135)
    alone := made
    alone.file_count = 0
    if generations.check(&alone) is_some {
        return 4
    }
    broken = made
    _ = generations.set_name(&broken.files[0].name, "supervisor.elf")
    if generations.check(&broken) is_none {
        return 5
    }
    broken = made
    for i in 0..<broken.command_line.count {
        broken.command_line[i] = 65
    }
    if generations.check(&broken) is_none {
        return 6
    }
    // Only the recovery generation is numbered as it, and it's numbered so
    broken = made
    broken.number = generations.RECOVERY_NUMBER
    if generations.check(&broken) is_none {
        return 12
    }
    broken = made
    broken.state = generations.STATE_RECOVERY
    if generations.check(&broken) is_none {
        return 13
    }
    // Read back from its bytes, and not from bytes of another size
    back :: generations.generation_of(generations.bytes_of(&made)) or_return 7
    if back.number != 7 || generations.text_of(&back.files[1].name) != "system.records" {
        return 8
    }
    if generations.generation_of(view_of(cast[ptr[u8]](&made), 100)) is_some {
        return 9
    }
    // A tentative generation's tries, up to TRIES (decisions/0134)
    tentative := generation(8, generations.STATE_TENTATIVE)
    tentative.tries_left = generations.TRIES
    if generations.check(&tentative) is_some {
        return 10
    }
    tentative.tries_left = generations.TRIES + 1
    if generations.check(&tentative) is_none {
        return 11
    }
    return 0
}

/** A generation numbered number, of the root task and the system records, with test_exit on its command line. */
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
