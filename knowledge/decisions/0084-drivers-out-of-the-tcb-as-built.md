# 0084: Drivers out of the TCB as Built

Status: accepted
Date: 2026-10-25
Related: `0039` (without an IOMMU, only trusted drivers get DMA), `0079` (the plan for D), `0077` (the supervisor's
restarts), `0081` to `0083` (D's other stages), `../../docs/specs/system_calls.md`, `../roadmap.md` D and M8

## Context
D's last stage (De, `0079`): with an IOMMU, no device has DMA outside its domain (Db, Dd), and none raises another's
interrupts (Dc); without one, only drivers `system_config` marks as trusted get DMA memory (`0039`); and a test
driver of QEMU's `edu` that DMAs outside its domain is stopped and reported, by a signal on its Device that the
supervisor acts on, restarting it within its restart limit (`0077`). Left to this stage: who enforces trust without
an IOMMU, how the supervisor learns of a fault, and how the test driver is started.

## Decision
Built:
- **Trust, enforced by the kernel**: `dma_domain_create` takes flags, and a domain made with `DMA_DOMAIN_TRUSTED` may
  have DMA memory where no IOMMU translates it; any other domain's `dma_memory_create` there fails with `Untrusted`
  (45). Behind a translating IOMMU every domain has DMA memory, confined to it. ABI 6.
- **Trust, decided by `system_config`**: each driver says whether it's `trusted_with_dma`. SlopOS's virtio drivers are;
  `edu_dma` isn't. The supervisor's `Claim` carries it (the platform protocol's `Wanted`, version 2), and the platform
  service makes the device's domain trusted only if it was, for the claim and every reissue of it.
- **The fault signal**: a Device raises `SIGNAL_DMA_FAULT` each time an IOMMU blocks its DMA, with the device address
  in the packet; the kernel finds the Device from the fault's IOMMU and stream. Devices take port bindings as
  processes do, two each.
- **The supervisor** keeps a handle to each driver's Device, duplicated before the bundle goes to the driver, bound
  for `SIGNAL_DMA_FAULT`; on a fault it logs it and kills the driver, which then ends as a killed driver does and is
  started again with its device reissued, up to its restart limit. The handle goes stale with the device, and is
  closed and unbound when the driver ends.
- **`edu_dma`** (`src/drivers/edu_dma`): makes a page of DMA memory, saying so and ending with 0 if it's refused; then
  has edu write a page 64 MiB past it, outside its domain, and waits to be stopped. With `test_dma_fault`, the
  supervisor reports everything started only once it has ended for good.
- **Found on the way, fixed**: a restarted driver's end bound the same key as the last process's, which a Once binding
  keeps after it fires, so the second end of a driver never reached the supervisor; it unbinds the key first.
- **Tests**: on both architectures, edu's write is blocked (VT-d reason 5, SMMUv3 `F_TRANSLATION`), and the driver is
  killed, started again three times, and given up, with nothing left over; and with `--no-iommu`, `edu_dma` gets no
  DMA memory. The root task has 25 grants, with `edu_dma`'s module.

## Alternatives considered
- **The platform service withholding the domain**: it would have to know whether an IOMMU translates, which the kernel
  knows; and a driver with a domain it can't use would fail in more ways than one refusal.
- **A right on the domain handle** for DMA without an IOMMU: the same, but a right is lost or kept with every
  duplicate, where a flag is the domain's.
- **The kernel killing the driver** on a fault: policy in the kernel, which the supervisor has (`0079`).
- **The driver told of its own fault**: a driver that DMAs outside its domain can't be trusted to act on it.

## Consequences
- D is done: no driver is in the trusted computing base where an IOMMU confines its device, and M8's storage stack
  starts on drivers that can only reach their own domains.
- A driver whose device keeps faulting is restarted until it's ended too often, as a crashing one is.
- A driver `system_config` trusts runs with DMA everywhere on a machine without an IOMMU; one it doesn't trust can't
  do DMA there at all.
