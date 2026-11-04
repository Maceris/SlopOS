/**
 * What the kernel tells the root task of the emulator's test device, with test_device on its command line
 * (decisions/0069): a page, granted as "test_device", which the root task passes to test_devices. It's what
 * the firmware tables would say until the platform service reads them (M7), and an address of RAM the kernel
 * owns, which device memory and controllers mustn't be at. With test_device, the kernel runs the device
 * while an IRQ for its line exists.
 */
package test_device

/** The page the kernel grants the root task as "test_device", laid out as the kernel writes it. */
TestDeviceInfo :: struct {
    /** The device's interrupt controller, as a slop_os.ControllerKind's value. */
    kind : u32,
    /** The device's interrupt line on that controller. */
    line : u32,
    /**
     * The line's IRQ_* flags, as an IRQ for it is made with: IRQ_LEVEL if it's level-triggered, IRQ_ACTIVE_LOW if
     * it's active low, or 0 for an edge-triggered, active-high line.
     */
    flags : u32,
    /** Unused; it aligns registers to 8 bytes. */
    reserved : u32,
    /** The physical address of the controller's registers. */
    registers : u64,
    /**
     * The physical address of a page of RAM the kernel owns (this page's own frame), which device memory and
     * controllers mustn't be at, so a test can check the kernel refuses them there.
     */
    kernel_ram : u64,
}
