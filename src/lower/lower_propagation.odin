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
	status_type: types.Type_Id
	#partial switch value in operand_plan^ {
	case check.Call_Plan:
		if len(value.results) != 2 { return lower_fail(state, node, .Expression) }
		status_type = value.results[1]
		lower_call_results(state, call_node, operand_info, value, values[:])
	case check.Type_Assertion_Plan:
		if !value.comma_ok { return lower_fail(state, node, .Expression) }
		values[0], values[1] = lower_type_assertion(state, call_node, value)
	case check.Map_Index_Plan:
		values[0], values[1] = lower_map_index(state, call_node, value)
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
		condition = lower_value_is_nil(state, status_type, values[1])
	}
	result_type := lower_info(state, node).type
	scalar := scalar_type(state, result_type)
	builder := state.builder
	function := state.job.function
	count := len(builder.values)
	result: ir.Variable
	slot: ir.Node_Id
	if scalar == .None {
		layout := state.job.layouts[result_type]
		if layout.error != .None { return lower_fail(state, node, .Expression) }
		slot = ir.stack_slot(function, state.entry_control, u32(max(layout.size, 1)), u32(layout.align))
	} else {
		result = ir.variable_declare(builder, ir.undef(function, scalar))
	}
	end := ir.jump_target_make(builder)
	branch := ir.branch_if(builder, condition)
	ir.enter_arm(builder, branch, 0)
	if scalar == .None {
		lower_store(state, slot, values[0], result_type)
	} else {
		ir.variable_set(builder, result, values[0])
	}
	ir.jump_to(builder, end)
	ir.enter_arm(builder, branch, 1)
	expression := state.ast.nodes[node].payload.(syntax.Or_Else_Expr)
	if lower_info(state, expression.y).mode == .No_Value {
		// A diverging fallback (noreturn call) produces no value: the call runs and the arm ends there.
		lower_value(state, expression.y)
		if state.failed || function.error != nil { return 0 }
		ir.emit_unreachable(builder)
	} else {
		fallback := lower_ternary_arm(state, expression.y, plan.fallback_conversion)
		if state.failed || function.error != nil { return 0 }
		if scalar == .None {
			lower_store(state, slot, fallback, result_type)
		} else {
			ir.variable_set(builder, result, fallback)
		}
		ir.jump_to(builder, end)
	}
	ir.seal_target(builder, end)
	value := slot
	if scalar != .None { value = ir.variable_get(builder, result) }
	ir.variables_truncate(builder, count)
	return value
}

@(private)
lower_or_branch :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Propagation_Plan) -> ir.Node_Id {
	values, allocation_error := make([]ir.Node_Id, len(plan.values), context.allocator)
	if allocation_error != nil { state.job.function.error = allocation_error; return 0 }
	defer delete(values, context.allocator)
	if !lower_or_branch_values(state, node, plan, values) { return 0 }
	if len(values) == 0 { return 0 }
	return values[0]
}

@(private)
lower_or_branch_values :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Propagation_Plan, values: []ir.Node_Id) -> bool {
	operand, is_expression := plan.operand.(check.Expression_Ref)
	if !is_expression || operand.view != state.view { lower_fail(state, node, .Expression); return false }
	operand_info := lower_info(state, operand.node)
	operand_plan := check.plan(state.job.program, operand_info.plan)
	call_node := operand.node
	for state.ast.nodes[call_node].kind == .Paren_Expr {
		call_node = state.ast.nodes[call_node].payload.(syntax.Paren_Expr).expr
	}
	result_count := 1
	status_type := operand_info.type
	if operand_plan != nil {
		#partial switch result_plan in operand_plan^ {
		case check.Call_Plan:
			if len(result_plan.results) < 1 { lower_fail(state, node, .Expression); return false }
			result_count = len(result_plan.results)
			status_type = result_plan.results[result_count - 1]
		case check.Type_Assertion_Plan:
			if !result_plan.comma_ok { lower_fail(state, node, .Expression); return false }
			result_count = 2
		case check.Map_Index_Plan:
			if !result_plan.comma_ok { lower_fail(state, node, .Expression); return false }
			result_count = 2
		case:
		}
	}
	status_index := result_count - 1
	if len(values) != status_index { lower_fail(state, node, .Result); return false }
	all_values, allocation_error := make([]ir.Node_Id, result_count, context.allocator)
	if allocation_error != nil { state.job.function.error = allocation_error; return false }
	defer delete(all_values, context.allocator)
	if operand_plan == nil {
		all_values[0] = lower_operand(state, plan.operand, status_type)
	} else {
		#partial switch result_plan in operand_plan^ {
		case check.Call_Plan:
			lower_call_results(state, call_node, operand_info, result_plan, all_values)
		case check.Type_Assertion_Plan:
			all_values[0], all_values[1] = lower_type_assertion(state, call_node, result_plan)
		case check.Map_Index_Plan:
			all_values[0], all_values[1] = lower_map_index(state, call_node, result_plan)
		case:
			all_values[0] = lower_operand(state, plan.operand, status_type)
		}
	}
	if state.failed || state.job.function.error != nil { return false }
	condition, condition_ok := lower_propagation_condition(state, plan, all_values[status_index], status_type)
	if !condition_ok { lower_fail(state, node, .Expression); return false }
	if plan.failure == 0 { lower_fail(state, node, .Control); return false }
	exit_plan := check.plan(state.job.program, plan.failure)
	if exit_plan == nil { lower_fail(state, node, .Control); return false }
	exit, valid_exit := exit_plan^.(check.Exit_Plan)
	branch_expr := state.ast.nodes[node].payload.(syntax.Or_Branch_Expr)
	expected_exit := check.Exit_Kind.Break
	if branch_expr.token.kind == .Or_Continue {
		expected_exit = .Continue
	} else if branch_expr.token.kind != .Or_Break {
		lower_fail(state, node, .Control)
		return false
	}
	if !valid_exit || exit.kind != expected_exit || exit.target.node == 0 { lower_fail(state, node, .Control); return false }
	builder := state.builder
	end := ir.jump_target_make(builder)
	branch := ir.branch_if(builder, condition)
	ir.enter_arm(builder, branch, 0)
	ir.jump_to(builder, end)
	ir.enter_arm(builder, branch, 1)
	lower_branch_exit(state, node, exit)
	if state.failed || state.job.function.error != nil { return false }
	ir.seal_target(builder, end)
	for index in 0 ..< status_index { values[index] = all_values[index] }
	return true
}

@(private)
lower_or_return :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Propagation_Plan) -> ir.Node_Id {
	operand, is_expression := plan.operand.(check.Expression_Ref)
	if !is_expression || operand.view != state.view { return lower_fail(state, node, .Expression) }
	operand_info := lower_info(state, operand.node)
	if operand_info.plan == 0 { return lower_or_return_stored(state, node, plan, operand, operand_info.type) }
	values, allocation_error := make([]ir.Node_Id, len(plan.values), context.allocator)
	if allocation_error != nil { state.job.function.error = allocation_error; return 0 }
	defer delete(values, context.allocator)
	if !lower_or_return_values(state, node, plan, values) { return 0 }
	if len(values) == 0 { return 0 }
	if len(values) != 1 { return lower_fail(state, node, .Result) }
	return values[0]
}

@(private)
lower_or_return_values :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Propagation_Plan, values: []ir.Node_Id) -> bool {
	operand, is_expression := plan.operand.(check.Expression_Ref)
	if !is_expression || operand.view != state.view { lower_fail(state, node, .Expression); return false }
	operand_info := lower_info(state, operand.node)
	if operand_info.plan == 0 { lower_fail(state, node, .Expression); return false }
	call_node := operand.node
	for state.ast.nodes[call_node].kind == .Paren_Expr {
		call_node = state.ast.nodes[call_node].payload.(syntax.Paren_Expr).expr
	}
	operand_plan := check.plan(state.job.program, operand_info.plan)
	if operand_plan == nil { lower_fail(state, node, .Expression); return false }
	result_count := 0
	status_type: types.Type_Id
	#partial switch result_plan in operand_plan^ {
	case check.Call_Plan:
		if len(result_plan.results) < 1 { lower_fail(state, node, .Expression); return false }
		result_count = len(result_plan.results)
		status_type = result_plan.results[result_count - 1]
	case check.Type_Assertion_Plan:
		if !result_plan.comma_ok { lower_fail(state, node, .Expression); return false }
		result_count = 2
	case:
		lower_fail(state, node, .Expression)
		return false
	}
	status_index := result_count - 1
	if len(values) != status_index || len(plan.values) != status_index { lower_fail(state, node, .Result); return false }
	all_values, allocation_error := make([]ir.Node_Id, result_count, context.allocator)
	if allocation_error != nil { state.job.function.error = allocation_error; return false }
	defer delete(all_values, context.allocator)
	#partial switch result_plan in operand_plan^ {
	case check.Call_Plan:
		lower_call_results(state, call_node, operand_info, result_plan, all_values)
	case check.Type_Assertion_Plan:
		all_values[0], all_values[1] = lower_type_assertion(state, call_node, result_plan)
	}
	if state.failed || state.job.function.error != nil { return false }
	condition, condition_ok := lower_propagation_condition(state, plan, all_values[status_index], status_type)
	if !condition_ok { lower_fail(state, node, .Expression); return false }
	if !lower_or_return_exit(state, node, plan, condition, all_values[status_index], status_type) { return false }
	copy(values, all_values[:status_index])
	return true
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
	condition, condition_ok := lower_propagation_condition(state, plan, status, status_type)
	if !condition_ok { return lower_fail(state, node, .Expression) }
	if !lower_or_return_exit(state, node, plan, condition, status, status_type) { return 0 }
	return 0
}

@(private)
lower_propagation_condition :: proc(
	state: ^Procedure_State,
	plan: check.Propagation_Plan,
	status: ir.Node_Id,
	status_type: types.Type_Id,
) -> (
	condition: ir.Node_Id,
	ok: bool,
) {
	switch plan.test {
	case .Boolean_True:
		if state.job.function.nodes.type[status] != .Bool { return 0, false }
		return status, true
	case .Nil:
		condition = lower_value_is_nil(state, status_type, status)
		return condition, !state.failed
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
	conversion: check.Plan_Id
	if len(exit.conversions) == 1 { conversion = exit.conversions[0] }
	value := status
	if conversion != 0 {
		value = lower_or_return_conversion(state, node, conversion, status_type, status)
		if state.failed || function.error != nil { return false }
	}
	results := state.job.procedure.results
	if len(results) <= 1 {
		if len(results) == 1 && results[0] != 0 {
			if conversion == 0 && !or_return_status_storable(state, results[0], status_type, status) { _ = lower_fail(state, node, .Result); return false }
			store_result_entity(state, results[0], value)
			lower_return(state, node, nil, nil)
		} else {
			returned := [1]ir.Node_Id{value}
			lower_result_values(state, node, returned[:])
		}
	} else {
		if results[len(results) - 1] == 0 { _ = lower_fail(state, node, .Result); return false }
		if conversion == 0 &&
		   !or_return_status_storable(state, results[len(results) - 1], status_type, status) { _ = lower_fail(state, node, .Result); return false }
		store_result_entity(state, results[len(results) - 1], value)
		lower_return(state, node, nil, nil)
	}
	if state.failed || function.error != nil { return false }
	ir.seal_target(builder, end)
	return true
}

// A converted status (an enum into an error union) is not stored raw. Identical types and booleans whose
// register types match are the shapes this lowering already emits.
@(private)
or_return_status_storable :: proc(state: ^Procedure_State, entity: check.Entity_Id, status: types.Type_Id, value: ir.Node_Id) -> bool {
	if entity == 0 { return false }
	destination := state.job.program.entities[entity].type
	if status != 0 && destination == status { return true }
	if lower_type(state, destination).kind != .Bool { return false }
	if status != 0 && lower_type(state, status).kind != .Bool { return false }
	return state.job.function.nodes.type[value] == scalar_type(state, destination)
}

@(private)
lower_or_return_conversion :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	plan_id: check.Plan_Id,
	status_type: types.Type_Id,
	status: ir.Node_Id,
) -> ir.Node_Id {
	if status_type == 0 { return lower_fail(state, node, .Conversion) }
	plan := check.plan(state.job.program, plan_id)
	if plan == nil { return lower_fail(state, node, .Conversion) }
	conversion, found := plan^.(check.Conversion_Plan)
	if !found { return lower_fail(state, node, .Conversion) }
	return lower_conversion_value(state, conversion, node, status_type, status)
}
