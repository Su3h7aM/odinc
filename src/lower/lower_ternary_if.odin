package lower

import "oc:ir"
import "oc:syntax"

// Branches on the condition like the official lb_build_cond, storing the taken value in a variable.
@(private)
lower_ternary_if :: proc(state: ^Procedure_State, node: syntax.Node_Index) -> ir.Node_Id {
	ternary := state.ast.nodes[node].payload.(syntax.Ternary_Expr)
	function := state.job.function
	builder := state.builder
	condition := lower_value(state, ternary.cond)
	if state.failed { return 0 }
	scalar := scalar_type(state, lower_info(state, node).type)
	if scalar == .None { return lower_fail(state, node, .Expression) }
	count := len(builder.values)
	result := ir.variable_declare(builder, ir.undef(function, scalar))
	end := ir.jump_target_make(builder)
	branch := ir.branch_if(builder, condition)
	ir.enter_arm(builder, branch, 0)
	value := lower_value(state, ternary.x)
	if state.failed { return 0 }
	ir.variable_set(builder, result, value)
	ir.jump_to(builder, end)
	ir.enter_arm(builder, branch, 1)
	value = lower_value(state, ternary.y)
	if state.failed { return 0 }
	ir.variable_set(builder, result, value)
	ir.jump_to(builder, end)
	ir.seal_target(builder, end)
	value = ir.variable_get(builder, result)
	ir.variables_truncate(builder, count)
	return value
}
