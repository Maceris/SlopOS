package arch_aarch64

import aarch64 from "base/intrinsics"
import slop_os from "std/os"

/** Which of the ID registers a feature is reported in. */
IdRegister :: enum {
    /** ID_AA64PFR0_EL1, processor features 0: FP, AdvSIMD, SVE. */
    Pfr0,
    /** ID_AA64PFR1_EL1, processor features 1: BTI and GCS. */
    Pfr1,
    /** ID_AA64ISAR0_EL1, instruction set attributes 0: the crypto, CRC32, atomic, RDM, dot product and RNG ones. */
    Isar0,
    /** ID_AA64ISAR1_EL1, instruction set attributes 1: pointer authentication. */
    Isar1,
    /** ID_AA64MMFR0_EL1, memory model features 0: ASID size. */
    Mmfr0,
    /** ID_AA64MMFR1_EL1, memory model features 1: HAFDBS and PAN. */
    Mmfr1,
}

/**
 * Where one feature is reported: an ID register, the 4-bit field's lowest bit, and the lowest value that means it's
 * there.
 */
FeatureField :: struct {
    /** The feature the field reports. */
    feature : slop_os.CpuFeature,
    /** The ID register the field is in. */
    register : IdRegister,
    /** The field's lowest bit, a multiple of 4 from 0 to 60. */
    shift : u32,
    /** The lowest field value that means the feature is there; FP and AdvSIMD are read otherwise (feature_present). */
    minimum : u64,
}

/*
 * Unsigned 4-bit fields, except FP and AdvSIMD, which are signed: 0xf means absent, and 0 or 1 present
 * (feature_present).
 */
/**
 * Every feature detect_features looks for, and where each is reported; a feature listed twice is there if
 * either field says so.
 *
 * SPEC: Arm ARM (DDI 0487) D19.2: ID_AA64PFR0_EL1, ID_AA64PFR1_EL1, ID_AA64ISAR0_EL1, ID_AA64ISAR1_EL1,
 * ID_AA64MMFR0_EL1, ID_AA64MMFR1_EL1.
 */
FEATURE_FIELDS :: FeatureField.[
    .{.Aarch64Fp, .Pfr0, 16, 0},
    .{.Aarch64AdvSimd, .Pfr0, 20, 0},
    .{.Aarch64Fp16, .Pfr0, 16, 1},
    .{.Aarch64Sve, .Pfr0, 32, 1},
    .{.Aarch64Bti, .Pfr1, 0, 1},
    .{.Aarch64Gcs, .Pfr1, 44, 1},
    .{.Aarch64Aes, .Isar0, 4, 1},
    .{.Aarch64Pmull, .Isar0, 4, 2},
    .{.Aarch64Sha1, .Isar0, 8, 1},
    .{.Aarch64Sha256, .Isar0, 12, 1},
    .{.Aarch64Sha512, .Isar0, 12, 2},
    .{.Aarch64Crc32, .Isar0, 16, 1},
    .{.Aarch64Atomics, .Isar0, 20, 2},
    .{.Aarch64Rdm, .Isar0, 28, 1},
    .{.Aarch64Sha3, .Isar0, 32, 1},
    .{.Aarch64DotProduct, .Isar0, 44, 1},
    .{.Aarch64Rng, .Isar0, 60, 1},
    // Either address-authentication field: APA (the architected algorithm) or API (an implementation's own)
    .{.Aarch64PointerAuthentication, .Isar1, 4, 1},
    .{.Aarch64PointerAuthentication, .Isar1, 8, 1},
    .{.Aarch64Asid16, .Mmfr0, 4, 2},
    // HAFDBS: the access flag set by the hardware as a page is touched
    .{.Aarch64HardwareAccessFlag, .Mmfr1, 0, 1},
    .{.Aarch64Pan, .Mmfr1, 20, 1},
]

/**
 * What SlopOS needs (decisions/0061): ARMv8.2-A with the LSE atomics, in the order they're checked.
 *
 * Floating point, Advanced SIMD and PAN are architectural from ARMv8.1-A and ARMv8.0-A, and RDM from ARMv8.1-A,
 * so checking those and the atomics finds a CPU below the baseline.
 */
BASELINE :: slop_os.CpuFeature.[.Aarch64Fp, .Aarch64AdvSimd, .Aarch64Atomics, .Aarch64Rdm, .Aarch64Pan]

/**
 * Tell whether a feature set has a feature.
 *
 * @param features The features, as detect_features found them; not changed.
 * @param feature The feature asked about.
 * @return True if features has it.
 */
has :: fn(features: ptr[slop_os.CpuFeatures], feature: slop_os.CpuFeature) -> bool {
    return slop_os.has_feature(features, feature)
}

/**
 * Read the calling CPU's features from its ID registers (arch_interface.detect_features).
 *
 * 1 GiB blocks come with 4 KiB pages on every AArch64 CPU, so Aarch64Pages1G is always there.
 *
 * @return Every feature FEATURE_FIELDS finds, and Aarch64Pages1G.
 */
detect_features :: fn() -> slop_os.CpuFeatures {
    features : slop_os.CpuFeatures
    for field in FEATURE_FIELDS {
        if feature_present(field) {
            slop_os.add_feature(&features, field.feature)
        }
    }
    slop_os.add_feature(&features, .Aarch64Pages1G)
    return features
}

/**
 * Tell whether one ID register field says its feature is there.
 *
 * @param field Where the feature is reported. FP and AdvSIMD are signed fields, there unless 0xf; every other
 *     field is unsigned, there at minimum or above.
 * @return True if the calling CPU has the feature, as the field says.
 */
feature_present :: fn(field: FeatureField) -> bool {
    value :: (id_register(field.register) >> cast[u64](field.shift)) & 0xf
    if field.feature == .Aarch64Fp || field.feature == .Aarch64AdvSimd {
        return value != 0xf
    }
    return value >= field.minimum
}

/**
 * Read one of the calling CPU's ID registers, at EL1.
 *
 * @param register Which register.
 * @return The register's whole 64-bit value.
 */
id_register :: fn(register: IdRegister) -> u64 {
    return match register {
        case .Pfr0 => aarch64.read_system_register(.ID_AA64PFR0_EL1)
        case .Pfr1 => aarch64.read_system_register_encoded(3, 0, 0, 4, 1)
        case .Isar0 => aarch64.read_system_register(.ID_AA64ISAR0_EL1)
        case .Isar1 => aarch64.read_system_register(.ID_AA64ISAR1_EL1)
        case .Mmfr0 => aarch64.read_system_register(.ID_AA64MMFR0_EL1)
        case .Mmfr1 => aarch64.read_system_register(.ID_AA64MMFR1_EL1)
    }
}

/**
 * Find the first baseline feature the CPU lacks (arch_interface.missing_baseline_feature), in BASELINE's order.
 *
 * @param features The CPU's features, from detect_features.
 * @return The missing feature's name, as Arm's manuals name it (feature_name), a static string; or null if the CPU
 *     has the whole baseline.
 */
missing_baseline_feature :: fn(features: ptr[slop_os.CpuFeatures]) -> string? {
    for feature in BASELINE {
        if !has(features, feature) {
            return feature_name(feature)
        }
    }
    return null
}

/**
 * Name a baseline feature as Arm's manuals name it, for the message that the CPU lacks it.
 *
 * @param feature The feature, one of BASELINE's.
 * @return Its name, a static string; "a feature" for one that isn't in BASELINE.
 */
feature_name :: fn(feature: slop_os.CpuFeature) -> string {
    return match feature {
        case .Aarch64Fp => "floating point"
        case .Aarch64AdvSimd => "Advanced SIMD"
        case .Aarch64Atomics => "the LSE atomics (FEAT_LSE)"
        case .Aarch64Rdm => "FEAT_RDM"
        case .Aarch64Pan => "Privileged Access Never (FEAT_PAN)"
        case _ => "a feature"
    }
}
