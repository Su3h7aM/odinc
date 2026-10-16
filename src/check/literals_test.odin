package check

import "core:math/big"
import "core:testing"
import "oc:syntax"

@(test)
literals_normalize_exact_numeric_values :: proc(t: ^testing.T) {
	pool: Constant_Pool
	testing.expect(t, constant_pool_init(&pool, context.allocator) == nil)
	defer constant_pool_destroy(&pool)
	err: Literal_Error

	integer_cases := [][2]string{{"0b1010", "10"}, {"0o17", "15"}, {"0xFF", "255"}, {"0z1b", "23"}, {"0d12", "12"}, {"1_234", "1234"}, {"1e+2", "100"}}
	for test_case in integer_cases {
		kind := syntax.Token_Kind.Integer
		if test_case[0] == "1e+2" { kind = .Float }
		id: Const_Id
		id, err = literal_constant(&pool, kind, test_case[0])
		testing.expect(t, err == nil && id != 0)
		stored := constant_pool_get(&pool, id).value.(big.Int)
		text, conversion_error := big.int_to_string(&stored, 10, allocator = context.temp_allocator)
		testing.expect(t, conversion_error == nil && text == test_case[1])
	}

	fraction_id: Const_Id
	fraction_id, err = literal_constant(&pool, .Float, "1.25")
	testing.expect(t, err == nil)
	fraction := constant_pool_get(&pool, fraction_id).value.(big.Rat)
	numerator_is_five, numerator_error := big.int_equals_digit(&fraction.a, 5)
	denominator_is_four, denominator_error := big.int_equals_digit(&fraction.b, 4)
	testing.expect(t, numerator_error == nil && denominator_error == nil && numerator_is_five && denominator_is_four)

	exponent_id: Const_Id
	exponent_id, err = literal_constant(&pool, .Float, "1e-1")
	testing.expect(t, err == nil)
	exponent_value := constant_pool_get(&pool, exponent_id).value.(big.Rat)
	exponent_numerator_is_one, exponent_numerator_error := big.int_equals_digit(&exponent_value.a, 1)
	exponent_denominator_is_ten, exponent_denominator_error := big.int_equals_digit(&exponent_value.b, 10)
	testing.expect(t, exponent_numerator_error == nil && exponent_denominator_error == nil && exponent_numerator_is_one && exponent_denominator_is_ten)

	hex_float_id: Const_Id
	hex_float_id, err = literal_constant(&pool, .Float, "0h3c00")
	testing.expect(t, err == nil)
	hex_float := constant_pool_get(&pool, hex_float_id).value.(Float_Value)
	testing.expect_value(t, hex_float, Float_Value{bits = transmute(u64)f64(1), width = 64})
	positive_zero_id: Const_Id
	positive_zero_id, err = literal_constant(&pool, .Float, "0h0000")
	testing.expect(t, err == nil)
	negative_zero_id: Const_Id
	negative_zero_id, err = literal_constant(&pool, .Float, "0h8000")
	testing.expect(t, err == nil && negative_zero_id != positive_zero_id)
	nan_id: Const_Id
	nan_id, err = literal_constant(&pool, .Float, "0h7ff8000000000001")
	testing.expect(t, err == nil)
	different_nan_id: Const_Id
	different_nan_id, err = literal_constant(&pool, .Float, "0h7ff8000000000002")
	testing.expect(t, err == nil && different_nan_id != nan_id)

	imaginary_id: Const_Id
	imaginary_id, err = literal_constant(&pool, .Imag, "2i")
	testing.expect(t, err == nil)
	duplicate_imaginary_id: Const_Id
	duplicate_imaginary_id, err = literal_constant(&pool, .Imag, "2i")
	testing.expect(t, err == nil && duplicate_imaginary_id == imaginary_id)
	imaginary := constant_pool_get(&pool, imaginary_id).value.(Complex_Value)
	testing.expect(t, constant_pool_get(&pool, imaginary[0]).value.(big.Int).used == 0)
	testing.expect(t, constant_pool_get(&pool, imaginary[1]).value.(big.Int).used > 0)
	j_id: Const_Id
	j_id, err = literal_constant(&pool, .Imag, "3j")
	testing.expect(t, err == nil)
	j_value := constant_pool_get(&pool, j_id).value.(Quaternion_Value)
	testing.expect(t, j_value[2] != 0 && j_value[3] != j_value[2])
	k_id: Const_Id
	k_id, err = literal_constant(&pool, .Imag, "4k")
	testing.expect(t, err == nil)
	k_value := constant_pool_get(&pool, k_id).value.(Quaternion_Value)
	testing.expect(t, k_value[3] != 0 && k_value[2] != k_value[3])

	rune_id: Const_Id
	rune_id, err = literal_constant(&pool, .Rune, "'\\u03bb'")
	testing.expect(t, err == nil)
	rune_value := constant_pool_get(&pool, rune_id).value.(big.Int)
	rune_is_lambda, rune_error := big.int_equals_digit(&rune_value, 955)
	testing.expect(t, rune_error == nil && rune_is_lambda)

	_, err = literal_constant(&pool, .Float, "1e1f")
	testing.expect(t, err == Literal_Diagnostic.Invalid_Integer_Literal)
	testing.expect_value(t, literal_error_message(err), "Invalid integer literal")
	_, err = literal_constant(&pool, .Float, "1.0f")
	testing.expect(t, err == Literal_Diagnostic.Invalid_Float_Literal)
	_, err = literal_constant(&pool, .Rune, "'ab'")
	testing.expect(t, err == Literal_Diagnostic.Invalid_Rune_Literal)
}
