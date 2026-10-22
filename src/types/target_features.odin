package types

X86_Feature :: enum {
	X87,
	Cx8,
	Cmov,
	Mmx,
	Fxsr,
	Sse,
	Sse2,
	Cx16,
	Sahf,
	Popcnt,
	Sse3,
	Ssse3,
	Sse4_1,
	Sse4_2,
	Crc32,
	Avx,
	Avx2,
	Bmi,
	Bmi2,
	F16c,
	Fma,
	Lzcnt,
	Movbe,
	Xsave,
	Avx512f,
	Avx512bw,
	Avx512cd,
	Avx512dq,
	Avx512vl,
	Aes,
	Pclmul,
	Sha,
	Adx,
	Rdrand,
	Rdseed,
}

X86_Features :: bit_set[X86_Feature;u64]

X86_Level :: enum {
	V1,
	V2,
	V3,
	V4,
}

X86_LEVEL_SPELLINGS := [X86_Level]string {
	.V1 = "x86_64_v1",
	.V2 = "x86_64_v2",
	.V3 = "x86_64_v3",
	.V4 = "x86_64_v4",
}

X86_FEATURE_SPELLINGS := [X86_Feature]string {
	.X87      = "x87",
	.Cx8      = "cx8",
	.Cmov     = "cmov",
	.Mmx      = "mmx",
	.Fxsr     = "fxsr",
	.Sse      = "sse",
	.Sse2     = "sse2",
	.Cx16     = "cx16",
	.Sahf     = "sahf",
	.Popcnt   = "popcnt",
	.Sse3     = "sse3",
	.Ssse3    = "ssse3",
	.Sse4_1   = "sse4.1",
	.Sse4_2   = "sse4.2",
	.Crc32    = "crc32",
	.Avx      = "avx",
	.Avx2     = "avx2",
	.Bmi      = "bmi",
	.Bmi2     = "bmi2",
	.F16c     = "f16c",
	.Fma      = "fma",
	.Lzcnt    = "lzcnt",
	.Movbe    = "movbe",
	.Xsave    = "xsave",
	.Avx512f  = "avx512f",
	.Avx512bw = "avx512bw",
	.Avx512cd = "avx512cd",
	.Avx512dq = "avx512dq",
	.Avx512vl = "avx512vl",
	.Aes      = "aes",
	.Pclmul   = "pclmul",
	.Sha      = "sha",
	.Adx      = "adx",
	.Rdrand   = "rdrand",
	.Rdseed   = "rdseed",
}

X86_LEVEL_FEATURES := [X86_Level]X86_Features {
	.V1 = {.X87, .Cx8, .Cmov, .Mmx, .Fxsr, .Sse, .Sse2},
	.V2 = {.X87, .Cx8, .Cmov, .Mmx, .Fxsr, .Sse, .Sse2, .Cx16, .Sahf, .Popcnt, .Sse3, .Ssse3, .Sse4_1, .Sse4_2, .Crc32},
	.V3 = {
		.X87,
		.Cx8,
		.Cmov,
		.Mmx,
		.Fxsr,
		.Sse,
		.Sse2,
		.Cx16,
		.Sahf,
		.Popcnt,
		.Sse3,
		.Ssse3,
		.Sse4_1,
		.Sse4_2,
		.Crc32,
		.Avx,
		.Avx2,
		.Bmi,
		.Bmi2,
		.F16c,
		.Fma,
		.Lzcnt,
		.Movbe,
		.Xsave,
	},
	.V4 = {
		.X87,
		.Cx8,
		.Cmov,
		.Mmx,
		.Fxsr,
		.Sse,
		.Sse2,
		.Cx16,
		.Sahf,
		.Popcnt,
		.Sse3,
		.Ssse3,
		.Sse4_1,
		.Sse4_2,
		.Crc32,
		.Avx,
		.Avx2,
		.Bmi,
		.Bmi2,
		.F16c,
		.Fma,
		.Lzcnt,
		.Movbe,
		.Xsave,
		.Avx512f,
		.Avx512bw,
		.Avx512cd,
		.Avx512dq,
		.Avx512vl,
	},
}

x86_level_spelling :: proc(level: X86_Level) -> string {
	return X86_LEVEL_SPELLINGS[level]
}

parse_x86_level :: proc(spelling: string) -> (level: X86_Level, ok: bool) {
	for candidate in X86_Level {
		if X86_LEVEL_SPELLINGS[candidate] == spelling {
			return candidate, true
		}
	}
	return .V1, false
}

x86_level_features :: proc(level: X86_Level) -> X86_Features {
	return X86_LEVEL_FEATURES[level]
}

parse_x86_feature :: proc(name: string) -> (feature: X86_Feature, ok: bool) {
	for candidate in X86_Feature {
		if X86_FEATURE_SPELLINGS[candidate] == name {
			return candidate, true
		}
	}
	switch name {
	case "sse4_1":
		return .Sse4_1, true
	case "sse4_2":
		return .Sse4_2, true
	case "bmi1":
		return .Bmi, true
	case "pclmulqdq":
		return .Pclmul, true
	case "rdrnd":
		return .Rdrand, true
	}
	return .X87, false
}

x86_features_list :: proc(features: X86_Features, allocator := context.allocator) -> []string {
	count := 0
	for feature in X86_Feature {
		if feature in features {
			count += 1
		}
	}
	list := make([]string, count, allocator)
	index := 0
	for feature in X86_Feature {
		if feature in features {
			list[index] = X86_FEATURE_SPELLINGS[feature]
			index += 1
		}
	}
	return list
}
