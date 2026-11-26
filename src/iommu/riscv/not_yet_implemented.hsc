package iommu_riscv

import runtime from "base:runtime"
import iommu_interface from "../../iommu_interface"

/**
 * What iommu_interface declares that the RISC-V IOMMU doesn't implement yet (decisions/0005, 0199), by name: all of it
 * but identify, which comes with M19's R6.
 *
 * The kernel's other code calls them, so they're here as stubs to compile, but identify refuses every IOMMU, so nothing
 * reaches them. Each one fails an assertion, which stops the kernel. The interface's house rule (src/checks) accepts
 * stubs in this file only if they're listed, and fails once one is implemented anywhere else.
 */
NOT_YET_IMPLEMENTED :: string.[
    "enable",
    "route_faults",
    "init_domain",
    "attach",
    "detach",
    "map",
    "unmap",
    "invalidate",
    "release_domain",
    "next_fault",
    "remap_interrupt",
    "unmap_interrupt"
]

/** What a stub reached says, as it fails its assertion. */
NOT_YET :: "the RISC-V IOMMU isn't driven until M19's R6, and identify refuses every IOMMU before then"

/**
 * Turn translation on (iommu_interface.enable): not yet, so this fails an assertion.
 *
 * @param iommu Unused.
 * @param memory Unused.
 * @param direct_map_offset Unused.
 * @return Never returns, the assertion handler stopping the kernel.
 */
enable :: fn(
    iommu : ptr[mut Iommu],
    memory : iommu_interface.PhysicalAddress,
    direct_map_offset : u64
) -> Result[void, iommu_interface.IommuError] {
    runtime.assert(false, NOT_YET)
    return .Error(.UnsupportedKind)
}

/**
 * Signal faults by a message (iommu_interface.route_faults): not yet, so this fails an assertion.
 *
 * @param iommu Unused.
 * @param message Unused.
 */
route_faults :: fn(iommu : ptr[mut Iommu], message : iommu_interface.MsiMessage) {
    runtime.assert(false, NOT_YET)
}

/**
 * Make a domain (iommu_interface.init_domain): not yet, so this fails an assertion.
 *
 * @param iommu Unused.
 * @param domain Unused.
 * @param id Unused.
 * @param root Unused.
 */
init_domain :: fn(iommu : ptr[Iommu], domain : ptr[mut Domain], id : u32, root : iommu_interface.PhysicalAddress) {
    runtime.assert(false, NOT_YET)
}

/**
 * Attach a stream to a domain (iommu_interface.attach): not yet, so this fails an assertion.
 *
 * @param iommu Unused.
 * @param domain Unused.
 * @param stream Unused.
 * @param frames Unused.
 * @return Never returns, the assertion handler stopping the kernel.
 */
attach :: fn(
    iommu : ptr[mut Iommu],
    domain : ptr[Domain],
    stream : u32,
    frames : ptr[mut iommu_interface.TableFrames]
) -> Result[void, iommu_interface.MapError] {
    runtime.assert(false, NOT_YET)
    return .Error(.InvalidAddress)
}

/**
 * Detach a stream (iommu_interface.detach): not yet, so this fails an assertion.
 *
 * @param iommu Unused.
 * @param domain Unused.
 * @param stream Unused.
 */
detach :: fn(iommu : ptr[mut Iommu], domain : ptr[Domain], stream : u32) {
    runtime.assert(false, NOT_YET)
}

/**
 * Map a page in a domain (iommu_interface.map): not yet, so this fails an assertion.
 *
 * @param iommu Unused.
 * @param domain Unused.
 * @param address Unused.
 * @param physical Unused.
 * @param writable Unused.
 * @param device Unused.
 * @param frames Unused.
 * @return Never returns, the assertion handler stopping the kernel.
 */
map :: fn(
    iommu : ptr[Iommu],
    domain : ptr[mut Domain],
    address : u64,
    physical : iommu_interface.PhysicalAddress,
    writable : bool,
    device : bool,
    frames : ptr[mut iommu_interface.TableFrames]
) -> Result[void, iommu_interface.MapError] {
    runtime.assert(false, NOT_YET)
    return .Error(.InvalidAddress)
}

/**
 * Unmap a page in a domain (iommu_interface.unmap): not yet, so this fails an assertion.
 *
 * @param iommu Unused.
 * @param domain Unused.
 * @param address Unused.
 */
unmap :: fn(iommu : ptr[Iommu], domain : ptr[mut Domain], address : u64) {
    runtime.assert(false, NOT_YET)
}

/**
 * Invalidate what the IOMMU cached of a domain (iommu_interface.invalidate): not yet, so this fails an assertion.
 *
 * @param iommu Unused.
 * @param domain Unused.
 * @param mapped Unused.
 */
invalidate :: fn(iommu : ptr[mut Iommu], domain : ptr[Domain], mapped : bool) {
    runtime.assert(false, NOT_YET)
}

/**
 * Let go of a domain's tables (iommu_interface.release_domain): not yet, so this fails an assertion.
 *
 * @param iommu Unused.
 * @param domain Unused.
 * @param freed Unused.
 * @return Never returns, the assertion handler stopping the kernel.
 */
release_domain :: fn(
    iommu : ptr[Iommu],
    domain : ptr[mut Domain],
    freed : ptr[mut iommu_interface.FreedFrames]
) -> bool {
    runtime.assert(false, NOT_YET)
    return true
}

/**
 * Take the oldest fault recorded (iommu_interface.next_fault): not yet, so this fails an assertion.
 *
 * @param iommu Unused.
 * @return Never returns, the assertion handler stopping the kernel.
 */
next_fault :: fn(iommu : ptr[mut Iommu]) -> iommu_interface.DmaFault? {
    runtime.assert(false, NOT_YET)
    return null
}

/**
 * Remap an interrupt (iommu_interface.remap_interrupt): not yet, so this fails an assertion.
 *
 * @param iommu Unused.
 * @param index Unused.
 * @param stream Unused.
 * @param cpu_hardware_id Unused.
 * @param vector Unused.
 * @param level Unused.
 * @return Never returns, the assertion handler stopping the kernel.
 */
remap_interrupt :: fn(
    iommu : ptr[mut Iommu],
    index : u32,
    stream : u32,
    cpu_hardware_id : u64,
    vector : u32,
    level : bool
) -> iommu_interface.MsiMessage {
    runtime.assert(false, NOT_YET)
    return iommu_interface.MsiMessage.{}
}

/**
 * Stop a remapped interrupt (iommu_interface.unmap_interrupt): not yet, so this fails an assertion.
 *
 * @param iommu Unused.
 * @param index Unused.
 */
unmap_interrupt :: fn(iommu : ptr[mut Iommu], index : u32) {
    runtime.assert(false, NOT_YET)
}
