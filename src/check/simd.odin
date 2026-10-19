package check

import "core:math/big"
import "core:mem"
import "oc:syntax"
import "oc:types"

// Lane count limit of `#simd` vectors, as SIMD_ELEMENT_COUNT_MAX in the official compiler.
SIMD_ELEMENT_COUNT_MAX :: 64

// Integers, floats, booleans and rawptr without an explicit endianness may be vector elements.
simd_element_valid :: proc(store: ^types.Store, elem: types.Type_Id) -> bool {
	element := types.get(store, types.resolve_named(store, elem))^
	#partial switch element.kind {
	case .Integer, .Float, .Bool, .Raw_Pointer:
		return element.endianness == .Native
	}
	return false
}

// The `#simd[N]T` type expression: an array type tagged `#simd`, with a power-of-two lane count.
simd_array_type :: proc(
	checker: ^Type_Checker,
	file_id: File_Id,
	file: ^File,
	scope: Scope_Id,
	array: syntax.Array_Type,
) -> (
	type: types.Type_Id,
	err: Resolve_Error,
) {
	if expression_text(file, array.tag) != "#simd" {
		type_report(checker, file_id, file, array.tag, .Unsupported_Type_Expression) or_return
		return types.TYPE_POISON, nil
	}
	count, count_valid := array_count(checker, file_id, scope, array.len) or_return
	elem := type_expression(checker, file_id, scope, array.elem, true) or_return
	if !count_valid || elem == types.TYPE_POISON { return types.TYPE_POISON, nil }
	if count < 1 || (count & (count - 1)) != 0 || count > SIMD_ELEMENT_COUNT_MAX {
		type_report(checker, file_id, file, array.len, .Invalid_Simd_Count) or_return
		return types.TYPE_POISON, nil
	}
	if !simd_element_valid(checker.store, elem) {
		type_report(checker, file_id, file, array.elem, .Invalid_Simd_Element) or_return
		return types.TYPE_POISON, nil
	}
	return types.intern(checker.store, types.Type{kind = .Simd_Vector, elem = elem, count = count}), nil
}

simd_builtin_kind :: proc(kind: Builtin_Kind) -> bool {
	#partial switch kind {
	case .Simd_Extract, .Simd_Replace, .Simd_Indices, .Simd_Select, .Simd_Shuffle:
		return true
	case .Simd_Lanes_Eq, .Simd_Lanes_Ne, .Simd_Lanes_Lt, .Simd_Lanes_Le, .Simd_Lanes_Gt, .Simd_Lanes_Ge:
		return true
	case .Simd_Add, .Simd_Sub, .Simd_Mul, .Simd_Div, .Simd_Bit_And, .Simd_Bit_Or, .Simd_Bit_Xor, .Simd_Bit_And_Not, .Simd_Min, .Simd_Max:
		return true
	case .Simd_Saturating_Add, .Simd_Saturating_Sub:
		return true
	case .Simd_Gather, .Simd_Scatter, .Simd_Masked_Load, .Simd_Masked_Store, .Simd_Masked_Expand_Load, .Simd_Masked_Compress_Store:
		return true
	case .Simd_Shl, .Simd_Shr, .Simd_Shl_Masked, .Simd_Shr_Masked:
		return true
	}
	return false
}

// A typed scalar of the element type, assigned to a vector, fills every lane.
simd_broadcast_allowed :: proc(target: types.Type, source: types.Type_Id) -> bool {
	return target.kind == .Simd_Vector && target.elem == source
}

// Returns a copy: interning a new type may reallocate the store.
@(private = "file")
simd_vector :: proc(store: ^types.Store, id: types.Type_Id) -> (vector: types.Type, ok: bool) {
	vector = types.get(store, types.resolve_named(store, id))^
	return vector, vector.kind == .Simd_Vector
}

@(private = "file")
simd_element_kind :: proc(store: ^types.Store, elem: types.Type_Id) -> types.Kind {
	return types.get(store, types.resolve_named(store, elem)).kind
}

@(private = "file")
simd_compare_allowed :: proc(kind: Builtin_Kind, element: types.Kind) -> bool {
	if kind == .Simd_Lanes_Eq || kind == .Simd_Lanes_Ne { return element == .Integer || element == .Float || element == .Bool }
	return element == .Integer || element == .Float
}

@(private = "file")
simd_lanewise_allowed :: proc(kind: Builtin_Kind, element: types.Kind) -> bool {
	#partial switch kind {
	case .Simd_Add, .Simd_Sub, .Simd_Mul:
		return element == .Integer || element == .Float
	case .Simd_Div:
		return element == .Float
	}
	return element == .Integer
}

// Checks the `#simd` intrinsics the checker plans, with the result rules of the official check_builtin.cpp:
// lanes_ne yields the unsigned integer of the element size per lane and select tests mask lanes for nonzero.
@(private = "package")
expression_simd_call :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	builtin: Builtin_Id,
	kind: Builtin_Kind,
	arguments: []syntax.Node_Index,
	ellipsis: bool,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	if ellipsis { return expression_unsupported(checker, view, scope, node, "Simd_Spread") }
	store := checker.type_checker.store
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	result := types.TYPE_NONE
	mode := Addressing_Mode.Value
	operands: []Operand
	#partial switch kind {
	case .Simd_Gather, .Simd_Scatter, .Simd_Masked_Load, .Simd_Masked_Store, .Simd_Masked_Expand_Load, .Simd_Masked_Compress_Store:
		if len(arguments) != 3 { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
		address := check_expression(checker, view, scope, arguments[0]) or_return
		values := check_expression(checker, view, scope, arguments[1]) or_return
		mask := check_expression(checker, view, scope, arguments[2]) or_return
		if address.state == .Invalid || values.state == .Invalid || mask.state == .Invalid { return expression_poison(scope), nil }
		vector, vector_ok := simd_vector(store, values.type)
		mask_vector, mask_ok := simd_vector(store, mask.type)
		if !vector_ok || !mask_ok || !expression_value(address) || !expression_value(values) || !expression_value(mask) {
			return expression_failure(checker, view, scope, node, .Invalid_Operand)
		}
		mask_element := simd_element_kind(store, mask_vector.elem)
		if vector.count != mask_vector.count || (mask_element != .Integer && mask_element != .Bool) {
			return expression_failure(checker, view, scope, arguments[2], .Invalid_Operand)
		}
		if kind == .Simd_Gather || kind == .Simd_Scatter {
			addresses, addresses_ok := simd_vector(store, address.type)
			if !addresses_ok || addresses.count != vector.count || simd_element_kind(store, addresses.elem) != .Raw_Pointer {
				return expression_failure(checker, view, scope, arguments[0], .Invalid_Operand)
			}
		} else {
			address_kind := types.get(store, types.resolve_named(store, address.type)).kind
			if address_kind != .Pointer && address_kind != .Raw_Pointer {
				return expression_failure(checker, view, scope, arguments[0], .Invalid_Operand)
			}
		}
		operands = make([]Operand, 3, allocator) or_return
		for argument, index in arguments { operands[index] = Operand(Expression_Ref{view, argument}) }
		if kind == .Simd_Gather || kind == .Simd_Masked_Load || kind == .Simd_Masked_Expand_Load {
			result = values.type
		} else {
			mode = .No_Value
		}
	case .Simd_Extract:
		if len(arguments) != 2 { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
		value := check_expression(checker, view, scope, arguments[0]) or_return
		if value.state == .Invalid { return expression_poison(scope), nil }
		vector, is_vector := simd_vector(store, value.type)
		if !is_vector || !expression_value(value) { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
		position := check_expression(checker, view, scope, arguments[1]) or_return
		if position.state == .Invalid { return expression_poison(scope), nil }
		if types.is_untyped(store, position.type) {
			position = check_expression(checker, view, scope, arguments[1], checker.default_integer) or_return
			if position.state == .Invalid { return expression_poison(scope), nil }
		}
		position_kind := types.get(store, types.resolve_named(store, position.type)).kind
		if !expression_value(position) || position_kind != .Integer && position_kind != .Enum {
			return expression_failure(checker, view, scope, arguments[1], .Invalid_Operand)
		}
		if position.mode == .Constant &&
		   checker.unchecked_depth == 0 &&
		   checker.type_checker.files[checker.views[view].file].policy.bounds_check != .Disabled {
			integer := constant_pool_get(checker.constants, position.constant).value.(big.Int)
			index, index_error := big.int_get_i64(&integer)
			if index_error != nil || index < 0 || index >= vector.count {
				return expression_failure(checker, view, scope, arguments[1], .Invalid_Operand)
			}
		}
		operands = make([]Operand, 2, allocator) or_return
		operands[0] = Operand(Expression_Ref{view, arguments[0]})
		operands[1] = Operand(Expression_Ref{view, arguments[1]})
		result = vector.elem
	case .Simd_Replace:
		if len(arguments) != 3 { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
		value := check_expression(checker, view, scope, arguments[0]) or_return
		if value.state == .Invalid { return expression_poison(scope), nil }
		vector, is_vector := simd_vector(store, value.type)
		if !is_vector || !expression_value(value) { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
		position := check_expression(checker, view, scope, arguments[1]) or_return
		if position.state == .Invalid { return expression_poison(scope), nil }
		if types.is_untyped(store, position.type) {
			position = check_expression(checker, view, scope, arguments[1], checker.default_integer) or_return
			if position.state == .Invalid { return expression_poison(scope), nil }
		}
		position_kind := types.get(store, types.resolve_named(store, position.type)).kind
		if !expression_value(position) || position_kind != .Integer && position_kind != .Enum {
			return expression_failure(checker, view, scope, arguments[1], .Invalid_Operand)
		}
		if position.mode == .Constant &&
		   checker.unchecked_depth == 0 &&
		   checker.type_checker.files[checker.views[view].file].policy.bounds_check != .Disabled {
			integer := constant_pool_get(checker.constants, position.constant).value.(big.Int)
			index, index_error := big.int_get_i64(&integer)
			if index_error != nil || index < 0 || index >= vector.count {
				return expression_failure(checker, view, scope, arguments[1], .Invalid_Operand)
			}
		}
		element := check_expression(checker, view, scope, arguments[2], vector.elem) or_return
		if element.state == .Invalid { return expression_poison(scope), nil }
		if element.type != vector.elem { return expression_failure(checker, view, scope, arguments[2], .Mismatched_Types) }
		operands = make([]Operand, 3, allocator) or_return
		operands[0] = Operand(Expression_Ref{view, arguments[0]})
		operands[1] = Operand(Expression_Ref{view, arguments[1]})
		operands[2] = Operand(Expression_Ref{view, arguments[2]})
		result = value.type
	case .Simd_Indices:
		if len(arguments) != 1 { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
		vector_type := type_expression(checker.type_checker, checker.views[view].file, scope, arguments[0], true) or_return
		if vector_type == types.TYPE_POISON { return expression_poison(scope), nil }
		vector, is_vector := simd_vector(store, vector_type)
		if !is_vector { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
		if kind := simd_element_kind(store, vector.elem); kind != .Integer && kind != .Float {
			return expression_failure(checker, view, scope, node, .Invalid_Operand)
		}
		result = vector_type
	case .Simd_Lanes_Eq, .Simd_Lanes_Ne, .Simd_Lanes_Lt, .Simd_Lanes_Le, .Simd_Lanes_Gt, .Simd_Lanes_Ge:
		if len(arguments) != 2 { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
		left := check_expression(checker, view, scope, arguments[0]) or_return
		if left.state == .Invalid { return expression_poison(scope), nil }
		right := check_expression(checker, view, scope, arguments[1], left.type) or_return
		if right.state == .Invalid { return expression_poison(scope), nil }
		vector, ok := simd_vector(store, left.type)
		if !ok || right.type != left.type { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
		element := simd_element_kind(store, vector.elem)
		if !simd_compare_allowed(kind, element) {
			return expression_failure(checker, view, scope, node, .Invalid_Operand)
		}
		size, _, layout_error := types.layout(store, vector.elem)
		if layout_error != .None || size > 8 { return expression_unsupported(checker, view, scope, node, "Simd_Element_Layout") }
		lane := types.sized_integer(store, size, false)
		result = types.intern(store, types.Type{kind = .Simd_Vector, elem = lane, count = vector.count})
		operands = make([]Operand, 2, allocator) or_return
		operands[0] = Operand(Expression_Ref{view, arguments[0]})
		operands[1] = Operand(Expression_Ref{view, arguments[1]})
	case .Simd_Add,
	     .Simd_Sub,
	     .Simd_Mul,
	     .Simd_Div,
	     .Simd_Bit_And,
	     .Simd_Bit_Or,
	     .Simd_Bit_Xor,
	     .Simd_Bit_And_Not,
	     .Simd_Min,
	     .Simd_Max,
	     .Simd_Saturating_Add,
	     .Simd_Saturating_Sub:
		if len(arguments) != 2 { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
		left := check_expression(checker, view, scope, arguments[0]) or_return
		if left.state == .Invalid { return expression_poison(scope), nil }
		right := check_expression(checker, view, scope, arguments[1], left.type) or_return
		if right.state == .Invalid { return expression_poison(scope), nil }
		vector, ok := simd_vector(store, left.type)
		if !ok || right.type != left.type || !expression_value(left) || !expression_value(right) {
			return expression_failure(checker, view, scope, node, .Invalid_Operand)
		}
		if !simd_lanewise_allowed(kind, simd_element_kind(store, vector.elem)) {
			return expression_failure(checker, view, scope, node, .Invalid_Operand)
		}
		operands = make([]Operand, 2, allocator) or_return
		operands[0] = Operand(Expression_Ref{view, arguments[0]})
		operands[1] = Operand(Expression_Ref{view, arguments[1]})
		result = left.type
	case .Simd_Shl, .Simd_Shr, .Simd_Shl_Masked, .Simd_Shr_Masked:
		if len(arguments) != 2 { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
		value := check_expression(checker, view, scope, arguments[0]) or_return
		if value.state == .Invalid { return expression_poison(scope), nil }
		amount := check_expression(checker, view, scope, arguments[1]) or_return
		if amount.state == .Invalid { return expression_poison(scope), nil }
		vector, ok := simd_vector(store, value.type)
		amounts, amounts_ok := simd_vector(store, amount.type)
		if !ok || !amounts_ok || amounts.count != vector.count || !expression_value(value) || !expression_value(amount) {
			return expression_failure(checker, view, scope, node, .Invalid_Operand)
		}
		if simd_element_kind(store, vector.elem) != .Integer || simd_element_kind(store, amounts.elem) != .Integer {
			return expression_failure(checker, view, scope, node, .Invalid_Operand)
		}
		if types.get(store, types.resolve_named(store, amounts.elem)).signed {
			return expression_failure(checker, view, scope, node, .Invalid_Operand)
		}
		operands = make([]Operand, 2, allocator) or_return
		operands[0] = Operand(Expression_Ref{view, arguments[0]})
		operands[1] = Operand(Expression_Ref{view, arguments[1]})
		result = value.type
	case .Simd_Select:
		if len(arguments) != 3 { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
		condition := check_expression(checker, view, scope, arguments[0]) or_return
		if condition.state == .Invalid { return expression_poison(scope), nil }
		when_true := check_expression(checker, view, scope, arguments[1]) or_return
		if when_true.state == .Invalid { return expression_poison(scope), nil }
		when_false := check_expression(checker, view, scope, arguments[2], when_true.type) or_return
		if when_false.state == .Invalid { return expression_poison(scope), nil }
		mask, mask_ok := simd_vector(store, condition.type)
		values, values_ok := simd_vector(store, when_true.type)
		if !mask_ok || !values_ok || when_false.type != when_true.type {
			return expression_failure(checker, view, scope, node, .Invalid_Operand)
		}
		mask_element := simd_element_kind(store, mask.elem)
		if (mask_element != .Integer && mask_element != .Bool) || mask.count != values.count {
			return expression_failure(checker, view, scope, node, .Invalid_Operand)
		}
		operands = make([]Operand, 3, allocator) or_return
		operands[0] = Operand(Expression_Ref{view, arguments[0]})
		operands[1] = Operand(Expression_Ref{view, arguments[1]})
		operands[2] = Operand(Expression_Ref{view, arguments[2]})
		result = when_true.type
	case .Simd_Shuffle:
		if len(arguments) < 3 { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
		left := check_expression(checker, view, scope, arguments[0]) or_return
		if left.state == .Invalid { return expression_poison(scope), nil }
		right := check_expression(checker, view, scope, arguments[1], left.type) or_return
		if right.state == .Invalid { return expression_poison(scope), nil }
		vector, is_vector := simd_vector(store, left.type)
		if !is_vector || right.type != left.type || !expression_value(left) || !expression_value(right) {
			return expression_failure(checker, view, scope, node, .Invalid_Operand)
		}
		lane_count := i64(len(arguments) - 2)
		if lane_count > SIMD_ELEMENT_COUNT_MAX || (lane_count & (lane_count - 1)) != 0 {
			return expression_failure(checker, view, scope, node, .Invalid_Operand)
		}
		operands = make([]Operand, len(arguments), allocator) or_return
		operands[0] = Operand(Expression_Ref{view, arguments[0]})
		operands[1] = Operand(Expression_Ref{view, arguments[1]})
		for argument, index in arguments[2:] {
			position := check_expression(checker, view, scope, argument, checker.default_integer) or_return
			if position.state == .Invalid { return expression_poison(scope), nil }
			position_kind := types.get(store, types.resolve_named(store, position.type)).kind
			if position.mode != .Constant || position_kind != .Integer {
				return expression_failure(checker, view, scope, argument, .Invalid_Operand)
			}
			integer := constant_pool_get(checker.constants, position.constant).value.(big.Int)
			lane, lane_error := big.int_get_i64(&integer)
			if lane_error != nil || lane < 0 || lane >= 2 * vector.count {
				return expression_failure(checker, view, scope, argument, .Invalid_Operand)
			}
			operands[index + 2] = Operand(position.constant)
		}
		result = types.intern(store, types.Type{kind = .Simd_Vector, elem = vector.elem, count = lane_count})
	case:
		return expression_unsupported(checker, view, scope, node, "Simd_Builtin")
	}
	plan := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(Builtin_Plan{builtin = builtin, arguments = operands})) or_return
	return Expression_Info{type = result, mode = mode, plan = plan, scope = scope, state = .Checked}, nil
}
