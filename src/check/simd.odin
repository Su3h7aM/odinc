package check

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
	case .Simd_Indices, .Simd_Select, .Simd_Lanes_Ne, .Simd_Reduce_Or, .Simd_Reduce_Min:
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

// Checks the `#simd` intrinsics the checker plans, with the result rules of the official check_builtin.cpp:
// lanes_ne yields the unsigned integer of the element size per lane, select tests mask lanes for nonzero,
// and reduce_or and reduce_min yield the element type.
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
	operands: []Operand
	#partial switch kind {
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
	case .Simd_Reduce_Or, .Simd_Reduce_Min:
		if len(arguments) != 1 { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
		value := check_expression(checker, view, scope, arguments[0]) or_return
		if value.state == .Invalid { return expression_poison(scope), nil }
		vector, ok := simd_vector(store, value.type)
		if !ok { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
		element := simd_element_kind(store, vector.elem)
		allowed := element == .Integer || element == .Bool
		if kind == .Simd_Reduce_Min { allowed = element == .Integer || element == .Float }
		if !allowed { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
		operands = make([]Operand, 1, allocator) or_return
		operands[0] = Operand(Expression_Ref{view, arguments[0]})
		result = vector.elem
	case .Simd_Lanes_Ne:
		if len(arguments) != 2 { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
		left := check_expression(checker, view, scope, arguments[0]) or_return
		if left.state == .Invalid { return expression_poison(scope), nil }
		right := check_expression(checker, view, scope, arguments[1], left.type) or_return
		if right.state == .Invalid { return expression_poison(scope), nil }
		vector, ok := simd_vector(store, left.type)
		if !ok || right.type != left.type { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
		element := simd_element_kind(store, vector.elem)
		if element != .Integer && element != .Float && element != .Bool {
			return expression_failure(checker, view, scope, node, .Invalid_Operand)
		}
		size, _, layout_error := types.layout(store, vector.elem)
		if layout_error != .None || size > 8 { return expression_unsupported(checker, view, scope, node, "Simd_Element_Layout") }
		lane := types.intern(store, types.Type{kind = .Integer, count = size})
		result = types.intern(store, types.Type{kind = .Simd_Vector, elem = lane, count = vector.count})
		operands = make([]Operand, 2, allocator) or_return
		operands[0] = Operand(Expression_Ref{view, arguments[0]})
		operands[1] = Operand(Expression_Ref{view, arguments[1]})
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
	case:
		return expression_unsupported(checker, view, scope, node, "Simd_Builtin")
	}
	plan := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(Builtin_Plan{builtin = builtin, arguments = operands})) or_return
	return Expression_Info{type = result, mode = .Value, plan = plan, scope = scope, state = .Checked}, nil
}
