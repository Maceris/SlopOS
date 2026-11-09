package arch_x86_64

import runtime from "base"
import x86_64 from "base/intrinsics"
import slop_os from "std/os"

/*
 * What the CPU has against exploits and transient execution (decisions/0186, 0097, 0013): which control-flow integrity
 * mechanisms it has, logged; which transient-execution issues apply to it, from IA32_ARCH_CAPABILITIES, logged; and
 * the one mitigation that costs close to nothing, enhanced IBRS, turned on in each CPU where it's there.
 *
 * SPEC: Intel SDM Vol. 4, IA32_ARCH_CAPABILITIES (10AH) and IA32_SPEC_CTRL (48H); Vol. 2A, CPUID leaf 07H.
 */

/** The speculation control MSR. */
IA32_SPEC_CTRL : u32 : 0x48
/** The MSR that says which transient-execution issues the CPU isn't affected by, and what it can do about the rest. */
IA32_ARCH_CAPABILITIES : u32 : 0x10a
/** IA32_SPEC_CTRL.IBRS: with IBRS_ALL, enhanced IBRS, set once and left on. */
SPEC_CTRL_IBRS : u64 : 1 << 0
/** CPUID.(07H,0).EDX: IA32_SPEC_CTRL is there, with IBRS. */
CPUID_SPEC_CTRL : u32 : 1 << 26
/** CPUID.(07H,0).EDX: IA32_ARCH_CAPABILITIES is there. */
CPUID_ARCH_CAPABILITIES : u32 : 1 << 29
/** IA32_ARCH_CAPABILITIES.IBRS_ALL: enhanced IBRS, which protects once set rather than at every entry. */
CAPABILITY_IBRS_ALL : u64 : 1 << 1

/** A transient-execution issue, and the IA32_ARCH_CAPABILITIES bits that together say the CPU isn't affected. */
Issue :: struct {
    /** Its usual name. */
    name : string,
    /** The bits; all of them set means not affected. */
    unaffected : u64,
}

/**
 * The issues IA32_ARCH_CAPABILITIES reports on, by their bits: RDCL_NO (0), SSB_NO (4), MDS_NO (5), TAA_NO (8),
 * SBDR_SSDP_NO, FBSDP_NO and PSDP_NO (13 to 15), BHI_NO (20), PBRSB_NO (24), GDS_NO (26) and RFDS_NO (27). Spectre
 * v1 applies to every CPU and isn't listed.
 */
ISSUES :: Issue.[
    .{"Meltdown", 1 << 0},
    .{"speculative store bypass", 1 << 4},
    .{"MDS", 1 << 5},
    .{"TAA", 1 << 8},
    .{"MMIO stale data", (1 << 13) | (1 << 14) | (1 << 15)},
    .{"BHI", 1 << 20},
    .{"PBRSB", 1 << 24},
    .{"GDS", 1 << 26},
    .{"RFDS", 1 << 27},
]

/**
 * Read IA32_ARCH_CAPABILITIES, where CPUID says it's there.
 *
 * @return Its value; null on a CPU without it, which reports nothing it isn't affected by.
 */
arch_capabilities :: fn() -> u64? {
    if x86_64.cpuid(0).eax < 7 || x86_64.cpuid(7, 0).edx & CPUID_ARCH_CAPABILITIES == 0 {
        return null
    }
    return x86_64.rdmsr(IA32_ARCH_CAPABILITIES)
}

/**
 * Tell whether the calling CPU has enhanced IBRS: IA32_SPEC_CTRL, and IBRS_ALL in IA32_ARCH_CAPABILITIES.
 *
 * @return True if it has.
 */
has_enhanced_ibrs :: fn() -> bool {
    capabilities :: arch_capabilities() or_return false
    return capabilities & CAPABILITY_IBRS_ALL != 0 && x86_64.cpuid(7, 0).edx & CPUID_SPEC_CTRL != 0
}

/**
 * Turn on the calling CPU's speculation controls that cost close to nothing (decisions/0186): enhanced IBRS, where
 * it's there. Called by init_cpu, on each CPU.
 */
enable_speculation_controls :: fn() {
    if has_enhanced_ibrs() {
        x86_64.wrmsr(IA32_SPEC_CTRL, x86_64.rdmsr(IA32_SPEC_CTRL) | SPEC_CTRL_IBRS)
    }
}

/**
 * Log, at boot, what the CPU has against exploits and transient execution (arch_interface.log_hardening): its
 * control-flow integrity mechanisms, the transient-execution issues that apply to it, and the mitigations on.
 *
 * @param features The boot CPU's features, from detect_features.
 */
log_hardening :: fn(features: ptr[slop_os.CpuFeatures]) {
    runtime.log_info("cpu: control-flow integrity: shadow stacks %, indirect branch tracking %", yes_no(has(features, .X86ShadowStack)),
        yes_no(has(features, .X86Ibt)))
    affected : LogLine
    unaffected : LogLine
    match arch_capabilities() {
        case Some(capabilities) => {
            for issue in ISSUES {
                if capabilities & issue.unaffected == issue.unaffected {
                    line_add(&unaffected, issue.name)
                }
                else {
                    line_add(&affected, issue.name)
                }
            }
        }
        // Without the MSR, every issue is taken as applying
        case None => {
            for issue in ISSUES {
                line_add(&affected, issue.name)
            }
        }
    }
    if affected.count == 0 {
        runtime.log_info("cpu: transient execution: affected by Spectre v1; not affected by %", line_text(&unaffected, "anything"))
    }
    else {
        runtime.log_info("cpu: transient execution: affected by Spectre v1, %; not affected by %", line_text(&affected, ""),
            line_text(&unaffected, "anything"))
    }
    mitigations : LogLine
    if has(features, .X86Smep) {
        line_add(&mitigations, "SMEP")
    }
    if has(features, .X86Smap) {
        line_add(&mitigations, "SMAP")
    }
    if has_enhanced_ibrs() {
        line_add(&mitigations, "enhanced IBRS")
    }
    runtime.log_info("cpu: mitigations on: %", line_text(&mitigations, "none"))
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

/**
 * Give the kernel's pointer authentication key (arch_interface.set_kernel_pointer_key): x86-64 has none, so nothing.
 *
 * @param system Unused.
 * @param key Unused.
 */
set_kernel_pointer_key :: fn(system: ptr[mut ArchSystem], key: u64[2]) {}

/**
 * Say which key the calling CPU returns to user mode with (arch_interface.set_user_pointer_key): x86-64 has none, so
 * nothing.
 *
 * @param key Unused.
 */
set_user_pointer_key :: fn(key: u64[2]) {}

// CET for user mode (decisions/0186): CR4.CET on each CPU, and per thread IA32_U_CET and IA32_PL3_SSP
/** CR4.CET (bit 23): CET's shadow stacks and indirect branch tracking can be turned on. */
CR4_CET : u64 : 1 << 23
/** CR0.WP (bit 16): the kernel can't write read-only pages, which CR4.CET needs. */
CR0_WRITE_PROTECT : u64 : 1 << 16
/** User mode's CET: SH_STK_EN (bit 0) and ENDBR_EN (bit 2). */
IA32_U_CET : u32 : 0x6a0
/** U_CET's SH_STK_EN: shadow stacks on. */
U_CET_SHADOW_STACK : u64 : 1 << 0
/** U_CET's ENDBR_EN: indirect branch tracking on. */
U_CET_LANDING_PADS : u64 : 1 << 2
/** User mode's shadow-stack pointer. */
IA32_PL3_SSP : u32 : 0x6a7

/**
 * Turn on CR4.CET on the calling CPU where it has CET's shadow stacks or indirect branch tracking, with CR0.WP, which it
 * needs, and note which, for load_user_control_flow. Called by init_cpu, on each CPU.
 *
 * @param cpu The CPU's state, whose shadow_stacks and indirect_branch_tracking are set.
 * @param features The CPU's features.
 */
enable_control_flow :: fn(cpu: ptr[mut ArchCpu], features: ptr[slop_os.CpuFeatures]) {
    cpu.shadow_stacks = has(features, .X86ShadowStack)
    cpu.indirect_branch_tracking = has(features, .X86Ibt)
    if !cpu.shadow_stacks && !cpu.indirect_branch_tracking {
        return void
    }
    x86_64.write_cr0(x86_64.read_cr0() | CR0_WRITE_PROTECT)
    x86_64.write_cr4(x86_64.read_cr4() | CR4_CET)
    x86_64.wrmsr(IA32_U_CET, 0)
}

/**
 * Tell whether the calling CPU gives user threads shadow stacks (arch_interface.has_user_shadow_stacks).
 *
 * @return True where init_cpu turned CET's on.
 */
has_user_shadow_stacks :: fn() -> bool {
    return current_cpu().shadow_stacks
}

/**
 * Set user mode's CET for the thread about to return to it (arch_interface.load_user_control_flow): IA32_U_CET, and
 * IA32_PL3_SSP where it has a shadow stack.
 *
 * @param landing_pads Whether its indirect branches must land on endbr64, where the CPU has indirect branch tracking.
 * @param shadow_stack Its shadow-stack pointer; 0 for none.
 */
load_user_control_flow :: fn(landing_pads: bool, shadow_stack: u64) {
    cpu :: current_cpu()
    if !cpu.shadow_stacks && !cpu.indirect_branch_tracking {
        return void
    }
    enables := cast[u64](0)
    if shadow_stack != 0 && cpu.shadow_stacks {
        x86_64.wrmsr(IA32_PL3_SSP, shadow_stack)
        enables |= U_CET_SHADOW_STACK
    }
    if landing_pads && cpu.indirect_branch_tracking {
        enables |= U_CET_LANDING_PADS
    }
    x86_64.wrmsr(IA32_U_CET, enables)
}

/**
 * Read user mode's shadow-stack pointer (arch_interface.read_user_shadow_stack).
 *
 * @return IA32_PL3_SSP; 0 where the CPU has no shadow stacks.
 */
read_user_shadow_stack :: fn() -> u64 {
    if !current_cpu().shadow_stacks {
        return 0
    }
    return x86_64.rdmsr(IA32_PL3_SSP)
}

