package check

import "core:testing"
import "oc:types"

// An untyped float scalar broadcasts into a fixed array from its converted element constant.
// The raw literal carries no usable type, so the plan source must be the folded f32 value.
@(test)
array_broadcast_keeps_converted_float_constant :: proc(t: ^testing.T) {
	pool: Constant_Pool
	if !testing.expect(t, constant_pool_init(&pool, context.allocator) == nil) { return }
	defer constant_pool_destroy(&pool)
	store := types.init()
	defer types.destroy(&store)
	f32_type := types.intern(&store, types.Type{kind = .Float, count = 4})
	array_type := types.intern(&store, types.Type{kind = .Array, elem = f32_type, count = 3})
	word := types.intern(&store, types.Type{kind = .Integer, name = "uintptr", count = 8})
	config := Conversion_Config {
		uintptr = word,
		layout  = types.DEFAULT_LAYOUT,
	}
	literal, literal_error := literal_constant(&pool, .Float, "0.5")
	if !testing.expect(t, literal_error == nil) { return }
	info := Expression_Info {
		type     = types.TYPE_UNTYPED_FLOAT,
		mode     = .Constant,
		state    = .Checked,
		constant = literal,
	}
	converted, diagnostic, err := check_conversion(&pool, &store, Operand(literal), info, array_type, .Assignment, config)
	if !testing.expect(t, err == nil && diagnostic == .None) { return }
	testing.expect(t, converted.info.type == array_type && converted.info.mode == .Value)
	if !testing.expect(t, converted.plan.kind == .Broadcast && converted.plan.source != Operand(literal)) { return }
	source, is_constant := converted.plan.source.(Const_Id)
	if !testing.expect(t, is_constant) { return }
	entry := constant_pool_get(&pool, source)
	if !testing.expect(t, entry != nil && entry.type == f32_type) { return }
	testing.expect_value(t, entry.value.(Float_Value), Float_Value{bits = transmute(u64)f64(0.5), width = 64})
}

// The splat reaches the innermost element through nested arrays.
@(test)
array_broadcast_splats_through_nested_arrays :: proc(t: ^testing.T) {
	pool: Constant_Pool
	if !testing.expect(t, constant_pool_init(&pool, context.allocator) == nil) { return }
	defer constant_pool_destroy(&pool)
	store := types.init()
	defer types.destroy(&store)
	f32_type := types.intern(&store, types.Type{kind = .Float, count = 4})
	inner := types.intern(&store, types.Type{kind = .Array, elem = f32_type, count = 2})
	outer := types.intern(&store, types.Type{kind = .Array, elem = inner, count = 2})
	word := types.intern(&store, types.Type{kind = .Integer, name = "uintptr", count = 8})
	config := Conversion_Config {
		uintptr = word,
		layout  = types.DEFAULT_LAYOUT,
	}
	literal, literal_error := literal_constant(&pool, .Float, "0.25")
	if !testing.expect(t, literal_error == nil) { return }
	info := Expression_Info {
		type     = types.TYPE_UNTYPED_FLOAT,
		mode     = .Constant,
		state    = .Checked,
		constant = literal,
	}
	converted, diagnostic, err := check_conversion(&pool, &store, Operand(literal), info, outer, .Assignment, config)
	if !testing.expect(t, err == nil && diagnostic == .None) { return }
	if !testing.expect(t, converted.plan.kind == .Broadcast) { return }
	source, is_constant := converted.plan.source.(Const_Id)
	if !testing.expect(t, is_constant) { return }
	entry := constant_pool_get(&pool, source)
	if !testing.expect(t, entry != nil && entry.type == f32_type) { return }
	testing.expect_value(t, entry.value.(Float_Value), Float_Value{bits = transmute(u64)f64(0.25), width = 64})
}

// Official: a float that is not representable as the element type is rejected.
@(test)
array_broadcast_rejects_unrepresentable_float :: proc(t: ^testing.T) {
	pool: Constant_Pool
	if !testing.expect(t, constant_pool_init(&pool, context.allocator) == nil) { return }
	defer constant_pool_destroy(&pool)
	store := types.init()
	defer types.destroy(&store)
	int_type := types.intern(&store, types.Type{kind = .Integer, count = 8, signed = true})
	array_type := types.intern(&store, types.Type{kind = .Array, elem = int_type, count = 3})
	word := types.intern(&store, types.Type{kind = .Integer, name = "uintptr", count = 8})
	config := Conversion_Config {
		uintptr = word,
		layout  = types.DEFAULT_LAYOUT,
	}
	literal, literal_error := literal_constant(&pool, .Float, "0.5")
	if !testing.expect(t, literal_error == nil) { return }
	info := Expression_Info {
		type     = types.TYPE_UNTYPED_FLOAT,
		mode     = .Constant,
		state    = .Checked,
		constant = literal,
	}
	_, diagnostic, err := check_conversion(&pool, &store, Operand(literal), info, array_type, .Assignment, config)
	testing.expect(t, err == nil && diagnostic == .Not_Representable)
}

// Official: unary plus and minus on a complex array work element-wise.
@(test)
unary_operators_apply_element_wise_to_complex_arrays :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
negate :: proc "contextless" (value: [2]complex128) -> [2]complex128 {
	_ = +value
	return -value
}
`)
	procedure, ok := check_procedure_source(t, source, procedure_name = "negate")
	if ok { testing.expect(t, procedure.body_state == .Complete) }
}

// Official: bitwise-not stays limited to integers, booleans, and bit sets.
@(test)
unary_bitwise_not_rejects_complex_arrays :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
flip :: proc "contextless" (value: [2]complex128) -> [2]complex128 {
	return ~value
}
`)
	_, ok := check_procedure_source(t, source, .Invalid_Operator, procedure_name = "flip")
	testing.expect(t, ok)
}
