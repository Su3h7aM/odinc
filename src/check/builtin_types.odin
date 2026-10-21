package check

import "oc:types"

Builtin_Types :: struct {
	int, uint, uintptr, i8, u8, i16, u16, i32, u32, i64, u64, i128, u128:              types.Type_Id,
	boolean, f32, f64, rune, rawptr, string_type:                                      types.Type_Id,
	cstring_type, string16_type, cstring16_type:                                       types.Type_Id,
	f16, complex32, complex64, complex128, quaternion64, quaternion128, quaternion256: types.Type_Id,
	b8, b16, b32, b64:                                                                 types.Type_Id,
	f16le, f32le, f64le, f16be, f32be, f64be:                                          types.Type_Id,
	i16le, u16le, i32le, u32le, i64le, u64le, i128le, u128le:                          types.Type_Id,
	i16be, u16be, i32be, u32be, i64be, u64be, i128be, u128be:                          types.Type_Id,
	any_type, typeid_type:                                                             types.Type_Id,
}

// `int`, `uint` and `uintptr` carry their names so they stay distinct from `i64`, `u64` and each other, as in the official compiler.
seed_builtin_types :: proc(store: ^types.Store) -> Builtin_Types {
	return Builtin_Types {
		int = types.intern(store, types.Type{kind = .Integer, name = "int", count = types.DEFAULT_LAYOUT.int_size, signed = true}),
		uint = types.intern(store, types.Type{kind = .Integer, name = "uint", count = types.DEFAULT_LAYOUT.int_size}),
		uintptr = types.intern(store, types.Type{kind = .Integer, name = "uintptr", count = types.DEFAULT_LAYOUT.ptr_size}),
		i8 = types.sized_integer(store, 1, true),
		u8 = types.sized_integer(store, 1, false),
		i16 = types.sized_integer(store, 2, true),
		u16 = types.sized_integer(store, 2, false),
		i32 = types.sized_integer(store, 4, true),
		u32 = types.sized_integer(store, 4, false),
		i64 = types.sized_integer(store, 8, true),
		u64 = types.sized_integer(store, 8, false),
		i128 = types.sized_integer(store, 16, true),
		u128 = types.sized_integer(store, 16, false),
		boolean = types.intern(store, types.Type{kind = .Bool}),
		f32 = types.intern(store, types.Type{kind = .Float, count = 4}),
		f64 = types.intern(store, types.Type{kind = .Float, count = 8}),
		f16 = types.intern(store, types.Type{kind = .Float, count = 2}),
		b8 = types.intern(store, types.Type{kind = .Bool, count = 1}),
		b16 = types.intern(store, types.Type{kind = .Bool, count = 2}),
		b32 = types.intern(store, types.Type{kind = .Bool, count = 4}),
		b64 = types.intern(store, types.Type{kind = .Bool, count = 8}),
		f16le = types.intern(store, types.Type{kind = .Float, count = 2, endianness = .Little}),
		f32le = types.intern(store, types.Type{kind = .Float, count = 4, endianness = .Little}),
		f64le = types.intern(store, types.Type{kind = .Float, count = 8, endianness = .Little}),
		f16be = types.intern(store, types.Type{kind = .Float, count = 2, endianness = .Big}),
		f32be = types.intern(store, types.Type{kind = .Float, count = 4, endianness = .Big}),
		f64be = types.intern(store, types.Type{kind = .Float, count = 8, endianness = .Big}),
		i16le = types.intern(store, types.Type{kind = .Integer, name = "i16le", count = 2, signed = true, endianness = .Little}),
		u16le = types.intern(store, types.Type{kind = .Integer, name = "u16le", count = 2, endianness = .Little}),
		i32le = types.intern(store, types.Type{kind = .Integer, name = "i32le", count = 4, signed = true, endianness = .Little}),
		u32le = types.intern(store, types.Type{kind = .Integer, name = "u32le", count = 4, endianness = .Little}),
		i64le = types.intern(store, types.Type{kind = .Integer, name = "i64le", count = 8, signed = true, endianness = .Little}),
		u64le = types.intern(store, types.Type{kind = .Integer, name = "u64le", count = 8, endianness = .Little}),
		i128le = types.intern(store, types.Type{kind = .Integer, name = "i128le", count = 16, signed = true, endianness = .Little}),
		u128le = types.intern(store, types.Type{kind = .Integer, name = "u128le", count = 16, endianness = .Little}),
		i16be = types.intern(store, types.Type{kind = .Integer, name = "i16be", count = 2, signed = true, endianness = .Big}),
		u16be = types.intern(store, types.Type{kind = .Integer, name = "u16be", count = 2, endianness = .Big}),
		i32be = types.intern(store, types.Type{kind = .Integer, name = "i32be", count = 4, signed = true, endianness = .Big}),
		u32be = types.intern(store, types.Type{kind = .Integer, name = "u32be", count = 4, endianness = .Big}),
		i64be = types.intern(store, types.Type{kind = .Integer, name = "i64be", count = 8, signed = true, endianness = .Big}),
		u64be = types.intern(store, types.Type{kind = .Integer, name = "u64be", count = 8, endianness = .Big}),
		i128be = types.intern(store, types.Type{kind = .Integer, name = "i128be", count = 16, signed = true, endianness = .Big}),
		u128be = types.intern(store, types.Type{kind = .Integer, name = "u128be", count = 16, endianness = .Big}),
		complex32 = types.intern(store, types.Type{kind = .Complex, count = 4}),
		complex64 = types.intern(store, types.Type{kind = .Complex, count = 8}),
		complex128 = types.intern(store, types.Type{kind = .Complex, count = 16}),
		quaternion64 = types.intern(store, types.Type{kind = .Quaternion, count = 8}),
		quaternion128 = types.intern(store, types.Type{kind = .Quaternion, count = 16}),
		quaternion256 = types.intern(store, types.Type{kind = .Quaternion, count = 32}),
		rune = types.intern(store, types.Type{kind = .Rune, name = "rune", count = 4, signed = true}),
		rawptr = types.intern(store, types.Type{kind = .Raw_Pointer}),
		string_type = types.intern(store, types.Type{kind = .String}),
		cstring_type = types.intern(store, types.Type{kind = .CString}),
		string16_type = types.intern(store, types.Type{kind = .String16}),
		cstring16_type = types.intern(store, types.Type{kind = .CString16}),
		any_type = types.intern(store, types.Type{kind = .Any}),
		typeid_type = types.intern(store, types.Type{kind = .Type_Id}),
	}
}

// Binds each builtin type name as a resolved Type_Name in the universal scope.
bind_builtin_types :: proc(scopes: ^Scope_Store, universe: Scope_Id, builtins: Builtin_Types) -> Binding_Error {
	bindings := [?]struct {
		name: string,
		type: types.Type_Id,
	} {
		{"int", builtins.int},
		{"uint", builtins.uint},
		{"uintptr", builtins.uintptr},
		{"i8", builtins.i8},
		{"u8", builtins.u8},
		{"byte", builtins.u8},
		{"i16", builtins.i16},
		{"u16", builtins.u16},
		{"i32", builtins.i32},
		{"u32", builtins.u32},
		{"i64", builtins.i64},
		{"u64", builtins.u64},
		{"i128", builtins.i128},
		{"u128", builtins.u128},
		{"bool", builtins.boolean},
		{"f32", builtins.f32},
		{"f64", builtins.f64},
		{"f16", builtins.f16},
		{"b8", builtins.b8},
		{"b16", builtins.b16},
		{"b32", builtins.b32},
		{"b64", builtins.b64},
		{"f16le", builtins.f16le},
		{"f32le", builtins.f32le},
		{"f64le", builtins.f64le},
		{"f16be", builtins.f16be},
		{"f32be", builtins.f32be},
		{"f64be", builtins.f64be},
		{"i16le", builtins.i16le},
		{"u16le", builtins.u16le},
		{"i32le", builtins.i32le},
		{"u32le", builtins.u32le},
		{"i64le", builtins.i64le},
		{"u64le", builtins.u64le},
		{"i128le", builtins.i128le},
		{"u128le", builtins.u128le},
		{"i16be", builtins.i16be},
		{"u16be", builtins.u16be},
		{"i32be", builtins.i32be},
		{"u32be", builtins.u32be},
		{"i64be", builtins.i64be},
		{"u64be", builtins.u64be},
		{"i128be", builtins.i128be},
		{"u128be", builtins.u128be},
		{"complex32", builtins.complex32},
		{"complex64", builtins.complex64},
		{"complex128", builtins.complex128},
		{"quaternion64", builtins.quaternion64},
		{"quaternion128", builtins.quaternion128},
		{"quaternion256", builtins.quaternion256},
		{"rune", builtins.rune},
		{"rawptr", builtins.rawptr},
		{"string", builtins.string_type},
		{"cstring", builtins.cstring_type},
		{"string16", builtins.string16_type},
		{"cstring16", builtins.cstring16_type},
		{"any", builtins.any_type},
		{"typeid", builtins.typeid_type},
	}
	for binding in bindings {
		id, create_error := entity_create(scopes, Entity{name = binding.name, kind = .Type_Name, scope = universe, state = .Resolved, type = binding.type})
		if create_error != nil { return create_error }
		if _, insert_error := scope_insert(scopes, universe, id); insert_error != nil { return insert_error }
	}
	return nil
}

// Ids of the universal builtins are reserved by expression_checker_init.
UNIVERSE_LEN :: Builtin_Id(1)
UNIVERSE_CAP :: Builtin_Id(2)
UNIVERSE_SIZE_OF :: Builtin_Id(3)
UNIVERSE_ALIGN_OF :: Builtin_Id(4)
UNIVERSE_MIN :: Builtin_Id(5)
UNIVERSE_MAX :: Builtin_Id(6)
UNIVERSE_ABS :: Builtin_Id(7)
UNIVERSE_CLAMP :: Builtin_Id(8)
UNIVERSE_TYPEID_OF :: Builtin_Id(9)
UNIVERSE_UNREACHABLE :: Builtin_Id(10)
UNIVERSE_RAW_DATA :: Builtin_Id(11)
UNIVERSE_TYPE_INFO_OF :: Builtin_Id(13)
UNIVERSE_OFFSET_OF :: Builtin_Id(14)
UNIVERSE_OFFSET_OF_BY_STRING :: Builtin_Id(15)
UNIVERSE_COMPLEX :: Builtin_Id(16)
UNIVERSE_QUATERNION :: Builtin_Id(17)
UNIVERSE_REAL :: Builtin_Id(18)
UNIVERSE_IMAG :: Builtin_Id(19)
UNIVERSE_JMAG :: Builtin_Id(20)
UNIVERSE_KMAG :: Builtin_Id(21)
UNIVERSE_CONJ :: Builtin_Id(22)
UNIVERSE_SWIZZLE :: Builtin_Id(23)

// Binds the universal builtin procedures as builtin entities in the universal scope.
bind_universe_builtins :: proc(scopes: ^Scope_Store, universe: Scope_Id) -> Binding_Error {
	bindings := [?]struct {
		name:    string,
		builtin: Builtin_Id,
	} {
		{"len", UNIVERSE_LEN},
		{"cap", UNIVERSE_CAP},
		{"size_of", UNIVERSE_SIZE_OF},
		{"align_of", UNIVERSE_ALIGN_OF},
		{"min", UNIVERSE_MIN},
		{"max", UNIVERSE_MAX},
		{"abs", UNIVERSE_ABS},
		{"clamp", UNIVERSE_CLAMP},
		{"typeid_of", UNIVERSE_TYPEID_OF},
		{"type_info_of", UNIVERSE_TYPE_INFO_OF},
		{"unreachable", UNIVERSE_UNREACHABLE},
		{"raw_data", UNIVERSE_RAW_DATA},
		{"offset_of", UNIVERSE_OFFSET_OF},
		{"offset_of_by_string", UNIVERSE_OFFSET_OF_BY_STRING},
		{"complex", UNIVERSE_COMPLEX},
		{"quaternion", UNIVERSE_QUATERNION},
		{"real", UNIVERSE_REAL},
		{"imag", UNIVERSE_IMAG},
		{"jmag", UNIVERSE_JMAG},
		{"kmag", UNIVERSE_KMAG},
		{"conj", UNIVERSE_CONJ},
		{"swizzle", UNIVERSE_SWIZZLE},
	}
	for binding in bindings {
		id, create_error := entity_create(scopes, Entity{name = binding.name, kind = .Builtin, scope = universe, state = .Resolved, data = binding.builtin})
		if create_error != nil { return create_error }
		if _, insert_error := scope_insert(scopes, universe, id); insert_error != nil { return insert_error }
	}
	return nil
}

// Binds `true`, `false` and `nil` as untyped constants in the universal scope.
bind_universe_constants :: proc(scopes: ^Scope_Store, universe: Scope_Id, pool: ^Constant_Pool) -> bool {
	true_value, true_error := constant_pool_intern_bool(pool, true, types.TYPE_UNTYPED_BOOL)
	false_value, false_error := constant_pool_intern_bool(pool, false, types.TYPE_UNTYPED_BOOL)
	nil_value, nil_error := constant_pool_intern_nil(pool, types.TYPE_UNTYPED_NIL)
	if true_error != nil || false_error != nil || nil_error != nil { return false }
	bindings := [?]struct {
		name:  string,
		value: Const_Id,
		type:  types.Type_Id,
	}{{"true", true_value, types.TYPE_UNTYPED_BOOL}, {"false", false_value, types.TYPE_UNTYPED_BOOL}, {"nil", nil_value, types.TYPE_UNTYPED_NIL}}
	for binding in bindings {
		id, create_error := entity_create(
			scopes,
			Entity{name = binding.name, kind = .Constant, scope = universe, state = .Resolved, type = binding.type, constant = binding.value},
		)
		if create_error != nil { return false }
		if _, insert_error := scope_insert(scopes, universe, id); insert_error != nil { return false }
	}
	return true
}
