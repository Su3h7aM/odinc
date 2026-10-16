package check

import "core:math/big"
import "core:testing"
import "oc:types"

@(test)
numeric_conversions_check_ranges_and_rounding :: proc(t: ^testing.T) {
	pool: Constant_Pool
	testing.expect(t, constant_pool_init(&pool, context.allocator) == nil)
	defer constant_pool_destroy(&pool)
	type_store := types.init()
	defer types.destroy(&type_store)

	i8_type := types.intern(&type_store, types.Type{kind = .Integer, count = 1, signed = true})
	i64_type := types.intern(&type_store, types.Type{kind = .Integer, count = 8, signed = true})
	f16_type := types.intern(&type_store, types.Type{kind = .Float, count = 2})
	f32_type := types.intern(&type_store, types.Type{kind = .Float, count = 4})
	f64_type := types.intern(&type_store, types.Type{kind = .Float, count = 8})
	complex64 := types.intern(&type_store, types.Type{kind = .Complex, count = 8})
	untyped_float_type := types.intern(&type_store, types.Type{kind = .Untyped_Float})
	untyped_rune_type := types.intern(&type_store, types.Type{kind = .Untyped_Rune})

	integer: big.Int
	defer big.int_destroy(&integer)
	testing.expect(t, big.int_set_from_integer(&integer, 123) == nil)
	integer_id, integer_error := constant_pool_intern_integer(&pool, &integer, i64_type)
	converted_id, conversion_error := numeric_convert_constant(&pool, &type_store, integer_id, i64_type, i8_type)
	testing.expect(t, integer_error == nil && conversion_error.kind == .None)
	converted_integer := constant_pool_get(&pool, converted_id).value.(big.Int)
	converted_number, number_error := big.int_get_i64(&converted_integer)
	testing.expect(t, number_error == nil && converted_number == 123)
	untyped_rune_id, untyped_rune_error := constant_pool_intern_integer(&pool, &integer, untyped_rune_type)
	promoted_rune_id, promotion_error := numeric_convert_constant(&pool, &type_store, untyped_rune_id, untyped_rune_type, types.TYPE_NONE)
	testing.expect(t, untyped_rune_error == nil && promotion_error.kind == .None)
	testing.expect(t, constant_pool_get(&pool, promoted_rune_id).type == types.default_type_of_untyped(&type_store, untyped_rune_type))

	testing.expect(t, big.int_set_from_integer(&integer, 16777217) == nil)
	integer_float_id, integer_float_error := constant_pool_intern_integer(&pool, &integer, i64_type)
	rounded_integer_id, rounded_integer_error := numeric_convert_constant(&pool, &type_store, integer_float_id, i64_type, f32_type)
	testing.expect(t, integer_float_error == nil && rounded_integer_error.kind == .None)
	testing.expect_value(
		t,
		constant_pool_get(&pool, rounded_integer_id).value.(Float_Value),
		Float_Value{bits = transmute(u64)f64(f64(f32(16777217))), width = 64},
	)

	testing.expect(t, big.int_set_from_integer(&integer, 128) == nil)
	too_large_id, too_large_error := constant_pool_intern_integer(&pool, &integer, i64_type)
	_, range_error := numeric_convert_constant(&pool, &type_store, too_large_id, i64_type, i8_type)
	testing.expect(t, too_large_error == nil && range_error.kind == .Numeric_Conversion_Not_Representable)
	testing.expect(t, big.int_set_from_integer(&integer, 65536) == nil)
	half_overflow_id, half_overflow_source_error := constant_pool_intern_integer(&pool, &integer, i64_type)
	_, half_overflow_error := numeric_convert_constant(&pool, &type_store, half_overflow_id, i64_type, f16_type)
	testing.expect(t, half_overflow_source_error == nil && half_overflow_error.kind == .Numeric_Conversion_Not_Representable)

	rational_id, rational_error := literal_constant(&pool, .Float, "0.1")
	rounded_id, rounded_error := numeric_convert_constant(&pool, &type_store, rational_id, untyped_float_type, f32_type)
	testing.expect(t, rational_error == nil && rounded_error.kind == .None)
	rounded := constant_pool_get(&pool, rounded_id).value.(Float_Value)
	expected_f32 := Float_Value {
		bits  = transmute(u64)f64(f64(f32(0.1))),
		width = 64,
	}
	testing.expect_value(t, rounded, expected_f32)
	rounded64_id, rounded64_error := numeric_convert_constant(&pool, &type_store, rational_id, untyped_float_type, f64_type)
	testing.expect(t, rounded64_error.kind == .None)
	testing.expect_value(t, constant_pool_get(&pool, rounded64_id).value.(Float_Value), Float_Value{bits = transmute(u64)f64(0.1), width = 64})
	rounded16_id, rounded16_error := numeric_convert_constant(&pool, &type_store, rational_id, untyped_float_type, f16_type)
	testing.expect(t, rounded16_error.kind == .None)
	rounded16 := constant_pool_get(&pool, rounded16_id).value.(Float_Value)
	testing.expect_value(t, rounded16, Float_Value{bits = transmute(u64)f64(f64(f16(0.1))), width = 64})

	float_source_id, float_source_error := constant_pool_intern_float(&pool, Float_Value{bits = transmute(u64)f64(0.1), width = 64}, f64_type)
	float_rounded_id, float_rounded_error := numeric_convert_constant(&pool, &type_store, float_source_id, f64_type, f32_type)
	testing.expect(t, float_source_error == nil && float_rounded_error.kind == .None)
	testing.expect_value(t, constant_pool_get(&pool, float_rounded_id).value.(Float_Value), Float_Value{bits = transmute(u64)f64(f64(f32(0.1))), width = 64})

	exact_float_id, exact_float_error := constant_pool_intern_float(&pool, Float_Value{bits = transmute(u64)f64(42), width = 64}, f64_type)
	exact_integer_id, exact_conversion_error := numeric_convert_constant(&pool, &type_store, exact_float_id, f64_type, i8_type)
	testing.expect(t, exact_float_error == nil && exact_conversion_error.kind == .None)
	integer_float := constant_pool_get(&pool, exact_integer_id).value.(big.Int)
	integer_float_value, integer_float_get_error := big.int_get_i64(&integer_float)
	testing.expect(t, integer_float_get_error == nil && integer_float_value == 42)

	inexact_float_id, inexact_float_error := constant_pool_intern_float(&pool, Float_Value{bits = transmute(u64)f64(42.5), width = 64}, f64_type)
	_, truncation_error := numeric_convert_constant(&pool, &type_store, inexact_float_id, f64_type, i8_type)
	testing.expect(t, inexact_float_error == nil && truncation_error.kind == .Truncated)

	complex_id, complex_error := numeric_convert_constant(&pool, &type_store, rational_id, untyped_float_type, complex64)
	testing.expect(t, complex_error.kind == .None)
	complex_value := constant_pool_get(&pool, complex_id).value.(Complex_Value)
	expected_component := expected_f32
	testing.expect_value(t, constant_pool_get(&pool, complex_value[0]).value.(Float_Value), expected_component)
	testing.expect_value(t, constant_pool_get(&pool, complex_value[1]).value.(Float_Value), Float_Value{bits = transmute(u64)f64(0), width = 64})
}
