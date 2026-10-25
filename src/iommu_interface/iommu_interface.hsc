/*
 * The IOMMU interface: what every IOMMU package implements and the kernel core (L2) calls, for the IOMMUs the
 * platform service registers (decisions/0039, 0079). Specified in docs/specs/iommu_interface.md.
 *
 * IOMMUs differ per platform rather than per architecture (Intel VT-d, AMD-Vi, Arm SMMUv3, the RISC-V IOMMU), and an
 * architecture may build several, so the kernel imports each one its architecture builds under an alias starting
 * iommu_, like iommu_vtd. Functions here are declarations only (---); each package defines them with the same
 * signature, and the per-implementation types (the empty structs) under the same names.
 */
package iommu_interface

import boot_info from "../boot_info"

PhysicalAddress :: boot_info.PhysicalAddress
VirtualAddress :: boot_info.VirtualAddress

// One IOMMU the platform service registered: what the implementation keeps of it, like its registers' address.
Iommu :: struct {}

// One DMA domain's translation on an IOMMU: its tables' root, its ID there, and how deep its tables are.
Domain :: struct {}

// Kinds of IOMMU. An implementation drives one, and an architecture builds only some.
IommuKind :: enum #backed_by(u8) {
    // x86-64
    VtD,
    AmdVi,
    // AArch64
    Smmuv3,
    // RISC-V
    RiscV,
}

IommuError :: enum #backed_by(u8) {
    // This implementation doesn't drive the kind.
    UnsupportedKind,
    // The registers don't identify an IOMMU of that kind, or there are fewer of them than it has.
    NotFound,
    // It lacks what the kernel needs of one: the translation its domains use (VT-d's second-level tables, SMMUv3's
    // stage 2), with 4 KiB pages and at least 39-bit I/O virtual addresses.
    Unsupported,
    // It didn't do what it was told in time, like turning translation on.
    Timeout,
}

MapError :: enum #backed_by(u8) {
    // frames ran out. Refill them and call again; nothing was changed.
    NeedFrames,
    // Something is mapped there already.
    AlreadyMapped,
    // Not page-aligned, or outside the domain's addresses.
    InvalidAddress,
}

// Zeroed frames L2 gives for new tables. Calls take them from the end.
TableFrames :: struct {
    count : u32,
    frames : PhysicalAddress[4],
}

// Table frames a call let go of. L2 frees them once the IOMMU can no longer reach them.
FreedFrames :: struct {
    count : u32,
    frames : PhysicalAddress[4],
}

// What's written, and where, to raise a message-signaled interrupt: arch_interface's MsiMessage.
MsiMessage :: struct {
    address : u64,
    data : u32,
}

// A DMA access an IOMMU blocked, or an interrupt it didn't remap.
DmaFault :: struct {
    stream : u32,
    // The page it was to, as the device addressed it; for an interrupt, the remapped interrupt's index.
    address : u64,
    write : bool,
    interrupt : bool,
    // Why, as the IOMMU numbers its reasons.
    reason : u32,
}

// What identify finds out about an IOMMU.
IommuInfo :: struct {
    // The I/O virtual addresses its domains can have: below 1 << address_bits.
    address_bits : u32,
    // Its version, as its registers give it: major, then minor.
    major : u32,
    minor : u32,
    // The bytes of zeroed, contiguous memory enable takes, for its tables and queues.
    memory : u64,
    // Domain IDs from 1 up to this, one per domain on it.
    domain_ids : u32,
    // The interrupts it remaps, by index from 0, once it's enabled; 0 if it doesn't.
    interrupts : u32,
    // Whether it signals its faults by a message (route_faults); otherwise L2 asks for them (next_fault) now and then.
    fault_messages : bool,
}

/*
 * Identify an IOMMU of kind whose registers, size bytes of them, L2 mapped uncached at registers, and keep what's
 * needed of it in iommu, changing nothing: DMA through it goes on as before, translated or not.
 */
identify : fn(iommu: ptr[mut Iommu], kind: IommuKind, registers: VirtualAddress, size: u64) -> Result[IommuInfo, IommuError] : ---

/*
 * Turn translation on, with memory, info.memory bytes of zeroed, contiguous memory, for its tables and queues, which
 * it keeps, and the rest of what it reaches, like domains' tables, through the direct map at direct_map_offset. Every
 * stream is blocked until it's attached to a domain; its faults are recorded, not yet signalled (route_faults).
 */
enable : fn(iommu: ptr[mut Iommu], memory: PhysicalAddress, direct_map_offset: u64) -> Result[void, IommuError] : ---

// Signal its faults by writing message.
route_faults : fn(iommu: ptr[mut Iommu], message: MsiMessage) : ---

// Make domain an empty one on the IOMMU, with ID id and root, a zeroed frame, for its top-level table.
init_domain : fn(iommu: ptr[Iommu], domain: ptr[mut Domain], id: u32, root: PhysicalAddress) : ---

// stream's DMA translated through domain from now on, instead of what it was before; it takes frames for its own tables.
attach : fn(iommu: ptr[mut Iommu], domain: ptr[Domain], stream: u32, frames: ptr[mut TableFrames]) -> Result[void, MapError] : ---

// stream's DMA blocked again, and nothing the IOMMU cached of domain's for it left, when this returns.
detach : fn(iommu: ptr[mut Iommu], domain: ptr[Domain], stream: u32) : ---

/*
 * The 4 KiB page at address in domain mapped to physical, readable, and writable if writable: RAM, or device memory
 * (device), like the MSI doorbell (arch_interface.msi_doorbell). Until invalidate, the IOMMU may not see it.
 */
map : fn(iommu: ptr[Iommu], domain: ptr[mut Domain], address: u64, physical: PhysicalAddress, writable: bool, device: bool,
    frames: ptr[mut TableFrames]) -> Result[void, MapError] : ---

// The 4 KiB page at address in domain unmapped, if it's mapped; until invalidate, the IOMMU may still reach it.
unmap : fn(iommu: ptr[Iommu], domain: ptr[mut Domain], address: u64) : ---

/*
 * Nothing the IOMMU cached of domain's tables left, when this returns: after unmapping, so it no longer reaches what
 * was mapped; after mapping (mapped), where it may cache what isn't mapped, like VT-d's caching mode.
 */
invalidate : fn(iommu: ptr[mut Iommu], domain: ptr[Domain], mapped: bool) : ---

/*
 * Let go of domain's tables, all but its root, as many as freed has room for each call: true once only the root is
 * left. Nothing is attached to it any more.
 */
release_domain : fn(iommu: ptr[Iommu], domain: ptr[mut Domain], freed: ptr[mut FreedFrames]) -> bool : ---

// The oldest fault it recorded and hasn't given yet, taken from its records, or null.
next_fault : fn(iommu: ptr[mut Iommu]) -> DmaFault? : ---

/*
 * Remapped interrupt index made to deliver vector, an InterruptId, to the CPU with this hardware ID, from stream only:
 * the message stream's device writes to raise it. The IOMMU uses it once this returns.
 */
remap_interrupt : fn(iommu: ptr[mut Iommu], index: u32, stream: u32, cpu_hardware_id: u64, vector: u32) -> MsiMessage : ---

// Remapped interrupt index raising nothing, and nothing the IOMMU cached of it left, when this returns.
unmap_interrupt : fn(iommu: ptr[mut Iommu], index: u32) : ---
