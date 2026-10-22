package lower

import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

@(private)
lower_assignment_results :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	assignment: check.Assignment_Plan,
	projection: check.Projection,
	first: int,
	values: []ir.Node_Id,
) -> int {
	previous_view := state.view
	state.view = projection.expression.view
	defer state.view = previous_view
	info := lower_info(state, projection.expression.node)
	plan := check.plan(state.job.program, info.plan)
	if plan == nil || projection.index != 0 { lower_fail(state, node, .Local); return first }
	results: []types.Type_Id
	pair: [2]types.Type_Id
	#partial switch variant in plan^ {
	case check.Call_Plan:
		results = variant.results
		if first + len(results) > len(values) { lower_fail(state, node, .Local); return first }
		lower_call_results(state, projection.expression.node, info, variant, values[first:first + len(results)])
	case check.Builtin_Plan:
		results = variant.results
		if first + len(results) > len(values) { lower_fail(state, node, .Local); return first }
		lower_intrinsic_tuple(state, projection.expression.node, variant, state.job.program.builtin_kinds[variant.builtin], values[first:first + len(results)])
	case check.Propagation_Plan:
		results = variant.results
		if first + len(results) > len(values) { lower_fail(state, node, .Local); return first }
		if state.ast.nodes[projection.expression.node].kind == .Or_Return_Expr {
			if !lower_or_return_values(state, projection.expression.node, variant, values[first:first + len(results)]) { return first }
		} else if state.ast.nodes[projection.expression.node].kind == .Or_Branch_Expr {
			if !lower_or_branch_values(state, projection.expression.node, variant, values[first:first + len(results)]) { return first }
		} else {
			lower_fail(state, node, .Local)
			return first
		}
	case check.Type_Assertion_Plan:
		if first + 2 > len(values) || !variant.comma_ok { lower_fail(state, node, .Local); return first }
		values[first], values[first + 1] = lower_type_assertion(state, projection.expression.node, variant)
		pair[0] = variant.target_type
		results = pair[:]
	case check.Map_Index_Plan:
		if first + 2 > len(values) || !variant.comma_ok { lower_fail(state, node, .Local); return first }
		values[first], values[first + 1] = lower_map_index(state, projection.expression.node, variant)
		pair[0] = info.type
		results = pair[:]
	case check.Address_Plan:
		if first + 2 > len(values) || !variant.comma_ok { lower_fail(state, node, .Local); return first }
		values[first], values[first + 1] = lower_optional_address(state, projection.expression.node)
		pair[0] = info.type
		results = pair[:]
	case:
		lower_fail(state, node, .Local)
		return first
	}
	if state.failed || state.job.function.error != nil { return first }
	for result, index in results {
		position := first + index
		if len(assignment.conversions) == 0 || assignment.conversions[position] == 0 { continue }
		conversion := check.plan(state.job.program, assignment.conversions[position])
		if conversion == nil { lower_fail(state, node, .Conversion); return first }
		converted, found := conversion^.(check.Conversion_Plan)
		if !found { lower_fail(state, node, .Conversion); return first }
		source_type := result
		if source_type == 0 { source_type = converted.source_type }
		if source_type == 0 { lower_fail(state, node, .Conversion); return first }
		values[position] = lower_conversion_value(state, converted, node, source_type, values[position])
	}
	return first + len(results)
}
