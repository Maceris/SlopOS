package bootloader

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
        // Whether the CPU maps 1 GiB pages
        gigabyte_pages : bool,
    }

    new_tables :: fn() -> PageTables? {
        root :: allocate_pages(LOADER_DATA, 4096) or_return null
        // CPUID 0x80000001's EDX bit 26: 1 GiB pages
        return PageTables.{root = root, gigabyte_pages = (x86_64.cpuid(0x80000001).edx >> 26) & 1 != 0}
    }

    // The table an entry of table at index points to, made if it points to none; null without memory, or over a large page.
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

    // size bytes at virtual mapped to physical, writable and executable, in the largest pages that fit: whether they were.
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
    // AArch64's tables come with its part of B2; until then the bootloader stops there
    GIGABYTE : u64 : 1 << 30
    HIGHER_HALF : u64 : 0xffff800000000000

    PageTables :: struct {
        root : u64,
    }

    new_tables :: fn() -> PageTables? {
        return null
    }

    map :: fn(tables: ptr[PageTables], virtual: u64, physical: u64, size: u64) -> bool {
        return false
    }
}
