/**
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
 *   beside it, <name>.manifest: the schema of its entry's type (decisions/0044), and <name>.docs, its documentation
 *   (decisions/0174), which the store builder puts in its bundle (decisions/0094); and beside the root task,
 *   system.records, the system configuration as data (decisions/0110).
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
import bundle from "../bundle"
import checks from "../checks"

/**
 * Add every target the targets setting asks for, and the checks every target's program goes through: the house
 * rules, the manifests, and system.records.
 *
 * It's run at compile time, by the #run at the file's end.
 */
build :: fn() {
    targets :: compiler.target_setting("targets", default = "all")
    if targets == "all" || targets == "kernel" {
        add_kernel()
    }
    if targets == "all" || targets == "programs" {
        add_libraries("../libraries")
        add_programs("../apps")
        add_programs("../services")
        add_programs("../drivers")
        add_programs("../tests")
        add_uefi_programs("../uefi")
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

/**
 * Write the system configuration as data (decisions/0110) beside the root task, as system.records, a module of the
 * boot set, which the root task checks again at boot.
 *
 * What's written is system_config's RECORDS, its bytes as the root task's program has them, which system_config
 * checked with system_records.check as it was compiled. A compiler check, run for every target.
 *
 * @param target The target being built; only root_task.elf's is written for.
 * @param program The target's program, which has to have the system_config package.
 * @return True when it's written, or the target isn't the root task's; false, with an error reported, if
 *     system_config isn't in the program, has no RECORDS, or the file couldn't be written.
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

/**
 * Write a SlopOS program's manifest (decisions/0044): the schema of its main's type (std's schema.write), beside the
 * program as <name>.manifest, its output's name with .elf replaced. A compiler check, run for every target.
 *
 * @param target The target being built; only a SlopOS program with startup code, whose output ends in .elf, has one.
 * @param program The target's program, whose root package's main is described.
 * @return True when it's written, or the target has none; false, with an error reported, if the program has no main or
 *     the file couldn't be written.
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
    return write_documentation(target, program, main)
}

/**
 * Join a documentation comment's text's lines back into its paragraphs, for a terminal to wrap as wide as it is: a
 * line break alone becomes a space, and a blank line between paragraphs stays one.
 *
 * @param text The text, its lines' margins already taken off.
 * @return The text unwrapped, from context's allocator at compile time, never freed; text itself when it has no line
 *     break.
 */
unwrapped :: fn(text: string) -> string {
    bytes :: string_bytes(text)
    made : u8[..]
    for byte, i in bytes {
        alone :: byte == 10 && (i == 0 || bytes[i - 1] != 10) && (i + 1 >= bytes.count || bytes[i + 1] != 10)
        runtime.array_add(&made, if alone { cast[u8](' ') } else { byte })
    }
    return if made.count > 0 { string_of(&made[0], made.count) } else { text }
}

/**
 * Write a SlopOS program's documentation (decisions/0174) beside its manifest, as <name>.docs: a record of a
 * bundle.Documentation made from its main's documentation comment, which its bundle refers to, for help and completion.
 *
 * @param target The target being built, a SlopOS program whose output ends in .elf.
 * @param program The target's program, for where an error is reported.
 * @param main The program's main, whose documentation comment and parameters' documentation are written; one without
 *     a comment writes a Documentation with nothing in it.
 * @return True once it's written; false, with an error reported, if the file couldn't be.
 */
write_documentation :: fn(target: ptr[compiler.BuildOptions], program: ptr[compiler.ProgramInfo], main: compiler.FunctionInfo) -> bool {
    parameters : bundle.Described[..]
    defer runtime.array_free(&parameters)
    for parameter in main.parameters {
        if parameter.documentation.count > 0 {
            runtime.array_add(&parameters, bundle.Described.{name = parameter.name, text = unwrapped(parameter.documentation)})
        }
    }
    results : string[..]
    defer runtime.array_free(&results)
    errors : bundle.Described[..]
    defer runtime.array_free(&errors)
    others : bundle.Described[..]
    defer runtime.array_free(&others)
    for tag in main.documentation.tags {
        if tag.tag == "return" {
            runtime.array_add(&results, unwrapped(tag.text))
        }
        else if tag.tag == "error" {
            runtime.array_add(&errors, bundle.Described.{name = tag.name, text = unwrapped(tag.text)})
        }
        else if tag.tag == "example" {
            runtime.array_add(&others, bundle.Described.{name = tag.tag, text = tag.text})
        }
        else if tag.tag != "param" && tag.tag != "tparam" {
            runtime.array_add(&others, bundle.Described.{name = tag.tag, text = unwrapped(tag.text)})
        }
    }
    made :: bundle.Documentation.{summary = unwrapped(main.documentation.brief), details = unwrapped(main.documentation.details),
        parameters = parameters[0..<parameters.count], results = results[0..<results.count], errors = errors[0..<errors.count],
        others = others[0..<others.count]}
    record : u8[..]
    defer runtime.array_free(&record)
    bundle.write(made, &record)
    path_storage : u8[512]
    path := text_buffer.make(path_storage)
    text_buffer.append(&path, string_of(cast[ptr[u8]](target.output_path.data), target.output_path.count - 4))
    text_buffer.append(&path, ".docs")
    written :: if record.count > 0 { string_of(cast[ptr[u8]](record.data), record.count) } else { "" }
    if os.write_entire_file(text_buffer.as_string(&path), written) != null {
        compiler.report_error(program.root.location, "couldn't write %", text_buffer.as_string(&path))
        return false
    }
    return true
}

/**
 * Add the kernel as a target, booted by SlopOS's own bootloader (decisions/0133): freestanding, entered at
 * kernel_entry with its own carrier block, no red zone and no SIMD (design/arch-x86-64.md), and stack checks that
 * trap, or call morestack with stack_check=morestack. On AArch64 that's no floating point or Advanced SIMD, which trap
 * at EL1 too until CPACR_EL1 allows them.
 *
 * Its output is the kernel_output setting, kernel.elf by default; its root is src/boot/slopos, with its linker script
 * for the architecture.
 */
add_kernel :: fn() {
    kernel := compiler.command_line_options()
    kernel.name = "kernel"
    kernel.root = "../boot/slopos"
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
    kernel.target_options.linker_script = "../boot/slopos/x86_64.ld"
    if compiler.target_setting("arch", default = "x86_64") == "aarch64" {
        kernel.target_options.architecture = .arm64
        kernel.target_options.cpu_features = "-fp-armv8,-neon"
        kernel.target_options.linker_script = "../boot/slopos/aarch64.ld"
    }
    target :: compiler.add_target(kernel)
}

/**
 * Add every folder in a folder as a SlopOS program named after it: a position-independent executable for x86-64-v3
 * (decisions/0003, 0004), or AArch64's baseline with arch=aarch64 (0061), which its loader relocates and starts with
 * its startup block.
 *
 * Each is <name>.elf in the programs_output folder, linked against service_kit's library and any PROGRAM_LIBRARIES
 * names for it. hello has a second build, hello_next.elf, with hello_build=next, for the test of generations applied
 * live (decisions/0126).
 *
 * @param folder The folder whose subfolders are programs, relative to src/build.
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
        /*
         * Every program has debug info, which Hemera puts in <name>.debug beside it rather than in the program, for the
         * debugger and crash reports (decisions/0185, 12e); the program itself is built as it was
         */
        program.backend_options.debug_info = true
        // Built apart from the program, which holds its output's storage
        linked : compiler.LinkedLibrary[..]
        // Every program's calls to service_kit go through its library, which none that doesn't call it is given
        runtime.array_add(&linked, compiler.LinkedLibrary.{target = "service_kit"})
        for i in 0..<PROGRAM_LIBRARIES.count {
            if PROGRAM_LIBRARIES[i].program == name {
                runtime.array_add(&linked, compiler.LinkedLibrary.{target = PROGRAM_LIBRARIES[i].library})
            }
        }
        program.libraries = linked
        target :: compiler.add_target(program)
        // hello's second build, which says so, for the test of generations applied live (decisions/0126)
        if name == "hello" {
            next_storage : u8[512]
            next := text_buffer.make(next_storage)
            text_buffer.append(&next, compiler.target_setting("programs_output", default = "."))
            text_buffer.append(&next, "/hello_next.elf")
            second := program
            second.name = "hello_next"
            second.output_path = text_buffer.as_string(&next)
            settings : compiler.TargetSetting[..]
            runtime.array_add(&settings, compiler.TargetSetting.{name = "hello_build", value = "next"})
            second.settings = settings
            next_target :: compiler.add_target(second)
        }
    }
}

/** A program that calls a library other than service_kit, which all do (decisions/0120, 0121), by their names. */
ProgramLibrary :: struct {
    /** The program's name, its folder's. */
    program : string,
    /** The library's name, its target's, which the program is linked against. */
    library : string,
}

/** Each program that calls a library other than service_kit, and which: test_libraries calls greeting. */
PROGRAM_LIBRARIES :: ProgramLibrary.[ProgramLibrary.{program = "test_libraries", library = "greeting"}]

/**
 * Add every folder in a folder as a SlopOS typed library named after it (decisions/0119, 0120), <name>.library in the
 * programs_output folder: its #export functions its interface, position-independent, for the programs' architecture,
 * which a program's runtime binds from the grant it's given (library:<name>.library).
 *
 * service_kit has a second build, service_kit_plus.library, with service_kit_build=plus, for substitution's test
 * (decisions/0122).
 *
 * @param folder The folder whose subfolders are libraries, relative to src/build.
 */
add_libraries :: fn(folder: string) {
    for subfolder in compiler.subfolders(folder) {
        name :: last_part(subfolder)
        output_storage : u8[512]
        output := text_buffer.make(output_storage)
        text_buffer.append(&output, compiler.target_setting("programs_output", default = "."))
        text_buffer.append(&output, "/")
        text_buffer.append(&output, name)
        text_buffer.append(&output, ".library")
        library := compiler.command_line_options()
        library.name = name
        library.root = subfolder
        library.output_path = text_buffer.as_string(&output)
        library.target_options.os = .SlopOS
        library.target_options.architecture = .x86_64
        library.target_options.cpu = "x86-64-v3"
        if compiler.target_setting("arch", default = "x86_64") == "aarch64" {
            library.target_options.architecture = .arm64
            library.target_options.cpu = ""
        }
        library.target_options.relocation_model = .Default
        library.target_options.output_type = .DynamicLibrary
        target :: compiler.add_target(library)
        // service_kit's second build, with one export more, for substitution's test (decisions/0122)
        if name == "service_kit" {
            plus_storage : u8[512]
            plus := text_buffer.make(plus_storage)
            text_buffer.append(&plus, compiler.target_setting("programs_output", default = "."))
            text_buffer.append(&plus, "/service_kit_plus.library")
            second := library
            second.name = "service_kit_plus"
            second.output_path = text_buffer.as_string(&plus)
            settings : compiler.TargetSetting[..]
            runtime.array_add(&settings, compiler.TargetSetting.{name = "service_kit_build", value = "plus"})
            second.settings = settings
            plus_target :: compiler.add_target(second)
        }
    }
}

/**
 * Add every folder in a folder as a UEFI application named after it (roadmap B, decisions/0131), <name>.efi in the
 * programs_output folder, for the programs' architecture, which the firmware runs: the bootloader, and the tests of
 * Hemera's UEFI target.
 *
 * @param folder The folder whose subfolders are UEFI applications, relative to src/build.
 */
add_uefi_programs :: fn(folder: string) {
    for subfolder in compiler.subfolders(folder) {
        name :: last_part(subfolder)
        output_storage : u8[512]
        output := text_buffer.make(output_storage)
        text_buffer.append(&output, compiler.target_setting("programs_output", default = "."))
        text_buffer.append(&output, "/")
        text_buffer.append(&output, name)
        text_buffer.append(&output, ".efi")
        program := compiler.command_line_options()
        program.name = name
        program.root = subfolder
        program.output_path = text_buffer.as_string(&output)
        program.target_options.os = .UEFI
        program.target_options.architecture = .x86_64
        program.target_options.cpu = "x86-64"
        if compiler.target_setting("arch", default = "x86_64") == "aarch64" {
            program.target_options.architecture = .arm64
            program.target_options.cpu = ""
        }
        program.target_options.startup_code = true
        target :: compiler.add_target(program)
    }
}

/**
 * Add every folder in a folder as a hosted program named after it, for this machine, in the tools_output folder.
 *
 * @param folder The folder whose subfolders are tools, relative to src/build.
 */
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

/**
 * Add every folder named test under a folder, at any depth, as a hosted program named after the package it tests,
 * <package>_test in the tests_output folder.
 *
 * A test package with a main of its own, as one the robustness sweeps run through robustness/hosted is, starts there;
 * any other is built as a test program, its #test functions run and reported by the entry Hemera gives it
 * (decisions/0175).
 *
 * @param folder The folder searched, relative to src/build; a test folder's own subfolders aren't.
 */
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
        info :: compiler.load_package(subfolder) or_else compiler.PackageInfo.{}
        test.test = compiler.find_function(&info, "main") is_none
        target :: compiler.add_target(test)
    }
}

/**
 * Give the last part of a path, after its last separator.
 *
 * @param path The path, with / or \ separators.
 * @return What's after the last separator, a view into path; all of it without one, empty if it ends in one.
 */
last_part :: fn(path: string) -> string {
    after :: separator_after(path)
    runtime.assert(after <= path.count, "separator_after is inside the path")
    return path[after..<path.count]
}

/**
 * Give a path without its last part.
 *
 * @param path The path, with / or \ separators.
 * @return What's before the last separator, a view into path; empty without one.
 */
parent_of :: fn(path: string) -> string {
    after :: separator_after(path)
    runtime.assert(after <= path.count, "separator_after is inside the path")
    if after == 0 {
        return ""
    }
    return path[0..<after - 1]
}

/**
 * Find where the last part of a path starts.
 *
 * @param path The path, with / or \ separators.
 * @return The index just after its last / or \, at most path's count; 0 without one.
 */
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
