package lower

import "oc:check"
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
	info := lower_info(state, node)
	conversions := check.Ternary_Conversion_Plan{}
	if info.plan != 0 { conversions = check.plan(state.job.program, info.plan)^.(check.Ternary_Conversion_Plan) }
	scalar := scalar_type(state, info.type)
	if scalar == .None { return lower_aggregate_ternary(state, node, ternary, condition, conversions) }
	count := len(builder.values)
	result := ir.variable_declare(builder, ir.undef(function, scalar))
	end := ir.jump_target_make(builder)
	branch := ir.branch_if(builder, condition)
	ir.enter_arm(builder, branch, 0)
	value := lower_ternary_arm(state, ternary.x, conversions.x)
	if state.failed { return 0 }
	ir.variable_set(builder, result, value)
	ir.jump_to(builder, end)
	ir.enter_arm(builder, branch, 1)
	value = lower_ternary_arm(state, ternary.y, conversions.y)
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
lower_aggregate_ternary :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	ternary: syntax.Ternary_Expr,
	condition: ir.Node_Id,
	conversions: check.Ternary_Conversion_Plan,
) -> ir.Node_Id {
	function := state.job.function
	builder := state.builder
	type := lower_info(state, node).type
	layout := state.job.layouts[type]
	slot := ir.stack_slot(function, state.entry_control, u32(max(layout.size, 1)), u32(layout.align))
	count := len(builder.values)
	end := ir.jump_target_make(builder)
	branch := ir.branch_if(builder, condition)
	ir.enter_arm(builder, branch, 0)
	value := lower_ternary_arm(state, ternary.x, conversions.x)
	if state.failed { return 0 }
	lower_store(state, slot, value, type)
	ir.jump_to(builder, end)
	ir.enter_arm(builder, branch, 1)
	value = lower_ternary_arm(state, ternary.y, conversions.y)
	if state.failed { return 0 }
	lower_store(state, slot, value, type)
	ir.jump_to(builder, end)
	ir.seal_target(builder, end)
	ir.variables_truncate(builder, count)
	return slot
}

@(private)
lower_ternary_arm :: proc(state: ^Procedure_State, node: syntax.Node_Index, conversion: check.Plan_Id) -> ir.Node_Id {
	if conversion != 0 { return lower_declared_conversion(state, node, conversion) }
	return lower_value(state, node)
}
