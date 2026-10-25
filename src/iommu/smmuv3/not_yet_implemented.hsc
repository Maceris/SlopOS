package iommu_smmuv3

import iommu_interface from "../../iommu_interface"

/*
 * What iommu_interface declares that SMMUv3 doesn't implement yet: its translation, roadmap Dd (decisions/0005,
 * 0079). The kernel turns translation on only when enable succeeds, which it doesn't here, so it reaches none of the
 * others; they're stubs to compile. The interface's house rule (src/checks) accepts stubs in this file only if they're
 * listed, and fails once one of them is implemented anywhere else, so the list stays true.
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
]

enable :: fn(iommu: ptr[mut Iommu], memory: iommu_interface.PhysicalAddress, direct_map_offset: u64) -> Result[void, iommu_interface.IommuError] {
    return .Error(.Unsupported)
}

route_faults :: fn(iommu: ptr[mut Iommu], message: iommu_interface.FaultMessage) {
}

init_domain :: fn(iommu: ptr[Iommu], domain: ptr[mut Domain], id: u32, root: iommu_interface.PhysicalAddress) {
}

attach :: fn(iommu: ptr[mut Iommu], domain: ptr[Domain], stream: u32, frames: ptr[mut iommu_interface.TableFrames])
    -> Result[void, iommu_interface.MapError] {
    return .Error(.InvalidAddress)
}

detach :: fn(iommu: ptr[mut Iommu], domain: ptr[Domain], stream: u32) {
}

map :: fn(iommu: ptr[Iommu], domain: ptr[mut Domain], address: u64, physical: iommu_interface.PhysicalAddress, writable: bool,
    frames: ptr[mut iommu_interface.TableFrames]) -> Result[void, iommu_interface.MapError] {
    return .Error(.InvalidAddress)
}

unmap :: fn(iommu: ptr[Iommu], domain: ptr[mut Domain], address: u64) {
}

invalidate :: fn(iommu: ptr[mut Iommu], domain: ptr[Domain], mapped: bool) {
}

release_domain :: fn(iommu: ptr[Iommu], domain: ptr[mut Domain], freed: ptr[mut iommu_interface.FreedFrames]) -> bool {
    return true
}

next_fault :: fn(iommu: ptr[mut Iommu]) -> iommu_interface.DmaFault? {
    return null
}
