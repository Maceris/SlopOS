package arch_x86_64

import intrinsics from "base"
import x86_64 from "base/intrinsics"
import arch_interface from "../../arch_interface"

/*
 * Threads' vector state (arch_interface, Vector State): an XSAVE area in the standard format, after a
 * 64-byte header saying which state components it holds. x87, SSE and AVX by default; with
 * VectorConfig.extended, AVX-512's too where the CPU has them (decisions/0023). Saved and restored
 * eagerly at every thread switch, never lazily (the LazyFP attack, CVE-2018-3665), with XSAVEOPT where
 * the CPU has it, which skips what wasn't changed since the restore. XCR0 is switched only when a
 * thread with other components is restored.
 */
//SPEC: Intel SDM Vol. 1 §13 (XSAVE): §13.4 (the XSAVE area), §13.8 (XRSTOR), §13.9 (XSAVEOPT); CPUID leaf 0DH

/** The state components every thread has, and XCR0 outside threads: x87, SSE and AVX (decisions/0023). */
XCR0_BASE : u64 : XCR0_X87 | XCR0_SSE | XCR0_AVX
/** XCR0 bits 5-7, AVX-512's components: the opmask registers, ZMM0 to ZMM15's upper halves, and ZMM16 to ZMM31. */
XCR0_AVX512 : u64 : (1 << 5) | (1 << 6) | (1 << 7)
/** The bytes of an XSAVE area's legacy region (512) and XSAVE header (64), before any extended component. */
XSAVE_LEGACY_AND_HEADER : u64 : 576
/** The bytes of VectorState's own header, before the XSAVE area, which keeps the area 64-byte aligned. */
VECTOR_HEADER_SIZE : u64 : 64
// Where the x87 control word and MXCSR are in the legacy region, and their values at reset
/** The byte offset of the x87 control word (FCW) in the XSAVE area's legacy region. */
FCW_OFFSET : u64 : 0
/** The byte offset of MXCSR in the XSAVE area's legacy region. */
MXCSR_OFFSET : u64 : 24
/** The x87 control word at reset: every exception masked, 64-bit precision, round to nearest. */
FCW_INITIAL : u16 : 0x037f
/** MXCSR at reset: every SIMD floating-point exception masked, round to nearest, no flush to zero. */
MXCSR_INITIAL : u32 : 0x1f80

/**
 * A thread's vector state (arch_interface.VectorState): this 64-byte header, then its XSAVE area, in the standard
 * (not compacted) format, vector_state_size bytes in all, 64-byte aligned.
 */
VectorState :: struct #align(64) {
    /** The state components the area holds, XCR0 bits, which XCR0 is set to while the thread runs. */
    components : u64,
    /** Unused, 0, so the XSAVE area after the header is 64-byte aligned. */
    reserved : u64[7],
}

#assert size_of(VectorState) == 64

/**
 * Choose the state components a thread with config gets.
 *
 * @param config Whether the thread asks for the extended state, AVX-512's.
 * @return XCR0 bits: XCR0_BASE, and XCR0_AVX512 too when config is extended and the CPU supports all three of its
 *     components, as CPUID leaf 0DH says.
 */
components_for :: fn(config: arch_interface.VectorConfig) -> u64 {
    if !config.extended {
        return XCR0_BASE
    }
    leaf :: x86_64.cpuid(0xd, 0)
    supported :: cast[u64](leaf.eax) | (cast[u64](leaf.edx) << 32)
    return if supported & XCR0_AVX512 == XCR0_AVX512 { XCR0_BASE | XCR0_AVX512 } else { XCR0_BASE }
}

/**
 * Measure an XSAVE area of components in the standard format: where its last component ends, from CPUID leaf 0DH.
 *
 * @param components XCR0 bits; x87 and SSE live in the legacy region, so only the others change the size.
 * @return The area's size in bytes, at least XSAVE_LEGACY_AND_HEADER, not counting VectorState's header.
 */
area_end :: fn(components: u64) -> u64 {
    size := XSAVE_LEGACY_AND_HEADER
    for component in 2..<64 {
        if (components >> cast[u64](component)) & 1 == 0 {
            continue
        }
        leaf :: x86_64.cpuid(0xd, cast[u32](component))
        end :: cast[u64](leaf.ebx) + cast[u64](leaf.eax)
        if end > size {
            size = end
        }
    }
    return size
}

/**
 * Give the bytes a thread's VectorState needs, header and XSAVE area.
 *
 * @param config The thread's configuration, which decides its components as components_for does.
 * @return The size in bytes, which init_vector_state fills and save_vector_state writes up to.
 */
vector_state_size :: fn(config: arch_interface.VectorConfig) -> usize {
    return cast[usize](VECTOR_HEADER_SIZE + area_end(components_for(config)))
}

/**
 * Give the alignment a VectorState needs.
 *
 * @return 64 bytes, which XSAVE and XRSTOR require of their area.
 */
vector_state_alignment :: fn() -> usize {
    return 64
}

/**
 * Set a new thread's vector state to the state at reset.
 *
 * The area is zeroed, so its XSAVE header marks every component absent, which XRSTOR loads in its initial state; the
 * x87 control word and MXCSR, which come from the legacy region, get their reset values.
 *
 * @param state The state, vector_state_size(config) bytes, aligned to vector_state_alignment(), all of it written.
 * @param config The thread's configuration, which decides its components.
 */
init_vector_state :: fn(state: ptr[mut VectorState], config: arch_interface.VectorConfig) {
    components :: components_for(config)
    intrinsics.mem_zero(cast[mut rawptr](state), cast[usize](VECTOR_HEADER_SIZE + area_end(components)))
    state.components = components
    area :: area_of(state)
    cast[ptr[mut u16]](area + FCW_OFFSET)^ = FCW_INITIAL
    cast[ptr[mut u32]](area + MXCSR_OFFSET)^ = MXCSR_INITIAL
}

/**
 * Save the calling CPU's vector registers into a thread's state, each of its components.
 *
 * XSAVEOPT is used where the CPU has it, which skips components unchanged since the last XRSTOR from the same area, so
 * state has to be the one restore_vector_state last loaded on this CPU, which it is at a thread switch.
 *
 * @param state The running thread's state, set up by init_vector_state.
 */
save_vector_state :: fn(state: ptr[mut VectorState]) {
    if current_cpu().xsaveopt {
        x86_64.xsaveopt(cast[rawptr](area_of(state)), state.components)
    }
    else {
        x86_64.xsave(cast[rawptr](area_of(state)), state.components)
    }
}

/**
 * Load a thread's state into the calling CPU's vector registers.
 *
 * XCR0 is set to the state's components first, when the last state loaded had others.
 *
 * @param state The thread's state, set up by init_vector_state, and saved by save_vector_state if it has run before.
 */
restore_vector_state :: fn(state: ptr[VectorState]) {
    cpu :: current_cpu()
    if cpu.xcr0 != state.components {
        x86_64.xsetbv(0, state.components)
        cpu.xcr0 = state.components
    }
    x86_64.xrstor(cast[rawptr](area_of(state)), state.components)
}

/**
 * Find a state's XSAVE area, right after its header.
 *
 * @param state The state's header, only used for its address; nothing is read through it.
 * @return The area's virtual address, VECTOR_HEADER_SIZE bytes past state, so 64-byte aligned when state is.
 */
area_of :: fn(state: ptr[VectorState]) -> u64 {
    return cast[u64](state) + VECTOR_HEADER_SIZE
}
