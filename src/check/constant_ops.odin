package check

import "core:math/big"
import "core:strings"
import "oc:syntax"
import "oc:types"

Constant_Operation_Error_Kind :: Constant_Pool_Error
Constant_Operation_Error :: Constant_Error
// Evaluates a constant unary operator and interns the result in pool.
@(private = "file")
constant_unsigned_integer_type :: proc(store: ^types.Store, type: types.Type_Id) -> bool {
	descriptor := types.get(store, conversion_base_type(store, type))
	return descriptor.kind == .Integer && !descriptor.signed && descriptor.count > 0
}

// Evaluates a constant unary operator and interns the result in pool.
@(require_results)
constant_unary_operator :: proc(
	pool: ^Constant_Pool,
	operator: syntax.Token_Kind,
	operand_id: Const_Id,
	result_type: types.Type_Id = 0,
	type_store: ^types.Store = nil,
) -> (
	id: Const_Id,
	err: Constant_Operation_Error,
) {
	operand := constant_pool_get(pool, operand_id)
	if operand == nil { return 0, Constant_Operation_Error_Kind.Invalid_Operand }
	type := result_type
	if type == 0 { type = operand.type }
	#partial switch &value in operand.value {
	case bool:
		if operator != .Not { return 0, Constant_Operation_Error_Kind.Unsupported_Operator }
		return constant_pool_intern_bool(pool, !value, type)
	case big.Int:
		if type != 0 && type_store == nil { return 0, Constant_Operation_Error_Kind.Missing_Type_Store }
		result: big.Int
		defer big.int_destroy(&result)
		#partial switch operator {
		case .Add:
			big.int_copy(&result, &value, allocator = context.temp_allocator) or_return
		case .Sub:
			big.int_neg(&result, &value, allocator = context.temp_allocator) or_return
		case .Xor:
			if type_store != nil && type != 0 && constant_unsigned_integer_type(type_store, type) {
				descriptor := types.get(type_store, conversion_base_type(type_store, type))
				mask: big.Int
				defer big.int_destroy(&mask)
				big.int_set_from_integer(&mask, 1, allocator = context.temp_allocator) or_return
				big.int_shl(&mask, &mask, int(descriptor.count) * 8, allocator = context.temp_allocator) or_return
				big.int_sub_digit(&mask, &mask, 1, allocator = context.temp_allocator) or_return
				big.int_sub(&result, &mask, &value, allocator = context.temp_allocator) or_return
			} else {
				big.bit_complement(&result, &value, allocator = context.temp_allocator) or_return
			}
		case:
			return 0, Constant_Operation_Error_Kind.Unsupported_Operator
		}
		if type_store != nil && type != 0 {
			representable := constant_integer_is_representable(type_store, type, &result) or_return
			if !representable { return 0, Constant_Operation_Error_Kind.Not_Representable }
		}
		return constant_pool_intern_integer(pool, &result, type)
	case big.Rat:
		result: big.Rat
		defer big.destroy(&result)
		#partial switch operator {
		case .Add:
			big.rat_set_rat(&result, &value, allocator = context.temp_allocator) or_return
		case .Sub:
			big.rat_neg(&result, &value, allocator = context.temp_allocator) or_return
		case:
			return 0, Constant_Operation_Error_Kind.Unsupported_Operator
		}
		return constant_pool_intern_rational(pool, &result, type)
	case Float_Value:
		f := constant_float_to_f64(value)
		#partial switch operator {
		case .Add:
		case .Sub:
			f = -f
		case:
			return 0, Constant_Operation_Error_Kind.Unsupported_Operator
		}
		return constant_pool_intern_float(pool, constant_float_from_f64(f, value.width), type)
	case Complex_Value, Quaternion_Value:
		return 0, Constant_Operation_Error_Kind.Unsupported_Constant_Op
	}
	return 0, Constant_Operation_Error_Kind.Invalid_Operand
}

// Evaluates a constant binary operator and interns the result in pool.
@(private = "file")
constant_is_aggregate :: proc(value: Constant_Value) -> bool {
	#partial switch _ in value {
	case Complex_Value, Quaternion_Value:
		return true
	}
	return false
}

@(private = "file")
constant_component_operation :: proc(
	pool: ^Constant_Pool,
	operator: syntax.Token_Kind,
	left, right: Const_Id,
	type_store: ^types.Store,
) -> (
	Const_Id,
	Constant_Error,
) {
	return constant_binary_operator(pool, operator, left, right, 0, .Trap, type_store)
}

@(private = "file")
constant_component_float :: proc(pool: ^Constant_Pool, id: Const_Id, width: u8) -> (Const_Id, bool) {
	constant := constant_pool_get(pool, id)
	if constant == nil { return 0, false }
	#partial switch component in constant.value {
	case Float_Value:
		return id, true
	case big.Int:
		integer := component
		value, failure := big.int_get_float(&integer, allocator = context.temp_allocator)
		if failure != nil { return 0, false }
		result, pool_error := constant_pool_intern_float(pool, constant_float_from_f64(value, width))
		return result, pool_error == nil
	case big.Rat:
		rational := component
		value, _, failure := numeric_rational_to_f64(&rational, width)
		if failure { return 0, false }
		result, pool_error := constant_pool_intern_float(pool, constant_float_from_f64(value, width))
		return result, pool_error == nil
	}
	return 0, false
}

// Complex and quaternion components are converted to floats so that division never truncates.
@(private = "file")
constant_aggregate_parts :: proc(pool: ^Constant_Pool, id: Const_Id, value: Constant_Value, count: int, width: u8) -> (parts: [4]Const_Id, ok: bool) {
	source: [4]Const_Id
	source_count := 0
	#partial switch aggregate in value {
	case Complex_Value:
		source[0], source[1] = aggregate[0], aggregate[1]
		source_count = 2
	case Quaternion_Value:
		source = aggregate
		source_count = 4
	case big.Int, big.Rat, Float_Value:
		source[0] = id
		source_count = 1
	case:
		return {}, false
	}
	if source_count > count { return {}, false }
	for i in 0 ..< count {
		if i < source_count {
			component, component_ok := constant_component_float(pool, source[i], width)
			if !component_ok { return {}, false }
			parts[i] = component
		} else {
			zero, zero_error := constant_pool_intern_float(pool, constant_float_from_f64(0, width))
			if zero_error != nil { return {}, false }
			parts[i] = zero
		}
	}
	return parts, true
}

@(private = "file")
constant_aggregate_binary_operator :: proc(
	pool: ^Constant_Pool,
	operator: syntax.Token_Kind,
	left_id, right_id: Const_Id,
	type_store: ^types.Store,
) -> (
	id: Const_Id,
	err: Constant_Error,
) {
	left := constant_pool_get(pool, left_id)
	right := constant_pool_get(pool, right_id)
	if left == nil || right == nil { return 0, Constant_Pool_Error.Invalid_Operand }
	type := right.type
	if constant_is_aggregate(left.value) { type = left.type }
	count := 2
	if _, is_quaternion := left.value.(Quaternion_Value); is_quaternion { count = 4 }
	if _, is_quaternion := right.value.(Quaternion_Value); is_quaternion { count = 4 }
	width := u8(64)
	if type_store != nil && type != 0 {
		if descriptor := types.get(type_store, type); descriptor.count > 0 { width = u8(descriptor.count * 8 / i64(count)) }
	}
	left_parts, left_ok := constant_aggregate_parts(pool, left_id, left.value, count, width)
	right_parts, right_ok := constant_aggregate_parts(pool, right_id, right.value, count, width)
	if !left_ok || !right_ok { return 0, Constant_Pool_Error.Invalid_Operand }
	result: [4]Const_Id
	#partial switch operator {
	case .Add, .Sub:
		for i in 0 ..< count {
			result[i] = constant_component_operation(pool, operator, left_parts[i], right_parts[i], type_store) or_return
		}
	case .Mul, .Quo:
		if count != 2 { return 0, Constant_Pool_Error.Unsupported_Constant_Op }
		a, b := left_parts[0], left_parts[1]
		c, d := right_parts[0], right_parts[1]
		if operator == .Mul {
			ac := constant_component_operation(pool, .Mul, a, c, type_store) or_return
			bd := constant_component_operation(pool, .Mul, b, d, type_store) or_return
			ad := constant_component_operation(pool, .Mul, a, d, type_store) or_return
			bc := constant_component_operation(pool, .Mul, b, c, type_store) or_return
			result[0] = constant_component_operation(pool, .Sub, ac, bd, type_store) or_return
			result[1] = constant_component_operation(pool, .Add, ad, bc, type_store) or_return
		} else {
			cc := constant_component_operation(pool, .Mul, c, c, type_store) or_return
			dd := constant_component_operation(pool, .Mul, d, d, type_store) or_return
			denominator := constant_component_operation(pool, .Add, cc, dd, type_store) or_return
			ac := constant_component_operation(pool, .Mul, a, c, type_store) or_return
			bd := constant_component_operation(pool, .Mul, b, d, type_store) or_return
			bc := constant_component_operation(pool, .Mul, b, c, type_store) or_return
			ad := constant_component_operation(pool, .Mul, a, d, type_store) or_return
			real_sum := constant_component_operation(pool, .Add, ac, bd, type_store) or_return
			imaginary_difference := constant_component_operation(pool, .Sub, bc, ad, type_store) or_return
			result[0] = constant_component_operation(pool, .Quo, real_sum, denominator, type_store) or_return
			result[1] = constant_component_operation(pool, .Quo, imaginary_difference, denominator, type_store) or_return
		}
	case:
		return 0, Constant_Pool_Error.Unsupported_Operator
	}
	if count == 4 { return constant_pool_intern_quaternion(pool, Quaternion_Value(result), type) }
	return constant_pool_intern_complex(pool, Complex_Value{result[0], result[1]}, type)
}

// Evaluates a constant binary operator and interns the result in pool.
// Promotes two numeric constants of different representations to one shared
// representation: integer against rational stays exact, anything against a
// float converts the exact side to f64 at the float's width. Same-kind and
// non-numeric pairs pass through unchanged.
@(private = "file")
constant_numeric_promotion :: proc(pool: ^Constant_Pool, left_id, right_id: Const_Id) -> (left, right: Const_Id, promoted: bool, err: Constant_Error) {
	left_constant := constant_pool_get(pool, left_id)
	right_constant := constant_pool_get(pool, right_id)
	if left_constant == nil || right_constant == nil {
		return left_id, right_id, false, Constant_Pool_Error.Invalid_Operand
	}
	if left_integer, is_integer := left_constant.value.(big.Int); is_integer {
		if _, is_rational := right_constant.value.(big.Rat); is_rational {
			value: big.Rat
			defer big.destroy(&value)
			big.rat_set_int(&value, &left_integer, allocator = context.temp_allocator) or_return
			converted, failure := constant_pool_intern_rational(pool, &value, left_constant.type)
			if failure != nil { return left_id, right_id, false, failure }
			return converted, right_id, true, nil
		}
		if right_float, is_float := right_constant.value.(Float_Value); is_float {
			value, failure := big.int_get_float(&left_integer, allocator = context.temp_allocator)
			if failure != nil { return left_id, right_id, false, failure }
			converted, intern_failure := constant_pool_intern_float(pool, constant_float_from_f64(value, right_float.width), left_constant.type)
			if intern_failure != nil { return left_id, right_id, false, intern_failure }
			return converted, right_id, true, nil
		}
		return left_id, right_id, false, nil
	}
	if left_float, is_float := left_constant.value.(Float_Value); is_float {
		if right_rational, is_rational := right_constant.value.(big.Rat); is_rational {
			value, _, failure := numeric_rational_to_f64(&right_rational, left_float.width)
			if failure { return left_id, right_id, false, Constant_Pool_Error.Invalid_Operand }
			converted, intern_failure := constant_pool_intern_float(pool, constant_float_from_f64(value, left_float.width), right_constant.type)
			if intern_failure != nil { return left_id, right_id, false, intern_failure }
			return left_id, converted, true, nil
		}
		if right_integer, is_integer := right_constant.value.(big.Int); is_integer {
			value, failure := big.int_get_float(&right_integer, allocator = context.temp_allocator)
			if failure != nil { return left_id, right_id, false, failure }
			converted, intern_failure := constant_pool_intern_float(pool, constant_float_from_f64(value, left_float.width), right_constant.type)
			if intern_failure != nil { return left_id, right_id, false, intern_failure }
			return left_id, converted, true, nil
		}
		return left_id, right_id, false, nil
	}
	if left_rational, is_rational := left_constant.value.(big.Rat); is_rational {
		if right_float, is_float := right_constant.value.(Float_Value); is_float {
			value, _, failure := numeric_rational_to_f64(&left_rational, right_float.width)
			if failure { return left_id, right_id, false, Constant_Pool_Error.Invalid_Operand }
			converted, intern_failure := constant_pool_intern_float(pool, constant_float_from_f64(value, right_float.width), left_constant.type)
			if intern_failure != nil { return left_id, right_id, false, intern_failure }
			return converted, right_id, true, nil
		}
		if right_integer, is_integer := right_constant.value.(big.Int); is_integer {
			value: big.Rat
			defer big.destroy(&value)
			big.rat_set_int(&value, &right_integer, allocator = context.temp_allocator) or_return
			converted, failure := constant_pool_intern_rational(pool, &value, right_constant.type)
			if failure != nil { return left_id, right_id, false, failure }
			return left_id, converted, true, nil
		}
	}
	return left_id, right_id, false, nil
}

@(require_results)
constant_binary_operator :: proc(
	pool: ^Constant_Pool,
	operator: syntax.Token_Kind,
	left_id, right_id: Const_Id,
	result_type: types.Type_Id = 0,
	division_by_zero: Division_By_Zero = .Trap,
	type_store: ^types.Store = nil,
) -> (
	id: Const_Id,
	err: Constant_Operation_Error,
) {
	left := constant_pool_get(pool, left_id)
	right := constant_pool_get(pool, right_id)
	if left == nil || right == nil { return 0, Constant_Operation_Error_Kind.Invalid_Operand }
	type := result_type
	if type == 0 { type = left.type }
	if constant_is_aggregate(left.value) || constant_is_aggregate(right.value) {
		return constant_aggregate_binary_operator(pool, operator, left_id, right_id, type_store)
	}
	binary_left, binary_right, _, binary_promotion_error := constant_numeric_promotion(pool, left_id, right_id)
	if binary_promotion_error != nil { return 0, binary_promotion_error }
	if binary_left != left_id || binary_right != right_id {
		left = constant_pool_get(pool, binary_left)
		right = constant_pool_get(pool, binary_right)
		if left == nil || right == nil { return 0, Constant_Operation_Error_Kind.Invalid_Operand }
	}
	#partial switch &left_value in left.value {
	case bool:
		right_value, ok := right.value.(bool)
		if !ok { return 0, Constant_Operation_Error_Kind.Invalid_Operand }
		result: bool
		#partial switch operator {
		case .Cmp_And:
			result = left_value && right_value
		case .Cmp_Or:
			result = left_value || right_value
		case .And:
			result = left_value & right_value
		case .Or:
			result = left_value | right_value
		case .And_Not:
			result = left_value && !right_value
		case .Xor:
			result = left_value != right_value
		case .Eq:
			result = left_value == right_value
		case .Not_Eq:
			result = left_value != right_value
		case:
			return 0, Constant_Operation_Error_Kind.Unsupported_Operator
		}
		return constant_pool_intern_bool(pool, result, type)
	case big.Int:
		right_value, ok := right.value.(big.Int)
		if !ok { return 0, Constant_Operation_Error_Kind.Invalid_Operand }
		if type != 0 && type_store == nil { return 0, Constant_Operation_Error_Kind.Missing_Type_Store }
		result: big.Int
		defer big.int_destroy(&result)
		#partial switch operator {
		case .Add:
			big.int_add(&result, &left_value, &right_value, allocator = context.temp_allocator) or_return
		case .Sub:
			big.int_sub(&result, &left_value, &right_value, allocator = context.temp_allocator) or_return
		case .Mul:
			big.int_mul(&result, &left_value, &right_value, allocator = context.temp_allocator) or_return
		case .Quo, .Quo_Eq:
			zero, zero_error := big.is_zero(&right_value, allocator = context.temp_allocator)
			if zero_error != nil { return 0, zero_error }
			if zero {
				if division_by_zero == .Trap || division_by_zero == .Unspecified { return 0, Constant_Operation_Error_Kind.Division_By_Zero }
				#partial switch division_by_zero {
				case .Zero:
					big.int_set_from_integer(&result, 0, allocator = context.temp_allocator) or_return
				case .Self:
					big.int_copy(&result, &left_value, allocator = context.temp_allocator) or_return
				case .All_Bits:
					constant_integer_set_all_bits(&result, type_store, type) or_return
				}
			} else { big.int_div(&result, &left_value, &right_value, allocator = context.temp_allocator) or_return }
		case .Mod, .Mod_Mod:
			zero, zero_error := big.is_zero(&right_value, allocator = context.temp_allocator)
			if zero_error != nil { return 0, zero_error }
			if zero {
				if division_by_zero == .Trap || division_by_zero == .Unspecified { return 0, Constant_Operation_Error_Kind.Division_By_Zero }
				if division_by_zero == .Self {big.int_set_from_integer(&result, 0, allocator = context.temp_allocator) or_return
				} else { big.int_copy(&result, &left_value, allocator = context.temp_allocator) or_return }
			} else if operator == .Mod {
				big.int_divmod(nil, &result, &left_value, &right_value, allocator = context.temp_allocator) or_return
			} else {
				big.int_mod(&result, &left_value, &right_value, allocator = context.temp_allocator) or_return
			}
		case .And:
			big.int_bit_and(&result, &left_value, &right_value, allocator = context.temp_allocator) or_return
		case .Or:
			big.int_bit_or(&result, &left_value, &right_value, allocator = context.temp_allocator) or_return
		case .Xor:
			big.int_bit_xor(&result, &left_value, &right_value, allocator = context.temp_allocator) or_return
		case .And_Not:
			complement: big.Int
			defer big.int_destroy(&complement)
			big.bit_complement(&complement, &right_value, allocator = context.temp_allocator) or_return
			big.int_bit_and(&result, &left_value, &complement, allocator = context.temp_allocator) or_return
		case .Shl, .Shr:
			negative, compare_error := big.int_is_negative(&right_value, allocator = context.temp_allocator)
			if compare_error != nil { return 0, compare_error }
			if negative { return 0, Constant_Operation_Error_Kind.Negative_Shift }
			shift_i64, conversion_error := big.int_get_i64(&right_value, allocator = context.temp_allocator)
			shift := int(shift_i64)
			if conversion_error != nil || shift > 1024 { return 0, Constant_Operation_Error_Kind.Shift_Too_Large }
			if operator == .Shl {big.int_shl(&result, &left_value, shift, allocator = context.temp_allocator) or_return
			} else { big.int_shr_signed(&result, &left_value, shift, allocator = context.temp_allocator) or_return }
		case:
			return 0, Constant_Operation_Error_Kind.Unsupported_Operator
		}
		if type_store != nil && type != 0 {
			representable := constant_integer_is_representable(type_store, type, &result) or_return
			if !representable { return 0, Constant_Operation_Error_Kind.Not_Representable }
		}
		return constant_pool_intern_integer(pool, &result, type)
	case big.Rat:
		right_value, ok := right.value.(big.Rat)
		if !ok { return 0, Constant_Operation_Error_Kind.Invalid_Operand }
		result: big.Rat
		defer big.destroy(&result)
		#partial switch operator {
		case .Add:
			big.rat_add_rat(&result, &left_value, &right_value, allocator = context.temp_allocator) or_return
		case .Sub:
			big.rat_sub_rat(&result, &left_value, &right_value, allocator = context.temp_allocator) or_return
		case .Mul:
			big.rat_mul_rat(&result, &left_value, &right_value, allocator = context.temp_allocator) or_return
		case .Quo:
			zero, zero_error := big.is_zero(&right_value.a, allocator = context.temp_allocator)
			if zero_error != nil { return 0, zero_error }
			if zero { return 0, Constant_Operation_Error_Kind.Division_By_Zero }
			big.rat_div_rat(&result, &left_value, &right_value, allocator = context.temp_allocator) or_return
		case:
			return 0, Constant_Operation_Error_Kind.Unsupported_Operator
		}
		return constant_pool_intern_rational(pool, &result, type)
	case Float_Value:
		right_value, ok := right.value.(Float_Value)
		if !ok { return 0, Constant_Operation_Error_Kind.Invalid_Operand }
		return constant_float_binary_operator(pool, operator, constant_float_to_f64(left_value), constant_float_to_f64(right_value), left_value.width, type)
	case string:
		right_value, ok := right.value.(string)
		if !ok { return 0, Constant_Operation_Error_Kind.Invalid_Operand }
		if operator != .Add { return 0, Constant_Operation_Error_Kind.Unsupported_Operator }
		joined, join_error := strings.concatenate({left_value, right_value}, allocator = context.temp_allocator)
		if join_error != nil { return 0, join_error }
		return constant_pool_intern_string(pool, joined, type)
	case Complex_Value:
		return 0, Constant_Operation_Error_Kind.Unsupported_Constant_Op
	case Quaternion_Value:
		return 0, Constant_Operation_Error_Kind.Unsupported_Constant_Op
	case []u16:
		right_value, ok := right.value.([]u16)
		if !ok { return 0, Constant_Operation_Error_Kind.Invalid_Operand }
		if operator != .Add { return 0, Constant_Operation_Error_Kind.Unsupported_Operator }
		joined := make([]u16, len(left_value) + len(right_value), context.temp_allocator)
		copy(joined[:len(left_value)], left_value)
		copy(joined[len(left_value):], right_value)
		return constant_pool_intern_string16(pool, joined, type)
	}
	return 0, Constant_Operation_Error_Kind.Invalid_Operand
}

@(private = "file")
constant_float_binary_operator :: proc(
	pool: ^Constant_Pool,
	operator: syntax.Token_Kind,
	left, right: f64,
	width: u8,
	type: types.Type_Id,
) -> (
	id: Const_Id,
	err: Constant_Operation_Error,
) {
	result: f64
	#partial switch operator {
	case .Add:
		result = left + right
	case .Sub:
		result = left - right
	case .Mul:
		result = left * right
	case .Quo:
		result = left / right
	case:
		return 0, Constant_Operation_Error_Kind.Unsupported_Operator
	}
	return constant_pool_intern_float(pool, constant_float_from_f64(result, width), type)
}

// Compares two constant values and interns the Boolean result in pool.
@(require_results)
constant_compare_operator :: proc(
	pool: ^Constant_Pool,
	operator: syntax.Token_Kind,
	left_id, right_id: Const_Id,
	bool_type: types.Type_Id = 0,
) -> (
	id: Const_Id,
	err: Constant_Operation_Error,
) {
	left := constant_pool_get(pool, left_id)
	right := constant_pool_get(pool, right_id)
	if left == nil || right == nil { return 0, Constant_Operation_Error_Kind.Invalid_Operand }
	compared_left, compared_right, _, compared_promotion_error := constant_numeric_promotion(pool, left_id, right_id)
	if compared_promotion_error != nil { return 0, compared_promotion_error }
	if compared_left != left_id || compared_right != right_id {
		left = constant_pool_get(pool, compared_left)
		right = constant_pool_get(pool, compared_right)
		if left == nil || right == nil { return 0, Constant_Operation_Error_Kind.Invalid_Operand }
	}
	comparison: int
	#partial switch &left_value in left.value {
	case bool:
		right_value, ok := right.value.(bool)
		if !ok { return 0, Constant_Operation_Error_Kind.Invalid_Operand }
		if operator != .Eq && operator != .Not_Eq { return 0, Constant_Operation_Error_Kind.Unsupported_Operator }
		comparison = 0
		if left_value != right_value {
			if left_value { comparison = 1 } else { comparison = -1 }
		}
	case big.Int:
		right_value, ok := right.value.(big.Int)
		if !ok { return 0, Constant_Operation_Error_Kind.Invalid_Operand }
		value_comparison, compare_error := big.int_compare(&left_value, &right_value, allocator = context.temp_allocator)
		if compare_error != nil { return 0, compare_error }
		comparison = value_comparison
	case big.Rat:
		right_value, ok := right.value.(big.Rat)
		if !ok { return 0, Constant_Operation_Error_Kind.Invalid_Operand }
		left_scaled, right_scaled: big.Int
		defer big.int_destroy(&left_scaled, &right_scaled)
		big.int_mul(&left_scaled, &left_value.a, &right_value.b, allocator = context.temp_allocator) or_return
		big.int_mul(&right_scaled, &right_value.a, &left_value.b, allocator = context.temp_allocator) or_return
		value_comparison, compare_error := big.int_compare(&left_scaled, &right_scaled, allocator = context.temp_allocator)
		if compare_error != nil { return 0, compare_error }
		comparison = value_comparison
	case Float_Value:
		right_value, ok := right.value.(Float_Value)
		if !ok { return 0, Constant_Operation_Error_Kind.Invalid_Operand }
		a, b := constant_float_to_f64(left_value), constant_float_to_f64(right_value)
		if a != a || b != b {
			return constant_pool_intern_bool(pool, operator == .Not_Eq, bool_type)
		}
		if a < b { comparison = -1 } else if a > b { comparison = 1 } else { comparison = 0 }
	case string:
		right_value, ok := right.value.(string)
		if !ok { return 0, Constant_Operation_Error_Kind.Invalid_Operand }
		if left_value < right_value { comparison = -1 } else if left_value > right_value { comparison = 1 } else { comparison = 0 }
	case []u16:
		right_value, ok := right.value.([]u16)
		if !ok { return 0, Constant_Operation_Error_Kind.Invalid_Operand }
		comparison = constant_string16_compare(left_value, right_value)
	case Complex_Value:
		right_value, ok := right.value.(Complex_Value)
		if !ok { return 0, Constant_Operation_Error_Kind.Invalid_Operand }
		if operator != .Eq && operator != .Not_Eq { return 0, Constant_Operation_Error_Kind.Unsupported_Constant_Op }
		equal := true
		for i in 0 ..< 2 {
			equal_id, compare_error := constant_compare_operator(pool, .Eq, left_value[i], right_value[i])
			if compare_error != nil { return 0, compare_error }
			equal &&= constant_pool_get(pool, equal_id).value.(bool)
		}
		if operator == .Not_Eq { equal = !equal }
		return constant_pool_intern_bool(pool, equal, bool_type)
	case Quaternion_Value:
		right_value, ok := right.value.(Quaternion_Value)
		if !ok { return 0, Constant_Operation_Error_Kind.Invalid_Operand }
		if operator != .Eq && operator != .Not_Eq { return 0, Constant_Operation_Error_Kind.Unsupported_Constant_Op }
		equal := true
		for i in 0 ..< 4 {
			equal_id, compare_error := constant_compare_operator(pool, .Eq, left_value[i], right_value[i])
			if compare_error != nil { return 0, compare_error }
			equal &&= constant_pool_get(pool, equal_id).value.(bool)
		}
		if operator == .Not_Eq { equal = !equal }
		return constant_pool_intern_bool(pool, equal, bool_type)
	case Aggregate_Value:
		right_value, ok := right.value.(Aggregate_Value)
		if !ok || len(left_value.elements) != len(right_value.elements) { return 0, Constant_Operation_Error_Kind.Invalid_Operand }
		if operator != .Eq && operator != .Not_Eq { return 0, Constant_Operation_Error_Kind.Unsupported_Constant_Op }
		equal := true
		for element, index in left_value.elements {
			equal_id, compare_error := constant_compare_operator(pool, .Eq, element, right_value.elements[index])
			if compare_error != nil { return 0, compare_error }
			equal &&= constant_pool_get(pool, equal_id).value.(bool)
		}
		if operator == .Not_Eq { equal = !equal }
		return constant_pool_intern_bool(pool, equal, bool_type)
	case:
		return 0, Constant_Operation_Error_Kind.Invalid_Operand
	}
	result := false
	#partial switch operator {
	case .Eq:
		result = comparison == 0
	case .Not_Eq:
		result = comparison != 0
	case .Lt:
		result = comparison < 0
	case .Gt:
		result = comparison > 0
	case .Lt_Eq:
		result = comparison <= 0
	case .Gt_Eq:
		result = comparison >= 0
	case:
		return 0, Constant_Operation_Error_Kind.Unsupported_Operator
	}
	return constant_pool_intern_bool(pool, result, bool_type)
}

@(private = "file")
constant_integer_is_representable :: proc(store: ^types.Store, type_id: types.Type_Id, value: ^big.Int) -> (ok: bool, err: Constant_Error) {
	if store == nil || type_id == 0 { return true, nil }
	descriptor := types.get(store, type_id)
	for _ in 0 ..< 16 {
		#partial switch descriptor.kind {
		case .Named:
			descriptor = types.get(store, descriptor.elem)
		case .Enum, .Bit_Field:
			if descriptor.backing == 0 { return true, nil }
			descriptor = types.get(store, descriptor.backing)
		case .Bit_Set:
			if descriptor.backing == 0 { return true, nil }
			descriptor = types.get(store, descriptor.backing)
		case .Integer, .Rune:
			if descriptor.count <= 0 { return true, nil }
			bits := int(descriptor.count * 8)
			if bits > 1024 { return true, nil }
			one, limit, minimum: big.Int
			defer big.int_destroy(&one, &limit, &minimum)
			big.int_set_from_integer(&one, 1, allocator = context.temp_allocator) or_return
			shift := bits
			if descriptor.signed { shift -= 1 }
			big.int_shl(&limit, &one, shift, allocator = context.temp_allocator) or_return
			negative, negative_error := big.int_is_negative(value, allocator = context.temp_allocator)
			if negative_error != nil { return false, negative_error }
			if descriptor.signed {
				if negative {
					big.int_neg(&minimum, &limit, allocator = context.temp_allocator) or_return
					comparison, compare_error := big.int_compare(value, &minimum, allocator = context.temp_allocator)
					if compare_error != nil { return false, compare_error }
					return comparison >= 0, nil
				}
				big.int_sub(&limit, &limit, &one, allocator = context.temp_allocator) or_return
			} else if negative {
				return false, nil
			}
			comparison, compare_error := big.int_compare(value, &limit, allocator = context.temp_allocator)
			if compare_error != nil { return false, compare_error }
			return comparison <= 0, nil
		case:
			return true, nil
		}
	}
	return true, nil
}

@(private = "file")
constant_integer_set_all_bits :: proc(value: ^big.Int, store: ^types.Store, type_id: types.Type_Id) -> (err: big.Error) {
	if store == nil || type_id == 0 {
		return big.int_set_from_integer(value, -1, allocator = context.temp_allocator)
	}
	descriptor := types.get(store, type_id)
	for _ in 0 ..< 16 {
		#partial switch descriptor.kind {
		case .Named:
			descriptor = types.get(store, descriptor.elem)
		case .Enum, .Bit_Field, .Bit_Set:
			if descriptor.backing == 0 { return big.int_set_from_integer(value, -1, allocator = context.temp_allocator) }
			descriptor = types.get(store, descriptor.backing)
		case .Integer, .Rune:
			if descriptor.signed || descriptor.count <= 0 { return big.int_set_from_integer(value, -1, allocator = context.temp_allocator) }
			bits := int(descriptor.count * 8)
			one: big.Int
			defer big.int_destroy(&one)
			big.int_set_from_integer(&one, 1, allocator = context.temp_allocator) or_return
			big.int_shl(value, &one, bits, allocator = context.temp_allocator) or_return
			return big.int_sub(value, value, &one, allocator = context.temp_allocator)
		case:
			return big.int_set_from_integer(value, -1, allocator = context.temp_allocator)
		}
	}
	return big.int_set_from_integer(value, -1, allocator = context.temp_allocator)
}

@(private = "file")
constant_float_to_f64 :: proc(value: Float_Value) -> f64 {
	switch value.width {
	case 16:
		return f64(transmute(f16)u16(value.bits))
	case 32:
		return f64(transmute(f32)u32(value.bits))
	case 64:
		return transmute(f64)value.bits
	}
	return 0
}

@(private = "file")
constant_float_from_f64 :: proc(value: f64, width: u8) -> Float_Value {
	switch width {
	case 16:
		return Float_Value{bits = u64(transmute(u16)f16(value)), width = 16}
	case 32:
		return Float_Value{bits = u64(transmute(u32)f32(value)), width = 32}
	case 64:
		return Float_Value{bits = transmute(u64)value, width = 64}
	}
	return {}
}

@(private = "file")
constant_string16_compare :: proc(left, right: []u16) -> int {
	for i in 0 ..< min(len(left), len(right)) {
		if left[i] < right[i] { return -1 }
		if left[i] > right[i] { return 1 }
	}
	if len(left) < len(right) { return -1 }
	if len(left) > len(right) { return 1 }
	return 0
}

// Mirrors official check_transmute: same-size integer and integer-to-bit-set transmutes of constants keep
// their bit pattern, re-expressed for the target's signedness instead of failing representability.
@(private = "package")
constant_transmute_integer :: proc(
	pool: ^Constant_Pool,
	constant: Const_Id,
	source_signed: bool,
	target_signed: bool,
	bits: i64,
	target: types.Type_Id,
) -> (
	id: Const_Id,
	err: Constant_Error,
) {
	source_value := constant_pool_get(pool, constant)
	if source_value == nil { return 0, Constant_Operation_Error_Kind.Invalid_Operand }
	source_integer, is_integer := source_value.value.(big.Int)
	if !is_integer { return 0, Constant_Operation_Error_Kind.Invalid_Operand }
	adjusted: big.Int
	big.int_copy(&adjusted, &source_integer, allocator = context.temp_allocator) or_return
	defer big.int_destroy(&adjusted)
	if bits > 0 && source_signed != target_signed {
		one, limit, maximum: big.Int
		defer big.int_destroy(&one, &limit, &maximum)
		big.int_set_from_integer(&one, 1, allocator = context.temp_allocator) or_return
		big.int_copy(&limit, &one, allocator = context.temp_allocator) or_return
		big.int_shl(&limit, &limit, int(bits), allocator = context.temp_allocator) or_return
		big.int_copy(&maximum, &limit, allocator = context.temp_allocator) or_return
		big.int_shr_signed(&maximum, &maximum, 1, allocator = context.temp_allocator) or_return
		big.int_sub(&maximum, &maximum, &one, allocator = context.temp_allocator) or_return
		if !source_signed && target_signed {
			comparison, compare_error := big.int_compare(&adjusted, &maximum, allocator = context.temp_allocator)
			if compare_error != nil { return 0, compare_error }
			if comparison > 0 {
				big.int_sub(&adjusted, &adjusted, &limit, allocator = context.temp_allocator) or_return
			}
		} else if source_signed && !target_signed {
			negative, negative_error := big.int_is_negative(&adjusted, allocator = context.temp_allocator)
			if negative_error != nil { return 0, negative_error }
			if negative {
				big.int_add(&adjusted, &adjusted, &limit, allocator = context.temp_allocator) or_return
			}
		}
	}
	return constant_pool_intern_integer(pool, &adjusted, target)
}
