package lower

import "oc:check"
import "oc:ir"
import "oc:syntax"

@(private)
lower_string_switch_plan :: proc(state: ^Procedure_State, node: syntax.Node_Index) -> (switch_plan: check.Switch_Plan, ok: bool) {
	info, found := check.expression_info(state.job.program, state.view, node)
	if !found || info.plan == 0 { return {}, false }
	plan := check.plan(state.job.program, info.plan)
	if plan == nil { return {}, false }
	switch_plan, ok = plan^.(check.Switch_Plan)
	return switch_plan, ok
}

// The case is the runtime comparison of the bound tag with the case value, as lb_emit_comp does for strings.
@(private)
lower_string_case :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan_id: check.Plan_Id) -> ir.Node_Id {
	plan := check.plan(state.job.program, plan_id)
	if plan == nil { return lower_fail(state, node, .Switch) }
	call, ok := plan^.(check.Call_Plan)
	if !ok || len(call.results) != 1 { return lower_fail(state, node, .Switch) }
	values: [1]ir.Node_Id
	lower_call_results(state, node, check.Expression_Info{type = call.results[0], mode = .Value}, call, values[:])
	return values[0]
}
