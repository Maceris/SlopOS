package arch_riscv64

import runtime from "base:runtime"
import slop_os from "std:os/slop_os"
import arch_interface from "../../arch_interface"

/*
 * What the harts have against exploits (decisions/0186, 0199): Zicfilp's landing pads and Zicfiss's shadow stacks,
 * logged at boot, and used from M19's R6. RISC-V has no pointer authentication, and nothing in the ISA says which
 * transient-execution issues a hart has.
 */

/**
 * Log, at boot, what the harts have against exploits and transient execution (arch_interface.log_hardening).
 *
 * @param features The boot hart's features, from detect_features.
 */
log_hardening :: fn(features : ptr[slop_os.CpuFeatures]) {
    runtime.log_info(
        "cpu: control-flow integrity: landing pads (Zicfilp) %, shadow stacks (Zicfiss) %; neither is used yet",
        yes_no(has(features, .RiscvZicfilp)),
        yes_no(has(features, .RiscvZicfiss))
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
 * Tell whether user threads get shadow stacks (arch_interface.has_user_shadow_stacks): not yet, until R6 turns
 * Zicfiss on.
 *
 * @return False.
 */
has_user_shadow_stacks :: fn() -> bool {
    return false
}

/**
 * Set the hart's user-mode control-flow integrity for the thread about to return to user mode
 * (arch_interface.load_user_control_flow): nothing yet, as neither Zicfilp's landing pads nor Zicfiss's shadow stacks
 * are turned on before R6, which needs the SBI's firmware features extension to let user mode have them.
 *
 * @param landing_pads Unused: indirect branches aren't checked yet.
 * @param shadow_stack Unused: has_user_shadow_stacks is false, so L2 gives none.
 */
load_user_control_flow :: fn(landing_pads : bool, shadow_stack : u64) {}

/**
 * Read the hart's user-mode shadow-stack pointer (arch_interface.read_user_shadow_stack): none yet.
 *
 * @return 0, as no thread has a shadow stack before R6.
 */
read_user_shadow_stack :: fn() -> u64 {
    return 0
}

/**
 * Tell whether the kernel's own code runs on shadow stacks (arch_interface.has_kernel_shadow_stacks): not yet, until
 * R6 turns Zicfiss on for supervisor mode.
 *
 * @return False.
 */
has_kernel_shadow_stacks :: fn() -> bool {
    return false
}

/**
 * Say what control-flow integrity the kernel's code runs under (arch_interface.kernel_control_flow): none yet.
 *
 * @return Every mechanism off.
 */
kernel_control_flow :: fn() -> arch_interface.KernelControlFlow {
    return arch_interface.KernelControlFlow.{}
}
