# Notes: Bitfields

Status: undecided in Hemera. Current plan: fixed-width integers + shifts/masks; C-style
unions for byte-granularity overlays. These notes record what SlopOS will need either way.

## Where SlopOS hits bit-packed data
- x86-64 page table entries (`u64`: present, writable, user, ..., physical frame in bits 12–51, NX in bit 63)
- GDT/IDT/TSS descriptors (addresses split across non-contiguous bit ranges)
- APIC registers, MSRs, `CR0`/`CR4`/`XCR0`
- PCIe configuration space, virtio feature bits
- Network headers (IPv4 version/IHL nibbles, TCP flags)

## Option A: Integers + generated accessors (works today)

Keep the language as is. Describe the layout once as data and generate accessor functions
at compile time with `#run`, so the mask/shift arithmetic is written exactly once:

```
PageTableEntry :: distinct u64

// Generated (by hand for now, by #run later):
pte_present :: fn(entry: PageTableEntry) -> bool {
    return (cast[u64](entry) & 1) != 0
}
pte_frame :: fn(entry: PageTableEntry) -> u64 {
    return (cast[u64](entry) >> 12) & 0xFF_FFFF_FFFF    // bits 12..<52
}
pte_with_frame :: fn(entry: PageTableEntry, frame: u64) -> PageTableEntry {
    cleared :: cast[u64](entry) & ~(0xFF_FFFF_FFFF << 12)
    return cast[PageTableEntry](cleared | ((frame & 0xFF_FFFF_FFFF) << 12))
}
```

`distinct u64` stops a raw integer being used as an entry by accident. The cost is
verbosity and having no field syntax.

## Option B: Bitfields with *explicit* bit positions (if added)

C bitfields are a mess because ordering, packing, alignment and straddling are
implementation-defined. The way to have **no** implementation-defined behavior is to
make the programmer state every bit position and the backing integer, including its
endianness, so the compiler decides nothing:

```
PageTableEntry :: bits[u64le] {
    present        : bool  @ 0,
    writable       : bool  @ 1,
    user           : bool  @ 2,
    write_through  : bool  @ 3,
    cache_disable  : bool  @ 4,
    accessed       : bool  @ 5,
    dirty          : bool  @ 6,
    huge           : bool  @ 7,
    global         : bool  @ 8,
    frame          : u64   @ 12..<52,   // value range-checked: must fit in 40 bits
    protection_key : u8    @ 59..<63,
    no_execute     : bool  @ 63,
}
```

Rules that would keep it fully defined:
- Size and alignment are exactly those of the backing type (`u64le` → 8 bytes, little endian).
- Bit 0 is the least significant bit of the backing integer, always.
- Overlapping ranges, or ranges outside the backing type, are compile errors.
- Unnamed bits are preserved on writes (read-modify-write of the whole integer), so
  reserved hardware bits aren't clobbered.
- Assigning a value that doesn't fit the range is a compile error if constant, otherwise a
  defined outcome (panic, or truncate — pick one).
- Field types limited to `bool`, unsigned integers, and enums with `#backed_by`.
- Reads/writes compile to exactly one load/store of the backing integer, which matters
  for MMIO registers.

Prior art: **Ada record representation clauses** (explicit bit positions, the closest match
to Hemera's goals), **Zig `packed struct`** (backed by an integer, ordering defined), Rust's
`bitfield`/`modular-bitfield` crates (macro-generated accessors, essentially Option A).

## Suggestion
Start with Option A in SlopOS. It's enough for the kernel, and real usage will show how
much the boilerplate actually hurts. That's precisely the kind of evidence this project is
meant to produce for Hemera.
