package lower

import "oc:check"
import "oc:ir"
import "oc:syntax"

@(private)
lower_or_else :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Propagation_Plan) -> ir.Node_Id {
	operand, is_expression := plan.operand.(check.Expression_Ref)
	if !is_expression || operand.view != state.view { return lower_fail(state, node, .Expression) }
	operand_info := lower_info(state, operand.node)
	if operand_info.plan == 0 { return lower_fail(state, node, .Expression) }
	call, is_call := check.plan(state.job.program, operand_info.plan)^.(check.Call_Plan)
	if !is_call || len(call.results) != 2 { return lower_fail(state, node, .Expression) }
	call_node := operand.node
	for state.ast.nodes[call_node].kind == .Paren_Expr {
		call_node = state.ast.nodes[call_node].payload.(syntax.Paren_Expr).expr
	}
	values: [2]ir.Node_Id
	lower_call_results(state, call_node, operand_info, call, values[:])
	if state.failed || state.job.function.error != nil { return 0 }
	condition: ir.Node_Id
	switch plan.test {
	case .Boolean_True:
		if state.job.function.nodes.type[values[1]] != .Bool { return lower_fail(state, node, .Expression) }
		condition = values[1]
	case .Nil:
		if state.job.function.nodes.type[values[1]] != .Ptr { return lower_fail(state, node, .Expression) }
		condition = ir.compare(state.job.function, .Eq, values[1], ir.const_int(state.job.function, .Ptr, 0))
	}
	result_type := lower_info(state, node).type
	scalar := scalar_type(state, result_type)
	if scalar == .None { return lower_fail(state, node, .Expression) }
	builder := state.builder
	function := state.job.function
	count := len(builder.values)
	result := ir.variable_declare(builder, ir.undef(function, scalar))
	end := ir.jump_target_make(builder)
	branch := ir.branch_if(builder, condition)
	ir.enter_arm(builder, branch, 0)
	ir.variable_set(builder, result, values[0])
	ir.jump_to(builder, end)
	ir.enter_arm(builder, branch, 1)
	expression := state.ast.nodes[node].payload.(syntax.Or_Else_Expr)
	fallback := lower_value(state, expression.y)
	if state.failed || function.error != nil { return 0 }
	ir.variable_set(builder, result, fallback)
	ir.jump_to(builder, end)
	ir.seal_target(builder, end)
	value := ir.variable_get(builder, result)
	ir.variables_truncate(builder, count)
	return value
}
