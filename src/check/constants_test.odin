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
