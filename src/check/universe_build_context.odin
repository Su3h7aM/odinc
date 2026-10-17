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

// Source of the ODIN_* universe constants. The driver fills it; `defines` is the slot for `-define:` values read by `#config`.
Build_Configuration :: struct {
	os:                         Target_Os,
	arch:                       Target_Arch,
	endian:                     Target_Endian,
	subtarget:                  Platform_Subtarget,
	build_mode:                 Build_Mode,
	error_pos_style:            Error_Pos_Style,
	debug:                      bool,
	disable_assert:             bool,
	no_bounds_check:            bool,
	no_type_assert:             bool,
	default_to_nil_allocator:   bool,
	default_to_panic_allocator: bool,
	no_crt:                     bool,
	no_thread_local:            bool,
	use_separate_modules:       bool,
	bedrock:                    bool,
	defines:                    map[string]string,
}

DEFAULT_BUILD_CONFIGURATION :: Build_Configuration {
	os     = .Linux,
	arch   = .amd64,
	endian = .Little,
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
	texts := [?]struct {
		name:  string,
		value: string,
	} {
		{"ODIN_OS_STRING", target_os_names[configuration.os]},
		{"ODIN_ARCH_STRING", target_arch_names[configuration.arch]},
		{"ODIN_ENDIAN_STRING", target_endian_names[configuration.endian]},
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
		{"ODIN_DISABLE_ASSERT", configuration.disable_assert},
		{"ODIN_NO_BOUNDS_CHECK", configuration.no_bounds_check},
		{"ODIN_NO_TYPE_ASSERT", configuration.no_type_assert},
		{"ODIN_DEFAULT_TO_NIL_ALLOCATOR", configuration.default_to_nil_allocator},
		{"ODIN_DEFAULT_TO_PANIC_ALLOCATOR", configuration.default_to_panic_allocator},
		{"ODIN_NO_CRT", configuration.no_crt},
		{"ODIN_NO_THREAD_LOCAL", configuration.no_thread_local},
		{"ODIN_USE_SEPARATE_MODULES", configuration.use_separate_modules},
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
	return publish_enum_constant(checker, universe, pool, "Odin_Error_Pos_Style_Type", "ODIN_ERROR_POS_STYLE", Error_Pos_Style, configuration.error_pos_style)
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
	names := reflect.enum_field_names(E)
	members, members_error := make([]Enum_Member, len(names), checker.arena_allocator)
	if members_error != nil { return false }
	for name, index in names {members[index] = Enum_Member {
			name  = name,
			value = i64(index),
		}}
	backing := types.intern(checker.store, types.Type{kind = .Integer, count = types.DEFAULT_LAYOUT.int_size, signed = true})
	enum_type := types.intern(
		checker.store,
		types.Type{kind = .Enum, name = type_name, backing = backing, count = i64(len(names)), lower_bound = 0, upper_bound = i64(len(names) - 1)},
	)
	_, stored, inserted, map_error := map_entry(&checker.enum_members, enum_type)
	if map_error != nil { return false }
	if inserted { stored^ = members }
	value: big.Int
	defer big.destroy(&value)
	if set_error := big.set(&value, i64(selected)); set_error != nil { return false }
	constant, constant_error := constant_pool_intern_integer(pool, &value, enum_type)
	if constant_error != nil { return false }
	return publish_universe_constant(checker, universe, constant_name, enum_type, constant)
}

@(private = "file")
publish_universe_constant :: proc(checker: ^Type_Checker, universe: Scope_Id, name: string, type: types.Type_Id, constant: Const_Id) -> bool {
	id, create_error := entity_create(
		checker.resolver.scopes,
		Entity{name = name, kind = .Constant, scope = universe, state = .Resolved, type = type, constant = constant},
	)
	if create_error != nil { return false }
	_, insert_error := scope_insert(checker.resolver.scopes, universe, id)
	return insert_error == nil
}
