/*
 * What the kernel tells the root task of the emulator's test device, with test_device on its command line
 * (decisions/0069): a page, granted as "test_device", which the root task passes to test_devices. It's what
 * the firmware tables would say until the platform service reads them (M7), and an address of RAM the kernel
 * owns, which device memory and controllers mustn't be at. With test_device, the kernel runs the device
 * while an IRQ for its line exists.
 */
package test_device

TestDeviceInfo :: struct {
    // Its interrupt controller's slop_os.ControllerKind, the device's line on it, and its IRQ_* flags
    kind : u32,
    line : u32,
    flags : u32,
    reserved : u32,
    // The controller's registers, and RAM the kernel owns
    registers : u64,
    kernel_ram : u64,
}
