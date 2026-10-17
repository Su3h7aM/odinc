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

@(private)
lower_or_branch :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Propagation_Plan) -> ir.Node_Id {
	operand, is_expression := plan.operand.(check.Expression_Ref)
	if !is_expression || operand.view != state.view { return lower_fail(state, node, .Expression) }
	operand_info := lower_info(state, operand.node)
	if operand_info.plan == 0 { return lower_fail(state, node, .Expression) }
	call, is_call := check.plan(state.job.program, operand_info.plan)^.(check.Call_Plan)
	if !is_call || (len(call.results) != 1 && len(call.results) != 2) { return lower_fail(state, node, .Expression) }
	call_node := operand.node
	for state.ast.nodes[call_node].kind == .Paren_Expr {
		call_node = state.ast.nodes[call_node].payload.(syntax.Paren_Expr).expr
	}
	values: [2]ir.Node_Id
	lower_call_results(state, call_node, operand_info, call, values[:len(call.results)])
	if state.failed || state.job.function.error != nil { return 0 }
	status_index := len(call.results) - 1
	condition: ir.Node_Id
	switch plan.test {
	case .Boolean_True:
		if state.job.function.nodes.type[values[status_index]] != .Bool { return lower_fail(state, node, .Expression) }
		condition = values[status_index]
	case .Nil:
		if state.job.function.nodes.type[values[status_index]] != .Ptr { return lower_fail(state, node, .Expression) }
		condition = ir.compare(state.job.function, .Eq, values[status_index], ir.const_int(state.job.function, .Ptr, 0))
	}
	if plan.failure == 0 { return lower_fail(state, node, .Control) }
	exit_plan := check.plan(state.job.program, plan.failure)
	if exit_plan == nil { return lower_fail(state, node, .Control) }
	exit, valid_exit := exit_plan^.(check.Exit_Plan)
	branch_expr := state.ast.nodes[node].payload.(syntax.Or_Branch_Expr)
	expected_exit := check.Exit_Kind.Break
	if branch_expr.token.kind == .Or_Continue {
		expected_exit = .Continue
	} else if branch_expr.token.kind != .Or_Break {
		return lower_fail(state, node, .Control)
	}
	if !valid_exit || exit.kind != expected_exit || exit.target.node == 0 { return lower_fail(state, node, .Control) }
	builder := state.builder
	end := ir.jump_target_make(builder)
	branch := ir.branch_if(builder, condition)
	ir.enter_arm(builder, branch, 0)
	ir.jump_to(builder, end)
	ir.enter_arm(builder, branch, 1)
	lower_branch_exit(state, node, exit)
	if state.failed || state.job.function.error != nil { return 0 }
	ir.seal_target(builder, end)
	if len(plan.values) == 0 { return 0 }
	if len(plan.values) != 1 || status_index != 1 { return lower_fail(state, node, .Result) }
	return values[0]
}

@(private)
lower_or_return :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Propagation_Plan) -> ir.Node_Id {
	operand, is_expression := plan.operand.(check.Expression_Ref)
	if !is_expression || operand.view != state.view { return lower_fail(state, node, .Expression) }
	operand_info := lower_info(state, operand.node)
	if operand_info.plan == 0 { return lower_fail(state, node, .Expression) }
	call, is_call := check.plan(state.job.program, operand_info.plan)^.(check.Call_Plan)
	if !is_call || (len(call.results) != 1 && len(call.results) != 2) { return lower_fail(state, node, .Expression) }
	call_node := operand.node
	for state.ast.nodes[call_node].kind == .Paren_Expr {
		call_node = state.ast.nodes[call_node].payload.(syntax.Paren_Expr).expr
	}
	values: [2]ir.Node_Id
	lower_call_results(state, call_node, operand_info, call, values[:len(call.results)])
	if state.failed || state.job.function.error != nil { return 0 }
	status_index := len(call.results) - 1
	condition: ir.Node_Id
	switch plan.test {
	case .Boolean_True:
		if state.job.function.nodes.type[values[status_index]] != .Bool { return lower_fail(state, node, .Expression) }
		condition = values[status_index]
	case .Nil:
		if state.job.function.nodes.type[values[status_index]] != .Ptr { return lower_fail(state, node, .Expression) }
		condition = ir.compare(state.job.function, .Eq, values[status_index], ir.const_int(state.job.function, .Ptr, 0))
	}
	if plan.failure == 0 { return lower_fail(state, node, .Result) }
	exit_plan := check.plan(state.job.program, plan.failure)
	if exit_plan == nil { return lower_fail(state, node, .Result) }
	exit, valid_exit := exit_plan^.(check.Exit_Plan)
	if !valid_exit || exit.kind != .Return || len(exit.values) != 1 { return lower_fail(state, node, .Result) }
	builder := state.builder
	end := ir.jump_target_make(builder)
	branch := ir.branch_if(builder, condition)
	ir.enter_arm(builder, branch, 0)
	ir.jump_to(builder, end)
	ir.enter_arm(builder, branch, 1)
	results := state.job.procedure.results
	if len(results) <= 1 {
		if len(results) == 1 && results[0] != 0 {
			store_result_entity(state, results[0], values[status_index])
			lower_return(state, node, nil, nil)
		} else {
			lower_scalar_return(state, node, values[status_index])
		}
	} else {
		if results[len(results) - 1] == 0 { return lower_fail(state, node, .Result) }
		store_result_entity(state, results[len(results) - 1], values[status_index])
		lower_return(state, node, nil, nil)
	}
	if state.failed || state.job.function.error != nil { return 0 }
	ir.seal_target(builder, end)
	if len(plan.values) == 0 { return 0 }
	if len(plan.values) != 1 || status_index != 1 { return lower_fail(state, node, .Result) }
	return values[0]
}
