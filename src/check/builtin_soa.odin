package check

import "core:fmt"
import "core:mem"
import "oc:syntax"
import "oc:types"

// soa_zip builds an #soa slice from one slice per field, and soa_unzip recovers those slices.
// Upstream recognizes both as compiler builtins (check_builtin.cpp); the rules below mirror it:
// zip takes at least one slice, named or positional but not mixed, and zips into the hint struct
// when the hint is a matching #soa slice; unzip takes exactly one #soa slice and returns its fields.
@(private = "package")
expression_soa_zip :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	builtin: Builtin_Id,
	arguments: []syntax.Node_Index,
	ellipsis: bool,
	hint: types.Type_Id,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[checker.views[view].file]
	store := checker.type_checker.store
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	if ellipsis || len(arguments) < 1 {
		reason := fmt.aprintf("too few arguments for 'soa_zip', expected 1, got %d", len(arguments), allocator = allocator)
		return expression_failure(checker, view, scope, node, .Invalid_Operand, reason)
	}
	first_named := file.ast.nodes[arguments[0]].kind == .Field_Value
	for argument in arguments[1:] {
		if (file.ast.nodes[argument].kind == .Field_Value) != first_named {
			return expression_failure(
				checker,
				view,
				scope,
				argument,
				.Invalid_Operand,
				"mixture of 'field = value' and value elements in 'soa_zip' is not allowed",
			)
		}
	}
	names := make([]string, len(arguments), allocator) or_return
	elements := make([]types.Type_Id, len(arguments), allocator) or_return
	operands := make([]Operand, len(arguments), allocator) or_return
	for argument, index in arguments {
		value_node := argument
		if first_named {
			field := syntax.node_payload(file.ast, argument, syntax.Field_Value)
			if file.ast.nodes[field.field].kind != .Ident {
				return expression_failure(checker, view, scope, field.field, .Invalid_Operand, "expected an identifier for field argument")
			}
			names[index] = expression_text(file, field.field)
			value_node = field.value
		} else {
			names[index] = fmt.aprintf("_%d", index, allocator = allocator)
		}
		if names[index] == "_" {
			return expression_failure(checker, view, scope, argument, .Invalid_Operand, "field argument name '_' is not allowed")
		}
		for prior in names[:index] {
			if prior == names[index] {
				reason := fmt.aprintf("field argument name '%s' already exists", names[index], allocator = allocator)
				return expression_failure(checker, view, scope, argument, .Invalid_Operand, reason)
			}
		}
		value := check_expression(checker, view, scope, value_node) or_return
		if value.state == .Invalid { return expression_poison(scope), nil }
		descriptor := types.get(store, types.resolve_named(store, value.type))
		if value.mode == .Type || descriptor.kind != .Slice {
			return expression_failure(checker, view, scope, value_node, .Invalid_Operand, "indices to 'soa_zip' must be slices")
		}
		elements[index] = descriptor.elem
		operands[index] = Operand(Expression_Ref{view, value_node})
	}
	elem := soa_zip_hint_element(checker, hint, first_named, names, elements)
	if elem == 0 {
		type_allocator := checker.type_checker.arena_allocator
		fields := make([]types.Type_Field, len(arguments), type_allocator) or_return
		for _, index in arguments {
			fields[index] = types.Type_Field {
				name = names[index],
				type = elements[index],
			}
		}
		elem = types.intern(store, types.Type{kind = .Struct, fields = fields})
	}
	soa, valid := soa_struct(checker.type_checker, elem, 0, .Slice)
	if !valid { return expression_unsupported(checker, view, scope, node, "Soa_Zip_Element") }
	plan := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(Builtin_Plan{builtin = builtin, arguments = operands})) or_return
	return Expression_Info{type = soa, mode = .Value, plan = plan, scope = scope, state = .Checked}, nil
}

// The hint struct the zip result converts to, or 0 for a synthesized field struct. A hint that is not a
// matching #soa slice falls back to the synthesized struct, as upstream does, and the assignment converts.
@(private = "file")
soa_zip_hint_element :: proc(checker: ^Expression_Checker, hint: types.Type_Id, named: bool, names: []string, elements: []types.Type_Id) -> types.Type_Id {
	if hint == 0 { return 0 }
	store := checker.type_checker.store
	descriptor := types.get(store, types.resolve_named(store, hint))
	if descriptor.kind != .Struct || descriptor.soa != .Slice { return 0 }
	elem_descriptor := types.get(store, types.resolve_named(store, descriptor.soa_elem))
	if elem_descriptor.kind != .Struct || len(elem_descriptor.fields) != len(elements) { return 0 }
	if named {
		for name, index in names {
			field := struct_field_index(elem_descriptor.fields, name)
			if field < 0 || !types.are_identical(store, elem_descriptor.fields[field].type, elements[index]) { return 0 }
		}
	} else {
		for element, index in elements {
			if !types.are_identical(store, elem_descriptor.fields[index].type, element) { return 0 }
		}
	}
	return descriptor.soa_elem
}

@(private = "package")
expression_soa_unzip :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	builtin: Builtin_Id,
	arguments: []syntax.Node_Index,
	ellipsis: bool,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	if ellipsis || len(arguments) != 1 {
		qualifier := "few" if len(arguments) < 1 else "many"
		reason := fmt.aprintf("too %s arguments for 'soa_unzip', expected 1, got %d", qualifier, len(arguments), allocator = allocator)
		return expression_failure(checker, view, scope, node, .Invalid_Operand, reason)
	}
	value := check_expression(checker, view, scope, arguments[0]) or_return
	if value.state == .Invalid { return expression_poison(scope), nil }
	store := checker.type_checker.store
	_, descriptor, ok := soa_descriptor(store, value.type)
	if !ok || descriptor.soa != .Slice {
		return expression_failure(checker, view, scope, arguments[0], .Invalid_Operand, "'soa_unzip' expects an #soa slice")
	}
	if len(descriptor.fields) < 1 {
		return expression_failure(checker, view, scope, arguments[0], .Invalid_Operand, "'soa_unzip' expects an #soa slice")
	}
	// The last field is the hidden length footer, not a field pointer.
	fields := descriptor.fields[:len(descriptor.fields) - 1]
	results := make([]types.Type_Id, len(fields), allocator) or_return
	for field, index in fields {
		field_type := types.get(store, types.resolve_named(store, field.type))
		if field_type.kind != .Multi_Pointer {
			return expression_failure(checker, view, scope, arguments[0], .Invalid_Operand, "'soa_unzip' expects an #soa slice")
		}
		results[index] = types.intern(store, types.Type{kind = .Slice, elem = field_type.elem})
	}
	operands := make([]Operand, 1, allocator) or_return
	operands[0] = Operand(Expression_Ref{view, arguments[0]})
	plan := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(Builtin_Plan{builtin = builtin, arguments = operands, results = results})) or_return
	return Expression_Info{mode = .No_Value, plan = plan, scope = scope, state = .Checked}, nil
}
