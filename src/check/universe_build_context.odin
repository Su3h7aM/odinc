package check

import "core:math/big"
import "core:reflect"
import "oc:types"

Target_Os :: enum u8 {
	Unknown,
	Windows,
	Darwin,
	Linux,
	FreeBSD,
	OpenBSD,
	NetBSD,
	WASI,
	JS,
	Orca,
	Freestanding,
}

Target_Arch :: enum u8 {
	Unknown,
	amd64,
	i386,
	arm32,
	arm64,
	wasm32,
	wasm64p32,
	riscv64,
}

Target_Endian :: enum u8 {
	Little,
	Big,
}

Platform_Subtarget :: enum u8 {
	Default,
	iPhone,
	iPhoneSimulator,
	Android,
	Playdate,
}

Build_Mode :: enum u8 {
	Executable,
	Dynamic,
	Static,
	Object,
	Assembly,
	LLVM_IR,
}

Error_Pos_Style :: enum u8 {
	Default,
	Unix,
}

// Values of BuildContext.optimization_level in official build_settings.cpp; the zero value is `-o:minimal`.
Optimization_Mode :: enum i8 {
	None = -1,
	Minimal = 0,
	Size,
	Speed,
	Aggressive,
}

// Source of the ODIN_* universe constants. The driver fills it; `defines` is the slot for `--define=` values read by `#config`.
Build_Configuration :: struct {
	root:                       string,
	os:                         Target_Os,
	arch:                       Target_Arch,
	endian:                     Target_Endian,
	subtarget:                  Platform_Subtarget,
	build_mode:                 Build_Mode,
	error_pos_style:            Error_Pos_Style,
	optimization_mode:          Optimization_Mode,
	debug:                      bool,
	disable_assert:             bool,
	no_bounds_check:            bool,
	no_type_assert:             bool,
	default_to_nil_allocator:   bool,
	default_to_panic_allocator: bool,
	no_crt:                     bool,
	no_thread_local:            bool,
	no_rtti:                    bool,
	use_separate_modules:       bool,
	test:                       bool,
	no_entry_point:             bool,
	foreign_error_procedures:   bool,
	valgrind_support:           bool,
	bedrock:                    bool,
	defines:                    map[string]string,
	target_features:            []string,
}

@(rodata)
DEFAULT_BUILD_CONFIGURATION := Build_Configuration {
	os              = .Linux,
	arch            = .amd64,
	endian          = .Little,
	no_crt          = true,
	// Upstream llvm_backend.cpp defaults Linux amd64 to x86-64-v2.
	target_features = {
		"64bit",
		"64bit-mode",
		"cmov",
		"crc32",
		"cx16",
		"cx8",
		"false-deps-popcnt",
		"fast-15bytenop",
		"fast-scalar-fsqrt",
		"fast-shld-rotate",
		"fxsr",
		"idivq-to-divl",
		"macrofusion",
		"mmx",
		"nopl",
		"popcnt",
		"sahf",
		"slow-3ops-lea",
		"slow-unaligned-mem-32",
		"sse",
		"sse2",
		"sse3",
		"sse4.1",
		"sse4.2",
		"ssse3",
		"vzeroupper",
		"x87",
	},
}

// Names from official build_settings.cpp `target_os_names`, `target_arch_names` and `target_endian_names`.
@(private = "file")
target_os_names := [Target_Os]string {
	.Unknown      = "",
	.Windows      = "windows",
	.Darwin       = "darwin",
	.Linux        = "linux",
	.FreeBSD      = "freebsd",
	.OpenBSD      = "openbsd",
	.NetBSD       = "netbsd",
	.WASI         = "wasi",
	.JS           = "js",
	.Orca         = "orca",
	.Freestanding = "freestanding",
}

@(private = "file")
target_arch_names := [Target_Arch]string {
	.Unknown   = "",
	.amd64     = "amd64",
	.i386      = "i386",
	.arm32     = "arm32",
	.arm64     = "arm64",
	.wasm32    = "wasm32",
	.wasm64p32 = "wasm64p32",
	.riscv64   = "riscv64",
}

@(private = "file")
target_endian_names := [Target_Endian]string {
	.Little = "little",
	.Big    = "big",
}

// Publishes the ODIN_* constants of the configuration into the universe, as official checker.cpp does.
bind_universe_build_context :: proc(checker: ^Type_Checker, universe: Scope_Id, pool: ^Constant_Pool, configuration: Build_Configuration) -> bool {
	string_type := types.intern(checker.store, types.Type{kind = .String})
	f16_supported := configuration.arch != .wasm32 && configuration.arch != .wasm64p32 && (configuration.os != .Darwin || configuration.arch != .amd64)
	texts := [?]struct {
		name:  string,
		value: string,
	} {
		{"ODIN_OS_STRING", target_os_names[configuration.os]},
		{"ODIN_ARCH_STRING", target_arch_names[configuration.arch]},
		{"ODIN_ENDIAN_STRING", target_endian_names[configuration.endian]},
		{"ODIN_ROOT", configuration.root},
	}
	for text in texts {
		constant, constant_error := constant_pool_intern_string(pool, text.value, string_type)
		if constant_error != nil || !publish_universe_constant(checker, universe, text.name, string_type, constant) { return false }
	}
	flags := [?]struct {
		name:  string,
		value: bool,
	} {
		{"ODIN_DEBUG", configuration.debug},
		{"__ODIN_LLVM_F16_SUPPORTED", f16_supported},
		{"ODIN_DISABLE_ASSERT", configuration.disable_assert},
		{"ODIN_NO_BOUNDS_CHECK", configuration.no_bounds_check},
		{"ODIN_NO_TYPE_ASSERT", configuration.no_type_assert},
		{"ODIN_DEFAULT_TO_NIL_ALLOCATOR", configuration.default_to_nil_allocator},
		{"ODIN_DEFAULT_TO_PANIC_ALLOCATOR", configuration.default_to_panic_allocator},
		{"ODIN_NO_CRT", configuration.no_crt},
		{"ODIN_NO_THREAD_LOCAL", configuration.no_thread_local},
		{"ODIN_NO_RTTI", configuration.no_rtti},
		{"ODIN_USE_SEPARATE_MODULES", configuration.use_separate_modules},
		{"ODIN_TEST", configuration.test},
		{"ODIN_NO_ENTRY_POINT", configuration.no_entry_point},
		{"ODIN_FOREIGN_ERROR_PROCEDURES", configuration.foreign_error_procedures},
		{"ODIN_VALGRIND_SUPPORT", configuration.valgrind_support},
		{"ODIN_BEDROCK", configuration.bedrock},
	}
	for flag in flags {
		constant, constant_error := constant_pool_intern_bool(pool, flag.value, types.TYPE_UNTYPED_BOOL)
		if constant_error != nil || !publish_universe_constant(checker, universe, flag.name, types.TYPE_UNTYPED_BOOL, constant) { return false }
	}
	if !publish_enum_constant(checker, universe, pool, "Odin_OS_Type", "ODIN_OS", Target_Os, configuration.os) { return false }
	if !publish_enum_constant(checker, universe, pool, "Odin_Arch_Type", "ODIN_ARCH", Target_Arch, configuration.arch) { return false }
	if !publish_enum_constant(checker, universe, pool, "Odin_Endian_Type", "ODIN_ENDIAN", Target_Endian, configuration.endian) { return false }
	if !publish_enum_constant(
		checker,
		universe,
		pool,
		"Odin_Platform_Subtarget_Type",
		"ODIN_PLATFORM_SUBTARGET",
		Platform_Subtarget,
		configuration.subtarget,
	) {
		return false
	}
	if !publish_enum_constant(checker, universe, pool, "Odin_Build_Mode_Type", "ODIN_BUILD_MODE", Build_Mode, configuration.build_mode) { return false }
	if !publish_enum_constant(checker, universe, pool, "Odin_Error_Pos_Style_Type", "ODIN_ERROR_POS_STYLE", Error_Pos_Style, configuration.error_pos_style) {
		return false
	}
	if !publish_optimization_mode(checker, universe, pool, configuration.optimization_mode) { return false }
	if !publish_sanitizer_flags(checker, universe, pool) { return false }
	if !publish_intrinsics_fast_math(checker) { return false }
	return bind_universe_calling_convention(checker, universe, pool)
}

@(private = "file")
Fast_Math_Flag :: enum u8 {
	Allow_Reassoc,
	No_NaNs,
	No_Infs,
	No_Signed_Zeros,
	Allow_Reciprocal,
	Allow_Contract,
	Approx_Func,
}

@(private = "file")
publish_intrinsics_fast_math :: proc(checker: ^Type_Checker) -> bool {
	for intrinsics_package in checker.packages {
		if intrinsics_package.kind != .Intrinsics { continue }
		names := reflect.enum_field_names(Fast_Math_Flag)
		members, allocation_error := make([]Enum_Member, len(names), checker.arena_allocator)
		if allocation_error != nil { return false }
		for name, index in names {members[index] = Enum_Member {
				name  = name,
				value = i128(index),
			}}
		backing := types.intern(checker.store, types.Type{kind = .Integer, count = 1})
		enum_type := types.intern(
			checker.store,
			types.Type {
				kind = .Enum,
				name = "Fast_Math_Flag",
				backing = backing,
				count = i64(len(members)),
				enum_lower_bound = 0,
				enum_upper_bound = i128(len(members) - 1),
			},
		)
		flag_type := types.intern(checker.store, types.Type{kind = .Named, name = "Fast_Math_Flag", elem = enum_type})
		checker.enum_members[enum_type] = members
		checker.enum_members[flag_type] = members
		if !publish_package_type(checker, intrinsics_package.scope, "Fast_Math_Flag", flag_type) { return false }
		u32_type := types.intern(checker.store, types.Type{kind = .Integer, count = 4})
		flags_bit_set := types.intern(
			checker.store,
			types.Type {
				kind = .Bit_Set,
				elem = flag_type,
				backing = u32_type,
				lower_bound = 0,
				upper_bound = i64(len(members) - 1),
				enum_lower_bound = 0,
				enum_upper_bound = i128(len(members) - 1),
			},
		)
		flags_type := types.intern(checker.store, types.Type{kind = .Named, name = "Fast_Math_Flags", elem = flags_bit_set})
		if !publish_package_type(checker, intrinsics_package.scope, "Fast_Math_Flags", flags_type) { return false }
		return true
	}
	return true
}

@(private = "file")
publish_package_type :: proc(checker: ^Type_Checker, scope: Scope_Id, name: string, type: types.Type_Id) -> bool {
	id, create_error := entity_create(checker.resolver.scopes, Entity{name = name, kind = .Type_Name, scope = scope, state = .Resolved, type = type})
	if create_error != nil { return false }
	_, insert_error := scope_insert(checker.resolver.scopes, scope, id)
	return insert_error == nil
}

// The enum type takes the member order of `E`, whose values count from 0 as in the official tables.
@(private = "file")
publish_enum_constant :: proc(
	checker: ^Type_Checker,
	universe: Scope_Id,
	pool: ^Constant_Pool,
	type_name: string,
	constant_name: string,
	$E: typeid,
	selected: E,
) -> bool {
	enum_type, ok := publish_enum_type(checker, E, type_name)
	if !ok { return false }
	return publish_enum_value(checker, universe, pool, enum_type, constant_name, i64(selected))
}

@(private = "file")
publish_enum_value :: proc(
	checker: ^Type_Checker,
	universe: Scope_Id,
	pool: ^Constant_Pool,
	enum_type: types.Type_Id,
	constant_name: string,
	selected: i64,
) -> bool {
	value: big.Int
	defer big.destroy(&value)
	if set_error := big.set(&value, selected); set_error != nil { return false }
	constant, constant_error := constant_pool_intern_integer(pool, &value, enum_type)
	if constant_error != nil { return false }
	return publish_universe_constant(checker, universe, constant_name, enum_type, constant)
}

@(private = "file")
publish_enum_type :: proc(checker: ^Type_Checker, $E: typeid, type_name: string) -> (enum_type: types.Type_Id, ok: bool) {
	names := reflect.enum_field_names(E)
	members, members_error := make([]Enum_Member, len(names), checker.arena_allocator)
	if members_error != nil { return 0, false }
	for name, index in names {members[index] = Enum_Member {
			name  = name,
			value = i128(index),
		}}
	return publish_enum_members(checker, type_name, members)
}

@(private = "file")
publish_enum_members :: proc(checker: ^Type_Checker, type_name: string, members: []Enum_Member) -> (enum_type: types.Type_Id, ok: bool) {
	lower, upper := members[0].value, members[0].value
	for member in members {
		lower = min(lower, member.value)
		upper = max(upper, member.value)
	}
	backing := types.intern(checker.store, types.Type{kind = .Integer, name = "int", count = types.DEFAULT_LAYOUT.int_size, signed = true})
	enum_type = types.intern(
		checker.store,
		types.Type{kind = .Enum, name = type_name, backing = backing, count = i64(len(members)), enum_lower_bound = lower, enum_upper_bound = upper},
	)
	_, stored, inserted, map_error := map_entry(&checker.enum_members, enum_type)
	if map_error != nil { return 0, false }
	if inserted { stored^ = members }
	return enum_type, true
}

@(private = "file")
publish_optimization_mode :: proc(checker: ^Type_Checker, universe: Scope_Id, pool: ^Constant_Pool, selected: Optimization_Mode) -> bool {
	names := reflect.enum_field_names(Optimization_Mode)
	members, members_error := make([]Enum_Member, len(names), checker.arena_allocator)
	if members_error != nil { return false }
	for mode, index in Optimization_Mode {
		members[index] = Enum_Member {
			name  = names[index],
			value = i128(mode),
		}
	}
	enum_type, ok := publish_enum_members(checker, "Odin_Optimization_Mode", members)
	if !ok { return false }
	return publish_enum_value(checker, universe, pool, enum_type, "ODIN_OPTIMIZATION_MODE", i64(selected))
}

// Official checker.cpp declares ODIN_SANITIZER_FLAGS as a bit_set of Odin_Sanitizer_Flag over u32; no sanitizer is enabled.
@(private = "file")
Sanitizer_Flag :: enum {
	Address,
	Memory,
	Thread,
}

@(private = "file")
publish_sanitizer_flags :: proc(checker: ^Type_Checker, universe: Scope_Id, pool: ^Constant_Pool) -> bool {
	enum_type, ok := publish_enum_type(checker, Sanitizer_Flag, "Odin_Sanitizer_Flag")
	if !ok { return false }
	backing := types.intern(checker.store, types.Type{kind = .Integer, count = 4})
	flags_type := types.intern(
		checker.store,
		types.Type {
			kind = .Bit_Set,
			name = "Odin_Sanitizer_Flags",
			elem = enum_type,
			backing = backing,
			lower_bound = 0,
			upper_bound = 2,
			enum_lower_bound = 0,
			enum_upper_bound = 2,
		},
	)
	value: big.Int
	defer big.destroy(&value)
	if set_error := big.set(&value, 0); set_error != nil { return false }
	constant, constant_error := constant_pool_intern_integer(pool, &value, flags_type)
	if constant_error != nil { return false }
	return publish_universe_constant(checker, universe, "ODIN_SANITIZER_FLAGS", flags_type, constant)
}

publish_universe_constant :: proc(checker: ^Type_Checker, universe: Scope_Id, name: string, type: types.Type_Id, constant: Const_Id) -> bool {
	id, create_error := entity_create(
		checker.resolver.scopes,
		Entity{name = name, kind = .Constant, scope = universe, state = .Resolved, type = type, constant = constant},
	)
	if create_error != nil { return false }
	_, insert_error := scope_insert(checker.resolver.scopes, universe, id)
	return insert_error == nil
}
