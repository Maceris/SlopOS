/**
 * The arch interface: what every architecture package (L1) implements and the kernel core (L2)
 * calls. Specified in docs/specs/arch_interface.md, with its rules for L2.
 *
 * Functions here are declarations only (---). The kernel imports one architecture package as
 * arch, which defines each of them with the same signature, and the per-architecture types
 * (the empty structs) under the same names.
 */
package arch_interface

import runtime from "base"
import boot_info from "../boot_info"
// The system ABI's types, like CpuFeatures (0019)
import slop_os from "std/os"

/** A physical address, as BootInfo gives them. */
PhysicalAddress :: boot_info.PhysicalAddress
/** A virtual address, in the kernel's half or a user address space. */
VirtualAddress :: boot_info.VirtualAddress

/**
 * User-mode registers saved at kernel entry: general registers, instruction and stack
 * pointers, flags.
 */
UserRegisters :: struct {}

/**
 * Vector and floating-point state of one thread. Its size depends on VectorConfig, so L2
 * allocates it separately, with vector_state_size and vector_state_alignment.
 */
VectorState :: struct {}

/** One CPU's architecture state, like x86-64's GDT and TSS. Must not move after init_cpu. */
ArchCpu :: struct {}

/**
 * A thread's debugging state (decisions/0183, 12b): whether it single-steps, and its hardware breakpoints and
 * watchpoints, in the form the CPU's debug registers take them. All zero is none, what a thread starts with.
 */
DebugRegisters :: struct {}

/** State shared by every CPU, like x86-64's IDT. Must not move after init_system. */
ArchSystem :: struct {}

/** One address space's page-table root and address-space tag. */
PageTable :: struct {}

/** One wired interrupt controller the platform service registered (0039), like an I/O APIC. */
InterruptController :: struct {}

/** Where a stack is, in the kernel's virtual addresses. */
StackRange :: struct {
    /** The stack's lowest address. */
    low : VirtualAddress,
    /** One past the stack's highest address, where an empty stack's pointer starts. */
    high : VirtualAddress,
}

/**
 * The events that can arrive at any time, including in the kernel, each with a separate stack; they index
 * CpuStacks.critical.
 */
CriticalEvent :: enum #backed_by(u8) {
    /** A non-maskable interrupt. */
    Nmi,
    /** A fault while delivering a fault (x86-64's double fault). */
    DoubleFault,
    /** A hardware error the CPU reports (x86-64's machine check). */
    MachineCheck,
}

/** The stacks a CPU's entries run on, which L2 allocates and init_cpu installs. */
CpuStacks :: struct {
    /** Where entries from user mode and from idle run. */
    kernel : StackRange,
    /** Indexed by CriticalEvent. Architectures without separate stacks for an event ignore its entry. */
    critical : StackRange[3],
}

/**
 * Read the CPU's features. L2 calls it once, on the boot CPU.
 *
 * @return The calling CPU's features. CpuFeatures is defined with the system ABI (0019).
 */
detect_features : fn() -> slop_os.CpuFeatures : ---

/**
 * Find the first baseline feature the CPU lacks (x86-64-v3 on x86-64, 0003), which the kernel can't run without.
 *
 * @param features The features detect_features read.
 * @return The missing feature's name, or null when the CPU has the whole baseline.
 */
missing_baseline_feature : fn(features: ptr[slop_os.CpuFeatures]) -> string? : ---

/**
 * Set up the state shared by every CPU. Called once, on the boot CPU, before init_cpu.
 *
 * @param system Where the shared state goes, in L2's own memory; it must not move afterwards.
 * @param firmware The firmware's tables, for what the architecture finds in them, like AArch64's interrupt
 *     controller in the device tree.
 * @param direct_map_offset The virtual address of physical 0 in the bootloader's direct map, through which the
 *     tables are reached.
 */
init_system : fn(system: ptr[mut ArchSystem], firmware: ptr[boot_info.FirmwareTables], direct_map_offset: u64) : ---

/**
 * Set up the calling CPU: descriptor tables, entry points, the stacks entries use, user-access protection,
 * no-execute, address-space tags, and the default vector state.
 *
 * Records carrier and context in cpu, and cpu in the architecture's per-CPU register (x86-64: IA32_KERNEL_GS_BASE;
 * AArch64: TPIDR_EL1; RISC-V: sscratch), for entry stubs. Keeping carrier and context makes them #escaping
 * (Hemera's docs/memory.md).
 *
 * @param system The shared state init_system set up.
 * @param cpu The calling CPU's architecture state, in L2's memory; it must not move afterwards.
 * @param carrier The carrier block entries run with; it's kept, so it has to stay valid while the CPU runs.
 * @param context The context entries run with; it's kept, so it has to stay valid while the CPU runs.
 * @param stacks The stacks entries run on; the stacks themselves have to stay while the CPU runs.
 */
init_cpu : fn(
    system: ptr[ArchSystem],
    cpu: ptr[mut ArchCpu],
    carrier #escaping : ptr[mut runtime.CarrierBlock],
    context #escaping : ptr[runtime.Context],
    stacks: ptr[CpuStacks],
) : ---

/** W^X: a mapping is never both writable and executable. */
Protection :: enum #backed_by(u8) {
    /** Readable only. */
    Read,
    /** Readable and writable, never executable. */
    ReadWrite,
    /** Readable and executable, never writable. */
    ReadExecute,
}

/** How the CPU caches a mapping's memory. */
CacheMode :: enum #backed_by(u8) {
    /** Normal cached memory, for RAM. */
    WriteBack,
    /** Uncached, with writes combined into bursts, for framebuffers. */
    WriteCombining,
    /** Uncached and strongly ordered, for device registers. */
    Device,
}

/** How a page is mapped: what it allows, how it's cached, and who reaches it. */
Mapping :: struct {
    /** What accesses the page allows. */
    protection : Protection,
    /** How the page's memory is cached. */
    cache : CacheMode,
    /** Accessible from user mode. Kernel mappings never are. */
    user : bool,
    /** Kept in the TLB across address-space switches. Kernel mappings only. */
    global : bool,
    /**
     * Executable pages indirect branches may land in only on landing pads (slop_os.PROTECTION_GUARDED, decisions/0186):
     * AArch64's guarded pages; ignored elsewhere.
     */
    guarded : bool = false,
    /**
     * A shadow stack's pages (decisions/0186), with protection Read: x86-64's shadow-stack pages (read-only and dirty),
     * which only shadow-stack accesses write.
     */
    shadow_stack : bool = false,
}

/** The size of one page a mapping maps, a level of the page tables. */
PageSize :: enum #backed_by(u8) {
    /** 4 KiB, the smallest page. */
    Size4K,
    /** 2 MiB, one level up. */
    Size2M,
    /** 1 GiB, two levels up; not every CPU supports it (supports_page_size). */
    Size1G,
}

/** Distinguishes address spaces in the TLB (x86-64 PCID, AArch64 ASID, RISC-V ASID). */
AddressSpaceTag :: distinct alias u16

/** Zeroed frames L2 provides for new page-table levels. map takes frames from the end. */
TableFrames :: struct {
    /** How many of frames are left to take, 0 to 4. */
    count : u32,
    /** The frames, each a zeroed 4 KiB physical frame; only the first count are meaningful. */
    frames : PhysicalAddress[4],
}

/** Page-table frames a call emptied. L2 frees them once no CPU can still use them. */
FreedTables :: struct {
    /** How many of frames hold freed tables, 0 to 4; L2 empties it by setting it to 0. */
    count : u32,
    /** The freed tables' physical frames; only the first count are meaningful. */
    frames : PhysicalAddress[4],
}

/** TLB entries to flush. Once full, or with all set, it covers the whole tag. */
TlbBatch :: struct {
    /** The address space the entries are for. */
    tag : AddressSpaceTag,
    /** Whether every entry for tag is to be flushed, not just addresses. */
    all : bool,
    /** How many of addresses are set, 0 to 16. */
    count : u32,
    /** The virtual addresses of pages to flush; only the first count are meaningful. */
    addresses : VirtualAddress[16],
}

/** Why map couldn't map a page. */
MapError :: enum #backed_by(u8) {
    /** tables ran out. Refill it and call again; nothing was changed. */
    NeedTableFrames,
    /** Something is already mapped there. */
    AlreadyMapped,
    /** Not aligned to the page size, or outside the range for user or kernel mappings. */
    InvalidAddress,
    /** The CPU doesn't support this page size. */
    UnsupportedPageSize,
}

/** Why unmap or protect couldn't change a page. */
UnmapError :: enum #backed_by(u8) {
    /** Nothing of that page size is mapped there. */
    NotMapped,
    /** The range covers part of a larger page. */
    PartOfLargerPage,
    /** freed is full. Empty it and call again; nothing was changed. */
    NeedFreedSpace,
}

/**
 * Give the range of addresses user mode may use.
 *
 * @return low The lowest user-mode address.
 * @return high One past the highest user-mode address.
 */
user_address_range : fn() -> (low, high: VirtualAddress) : ---

/**
 * Count the address-space tags the CPU supports.
 *
 * @return How many tags there are, so the valid tags are 0 to one less; 1 means tags aren't supported.
 */
address_space_tag_count : fn() -> u32 : ---

/**
 * Tell whether the CPU supports a page size.
 *
 * @param size Any of the sizes; one the CPU lacks gives false rather than failing.
 * @return Whether map can map pages of that size; Size4K always can.
 */
supports_page_size : fn(size: PageSize) -> bool : ---

/**
 * Count the zeroed frames the kernel's own table needs besides its root.
 *
 * They're tables for the whole kernel half, made up front so every address space shares it as it grows.
 *
 * @return How many contiguous 4 KiB frames init_kernel_page_table's half takes (x86-64: 256, one per top-level
 *     entry); 0 where the kernel half has a root of its own (AArch64's TTBR1).
 */
kernel_half_frames : fn() -> u32 : ---

/**
 * Make table the kernel's own address space, which maps the kernel half and nothing else.
 *
 * @param table The page table to set up, in L2's memory.
 * @param root The physical address of a zeroed 4 KiB frame for the top-level table.
 * @param half The physical address of the first of kernel_half_frames() contiguous zeroed frames; unused when that's
 *     0.
 * @param tag The address-space tag for the kernel's own table.
 * @param direct_map_offset The virtual address of physical 0 in the direct map, through which every table is reached.
 */
init_kernel_page_table : fn(
    table: ptr[mut PageTable],
    root: PhysicalAddress,
    half: PhysicalAddress,
    tag: AddressSpaceTag,
    direct_map_offset: u64,
) : ---

/**
 * Make table a user address space that shares the kernel's kernel half. It maps user addresses only.
 *
 * @param table The page table to set up, in L2's memory.
 * @param root The physical address of a zeroed 4 KiB frame for its top-level table.
 * @param tag The address-space tag it runs with, below address_space_tag_count().
 * @param kernel The kernel's own table, set up by init_kernel_page_table, whose kernel half it shares.
 */
init_page_table : fn(
    table: ptr[mut PageTable],
    root: PhysicalAddress,
    tag: AddressSpaceTag,
    kernel: ptr[PageTable],
) : ---

/**
 * Map one page.
 *
 * A call that fails changes nothing. No TLB flush is needed, since nothing was mapped there before.
 *
 * @param table The address space: user pages only in a user one, kernel pages only in the kernel's own.
 * @param virtual_address Where the page goes, aligned to size.
 * @param physical_address The physical memory it maps, aligned to size.
 * @param size The page's size, which both addresses have to be aligned to; one the CPU doesn't support
 *     (supports_page_size) fails with UnsupportedPageSize.
 * @param mapping How it's mapped.
 * @param tables Zeroed frames for page-table levels the walk lacks, taken from its end.
 * @error NeedTableFrames tables has too few frames; refill it and call again.
 * @error AlreadyMapped A page, or a larger page, is already mapped there.
 * @error InvalidAddress An address isn't aligned to size, or is outside the table's half.
 * @error UnsupportedPageSize The CPU doesn't support size.
 */
map : fn(
    table: ptr[mut PageTable],
    virtual_address: VirtualAddress,
    physical_address: PhysicalAddress,
    size: PageSize,
    mapping: Mapping,
    tables: ptr[mut TableFrames],
) -> Result[void, MapError] : ---

/**
 * Unmap one page, freeing the page tables it leaves empty.
 *
 * flush and freed cover one table. The root, and in the kernel's own table the kernel half's tables, are never freed.
 *
 * @param table A user address space or the kernel's own table; the page's entry is cleared, and the tables it
 *     empties are taken out of it.
 * @param virtual_address The page's address, aligned to size, in table's half; it's what's added to flush.
 * @param size The size it was mapped with.
 * @param freed Where the page-table frames the call empties go; L2 frees them once no CPU can still use them.
 * @param flush Where the page's address is added, for L2 to flush.
 * @return The physical address the page mapped, which the caller still owns.
 * @error NotMapped Nothing of that size is mapped there.
 * @error PartOfLargerPage A larger page covers the address.
 * @error NeedFreedSpace freed hasn't room for the tables the call would empty; nothing was changed.
 */
unmap : fn(
    table: ptr[mut PageTable],
    virtual_address: VirtualAddress,
    size: PageSize,
    freed: ptr[mut FreedTables],
    flush: ptr[mut TlbBatch],
) -> Result[PhysicalAddress, UnmapError] : ---

/**
 * Change how a mapped page is mapped, keeping what it maps.
 *
 * @param table A user address space or the kernel's own table, whichever holds the page; only its entry changes.
 * @param virtual_address The page's address, aligned to size; one outside the half mapping's user names fails with
 *     NotMapped, changing nothing.
 * @param size The size it was mapped with.
 * @param mapping How it's to be mapped now; its user has to match the table's half.
 * @param flush Where the page's address is added, for L2 to flush.
 * @error NotMapped Nothing of that size is mapped there, or the address is outside the half mapping's user names.
 * @error PartOfLargerPage A larger page covers the address.
 */
protect : fn(
    table: ptr[mut PageTable],
    virtual_address: VirtualAddress,
    size: PageSize,
    mapping: Mapping,
    flush: ptr[mut TlbBatch],
) -> Result[void, UnmapError] : ---

/** Where a virtual address is mapped, and how. */
Translation :: struct {
    /** The physical address the virtual address itself maps to, its offset in the page included. */
    physical_address : PhysicalAddress,
    /** How the page holding it is mapped. */
    mapping : Mapping,
}

/**
 * Free an address space's page tables before its root is freed, as many as freed has room for each call.
 *
 * What they mapped isn't touched. L2 frees them, and the root, once no CPU can still use them. Only for user address
 * spaces, never the kernel's own.
 *
 * @param table The user address space, no longer active on any CPU.
 * @param freed Where the freed tables' frames go.
 * @return True once only the root is left; false when freed filled first, so L2 empties it and calls again.
 */
release_user_tables : fn(table: ptr[mut PageTable], freed: ptr[mut FreedTables]) -> bool : ---

/**
 * Find where a virtual address is mapped.
 *
 * @param table A user address space or the kernel's own table; only read, its tables walked from the root.
 * @param virtual_address Any address, not necessarily page-aligned.
 * @return The physical address and the mapping, or null if nothing is mapped there.
 */
translate : fn(table: ptr[PageTable], virtual_address: VirtualAddress) -> Translation? : ---

/**
 * Tell whether a 4 KiB page was touched since this last asked, clearing the mark that says so, without a TLB flush.
 *
 * @param table The address space holding the page; only that page's entry changes, atomically.
 * @param virtual_address An address in the page, mapped as a 4 KiB page.
 * @return Whether the hardware marked the page accessed; false where nothing's mapped there as a 4 KiB page, or the
 *     hardware doesn't keep the mark.
 */
take_accessed : fn(table: ptr[mut PageTable], virtual_address: VirtualAddress) -> bool : ---

/**
 * Switch the calling CPU to an address space. The first switch from the bootloader's tables flushes the whole TLB.
 *
 * @param table The address space, which stays in use by this CPU until it switches away.
 */
activate : fn(table: ptr[PageTable]) : ---

/**
 * Flush entries from the calling CPU's TLB; other CPUs' are L2's to flush, with send_ipi.
 *
 * @param batch The entries, not changed: its addresses for its tag, or the whole tag when all is set or it's full.
 */
flush_tlb : fn(batch: ptr[TlbBatch]) : ---

/**
 * Flush every non-global entry for a tag from the calling CPU's TLB, before the tag is reused.
 *
 * @param tag The address-space tag.
 */
flush_tlb_tag : fn(tag: AddressSpaceTag) : ---

/** An interrupt the CPU can receive, local to each CPU: the vector on x86-64, the INTID on AArch64. */
InterruptId :: distinct alias u32

/** What an inter-processor interrupt asks the CPU it's sent to to do. */
IpiKind :: enum #backed_by(u8) {
    /** Run the scheduler: a higher-priority thread became runnable. */
    Reschedule,
    /** Flush TLB entries L2 queued for this CPU. */
    TlbFlush,
    /** Stop this CPU (panic or shutdown). */
    Stop,
}

/** What a device writes, and where, to raise a message-signaled interrupt (PCIe MSI and MSI-X). */
MsiMessage :: struct {
    /** The physical (bus) address the device writes to. */
    address : u64,
    /** The 32-bit value it writes there. */
    data : u32,
}

/**
 * Give the interrupt IDs L2 may give to devices, wired or message-signaled.
 *
 * @return first The first of them.
 * @return count How many there are, contiguous from first.
 */
device_interrupt_range : fn() -> (first: InterruptId, count: u32) : ---

/**
 * Give the bytes of memory the interrupt controller keeps for each device's MSIs (an ITS's translation table).
 *
 * Message-signaled interrupts (decisions/0073): a device's are known to the interrupt controller by its source (on
 * AArch64, the ITS's device ID; unused on x86-64), and each of them by an event, from 0.
 *
 * @return The bytes add_msi_device takes for each device, 0 for none; null if the controller takes no MSIs at all.
 */
msi_device_memory : fn() -> u64? : ---

/**
 * Give the bytes of memory the interrupt controller needs for MSIs at all. Asked once every CPU has started.
 *
 * @return The bytes init_msi takes, 0 for none.
 */
msi_controller_memory : fn() -> u64 : ---

/**
 * Set up MSIs, once, before any device's are added.
 *
 * @param memory The physical address of msi_controller_memory()'s bytes, zeroed and contiguous, aligned to their size
 *     rounded up to a power of two; the controller keeps it for good. Unused when that size is 0.
 */
init_msi : fn(memory: PhysicalAddress) : ---

/**
 * Make a device's MSIs known to the interrupt controller.
 *
 * @param source The device's source (on AArch64, its ITS device ID; unused on x86-64).
 * @param memory The physical address of msi_device_memory()'s bytes, zeroed and contiguous, which the controller keeps
 *     until remove_msi_device. Unused when that size is 0.
 * @param events How many events the device has, numbered from 0.
 */
add_msi_device : fn(source: u32, memory: PhysicalAddress, events: u32) : ---

/**
 * Forget a device's MSIs, every event of them; its memory is the caller's again afterwards.
 *
 * @param source The device's source, as add_msi_device took it.
 */
remove_msi_device : fn(source: u32) : ---

/**
 * Route a device's event to a CPU as an interrupt.
 *
 * @param source The device's source, as add_msi_device took it.
 * @param event The event, below the device's events.
 * @param cpu_hardware_id The CPU's hardware ID (BootCpu.hardware_id).
 * @param id The interrupt it arrives as, from device_interrupt_range.
 * @return The message the device sends to raise it, for its driver to program.
 */
route_msi : fn(source: u32, event: u32, cpu_hardware_id: u64, id: InterruptId) -> MsiMessage : ---

/**
 * Deliver an event route_msi routed to another CPU, or as another interrupt, instead.
 *
 * @param source The device's source, as add_msi_device and route_msi took it; with event, it names the routed event to
 *     move.
 * @param event The event, already routed.
 * @param cpu_hardware_id The hardware ID of the CPU it goes to now.
 * @param id The interrupt it arrives as now.
 * @return The message the device sends to raise it now, which may be the one it had; if not, the driver programs it.
 */
move_msi : fn(source: u32, event: u32, cpu_hardware_id: u64, id: InterruptId) -> MsiMessage : ---

/**
 * Stop delivering a device's event.
 *
 * @param source The device's source, as add_msi_device and route_msi took it; with event, it names the event to stop,
 *     and one that isn't routed is ignored.
 * @param event The event, routed by route_msi.
 */
unroute_msi : fn(source: u32, event: u32) : ---

/**
 * Give the page devices write their MSIs to as memory.
 *
 * An IOMMU translating their DMA must map it into each of their domains, at its own address, for the MSIs to arrive.
 *
 * @return The page's physical address (AArch64: the ITS's GITS_TRANSLATER); null where MSIs aren't DMA an IOMMU
 *     translates (x86-64, whose interrupt range VT-d takes as interrupts).
 */
msi_doorbell : fn() -> PhysicalAddress? : ---

/**
 * Acknowledge a device interrupt to the interrupt controller, once L2 has masked a level-triggered line.
 *
 * @param id The interrupt, one the calling CPU took.
 */
end_of_interrupt : fn(id: InterruptId) : ---

/**
 * Send an inter-processor interrupt. It doesn't wait for the CPU to take it.
 *
 * @param cpu_hardware_id The target CPU's hardware ID (BootCpu.hardware_id).
 * @param kind What it asks of the CPU.
 */
send_ipi : fn(cpu_hardware_id: u64, kind: IpiKind) : ---

/**
 * Tell whether an interrupt is waiting, for preemption points. Interrupts stay disabled.
 *
 * @return Whether the calling CPU has an interrupt pending.
 */
interrupt_pending : fn() -> bool : ---

/**
 * Wait for an interrupt with interrupts enabled. The interrupt enters
 * kernel_entry.interrupt with from = .Idle.
 */
idle #never_returns : fn() : ---

/** Kinds of wired interrupt controller. An architecture supports only some of them. */
ControllerKind :: enum #backed_by(u8) {
    /** x86-64's I/O APIC. */
    IoApic,
    /** AArch64: a GIC distributor's shared peripheral interrupts. */
    GicDistributor,
    /** RISC-V's Platform-Level Interrupt Controller. */
    Plic,
    /** RISC-V's Advanced Platform-Level Interrupt Controller. */
    Aplic,
}

/** How a wired line signals its interrupt. */
Trigger :: enum #backed_by(u8) {
    /** By a change of level; each change is one interrupt. */
    Edge,
    /** By holding a level, until the device is serviced. */
    Level,
}

/** Which level of a wired line is active. */
Polarity :: enum #backed_by(u8) {
    /** The line is active high. */
    ActiveHigh,
    /** The line is active low. */
    ActiveLow,
}

/** Why init_interrupt_controller couldn't set up a controller. */
ControllerError :: enum #backed_by(u8) {
    /** This architecture doesn't support the kind. */
    UnsupportedKind,
    /** The registers don't identify a controller of that kind. */
    NotFound,
}

/**
 * Set up a wired interrupt controller, with every line masked.
 *
 * @param controller Where its state goes, in L2's memory.
 * @param kind What kind of controller it is.
 * @param registers The virtual address L2 mapped its registers at, as Device memory.
 * @return How many lines it has, numbered from 0.
 * @error UnsupportedKind This architecture doesn't support kind.
 * @error NotFound The registers don't identify a controller of that kind.
 */
init_interrupt_controller : fn(
    controller: ptr[mut InterruptController],
    kind: ControllerKind,
    registers: VirtualAddress,
) -> Result[u32, ControllerError] : ---

/**
 * Route a wired line to a CPU as an interrupt, leaving it masked.
 *
 * @param controller The controller, set up by init_interrupt_controller.
 * @param line The line, below the count init_interrupt_controller returned.
 * @param cpu_hardware_id The CPU's hardware ID (BootCpu.hardware_id).
 * @param id The interrupt it arrives as, from device_interrupt_range.
 * @param trigger How the line signals.
 * @param polarity Which level is active.
 */
route_wired : fn(
    controller: ptr[mut InterruptController],
    line: u32,
    cpu_hardware_id: u64,
    id: InterruptId,
    trigger: Trigger,
    polarity: Polarity,
) : ---

/**
 * Route a wired line through an IOMMU's interrupt remapping (decisions/0182), leaving it masked: its entry names the
 * remapped interrupt the IOMMU gave, which delivers id to its CPU.
 *
 * @param controller The controller, set up by init_interrupt_controller.
 * @param line The line, below the count init_interrupt_controller returned.
 * @param message The message the IOMMU gave for the remapped interrupt (iommu_interface.remap_interrupt), which says
 *     its handle.
 * @param id The interrupt it arrives as, which the remapped interrupt delivers.
 * @param trigger How the line signals.
 * @param polarity Which level is active.
 */
route_wired_remapped : fn(
    controller: ptr[mut InterruptController],
    line: u32,
    message: MsiMessage,
    id: InterruptId,
    trigger: Trigger,
    polarity: Polarity,
) : ---

/**
 * Mask a wired line, so it raises no interrupt.
 *
 * @param controller The controller from init_interrupt_controller (an I/O APIC, or a GIC distributor), its
 *     registers written; the rest of the line's routing is kept.
 * @param line The line, from 0, below the controller's count of lines; it isn't checked. It needn't be routed.
 */
mask_wired : fn(controller: ptr[mut InterruptController], line: u32) : ---
/**
 * Unmask a wired line, so it raises its interrupt again.
 *
 * @param controller The controller from init_interrupt_controller (an I/O APIC, or a GIC distributor), its
 *     registers written; the rest of the line's routing is kept.
 * @param line The line, from 0, below the controller's count of lines and routed by route_wired; neither is
 *     checked.
 */
unmask_wired : fn(controller: ptr[mut InterruptController], line: u32) : ---

/**
 * Calibrate the counter and start the timer, on the calling CPU.
 *
 * @param hint BootInfo.counter_frequency_hint, the counter's frequency in Hz if the bootloader measured it; null to
 *     find it another way.
 * @return The counter's frequency in Hz.
 */
init_timer : fn(hint: u64?) -> u64 : ---

/**
 * Read the calling CPU's counter.
 *
 * @return The counter, in ticks at init_timer's frequency; it only grows.
 */
counter : fn() -> u64 : ---

/**
 * Raise a timer interrupt on the calling CPU once counter() reaches a value, replacing any deadline set before.
 *
 * @param value The counter value to fire at; one already past fires at once.
 */
set_deadline : fn(value: u64) : ---

/** Cancel the calling CPU's deadline, so no timer interrupt comes. */
cancel_deadline : fn() : ---

/** Where a new thread starts in user mode. */
UserStart :: struct {
    /** The user-mode address it begins executing at. */
    instruction_pointer : VirtualAddress,
    /** Its initial user-mode stack pointer. */
    stack_pointer : VirtualAddress,
    /** Goes in the first argument register (0026). */
    argument : u64,
}

/** The result of a system call, in the system ABI's result registers. */
SyscallResult :: struct {
    /** 0 for success, otherwise the error variant's tag. */
    tag : u64,
    /** The result's values, in the system ABI's value registers; what they mean is the call's. */
    values : u64[2],
}

/** Which vector state a thread uses. */
VectorConfig :: struct {
    /** Whether a thread uses the architecture's largest vector state (AVX-512, 0023). */
    extended : bool,
}

/**
 * Set up a new thread's registers. Every other register is zero, so no kernel value leaks (0026).
 *
 * @param registers The thread's registers, all overwritten.
 * @param start Where it starts, and its argument.
 */
init_user_registers : fn(registers: ptr[mut UserRegisters], start: ptr[UserStart]) : ---

/**
 * Read which system call a thread made.
 *
 * @param registers The thread's registers, saved at the system call's entry.
 * @return The call's number, from the system ABI's number register.
 */
syscall_number : fn(registers: ptr[UserRegisters]) -> u64 : ---
/**
 * Read one of a system call's arguments.
 *
 * @param registers The thread's registers, saved at the system call's entry.
 * @param index Which argument, from 0, in the system ABI's order.
 * @return The value of the argument's register.
 */
syscall_argument : fn(registers: ptr[UserRegisters], index: u32) -> u64 : ---
/**
 * Set a system call's result, for when the thread returns to user mode.
 *
 * @param registers The calling thread's registers, saved at its system call's entry; only the system ABI's result
 *     registers change.
 * @param result The result, written to the system ABI's result registers.
 */
set_syscall_result : fn(registers: ptr[mut UserRegisters], result: ptr[SyscallResult]) : ---
/**
 * Read where a thread is in user mode.
 *
 * @param registers The thread's registers, as its last entry to the kernel (a system call or a fault) saved them; only
 *     read.
 * @return The user-mode instruction pointer it returns to.
 */
instruction_pointer : fn(registers: ptr[UserRegisters]) -> VirtualAddress : ---

/**
 * Go back to the system call instruction, so returning to user mode makes the call again.
 *
 * That's how a call a debugger stopped at its entry runs once it's let go (knowledge/design/kernel.md §4).
 *
 * @param registers The registers of a thread that entered the kernel by a system call.
 */
restart_syscall : fn(registers: ptr[mut UserRegisters]) : ---

/*
 * A thread's registers as a debugger sees them, by index, in the order the system ABI gives for this
 * architecture (slop_os.THREAD_REGISTERS): how many, one, and one set.
 */

/**
 * Count the registers a debugger sees.
 *
 * @return How many there are; the valid indexes are 0 to one less.
 */
user_register_count : fn() -> u32 : ---
/**
 * Read one of a thread's registers, as a debugger sees it.
 *
 * @param registers The thread's registers, as its last entry to the kernel saved them; only read.
 * @param index The register's index in slop_os.THREAD_REGISTERS' order, below user_register_count().
 * @return The register's value as user mode sees it; 0 for an index at user_register_count() or past it.
 */
get_user_register : fn(registers: ptr[UserRegisters], index: u32) -> u64 : ---
/**
 * Set one of a thread's registers, as a debugger sets it.
 *
 * Flags user mode can't change are kept as they were.
 *
 * @param registers The thread's saved registers, which it returns to user mode with; only the indexed one changes, and
 *     only when this returns true.
 * @param index The register's index in slop_os.THREAD_REGISTERS' order, below user_register_count().
 * @param value The register's new value, taken whole for most. An instruction or stack pointer has to be a user
 *     address; for the flags (rflags, pstate) only the bits user mode can change are taken, the rest kept.
 * @return False, changing nothing, for a value user mode can't have (an instruction or stack pointer outside user
 *     addresses); true once it's set.
 */
set_user_register : fn(registers: ptr[mut UserRegisters], index: u32, value: u64) -> bool : ---

/**
 * Set a thread's debugging state from what a debugger asks (thread_set_debug), and its saved registers for stepping.
 *
 * Each slot that isn't Off is checked: its address a user address, and a data slot's size 1, 2, 4 or 8 with the
 * address a multiple of it; on x86-64 also with no more than four slots in all, and on AArch64 no more breakpoints or
 * watchpoints than the CPU has. A hit is reported as a fault: Breakpoint for an Execute slot, Watchpoint for a data
 * slot, SingleStep after a step.
 *
 * @param debug The thread's state, replaced whole.
 * @param registers The thread's saved registers, off its CPU, whose flags say whether it steps.
 * @param step Whether it stops after each instruction it runs in user mode.
 * @param slots The breakpoints and watchpoints, slop_os.DEBUG_SLOTS of them at most.
 * @return True once it's set; false, with nothing changed, if a slot is one the CPU can't set.
 */
set_debug : fn(debug: ptr[mut DebugRegisters], registers: ptr[mut UserRegisters], step: bool, slots: slop_os.DebugSlot[]) -> bool : ---

/**
 * Load a thread's debugging state into the calling CPU, as it returns to user mode; one with none loads nothing.
 *
 * @param debug The thread's state.
 * @param registers The thread's registers, about to be loaded, which AArch64 marks to step one instruction.
 */
debug_on : fn(debug: ptr[DebugRegisters], registers: ptr[mut UserRegisters]) : ---

/**
 * Have the calling CPU trap user mode's reads of its counter, or let them run, for the thread about to return to user
 * mode (slop_os.TRAP_COUNTER, decisions/0183); a CPU changes only when it's asked for the other.
 *
 * @param trapped Whether they trap.
 */
set_counter_trap : fn(trapped: bool) : ---

/**
 * Run a trapped read of the counter, if that's what a thread's instruction is: its value put where the instruction
 * puts it, and the thread moved past it.
 *
 * @param registers The thread's saved registers, at the instruction that trapped.
 * @param instruction The instruction's first four bytes, little-endian, read from the thread's memory; 0 if they
 *     couldn't be.
 * @return The value read; null if the instruction isn't a counter read, with the registers left as they were.
 */
emulate_counter_read : fn(registers: ptr[mut UserRegisters], instruction: u32) -> u64? : ---

/**
 * Turn the calling CPU's breakpoints and watchpoints off, if a thread's are loaded, as it enters the kernel from user
 * mode: so the kernel's own accesses to user memory don't hit them, and the next thread doesn't have them.
 */
debug_off : fn() : ---

/**
 * Return to user mode, on the calling CPU's active page table.
 *
 * @param registers The thread's registers, loaded into the CPU.
 */
return_to_user #never_returns : fn(registers: ptr[UserRegisters]) : ---

/**
 * Give the bytes a thread's vector state takes.
 *
 * @param config Which state the thread uses.
 * @return The VectorState's size in bytes, for L2 to allocate.
 */
vector_state_size : fn(config: VectorConfig) -> usize : ---
/**
 * Give the alignment a VectorState needs.
 *
 * @return The alignment in bytes, a power of two.
 */
vector_state_alignment : fn() -> usize : ---
/**
 * Set up a thread's vector state as it is at reset.
 *
 * @param state The state, vector_state_size(config) bytes aligned to vector_state_alignment().
 * @param config Which state the thread uses.
 */
init_vector_state : fn(state: ptr[mut VectorState], config: VectorConfig) : ---

/**
 * Save the calling CPU's vector registers into a thread's state.
 *
 * @param state The state, set up with the config the CPU has loaded.
 */
save_vector_state : fn(state: ptr[mut VectorState]) : ---

/**
 * Load a thread's state into the calling CPU's vector registers, switching which state components are
 * enabled if its VectorConfig differs from the last one loaded.
 *
 * @param state The state, set up by init_vector_state.
 */
restore_vector_state : fn(state: ptr[VectorState]) : ---

/** What kind of access faulted. */
Access :: enum #backed_by(u8) {
    /** A read. */
    Read,
    /** A write. */
    Write,
    /** An instruction fetch. */
    Execute,
}

/** A page fault, as the architecture reported it. */
PageFault :: struct {
    /** The virtual address that faulted. */
    address : VirtualAddress,
    /** What the access was. */
    access : Access,
    /** A mapping exists, and the access broke its protection. */
    present : bool,
    /** The access was the shadow stack's own, as a call pushing a return address there (decisions/0186). */
    shadow_stack : bool = false,
}

/** A fault user mode took, for L2 to handle. */
Fault :: union {
    /** An access to a page that isn't mapped, or that its mapping doesn't allow. */
    Page(PageFault),
    /** An instruction the CPU doesn't recognize. */
    InvalidInstruction,
    /** A breakpoint instruction. */
    Breakpoint,
    /** A single step completed, as a debugger asked. */
    SingleStep,
    /** Integer division by zero or overflow, where the architecture traps on it. */
    Arithmetic,
    /** A misaligned access, where the architecture traps on it. */
    Alignment,
    /** A hardware watchpoint (set_debug) was hit: the address accessed. */
    Watchpoint(u64),
    /** A privileged instruction, or an address the architecture rejects outright. */
    Protection,
    /** A floating-point or vector exception that's unmasked. */
    FloatingPoint,
    /** Hardware control-flow integrity refused a branch or a return (decisions/0186). */
    ControlFlow(ControlFlowFault),
}

/** What hardware control-flow integrity refused (decisions/0186). */
ControlFlowFault :: enum {
    /** A return the shadow stack didn't match: x86-64's control protection exception, or AArch64's GCS. */
    ShadowStack,
    /** An indirect branch to no landing pad: indirect branch tracking or branch target identification. */
    LandingPad,
    /** A signed pointer that failed authentication. */
    Authentication,
}

/** Stop the calling CPU for good, with interrupts disabled. */
halt #never_returns : fn() : ---

/** Hint that the caller is spinning. */
spin_hint : fn() : ---

/**
 * Stop the calling CPU taking interrupts (NMIs still arrive).
 *
 * Code running fibers masks them: while a fiber resumes, its stack holds live frames above the stack pointer, which an
 * interrupt taken on that stack would overwrite (Hemera's docs/calling_convention.md).
 */
mask_interrupts : fn() : ---
/** Let the calling CPU take interrupts again, after mask_interrupts. */
unmask_interrupts : fn() : ---

/**
 * Read one value from the CPU's random source (RDSEED, RNDR, Zkr seed).
 *
 * @return 64 random bits, or null if the CPU has no such source or it failed.
 */
hardware_entropy : fn() -> u64? : ---

/**
 * Tell whether the architecture has I/O ports (x86-64), which port_read and port_write reach (decisions/0093).
 *
 * @return True on x86-64, false elsewhere.
 */
has_io_ports : fn() -> bool : ---

/**
 * Read from an I/O port.
 *
 * @param port Any of the 65536 ports, unchecked: reading one may have a device's side effects. Unused where
 *     there are no I/O ports.
 * @param width How many bytes to read: 1, 2 or 4.
 * @return The value read, zero-extended; null for another width, or where there are no I/O ports.
 */
port_read : fn(port: u16, width: u32) -> u32? : ---

/**
 * Write to an I/O port.
 *
 * @param port Any of the 65536 ports, unchecked. Unused where there are no I/O ports.
 * @param width How many bytes to write: 1, 2 or 4.
 * @param value The value, of which the low width bytes are written.
 * @return True once written; false for another width, or where there are no I/O ports.
 */
port_write : fn(port: u16, width: u32, value: u32) -> bool : ---

/**
 * Set up the architecture's early console. Called once, by L0, before anything is written to it.
 *
 * @param direct_map_offset The bootloader's direct map's offset, through which a console in memory-mapped registers
 *     (AArch64's PL011) is reached, in the bootloader's tables and then in the kernel's own (init_kernel_page_table).
 * @param firmware The firmware's tables, which say where the console is.
 */
early_console_init : fn(direct_map_offset: u64, firmware: ptr[boot_info.FirmwareTables]) : ---

/**
 * Write to the architecture's early console, before any driver exists.
 *
 * @param text The text, written as it is.
 */
early_console_write : fn(text: string) : ---

/**
 * Ask the emulator the kernel runs in to exit, for tests that boot the kernel.
 *
 * Only called when the command line asks for it (test_exit), since on real hardware the device it writes to may be
 * something else entirely.
 *
 * @param code The exit code to ask for; how the emulator reports it is the emulator's.
 */
test_exit : fn(code: u32) : ---

/**
 * Choose how the machine resets and turns off, for reset and power_off to use later. Called once, at boot.
 *
 * @param firmware The firmware's tables, which may say how (AArch64's devicetree names PSCI's conduit).
 * @param direct_map_offset Where physical address 0 is in the bootloader's direct map; 0 means there's none.
 * @return The architecture's method, opaque to L2, which only passes it back; 0 where it found none.
 */
reset_method : fn(firmware: ptr[boot_info.FirmwareTables], direct_map_offset: u64) -> u8 : ---

/**
 * Reset the machine, warm, keeping RAM where the hardware does, so the next boot can read the panic record.
 *
 * @param method What reset_method chose. Returns only if the machine didn't reset, as without a method.
 */
reset : fn(method: u8) : ---

/**
 * Tell whether power_off turns the machine off by itself, without what the firmware's tables say (decisions/0182).
 *
 * @param method What reset_method chose.
 * @return True where the architecture's own means turn it off (AArch64's PSCI); false where L2 has to be told how
 *     (x86-64's ACPI, power_set_off) or there's no way.
 */
can_power_off : fn(method: u8) -> bool : ---

/**
 * Turn the machine off by the architecture's own means, as can_power_off says there are.
 *
 * @param method What reset_method chose. Returns only if the machine didn't turn off.
 */
power_off : fn(method: u8) : ---

/**
 * Raise an NMI on the calling CPU, for tests of the critical-event entry that resumes what it
 * interrupted. Only called when the command line asks for it (test_nmi).
 */
test_nmi : fn() : ---

/**
 * Send another CPU an NMI, for lockup detection (decisions/0183), which interrupts it even with interrupts off.
 *
 * @param cpu_hardware_id The CPU's hardware ID.
 * @return True if it was sent; false where the architecture has no NMI to send, or none set up.
 */
send_nmi : fn(cpu_hardware_id: u64) -> bool : ---

/**
 * Name a register of those the architecture's NMI entry passes kernel_entry.nmi, for a lockup's report.
 *
 * @param index The register's place among them, from 0.
 * @return Its name, a constant, like "rax" or "x29"; "?" past them.
 */
nmi_register_name : fn(index: usize) -> string : ---

/**
 * Log, once at boot, what the CPU has against exploits and transient execution (decisions/0186, 0097): its
 * control-flow integrity mechanisms, the transient-execution issues that apply to it, and the mitigations on.
 *
 * @param features The boot CPU's features, from detect_features.
 */
log_hardening : fn(features: ptr[slop_os.CpuFeatures]) : ---

/**
 * Give the kernel's pointer authentication key, once at boot, after init_system (decisions/0186): each CPU loads it,
 * and turns pointer authentication on, as it first goes idle, where no frame signed before returns. Ignored where the
 * architecture has none.
 *
 * @param system The shared state.
 * @param key The key's 128 bits, random.
 */
set_kernel_pointer_key : fn(system: ptr[mut ArchSystem], key: u64[2]) : ---

/**
 * Say which pointer authentication key the calling CPU returns to user mode with, the thread's process's
 * (decisions/0186): loaded as return_to_user leaves, where no frame signed before returns. Ignored where the
 * architecture has none.
 *
 * @param key The key's 128 bits.
 */
set_user_pointer_key : fn(key: u64[2]) : ---

/**
 * Tell whether the calling CPU gives user threads shadow stacks (decisions/0186): x86-64's CET shadow stacks.
 *
 * @return True if a thread can have one.
 */
has_user_shadow_stacks : fn() -> bool : ---

/**
 * Set the calling CPU's user-mode control-flow integrity for the thread about to return to user mode: landing pads
 * checked or not, and its shadow-stack pointer, 0 for none (decisions/0186). Where the CPU has neither, nothing.
 *
 * @param landing_pads Whether its indirect branches must land on landing pads.
 * @param shadow_stack Its shadow-stack pointer; 0 for no shadow stack.
 */
load_user_control_flow : fn(landing_pads: bool, shadow_stack: u64) : ---

/**
 * Read the calling CPU's user-mode shadow-stack pointer, as a thread that has a shadow stack enters the kernel.
 *
 * @return The pointer.
 */
read_user_shadow_stack : fn() -> u64 : ---

/**
 * Tell whether the kernel's own code runs on shadow stacks on the calling CPU's kind (decisions/0186, Hd): AArch64's GCS
 * at EL1, x86-64's supervisor shadow stacks. Where it does, L2 gives each CPU one (set_kernel_shadow_stack) before it
 * first goes idle; called after the CPU has switched to the kernel's own tables (activate).
 *
 * @return True if a CPU's kernel stack has a shadow stack.
 */
has_kernel_shadow_stacks : fn() -> bool : ---

/**
 * Give a CPU the shadow stack its kernel stack runs with (decisions/0186, Hd): mapped by L2 in the kernel window as a
 * kernel shadow stack (Mapping.shadow_stack, not user), between unmapped guard pages, and owned by L2 for good. The CPU
 * starts on it, empty, from its top, as its kernel stack starts from its top: as it first goes idle, and each time it
 * returns to user mode or idles. Called before the CPU first goes idle, on any CPU.
 *
 * @param cpu The CPU's own state.
 * @param base The shadow stack's lowest kernel virtual address, page aligned.
 * @param size Its size in bytes, a multiple of a page.
 */
set_kernel_shadow_stack : fn(cpu: ptr[mut ArchCpu], base: u64, size: u64) : ---

/** What hardware control-flow integrity the kernel's own code runs under (decisions/0186, Hd). */
KernelControlFlow :: struct {
    /** Its indirect branches land only on landing pads: AArch64's guarded pages, x86-64's supervisor IBT. */
    landing_pads : bool,
    /** Its return addresses are signed with the kernel's own key: AArch64's pointer authentication. */
    signed_returns : bool,
    /** Its returns are checked against a shadow stack: AArch64's GCS at EL1, x86-64's supervisor shadow stacks. */
    shadow_stack : bool,
    /** Where the calling CPU's shadow stack's latest entry is, with shadow_stack; 0 without. */
    shadow_stack_pointer : u64,
}

/**
 * Say what hardware control-flow integrity the kernel's code runs under on the calling CPU, now (decisions/0186, Hd):
 * for the kernel's tests of it, test_tamper and test_branch.
 *
 * @return Each mechanism that's on; signed returns only once the CPU has first gone idle, which turns them on.
 */
kernel_control_flow : fn() -> KernelControlFlow : ---

/** A device the emulator always has that raises a wired interrupt: its controller, and its line there. */
TestDevice :: struct {
    /** The kind of controller its line is on. */
    kind : ControllerKind,
    /** The physical address of the controller's registers, for L2 to map. */
    registers : PhysicalAddress,
    /** The device's line on the controller. */
    line : u32,
    /** How the line signals. */
    trigger : Trigger,
    /** Which level of the line is active. */
    polarity : Polarity,
}

/**
 * Find the emulator's test device, for tests that route a wired interrupt (test_ioapic).
 *
 * On real hardware the platform service finds controllers in the firmware tables instead.
 *
 * @return Where the device is and how its line signals.
 */
test_device : fn() -> TestDevice : ---

/**
 * Start or stop the test device's interrupts, about a thousand a second. Only for test_ioapic.
 *
 * @param on True to start them, false to stop them.
 */
test_device_interrupts : fn(on: bool) : ---
