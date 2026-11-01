/* Places the kernel for SlopOS's bootloader on AArch64 (decisions/0133): code, read-only data and data, in the higher half, as a PIE the bootloader relocates. */
OUTPUT_FORMAT(elf64-littleaarch64)
ENTRY(kernel_entry)

PHDRS
{
    text PT_LOAD;
    rodata PT_LOAD;
    data PT_LOAD;
    dynamic PT_DYNAMIC;
}

SECTIONS
{
    . = 0xffffffff80000000;

    . = ALIGN(CONSTANT(MAXPAGESIZE));
    .text : { *(.text .text.*) } :text

    . = ALIGN(CONSTANT(MAXPAGESIZE));
    .rodata : { *(.rodata .rodata.*) } :rodata

    . = ALIGN(CONSTANT(MAXPAGESIZE));
    .data : { *(.data .data.*) } :data
    .bss : { *(.bss .bss.*) *(COMMON) } :data

    .dynamic : { *(.dynamic) } :data :dynamic
    /DISCARD/ : { *(.eh_frame*) *(.note .note.*) }
}
