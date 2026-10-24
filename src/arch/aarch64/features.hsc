package arch_aarch64

import aarch64 from "base/intrinsics"
import slop_os from "std/os"

// Where one feature is reported: an ID register, the field's lowest bit, and the lowest value that means it's there.
IdRegister :: enum {
    Pfr0,
    Pfr1,
    Isar0,
    Isar1,
    Mmfr0,
    Mmfr1,
}

FeatureField :: struct {
    feature : slop_os.CpuFeature,
    register : IdRegister,
    shift : u32,
    minimum : u64,
}

/*
 * Unsigned 4-bit fields, except FP and AdvSIMD, which are signed: 0xf means absent, and 0 or 1 present
 * (feature_present).
 */
//SPEC: Arm ARM (DDI 0487) D19.2: ID_AA64PFR0_EL1, ID_AA64PFR1_EL1, ID_AA64ISAR0_EL1, ID_AA64ISAR1_EL1, ID_AA64MMFR0_EL1, ID_AA64MMFR1_EL1
FEATURE_FIELDS :: FeatureField.[
    .{.Aarch64Fp, .Pfr0, 16, 0},
    .{.Aarch64AdvSimd, .Pfr0, 20, 0},
    .{.Aarch64Fp16, .Pfr0, 16, 1},
    .{.Aarch64Sve, .Pfr0, 32, 1},
    .{.Aarch64Bti, .Pfr1, 0, 1},
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
    .{.Aarch64Pan, .Mmfr1, 20, 1},
]

/*
 * What SlopOS needs (decisions/0061): ARMv8.2-A with the LSE atomics. Floating point, Advanced SIMD and
 * PAN are architectural from ARMv8.1-A and ARMv8.0-A, and RDM from ARMv8.1-A, so checking those and the
 * atomics finds a CPU below the baseline. In the order they're checked.
 */
BASELINE :: slop_os.CpuFeature.[.Aarch64Fp, .Aarch64AdvSimd, .Aarch64Atomics, .Aarch64Rdm, .Aarch64Pan]

has :: fn(features: ptr[slop_os.CpuFeatures], feature: slop_os.CpuFeature) -> bool {
    return slop_os.has_feature(features, feature)
}

// The CPU's features, from its ID registers. 1 GiB blocks come with 4 KiB pages on every AArch64 CPU.
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

feature_present :: fn(field: FeatureField) -> bool {
    value :: (id_register(field.register) >> cast[u64](field.shift)) & 0xf
    if field.feature == .Aarch64Fp || field.feature == .Aarch64AdvSimd {
        return value != 0xf
    }
    return value >= field.minimum
}

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

// The first baseline feature the CPU lacks, or null.
missing_baseline_feature :: fn(features: ptr[slop_os.CpuFeatures]) -> string? {
    for feature in BASELINE {
        if !has(features, feature) {
            return feature_name(feature)
        }
    }
    return null
}

// Each feature as Arm's manuals name it
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
