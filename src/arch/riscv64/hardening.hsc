package arch_riscv64

import riscv64 from "base:intrinsics/riscv64"
import runtime from "base:runtime"
import slop_os from "std:os/slop_os"
import arch_interface from "../../arch_interface"

/*
 * What the harts have against exploits (decisions/0186, 0199's R6): Zicfilp's landing pads and Zicfiss's shadow
 * stacks. RISC-V has no pointer authentication, and nothing in the ISA says which transient-execution issues a hart
 * has.
 *
 * Supervisor mode's are the machine's to turn on, menvcfg's LPE and SSE, which the SBI's firmware features extension
 * (FWFT) sets for the calling hart. User mode's are senvcfg's, set for each thread as it returns to user mode, its SSE
 * only where supervisor mode's is on.
 *
 * Landing pads are on in the kernel from init_cpu, as every function and every indirect branch target Hemera makes has
 * one. Shadow stacks are on from the hart's first idle or return to user mode, in idle's and return_to_user's own
 * bodies, which never return: every function saves its return address (Hemera keeps frame pointers), so one returning
 * across the change would check a return the shadow stack never had. They also set senvcfg, the user-mode controls
 * the thread returns with (load_user_control_flow), whose SSE takes only once supervisor mode's is on. A
 * hart has one ssp: a trap from user mode switches it to the kernel's shadow stack and a return to user mode back
 * (riscv64.TrapScratch, Hemera's docs/calling_convention.md), the kernel's starting from its top each time, as its
 * stack does.
 *
 * SPEC: The RISC-V Instruction Set Manual, Volume I: Zicfilp and Zicfiss (Control-flow Integrity); Volume II: menvcfg
 * and senvcfg; the RISC-V SBI specification, version 3.0: the firmware features extension.
 */

/** The SBI's firmware features extension's ID, "FWFT". */
SBI_FWFT : u64 : 0x46574654
/** FWFT's set function: a feature, its value, and flags, 0 to leave it unlocked. */
SBI_FWFT_SET : u64 : 0
/** FWFT's get function: a feature's value, or an error where the feature isn't. */
SBI_FWFT_GET : u64 : 1
/** FWFT's LANDING_PAD feature: supervisor mode's landing pads, menvcfg.LPE. */
FWFT_LANDING_PAD : u64 : 1
/** FWFT's SHADOW_STACK feature: supervisor mode's shadow stacks, menvcfg.SSE, and so user mode's allowed. */
FWFT_SHADOW_STACK : u64 : 2
/** senvcfg's LPE: user mode's indirect branches must land on landing pads. */
SENVCFG_LANDING_PADS : u64 : 1 << 2
/** senvcfg's SSE: user mode has shadow stacks. */
SENVCFG_SHADOW_STACK : u64 : 1 << 3

/**
 * Log, at boot, what the harts have against exploits and transient execution (arch_interface.log_hardening).
 *
 * @param features The boot hart's features, from detect_features.
 */
log_hardening :: fn(features : ptr[slop_os.CpuFeatures]) {
    system :: current_system()
    runtime.log_info(
        "cpu: control-flow integrity: landing pads (Zicfilp) %, shadow stacks (Zicfiss) %; for the kernel: %, %",
        yes_no(has(features, .RiscvZicfilp)),
        yes_no(has(features, .RiscvZicfiss)),
        yes_no(current_cpu().landing_pads),
        yes_no(system.shadow_stacks)
    )
    runtime.log_info(
        "cpu: transient execution: the ISA reports nothing, so Spectre v1 and v2 are assumed; mitigations on: SUM clear"
    )
}

/**
 * Say yes or no.
 *
 * @param value The answer.
 * @return "yes" or "no", constants.
 */
yes_no :: fn(value : bool) -> string {
    return if value { "yes" } else { "no" }
}

/**
 * Find out, once for every hart, whether the kernel can have shadow stacks: where the harts have Zicfiss and the
 * firmware's FWFT has its SHADOW_STACK feature. From init_system.
 *
 * @param system The shared state, whose features are read; its shadow_stacks is set.
 */
find_shadow_stacks :: fn(system : ptr[mut ArchSystem]) {
    probed :: riscv64.sbi_call(SBI_BASE, SBI_PROBE_EXTENSION, SBI_FWFT)
    system.shadow_stacks = has(&system.features, .RiscvZicfiss)
        && probed.error == 0
        && probed.value != 0
        && riscv64.sbi_call(SBI_FWFT, SBI_FWFT_GET, FWFT_SHADOW_STACK).error == 0
}

/**
 * Turn the calling hart's landing pads on in the kernel, where it has Zicfilp and the firmware lets it: FWFT's
 * LANDING_PAD. From init_cpu; safe at once, as every indirect branch the kernel makes lands on one.
 *
 * @param system The shared state, for the features.
 * @param cpu The calling hart's state, whose landing_pads is set.
 */
enable_landing_pads :: fn(system : ptr[ArchSystem], cpu : ptr[mut ArchCpu]) {
    cpu.landing_pads = has(&system.features, .RiscvZicfilp)
        && riscv64.sbi_call(SBI_FWFT, SBI_FWFT_SET, FWFT_LANDING_PAD, 1, 0).error == 0
}

/**
 * Take the kernel's pointer authentication key (arch_interface.set_kernel_pointer_key): RISC-V has none, so it's
 * ignored.
 *
 * @param system Unused.
 * @param key Unused.
 */
set_kernel_pointer_key :: fn(system : ptr[mut ArchSystem], key : u64[2]) {}

/**
 * Take the key a hart returns to user mode with (arch_interface.set_user_pointer_key): RISC-V has none, so it's
 * ignored.
 *
 * @param key Unused.
 */
set_user_pointer_key :: fn(key : u64[2]) {}

/**
 * Tell whether user threads get shadow stacks (arch_interface.has_user_shadow_stacks): where the kernel can have
 * them, as user mode's need supervisor mode's on.
 *
 * @return True where find_shadow_stacks found Zicfiss and FWFT's SHADOW_STACK.
 */
has_user_shadow_stacks :: fn() -> bool {
    return current_system().shadow_stacks
}

/**
 * Set the hart's user-mode control-flow integrity for the thread about to return to user mode
 * (arch_interface.load_user_control_flow): senvcfg's LPE and SSE, which return_to_user writes, and user mode's ssp,
 * which the return puts back (riscv64.TrapScratch).
 *
 * @param landing_pads Whether its indirect branches must land on landing pads; taken only where the harts have
 *     Zicfilp.
 * @param shadow_stack Its shadow-stack pointer, its latest entry; 0 for none, which leaves its SSE off.
 */
load_user_control_flow :: fn(landing_pads : bool, shadow_stack : u64) {
    cpu :: current_cpu()
    system :: current_system()
    envcfg := cast[u64](0)
    if landing_pads && has(&system.features, .RiscvZicfilp) {
        envcfg |= SENVCFG_LANDING_PADS
    }
    if shadow_stack != 0 && system.shadow_stacks {
        envcfg |= SENVCFG_SHADOW_STACK
    }
    cpu.user_envcfg = envcfg
    cpu.scratch.user_shadow_stack = shadow_stack
}

/**
 * Read the hart's user-mode shadow-stack pointer (arch_interface.read_user_shadow_stack), as the trap from user mode
 * kept it.
 *
 * @return The TrapScratch's user_shadow_stack: the ssp user mode had, where the kernel has shadow stacks on this hart;
 *     what load_user_control_flow set, otherwise.
 */
read_user_shadow_stack :: fn() -> u64 {
    return current_cpu().scratch.user_shadow_stack
}

/**
 * Tell whether the kernel's own code runs on shadow stacks (arch_interface.has_kernel_shadow_stacks): where
 * find_shadow_stacks found Zicfiss and FWFT's SHADOW_STACK.
 *
 * @return True if a hart's kernel stack has a shadow stack.
 */
has_kernel_shadow_stacks :: fn() -> bool {
    return current_system().shadow_stacks
}

/**
 * Give a hart its kernel shadow stack (arch_interface.set_kernel_shadow_stack): kept for idle and return_to_user,
 * which start it from its top and turn shadow stacks on.
 *
 * @param cpu The hart's own state, whose kernel_shadow_top is set.
 * @param base The shadow stack's lowest address.
 * @param size Its size in bytes.
 */
set_kernel_shadow_stack :: fn(cpu : ptr[mut ArchCpu], base : u64, size : u64) {
    cpu.kernel_shadow_top = base + size
}

/**
 * Say what control-flow integrity the kernel's code runs under on the calling hart (arch_interface.kernel_control_flow):
 * landing pads where enable_landing_pads turned them on, and a shadow stack once idle or return_to_user has.
 *
 * @return Each that's on, with ssp, the shadow stack's latest entry, when it is.
 */
kernel_control_flow :: fn() -> arch_interface.KernelControlFlow {
    cpu :: current_cpu()
    return arch_interface.KernelControlFlow.{
        landing_pads = cpu.landing_pads,
        shadow_stack = cpu.shadow_stacks_on,
        shadow_stack_pointer = if cpu.shadow_stacks_on { riscv64.csrr(.SSP) } else { cast[u64](0) },
    }
}
