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

// Whether an argument of a different type still matches an already-bound polymorphic name: it must
// convert to the bound type under assignment, as the instance call converts it. Speculative only.
@(private = "file")
poly_rebind_assignable :: proc(match: ^Poly_Match, name: string, argument: types.Type_Id) -> (matched: bool, err: Resolve_Error) {
	checker := match.checker
	store := checker.type_checker.store
	for bound_name, index in match.bindings.names {
		if bound_name != name { continue }
		if match.bindings.constants[index] != 0 { return false, nil }
		bound := match.bindings.types[index]
		if types.are_identical(store, bound, argument) { return true, nil }
		info := Expression_Info {
			type  = argument,
			mode  = .Value,
			scope = match.scope,
			state = .Checked,
		}
		_, diagnostic, failure := check_conversion(checker.constants, store, Operand(nil), info, bound, .Assignment, checker.config)
		if failure != nil { return false, nil }
		return diagnostic == .None, nil
	}
	return false, nil
}

@(private = "package")
poly_pattern_has_poly :: proc(file: ^File, pattern: syntax.Node_Index) -> bool {
	#partial switch file.ast.nodes[pattern].kind {
	case .Proc_Type:
		signature := syntax.node_payload(file.ast, pattern, syntax.Proc_Type)
		for fields in ([2]syntax.Node_Index{signature.params, signature.results}) {
			if fields == 0 { continue }
			for field_node in syntax.node_list(file.ast, syntax.node_payload(file.ast, fields, syntax.Field_List).list) {
				field := syntax.node_payload(file.ast, field_node, syntax.Field)
				if poly_pattern_has_poly(file, field.type) { return true }
			}
		}
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
	case .Matrix_Type:
		shape := syntax.node_payload(file.ast, pattern, syntax.Matrix_Type)
		return(
			poly_pattern_has_poly(file, shape.elem) ||
			file.ast.nodes[shape.row_count].kind == .Poly_Type ||
			file.ast.nodes[shape.column_count].kind == .Poly_Type \
		)
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
	case .Proc_Type:
		descriptor := types.get(match.checker.type_checker.store, underlying_type(match.checker.type_checker.store, argument))^
		if descriptor.kind != .Procedure { return false, nil }
		signature := syntax.node_payload(file.ast, pattern, syntax.Proc_Type)
		for fields, index in ([2]syntax.Node_Index{signature.params, signature.results}) {
			field_types := descriptor.params if index == 0 else descriptor.results
			position := 0
			if fields != 0 {
				for field_node in syntax.node_list(file.ast, syntax.node_payload(file.ast, fields, syntax.Field_List).list) {
					field := syntax.node_payload(file.ast, field_node, syntax.Field)
					for _ in 0 ..< max(1, len(syntax.node_list(file.ast, field.names))) {
						if position >= len(field_types) { return false, nil }
						matched = poly_match_pattern(match, field.type, field_types[position]) or_return
						if !matched { return false, nil }
						position += 1
					}
				}
			}
			if position != len(field_types) { return false, nil }
		}
		return true, nil
	case .Call_Expr:
		return poly_match_record(match, pattern, argument)
	case .Poly_Type:
		poly := syntax.node_payload(file.ast, pattern, syntax.Poly_Type)
		bound := poly_bind(match.checker.type_checker.store, match.bindings, expression_text(file, poly.type), argument, 0) or_return
		if !bound {
			// Parameters sharing `$T` bind it from the first argument; a later argument of a
			// different type still matches when it converts to the bound type, as the call
			// converts it (for example a union variant where `T` bound to the union).
			return poly_rebind_assignable(match, expression_text(file, poly.type), argument)
		}
		if poly.specialization == 0 { return true, nil }
		matched = poly_match_pattern(match, poly.specialization, argument) or_return
		if matched || poly_pattern_has_poly(file, poly.specialization) { return matched, nil }
		store := match.checker.type_checker.store
		record := types.get(store, underlying_type(store, argument)).kind
		if record != .Struct && record != .Union { return false, nil }
		bound_scope := poly_bound_scope(match) or_return
		expected := type_expression(match.checker.type_checker, match.definition_file, bound_scope, poly.specialization, true) or_return
		return expected != types.TYPE_POISON && types.are_identical(store, underlying_type(store, expected), underlying_type(store, argument)), nil
	case .Pointer_Type:
		pointer := syntax.node_payload(file.ast, pattern, syntax.Pointer_Type)
		if pointer.tag != 0 {
			return poly_match_soa_pointer(match, file, pointer.tag, pointer.elem, argument)
		}
		return poly_match_element(match, .Pointer, pointer.elem, argument)
	case .Multi_Pointer_Type:
		elem := syntax.node_payload(file.ast, pattern, syntax.Multi_Pointer_Type).elem
		return poly_match_element(match, .Multi_Pointer, elem, argument)
	case .Dynamic_Array_Type:
		array := syntax.node_payload(file.ast, pattern, syntax.Dynamic_Array_Type)
		if array.tag == 0 {
			return poly_match_element(match, .Dynamic_Array, array.elem, argument)
		}
		return poly_match_soa(match, file, array.tag, .Dynamic, 0, array.elem, argument)
	case .Array_Type:
		array := syntax.node_payload(file.ast, pattern, syntax.Array_Type)
		if array.tag != 0 && array.len != 0 && expression_text(file, array.tag) == "#simd" {
			return poly_match_array(match, .Simd_Vector, array.len, array.elem, argument)
		}
		if array.tag == 0 {
			if array.len == 0 { return poly_match_element(match, .Slice, array.elem, argument) }
			return poly_match_array(match, .Array, array.len, array.elem, argument)
		}
		if array.len == 0 {
			return poly_match_soa(match, file, array.tag, .Slice, 0, array.elem, argument)
		}
		return poly_match_soa(match, file, array.tag, .Fixed, array.len, array.elem, argument)
	case .Fixed_Capacity_Dynamic_Array_Type:
		array := syntax.node_payload(file.ast, pattern, syntax.Fixed_Capacity_Dynamic_Array_Type)
		return poly_match_array(match, .Fixed_Capacity_Array, array.capacity, array.elem, argument)
	case .Matrix_Type:
		return poly_match_matrix(match, syntax.node_payload(file.ast, pattern, syntax.Matrix_Type), argument)
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
	bound_matched, is_bound := poly_match_bound_type(match, pattern, argument) or_return
	if is_bound { return bound_matched, nil }
	template_matched, is_template := poly_match_record_template(match, pattern, argument) or_return
	if is_template { return template_matched, nil }
	bound_scope := poly_bound_scope(match) or_return
	expected := type_expression(match.checker.type_checker, match.definition_file, bound_scope, pattern, true) or_return
	return expected != types.TYPE_POISON && types.are_identical(match.checker.type_checker.store, expected, argument), nil
}

// A plain name in a later parameter may refer to a type bound by an earlier one.
@(private = "file")
poly_match_bound_type :: proc(match: ^Poly_Match, pattern: syntax.Node_Index, argument: types.Type_Id) -> (matched: bool, found: bool, err: Resolve_Error) {
	file := match.checker.type_checker.files[match.definition_file]
	if file.ast.nodes[pattern].kind != .Ident { return false, false, nil }
	name := expression_text(file, pattern)
	for bound_name, index in match.bindings.names {
		if bound_name != name { continue }
		if match.bindings.constants[index] != 0 { return false, true, nil }
		return types.are_identical(match.checker.type_checker.store, match.bindings.types[index], argument), true, nil
	}
	return false, false, nil
}

// A bare generic record name used as a constraint (`$T/Table`) accepts an instance of that record.
@(private = "file")
poly_match_record_template :: proc(
	match: ^Poly_Match,
	pattern: syntax.Node_Index,
	argument: types.Type_Id,
) -> (
	matched: bool,
	found: bool,
	err: Resolve_Error,
) {
	checker := match.checker.type_checker
	file := checker.files[match.definition_file]
	kind := file.ast.nodes[pattern].kind
	if kind != .Ident && kind != .Selector_Expr { return false, false, nil }
	definition := type_name_entity(checker, file, match.scope, pattern)
	if definition == 0 { return false, false, nil }
	state := resolve_type_dependency(checker, definition, type_node_span(match.definition_file, file, pattern), .Name) or_return
	if state == .Invalid { return false, true, nil }
	if _, is_generic := checker.generic_records[definition]; !is_generic { return false, false, nil }
	for instance in checker.record_instances {
		if instance.definition == definition && instance.type == argument { return true, true, nil }
	}
	return false, true, nil
}

@(private = "file")
poly_match_element :: proc(match: ^Poly_Match, kind: types.Kind, elem: syntax.Node_Index, argument: types.Type_Id) -> (matched: bool, err: Resolve_Error) {
	store := match.checker.type_checker.store
	descriptor := types.get(store, underlying_type(store, argument))
	if descriptor.kind != kind { return false, nil }
	element := descriptor.elem
	matched = poly_match_pattern(match, elem, element) or_return
	file := match.checker.type_checker.files[match.definition_file]
	if matched || (kind != .Pointer && kind != .Multi_Pointer) || poly_pattern_has_poly(file, elem) { return matched, nil }
	bound_scope := poly_bound_scope(match) or_return
	expected := type_expression(match.checker.type_checker, match.definition_file, bound_scope, elem, true) or_return
	return expected != types.TYPE_POISON && conversion_offset_zero_element(store, match.checker.config, element, expected), nil
}

// A `#soa` array pattern matches only an `#soa` type of the same form; the element pattern is matched
// against the soa element type. A non-soa argument never matches, and any other tag never matches.
@(private = "file")
poly_match_soa :: proc(
	match: ^Poly_Match,
	file: ^File,
	tag: syntax.Node_Index,
	kind: types.Soa_Kind,
	length: syntax.Node_Index,
	elem: syntax.Node_Index,
	argument: types.Type_Id,
) -> (
	matched: bool,
	err: Resolve_Error,
) {
	if expression_text(file, tag) != "#soa" { return false, nil }
	store := match.checker.type_checker.store
	_, descriptor, ok := soa_descriptor(store, argument)
	if !ok || descriptor.soa != kind { return false, nil }
	if kind == .Fixed {
		expected, valid, count_error := poly_match_count(match, length)
		if count_error != nil { return false, count_error }
		if !valid || expected != descriptor.count { return false, nil }
	}
	return poly_match_pattern(match, elem, descriptor.soa_elem)
}

// A `^#soa` pointer pattern matches only an `#soa` pointer; other pointers never match.
@(private = "file")
poly_match_soa_pointer :: proc(
	match: ^Poly_Match,
	file: ^File,
	tag: syntax.Node_Index,
	elem: syntax.Node_Index,
	argument: types.Type_Id,
) -> (
	matched: bool,
	err: Resolve_Error,
) {
	if expression_text(file, tag) != "#soa" { return false, nil }
	store := match.checker.type_checker.store
	descriptor := types.get(store, underlying_type(store, argument))
	if descriptor.kind != .Soa_Pointer { return false, nil }
	return poly_match_pattern(match, elem, descriptor.elem)
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
	count, element := descriptor.count, descriptor.elem
	file := match.checker.type_checker.files[match.definition_file]
	if kind == .Array && descriptor.kind == .Enumerated_Array && file.ast.nodes[length].kind == .Poly_Type {
		matched = poly_match_pattern(match, length, descriptor.index) or_return
		if !matched { return false, nil }
		return poly_match_pattern(match, elem, element)
	}
	if descriptor.kind != kind { return false, nil }
	if file.ast.nodes[length].kind == .Poly_Type {
		name := expression_text(file, syntax.node_payload(file.ast, length, syntax.Poly_Type).type)
		constant, ok, constant_error := poly_integer_constant(match, count)
		if constant_error != nil || !ok { return false, constant_error }
		count_type := types.TYPE_UNTYPED_INTEGER if kind == .Fixed_Capacity_Array else match.checker.default_integer
		bound := poly_bind(match.checker.type_checker.store, match.bindings, name, count_type, constant) or_return
		if !bound { return false, nil }
	} else {
		expected, valid, count_error := poly_match_count(match, length)
		if count_error != nil { return false, count_error }
		if !valid || expected != count { return false, nil }
	}
	return poly_match_pattern(match, elem, element)
}

// A dimension may name a constant bound by an earlier parameter, so it is evaluated with those bindings in scope.
@(private = "package")
poly_bound_scope :: proc(match: ^Poly_Match) -> (scope: Scope_Id, err: Resolve_Error) {
	checker := match.checker.type_checker
	scopes := checker.resolver.scopes
	bound_scope, scope_error := scope_create(scopes, match.scope, .Block)
	if scope_error != nil { return 0, binding_resolve_error(scope_error) }
	for name, index in match.bindings.names {
		bound := Entity {
			name  = name,
			kind  = .Type_Name,
			scope = bound_scope,
			state = .Resolved,
			type  = match.bindings.types[index],
		}
		if match.bindings.constants[index] != 0 { bound.kind, bound.constant = .Constant, match.bindings.constants[index] }
		bound_entity, create_error := entity_create(scopes, bound)
		if create_error != nil { return 0, binding_resolve_error(create_error) }
		if _, insert_error := scope_insert(scopes, bound_scope, bound_entity); insert_error != nil {
			return 0, binding_resolve_error(insert_error)
		}
	}
	return bound_scope, nil
}

poly_match_count :: proc(match: ^Poly_Match, length: syntax.Node_Index) -> (count: i64, valid: bool, err: Resolve_Error) {
	scope := match.scope
	has_constant_binding := false
	for _, index in match.bindings.names {
		if match.bindings.constants[index] != 0 { has_constant_binding = true; break }
	}
	if has_constant_binding {
		scopes := match.checker.type_checker.resolver.scopes
		bound_scope, scope_error := scope_create(scopes, match.scope, .Block)
		if scope_error != nil { return 0, false, binding_resolve_error(scope_error) }
		for name, index in match.bindings.names {
			constant := match.bindings.constants[index]
			if constant == 0 { continue }
			entity, create_error := entity_create(
				scopes,
				Entity{name = name, kind = .Constant, scope = bound_scope, state = .Resolved, type = match.bindings.types[index], constant = constant},
			)
			if create_error != nil { return 0, false, binding_resolve_error(create_error) }
			if _, insert_error := scope_insert(scopes, bound_scope, entity); insert_error != nil {
				return 0, false, binding_resolve_error(insert_error)
			}
		}
		scope = bound_scope
	}
	// Rows are keyed by node, so bindings from this call would leak into the next one without speculation.
	mark := expression_speculation_begin(match.checker)
	defer expression_speculation_end(match.checker, mark)
	return array_count(match.checker.type_checker, match.definition_file, scope, length)
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

@(private = "file")
poly_match_matrix :: proc(match: ^Poly_Match, shape: syntax.Matrix_Type, argument: types.Type_Id) -> (matched: bool, err: Resolve_Error) {
	store := match.checker.type_checker.store
	descriptor := types.get(store, underlying_type(store, argument))
	if descriptor.kind != .Matrix { return false, nil }
	file := match.checker.type_checker.files[match.definition_file]
	dimensions := [2]struct {
		node:  syntax.Node_Index,
		count: i64,
	}{{shape.row_count, descriptor.count}, {shape.column_count, descriptor.upper_bound}}
	for dimension in dimensions {
		if file.ast.nodes[dimension.node].kind == .Poly_Type {
			name := expression_text(file, syntax.node_payload(file.ast, dimension.node, syntax.Poly_Type).type)
			constant, ok, constant_error := poly_integer_constant(match, dimension.count)
			if constant_error != nil || !ok { return false, constant_error }
			bound := poly_bind(store, match.bindings, name, match.checker.default_integer, constant) or_return
			if !bound { return false, nil }
			continue
		}
		expected, valid, count_error := poly_match_count(match, dimension.node)
		if count_error != nil { return false, count_error }
		if !valid || expected != dimension.count { return false, nil }
	}
	return poly_match_pattern(match, shape.elem, descriptor.elem)
}
