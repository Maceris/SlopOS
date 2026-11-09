package arch_aarch64

import runtime from "base"
import aarch64 from "base/intrinsics"
import slop_os from "std/os"
import arch_interface from "../../arch_interface"

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

// Pointer authentication (decisions/0186): the A instruction key, APIAKeyLo_EL1 and APIAKeyHi_EL1, and SCTLR_EL1.EnIA
/** SCTLR_EL1.EnIA (bit 31): PACIA and AUTIA, and PACIASP and AUTIASP, sign and authenticate with the A key. */
SCTLR_ENABLE_IA : u64 : 1 << 31

/**
 * Give the kernel's pointer authentication key (arch_interface.set_kernel_pointer_key): kept for idle to load.
 *
 * @param system The shared state, whose kernel_key is set.
 * @param key The key's 128 bits, random.
 */
set_kernel_pointer_key :: fn(system: ptr[mut ArchSystem], key: u64[2]) {
    system.kernel_key = key
}

/**
 * Say which key the calling CPU returns to user mode with (arch_interface.set_user_pointer_key).
 *
 * @param key The thread's process's key's 128 bits, kept in the CPU's ArchCpu for return_to_user.
 */
set_user_pointer_key :: fn(key: u64[2]) {
    current_cpu().user_key = key
}

/**
 * Say what control-flow integrity the kernel's code runs under on the calling CPU (arch_interface.kernel_control_flow):
 * landing pads where it has BTI, as its code is guarded then; signed returns once pointer authentication is on.
 *
 * @return Each that's on.
 */
kernel_control_flow :: fn() -> arch_interface.KernelControlFlow {
    shadow_stack :: current_system().gcs && aarch64.read_system_register_encoded(3, 0, 2, 5, 0) & GCSCR_ON != 0
    return arch_interface.KernelControlFlow.{
        landing_pads = has_branch_target_identification(),
        signed_returns = aarch64.read_system_register(.SCTLR_EL1) & SCTLR_ENABLE_IA != 0,
        // GCSCR_EL1 (S3_0_C2_C5_0)
        shadow_stack = shadow_stack,
        // GCSPR_EL1 (S3_0_C2_C5_1)
        shadow_stack_pointer = if shadow_stack { aarch64.read_system_register_encoded(3, 0, 2, 5, 1) } else { cast[u64](0) },
    }
}

/**
 * Tell whether the kernel's code runs on Guarded Control Stacks (arch_interface.has_kernel_shadow_stacks): where
 * permission indirection and GCS are on, as for user threads.
 *
 * @return True where enable_permission_indirection turned them on.
 */
has_kernel_shadow_stacks :: fn() -> bool {
    return current_system().gcs
}

/**
 * Give a CPU its kernel Guarded Control Stack (arch_interface.set_kernel_shadow_stack): kept for idle and
 * return_to_user, which start it from its top and turn it on.
 *
 * @param cpu The CPU's own state, whose kernel_shadow_top is set.
 * @param base The GCS's lowest address.
 * @param size Its size in bytes.
 */
set_kernel_shadow_stack :: fn(cpu: ptr[mut ArchCpu], base: u64, size: u64) {
    cpu.kernel_shadow_top = base + size
}

/**
 * Tell whether the calling CPU has pointer authentication, whose keys idle and return_to_user load (decisions/0186).
 * They load them in their own bodies, which never return, rather than here: a function that returns signed its return
 * address with the key or the setting before, and would fail to authenticate it once they're changed.
 *
 * @return True where ID_AA64ISAR1_EL1 has an address authentication algorithm, APA or API.
 */
has_pointer_authentication :: fn() -> bool {
    return aarch64.read_system_register(.ID_AA64ISAR1_EL1) & 0xff0 != 0
}

/*
 * Permission indirection (FEAT_S1PIE) and the Guarded Control Stack (FEAT_GCS), decisions/0186: a descriptor's UXN, PXN,
 * DBM and AP[1] bits read as a 4-bit index into PIR_EL1 for EL1's permissions and PIRE0_EL1 for EL0's, which can say
 * "a GCS page", as the plain bits can't. Each index leaf_entry makes:
 *     0x5 user RX (PXN, AP[1]), 0x8 kernel RX (UXN), 0xa kernel GCS (UXN, DBM), 0xb user GCS (UXN, DBM, AP[1]),
 *     0xc kernel R (UXN, PXN),
 *     0xd user R (UXN, PXN, AP[1]), 0xe kernel RW (UXN, PXN, DBM), 0xf user RW (UXN, PXN, DBM, AP[1]);
 * every other index is no access. The kernel reaches user pages as before (PAN still applies), not GCS pages.
 *
 * SPEC: Arm ARM (DDI 0487) D8.4.1 (permission indirection), D11 (the Guarded Control Stack); PIR_EL1, PIRE0_EL1,
 * TCR2_EL1, GCSCRE0_EL1, GCSPR_EL0.
 */
/** A permission's 4-bit encoding, without permission overlays: read. */
PERMISSION_R : u64 : 0x8
/** Read, and a Guarded Control Stack's own writes. */
PERMISSION_GCS : u64 : 0x9
/** Read and execute. */
PERMISSION_RX : u64 : 0xa
/** Read and write. */
PERMISSION_RW : u64 : 0xc
/** PIRE0_EL1: what EL0 may do through each index. */
PERMISSIONS_EL0 : u64 : (PERMISSION_RX << (0x5 * 4)) | (PERMISSION_GCS << (0xb * 4)) | (PERMISSION_R << (0xd * 4))
    | (PERMISSION_RW << (0xf * 4))
/** PIR_EL1: what EL1 may do through each index; a user GCS page, nothing. */
PERMISSIONS_EL1 : u64 : (PERMISSION_R << (0x5 * 4)) | (PERMISSION_RX << (0x8 * 4)) | (PERMISSION_GCS << (0xa * 4))
    | (PERMISSION_R << (0xc * 4)) | (PERMISSION_R << (0xd * 4)) | (PERMISSION_RW << (0xe * 4)) | (PERMISSION_RW << (0xf * 4))
/** TCR2_EL1.PIE (bit 1): permission indirection on. */
TCR2_PIE : u64 : 1 << 1
/** GCSCR_EL1.PCRSEL (bit 0): EL1's procedure returns checked against its GCS, GCSPR_EL1. */
GCSCR_ON : u64 : 1 << 0
/** GCSCRE0_EL1.PCRSEL (bit 0): EL0's procedure returns checked against its GCS. */
GCSCRE0_ON : u64 : 1 << 0
/** GCSCRE0_EL1.nTR (bit 10): EL0 reads GCSPR_EL0 without a trap, as the fiber switches do. */
GCSCRE0_READS : u64 : 1 << 10

/**
 * Tell whether the calling CPU has permission indirection and TCR2_EL1, which turns it on: ID_AA64MMFR3_EL1's S1PIE
 * (bits 8 to 11) and TCRX (bits 0 to 3).
 *
 * @return True if both are there.
 */
has_permission_indirection :: fn() -> bool {
    features :: aarch64.read_system_register_encoded(3, 0, 0, 7, 3)
    return (features >> 8) & 0xf != 0 && features & 0xf != 0
}

/**
 * Turn permission indirection on for the calling CPU, where it has it and the Guarded Control Stack, which needs it:
 * PIR_EL1 and PIRE0_EL1 as leaf_entry's indexes need, then TCR2_EL1.PIE. Called as the CPU first switches to the
 * kernel's own tables, every entry one leaf_entry made, before its TLB is flushed.
 *
 * @param system The shared state, whose gcs is set where it's turned on, on the boot CPU, and kept by the others.
 */
enable_permission_indirection :: fn(system: ptr[mut ArchSystem]) {
    features :: detect_features()
    if !has(&features, .Aarch64Gcs) || !has_permission_indirection() {
        return void
    }
    // PIR_EL1 (S3_0_C10_C2_3), PIRE0_EL1 (S3_0_C10_C2_2), TCR2_EL1 (S3_0_C2_C0_3)
    aarch64.write_system_register_encoded(3, 0, 10, 2, 3, PERMISSIONS_EL1)
    aarch64.write_system_register_encoded(3, 0, 10, 2, 2, PERMISSIONS_EL0)
    aarch64.isb()
    aarch64.write_system_register_encoded(3, 0, 2, 0, 3, aarch64.read_system_register_encoded(3, 0, 2, 0, 3) | TCR2_PIE)
    aarch64.isb()
    system.gcs = true
}

/**
 * Tell whether the calling CPU gives user threads shadow stacks (arch_interface.has_user_shadow_stacks): the Guarded
 * Control Stack, with permission indirection on.
 *
 * @return True where enable_permission_indirection turned it on.
 */
has_user_shadow_stacks :: fn() -> bool {
    return current_system().gcs
}

/**
 * Set user mode's control-flow integrity for a thread (arch_interface.load_user_control_flow): its Guarded Control
 * Stack, GCSPR_EL0 and GCSCRE0_EL1, where it has one. Landing pads are checked by page (PROTECTION_GUARDED).
 *
 * @param landing_pads Unused.
 * @param shadow_stack Its GCS pointer; 0 for none, which turns EL0's GCS off.
 */
load_user_control_flow :: fn(landing_pads: bool, shadow_stack: u64) {
    if !current_system().gcs {
        return void
    }
    // GCSPR_EL0 (S3_3_C2_C5_1), GCSCRE0_EL1 (S3_0_C2_C5_2)
    if shadow_stack != 0 {
        aarch64.write_system_register_encoded(3, 3, 2, 5, 1, shadow_stack)
        aarch64.write_system_register_encoded(3, 0, 2, 5, 2, GCSCRE0_ON | GCSCRE0_READS)
    }
    else {
        aarch64.write_system_register_encoded(3, 0, 2, 5, 2, 0)
    }
}

/**
 * Read user mode's GCS pointer (arch_interface.read_user_shadow_stack).
 *
 * @return GCSPR_EL0; 0 where GCS isn't on.
 */
read_user_shadow_stack :: fn() -> u64 {
    if !current_system().gcs {
        return 0
    }
    return aarch64.read_system_register_encoded(3, 3, 2, 5, 1)
}
