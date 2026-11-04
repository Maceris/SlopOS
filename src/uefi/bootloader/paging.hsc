package bootloader

import uefi from "std/os"

#if TARGET_ARCH == .x86_64 {
    import x86_64 from "base/intrinsics"
}

/*
 * The page tables the kernel starts on (src/boot_protocol): x86-64's 4-level tables, in the bootloader's own pages
 * (boot-reclaimable, as the kernel's own replace them), the largest pages each range's alignment allows. Ranges are
 * mapped once each and don't overlap, so a large page never covers part of another range.
 */
#if TARGET_ARCH == .x86_64 {
    /** A page table entry's present bit, bit 0 (Intel SDM, volume 3, 4-level paging). */
    PRESENT : u64 : 1
    /** A page table entry's read/write bit, bit 1: writes are allowed through it. */
    WRITABLE : u64 : 2
    /** A page table entry's page size bit, bit 7: a 1 GiB page in a PDPT, a 2 MiB page in a page directory. */
    LARGE : u64 : 1 << 7
    /** The bits of an entry that hold the physical address of the table or page it points to, 4096-aligned. */
    ADDRESS_MASK : u64 : 0x000ffffffffff000
    /** 1 GiB in bytes, the size of a page a PDPT entry maps. */
    GIGABYTE : u64 : 1 << 30
    /** 2 MiB in bytes, the size of a page a page directory entry maps. */
    TWO_MEGABYTES : u64 : 1 << 21

    /** The page tables the kernel starts on: their root, and what the CPU allows them. */
    PageTables :: struct {
        /** The PML4's physical address, 4096-aligned and below 4 GiB, which CR3 is loaded with. */
        root : u64,
        /** Whether the CPU maps 1 GiB pages (CPUID 0x80000001, EDX bit 26), so map may use them. */
        gigabyte_pages : bool,
    }

    /**
     * Make empty page tables, their root below 4 GiB, where the other CPUs' trampoline loads it from real mode
     * (cpus.hsc).
     *
     * Boot services have to be running. The root is loader data, which the kernel can reclaim once it has its own.
     *
     * @return The tables, the root zeroed; null if boot services are gone or no page below 4 GiB can be had.
     */
    new_tables :: fn() -> PageTables? {
        services :: uefi.boot_services() or_return null
        root : u64 = 0xfffff000
        if services.allocate_pages(cast[u32](uefi.AllocateKind.MaxAddress), LOADER_DATA, 1, &root) != uefi.SUCCESS {
            return null
        }
        zero(root, 4096)
        // CPUID 0x80000001's EDX bit 26: 1 GiB pages
        return PageTables.{root = root, gigabyte_pages = (x86_64.cpuid(0x80000001).edx >> 26) & 1 != 0}
    }

    /**
     * Find the table an entry of a table points to, making it if it points to none.
     *
     * A table made is a zeroed loader-data page, and the entry is made present and writable.
     *
     * @param table The table's physical address, identity-mapped.
     * @param index The entry's index, 0 to 511.
     * @return The next table's physical address, 4096-aligned; null if no page can be had, or the entry maps a large
     *     page, which isn't split.
     */
    next_table :: fn(table: u64, index: u64) -> u64? {
        entry :: cast[ptr[mut u64]](cast[rawptr](table + index * 8))
        if entry^ & PRESENT != 0 {
            if entry^ & LARGE != 0 {
                return null
            }
            return entry^ & ADDRESS_MASK
        }
        made :: allocate_pages(LOADER_DATA, 4096) or_return null
        entry^ = made | PRESENT | WRITABLE
        return made
    }

    /**
     * Map a range at a virtual address to physical memory, writable and executable, in the largest pages that fit.
     *
     * Pages are supervisor-only and cached as the CPU's default memory type says (no PAT, PCD or PWT bits). An entry
     * already there is written over; ranges mapped shouldn't overlap, or a large page could land over part of one.
     *
     * @param tables The page tables, which grow as tables are needed.
     * @param virtual The range's virtual address, canonical and 4096-aligned.
     * @param physical The memory's physical address, 4096-aligned.
     * @param size The range's size in bytes; a part of a page past a multiple of 4096 maps the whole page.
     * @return True if the whole range was mapped; false if a table couldn't be had, or the range runs into a large page
     *     already mapped, leaving what was mapped before it.
     */
    map :: fn(tables: ptr[PageTables], virtual: u64, physical: u64, size: u64) -> bool {
        done := cast[u64](0)
        loop {
            if done >= size {
                break
            }
            at :: virtual + done
            to :: physical + done
            left :: size - done
            third :: next_table(tables.root, (at >> 39) & 511) or_return false
            if tables.gigabyte_pages && at & (GIGABYTE - 1) == 0 && to & (GIGABYTE - 1) == 0 && left >= GIGABYTE {
                cast[ptr[mut u64]](cast[rawptr](third + ((at >> 30) & 511) * 8))^ = to | PRESENT | WRITABLE | LARGE
                done += GIGABYTE
                continue
            }
            second :: next_table(third, (at >> 30) & 511) or_return false
            if at & (TWO_MEGABYTES - 1) == 0 && to & (TWO_MEGABYTES - 1) == 0 && left >= TWO_MEGABYTES {
                cast[ptr[mut u64]](cast[rawptr](second + ((at >> 21) & 511) * 8))^ = to | PRESENT | WRITABLE | LARGE
                done += TWO_MEGABYTES
                continue
            }
            first :: next_table(second, (at >> 21) & 511) or_return false
            cast[ptr[mut u64]](cast[rawptr](first + ((at >> 12) & 511) * 8))^ = to | PRESENT | WRITABLE
            done += 4096
        }
        return true
    }

    // The bottom of the higher half, where the direct map may start, and the kernel's lowest link address
    /** The bottom of the higher half, the lowest canonical address with bit 47 set, where the direct map may start. */
    HIGHER_HALF : u64 : 0xffff800000000000
    /** The kernel's lowest link address, the top 2 GiB, before the slide. */
    KERNEL_LINK_BASE : u64 : 0xffffffff80000000
}
#else {
    import aarch64 from "base/intrinsics"

    /*
     * AArch64's: 4 KiB granules, 48-bit halves, TTBR1's root for the kernel half (the kernel image and the direct map)
     * and TTBR0's for the identity map, every page normal write-back memory (MAIR_EL1's index 0), inner shareable.
     * Devices' registers aren't mapped: the kernel maps those it needs itself, in the gaps (arch/aarch64,
     * map_early_device).
     */

    /** A descriptor's valid bit, bit 0 (Arm Architecture Reference Manual, VMSAv8-64 translation table format). */
    VALID : u64 : 1
    /** Bit 1: a table descriptor at levels 0 to 2, or a page descriptor at level 3; clear, with VALID, a block. */
    TABLE : u64 : 2
    /**
     * A block's or page's lower attributes: AttrIndx 0 (MAIR_EL1's index 0), AP 0 for EL1 read and write and no EL0
     * access, SH 3 for inner shareable, and AF set, so no access flag fault is taken.
     */
    ATTRIBUTES : u64 : (3 << 8) | (1 << 10)
    /** The bits of a descriptor that hold the physical address of the table, block or page it points to. */
    ADDRESS_MASK : u64 : 0x0000fffffffff000
    /** 1 GiB in bytes, the size of a level 1 block. */
    GIGABYTE : u64 : 1 << 30
    /** 2 MiB in bytes, the size of a level 2 block. */
    TWO_MEGABYTES : u64 : 1 << 21
    /** The bottom of the higher half, TTBR1's, where the direct map may start: with T1SZ 16, bits 63 to 48 set. */
    HIGHER_HALF : u64 : 0xffff800000000000
    /** MAIR_EL1's index 0, normal memory, write-back, as the kernel takes it (arch/aarch64/paging.hsc). */
    MAIR_VALUE : u64 : 0xff

    /** The page tables the kernel starts on: TTBR1's root for the higher half, and TTBR0's for the lower. */
    PageTables :: struct {
        // TTBR1's, and TTBR0's
        /** TTBR1_EL1's level 0 table's physical address, 4096-aligned: the kernel image and the direct map. */
        root : u64,
        /** TTBR0_EL1's level 0 table's physical address, 4096-aligned: the identity map. */
        low_root : u64,
    }

    /**
     * Make empty page tables, both roots zeroed loader-data pages, anywhere in memory.
     *
     * @return The tables; null if boot services are gone or a page can't be had, the first root then not freed.
     */
    new_tables :: fn() -> PageTables? {
        root :: allocate_pages(LOADER_DATA, 4096) or_return null
        low_root :: allocate_pages(LOADER_DATA, 4096) or_return null
        return PageTables.{root = root, low_root = low_root}
    }

    /**
     * Find the table an entry of a table points to, making it if it points to none.
     *
     * A table made is a zeroed loader-data page, and the entry a valid table descriptor.
     *
     * @param table The table's physical address, identity-mapped.
     * @param index The entry's index, 0 to 511.
     * @return The next table's physical address, 4096-aligned; null if no page can be had, or the entry is a block,
     *     which isn't split.
     */
    next_table :: fn(table: u64, index: u64) -> u64? {
        entry :: cast[ptr[mut u64]](cast[rawptr](table + index * 8))
        if entry^ & VALID != 0 {
            if entry^ & TABLE == 0 {
                return null
            }
            return entry^ & ADDRESS_MASK
        }
        made :: allocate_pages(LOADER_DATA, 4096) or_return null
        entry^ = made | VALID | TABLE
        return made
    }

    /**
     * Map a range at a virtual address to physical memory in the largest blocks or pages that fit, as normal
     * write-back memory, EL1 read, write and execute, not EL0's.
     *
     * An address in the higher half goes in root's tables, any other in low_root's. An entry already there is written
     * over; ranges mapped shouldn't overlap, or a block could land over part of one.
     *
     * @param tables The page tables, which grow as tables are needed.
     * @param virtual The range's virtual address, 4096-aligned, below 2 to the 48th or at least HIGHER_HALF.
     * @param physical The memory's physical address, 4096-aligned.
     * @param size The range's size in bytes; a part of a page past a multiple of 4096 maps the whole page.
     * @return True if the whole range was mapped; false if a table couldn't be had, or the range runs into a block
     *     already mapped, leaving what was mapped before it.
     */
    map :: fn(tables: ptr[PageTables], virtual: u64, physical: u64, size: u64) -> bool {
        root :: if virtual >= HIGHER_HALF { tables.root } else { tables.low_root }
        done := cast[u64](0)
        loop {
            if done >= size {
                break
            }
            at :: virtual + done
            to :: physical + done
            left :: size - done
            first :: next_table(root, (at >> 39) & 511) or_return false
            if at & (GIGABYTE - 1) == 0 && to & (GIGABYTE - 1) == 0 && left >= GIGABYTE {
                cast[ptr[mut u64]](cast[rawptr](first + ((at >> 30) & 511) * 8))^ = to | ATTRIBUTES | VALID
                done += GIGABYTE
                continue
            }
            second :: next_table(first, (at >> 30) & 511) or_return false
            if at & (TWO_MEGABYTES - 1) == 0 && to & (TWO_MEGABYTES - 1) == 0 && left >= TWO_MEGABYTES {
                cast[ptr[mut u64]](cast[rawptr](second + ((at >> 21) & 511) * 8))^ = to | ATTRIBUTES | VALID
                done += TWO_MEGABYTES
                continue
            }
            third :: next_table(second, (at >> 21) & 511) or_return false
            cast[ptr[mut u64]](cast[rawptr](third + ((at >> 12) & 511) * 8))^ = to | ATTRIBUTES | VALID | TABLE
            done += 4096
        }
        return true
    }

    /**
     * Compute TCR_EL1's value: 48-bit halves (T0SZ and T1SZ 16), 4 KiB granules, walks write-back and inner shareable,
     * and the CPU's physical address size, up to 48 bits.
     *
     * @return The value for TCR_EL1, its IPS field ID_AA64MMFR0_EL1's PARange capped at 5, 48 bits; ASIDs 8 bits and
     *     taken from TTBR0, top-byte-ignore off.
     */
    tcr_value :: fn() -> u64 {
        range := aarch64.read_system_register(.ID_AA64MMFR0_EL1) & 0xf
        range = if range > 5 { cast[u64](5) } else { range }
        return 16 | (1 << 8) | (1 << 10) | (3 << 12) | (16 << 16) | (1 << 24) | (1 << 26) | (3 << 28) | (2 << 30) | (range << 32)
    }
}
