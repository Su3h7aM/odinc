package check

import "core:math/big"
import "core:testing"
import "oc:types"

@(test)
conversions_preserve_identity_range_and_source :: proc(t: ^testing.T) {
	store := types.init()
	defer types.destroy(&store)
	pool: Constant_Pool
	if !testing.expect(t, constant_pool_init(&pool, context.allocator) == nil) { return }
	defer constant_pool_destroy(&pool)
	integer := types.intern(&store, types.Type{kind = .Integer, count = 8, signed = true})
	byte_type := types.intern(&store, types.Type{kind = .Integer, count = 1})
	unsigned := types.intern(&store, types.Type{kind = .Integer, count = 8})
	word := types.intern(&store, types.Type{kind = .Integer, name = "uintptr", count = 8})
	pointer := types.intern(&store, types.Type{kind = .Pointer, elem = byte_type})
	config := Conversion_Config {
		uintptr = word,
		layout  = types.DEFAULT_LAYOUT,
	}
	literal, literal_error := literal_constant(&pool, .Integer, "256")
	if !testing.expect(t, literal_error == nil) { return }
	info := Expression_Info {
		type     = types.TYPE_UNTYPED_INTEGER,
		constant = literal,
		mode     = .Constant,
		state    = .Checked,
	}
	value := Operand(Expression_Ref{view = 1, node = 2})
	_, diagnostic, err := check_conversion(&pool, &store, value, info, byte_type, .Assignment, config)
	testing.expect(t, err == nil && diagnostic == .Not_Representable)
	converted: Conversion_Result
	converted, diagnostic, err = check_conversion(&pool, &store, value, info, integer, .Assignment, config)
	testing.expect(t, err == nil && diagnostic == .None && converted.info.mode == .Constant)
	testing.expect(t, converted.plan.source == value && converted.plan.target == integer && info.type == types.TYPE_UNTYPED_INTEGER)
	info = Expression_Info {
		type  = integer,
		mode  = .Variable,
		state = .Checked,
	}
	_, diagnostic, err = check_conversion(&pool, &store, value, info, byte_type, .Assignment, config)
	testing.expect(t, err == nil && diagnostic == .Not_Assignable)
	converted, diagnostic, err = check_conversion(&pool, &store, value, info, byte_type, .Cast, config)
	testing.expect(t, err == nil && diagnostic == .None && converted.info.mode == .Value)
	_, diagnostic, err = check_conversion(&pool, &store, value, info, byte_type, .Transmute, config)
	testing.expect(t, err == nil && diagnostic == .Size_Mismatch)
	info.type = unsigned
	_, diagnostic, err = check_conversion(&pool, &store, value, info, pointer, .Cast, config)
	testing.expect(t, err == nil && diagnostic == .Not_Castable)
	info.type = word
	converted, diagnostic, err = check_conversion(&pool, &store, value, info, pointer, .Cast, config)
	testing.expect(t, err == nil && diagnostic == .None && converted.plan.source == value)
	info.type = types.TYPE_UNTYPED_INTEGER
	_, diagnostic, err = check_conversion(&pool, &store, value, info, integer, .Transmute, config)
	testing.expect(t, err == nil && diagnostic == .Untyped_Transmute)
	source_integer, source_error := literal_constant(&pool, .Integer, "200")
	if !testing.expect(t, source_error == nil) { return }
	transmuted_info := Expression_Info {
		type     = byte_type,
		constant = source_integer,
		mode     = .Constant,
		state    = .Checked,
	}
	signed_byte := types.intern(&store, types.Type{kind = .Integer, count = 1, signed = true})
	converted, diagnostic, err = check_conversion(&pool, &store, value, transmuted_info, signed_byte, .Transmute, config)
	testing.expect(t, err == nil && diagnostic == .None && converted.info.mode == .Constant && converted.info.type == signed_byte)
	if testing.expect(t, converted.info.constant != 0) {
		transmuted := constant_pool_get(&pool, converted.info.constant).value.(big.Int)
		bits, bits_error := big.int_get_i64(&transmuted)
		testing.expect(t, bits_error == nil && bits == -56)
	}
	set_type := types.intern(&store, types.Type{kind = .Bit_Set, backing = byte_type})
	converted, diagnostic, err = check_conversion(&pool, &store, value, transmuted_info, set_type, .Transmute, config)
	testing.expect(t, err == nil && diagnostic == .None && converted.info.mode == .Constant && converted.info.type == set_type)
	code_unit := types.intern(&store, types.Type{kind = .Integer, count = 2})
	info.type = types.intern(&store, types.Type{kind = .Slice, elem = code_unit})
	text16 := types.intern(&store, types.Type{kind = .String16})
	converted, diagnostic, err = check_conversion(&pool, &store, value, info, text16, .Cast, config)
	testing.expect(t, err == nil && diagnostic == .None && converted.info.type == text16)
	for kind in ([?]types.Kind{.Complex, .Quaternion}) {
		info.type = types.intern(&store, types.Type{kind = kind, count = 8})
		wide := types.intern(&store, types.Type{kind = kind, count = 16})
		converted, diagnostic, err = check_conversion(&pool, &store, value, info, wide, .Cast, config)
		testing.expect(t, err == nil && diagnostic == .None && converted.info.type == wide)
	}
	text, text_error := constant_pool_intern_string(&pool, "literal", types.TYPE_UNTYPED_STRING)
	if !testing.expect(t, text_error == nil) { return }
	info = Expression_Info {
		type     = types.TYPE_UNTYPED_STRING,
		mode     = .Constant,
		constant = text,
		state    = .Checked,
	}
	cstring_type := types.intern(&store, types.Type{kind = .CString})
	converted, diagnostic, err = check_conversion(&pool, &store, value, info, cstring_type, .Cast, config)
	testing.expect(t, err == nil && diagnostic == .None && converted.info.mode == .Constant && converted.info.type == cstring_type)
	info.type = types.intern(&store, types.Type{kind = .String})
	converted, diagnostic, err = check_conversion(&pool, &store, value, info, cstring_type, .Cast, config)
	testing.expect(t, err == nil && diagnostic == .None && converted.info.mode == .Constant && converted.info.type == cstring_type)
	converted, diagnostic, err = check_conversion(&pool, &store, value, info, cstring_type, .Assignment, config)
	testing.expect(t, err == nil && diagnostic == .None && converted.info.mode == .Constant && converted.info.type == cstring_type)
	testing.expect(t, converted.plan.source == Operand(converted.info.constant))
	info = Expression_Info {
		type  = integer,
		mode  = .Map_Index,
		state = .Checked,
	}
	any_type := types.intern(&store, types.Type{kind = .Any})
	converted, diagnostic, err = check_conversion(&pool, &store, value, info, any_type, .Assignment, config)
	testing.expect(t, err == nil && diagnostic == .None && converted.plan.kind == .Box && converted.plan.source == value)
}

@(test)
using_field_converts_to_embedded_type :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Allocator :: struct {data: rawptr}
Guard :: struct {using allocator: Allocator}
take :: proc "contextless" (allocator: Allocator) {}
main :: proc "contextless" () {
	guard: Guard
	take(guard)
}
`,
	)
	procedure, ok := check_procedure_source(t, source, diagnostic_count = 0)
	if ok { testing.expect(t, procedure.body_state == .Complete) }
}

@(test)
nil_converts_only_to_nilable_targets :: proc(t: ^testing.T) {
	store := types.init()
	defer types.destroy(&store)
	pool: Constant_Pool
	if !testing.expect(t, constant_pool_init(&pool, context.allocator) == nil) { return }
	defer constant_pool_destroy(&pool)
	byte_type := types.intern(&store, types.Type{kind = .Integer, count = 1})
	config := Conversion_Config {
		layout = types.DEFAULT_LAYOUT,
	}
	info := Expression_Info {
		type  = types.TYPE_UNTYPED_NIL,
		mode  = .Value,
		state = .Checked,
	}
	source := Operand(Expression_Ref{view = 1, node = 2})
	nilable := [?]types.Type {
		{kind = .Slice, elem = byte_type},
		{kind = .Dynamic_Array, elem = byte_type},
		{kind = .Map, elem = byte_type, index = byte_type},
		{kind = .Enum, backing = byte_type},
		{kind = .Bit_Set, elem = byte_type},
		{kind = .Any},
		{kind = .Type_Id},
		{kind = .Union, union_form = .Tagged},
		{kind = .Struct, soa = .Slice},
	}
	for descriptor in nilable {
		target := types.intern(&store, descriptor)
		converted, diagnostic, err := check_conversion(&pool, &store, source, info, target, .Assignment, config)
		testing.expect(t, err == nil && diagnostic == .None && converted.info.mode == .Constant && converted.info.type == target)
	}
	no_nil_union := types.intern(&store, types.Type{kind = .Union, union_form = .No_Nil})
	_, diagnostic, err := check_conversion(&pool, &store, source, info, no_nil_union, .Assignment, config)
	testing.expect(t, err == nil && diagnostic == .Not_Assignable)
}

@(test)
cast_unwraps_named_enums_and_converts_booleans_to_integers :: proc(t: ^testing.T) {
	store := types.init()
	defer types.destroy(&store)
	pool: Constant_Pool
	if !testing.expect(t, constant_pool_init(&pool, context.allocator) == nil) { return }
	defer constant_pool_destroy(&pool)
	byte_type := types.intern(&store, types.Type{kind = .Integer, count = 1})
	unsigned := types.intern(&store, types.Type{kind = .Integer, count = 8})
	boolean := types.intern(&store, types.Type{kind = .Bool, count = 1})
	enum_type := types.intern(&store, types.Type{kind = .Enum, backing = byte_type})
	mode := types.intern(&store, types.Type{kind = .Named, name = "Mode", elem = enum_type})
	config := Conversion_Config {
		layout = types.DEFAULT_LAYOUT,
	}
	value := Operand(Expression_Ref{view = 1, node = 2})
	info := Expression_Info {
		type  = mode,
		mode  = .Value,
		state = .Checked,
	}
	_, diagnostic, err := check_conversion(&pool, &store, value, info, unsigned, .Cast, config)
	testing.expect(t, err == nil && diagnostic == .None)
	info.type = boolean
	_, diagnostic, err = check_conversion(&pool, &store, value, info, unsigned, .Cast, config)
	testing.expect(t, err == nil && diagnostic == .None)
}

@(test)
untyped_constant_converts_to_the_only_union_variant_that_accepts_it :: proc(t: ^testing.T) {
	store := types.init()
	defer types.destroy(&store)
	pool: Constant_Pool
	if !testing.expect(t, constant_pool_init(&pool, context.allocator) == nil) { return }
	defer constant_pool_destroy(&pool)
	config := Conversion_Config {
		layout = types.DEFAULT_LAYOUT,
	}
	integer := types.intern(&store, types.Type{kind = .Integer, name = "int", count = 8, signed = true})
	text := types.intern(&store, types.Type{kind = .String})
	unique_variants := [?]types.Type_Id{integer, text}
	unique := types.intern(&store, types.Type{kind = .Union, union_form = .Tagged, variants = unique_variants[:]})
	narrow := types.intern(&store, types.Type{kind = .Integer, count = 4, signed = true})
	wide := types.intern(&store, types.Type{kind = .Integer, name = "i64", count = 8, signed = true})
	ambiguous_variants := [?]types.Type_Id{narrow, wide}
	ambiguous := types.intern(&store, types.Type{kind = .Union, union_form = .Tagged, variants = ambiguous_variants[:]})
	default_variants := [?]types.Type_Id{narrow, integer}
	defaulted := types.intern(&store, types.Type{kind = .Union, union_form = .Tagged, variants = default_variants[:]})
	literal, literal_error := literal_constant(&pool, .Integer, "123")
	if !testing.expect(t, literal_error == nil) { return }
	info := Expression_Info {
		type     = types.TYPE_UNTYPED_INTEGER,
		constant = literal,
		mode     = .Constant,
		state    = .Checked,
	}
	value := Operand(Expression_Ref{view = 1, node = 2})
	converted, diagnostic, err := check_conversion(&pool, &store, value, info, unique, .Assignment, config)
	testing.expect(t, err == nil && diagnostic == .None && converted.info.type == unique)
	testing.expect(t, converted.plan.kind == .Union_Injection && converted.plan.target == unique)
	converted, diagnostic, err = check_conversion(&pool, &store, value, info, unique, .Cast, config)
	testing.expect(t, err == nil && diagnostic == .None && converted.plan.kind == .Union_Injection)
	typed := Expression_Info {
		type  = integer,
		mode  = .Value,
		state = .Checked,
	}
	converted, diagnostic, err = check_conversion(&pool, &store, value, typed, unique, .Cast, config)
	testing.expect(t, err == nil && diagnostic == .None && converted.plan.kind == .Union_Injection)
	_, diagnostic, err = check_conversion(&pool, &store, value, info, ambiguous, .Assignment, config)
	testing.expect(t, err == nil && diagnostic == .Not_Assignable)
	converted, diagnostic, err = check_conversion(&pool, &store, value, info, defaulted, .Assignment, config)
	testing.expect(t, err == nil && diagnostic == .None && converted.plan.target == defaulted)
}

@(test)
untyped_scalar_broadcasts_to_arrays_through_the_element_type :: proc(t: ^testing.T) {
	store := types.init()
	defer types.destroy(&store)
	pool: Constant_Pool
	if !testing.expect(t, constant_pool_init(&pool, context.allocator) == nil) { return }
	defer constant_pool_destroy(&pool)
	config := Conversion_Config {
		layout = types.DEFAULT_LAYOUT,
	}
	byte_type := types.intern(&store, types.Type{kind = .Integer, count = 1})
	bytes_type := types.intern(&store, types.Type{kind = .Array, elem = byte_type, count = 4})
	literal, literal_error := literal_constant(&pool, .Integer, "0")
	if !testing.expect(t, literal_error == nil) { return }
	info := Expression_Info {
		type     = types.TYPE_UNTYPED_INTEGER,
		constant = literal,
		mode     = .Constant,
		state    = .Checked,
	}
	value := Operand(Expression_Ref{view = 1, node = 2})
	converted, diagnostic, err := check_conversion(&pool, &store, value, info, bytes_type, .Assignment, config)
	testing.expect(t, err == nil && diagnostic == .None)
	testing.expect(t, converted.info.type == bytes_type && converted.info.mode == .Value)
	testing.expect(t, converted.plan.kind == .Broadcast && converted.plan.target == bytes_type)
	wide, wide_error := literal_constant(&pool, .Integer, "300")
	if !testing.expect(t, wide_error == nil) { return }
	info.constant = wide
	_, diagnostic, err = check_conversion(&pool, &store, value, info, bytes_type, .Assignment, config)
	testing.expect(t, err == nil && diagnostic == .Not_Representable)
}

@(test)
named_procedure_assignment_requires_matching_top_level_signatures :: proc(t: ^testing.T) {
	store := types.init()
	defer types.destroy(&store)
	pool: Constant_Pool
	if !testing.expect(t, constant_pool_init(&pool, context.allocator) == nil) { return }
	defer constant_pool_destroy(&pool)
	integer := types.intern(&store, types.Type{kind = .Integer, count = 8, signed = true})
	string_type := types.intern(&store, types.Type{kind = .String})
	parameters := [1]types.Type_Id{integer}
	wrong_parameters := [1]types.Type_Id{string_type}
	results := [1]types.Type_Id{integer}
	procedure := types.intern(&store, types.Type{kind = .Procedure, params = parameters[:], results = results[:]})
	string_procedure := types.intern(&store, types.Type{kind = .Procedure, params = wrong_parameters[:], results = results[:]})
	named_a := types.reserve_nominal(&store, .Named, "A")
	named_b := types.reserve_nominal(&store, .Named, "B")
	named_wrong := types.reserve_nominal(&store, .Named, "Wrong")
	types.complete_nominal(&store, named_a, types.Type{kind = .Named, name = "A", elem = procedure})
	types.complete_nominal(&store, named_b, types.Type{kind = .Named, name = "B", elem = procedure})
	types.complete_nominal(&store, named_wrong, types.Type{kind = .Named, name = "Wrong", elem = string_procedure})
	value := Operand(Expression_Ref{view = 1, node = 2})
	config := Conversion_Config {
		layout = types.DEFAULT_LAYOUT,
	}
	info := Expression_Info {
		type  = procedure,
		mode  = .Value,
		state = .Checked,
	}
	_, diagnostic, err := check_conversion(&pool, &store, value, info, named_a, .Assignment, config)
	testing.expect(t, err == nil && diagnostic == .None)
	info.type = named_a
	_, diagnostic, err = check_conversion(&pool, &store, value, info, named_b, .Assignment, config)
	testing.expect(t, err == nil && diagnostic == .None)
	_, diagnostic, err = check_conversion(&pool, &store, value, info, procedure, .Assignment, config)
	testing.expect(t, err == nil && diagnostic == .None)
	_, diagnostic, err = check_conversion(&pool, &store, value, info, named_b, .Cast, config)
	testing.expect(t, err == nil && diagnostic == .None)
	_, diagnostic, err = check_conversion(&pool, &store, value, info, named_wrong, .Assignment, config)
	testing.expect(t, err == nil && diagnostic == .Not_Assignable)
	procedure_slice := types.intern(&store, types.Type{kind = .Slice, elem = procedure})
	named_slice := types.intern(&store, types.Type{kind = .Slice, elem = named_a})
	info.type = procedure_slice
	_, diagnostic, err = check_conversion(&pool, &store, value, info, named_slice, .Assignment, config)
	testing.expect(t, err == nil && diagnostic == .Not_Assignable)
}

@(test)
named_procedure_assignment_rejects_a_different_signature :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Callback :: proc(value: int) -> int
wrong :: proc(value: string) -> int { return 0 }
main :: proc() {
	callback: Callback = wrong
}
`,
	)
	_, ok := check_procedure_source(t, source, .Mismatched_Types)
	testing.expect(t, ok)
}
