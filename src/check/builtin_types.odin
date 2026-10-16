package check

import "oc:types"

Builtin_Types :: struct {
	int, uint, uintptr, i8, u8, i16, u16, i32, u32, i64, u64: types.Type_Id,
	boolean, f32, f64, rune, rawptr, string_type:             types.Type_Id,
}

// `int` and `uint` are unnamed, like the default-integer descriptor; `uintptr` is named so it stays distinct from `uint`.
seed_builtin_types :: proc(store: ^types.Store) -> Builtin_Types {
	return Builtin_Types {
		int = types.intern(store, types.Type{kind = .Integer, count = types.DEFAULT_LAYOUT.int_size, signed = true}),
		uint = types.intern(store, types.Type{kind = .Integer, count = types.DEFAULT_LAYOUT.int_size}),
		uintptr = types.intern(store, types.Type{kind = .Integer, name = "uintptr", count = types.DEFAULT_LAYOUT.ptr_size}),
		i8 = types.intern(store, types.Type{kind = .Integer, count = 1, signed = true}),
		u8 = types.intern(store, types.Type{kind = .Integer, count = 1}),
		i16 = types.intern(store, types.Type{kind = .Integer, count = 2, signed = true}),
		u16 = types.intern(store, types.Type{kind = .Integer, count = 2}),
		i32 = types.intern(store, types.Type{kind = .Integer, count = 4, signed = true}),
		u32 = types.intern(store, types.Type{kind = .Integer, count = 4}),
		i64 = types.intern(store, types.Type{kind = .Integer, count = 8, signed = true}),
		u64 = types.intern(store, types.Type{kind = .Integer, count = 8}),
		boolean = types.intern(store, types.Type{kind = .Bool}),
		f32 = types.intern(store, types.Type{kind = .Float, count = 4}),
		f64 = types.intern(store, types.Type{kind = .Float, count = 8}),
		rune = types.intern(store, types.Type{kind = .Rune, count = 4, signed = true}),
		rawptr = types.intern(store, types.Type{kind = .Raw_Pointer}),
		string_type = types.intern(store, types.Type{kind = .String}),
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
		{"bool", builtins.boolean},
		{"f32", builtins.f32},
		{"f64", builtins.f64},
		{"rune", builtins.rune},
		{"rawptr", builtins.rawptr},
		{"string", builtins.string_type},
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

// Binds `len` and `cap` as builtin entities in the universal scope.
bind_universe_builtins :: proc(scopes: ^Scope_Store, universe: Scope_Id) -> Binding_Error {
	bindings := [?]struct {
		name:    string,
		builtin: Builtin_Id,
	}{{"len", UNIVERSE_LEN}, {"cap", UNIVERSE_CAP}}
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
