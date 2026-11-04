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

/**
 * Give the bytes of a thread's vector state (arch_interface.vector_state_size).
 *
 * @param config Ignored: SVE's state isn't kept, so extended changes nothing.
 * @return aarch64.FP_SIMD_STATE_SIZE, 528 bytes: v0 to v31, FPCR and FPSR.
 */
vector_state_size :: fn(config: arch_interface.VectorConfig) -> usize {
    return aarch64.FP_SIMD_STATE_SIZE
}

/**
 * Give the alignment a thread's vector state needs (arch_interface.vector_state_alignment).
 *
 * @return 16 bytes, VectorState's alignment.
 */
vector_state_alignment :: fn() -> usize {
    return 16
}

/**
 * Set a new thread's vector state to the state at reset (arch_interface.init_vector_state): every register zero,
 * so FPCR has round to nearest and no traps.
 *
 * @param state The state, vector_state_size bytes, 16-byte aligned.
 * @param config Ignored, as in vector_state_size.
 */
init_vector_state :: fn(state: ptr[mut VectorState], config: arch_interface.VectorConfig) {
    intrinsics.mem_zero(cast[mut rawptr](state), aarch64.FP_SIMD_STATE_SIZE)
}

/**
 * Save the calling CPU's v0 to v31, FPCR and FPSR into state (arch_interface.save_vector_state).
 *
 * @param state Where they go, vector_state_size bytes, 16-byte aligned.
 */
save_vector_state :: fn(state: ptr[mut VectorState]) {
    aarch64.save_fp_simd(cast[rawptr](state))
}

/**
 * Load state into the calling CPU's v0 to v31, FPCR and FPSR (arch_interface.restore_vector_state).
 *
 * @param state The state, as save_vector_state or init_vector_state left it.
 */
restore_vector_state :: fn(state: ptr[VectorState]) {
    aarch64.restore_fp_simd(cast[rawptr](state))
}
