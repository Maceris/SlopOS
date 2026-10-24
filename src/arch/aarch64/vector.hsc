package arch_aarch64

import intrinsics from "base"
import aarch64 from "base/intrinsics"
import arch_interface from "../../arch_interface"

/*
 * A thread's floating-point and SIMD state (arch_interface, User State; decisions/0066): v0 to v31, FPCR and
 * FPSR, saved at every switch away from a user thread and restored on the way back, as x86-64 does with
 * XSAVE (decisions/0023). init_cpu lets EL0 and EL1 use floating point (CPACR_EL1.FPEN), and the kernel,
 * built without it, never touches those registers, so they're always the current thread's. SVE's larger
 * state isn't kept yet, so VectorConfig.extended changes nothing.
 */

vector_state_size :: fn(config: arch_interface.VectorConfig) -> usize {
    return aarch64.FP_SIMD_STATE_SIZE
}

vector_state_alignment :: fn() -> usize {
    return 16
}

// The state at reset: every register zero, with FPCR's default rounding and no traps.
init_vector_state :: fn(state: ptr[mut VectorState], config: arch_interface.VectorConfig) {
    intrinsics.mem_zero(cast[mut rawptr](state), aarch64.FP_SIMD_STATE_SIZE)
}

save_vector_state :: fn(state: ptr[mut VectorState]) {
    aarch64.save_fp_simd(cast[rawptr](state))
}

restore_vector_state :: fn(state: ptr[VectorState]) {
    aarch64.restore_fp_simd(cast[rawptr](state))
}
