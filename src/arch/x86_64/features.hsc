package arch_x86_64

import x86_64 from "base/intrinsics"
import slop_os from "std/os"

// Where one feature is reported: a CPUID leaf, subleaf, register and bit.
CpuidRegister :: enum {
    Eax,
    Ebx,
    Ecx,
    Edx,
}

FeatureBit :: struct {
    feature : slop_os.CpuFeature,
    leaf : u32,
    subleaf : u32,
    register : CpuidRegister,
    bit : u32,
}

//SPEC: Intel SDM Vol. 2A, CPUID (Tables 3-10, 3-11, leaf 07H, leaf 0DH, leaves 80000001H and 80000007H)
//HEMERA(friction): an element of an array literal can't be written .{...}, so each names its type
FEATURE_BITS :: FeatureBit.[
    FeatureBit.{.X86Sse3, 1, 0, .Ecx, 0},
    FeatureBit.{.X86Pclmulqdq, 1, 0, .Ecx, 1},
    FeatureBit.{.X86Ssse3, 1, 0, .Ecx, 9},
    FeatureBit.{.X86Fma, 1, 0, .Ecx, 12},
    FeatureBit.{.X86Cx16, 1, 0, .Ecx, 13},
    FeatureBit.{.X86Pcid, 1, 0, .Ecx, 17},
    FeatureBit.{.X86Sse41, 1, 0, .Ecx, 19},
    FeatureBit.{.X86Sse42, 1, 0, .Ecx, 20},
    FeatureBit.{.X86X2Apic, 1, 0, .Ecx, 21},
    FeatureBit.{.X86Movbe, 1, 0, .Ecx, 22},
    FeatureBit.{.X86Popcnt, 1, 0, .Ecx, 23},
    FeatureBit.{.X86TscDeadline, 1, 0, .Ecx, 24},
    FeatureBit.{.X86AesNi, 1, 0, .Ecx, 25},
    FeatureBit.{.X86Xsave, 1, 0, .Ecx, 26},
    FeatureBit.{.X86Avx, 1, 0, .Ecx, 28},
    FeatureBit.{.X86F16c, 1, 0, .Ecx, 29},
    FeatureBit.{.X86Rdrand, 1, 0, .Ecx, 30},
    FeatureBit.{.X86Apic, 1, 0, .Edx, 9},
    FeatureBit.{.X86Pat, 1, 0, .Edx, 16},
    FeatureBit.{.X86FsGsBase, 7, 0, .Ebx, 0},
    FeatureBit.{.X86Bmi1, 7, 0, .Ebx, 3},
    FeatureBit.{.X86Avx2, 7, 0, .Ebx, 5},
    FeatureBit.{.X86Smep, 7, 0, .Ebx, 7},
    FeatureBit.{.X86Bmi2, 7, 0, .Ebx, 8},
    FeatureBit.{.X86Invpcid, 7, 0, .Ebx, 10},
    FeatureBit.{.X86Avx512F, 7, 0, .Ebx, 16},
    FeatureBit.{.X86Avx512Dq, 7, 0, .Ebx, 17},
    FeatureBit.{.X86Rdseed, 7, 0, .Ebx, 18},
    FeatureBit.{.X86Smap, 7, 0, .Ebx, 20},
    FeatureBit.{.X86Avx512Cd, 7, 0, .Ebx, 28},
    FeatureBit.{.X86Sha, 7, 0, .Ebx, 29},
    FeatureBit.{.X86Avx512Bw, 7, 0, .Ebx, 30},
    FeatureBit.{.X86Avx512Vl, 7, 0, .Ebx, 31},
    FeatureBit.{.X86Vaes, 7, 0, .Ecx, 9},
    FeatureBit.{.X86Vpclmulqdq, 7, 0, .Ecx, 10},
    FeatureBit.{.X86FiveLevelPaging, 7, 0, .Ecx, 16},
    FeatureBit.{.X86Xsaveopt, 0xd, 1, .Eax, 0},
    FeatureBit.{.X86Xsavec, 0xd, 1, .Eax, 1},
    FeatureBit.{.X86LahfSahf, 0x80000001, 0, .Ecx, 0},
    FeatureBit.{.X86Lzcnt, 0x80000001, 0, .Ecx, 5},
    FeatureBit.{.X86Syscall, 0x80000001, 0, .Edx, 11},
    FeatureBit.{.X86NoExecute, 0x80000001, 0, .Edx, 20},
    FeatureBit.{.X86Pages1G, 0x80000001, 0, .Edx, 26},
    FeatureBit.{.X86InvariantTsc, 0x80000007, 0, .Edx, 8},
]

/*
 * What SlopOS needs (decisions/0003, design/arch-x86-64.md): x86-64-v3, which includes v2, plus
 * no-execute for W^X, SYSCALL, and a local APIC. In the order they're checked.
 */
BASELINE :: slop_os.CpuFeature.[
    .X86Cx16, .X86LahfSahf, .X86Popcnt, .X86Sse3, .X86Ssse3, .X86Sse41, .X86Sse42,
    .X86Avx, .X86Avx2, .X86Bmi1, .X86Bmi2, .X86F16c, .X86Fma, .X86Lzcnt, .X86Movbe, .X86Xsave,
    .X86NoExecute, .X86Syscall, .X86Apic,
]

has :: fn(features: ptr[slop_os.CpuFeatures], feature: slop_os.CpuFeature) -> bool {
    return slop_os.has_feature(features, feature)
}

// The CPU's features, from CPUID. Leaves the CPU doesn't have report nothing.
detect_features :: fn() -> slop_os.CpuFeatures {
    features : slop_os.CpuFeatures
    highest_basic :: x86_64.cpuid(0).eax
    highest_extended :: x86_64.cpuid(0x80000000).eax
    for bit in FEATURE_BITS {
        highest :: if bit.leaf >= 0x80000000 { highest_extended } else { highest_basic }
        if bit.leaf > highest {
            continue
        }
        if (register_of(x86_64.cpuid(bit.leaf, bit.subleaf), bit.register) >> bit.bit) & 1 == 1 {
            slop_os.add_feature(&features, bit.feature)
        }
    }
    return features
}

register_of :: fn(result: x86_64.CpuidResult, register: CpuidRegister) -> u32 {
    return match register {
        case .Eax => result.eax
        case .Ebx => result.ebx
        case .Ecx => result.ecx
        case .Edx => result.edx
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

//HEMERA(friction): no way to get an enum value's name, so the baseline's names are written out
feature_name :: fn(feature: slop_os.CpuFeature) -> string {
    return match feature {
        case .X86Cx16 => "CMPXCHG16B"
        case .X86LahfSahf => "LAHF/SAHF"
        case .X86Popcnt => "POPCNT"
        case .X86Sse3 => "SSE3"
        case .X86Ssse3 => "SSSE3"
        case .X86Sse41 => "SSE4.1"
        case .X86Sse42 => "SSE4.2"
        case .X86Avx => "AVX"
        case .X86Avx2 => "AVX2"
        case .X86Bmi1 => "BMI1"
        case .X86Bmi2 => "BMI2"
        case .X86F16c => "F16C"
        case .X86Fma => "FMA"
        case .X86Lzcnt => "LZCNT"
        case .X86Movbe => "MOVBE"
        case .X86Xsave => "XSAVE"
        case .X86NoExecute => "no-execute (NX)"
        case .X86Syscall => "SYSCALL"
        case .X86Apic => "local APIC"
        case _ => "a feature"
    }
}
