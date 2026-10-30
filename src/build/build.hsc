/*
 * SlopOS's build (decisions/0028): `hemera src/build` builds every target, each checked by the house
 * rules (decisions/0029). The kernel is named here; programs and tests are found: every folder in
 * src/apps, src/services, src/drivers and src/tests is a SlopOS program (decisions/0033, 0058, 0069), every test
 * folder under src a hosted test program (decisions/0033, Tests), and every folder in src/tools a hosted tool, like
 * the image builder (decisions/0088).
 *
 * Settings (--setting=name=value):
 * - targets: all (the default), kernel, programs, tests, or tools.
 * - kernel_output: the kernel's ELF, kernel.elf by default.
 * - programs_output: the folder programs go in, each <name>.elf, the current folder by default, each with its manifest
 *   beside it, <name>.manifest: the schema of its entry's type (decisions/0044), which the store builder puts in its
 *   bundle (decisions/0094); and beside the root task, system.records, the system configuration as data (decisions/0110).
 * - tests_output: the folder test programs go in, the current folder by default.
 * - tools_output: the folder tools go in, the current folder by default.
 * - stack_check: what the kernel's prologue checks do without room, trap (the default) or morestack,
 *   which a boot test of stack segments builds.
 * - arch: the kernel's and the programs' architecture, x86_64 (the default) or aarch64 (roadmap A).
 * - robustness: on, for robustness testing's machinery (src/robustness, decisions/0096): the kernel's failure points,
 *   which fail= on its command line makes fail, and the hosted tests' (SLOPOS_FAIL). off by default, and then none of
 *   it is compiled in. Read by the code with compiler.target_setting, as every target gets the command line's settings.
 */
package build

import compiler from "base"
import runtime from "base"
import os from "std"
import schema from "std"
import text_buffer from "std"
import checks from "../checks"

build :: fn() {
    targets :: compiler.target_setting("targets", default = "all")
    if targets == "all" || targets == "kernel" {
        add_kernel()
    }
    if targets == "all" || targets == "programs" {
        add_programs("../apps")
        add_programs("../services")
        add_programs("../drivers")
        add_programs("../tests")
    }
    if targets == "all" || targets == "tests" {
        add_tests("..")
    }
    if targets == "all" || targets == "tools" {
        add_tools("../tools")
    }
    compiler.add_check(checks.check_program)
    compiler.add_check(write_manifest)
    compiler.add_check(write_system_records)
}

/*
 * The system configuration as data (decisions/0110): system_config's RECORDS, as the root task's program has them,
 * which system_config checked with system_records.check as it was compiled, written beside the root task as
 * system.records, a module of the boot set, which the root task checks again at boot.
 */
write_system_records :: fn(target: ptr[compiler.BuildOptions], program: ptr[compiler.ProgramInfo]) -> bool {
    if target.name != "root_task.elf" {
        return true
    }
    for &package in program.packages {
        if package.name != "system_config" {
            continue
        }
        records :: match compiler.find_constant(package, "RECORDS") {
            case Some(found) => found
            case None => {
                compiler.report_error(package.location, "system_config has no RECORDS to write")
                return false
            }
        }
        size :: type_info_of(records.value.type).size
        bytes :: string_of(cast[ptr[u8]](records.value.data), size)
        separator :: separator_after(target.output_path)
        folder :: if separator <= target.output_path.count { target.output_path[0..<separator] } else { "" }
        path_storage : u8[512]
        path := text_buffer.make(path_storage)
        text_buffer.append(&path, folder)
        text_buffer.append(&path, "system.records")
        if os.write_entire_file(text_buffer.as_string(&path), bytes) != null {
            compiler.report_error(package.location, "couldn't write %", text_buffer.as_string(&path))
            return false
        }
        return true
    }
    compiler.report_error(program.root.location, "the root task has no system_config to write system.records from")
    return false
}

/*
 * A SlopOS program's manifest (decisions/0044): the schema of its main's type (std's schema.write), written beside
 * the program as <name>.manifest. Other targets have none.
 */
write_manifest :: fn(target: ptr[compiler.BuildOptions], program: ptr[compiler.ProgramInfo]) -> bool {
    if target.target_options.os != .SlopOS || !target.target_options.startup_code || !checks.ends_with(target.output_path, ".elf") {
        return true
    }
    main :: match compiler.find_function(program.root, "main") {
        case Some(found) => found
        case None => {
            compiler.report_error(program.root.location, "% has no main, so no manifest", target.name)
            return false
        }
    }
    bytes : u8[..]
    defer runtime.array_free(&bytes)
    schema.write(type_info_of(main.type), &bytes)
    path_storage : u8[512]
    path := text_buffer.make(path_storage)
    text_buffer.append(&path, string_of(cast[ptr[u8]](target.output_path.data), target.output_path.count - 4))
    text_buffer.append(&path, ".manifest")
    written :: if bytes.count > 0 { string_of(cast[ptr[u8]](bytes.data), bytes.count) } else { "" }
    if os.write_entire_file(text_buffer.as_string(&path), written) != null {
        compiler.report_error(program.root.location, "couldn't write %", text_buffer.as_string(&path))
        return false
    }
    return true
}

/*
 * The kernel, booted by Limine: freestanding, entered at kernel_entry with its own carrier block, no red
 * zone and no SIMD (design/arch-x86-64.md), and stack checks that trap. On AArch64 that's no floating
 * point or Advanced SIMD, which trap at EL1 too until CPACR_EL1 allows them.
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
    if compiler.target_setting("stack_check", default = "trap") == "morestack" {
        kernel.target_options.stack_check_failure = .Morestack
    }
    kernel.target_options.cpu_features = "-mmx,-sse,-sse2,-avx,-avx2,+soft-float"
    kernel.target_options.linker_script = "../boot/limine/x86_64.ld"
    if compiler.target_setting("arch", default = "x86_64") == "aarch64" {
        kernel.target_options.architecture = .arm64
        kernel.target_options.cpu_features = "-fp-armv8,-neon"
        kernel.target_options.linker_script = "../boot/limine/aarch64.ld"
    }
    target :: compiler.add_target(kernel)
}

/*
 * Every folder in folder, as a SlopOS program named after it: a position-independent executable for
 * x86-64-v3 (decisions/0003, 0004), or AArch64's ARMv8.2-A with LSE (0061), which its loader relocates and
 * starts with its startup block.
 */
add_programs :: fn(folder: string) {
    for subfolder in compiler.subfolders(folder) {
        name :: last_part(subfolder)
        output_storage : u8[512]
        output := text_buffer.make(output_storage)
        text_buffer.append(&output, compiler.target_setting("programs_output", default = "."))
        text_buffer.append(&output, "/")
        text_buffer.append(&output, name)
        text_buffer.append(&output, ".elf")
        program := compiler.command_line_options()
        program.name = name
        program.root = subfolder
        program.output_path = text_buffer.as_string(&output)
        program.target_options.os = .SlopOS
        program.target_options.architecture = .x86_64
        program.target_options.cpu = "x86-64-v3"
        if compiler.target_setting("arch", default = "x86_64") == "aarch64" {
            program.target_options.architecture = .arm64
            // The baseline, which Hemera gives AArch64 without a CPU
            program.target_options.cpu = ""
        }
        program.target_options.relocation_model = .Default
        program.target_options.startup_code = true
        target :: compiler.add_target(program)
    }
}

// Every folder in folder, as a hosted program named after it, for this machine.
add_tools :: fn(folder: string) {
    for subfolder in compiler.subfolders(folder) {
        name :: last_part(subfolder)
        output_storage : u8[512]
        output := text_buffer.make(output_storage)
        text_buffer.append(&output, compiler.target_setting("tools_output", default = "."))
        text_buffer.append(&output, "/")
        text_buffer.append(&output, name)
        tool := compiler.command_line_options()
        tool.name = name
        tool.root = subfolder
        tool.output_path = text_buffer.as_string(&output)
        target :: compiler.add_target(tool)
    }
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
