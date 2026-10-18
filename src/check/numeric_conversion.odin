package check

import "core:math"
import "core:math/big"
import "oc:types"

Numeric_Conversion_Error_Kind :: enum u8 {
	None,
	Invalid_Source,
	Invalid_Target,
	// F3 maps these categories to the corresponding check_expr.cpp diagnostic format.
	Cannot_Convert_Untyped_Value,
	// `'value' truncated to 'target', got <value>`.
	Truncated,
	// `Numeric value ... cannot be represented by ...` when source and target types match.
	Numeric_Value_Not_Representable,
	// `Cannot convert numeric value ...` when source and target types differ.
	Numeric_Conversion_Not_Representable,
	// `Cannot convert ...` for nonnumeric source/target pairs.
	Cannot_Convert_Value,
	Internal_Error,
}

// Numeric_Conversion_Error identifies the source constant and requested target for F3 diagnostics.
Numeric_Conversion_Error :: struct {
	kind:   Numeric_Conversion_Error_Kind,
	source: Const_Id,
	target: types.Type_Id,
}

// Converts one scalar constant to a target type and interns its typed value.
// Float-to-integer conversion succeeds only for an exact integer in i64 range. Rational-to-float
// conversion rounds directly to the target precision; other numeric sources follow the f64-backed
// precision update used for typed f16/f32 values.
@(require_results)
numeric_convert_constant :: proc(
	pool: ^Constant_Pool,
	store: ^types.Store,
	source_id: Const_Id,
	source_type, requested_target_type: types.Type_Id,
) -> (
	id: Const_Id,
	err: Numeric_Conversion_Error,
) {
	target_type := requested_target_type
	if pool == nil || store == nil || constant_pool_get(pool, source_id) == nil {
		return 0, numeric_conversion_error(.Invalid_Source, source_id, target_type)
	}
	if target_type == types.TYPE_NONE {
		if numeric_is_untyped_type(store, source_type) {
			target_type = numeric_default_type_of_untyped(store, source_type)
		}
		if target_type == types.TYPE_NONE { return 0, numeric_conversion_error(.Invalid_Target, source_id, requested_target_type) }
	}
	constant := constant_pool_get(pool, source_id)
	source_descriptor, source_base_id, source_ok := numeric_resolve_scalar_type(store, source_type)
	target_descriptor, _, target_ok := numeric_resolve_scalar_type(store, target_type)
	if !source_ok { return 0, numeric_conversion_error(.Invalid_Source, source_id, target_type) }
	if !target_ok { return 0, numeric_conversion_error(.Invalid_Target, source_id, target_type) }

	if numeric_is_untyped_type(store, source_type) {
		if numeric_is_untyped_type(store, target_type) {
			return numeric_promote_untyped_constant(pool, store, source_id, source_type, target_type)
		}
		if !numeric_untyped_source_matches(source_descriptor.kind, constant.value) {
			return 0, numeric_conversion_error(.Cannot_Convert_Untyped_Value, source_id, target_type)
		}
	} else if constant.type != 0 && constant.type != source_type && constant.type != source_base_id {
		return 0, numeric_conversion_error(.Invalid_Source, source_id, target_type)
	}

	#partial switch target_descriptor.kind {
	case .Bool:
		value, ok := constant.value.(bool)
		if !ok { return 0, numeric_conversion_error(numeric_non_numeric_conversion_category(source_descriptor.kind), source_id, target_type) }
		return numeric_intern_bool(pool, value, target_type, source_id)
	case .Integer, .Rune:
		integer, diagnostic, internal_error := numeric_constant_to_integer(constant, source_descriptor.kind)
		if internal_error != nil { return 0, numeric_conversion_error(.Internal_Error, source_id, target_type) }
		if diagnostic == .Truncated || diagnostic == .Cannot_Convert_Untyped_Value || diagnostic == .Cannot_Convert_Value {
			return 0, numeric_conversion_error(diagnostic, source_id, target_type)
		}
		if diagnostic != .None { return 0, numeric_unrepresentable_error(source_id, source_type, target_type) }
		defer big.int_destroy(&integer)
		representable, range_error := numeric_integer_is_representable(store, target_type, &integer)
		if range_error != nil { return 0, numeric_conversion_error(.Internal_Error, source_id, target_type) }
		if !representable { return 0, numeric_unrepresentable_error(source_id, source_type, target_type) }
		return numeric_intern_integer(pool, &integer, target_type, source_id)
	case .Float:
		width := numeric_float_width(target_descriptor)
		if width == 0 { return 0, numeric_conversion_error(.Invalid_Target, source_id, target_type) }
		converted, overflowed, conversion_error := numeric_constant_to_float(constant, width)
		if conversion_error { return 0, numeric_conversion_error(.Internal_Error, source_id, target_type) }
		if overflowed { return 0, numeric_unrepresentable_error(source_id, source_type, target_type) }
		return numeric_intern_float(pool, converted, target_type, source_id)
	case .Complex:
		width := numeric_complex_component_width(target_descriptor, 2)
		if width == 0 { return 0, numeric_conversion_error(.Invalid_Target, source_id, target_type) }
		value, conversion_category, ok := numeric_constant_to_complex(pool, source_id, constant.value, source_descriptor.kind, width)
		if !ok { return 0, numeric_conversion_error(conversion_category, source_id, target_type) }
		result, pool_error := constant_pool_intern_complex(pool, value, target_type)
		if pool_error != nil { return 0, numeric_conversion_error(.Internal_Error, source_id, target_type) }
		return result, {}
	case .Quaternion:
		width := numeric_complex_component_width(target_descriptor, 4)
		if width == 0 { return 0, numeric_conversion_error(.Invalid_Target, source_id, target_type) }
		value, conversion_category, ok := numeric_constant_to_quaternion(pool, source_id, constant.value, source_descriptor.kind, width)
		if !ok { return 0, numeric_conversion_error(conversion_category, source_id, target_type) }
		result, pool_error := constant_pool_intern_quaternion(pool, value, target_type)
		if pool_error != nil { return 0, numeric_conversion_error(.Internal_Error, source_id, target_type) }
		return result, {}
	case:
		return 0, numeric_conversion_error(numeric_non_numeric_conversion_category(source_descriptor.kind), source_id, target_type)
	}
}

@(private = "file")
numeric_conversion_error :: proc(kind: Numeric_Conversion_Error_Kind, source: Const_Id, target: types.Type_Id) -> Numeric_Conversion_Error {
	return Numeric_Conversion_Error{kind, source, target}
}

@(private = "file")
numeric_conversion_category :: proc(source_kind: types.Kind) -> Numeric_Conversion_Error_Kind {
	if numeric_is_untyped_kind(source_kind) { return .Cannot_Convert_Untyped_Value }
	#partial switch source_kind {
	case .Integer, .Rune, .Float, .Complex, .Quaternion:
		return .Numeric_Conversion_Not_Representable
	}
	return .Cannot_Convert_Value
}

@(private = "file")
numeric_non_numeric_conversion_category :: proc(source_kind: types.Kind) -> Numeric_Conversion_Error_Kind {
	if numeric_is_untyped_kind(source_kind) { return .Cannot_Convert_Untyped_Value }
	return .Cannot_Convert_Value
}

@(private = "file")
numeric_unrepresentable_error :: proc(source: Const_Id, source_type, target_type: types.Type_Id) -> Numeric_Conversion_Error {
	kind := Numeric_Conversion_Error_Kind.Numeric_Conversion_Not_Representable
	if source_type == target_type { kind = .Numeric_Value_Not_Representable }
	return numeric_conversion_error(kind, source, target_type)
}

@(private = "file")
numeric_resolve_scalar_type :: proc(store: ^types.Store, type_id: types.Type_Id) -> (descriptor: ^types.Type, base_id: types.Type_Id, ok: bool) {
	if type_id == types.TYPE_NONE || u64(type_id) >= u64(len(store.types)) { return nil, 0, false }
	base_id = type_id
	for _ in 0 ..< 16 {
		descriptor = types.get(store, base_id)
		#partial switch descriptor.kind {
		case .Named:
			base_id = descriptor.elem
		case .Enum, .Bit_Field:
			base_id = descriptor.backing
		case:
			return descriptor, base_id, true
		}
		if base_id == types.TYPE_NONE || u64(base_id) >= u64(len(store.types)) { return nil, 0, false }
	}
	return nil, 0, false
}

@(private = "file")
numeric_untyped_source_matches :: proc(kind: types.Kind, value: Constant_Value) -> bool {
	#partial switch kind {
	case .Untyped_Bool:
		_, ok := value.(bool)
		return ok
	case .Untyped_Integer, .Untyped_Rune:
		_, ok := value.(big.Int)
		return ok
	case .Untyped_Float:
		_, integer_ok := value.(big.Int)
		_, rational_ok := value.(big.Rat)
		_, float_ok := value.(Float_Value)
		return integer_ok || rational_ok || float_ok
	case .Untyped_Complex:
		_, integer_ok := value.(big.Int)
		_, rational_ok := value.(big.Rat)
		_, float_ok := value.(Float_Value)
		_, complex_ok := value.(Complex_Value)
		return integer_ok || rational_ok || float_ok || complex_ok
	case .Untyped_Quaternion:
		_, integer_ok := value.(big.Int)
		_, rational_ok := value.(big.Rat)
		_, float_ok := value.(Float_Value)
		_, complex_ok := value.(Complex_Value)
		_, quaternion_ok := value.(Quaternion_Value)
		return integer_ok || rational_ok || float_ok || complex_ok || quaternion_ok
	}
	return false
}

@(private = "file")
numeric_constant_to_integer :: proc(
	constant: ^Constant,
	source_kind: types.Kind,
) -> (
	integer: big.Int,
	diagnostic: Numeric_Conversion_Error_Kind,
	err: big.Error,
) {
	#partial switch &value in constant.value {
	case big.Int:
		big.int_copy(&integer, &value, allocator = context.temp_allocator) or_return
	case big.Rat:
		if !big.rat_is_int(&value) { return {}, numeric_nonintegral_float_conversion_error(source_kind), nil }
		big.int_copy(&integer, &value.a, allocator = context.temp_allocator) or_return
	case Float_Value:
		f := numeric_float_value_to_f64(value)
		minimum := f64(min(i64))
		maximum := -minimum
		if f < minimum || f >= maximum { return {}, numeric_nonintegral_float_conversion_error(source_kind), nil }
		i := i64(f)
		if f64(i) != f { return {}, numeric_nonintegral_float_conversion_error(source_kind), nil }
		big.int_set_from_integer(&integer, i, allocator = context.temp_allocator) or_return
	case:
		return {}, numeric_conversion_category(source_kind), nil
	}
	return integer, .None, nil
}

@(private = "file")
numeric_nonintegral_float_conversion_error :: proc(source_kind: types.Kind) -> Numeric_Conversion_Error_Kind {
	if numeric_is_integer_kind(source_kind) { return .Numeric_Conversion_Not_Representable }
	return .Truncated
}

@(private = "file")
numeric_is_integer_kind :: proc(kind: types.Kind) -> bool {
	#partial switch kind {
	case .Integer, .Rune, .Untyped_Integer, .Untyped_Rune:
		return true
	}
	return false
}

@(private = "file")
numeric_integer_is_representable :: proc(store: ^types.Store, type_id: types.Type_Id, value: ^big.Int) -> (ok: bool, err: big.Error) {
	descriptor, _, found := numeric_resolve_scalar_type(store, type_id)
	if !found || (descriptor.kind != .Integer && descriptor.kind != .Rune) { return false, nil }
	byte_count := descriptor.count
	if byte_count <= 0 {
		if descriptor.kind == .Rune { byte_count = 4 } else { byte_count = types.DEFAULT_LAYOUT.int_size }
	}
	bits := int(byte_count * 8)
	if bits <= 0 { return false, nil }
	signed := descriptor.signed || descriptor.kind == .Rune
	negative, negative_error := big.int_is_negative(value, allocator = context.temp_allocator)
	if negative_error != nil { return false, negative_error }
	one, limit, minimum: big.Int
	defer big.int_destroy(&one, &limit, &minimum)
	big.int_set_from_integer(&one, 1, allocator = context.temp_allocator) or_return
	shift := bits
	if signed { shift -= 1 }
	big.int_shl(&limit, &one, shift, allocator = context.temp_allocator) or_return
	if signed {
		if negative {
			big.int_neg(&minimum, &limit, allocator = context.temp_allocator) or_return
			comparison, compare_error := big.int_compare(value, &minimum, allocator = context.temp_allocator)
			if compare_error != nil { return false, compare_error }
			return comparison >= 0, nil
		}
		big.int_sub(&limit, &limit, &one, allocator = context.temp_allocator) or_return
	} else if negative {
		return false, nil
	} else {
		big.int_sub(&limit, &limit, &one, allocator = context.temp_allocator) or_return
	}
	comparison, compare_error := big.int_compare(value, &limit, allocator = context.temp_allocator)
	if compare_error != nil { return false, compare_error }
	return comparison <= 0, nil
}

@(private = "file")
numeric_constant_to_float :: proc(constant: ^Constant, target_width: u8) -> (result: Float_Value, overflowed, err: bool) {
	value: f64
	from_exact: bool
	#partial switch &source in constant.value {
	case big.Int:
		converted, conversion_error := big.int_get_float(&source, allocator = context.temp_allocator)
		if conversion_error != nil { return {}, false, true }
		value = converted
		from_exact = true
	case big.Rat:
		rational_value, _, conversion_error := numeric_rational_to_f64(&source, target_width)
		if conversion_error { return {}, false, true }
		value = rational_value
		from_exact = true
	case Float_Value:
		value = numeric_float_value_to_f64(source)
	case:
		return {}, false, true
	}
	if target_width == 16 || target_width == 32 { value = f64(f32(value)) }
	if from_exact && (math.is_inf(value, 0) || math.is_nan(value)) { return {}, true, false }
	if from_exact && target_width == 16 && math.is_inf(f64(f16(f32(value))), 0) { return {}, true, false }
	return Float_Value{bits = transmute(u64)value, width = 64}, false, false
}

@(private = "package")
numeric_rational_to_f64 :: proc(value: ^big.Rat, target_width: u8) -> (result: f64, exact, err: bool) {
	switch target_width {
	case 16:
		converted, was_exact, conversion_error := big.rat_to_f16(value, allocator = context.temp_allocator)
		return f64(converted), was_exact, conversion_error != nil
	case 32:
		converted, was_exact, conversion_error := big.rat_to_f32(value, allocator = context.temp_allocator)
		return f64(converted), was_exact, conversion_error != nil
	case 64:
		converted, was_exact, conversion_error := big.rat_to_f64(value, allocator = context.temp_allocator)
		return converted, was_exact, conversion_error != nil
	}
	return 0, false, true
}

@(private = "file")
numeric_float_width :: proc(descriptor: ^types.Type) -> u8 {
	byte_count := descriptor.count
	if byte_count <= 0 { byte_count = 8 }
	switch byte_count {
	case 2:
		return 16
	case 4:
		return 32
	case 8:
		return 64
	}
	return 0
}

@(private = "file")
numeric_complex_component_width :: proc(descriptor: ^types.Type, component_count: int) -> u8 {
	if descriptor.count <= 0 { return 0 }
	bits := descriptor.count * 8 / i64(component_count)
	if bits != 16 && bits != 32 && bits != 64 { return 0 }
	return u8(bits)
}

@(private = "file")
numeric_float_value_to_f64 :: proc(value: Float_Value) -> f64 {
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
numeric_intern_bool :: proc(pool: ^Constant_Pool, value: bool, type_id: types.Type_Id, source: Const_Id) -> (id: Const_Id, err: Numeric_Conversion_Error) {
	result, pool_error := constant_pool_intern_bool(pool, value, type_id)
	if pool_error != nil { return 0, numeric_conversion_error(.Internal_Error, source, type_id) }
	return result, {}
}

@(private = "file")
numeric_intern_integer :: proc(
	pool: ^Constant_Pool,
	value: ^big.Int,
	type_id: types.Type_Id,
	source: Const_Id,
) -> (
	id: Const_Id,
	err: Numeric_Conversion_Error,
) {
	result, pool_error := constant_pool_intern_integer(pool, value, type_id)
	if pool_error != nil { return 0, numeric_conversion_error(.Internal_Error, source, type_id) }
	return result, {}
}

@(private = "file")
numeric_intern_float :: proc(
	pool: ^Constant_Pool,
	value: Float_Value,
	type_id: types.Type_Id,
	source: Const_Id,
) -> (
	id: Const_Id,
	err: Numeric_Conversion_Error,
) {
	result, pool_error := constant_pool_intern_float(pool, value, type_id)
	if pool_error != nil { return 0, numeric_conversion_error(.Internal_Error, source, type_id) }
	return result, {}
}

@(private = "file")
numeric_constant_to_complex :: proc(
	pool: ^Constant_Pool,
	source_id: Const_Id,
	source_value: Constant_Value,
	source_kind: types.Kind,
	width: u8,
) -> (
	result: Complex_Value,
	diagnostic: Numeric_Conversion_Error_Kind,
	ok: bool,
) {
	#partial switch value in source_value {
	case Complex_Value:
		for i in 0 ..< 2 {
			component, component_error := numeric_convert_float_component(pool, value[i], width, source_id)
			if component_error.kind != .None { return {}, component_error.kind, false }
			result[i] = component
		}
		return result, .None, true
	case big.Int, big.Rat, Float_Value:
		real, conversion_error := numeric_convert_float_component(pool, source_id, width, source_id)
		if conversion_error.kind != .None { return {}, conversion_error.kind, false }
		imaginary, zero_error := numeric_zero_float_component(pool, source_id)
		if zero_error.kind != .None { return {}, zero_error.kind, false }
		return Complex_Value{real, imaginary}, .None, true
	}
	return {}, numeric_conversion_category(source_kind), false
}

@(private = "file")
numeric_constant_to_quaternion :: proc(
	pool: ^Constant_Pool,
	source_id: Const_Id,
	source_value: Constant_Value,
	source_kind: types.Kind,
	width: u8,
) -> (
	result: Quaternion_Value,
	diagnostic: Numeric_Conversion_Error_Kind,
	ok: bool,
) {
	#partial switch value in source_value {
	case Quaternion_Value:
		for i in 0 ..< 4 {
			component, component_error := numeric_convert_float_component(pool, value[i], width, source_id)
			if component_error.kind != .None { return {}, component_error.kind, false }
			result[i] = component
		}
		return result, .None, true
	case Complex_Value:
		for i in 0 ..< 2 {
			component, component_error := numeric_convert_float_component(pool, value[i], width, source_id)
			if component_error.kind != .None { return {}, component_error.kind, false }
			result[i] = component
		}
		for i in 2 ..< 4 {
			zero, zero_error := numeric_zero_float_component(pool, source_id)
			if zero_error.kind != .None { return {}, zero_error.kind, false }
			result[i] = zero
		}
		return result, .None, true
	case big.Int, big.Rat, Float_Value:
		real, conversion_error := numeric_convert_float_component(pool, source_id, width, source_id)
		if conversion_error.kind != .None { return {}, conversion_error.kind, false }
		result[0] = real
		for i in 1 ..< 4 {
			zero, zero_error := numeric_zero_float_component(pool, source_id)
			if zero_error.kind != .None { return {}, zero_error.kind, false }
			result[i] = zero
		}
		return result, .None, true
	}
	return {}, numeric_conversion_category(source_kind), false
}

@(private = "file")
numeric_convert_float_component :: proc(
	pool: ^Constant_Pool,
	source_id: Const_Id,
	width: u8,
	root_source: Const_Id,
) -> (
	id: Const_Id,
	err: Numeric_Conversion_Error,
) {
	constant := constant_pool_get(pool, source_id)
	value: f64
	exact_source := false
	#partial switch &component in constant.value {
	case big.Int:
		rational: big.Rat
		defer big.destroy(&rational)
		if conversion_error := big.rat_set_int(&rational, &component, allocator = context.temp_allocator); conversion_error != nil {
			return 0, numeric_conversion_error(.Internal_Error, root_source, 0)
		}
		converted, _, conversion_error := numeric_rational_to_f64(&rational, width)
		if conversion_error { return 0, numeric_conversion_error(.Internal_Error, root_source, 0) }
		value = converted
		exact_source = true
	case big.Rat:
		converted, _, conversion_error := numeric_rational_to_f64(&component, width)
		if conversion_error { return 0, numeric_conversion_error(.Internal_Error, root_source, 0) }
		value = converted
		exact_source = true
	case Float_Value:
		value = numeric_float_value_to_f64(component)
	case:
		return 0, numeric_conversion_error(.Numeric_Conversion_Not_Representable, root_source, 0)
	}
	if exact_source && (math.is_inf(value, 0) || math.is_nan(value)) {
		return 0, numeric_conversion_error(.Numeric_Conversion_Not_Representable, root_source, 0)
	}
	converted := Float_Value {
		bits  = transmute(u64)value,
		width = 64,
	}
	result, pool_error := constant_pool_intern_float(pool, converted)
	if pool_error != nil { return 0, numeric_conversion_error(.Internal_Error, root_source, 0) }
	return result, {}
}

@(private = "file")
numeric_zero_float_component :: proc(pool: ^Constant_Pool, root_source: Const_Id) -> (id: Const_Id, err: Numeric_Conversion_Error) {
	zero := Float_Value {
		bits  = transmute(u64)f64(0),
		width = 64,
	}
	result, pool_error := constant_pool_intern_float(pool, zero)
	if pool_error != nil { return 0, numeric_conversion_error(.Internal_Error, root_source, 0) }
	return result, {}
}

@(private = "file")
numeric_promote_untyped_constant :: proc(
	pool: ^Constant_Pool,
	store: ^types.Store,
	source_id: Const_Id,
	source_type, target_type: types.Type_Id,
) -> (
	id: Const_Id,
	err: Numeric_Conversion_Error,
) {
	source, _, source_ok := numeric_resolve_scalar_type(store, source_type)
	target, _, target_ok := numeric_resolve_scalar_type(store, target_type)
	if !source_ok { return 0, numeric_conversion_error(.Invalid_Source, source_id, target_type) }
	if !target_ok { return 0, numeric_conversion_error(.Invalid_Target, source_id, target_type) }
	if source_type == target_type { return source_id, {} }
	source_rank := numeric_untyped_rank(source.kind)
	target_rank := numeric_untyped_rank(target.kind)
	if source_rank < 0 || target_rank < 0 { return 0, numeric_conversion_error(.Cannot_Convert_Untyped_Value, source_id, target_type) }
	if target_rank <= source_rank { return source_id, {} }
	constant := constant_pool_get(pool, source_id)
	#partial switch &value in constant.value {
	case bool:
		return numeric_intern_bool(pool, value, target_type, source_id)
	case big.Int:
		if target.kind == .Untyped_Float {
			rational: big.Rat
			defer big.destroy(&rational)
			if set_error := big.rat_set_int(&rational, &value, allocator = context.temp_allocator); set_error != nil {
				return 0, numeric_conversion_error(.Internal_Error, source_id, target_type)
			}
			result, pool_error := constant_pool_intern_rational(pool, &rational, target_type)
			if pool_error != nil { return 0, numeric_conversion_error(.Internal_Error, source_id, target_type) }
			return result, {}
		}
		return numeric_intern_integer(pool, &value, target_type, source_id)
	case big.Rat:
		result, pool_error := constant_pool_intern_rational(pool, &value, target_type)
		if pool_error != nil { return 0, numeric_conversion_error(.Internal_Error, source_id, target_type) }
		return result, {}
	case Float_Value:
		return numeric_intern_float(pool, value, target_type, source_id)
	case Complex_Value:
		result, pool_error := constant_pool_intern_complex(pool, value, target_type)
		if pool_error != nil { return 0, numeric_conversion_error(.Internal_Error, source_id, target_type) }
		return result, {}
	case Quaternion_Value:
		result, pool_error := constant_pool_intern_quaternion(pool, value, target_type)
		if pool_error != nil { return 0, numeric_conversion_error(.Internal_Error, source_id, target_type) }
		return result, {}
	}
	return 0, numeric_conversion_error(.Cannot_Convert_Untyped_Value, source_id, target_type)
}

@(private = "file")
numeric_is_untyped_type :: proc(store: ^types.Store, type_id: types.Type_Id) -> bool {
	return types.is_untyped(store, type_id)
}

@(private = "file")
numeric_default_type_of_untyped :: proc(store: ^types.Store, type_id: types.Type_Id) -> types.Type_Id {
	return types.default_type_of_untyped(store, type_id)
}

@(private = "file")
numeric_is_untyped_kind :: proc(kind: types.Kind) -> bool {
	#partial switch kind {
	case .Untyped_Bool, .Untyped_Integer, .Untyped_Rune, .Untyped_Float, .Untyped_Complex, .Untyped_Quaternion, .Untyped_String, .Untyped_Nil:
		return true
	}
	return false
}

@(private = "file")
numeric_untyped_rank :: proc(kind: types.Kind) -> int {
	#partial switch kind {
	case .Untyped_Integer:
		return 0
	case .Untyped_Float:
		return 1
	case .Untyped_Complex:
		return 2
	case .Untyped_Quaternion:
		return 3
	case .Untyped_Rune:
		return 4
	}
	return -1
}
