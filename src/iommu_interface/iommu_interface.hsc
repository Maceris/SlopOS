/**
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

/** A physical address, as boot_info has it: what an IOMMU's tables and a device's DMA translate to. */
PhysicalAddress :: boot_info.PhysicalAddress
/** A virtual address in the kernel's address space, as boot_info has it, like where L2 mapped an IOMMU's registers. */
VirtualAddress :: boot_info.VirtualAddress

/** One IOMMU the platform service registered: what the implementation keeps of it, like its registers' address. */
Iommu :: struct {}

/** One DMA domain's translation on an IOMMU: its tables' root, its ID there, and how deep its tables are. */
Domain :: struct {}

/** Kinds of IOMMU. An implementation drives one, and an architecture builds only some. */
IommuKind :: enum #backed_by(u8) {
    /** Intel VT-d, on x86-64. */
    VtD,
    /** AMD-Vi, on x86-64. */
    AmdVi,
    /** Arm's SMMUv3, on AArch64. */
    Smmuv3,
    /** The RISC-V IOMMU. */
    RiscV,
}

/** Why identifying an IOMMU, or turning its translation on, failed. */
IommuError :: enum #backed_by(u8) {
    /** This implementation doesn't drive the kind. */
    UnsupportedKind,
    /** The registers don't identify an IOMMU of that kind, or there are fewer of them than it has. */
    NotFound,
    /**
     * It lacks what the kernel needs of one: the translation its domains use (VT-d's second-level tables, SMMUv3's
     * stage 2), with 4 KiB pages and at least 39-bit I/O virtual addresses.
     */
    Unsupported,
    /** It didn't do what it was told in time, like turning translation on. */
    Timeout,
}

/** Why attaching a stream to a domain, or mapping a page in one, failed. */
MapError :: enum #backed_by(u8) {
    /** frames ran out. Refill them and call again; nothing was changed. */
    NeedFrames,
    /** Something is mapped there already. */
    AlreadyMapped,
    /** Not page-aligned, or outside the domain's addresses; for attach, a stream the IOMMU doesn't have. */
    InvalidAddress,
}

/** Zeroed frames L2 gives for new tables. Calls take them from the end. */
TableFrames :: struct {
    /** How many of frames are left to take, at most 4; a call that takes one lowers it. */
    count : u32,
    /** The frames' physical addresses, each a zeroed 4 KiB frame, the first count of them still available. */
    frames : PhysicalAddress[4],
}

/** Table frames a call let go of. L2 frees them once the IOMMU can no longer reach them. */
FreedFrames :: struct {
    /** How many of frames hold frames let go of, at most 4; L2 sets it to 0 before a call. */
    count : u32,
    /** The let-go frames' physical addresses, the first count of them meaningful. */
    frames : PhysicalAddress[4],
}

/** What's written, and where, to raise a message-signaled interrupt: arch_interface's MsiMessage. */
MsiMessage :: struct {
    /** The physical address the device writes to. */
    address : u64,
    /** The 32-bit value the device writes there. */
    data : u32,
}

/** A DMA access an IOMMU blocked, or an interrupt it didn't remap. */
DmaFault :: struct {
    /** The stream the access came from: the device's requester ID on VT-d, its StreamID on an SMMUv3. */
    stream : u32,
    /**
     * The page it was to, as the device addressed it; for an interrupt, the remapped interrupt's index. 0 when the
     * IOMMU doesn't say, as for an SMMUv3 fault that isn't a translation's.
     */
    address : u64,
    /** Whether the access was a write; false for a read, and for a fault whose kind of access isn't known. */
    write : bool,
    /** Whether it's an interrupt the IOMMU didn't remap, rather than a DMA access. */
    interrupt : bool,
    /** Why, as the IOMMU numbers its reasons. */
    reason : u32,
}

/** What identify finds out about an IOMMU. */
IommuInfo :: struct {
    /** The I/O virtual addresses its domains can have: below 1 << address_bits, at least 39. */
    address_bits : u32,
    /** Its major version, as its registers give it. */
    major : u32,
    /** Its minor version, as its registers give it. */
    minor : u32,
    /** The bytes of zeroed, contiguous memory enable takes, for its tables and queues. */
    memory : u64,
    /** Domain IDs from 1 up to this, one per domain on it. */
    domain_ids : u32,
    /** The interrupts it remaps, by index from 0, once it's enabled; 0 if it doesn't. */
    interrupts : u32,
    /**
     * Whether it signals its faults by a message (route_faults); otherwise L2 asks for them (next_fault) now and then.
     */
    fault_messages : bool,
}

/**
 * Identify an IOMMU, and keep what's needed of it, changing nothing: DMA through it goes on as before, translated or
 * not.
 *
 * @param iommu Where the implementation keeps what it needs of the IOMMU, which L2 owns and passes to every later
 *     call on it; what's there before is overwritten.
 * @param kind The kind of IOMMU the platform service registered it as.
 * @param registers Where L2 mapped its registers, uncached, in the kernel's address space.
 * @param size How many bytes of registers are mapped there.
 * @return What the kernel needs to know of it, like how much memory enable takes.
 * @error UnsupportedKind This implementation doesn't drive kind.
 * @error NotFound The registers don't identify an IOMMU of that kind, or size is less than its registers take.
 * @error Unsupported It lacks the translation, page size or address width the kernel needs.
 */
identify : fn(iommu: ptr[mut Iommu], kind: IommuKind, registers: VirtualAddress, size: u64) -> Result[IommuInfo, IommuError] : ---

/**
 * Turn translation on. Every stream is blocked until it's attached to a domain; its faults are recorded, not yet
 * signalled (route_faults).
 *
 * @param iommu The IOMMU, as identify left it.
 * @param memory The physical address of info.memory bytes of zeroed, contiguous memory for its tables and queues,
 *     which it keeps from then on.
 * @param direct_map_offset The direct map's offset, what's added to a physical address to reach it, through which
 *     the implementation reaches memory and the rest of what it uses, like domains' tables.
 * @error Timeout It didn't do what it was told in time, like turning translation on; how far it got isn't said.
 */
enable : fn(iommu: ptr[mut Iommu], memory: PhysicalAddress, direct_map_offset: u64) -> Result[void, IommuError] : ---

/**
 * Signal the IOMMU's faults by writing a message, from now on, for one whose info.fault_messages is true.
 *
 * @param iommu The IOMMU, enabled.
 * @param message What it writes, and where, to raise the interrupt L2 handles its faults on.
 */
route_faults : fn(iommu: ptr[mut Iommu], message: MsiMessage) : ---

/**
 * Make a domain an empty one on the IOMMU, which nothing is mapped in or attached to.
 *
 * @param iommu The IOMMU the domain is on.
 * @param domain Where the implementation keeps the domain, which L2 owns; what's there before is overwritten.
 * @param id The domain's ID on the IOMMU, from 1 up to info.domain_ids, which no other domain on it has.
 * @param root The physical address of a zeroed frame for its top-level table, which the domain keeps until it's
 *     released.
 */
init_domain : fn(iommu: ptr[Iommu], domain: ptr[mut Domain], id: u32, root: PhysicalAddress) : ---

/**
 * Translate a stream's DMA through a domain from now on, instead of what it was before.
 *
 * @param iommu The IOMMU, enabled.
 * @param domain The domain, made with init_domain on this IOMMU.
 * @param stream The stream: a device's requester ID on VT-d, its StreamID on an SMMUv3.
 * @param frames Zeroed frames for the IOMMU's own tables of streams, taken from the end as they're needed.
 * @error NeedFrames frames ran out; refill them and call again.
 * @error InvalidAddress The stream is outside what the IOMMU has.
 */
attach : fn(iommu: ptr[mut Iommu], domain: ptr[Domain], stream: u32, frames: ptr[mut TableFrames]) -> Result[void, MapError] : ---

/**
 * Block a stream's DMA again, and leave nothing the IOMMU cached of the domain's for it, by the time this returns.
 *
 * @param iommu The IOMMU, enabled.
 * @param domain The domain the stream was attached to.
 * @param stream The stream, as attach was given it.
 */
detach : fn(iommu: ptr[mut Iommu], domain: ptr[Domain], stream: u32) : ---

/**
 * Map a 4 KiB page in a domain. Until invalidate, the IOMMU may not see it.
 *
 * @param iommu The IOMMU the domain is on.
 * @param domain A domain made with init_domain on this IOMMU and not yet released; its tables gain the page's entry,
 *     and any tables on the way to it, from frames.
 * @param address The page's I/O virtual address, as the domain's devices address it: page-aligned and below
 *     1 << info.address_bits.
 * @param physical The physical address it's mapped to, page-aligned.
 * @param writable Whether devices may write it as well as read it.
 * @param device Whether it's device memory, like the MSI doorbell (arch_interface.msi_doorbell), rather than RAM.
 * @param frames Zeroed frames for the domain's tables, taken from the end as they're needed.
 * @error NeedFrames frames ran out; refill them and call again. Nothing was changed.
 * @error AlreadyMapped Something is mapped at address already, which is left as it was.
 * @error InvalidAddress address isn't page-aligned, or is outside the domain's addresses.
 */
map : fn(iommu: ptr[Iommu], domain: ptr[mut Domain], address: u64, physical: PhysicalAddress, writable: bool, device: bool,
    frames: ptr[mut TableFrames]) -> Result[void, MapError] : ---

/**
 * Unmap a 4 KiB page in a domain, if it's mapped; until invalidate, the IOMMU may still reach it.
 *
 * @param iommu The IOMMU the domain is on.
 * @param domain A domain made with init_domain on this IOMMU; only the page's entry is cleared, and tables left empty
 *     stay until the domain is released.
 * @param address The page's I/O virtual address; an address not mapped is left as it is.
 */
unmap : fn(iommu: ptr[Iommu], domain: ptr[mut Domain], address: u64) : ---

/**
 * Leave nothing the IOMMU cached of a domain's tables, by the time this returns: after unmapping, so it no longer
 * reaches what was mapped; after mapping, where it may cache what isn't mapped, like VT-d's caching mode.
 *
 * @param iommu The IOMMU the domain is on.
 * @param domain The domain whose tables changed, made with init_domain on this IOMMU; it isn't changed, and the
 *     invalidation may cover its ID as a whole rather than the pages changed.
 * @param mapped Whether the batch of changes since the last invalidate mapped pages, rather than only unmapping
 *     them; an IOMMU that doesn't cache what isn't mapped may then do nothing.
 */
invalidate : fn(iommu: ptr[mut Iommu], domain: ptr[Domain], mapped: bool) : ---

/**
 * Let go of a domain's tables, all but its root, as many as freed has room for each call. Nothing is attached to it
 * any more.
 *
 * @param iommu The IOMMU the domain is on.
 * @param domain The domain, which nothing is attached to.
 * @param freed Where the frames let go of are put, which L2 frees once the IOMMU can no longer reach them.
 * @return True once only the root is left, false if there are more to let go of, so L2 calls again.
 */
release_domain : fn(iommu: ptr[Iommu], domain: ptr[mut Domain], freed: ptr[mut FreedFrames]) -> bool : ---

/**
 * Take the oldest fault the IOMMU recorded and hasn't given yet from its records.
 *
 * @param iommu The IOMMU, enabled.
 * @return The fault, or null if there are none left.
 */
next_fault : fn(iommu: ptr[mut Iommu]) -> DmaFault? : ---

/**
 * Make a remapped interrupt deliver a vector to a CPU, raised from one stream only. The IOMMU uses it once this
 * returns.
 *
 * @param iommu The IOMMU, enabled, with info.interrupts above 0; one that remaps none is never asked.
 * @param index Which remapped interrupt, from 0 below info.interrupts.
 * @param stream The only stream that may raise it.
 * @param cpu_hardware_id The hardware ID of the CPU it's delivered to.
 * @param vector The vector it's delivered as, an InterruptId.
 * @param level Whether it's level-triggered, as a wired line remapped may be; a message is edge-triggered.
 * @return The message the stream's device writes to raise it; a wired line's controller is programmed from it.
 */
remap_interrupt : fn(iommu: ptr[mut Iommu], index: u32, stream: u32, cpu_hardware_id: u64, vector: u32, level: bool) -> MsiMessage : ---

/**
 * Make a remapped interrupt raise nothing, leaving nothing the IOMMU cached of it, by the time this returns.
 *
 * @param iommu The IOMMU, enabled.
 * @param index Which remapped interrupt, from 0 below info.interrupts.
 */
unmap_interrupt : fn(iommu: ptr[mut Iommu], index: u32) : ---
