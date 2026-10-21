package check

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
	values, indices, conversions, count, failed, elements_error := expression_literal_elements(checker, view, scope, file_id, elements, element_type)
	if elements_error != nil { return {}, elements_error }
	if failed { return expression_poison(scope), nil }
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

// Positional elements take their own position; `i = v` and range keys take the keyed span.
// Shared by slice and dynamic array literals, whose backing stores match.
@(private = "package")
expression_literal_elements :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	file_id: File_Id,
	elements: []syntax.Node_Index,
	element_type: types.Type_Id,
) -> (
	values: []Operand,
	indices: []u32,
	conversions: []Plan_Id,
	count: int,
	failed: bool,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[file_id]
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	firsts := make([]int, len(elements), allocator) or_return
	lasts := make([]int, len(elements), allocator) or_return
	for element, position in elements {
		first, last := position, position
		if file.ast.nodes[element].kind == .Field_Value {
			pair := syntax.node_payload(file.ast, element, syntax.Field_Value)
			lower_index, upper_index, key_failed, key_error := expression_array_key(checker, view, scope, file_id, pair.field, checker.default_integer)
			if key_error != nil { return {}, {}, {}, 0, false, key_error }
			if key_failed { return {}, {}, {}, 0, true, nil }
			first, last = int(lower_index), int(upper_index)
		}
		if first < 0 {
			_, failure_error := expression_failure(checker, view, scope, element, .Invalid_Operand)
			if failure_error != nil { return {}, {}, {}, 0, false, failure_error }
			return {}, {}, {}, 0, true, nil
		}
		firsts[position], lasts[position] = first, last
		count = max(count, last + 1)
	}
	seen := make([]bool, count, allocator) or_return
	value_list := make([dynamic]Operand, allocator) or_return
	index_list := make([dynamic]u32, allocator) or_return
	conversion_list := make([dynamic]Plan_Id, allocator) or_return
	for element, position in elements {
		value_node := element
		if file.ast.nodes[element].kind == .Field_Value {
			value_node = syntax.node_payload(file.ast, element, syntax.Field_Value).value
		}
		value := check_expression(checker, view, scope, value_node, element_type) or_return
		if value.state == .Invalid { return {}, {}, {}, 0, true, nil }
		if value.mode == .Type {
			expression_type_ambiguous_failure(checker, view, scope, value_node) or_return
			return {}, {}, {}, 0, true, nil
		}
		conversion := expression_boxing_plan(checker, value.plan)
		for index in firsts[position] ..= lasts[position] {
			if seen[index] {
				_, failure_error := expression_failure(checker, view, scope, element, .Invalid_Operand)
				if failure_error != nil { return {}, {}, {}, 0, false, failure_error }
				return {}, {}, {}, 0, true, nil
			}
			seen[index] = true
			append(&value_list, Operand(Expression_Ref{view, value_node})) or_return
			append(&index_list, u32(index)) or_return
			append(&conversion_list, conversion) or_return
		}
	}
	return value_list[:], index_list[:], conversion_list[:], count, false, nil
}
