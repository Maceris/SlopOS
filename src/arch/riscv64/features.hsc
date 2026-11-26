package arch_riscv64

import slop_os from "std:os/slop_os"
import boot_info from "../../boot_info"
import devicetree from "../../devicetree"

/*
 * A RISC-V hart's features (decisions/0199): supervisor mode can't read misa or probe an extension, so they're the
 * device tree's, its first cpu node's riscv,isa-extensions, or failing that its riscv,isa string, and its mmu-type,
 * every hart being alike.
 *
 * SPEC: the Linux kernel's Documentation/devicetree/bindings/riscv/cpus.yaml and extensions.yaml, the RISC-V device
 * tree bindings (riscv,isa-extensions, riscv,isa, mmu-type); RVA23 Profiles, version 1.0.
 */

/** One extension's name, as the device tree spells it, and the feature it is. */
ExtensionName :: struct {
    /** The extension's name, in lower case, as riscv,isa-extensions lists it. */
    name : string,
    /** The feature it is. */
    feature : slop_os.CpuFeature,
}

/** Every extension detect_features looks for, by the name the device tree gives it. */
EXTENSIONS :: ExtensionName.[
    .{"m", .RiscvM},
    .{"a", .RiscvA},
    .{"f", .RiscvF},
    .{"d", .RiscvD},
    .{"c", .RiscvC},
    .{"v", .RiscvV},
    .{"zba", .RiscvZba},
    .{"zbb", .RiscvZbb},
    .{"zbs", .RiscvZbs},
    .{"zicond", .RiscvZicond},
    .{"zcb", .RiscvZcb},
    .{"zfa", .RiscvZfa},
    .{"zfhmin", .RiscvZfhmin},
    .{"zicboz", .RiscvZicboz},
    .{"zihintpause", .RiscvZihintpause},
    .{"zawrs", .RiscvZawrs},
    .{"zimop", .RiscvZimop},
    .{"zacas", .RiscvZacas},
    .{"zbc", .RiscvZbc},
    .{"zbkb", .RiscvZbkb},
    .{"zknd", .RiscvZknd},
    .{"zkne", .RiscvZkne},
    .{"zknh", .RiscvZknh},
    .{"zvbb", .RiscvZvbb},
    .{"zvbc", .RiscvZvbc},
    .{"zvkned", .RiscvZvkned},
    .{"zvknhb", .RiscvZvknhb},
    .{"zvkg", .RiscvZvkg},
    .{"zkt", .RiscvZkt},
    .{"zkr", .RiscvZkr},
    .{"zicfilp", .RiscvZicfilp},
    .{"zicfiss", .RiscvZicfiss},
    .{"svpbmt", .RiscvSvpbmt},
    .{"svnapot", .RiscvSvnapot},
    .{"svinval", .RiscvSvinval},
    .{"svadu", .RiscvSvadu},
    .{"sstc", .RiscvSstc},
    .{"sscofpmf", .RiscvSscofpmf},
    .{"ssaia", .RiscvSsaia}
]

/**
 * What SlopOS needs (decisions/0199): the parts of RVA23U64 and RVA23S64 the kernel and programs are built for, and
 * Sv48, in the order they're checked.
 */
BASELINE :: slop_os.CpuFeature.[
    .RiscvM,
    .RiscvA,
    .RiscvF,
    .RiscvD,
    .RiscvC,
    .RiscvV,
    .RiscvZba,
    .RiscvZbb,
    .RiscvZbs,
    .RiscvZicond,
    .RiscvZcb,
    .RiscvZfa,
    .RiscvZfhmin,
    .RiscvZicboz,
    .RiscvZihintpause,
    .RiscvZawrs,
    .RiscvZimop,
    .RiscvZkt,
    .RiscvSv48,
    .RiscvSvpbmt,
    .RiscvSstc
]

/**
 * Tell whether a feature set has a feature.
 *
 * @param features The features, as detect_features found them; not changed.
 * @param feature The feature asked about.
 * @return True if features has it.
 */
has :: fn(features : ptr[slop_os.CpuFeatures], feature : slop_os.CpuFeature) -> bool {
    return slop_os.has_feature(features, feature)
}

/**
 * Read the harts' features from the device tree (arch_interface.detect_features): the first cpu node's
 * riscv,isa-extensions, or without one its riscv,isa, and its mmu-type, Sv48 for riscv,sv48 or riscv,sv57, Sv57 for
 * the second.
 *
 * @param firmware The firmware's tables, which say where the device tree is.
 * @param direct_map_offset Where physical address 0 is in the bootloader's direct map; 0 means there's none.
 * @return Every feature of EXTENSIONS the node lists, and the paging modes; none without a direct map, a device tree or
 *     a cpu node.
 */
detect_features :: fn(firmware : ptr[boot_info.FirmwareTables], direct_map_offset : u64) -> slop_os.CpuFeatures {
    features : slop_os.CpuFeatures
    if direct_map_offset == 0 {
        return features
    }
    tree := devicetree.open(devicetree_address(firmware, direct_map_offset)) or_return features
    node := devicetree.find_device_type(&tree, "cpu") or_return features
    match devicetree.property(&tree, &node, "riscv,isa-extensions") {
        case Some(listed) => {
            for extension in EXTENSIONS {
                if devicetree.lists(listed, extension.name) {
                    slop_os.add_feature(&features, extension.feature)
                }
            }
        }
        case None => {
            match devicetree.property(&tree, &node, "riscv,isa") {
                case Some(isa) => add_isa_string(&features, isa)
                case None => {}
            }
        }
    }
    match devicetree.property(&tree, &node, "mmu-type") {
        case Some(mode) => {
            if devicetree.lists(mode, "riscv,sv57") {
                slop_os.add_feature(&features, .RiscvSv57)
                slop_os.add_feature(&features, .RiscvSv48)
            }
            if devicetree.lists(mode, "riscv,sv48") {
                slop_os.add_feature(&features, .RiscvSv48)
            }
        }
        case None => {}
    }
    return features
}

/**
 * Add the features an ISA string names, as riscv,isa gives one: "rv64", the single-letter extensions, then the others,
 * each after an underscore, like "rv64imafdcv_zba_zbb_sstc".
 *
 * @param features The set to add to.
 * @param isa The property's value, a string ending in its NUL; one not starting "rv64" adds nothing.
 */
add_isa_string :: fn(features : ptr[mut slop_os.CpuFeatures], isa : devicetree.Property) {
    if isa.size < 5 || !devicetree.matches(isa.address, "rv64") {
        return void
    }
    // The single letters, up to the first underscore or the end
    at := cast[u64](4)
    loop {
        if at >= isa.size {
            break
        }
        letter :: devicetree.byte_at(isa.address + at)
        if letter == 0 || letter == cast[u8]('_') {
            break
        }
        add_named(features, string_of(cast[ptr[u8]](isa.address + at), 1))
        at += 1
    }
    // The rest, each between underscores
    loop {
        if at >= isa.size || devicetree.byte_at(isa.address + at) != cast[u8]('_') {
            break
        }
        start :: at + 1
        at = start
        loop {
            if at >= isa.size {
                break
            }
            character :: devicetree.byte_at(isa.address + at)
            if character == 0 || character == cast[u8]('_') {
                break
            }
            at += 1
        }
        add_named(features, string_of(cast[ptr[u8]](isa.address + start), cast[usize](at - start)))
    }
}

/**
 * Add the feature an extension's name is, if it's one of EXTENSIONS.
 *
 * @param features The set to add to.
 * @param name The extension's name, in lower case; one EXTENSIONS doesn't have adds nothing.
 */
add_named :: fn(features : ptr[mut slop_os.CpuFeatures], name : string) {
    for extension in EXTENSIONS {
        if extension.name == name {
            slop_os.add_feature(features, extension.feature)
        }
    }
}

/**
 * Find the first baseline feature the harts lack (arch_interface.missing_baseline_feature), in BASELINE's order.
 *
 * @param features The harts' features, from detect_features.
 * @return The missing feature's name, as the RISC-V specifications name it (feature_name), a static string; or null if
 *     the harts have the whole baseline.
 */
missing_baseline_feature :: fn(features : ptr[slop_os.CpuFeatures]) -> string? {
    for feature in BASELINE {
        if !has(features, feature) {
            return feature_name(feature)
        }
    }
    return null
}

/**
 * Name a baseline feature as the RISC-V specifications name it, for the message that the harts lack it.
 *
 * @param feature The feature, one of BASELINE's.
 * @return Its name, a static string; "a feature" for one that isn't in BASELINE.
 */
feature_name :: fn(feature : slop_os.CpuFeature) -> string {
    if feature == .RiscvSv48 {
        return "Sv48 paging"
    }
    if feature == .RiscvV {
        return "the vector extension (V)"
    }
    for extension in EXTENSIONS {
        if extension.feature == feature {
            return extension.name
        }
    }
    return "a feature"
}
