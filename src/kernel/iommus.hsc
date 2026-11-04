package kernel

import intrinsics from "base"
import runtime from "base"
import iommu_interface from "../iommu_interface"
import boot_info from "../boot_info"
import concurrency from "std"
import slop_os from "std/os"

// Each architecture's IOMMU package, by one name
#if TARGET_ARCH == .x86_64 {
    import iommu_vtd as iommu_unit from "../iommu/vtd"
}
#else_if TARGET_ARCH == .arm64 {
    import iommu_smmuv3 as iommu_unit from "../iommu/smmuv3"
}

/*
 * IOMMUs (roadmap D, decisions/0039, 0079): the platform service registers each one it finds in the firmware tables,
 * with the requester IDs it covers, and the kernel maps its registers and identifies it through its implementation
 * (iommu_interface; VT-d on x86-64, SMMUv3 on AArch64). A device is attached through the IOMMU that covers its
 * requester ID most narrowly, as VT-d's DMAR has a unit for all of a segment's devices besides those another covers,
 * and a domain's devices are all behind one IOMMU, or all behind none.
 *
 * Once it's identified, translation goes on, where its implementation can (translation.hsc).
 *
 * Lock order: a device's lock, then iommus_lock; a device's lock, then an IOMMU's lock.
 */

/** How many IOMMUs the kernel keeps, registered for good: kernel.iommus' size. */
MAX_IOMMUS :: 8
/** The ranges of requester IDs every IOMMU covers, together. */
MAX_IOMMU_SCOPES :: 32
/** The most bytes of registers an IOMMU may have: SMMUv3's are 128 KiB. */
MAX_IOMMU_REGISTERS : u64 : 1 << 20

/** An IOMMU the kernel has registered: kernel.iommus' entries, never removed. */
RegisteredIommu :: struct {
    /** Held (rank Iommu) for everything done through it once it's registered. */
    lock : concurrency.SpinLock,
    /** Its implementation's state (VT-d on x86-64, SMMUv3 on AArch64). */
    unit : iommu_unit.Iommu,
    /** What kind of IOMMU it is. */
    kind : iommu_interface.IommuKind,
    /** What identifying it found: its version, its I/O address bits, and what it can do. */
    info : iommu_interface.IommuInfo,
    /** Where its registers are mapped in the kernel window, uncached. */
    registers : u64,
    /** The physical address of its registers, as it was registered with; how a second registration is known. */
    physical : u64,
    /** The size of its registers in bytes, as it was registered with. */
    size : u64,
    /** Whether translation is on (translation.hsc). */
    translating : bool,
    /** The domain IDs in use, a bit each, below id_limit. */
    ids : u64[MAX_DOMAIN_IDS / 64],
    /** How many domain IDs it gives out, at most MAX_DOMAIN_IDS. */
    id_limit : u32,
    /** How many DMA faults it has reported. */
    faults : u64,
    /** Whether it remaps interrupts, so a device's MSIs reach a CPU only through its entries. */
    remapping : bool,
    /** Its remapped interrupts in use, a bit each, below interrupt_limit. */
    interrupts : u64[MAX_REMAPPED_INTERRUPTS / 64],
    /** How many remapped interrupts it gives out, at most MAX_REMAPPED_INTERRUPTS. */
    interrupt_limit : u32,
}

/**
 * A range of requester IDs behind one IOMMU: count of them from first (slop_os.device_address), as streams from
 * stream.
 */
IommuScope :: struct {
    /** The IOMMU's number, its index in kernel.iommus. */
    iommu : u32,
    /** The first requester ID, with its segment in the upper 16 bits. */
    first : u32,
    /** How many requester IDs, at least 1, all in first's segment. */
    count : u32,
    /** The stream (on SMMUv3, the stream ID) first is at the IOMMU; the next IDs are the next streams. */
    stream : u32,
}

/** Which IOMMU a device is behind, and the stream it is there. */
IommuPath :: struct {
    /** The IOMMU's number plus one, 0 for none. */
    iommu : u32,
    /** The device's stream at that IOMMU; meaningless when iommu is 0. */
    stream : u32,
}

/**
 * Register an IOMMU and a range of requester IDs it covers.
 *
 * One registered already, of the same kind at the same physical address, is the same IOMMU, and covers these too; a
 * scope registered already is kept once. A new one's registers are mapped, it's identified, and translation goes on
 * where its implementation can. Takes iommus_lock.
 *
 * @param kernel The kernel: its iommus and iommu_scopes grow, under iommus_lock, and a new IOMMU's registers are
 *     mapped into its window. Called from the platform service's system call, with interrupts off.
 * @param kind What kind of IOMMU it is.
 * @param physical The physical address of its registers, as the firmware tables give it.
 * @param size The size of its registers in bytes, which the caller limits to MAX_IOMMU_REGISTERS.
 * @param first The first requester ID it covers (slop_os.device_address), its segment in the upper 16 bits.
 * @param count How many requester IDs from first it covers: at least 1, and none past the segment's last.
 * @param stream The stream first is at the IOMMU; stream + count may not pass 2^32.
 * @return The IOMMU's number, its index in kernel.iommus.
 * @error InvalidSize count was 0, or the range went past its segment, or its streams past 2^32.
 * @error OutOfMemory A new IOMMU's registers couldn't be mapped into the kernel window.
 * @error NoIommu The registers aren't an IOMMU of that kind the kernel can drive.
 * @error TooManyIommus MAX_IOMMUS are registered already, or MAX_IOMMU_SCOPES scopes; an IOMMU registered before
 *     the scopes ran out stays registered.
 */
register_iommu :: fn(kernel: ptr[mut Kernel], kind: iommu_interface.IommuKind, physical: u64, size: u64, first: u32, count: u32,
    stream: u32) -> Result[u32, slop_os.DeviceError] {
    if count == 0 || (first & 0xffff) + count > 0x10000 || stream > ~count {
        return .Error(.InvalidSize)
    }
    number := find_iommu(kernel, kind, physical)
    if number is_none {
        made :: add_iommu(kernel, kind, physical, size)?
        number = made
    }
    index :: number or_else 0
    lock_at(&kernel.iommus_lock, .Iommus)
    known := false
    for i in 0..<cast[usize](kernel.iommu_scope_count) {
        scope :: &kernel.iommu_scopes[i % MAX_IOMMU_SCOPES]
        known = known || (scope.iommu == index && scope.first == first && scope.count == count && scope.stream == stream)
    }
    slot :: cast[usize](kernel.iommu_scope_count)
    full :: !known && slot >= MAX_IOMMU_SCOPES
    if !known && slot < MAX_IOMMU_SCOPES {
        kernel.iommu_scopes[slot] = IommuScope.{iommu = index, first = first, count = count, stream = stream}
        kernel.iommu_scope_count += 1
    }
    unlock_at(&kernel.iommus_lock, .Iommus)
    if full {
        return .Error(.TooManyIommus)
    }
    return .Ok(index)
}

/**
 * Find a registered IOMMU by its kind and registers.
 *
 * @param kernel The kernel, whose iommus are read up to iommu_count, loaded with acquire; no lock is taken.
 * @param kind The IOMMU's kind.
 * @param physical The physical address of its registers.
 * @return Its number, its index in kernel.iommus, or null if none of that kind is registered there.
 */
find_iommu :: fn(kernel: ptr[mut Kernel], kind: iommu_interface.IommuKind, physical: u64) -> u32? {
    for index in 0..<cast[usize](intrinsics.atomic_load_u32_acquire(&kernel.iommu_count)) {
        if index < MAX_IOMMUS && kernel.iommus[index].physical == physical && kernel.iommus[index].kind == kind {
            return cast[u32](index)
        }
    }
    return null
}

/**
 * Add a new IOMMU: its registers mapped, identified by its implementation, and its translation started.
 *
 * If another registration added it since the caller looked, that one is kept and the registers mapped here are
 * unmapped again. Takes iommus_lock.
 *
 * @param kernel The kernel: the registers are mapped into its window, and its iommus grow under iommus_lock.
 * @param kind What kind of IOMMU it is.
 * @param physical The physical address of its registers.
 * @param size The size of its registers in bytes.
 * @return The IOMMU's number, its index in kernel.iommus, the new one's or the one registered meanwhile.
 * @error OutOfMemory Its registers couldn't be mapped into the kernel window.
 * @error NoIommu The registers aren't an IOMMU of that kind the kernel can drive; they're unmapped again.
 * @error TooManyIommus MAX_IOMMUS are registered already; the registers are unmapped again.
 */
add_iommu :: fn(kernel: ptr[mut Kernel], kind: iommu_interface.IommuKind, physical: u64, size: u64) -> Result[u32, slop_os.DeviceError] {
    mapped := cast[u64](0)
    match map_device(kernel, cast[boot_info.PhysicalAddress](physical), size) {
        case Ok(address) => mapped = address
        case Error(error) => return .Error(.OutOfMemory)
    }
    unit : iommu_unit.Iommu
    info : iommu_interface.IommuInfo
    match iommu_unit.identify(&unit, kind, cast[iommu_interface.VirtualAddress](mapped), size) {
        case Ok(found) => info = found
        case Error(error) => {
            unmap_device(kernel, mapped, size)
            return .Error(.NoIommu)
        }
    }
    lock_at(&kernel.iommus_lock, .Iommus)
    index :: kernel.iommu_count
    // Another registration of it, since find_iommu looked
    again :: find_iommu(kernel, kind, physical)
    full :: (again is_none) && cast[usize](index) >= MAX_IOMMUS
    if (again is_none) && cast[usize](index) < MAX_IOMMUS {
        kernel.iommus[cast[usize](index)] = RegisteredIommu.{unit = unit, kind = kind, info = info, registers = mapped, physical = physical, size = size}
        intrinsics.atomic_store_u32_release(&kernel.iommu_count, index + 1)
    }
    unlock_at(&kernel.iommus_lock, .Iommus)
    if (again is_some) || full {
        unmap_device(kernel, mapped, size)
        return if full { .Error(.TooManyIommus) } else { .Ok(again or_else 0) }
    }
    runtime.log_info("IOMMU %: %, % KiB of registers at %{#018x}, version %.%, %-bit I/O addresses", index, kind_name(kind), size / 1024,
        physical, info.major, info.minor, info.address_bits)
    start_translation(kernel, index)
    return .Ok(index)
}

/**
 * Name a kind of IOMMU, for the log.
 *
 * @param kind The kind; any not VT-d, AMD-Vi or SMMUv3 is named as RISC-V's.
 * @return Its name, a string literal: "VT-d", "AMD-Vi", "SMMUv3" or "RISC-V IOMMU".
 */
kind_name :: fn(kind: iommu_interface.IommuKind) -> string {
    if kind == .VtD {
        return "VT-d"
    }
    if kind == .AmdVi {
        return "AMD-Vi"
    }
    return if kind == .Smmuv3 { "SMMUv3" } else { "RISC-V IOMMU" }
}

/**
 * Find the IOMMU interface's kind for a kind a system call names.
 *
 * @param kind A slop_os.IommuKind, as a call's raw value.
 * @return The interface's kind, or null for a value that's no kind; whether the kernel can drive it is found when
 *     it's identified.
 */
iommu_kind :: fn(kind: u32) -> iommu_interface.IommuKind? {
    if kind == cast[u32](slop_os.IommuKind.VtD) {
        return iommu_interface.IommuKind.VtD
    }
    if kind == cast[u32](slop_os.IommuKind.AmdVi) {
        return iommu_interface.IommuKind.AmdVi
    }
    if kind == cast[u32](slop_os.IommuKind.Smmuv3) {
        return iommu_interface.IommuKind.Smmuv3
    }
    if kind == cast[u32](slop_os.IommuKind.RiscV) {
        return iommu_interface.IommuKind.RiscV
    }
    return null
}

/**
 * Find the IOMMU a device is behind: of the scopes registered, the one that covers its requester ID most narrowly.
 * Takes iommus_lock.
 *
 * @param kernel The kernel, whose iommu_scopes are read under iommus_lock, so the caller holds no lock of rank
 *     Iommus or above.
 * @param address The device's address (slop_os.device_address), its segment in the upper 16 bits.
 * @return The IOMMU's number plus one and the device's stream there, or a path with iommu 0 if no scope covers it.
 */
iommu_path :: fn(kernel: ptr[mut Kernel], address: u32) -> IommuPath {
    path := IommuPath.{}
    narrowest := cast[u32](0)
    lock_at(&kernel.iommus_lock, .Iommus)
    for i in 0..<cast[usize](kernel.iommu_scope_count) {
        scope :: &kernel.iommu_scopes[i % MAX_IOMMU_SCOPES]
        if address >> 16 == scope.first >> 16 && address >= scope.first && address - scope.first < scope.count
            && (path.iommu == 0 || scope.count < narrowest) {
            path = IommuPath.{iommu = scope.iommu + 1, stream = scope.stream + (address - scope.first)}
            narrowest = scope.count
        }
    }
    unlock_at(&kernel.iommus_lock, .Iommus)
    return path
}
