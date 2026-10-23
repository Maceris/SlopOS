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

XCR0_BASE : u64 : XCR0_X87 | XCR0_SSE | XCR0_AVX
// AVX-512: the opmask registers, the upper halves of ZMM0 to ZMM15, and ZMM16 to ZMM31
XCR0_AVX512 : u64 : (1 << 5) | (1 << 6) | (1 << 7)
// The legacy region and the XSAVE header
XSAVE_LEGACY_AND_HEADER : u64 : 576
VECTOR_HEADER_SIZE : u64 : 64
// Where the x87 control word and MXCSR are in the legacy region, and their values at reset
FCW_OFFSET : u64 : 0
MXCSR_OFFSET : u64 : 24
FCW_INITIAL : u16 : 0x037f
MXCSR_INITIAL : u32 : 0x1f80

// A thread's vector state (arch_interface.VectorState): this header, then its XSAVE area.
VectorState :: struct #align(64) {
    // The state components the area holds, and XCR0 while the thread runs.
    components : u64,
    reserved : u64[7],
}

#assert size_of(VectorState) == 64

// The components a thread with config gets: the extended ones only where the CPU has them.
components_for :: fn(config: arch_interface.VectorConfig) -> u64 {
    if !config.extended {
        return XCR0_BASE
    }
    leaf :: x86_64.cpuid(0xd, 0)
    supported :: cast[u64](leaf.eax) | (cast[u64](leaf.edx) << 32)
    return if supported & XCR0_AVX512 == XCR0_AVX512 { XCR0_BASE | XCR0_AVX512 } else { XCR0_BASE }
}

// Bytes for the header and an XSAVE area of components, in the standard format.
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

vector_state_size :: fn(config: arch_interface.VectorConfig) -> usize {
    return cast[usize](VECTOR_HEADER_SIZE + area_end(components_for(config)))
}

vector_state_alignment :: fn() -> usize {
    return 64
}

/*
 * The state at reset: every component in its initial state, which XRSTOR loads for components the
 * header marks absent, and the x87 control word and MXCSR, which come from the legacy region.
 */
init_vector_state :: fn(state: ptr[mut VectorState], config: arch_interface.VectorConfig) {
    components :: components_for(config)
    intrinsics.mem_zero(cast[rawptr](state), cast[usize](VECTOR_HEADER_SIZE + area_end(components)))
    state.components = components
    area :: area_of(state)
    cast[ptr[mut u16]](area + FCW_OFFSET)^ = FCW_INITIAL
    cast[ptr[mut u32]](area + MXCSR_OFFSET)^ = MXCSR_INITIAL
}

save_vector_state :: fn(state: ptr[mut VectorState]) {
    if current_cpu().xsaveopt {
        x86_64.xsaveopt(cast[rawptr](area_of(state)), state.components)
    }
    else {
        x86_64.xsave(cast[rawptr](area_of(state)), state.components)
    }
}

restore_vector_state :: fn(state: ptr[VectorState]) {
    cpu :: current_cpu()
    if cpu.xcr0 != state.components {
        x86_64.xsetbv(0, state.components)
        cpu.xcr0 = state.components
    }
    x86_64.xrstor(cast[rawptr](area_of(state)), state.components)
}

area_of :: fn(state: ptr[VectorState]) -> u64 {
    return cast[u64](state) + VECTOR_HEADER_SIZE
}
