# 0129: Pb, Large Pages for Anonymous Memory, as Built

Status: accepted
Date: 2026-10-31
Related: `0127` (Perf's stages), `0048` (paging, the direct map), `0054` (memory objects), `0111` (paged memory)

## Context
`0127`: anonymous memory objects of 2 MiB or more get 2 MiB pages where they line up, their frames as 2 MiB blocks
where the frame allocator has them; paged objects stay 4 KiB. The direct map already had large pages.

## Decision
- **Where**: a fault on anonymous memory (not paged, a window, device or DMA memory) of 2 MiB or more maps a 2 MiB
  page when the 2 MiB of the object around the page is whole, at a 2 MiB-aligned address the mapping holds all of. A
  memory object's page array has a leaf per 512 pages, so that 2 MiB is one leaf.
- **Frames**: a leaf that holds nothing yet gets a 2 MiB block (`frames.allocate_frames`, order 9), zeroed, each of
  its frames allocated on its own, so the memory's release gives them back one at a time as any frames, and the
  block merges again once they all are. Each page of the leaf is claimed with a compare-exchange; if a fault on the
  same memory gave one of them a frame first, the block's other frames go back and the fault maps a 4 KiB page. A
  leaf filled already maps with a large page only if it's one aligned block, as another mapping's fault left it.
- **Mapping and unmapping**: the large page is mapped under the space's lock; if any page of it is mapped already, as
  a fault on another of its pages may have done, it maps a 4 KiB page instead. Unmapping a range that holds a large
  page unmaps it whole, which it can, as a large page is only ever made inside one mapping.
- **Tests**: `test_memory` makes two objects of 4 MiB, maps one on a 2 MiB boundary and one a page past one, touches
  every page of each, and checks the first took at least two page tables of 4 KiB pages fewer than the second (it
  takes none). The full suite and the Perf baselines as before.

## Alternatives considered
- **Contiguous frames for every object of 2 MiB at once**, at its creation: memory is filled only as it's touched
  (`0054`), and a 2 MiB object touched once would hold all of it.

## Consequences
- A large anonymous mapping costs one TLB entry per 2 MiB and no last-level tables; a program's heap, made of smaller
  objects, gains nothing until its objects grow to 2 MiB.
