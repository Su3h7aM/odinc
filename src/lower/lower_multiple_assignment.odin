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
	#partial switch variant in plan^ {
	case check.Call_Plan:
		results = variant.results
		if first + len(results) > len(values) { lower_fail(state, node, .Local); return first }
		lower_call_results(state, projection.expression.node, info, variant, values[first:first + len(results)])
	case check.Builtin_Plan:
		results = variant.results
		if first + len(results) > len(values) { lower_fail(state, node, .Local); return first }
		lower_intrinsic_tuple(state, projection.expression.node, variant, state.job.program.builtin_kinds[variant.builtin], values[first:first + len(results)])
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
		values[position] = lower_conversion_value(state, converted, node, result, values[position])
	}
	return first + len(results)
}
