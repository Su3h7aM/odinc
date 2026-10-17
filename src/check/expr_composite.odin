package check

import "core:mem"
import "core:slice"
import "oc:syntax"
import "oc:types"

// Positional and named (`field = value`) elements become operands in declaration order of the plan's field indices.
@(private = "package")
expression_composite :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[file_id]
	literal := syntax.node_payload(file.ast, node, syntax.Comp_Lit)
	if literal.type == 0 { return expression_failure(checker, view, scope, node, .Unsupported) }
	type := type_expression(checker.type_checker, file_id, scope, literal.type, true) or_return
	if type == types.TYPE_POISON { return expression_poison(scope), nil }
	store := checker.type_checker.store
	owner := types.resolve_named(store, type)
	descriptor := types.get(store, owner)
	if descriptor.kind != .Struct { return expression_failure(checker, view, scope, node, .Unsupported) }
	fields := descriptor.fields
	elements := syntax.node_list(file.ast, literal.elems)
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	values := make([]Operand, len(elements), allocator) or_return
	indices := make([]u32, len(elements), allocator) or_return
	conversions := make([]Plan_Id, len(elements), allocator) or_return
	constants := make([]Const_Id, len(fields), allocator) or_return
	for element, position in elements {
		value_node := element
		index := position
		if file.ast.nodes[element].kind == .Field_Value {
			pair := syntax.node_payload(file.ast, element, syntax.Field_Value)
			value_node = pair.value
			index = struct_field_index(fields, expression_text(file, pair.field))
			if index < 0 { return expression_failure(checker, view, scope, pair.field, .Undeclared_Name) }
		} else if position >= len(fields) {
			return expression_failure(checker, view, scope, element, .Invalid_Operand)
		}
		value := check_expression(checker, view, scope, value_node, fields[index].type) or_return
		if value.state == .Invalid { return expression_poison(scope), nil }
		values[position] = Operand(Expression_Ref{view, value_node})
		indices[position] = u32(index)
		conversions[position] = expression_boxing_plan(checker, value.plan)
		if value.constant != 0 && expression_conversion_plan(checker, value.plan) == 0 { constants[index] = value.constant }
	}
	if len(elements) == len(fields) && !slice.contains(constants, 0) {
		constant, constant_error := constant_pool_intern_aggregate(checker.constants, type, constants)
		if constant_error != nil {
			expression_constant_failure(checker, file_id, node, constant_error) or_return
			return expression_poison(scope), nil
		}
		return Expression_Info{type = type, constant = constant, mode = .Constant, scope = scope, state = .Checked}, nil
	}
	plan := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(Aggregate_Plan{type = type, values = values, field_indices = indices, conversions = conversions})) or_return
	return Expression_Info{type = type, mode = .Value, plan = plan, scope = scope, state = .Checked}, nil
}
