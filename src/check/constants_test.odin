package check

import "core:math/big"
import "core:testing"
import "oc:syntax"
import "oc:types"

@(test)
constant_pool_interns_canonical_owned_numbers :: proc(t: ^testing.T) {
	zero_pool: Constant_Pool
	constant_pool_destroy(&zero_pool)
	pool: Constant_Pool
	testing.expect(t, constant_pool_init(&pool, context.allocator) == nil)
	defer constant_pool_destroy(&pool)

	integer: big.Int
	defer big.int_destroy(&integer)
	testing.expect(t, big.int_set_from_integer(&integer, 123) == nil)
	integer_id, err := constant_pool_intern_integer(&pool, &integer)
	testing.expect(t, err == nil && integer_id != 0)
	testing.expect(t, big.int_set_from_integer(&integer, 124) == nil)
	stored_integer := constant_pool_get(&pool, integer_id)
	stored_number := stored_integer.value.(big.Int)
	equal, compare_error := big.int_equals_digit(&stored_number, 123)
	testing.expect(t, compare_error == nil && equal)

	duplicate_integer: big.Int
	defer big.int_destroy(&duplicate_integer)
	testing.expect(t, big.int_set_from_integer(&duplicate_integer, 123) == nil)
	duplicate_id: Const_Id
	duplicate_id, err = constant_pool_intern_integer(&pool, &duplicate_integer)
	testing.expect(t, err == nil && duplicate_id == integer_id)

	fraction: big.Rat
	defer big.destroy(&fraction)
	testing.expect(t, big.rat_set_frac(&fraction, 2, 4) == nil)
	fraction_id: Const_Id
	fraction_id, err = constant_pool_intern_rational(&pool, &fraction)
	testing.expect(t, err == nil && fraction_id != 0)
	testing.expect(t, big.rat_set_frac(&fraction, 2, 3) == nil)
	canonical_fraction: big.Rat
	testing.expect(t, big.rat_set_frac(&canonical_fraction, 1, 2) == nil)
	defer big.destroy(&canonical_fraction)
	canonical_id: Const_Id
	canonical_id, err = constant_pool_intern_rational(&pool, &canonical_fraction)
	testing.expect(t, err == nil && canonical_id == fraction_id)
	stored_rational := constant_pool_get(&pool, fraction_id).value.(big.Rat)
	numerator_is_one, numerator_error := big.int_equals_digit(&stored_rational.a, 1)
	denominator_is_two, denominator_error := big.int_equals_digit(&stored_rational.b, 2)
	testing.expect(t, numerator_error == nil && denominator_error == nil && numerator_is_one && denominator_is_two)
	invalid_rational: big.Rat
	_, err = constant_pool_intern_rational(&pool, &invalid_rational)
	testing.expect(t, err == big.Error.Division_by_Zero)

	different_type_id: Const_Id
	different_type_id, err = constant_pool_intern_integer(&pool, &duplicate_integer, types.Type_Id(1))
	testing.expect(t, err == nil && different_type_id != integer_id)
	testing.expect(t, constant_pool_get(&pool, 0) == nil && constant_pool_get(&pool, 0xffff_ffff) == nil)
}

@(test)
constant_operators_fold_and_intern_results :: proc(t: ^testing.T) {
	pool: Constant_Pool
	testing.expect(t, constant_pool_init(&pool, context.allocator) == nil)
	defer constant_pool_destroy(&pool)

	left_value, right_value: big.Int
	defer big.int_destroy(&left_value, &right_value)
	testing.expect(t, big.int_set_from_integer(&left_value, -17) == nil)
	testing.expect(t, big.int_set_from_integer(&right_value, 5) == nil)
	left, left_error := constant_pool_intern_integer(&pool, &left_value)
	right, right_error := constant_pool_intern_integer(&pool, &right_value)
	testing.expect(t, left_error == nil && right_error == nil)

	quotient, operation_error := constant_binary_operator(&pool, .Quo, left, right)
	testing.expect(t, operation_error == nil)
	quotient_value := constant_pool_get(&pool, quotient).value.(big.Int)
	quotient_integer, conversion_error := big.int_get_i64(&quotient_value)
	testing.expect(t, conversion_error == nil && quotient_integer == -3)

	comparison, comparison_error := constant_compare_operator(&pool, .Lt, left, right)
	testing.expect(t, comparison_error == nil && constant_pool_get(&pool, comparison).value.(bool))

	true_value, true_error := constant_pool_intern_bool(&pool, true)
	false_value, false_error := constant_pool_intern_bool(&pool, false)
	logical, logical_error := constant_binary_operator(&pool, .Cmp_And, true_value, false_value)
	testing.expect(t, true_error == nil && false_error == nil && logical_error == nil)
	testing.expect(t, !constant_pool_get(&pool, logical).value.(bool))

	first, first_error := constant_pool_intern_string(&pool, "Odin")
	second, second_error := constant_pool_intern_string(&pool, " compiler")
	joined, join_error := constant_binary_operator(&pool, .Add, first, second)
	testing.expect(t, first_error == nil && second_error == nil && join_error == nil)
	testing.expect(t, constant_pool_get(&pool, joined).value.(string) == "Odin compiler")

	first_utf16 := []u16{'O', 'd', 'i', 'n'}
	second_utf16 := []u16{' ', 'c', 'o', 'm', 'p', 'i', 'l', 'e', 'r'}
	first16, first16_error := constant_pool_intern_string16(&pool, first_utf16)
	second16, second16_error := constant_pool_intern_string16(&pool, second_utf16)
	joined16, join16_error := constant_binary_operator(&pool, .Add, first16, second16)
	testing.expect(t, first16_error == nil && second16_error == nil && join16_error == nil)
	joined16_value := constant_pool_get(&pool, joined16).value.([]u16)
	expected16 := []u16{'O', 'd', 'i', 'n', ' ', 'c', 'o', 'm', 'p', 'i', 'l', 'e', 'r'}
	testing.expect(t, len(joined16_value) == len(expected16))
	for i in 0 ..< len(expected16) {
		testing.expect(t, joined16_value[i] == expected16[i])
	}

	type_store := types.init()
	defer types.destroy(&type_store)
	i8 := types.intern(&type_store, types.Type{kind = .Integer, count = 1, signed = true})
	max_value: big.Int
	one: big.Int
	defer big.int_destroy(&max_value, &one)
	testing.expect(t, big.int_set_from_integer(&max_value, 127) == nil)
	testing.expect(t, big.int_set_from_integer(&one, 1) == nil)
	max_id, max_error := constant_pool_intern_integer(&pool, &max_value, i8)
	one_id, one_error := constant_pool_intern_integer(&pool, &one, i8)
	_, overflow_error := constant_binary_operator(&pool, .Add, max_id, one_id, i8, type_store = &type_store)
	testing.expect(t, max_error == nil && one_error == nil && overflow_error == Constant_Operation_Error_Kind.Not_Representable)
	complex, complex_error := constant_pool_intern_complex(&pool, Complex_Value{max_id, one_id})
	_, complex_binary_error := constant_binary_operator(&pool, .Add, complex, complex)
	_, complex_unary_error := constant_unary_operator(&pool, .Add, complex)
	testing.expect(t, complex_error == nil && complex_binary_error == nil)
	testing.expect(t, complex_unary_error == Constant_Operation_Error_Kind.Unsupported_Constant_Op)
	quaternion, quaternion_error := constant_pool_intern_quaternion(&pool, Quaternion_Value{max_id, one_id, max_id, one_id})
	_, quaternion_binary_error := constant_binary_operator(&pool, .Mul, quaternion, quaternion)
	testing.expect(t, quaternion_error == nil && quaternion_binary_error == Constant_Operation_Error_Kind.Unsupported_Constant_Op)
}
@(test)
constant_compare_folds_mixed_representations :: proc(t: ^testing.T) {
	pool: Constant_Pool
	testing.expect(t, constant_pool_init(&pool, context.allocator) == nil)
	defer constant_pool_destroy(&pool)

	five: big.Int
	defer big.int_destroy(&five)
	testing.expect(t, big.int_set_from_integer(&five, 5) == nil)
	five_id, five_error := constant_pool_intern_integer(&pool, &five)
	testing.expect(t, five_error == nil)

	five_rational: big.Rat
	defer big.destroy(&five_rational)
	testing.expect(t, big.rat_set_frac(&five_rational, 5, 1) == nil)
	five_rational_id, five_rational_error := constant_pool_intern_rational(&pool, &five_rational)
	testing.expect(t, five_rational_error == nil)

	eleven_halves: big.Rat
	defer big.destroy(&eleven_halves)
	testing.expect(t, big.rat_set_frac(&eleven_halves, 11, 2) == nil)
	eleven_halves_id, eleven_halves_error := constant_pool_intern_rational(&pool, &eleven_halves)
	testing.expect(t, eleven_halves_error == nil)

	third: big.Rat
	defer big.destroy(&third)
	testing.expect(t, big.rat_set_frac(&third, 1, 3) == nil)
	third_id, third_error := constant_pool_intern_rational(&pool, &third)
	testing.expect(t, third_error == nil)

	half: big.Rat
	defer big.destroy(&half)
	testing.expect(t, big.rat_set_frac(&half, 1, 2) == nil)
	half_id, half_error := constant_pool_intern_rational(&pool, &half)
	testing.expect(t, half_error == nil)

	five_float_id, five_float_error := constant_pool_intern_float(&pool, Float_Value{bits = transmute(u64)f64(5), width = 64})
	testing.expect(t, five_float_error == nil)

	large: big.Int
	defer big.int_destroy(&large)
	testing.expect(t, big.int_set_from_integer(&large, 9007199254740993) == nil)
	large_id, large_error := constant_pool_intern_integer(&pool, &large)
	testing.expect(t, large_error == nil)

	large_rational: big.Rat
	defer big.destroy(&large_rational)
	testing.expect(t, big.rat_set_frac(&large_rational, 9007199254740993, 1) == nil)
	large_rational_id, large_rational_error := constant_pool_intern_rational(&pool, &large_rational)
	testing.expect(t, large_rational_error == nil)

	large_even_rational: big.Rat
	defer big.destroy(&large_even_rational)
	testing.expect(t, big.rat_set_frac(&large_even_rational, 9007199254740992, 1) == nil)
	large_even_rational_id, large_even_rational_error := constant_pool_intern_rational(&pool, &large_even_rational)
	testing.expect(t, large_even_rational_error == nil)

	rounded_float_id, rounded_float_error := constant_pool_intern_float(&pool, Float_Value{bits = transmute(u64)f64(9007199254740992), width = 64})
	testing.expect(t, rounded_float_error == nil)

	Case :: struct {
		operator: syntax.Token_Kind,
		left:     Const_Id,
		right:    Const_Id,
		want:     bool,
	}
	// Each row matches the official compiler's `when` probe for the same operands.
	cases := []Case {
		{.Eq, five_id, five_rational_id, true},
		{.Lt, five_id, eleven_halves_id, true},
		{.Gt, eleven_halves_id, five_id, true},
		{.Lt_Eq, five_id, five_rational_id, true},
		{.Gt_Eq, five_id, eleven_halves_id, false},
		{.Not_Eq, five_id, eleven_halves_id, true},
		{.Lt, third_id, half_id, true},
		{.Gt, half_id, third_id, true},
		{.Not_Eq, third_id, half_id, true},
		{.Eq, five_float_id, five_id, true},
		{.Eq, five_float_id, five_rational_id, true},
		{.Eq, large_id, large_rational_id, true},
		{.Eq, large_id, large_even_rational_id, false},
		{.Gt, large_id, large_even_rational_id, true},
		{.Not_Eq, large_id, large_even_rational_id, true},
		{.Eq, rounded_float_id, large_id, true},
		{.Eq, rounded_float_id, large_rational_id, true},
		{.Lt, rounded_float_id, large_rational_id, false},
	}
	for &c in cases {
		result_id, compare_error := constant_compare_operator(&pool, c.operator, c.left, c.right)
		testing.expect(t, compare_error == nil)
		if compare_error != nil { continue }
		testing.expect(t, constant_pool_get(&pool, result_id).value.(bool) == c.want)
	}
}
