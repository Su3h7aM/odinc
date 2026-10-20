package lower

import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

@(private)
lower_or_else :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Propagation_Plan) -> ir.Node_Id {
	operand, is_expression := plan.operand.(check.Expression_Ref)
	if !is_expression || operand.view != state.view { return lower_fail(state, node, .Expression) }
	operand_info := lower_info(state, operand.node)
	if operand_info.plan == 0 { return lower_fail(state, node, .Expression) }
	operand_plan := check.plan(state.job.program, operand_info.plan)
	if operand_plan == nil { return lower_fail(state, node, .Expression) }
	call_node := operand.node
	for state.ast.nodes[call_node].kind == .Paren_Expr {
		call_node = state.ast.nodes[call_node].payload.(syntax.Paren_Expr).expr
	}
	values: [2]ir.Node_Id
	#partial switch value in operand_plan^ {
	case check.Call_Plan:
		if len(value.results) != 2 { return lower_fail(state, node, .Expression) }
		lower_call_results(state, call_node, operand_info, value, values[:])
	case check.Type_Assertion_Plan:
		if !value.comma_ok { return lower_fail(state, node, .Expression) }
		values[0], values[1] = lower_type_assertion(state, call_node, value)
	case check.Map_Index_Plan:
		return lower_fail(state, node, .Expression)
	case:
		return lower_fail(state, node, .Expression)
	}
	if state.failed || state.job.function.error != nil { return 0 }
	condition: ir.Node_Id
	switch plan.test {
	case .Boolean_True:
		if state.job.function.nodes.type[values[1]] != .Bool { return lower_fail(state, node, .Expression) }
		condition = values[1]
	case .Nil:
		nil_condition, nil_ok := propagation_nil_condition(state.job.function, values[1])
		if !nil_ok { return lower_fail(state, node, .Expression) }
		condition = nil_condition
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
		nil_condition, nil_ok := propagation_nil_condition(state.job.function, values[status_index])
		if !nil_ok { return lower_fail(state, node, .Expression) }
		condition = nil_condition
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
	if operand_info.plan == 0 { return lower_or_return_stored(state, node, plan, operand, operand_info.type) }
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
	condition, condition_ok := or_return_condition(state.job.function, plan, values[status_index])
	if !condition_ok { return lower_fail(state, node, .Expression) }
	if !lower_or_return_exit(state, node, plan, condition, values[status_index], call.results[status_index]) { return 0 }
	if len(plan.values) == 0 { return 0 }
	if len(plan.values) != 1 || status_index != 1 { return lower_fail(state, node, .Result) }
	return values[0]
}

// A stored status has no call plan and yields no value: the expression is a statement.
@(private)
lower_or_return_stored :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	plan: check.Propagation_Plan,
	operand: check.Expression_Ref,
	status_type: types.Type_Id,
) -> ir.Node_Id {
	status := lower_operand(state, check.Operand(operand), status_type)
	if state.failed || state.job.function.error != nil { return 0 }
	condition, condition_ok := or_return_condition(state.job.function, plan, status)
	if !condition_ok { return lower_fail(state, node, .Expression) }
	if !lower_or_return_exit(state, node, plan, condition, status, status_type) { return 0 }
	return 0
}

@(private)
or_return_condition :: proc(function: ^ir.Function, plan: check.Propagation_Plan, status: ir.Node_Id) -> (condition: ir.Node_Id, ok: bool) {
	switch plan.test {
	case .Boolean_True:
		if function.nodes.type[status] != .Bool { return 0, false }
		return status, true
	case .Nil:
		return propagation_nil_condition(function, status)
	}
	return 0, false
}

// Branches on condition into the procedure's exit; the fall-through arm ends the target.
@(private)
lower_or_return_exit :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	plan: check.Propagation_Plan,
	condition: ir.Node_Id,
	status: ir.Node_Id,
	status_type: types.Type_Id,
) -> bool {
	if plan.failure == 0 { _ = lower_fail(state, node, .Result); return false }
	exit_plan := check.plan(state.job.program, plan.failure)
	if exit_plan == nil { _ = lower_fail(state, node, .Result); return false }
	exit, valid_exit := exit_plan^.(check.Exit_Plan)
	if !valid_exit || exit.kind != .Return || len(exit.values) != 1 { _ = lower_fail(state, node, .Result); return false }
	builder := state.builder
	function := state.job.function
	end := ir.jump_target_make(builder)
	branch := ir.branch_if(builder, condition)
	ir.enter_arm(builder, branch, 0)
	ir.jump_to(builder, end)
	ir.enter_arm(builder, branch, 1)
	results := state.job.procedure.results
	if len(results) <= 1 {
		if len(results) == 1 && results[0] != 0 {
			if !or_return_status_storable(state, results[0], status_type, status) { _ = lower_fail(state, node, .Result); return false }
			store_result_entity(state, results[0], status)
			lower_return(state, node, nil, nil)
		} else {
			lower_scalar_return(state, node, status)
		}
	} else {
		if results[len(results) - 1] == 0 { _ = lower_fail(state, node, .Result); return false }
		if !or_return_status_storable(state, results[len(results) - 1], status_type, status) { _ = lower_fail(state, node, .Result); return false }
		store_result_entity(state, results[len(results) - 1], status)
		lower_return(state, node, nil, nil)
	}
	if state.failed || function.error != nil { return false }
	ir.seal_target(builder, end)
	return true
}

// Official `x == nil` for a status: zero for pointers and integer-backed types (enums, bit_sets).
@(private)
propagation_nil_condition :: proc(function: ^ir.Function, value: ir.Node_Id) -> (condition: ir.Node_Id, ok: bool) {
	value_type := function.nodes.type[value]
	#partial switch value_type {
	case .Ptr, .I8, .I16, .I32, .I64:
	case:
		return 0, false
	}
	return ir.compare(function, .Eq, value, ir.const_int(function, value_type, 0)), true
}

// A converted status (an enum into an error union) is not stored raw. Identical types and booleans whose
// register types match are the shapes this lowering already emits.
@(private)
or_return_status_storable :: proc(state: ^Procedure_State, entity: check.Entity_Id, status: types.Type_Id, value: ir.Node_Id) -> bool {
	if entity == 0 { return false }
	destination := state.job.program.entities[entity].type
	if destination == status { return true }
	destination_type := lower_type(state, destination)
	status_type := lower_type(state, status)
	if destination_type.kind != .Bool || status_type.kind != .Bool { return false }
	return state.job.function.nodes.type[value] == scalar_type(state, destination)
}
