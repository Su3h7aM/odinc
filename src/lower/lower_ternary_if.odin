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
	if scalar == .None { return lower_aggregate_ternary(state, node, ternary, condition) }
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

// An aggregate result is stored into a stack slot by the taken branch; the slot's address is the value.
@(private)
lower_aggregate_ternary :: proc(state: ^Procedure_State, node: syntax.Node_Index, ternary: syntax.Ternary_Expr, condition: ir.Node_Id) -> ir.Node_Id {
	function := state.job.function
	builder := state.builder
	type := lower_info(state, node).type
	layout := state.job.layouts[type]
	slot := ir.stack_slot(function, state.entry_control, u32(max(layout.size, 1)), u32(layout.align))
	count := len(builder.values)
	end := ir.jump_target_make(builder)
	branch := ir.branch_if(builder, condition)
	ir.enter_arm(builder, branch, 0)
	value := lower_value(state, ternary.x)
	if state.failed { return 0 }
	lower_store(state, slot, value, type)
	ir.jump_to(builder, end)
	ir.enter_arm(builder, branch, 1)
	value = lower_value(state, ternary.y)
	if state.failed { return 0 }
	lower_store(state, slot, value, type)
	ir.jump_to(builder, end)
	ir.seal_target(builder, end)
	ir.variables_truncate(builder, count)
	return slot
}
