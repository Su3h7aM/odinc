package check

import "core:math/big"
import "core:mem"
import "oc:syntax"
import "oc:types"

// The backing array holds max(index) + 1 elements, where an element's index is its position or its key.
@(private = "package")
expression_slice_literal :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	slice_type: types.Type_Id,
	element_type: types.Type_Id,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[file_id]
	literal := syntax.node_payload(file.ast, node, syntax.Comp_Lit)
	elements := syntax.node_list(file.ast, literal.elems)
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	indices := make([]u32, len(elements), allocator) or_return
	count := 0
	for element, position in elements {
		index := position
		if file.ast.nodes[element].kind == .Field_Value {
			pair := syntax.node_payload(file.ast, element, syntax.Field_Value)
			key := check_expression(checker, view, scope, pair.field, checker.default_integer) or_return
			if key.state == .Invalid { return expression_poison(scope), nil }
			if key.constant == 0 { return expression_failure(checker, view, scope, pair.field, .Invalid_Operand) }
			integer := constant_pool_get(checker.constants, key.constant).value.(big.Int)
			key_value, key_error := big.int_get_i64(&integer)
			if key_error != .None || key_value < 0 { return expression_failure(checker, view, scope, pair.field, .Invalid_Operand) }
			index = int(key_value)
		}
		indices[position] = u32(index)
		count = max(count, index + 1)
	}
	seen := make([]bool, count, allocator) or_return
	values := make([]Operand, len(elements), allocator) or_return
	conversions := make([]Plan_Id, len(elements), allocator) or_return
	for element, position in elements {
		value_node := element
		if file.ast.nodes[element].kind == .Field_Value {
			value_node = syntax.node_payload(file.ast, element, syntax.Field_Value).value
		}
		index := indices[position]
		if seen[index] { return expression_failure(checker, view, scope, element, .Invalid_Operand) }
		seen[index] = true
		value := check_expression(checker, view, scope, value_node, element_type) or_return
		if value.state == .Invalid { return expression_poison(scope), nil }
		values[position] = Operand(Expression_Ref{view, value_node})
		conversions[position] = expression_boxing_plan(checker, value.plan)
	}
	array_type := types.intern(checker.type_checker.store, types.Type{kind = .Array, elem = element_type, count = i64(count)})
	plan := Plan_Id(len(checker.plans))
	backing := Aggregate_Plan {
		type          = array_type,
		values        = values,
		field_indices = indices,
		conversions   = conversions,
	}
	append(&checker.plans, Plan(Slice_Literal_Plan{type = slice_type, backing = backing})) or_return
	return Expression_Info{type = slice_type, mode = .Value, plan = plan, scope = scope, state = .Checked}, nil
}
