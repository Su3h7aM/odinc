package check

import "core:math/big"
import "oc:syntax"
import "oc:types"

// Names bound by one generic call, in order of first binding. A constant name has a nonzero constant.
Poly_Bindings :: struct {
	names:     [dynamic]string,
	types:     [dynamic]types.Type_Id,
	constants: [dynamic]Const_Id,
}

// The call being matched: its patterns live in definition_file and scope, its diagnostics point at call_node in call_file.
Poly_Match :: struct {
	checker:         ^Expression_Checker,
	call_file:       File_Id,
	call_node:       syntax.Node_Index,
	definition_file: File_Id,
	scope:           Scope_Id,
	bindings:        ^Poly_Bindings,
}

// Binds name, or checks that an earlier binding of name has the same type and constant.
@(private = "package")
poly_bind :: proc(store: ^types.Store, bindings: ^Poly_Bindings, name: string, type: types.Type_Id, constant: Const_Id) -> (bound: bool, err: Resolve_Error) {
	for bound_name, index in bindings.names {
		if bound_name == name { return types.are_identical(store, bindings.types[index], type) && bindings.constants[index] == constant, nil }
	}
	append(&bindings.names, name) or_return
	append(&bindings.types, type) or_return
	append(&bindings.constants, constant) or_return
	return true, nil
}

@(private = "package")
poly_pattern_has_poly :: proc(file: ^File, pattern: syntax.Node_Index) -> bool {
	#partial switch file.ast.nodes[pattern].kind {
	case .Poly_Type:
		return true
	case .Call_Expr:
		call := syntax.node_payload(file.ast, pattern, syntax.Call_Expr)
		for argument in syntax.node_list(file.ast, call.args) {
			if poly_pattern_has_poly(file, argument) { return true }
		}
	case .Field_Value:
		return poly_pattern_has_poly(file, syntax.node_payload(file.ast, pattern, syntax.Field_Value).value)
	case .Pointer_Type:
		return poly_pattern_has_poly(file, syntax.node_payload(file.ast, pattern, syntax.Pointer_Type).elem)
	case .Multi_Pointer_Type:
		return poly_pattern_has_poly(file, syntax.node_payload(file.ast, pattern, syntax.Multi_Pointer_Type).elem)
	case .Dynamic_Array_Type:
		return poly_pattern_has_poly(file, syntax.node_payload(file.ast, pattern, syntax.Dynamic_Array_Type).elem)
	case .Array_Type:
		array := syntax.node_payload(file.ast, pattern, syntax.Array_Type)
		return poly_pattern_has_poly(file, array.elem) || (array.len != 0 && file.ast.nodes[array.len].kind == .Poly_Type)
	case .Fixed_Capacity_Dynamic_Array_Type:
		array := syntax.node_payload(file.ast, pattern, syntax.Fixed_Capacity_Dynamic_Array_Type)
		return poly_pattern_has_poly(file, array.elem) || file.ast.nodes[array.capacity].kind == .Poly_Type
	case .Map_Type:
		map_type := syntax.node_payload(file.ast, pattern, syntax.Map_Type)
		return poly_pattern_has_poly(file, map_type.key) || poly_pattern_has_poly(file, map_type.value)
	case .Bit_Set_Type:
		set_type := syntax.node_payload(file.ast, pattern, syntax.Bit_Set_Type)
		return poly_pattern_has_poly(file, set_type.elem) || set_type.underlying != 0 && poly_pattern_has_poly(file, set_type.underlying)
	}
	return false
}

// Matches an argument type against a parameter pattern, binding the polymorphic names it contains. Reports false
// when the argument does not have the pattern's shape.
@(private = "package")
poly_match_pattern :: proc(match: ^Poly_Match, pattern: syntax.Node_Index, argument: types.Type_Id) -> (matched: bool, err: Resolve_Error) {
	file := match.checker.type_checker.files[match.definition_file]
	#partial switch file.ast.nodes[pattern].kind {
	case .Call_Expr:
		return poly_match_record(match, pattern, argument)
	case .Poly_Type:
		poly := syntax.node_payload(file.ast, pattern, syntax.Poly_Type)
		bound := poly_bind(match.checker.type_checker.store, match.bindings, expression_text(file, poly.type), argument, 0) or_return
		if !bound || poly.specialization == 0 { return bound, nil }
		return poly_match_pattern(match, poly.specialization, argument)
	case .Pointer_Type:
		elem := syntax.node_payload(file.ast, pattern, syntax.Pointer_Type).elem
		return poly_match_element(match, .Pointer, elem, argument)
	case .Multi_Pointer_Type:
		elem := syntax.node_payload(file.ast, pattern, syntax.Multi_Pointer_Type).elem
		return poly_match_element(match, .Multi_Pointer, elem, argument)
	case .Dynamic_Array_Type:
		array := syntax.node_payload(file.ast, pattern, syntax.Dynamic_Array_Type)
		if array.tag != 0 { return false, nil }
		return poly_match_element(match, .Dynamic_Array, array.elem, argument)
	case .Array_Type:
		array := syntax.node_payload(file.ast, pattern, syntax.Array_Type)
		if array.tag != 0 { return false, nil }
		if array.len == 0 { return poly_match_element(match, .Slice, array.elem, argument) }
		return poly_match_array(match, .Array, array.len, array.elem, argument)
	case .Fixed_Capacity_Dynamic_Array_Type:
		array := syntax.node_payload(file.ast, pattern, syntax.Fixed_Capacity_Dynamic_Array_Type)
		return poly_match_array(match, .Fixed_Capacity_Array, array.capacity, array.elem, argument)
	case .Map_Type:
		map_type := syntax.node_payload(file.ast, pattern, syntax.Map_Type)
		store := match.checker.type_checker.store
		descriptor := types.get(store, underlying_type(store, argument))
		if descriptor.kind != .Map { return false, nil }
		key, value := descriptor.index, descriptor.elem
		matched_key := poly_match_pattern(match, map_type.key, key) or_return
		if !matched_key { return false, nil }
		return poly_match_pattern(match, map_type.value, value)
	case .Bit_Set_Type:
		set_type := syntax.node_payload(file.ast, pattern, syntax.Bit_Set_Type)
		store := match.checker.type_checker.store
		descriptor := types.get(store, underlying_type(store, argument))^
		if descriptor.kind != .Bit_Set { return false, nil }
		if !poly_pattern_has_poly(file, set_type.elem) {
			expected := type_expression(match.checker.type_checker, match.definition_file, match.scope, pattern, true) or_return
			return expected != types.TYPE_POISON && types.are_identical(store, underlying_type(store, expected), underlying_type(store, argument)), nil
		}
		matched = poly_match_pattern(match, set_type.elem, descriptor.elem) or_return
		if !matched || set_type.underlying == 0 { return matched, nil }
		backing := descriptor.backing
		if backing == 0 {
			size, _, failure := types.layout(store, argument)
			if failure != .None { return false, nil }
			backing = types.sized_integer(store, size, false)
		}
		return poly_match_pattern(match, set_type.underlying, backing)
	}
	expected := type_expression(match.checker.type_checker, match.definition_file, match.scope, pattern, true) or_return
	return expected != types.TYPE_POISON && types.are_identical(match.checker.type_checker.store, expected, argument), nil
}

@(private = "file")
poly_match_element :: proc(match: ^Poly_Match, kind: types.Kind, elem: syntax.Node_Index, argument: types.Type_Id) -> (matched: bool, err: Resolve_Error) {
	store := match.checker.type_checker.store
	descriptor := types.get(store, underlying_type(store, argument))
	if descriptor.kind != kind { return false, nil }
	element := descriptor.elem
	return poly_match_pattern(match, elem, element)
}

// A length that is a polymorphic name binds the count as a constant; any other length must equal the count.
@(private = "file")
poly_match_array :: proc(
	match: ^Poly_Match,
	kind: types.Kind,
	length: syntax.Node_Index,
	elem: syntax.Node_Index,
	argument: types.Type_Id,
) -> (
	matched: bool,
	err: Resolve_Error,
) {
	store := match.checker.type_checker.store
	descriptor := types.get(store, underlying_type(store, argument))
	if descriptor.kind != kind { return false, nil }
	count, element := descriptor.count, descriptor.elem
	file := match.checker.type_checker.files[match.definition_file]
	if file.ast.nodes[length].kind == .Poly_Type {
		name := expression_text(file, syntax.node_payload(file.ast, length, syntax.Poly_Type).type)
		constant, ok, constant_error := poly_integer_constant(match, count)
		if constant_error != nil || !ok { return false, constant_error }
		bound := poly_bind(match.checker.type_checker.store, match.bindings, name, match.checker.default_integer, constant) or_return
		if !bound { return false, nil }
	} else {
		expected, valid, count_error := array_count(match.checker.type_checker, match.definition_file, match.scope, length)
		if count_error != nil { return false, count_error }
		if !valid || expected != count { return false, nil }
	}
	return poly_match_pattern(match, elem, element)
}

@(private = "file")
poly_integer_constant :: proc(match: ^Poly_Match, value: i64) -> (constant: Const_Id, ok: bool, err: Resolve_Error) {
	integer: big.Int
	defer big.destroy(&integer)
	if set_error := big.set(&integer, value); set_error != nil {
		return 0, false, expression_constant_failure(match.checker, match.call_file, match.call_node, set_error)
	}
	interned, intern_error := constant_pool_intern_integer(match.checker.constants, &integer, match.checker.default_integer)
	if intern_error != nil {
		return 0, false, expression_constant_failure(match.checker, match.call_file, match.call_node, intern_error)
	}
	return interned, true, nil
}
