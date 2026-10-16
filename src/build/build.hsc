/*
 * SlopOS's build (decisions/0028): `hemera src/build` builds every target, each checked by the house
 * rules (decisions/0029). The kernel is named here; tests are found, every test folder under src being a
 * hosted test program (decisions/0033, Tests).
 *
 * Settings (--setting=name=value):
 * - targets: all (the default), kernel, or tests.
 * - kernel_output: the kernel's ELF, kernel.elf by default.
 * - tests_output: the folder test programs go in, the current folder by default.
 */
package build

import compiler from "base"
import runtime from "base"
import text_buffer from "std"
import checks from "../checks"

build :: fn() {
    targets :: compiler.target_setting("targets", default = "all")
    if targets == "all" || targets == "kernel" {
        add_kernel()
    }
    if targets == "all" || targets == "tests" {
        add_tests("..")
    }
    compiler.add_check(checks.check_program)
}

/*
 * The kernel, booted by Limine: freestanding, entered at kernel_entry with its own carrier block, no red
 * zone and no SIMD (design/arch-x86-64.md), and stack checks that trap.
 */
add_kernel :: fn() {
    kernel := compiler.command_line_options()
    kernel.name = "kernel"
    kernel.root = "../boot/limine"
    kernel.entry = "kernel_entry"
    kernel.output_path = compiler.target_setting("kernel_output", default = "kernel.elf")
    kernel.target_options.os = .None
    kernel.target_options.startup_code = false
    kernel.target_options.red_zone = false
    kernel.target_options.stack_check_failure = .Trap
    kernel.target_options.cpu_features = "-mmx,-sse,-sse2,-avx,-avx2,+soft-float"
    kernel.target_options.linker_script = "../boot/limine/x86_64.ld"
    target :: compiler.add_target(kernel)
}

// Every test folder under folder, as a hosted program named after the package it tests.
add_tests :: fn(folder: string) {
    for subfolder in compiler.subfolders(folder) {
        name :: last_part(subfolder)
        if name != "test" {
            add_tests(subfolder)
            continue
        }
        storage : u8[256]
        test_name := text_buffer.make(storage)
        text_buffer.append(&test_name, last_part(parent_of(subfolder)))
        text_buffer.append(&test_name, "_test")
        output_storage : u8[512]
        output := text_buffer.make(output_storage)
        text_buffer.append(&output, compiler.target_setting("tests_output", default = "."))
        text_buffer.append(&output, "/")
        text_buffer.append(&output, text_buffer.as_string(&test_name))
        test := compiler.command_line_options()
        test.name = text_buffer.as_string(&test_name)
        test.root = subfolder
        test.output_path = text_buffer.as_string(&output)
        target :: compiler.add_target(test)
    }
}

// The last part of a path, after its last separator.
last_part :: fn(path: string) -> string {
    after :: separator_after(path)
    runtime.assert(after <= path.count, "separator_after is inside the path")
    return path[after..<path.count]
}

// A path without its last part.
parent_of :: fn(path: string) -> string {
    after :: separator_after(path)
    runtime.assert(after <= path.count, "separator_after is inside the path")
    if after == 0 {
        return ""
    }
    return path[0..<after - 1]
}

// Where the last part of a path starts: just after its last / or \, or 0.
separator_after :: fn(path: string) -> usize {
    start : usize = 0
    for character, index in path {
        if character == '/' || character == '\\' {
            start = index + 1
        }
    }
    return start
}

#run build()
