package arch_aarch64

import runtime from "base"
import slop_os from "std/os"

/*
 * What the CPU has against exploits and transient execution (decisions/0186, 0097, 0013): which control-flow integrity
 * mechanisms it has, and which transient-execution issues apply to it, from its ID registers, logged at boot. Nothing
 * is turned on for transient execution: PAN, which the baseline has, is on already (init_cpu).
 *
 * SPEC: Arm ARM (DDI 0487) D19.2: ID_AA64PFR0_EL1.CSV2 (bits 56 to 59) and CSV3 (60 to 63), ID_AA64PFR1_EL1.SSBS
 * (4 to 7).
 */

/**
 * Log, at boot, what the CPU has against exploits and transient execution (arch_interface.log_hardening): its
 * control-flow integrity mechanisms, the transient-execution issues that apply to it, and the mitigations on.
 *
 * @param features The boot CPU's features, from detect_features.
 */
log_hardening :: fn(features: ptr[slop_os.CpuFeatures]) {
    runtime.log_info("cpu: control-flow integrity: branch target identification %, pointer authentication %, guarded control stack %",
        yes_no(has(features, .Aarch64Bti)), yes_no(has(features, .Aarch64PointerAuthentication)), yes_no(has(features, .Aarch64Gcs)))
    pfr0 :: id_register(.Pfr0)
    pfr1 :: id_register(.Pfr1)
    affected : LogLine
    unaffected : LogLine
    // CSV2: branch targets aren't speculated across contexts; CSV3: faulting loads don't forward data
    line_add(if (pfr0 >> 56) & 0xf >= 1 { &unaffected } else { &affected }, "Spectre v2")
    line_add(if (pfr0 >> 60) & 0xf >= 1 { &unaffected } else { &affected }, "Meltdown")
    if affected.count == 0 {
        runtime.log_info("cpu: transient execution: affected by Spectre v1; not affected by %", line_text(&unaffected, "anything"))
    }
    else {
        runtime.log_info("cpu: transient execution: affected by Spectre v1, %; not affected by %", line_text(&affected, ""),
            line_text(&unaffected, "anything"))
    }
    runtime.log_info("cpu: mitigations on: PAN; speculative store bypass control (SSBS) %", yes_no((pfr1 >> 4) & 0xf >= 1))
}

/**
 * Say yes or no.
 *
 * @param value The answer.
 * @return "yes" or "no", constants.
 */
yes_no :: fn(value: bool) -> string {
    return if value { "yes" } else { "no" }
}

/** A list of names for a log line, separated by commas, in a buffer of its own; names past it are left out. */
LogLine :: struct {
    /** The text so far. */
    bytes : u8[256],
    /** How many of bytes are used. */
    count : usize,
}

/**
 * Add a name to a list, after a comma if it isn't the first.
 *
 * @param line The list.
 * @param name The name; its bytes past the buffer's end are left out.
 */
line_add :: fn(line: ptr[mut LogLine], name: string) {
    if line.count > 0 {
        line_append(line, ", ")
    }
    line_append(line, name)
}

/**
 * Add text to a list as it is.
 *
 * @param line The list.
 * @param text The text; its bytes past the buffer's end are left out.
 */
line_append :: fn(line: ptr[mut LogLine], text: string) {
    for byte in string_bytes(text) {
        at :: line.count
        if at >= line.bytes.count {
            return void
        }
        line.bytes[at] = byte
        line.count += 1
    }
}

/**
 * Give a list's text, or something else for an empty one.
 *
 * @param line The list, whose buffer the text views.
 * @param empty What to give for an empty list.
 * @return The text, valid while the list is.
 */
line_text :: fn(line: ptr[LogLine], empty: string) -> string {
    if line.count == 0 {
        return empty
    }
    return string_of(&line.bytes[0], line.count)
}
