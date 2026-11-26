/* Places the kernel for SlopOS's bootloader on RISC-V (decisions/0133, 0199): code, read-only data and data, small data with them, in the higher half, as a PIE the bootloader relocates. */
OUTPUT_FORMAT(elf64-littleriscv)
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
    .rodata : { *(.rodata .rodata.* .srodata .srodata.*) } :rodata

    . = ALIGN(CONSTANT(MAXPAGESIZE));
    .data : { *(.data .data.* .sdata .sdata.*) } :data
    .bss : { *(.sbss .sbss.* .bss .bss.*) *(COMMON) } :data

    .dynamic : { *(.dynamic) } :data :dynamic
    /DISCARD/ : { *(.eh_frame*) *(.note .note.*) *(.riscv.attributes) }
}
