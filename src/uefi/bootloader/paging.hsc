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
    PRESENT : u64 : 1
    WRITABLE : u64 : 2
    LARGE : u64 : 1 << 7
    ADDRESS_MASK : u64 : 0x000ffffffffff000
    GIGABYTE : u64 : 1 << 30
    TWO_MEGABYTES : u64 : 1 << 21

    PageTables :: struct {
        root : u64,
        /** Whether the CPU maps 1 GiB pages */
        gigabyte_pages : bool,
    }

    /** The root below 4 GiB, where the other CPUs' trampoline loads it from real mode (cpus.hsc) */
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
     * The table an entry of table at index points to, made if it points to none; null without memory, or over a large page.
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
     * size bytes at virtual mapped to physical, writable and executable, in the largest pages that fit: whether they were.
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
    HIGHER_HALF : u64 : 0xffff800000000000
    KERNEL_LINK_BASE : u64 : 0xffffffff80000000
}
#else {
    import aarch64 from "base/intrinsics"

    /**
     * AArch64's: 4 KiB granules, 48-bit halves, TTBR1's root for the kernel half (the kernel image and the direct map) and
     * TTBR0's for the identity map, every page normal write-back memory (MAIR_EL1's index 0), inner shareable. Devices'
     * registers aren't mapped: the kernel maps those it needs itself, in the gaps (arch/aarch64, map_early_device).
     */
    VALID : u64 : 1
    /** A table descriptor, or a page at level 3 */
    TABLE : u64 : 2
    // AttrIndx 0, EL1 read and write, inner shareable, accessed
    ATTRIBUTES : u64 : (3 << 8) | (1 << 10)
    ADDRESS_MASK : u64 : 0x0000fffffffff000
    GIGABYTE : u64 : 1 << 30
    TWO_MEGABYTES : u64 : 1 << 21
    HIGHER_HALF : u64 : 0xffff800000000000
    /** MAIR_EL1's index 0, normal memory, write-back, as the kernel takes it (arch/aarch64/paging.hsc) */
    MAIR_VALUE : u64 : 0xff

    PageTables :: struct {
        // TTBR1's, and TTBR0's
        root : u64,
        low_root : u64,
    }

    new_tables :: fn() -> PageTables? {
        root :: allocate_pages(LOADER_DATA, 4096) or_return null
        low_root :: allocate_pages(LOADER_DATA, 4096) or_return null
        return PageTables.{root = root, low_root = low_root}
    }

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
     * TCR_EL1: 48-bit halves (T0SZ and T1SZ 16), 4 KiB granules, walks write-back and inner shareable, and the CPU's
     * physical address size, up to 48 bits.
     */
    tcr_value :: fn() -> u64 {
        range := aarch64.read_system_register(.ID_AA64MMFR0_EL1) & 0xf
        range = if range > 5 { cast[u64](5) } else { range }
        return 16 | (1 << 8) | (1 << 10) | (3 << 12) | (16 << 16) | (1 << 24) | (1 << 26) | (3 << 28) | (2 << 30) | (range << 32)
    }
}
