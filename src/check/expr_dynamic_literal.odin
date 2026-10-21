package check

import "core:mem"
import "oc:syntax"
import "oc:types"

// Dynamic containers allocate through the context allocator, so non-empty dynamic
// array and map literals are opt-in per file (`#+feature dynamic-literals`), like
// upstream's check_for_dynamic_literals. Empty literals need no allocation.
@(private = "package")
expression_dynamic_literal :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	literal_type: types.Type_Id,
	descriptor: types.Type,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[file_id]
	literal := syntax.node_payload(file.ast, node, syntax.Comp_Lit)
	elements := syntax.node_list(file.ast, literal.elems)
	if len(elements) != 0 && !dynamic_literals_enabled(file) {
		return expression_failure(checker, view, scope, node, .Invalid_Operand, "Dynamic_Literals_Disallowed")
	}
	if descriptor.kind == .Dynamic_Array {
		return expression_dynamic_array_literal(checker, view, file_id, scope, node, literal_type, elements, descriptor.elem)
	}
	return expression_map_literal(checker, view, file_id, scope, node, literal_type, elements, descriptor.index, descriptor.elem)
}

// The backing store matches a slice literal's; only the container header differs.
@(private = "file")
expression_dynamic_array_literal :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	literal_type: types.Type_Id,
	elements: []syntax.Node_Index,
	element_type: types.Type_Id,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	values, indices, conversions, count, failed, elements_error := expression_literal_elements(checker, view, scope, file_id, elements, element_type)
	if elements_error != nil { return {}, elements_error }
	if failed { return expression_poison(scope), nil }
	backing_type := types.intern(checker.type_checker.store, types.Type{kind = .Array, elem = element_type, count = i64(count)})
	plan := Plan_Id(len(checker.plans))
	backing := Aggregate_Plan {
		type          = backing_type,
		values        = values,
		field_indices = indices,
		conversions   = conversions,
	}
	append(&checker.plans, Plan(Dynamic_Array_Literal_Plan{type = literal_type, backing = backing})) or_return
	return Expression_Info{type = literal_type, mode = .Value, plan = plan, scope = scope, state = .Checked}, nil
}

// Map keys are arbitrary expressions, so every element names its key (`key = value`).
@(private = "file")
expression_map_literal :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	literal_type: types.Type_Id,
	elements: []syntax.Node_Index,
	key_type: types.Type_Id,
	value_type: types.Type_Id,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[file_id]
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	keys := make([dynamic]Operand, allocator) or_return
	values := make([dynamic]Operand, allocator) or_return
	key_conversions := make([dynamic]Plan_Id, allocator) or_return
	value_conversions := make([dynamic]Plan_Id, allocator) or_return
	for element in elements {
		if file.ast.nodes[element].kind != .Field_Value {
			_, failure_error := expression_failure(checker, view, scope, element, .Invalid_Operand, "Map_Literal_Field")
			if failure_error != nil { return {}, failure_error }
			return expression_poison(scope), nil
		}
		pair := syntax.node_payload(file.ast, element, syntax.Field_Value)
		key := check_expression(checker, view, scope, pair.field, key_type) or_return
		if key.state == .Invalid { return expression_poison(scope), nil }
		value := check_expression(checker, view, scope, pair.value, value_type) or_return
		if value.state == .Invalid { return expression_poison(scope), nil }
		append(&keys, Operand(Expression_Ref{view, pair.field})) or_return
		append(&values, Operand(Expression_Ref{view, pair.value})) or_return
		append(&key_conversions, expression_boxing_plan(checker, key.plan)) or_return
		append(&value_conversions, expression_boxing_plan(checker, value.plan)) or_return
	}
	plan := Plan_Id(len(checker.plans))
	append(
		&checker.plans,
		Plan(
			Map_Literal_Plan {
				type = literal_type,
				keys = keys[:],
				values = values[:],
				key_conversions = key_conversions[:],
				value_conversions = value_conversions[:],
			},
		),
	) or_return
	return Expression_Info{type = literal_type, mode = .Value, plan = plan, scope = scope, state = .Checked}, nil
}
