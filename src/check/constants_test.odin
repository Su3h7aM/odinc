package check

import "core:math/big"
import "core:testing"
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
	testing.expect(t, complex_error == nil && complex_binary_error == Constant_Operation_Error_Kind.Unsupported_Constant_Op)
	testing.expect(t, complex_unary_error == Constant_Operation_Error_Kind.Unsupported_Constant_Op)
	quaternion, quaternion_error := constant_pool_intern_quaternion(&pool, Quaternion_Value{max_id, one_id, max_id, one_id})
	_, quaternion_binary_error := constant_binary_operator(&pool, .Mul, quaternion, quaternion)
	testing.expect(t, quaternion_error == nil && quaternion_binary_error == Constant_Operation_Error_Kind.Unsupported_Constant_Op)
}
