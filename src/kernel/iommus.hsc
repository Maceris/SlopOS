package kernel

import intrinsics from "base"
import runtime from "base"
import iommu_interface from "../iommu_interface"
import boot_info from "../boot_info"
import concurrency from "std"
import slop_os from "std/os"

#if TARGET_ARCH == .x86_64 {
    import iommu_vtd from "../iommu/vtd"
}
#else_if TARGET_ARCH == .arm64 {
    import iommu_smmuv3 from "../iommu/smmuv3"
}

/*
 * IOMMUs (roadmap D, decisions/0039, 0079): the platform service registers each one it finds in the firmware tables,
 * with the requester IDs it covers, and the kernel maps its registers and identifies it through its implementation
 * (iommu_interface; VT-d on x86-64, SMMUv3 on AArch64). A device is attached through the IOMMU that covers its
 * requester ID most narrowly, as VT-d's DMAR has a unit for all of a segment's devices besides those another covers,
 * and a domain's devices are all behind one IOMMU, or all behind none.
 *
 * Registering an IOMMU changes nothing it does yet: translation comes with each implementation's stage (Db, Dd).
 *
 * Lock order: a device's lock, then iommus_lock.
 */

MAX_IOMMUS :: 8
// The ranges of requester IDs every IOMMU covers, together
MAX_IOMMU_SCOPES :: 32
// The most bytes of registers an IOMMU may have: SMMUv3's are 128 KiB
MAX_IOMMU_REGISTERS : u64 : 1 << 20

#if TARGET_ARCH == .x86_64 {
    IommuUnit :: iommu_vtd.Iommu
}
#else_if TARGET_ARCH == .arm64 {
    IommuUnit :: iommu_smmuv3.Iommu
}

RegisteredIommu :: struct {
    unit : IommuUnit,
    kind : iommu_interface.IommuKind,
    info : iommu_interface.IommuInfo,
    // In the kernel window, and where they are.
    registers : u64,
    physical : u64,
    size : u64,
}

// count requester IDs from first (slop_os.device_address), behind the IOMMU with number iommu, as streams from stream.
IommuScope :: struct {
    iommu : u32,
    first : u32,
    count : u32,
    stream : u32,
}

// Which IOMMU a device is behind: its number plus one, 0 for none, and the stream it's there.
IommuPath :: struct {
    iommu : u32,
    stream : u32,
}

/*
 * The IOMMU of kind whose registers, size bytes of them, are at physical, covering count requester IDs from first, as
 * streams from stream: its number. One registered already, of the same kind at the same place, is the same, and
 * covers those too.
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
    concurrency.lock(&kernel.iommus_lock)
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
    concurrency.unlock(&kernel.iommus_lock)
    if full {
        return .Error(.TooManyIommus)
    }
    return .Ok(index)
}

// The number of the IOMMU of kind at physical, if it's registered.
find_iommu :: fn(kernel: ptr[mut Kernel], kind: iommu_interface.IommuKind, physical: u64) -> u32? {
    for index in 0..<cast[usize](intrinsics.atomic_load_u32_acquire(&kernel.iommu_count)) {
        if index < MAX_IOMMUS && kernel.iommus[index].physical == physical && kernel.iommus[index].kind == kind {
            return cast[u32](index)
        }
    }
    return null
}

// A new IOMMU: its registers mapped, and identified by its implementation.
add_iommu :: fn(kernel: ptr[mut Kernel], kind: iommu_interface.IommuKind, physical: u64, size: u64) -> Result[u32, slop_os.DeviceError] {
    mapped := cast[u64](0)
    match map_device(kernel, cast[boot_info.PhysicalAddress](physical), size) {
        case Ok(address) => mapped = address
        case Error(error) => return .Error(.OutOfMemory)
    }
    unit : IommuUnit
    info : iommu_interface.IommuInfo
    match identify_iommu(&unit, kind, cast[iommu_interface.VirtualAddress](mapped), size) {
        case Ok(found) => info = found
        case Error(error) => {
            unmap_device(kernel, mapped, size)
            return .Error(.NoIommu)
        }
    }
    concurrency.lock(&kernel.iommus_lock)
    index :: kernel.iommu_count
    // Another registration of it, since find_iommu looked
    again :: find_iommu(kernel, kind, physical)
    full :: (again is_none) && cast[usize](index) >= MAX_IOMMUS
    if (again is_none) && cast[usize](index) < MAX_IOMMUS {
        kernel.iommus[cast[usize](index)] = RegisteredIommu.{unit = unit, kind = kind, info = info, registers = mapped, physical = physical, size = size}
        intrinsics.atomic_store_u32_release(&kernel.iommu_count, index + 1)
    }
    concurrency.unlock(&kernel.iommus_lock)
    if (again is_some) || full {
        unmap_device(kernel, mapped, size)
        return if full { .Error(.TooManyIommus) } else { .Ok(again or_else 0) }
    }
    runtime.log_info("IOMMU %: %, % KiB of registers at %, version %.%, %-bit I/O addresses", index, kind_name(kind), size / 1024,
        cast[rawptr](physical), info.major, info.minor, info.address_bits)
    return .Ok(index)
}

identify_iommu :: fn(unit: ptr[mut IommuUnit], kind: iommu_interface.IommuKind, registers: iommu_interface.VirtualAddress, size: u64)
    -> Result[iommu_interface.IommuInfo, iommu_interface.IommuError] {
    #if TARGET_ARCH == .x86_64 {
        return iommu_vtd.identify(unit, kind, registers, size)
    }
    #else {
        return iommu_smmuv3.identify(unit, kind, registers, size)
    }
}

kind_name :: fn(kind: iommu_interface.IommuKind) -> string {
    if kind == .VtD {
        return "VT-d"
    }
    if kind == .AmdVi {
        return "AMD-Vi"
    }
    return if kind == .Smmuv3 { "SMMUv3" } else { "RISC-V IOMMU" }
}

// The interface's kind for the system ABI's, if it's one.
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

// The IOMMU a device at address (slop_os.device_address) is behind: the one that covers it most narrowly.
iommu_path :: fn(kernel: ptr[mut Kernel], address: u32) -> IommuPath {
    path := IommuPath.{}
    narrowest := cast[u32](0)
    concurrency.lock(&kernel.iommus_lock)
    for i in 0..<cast[usize](kernel.iommu_scope_count) {
        scope :: &kernel.iommu_scopes[i % MAX_IOMMU_SCOPES]
        if address >> 16 == scope.first >> 16 && address >= scope.first && address - scope.first < scope.count
            && (path.iommu == 0 || scope.count < narrowest) {
            path = IommuPath.{iommu = scope.iommu + 1, stream = scope.stream + (address - scope.first)}
            narrowest = scope.count
        }
    }
    concurrency.unlock(&kernel.iommus_lock)
    return path
}
