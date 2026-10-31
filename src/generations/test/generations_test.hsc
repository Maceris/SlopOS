/*
 * The generations package's tests, as a hosted program (tools/unit_tests.py): main returns 0 if everything worked, or
 * the number of the first check that failed. A generation's record is checked, refused when it's broken, read back from
 * its bytes, and written into limine.conf with its kernel and boot set by their objects.
 */
package generations_test

import runtime from "base"
import strings from "std"
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
    broken.file_count = 0
    if generations.check(&broken) is_none {
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
    // limine.conf: an entry each, in the order given, the kernel and every module by its object, named for the kernel
    recovery := generation(generations.RECOVERY_NUMBER, generations.STATE_RECOVERY)
    text : u8[..]
    defer runtime.array_free(&text)
    generations.limine_conf(generations.Generation.[made, recovery], 3, 0, &text)
    conf :: bit_cast[string](text[0..<text.count])
    hex_storage : u8[64]
    kernel_hex :: bundle.hex(made.kernel, &hex_storage)
    for expected in string.["timeout: 3\n", "/SlopOS generation 7\n", "/SlopOS recovery\n", "cmdline: test_exit generation=7\n",
        "module_cmdline: root_task.elf\n", "module_cmdline: system.records\n", "kaslr: yes\n"] {
        if !strings.contains(conf, expected) {
            runtime.log_error("limine.conf lacks %", expected)
            return 10
        }
    }
    newest :: strings.find(conf, "generation 7") or_return 11
    oldest :: strings.find(conf, "/SlopOS recovery") or_return 11
    if !strings.contains(conf, kernel_hex) || newest > oldest {
        return 11
    }
    return 0
}

// A generation numbered number, of the root task and the system records, with test_exit on its command line.
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
