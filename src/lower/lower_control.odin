package lower

import "core:mem/virtual"
import "oc:check"
import "oc:ir"
import "oc:syntax"

@(private)
Control_Target :: struct {
	node:            check.Node_Ref,
	break_target:    ir.Jump_Target_Id,
	continue_target: ir.Jump_Target_Id,
	is_loop:         bool,
	defers:          int,
}

@(private)
Local_Scope :: struct {
	variables, entities, defers: int,
	context_pointer:             ir.Node_Id,
}

@(private)
local_scope :: proc(state: ^Procedure_State) -> Local_Scope {
	return {len(state.builder.values), len(state.local_entities), len(state.defers), state.context_pointer}
}

// Runs the deferred statements registered at or above first, last registered first. Their
// statements may open their own scopes, which pop back to the same depth.
@(private)
run_deferred :: proc(state: ^Procedure_State, first: int) {
	for index := len(state.defers) - 1; index >= first; index -= 1 {
		if state.failed || state.job.function.error != nil || state.builder.control == 0 { return }
		switch action in state.defers[index] {
		case syntax.Node_Index:
			body := syntax.node_payload(state.ast, action, syntax.Defer_Stmt).stmt
			lower_statement(state, body)
		case Deferred_Call:
			function := state.job.function
			call := ir.call(
				function,
				state.builder.control,
				ir.variable_get(state.builder, ir.MEMORY_VARIABLE),
				action.callee,
				action.signature,
				action.arguments,
			)
			memory := ir.add_node(function, .Proj, .Memory, {call}, {index = 0})
			ir.variable_set(state.builder, ir.MEMORY_VARIABLE, memory)
		}
	}
}

@(private)
leave_local_scope :: proc(state: ^Procedure_State, scope: Local_Scope) {
	run_deferred(state, scope.defers)
	for entity in state.local_entities[scope.entities:] { state.locals[entity] = {} }
	state.context_pointer = scope.context_pointer
	if err := resize(&state.local_entities, scope.entities); err != nil { state.job.function.error = err }
	if err := resize(&state.defers, scope.defers); err != nil { state.job.function.error = err }
	if state.job.function.error == nil { ir.variables_truncate(state.builder, scope.variables) }
}

@(private)
lower_scoped_statement :: proc(state: ^Procedure_State, node: syntax.Node_Index) {
	scope := local_scope(state)
	defer leave_local_scope(state, scope)
	lower_statement(state, node)
}

@(private)
push_control_target :: proc(state: ^Procedure_State, target: Control_Target) -> bool {
	entry := target
	entry.defers = len(state.defers)
	if _, err := append(&state.control_targets, entry); err != nil {
		state.job.function.error = err
		return false
	}
	return true
}

@(private)
lower_block :: proc(state: ^Procedure_State, node: syntax.Node_Index, block: syntax.Block_Stmt) {
	scope := local_scope(state)
	defer leave_local_scope(state, scope)
	if block.label == 0 {
		for statement in syntax.node_list(state.ast, block.stmts) { lower_statement(state, statement) }
		return
	}
	end := ir.jump_target_make(state.builder)
	if !push_control_target(state, {node = {state.job.procedure.body.file, node}, break_target = end}) { return }
	defer pop(&state.control_targets)
	for statement in syntax.node_list(state.ast, block.stmts) { lower_statement(state, statement) }
	if state.failed || state.job.function.error != nil { return }
	run_deferred(state, scope.defers)
	if state.failed || state.job.function.error != nil { return }
	ir.jump_to(state.builder, end)
	ir.seal_target(state.builder, end)
}

@(private)
lower_if :: proc(state: ^Procedure_State, node: syntax.Node_Index, statement: syntax.If_Stmt) {
	scope := local_scope(state)
	defer leave_local_scope(state, scope)
	lower_statement(state, statement.init)
	if state.failed || state.job.function.error != nil || state.builder.control == 0 { return }
	condition := lower_value(state, statement.cond)
	if state.failed || state.job.function.error != nil { return }
	end := ir.jump_target_make(state.builder)
	if !push_control_target(state, {node = {state.job.procedure.body.file, node}, break_target = end}) { return }
	defer pop(&state.control_targets)
	if function := state.job.function; function.nodes.kind[condition] == .Const_Int {
		taken := statement.body if ir.node_int_value(function, condition) != 0 else statement.else_stmt
		lower_scoped_statement(state, taken)
		if state.failed || state.job.function.error != nil { return }
		ir.jump_to(state.builder, end)
		ir.seal_target(state.builder, end)
		return
	}
	branch := ir.branch_if(state.builder, condition)
	ir.enter_arm(state.builder, branch, 0)
	lower_scoped_statement(state, statement.body)
	if state.failed || state.job.function.error != nil { return }
	ir.jump_to(state.builder, end)
	ir.enter_arm(state.builder, branch, 1)
	lower_scoped_statement(state, statement.else_stmt)
	if state.failed || state.job.function.error != nil { return }
	ir.jump_to(state.builder, end)
	ir.seal_target(state.builder, end)
}

@(private)
mark_assigned_operand :: proc(state: ^Procedure_State, operand: check.Operand, assigned: []bool) {
	entity: check.Entity_Id
	#partial switch value in operand {
	case check.Entity_Id:
		entity = value
	case check.Expression_Ref:
		info, ok := check.expression_info(state.job.program, value.view, value.node)
		assert(ok)
		if state.ast.nodes[value.node].kind == .Ident { entity = info.entity }
	}
	if entity != 0 && state.locals[entity].kind == .Variable {
		variable := state.locals[entity].variable
		if int(variable) < len(assigned) { assigned[variable] = true }
	}
}

@(private)
scan_assigned_variables :: proc(state: ^Procedure_State, node: syntax.Node_Index, assigned: []bool) {
	if node == 0 { return }
	ast_node := state.ast.nodes[node]
	#partial switch statement in ast_node.payload {
	case syntax.Block_Stmt:
		for child in syntax.node_list(state.ast, statement.stmts) { scan_assigned_variables(state, child, assigned) }
	case syntax.If_Stmt:
		scan_assigned_variables(state, statement.init, assigned)
		scan_assigned_variables(state, statement.body, assigned)
		scan_assigned_variables(state, statement.else_stmt, assigned)
	case syntax.For_Stmt:
		scan_assigned_variables(state, statement.init, assigned)
		scan_assigned_variables(state, statement.body, assigned)
		scan_assigned_variables(state, statement.post, assigned)
	case syntax.When_Stmt:
		scan_assigned_variables(state, statement.body, assigned)
		scan_assigned_variables(state, statement.else_stmt, assigned)
	case syntax.Switch_Stmt:
		scan_assigned_variables(state, statement.init, assigned)
		scan_assigned_variables(state, statement.body, assigned)
	case syntax.Type_Switch_Stmt:
		scan_assigned_variables(state, statement.body, assigned)
	case syntax.Case_Clause:
		for child in syntax.node_list(state.ast, statement.body) { scan_assigned_variables(state, child, assigned) }
	case syntax.Range_Stmt:
		scan_assigned_variables(state, statement.init, assigned)
		scan_assigned_variables(state, statement.body, assigned)
	case syntax.Unroll_Range_Stmt:
		scan_assigned_variables(state, statement.body, assigned)
	case syntax.Tag_Stmt:
		scan_assigned_variables(state, statement.stmt, assigned)
	case syntax.Defer_Stmt:
		scan_assigned_variables(state, statement.stmt, assigned)
	case syntax.Assign_Stmt:
		info, ok := check.expression_info(state.job.program, state.view, node)
		if ok && info.plan != 0 {
			plan := check.plan(state.job.program, info.plan)
			assert(plan != nil)
			if assignment, found := plan^.(check.Assignment_Plan); found {
				for destination in assignment.destinations { mark_assigned_operand(state, destination, assigned) }
			}
		} else {
			for destination in syntax.node_list(state.ast, statement.lhs) {
				mark_assigned_operand(state, check.Expression_Ref{state.view, destination}, assigned)
			}
		}
	}
}

@(private)
lower_for :: proc(state: ^Procedure_State, node: syntax.Node_Index, statement: syntax.For_Stmt) {
	scope := local_scope(state)
	defer leave_local_scope(state, scope)
	lower_statement(state, statement.init)
	if state.failed || state.job.function.error != nil || state.builder.control == 0 { return }
	allocator := virtual.arena_allocator(&state.job.function.arena)
	assigned, assigned_error := make([]bool, len(state.builder.values), allocator)
	if assigned_error != nil { state.job.function.error = assigned_error; return }
	scan_assigned_variables(state, statement.body, assigned)
	scan_assigned_variables(state, statement.post, assigned)
	variables := make([dynamic]ir.Variable, allocator)
	for modified, index in assigned {
		if modified && index != 0 {
			if _, err := append(&variables, ir.Variable(index)); err != nil { state.job.function.error = err; return }
		}
	}
	end := ir.jump_target_make(state.builder)
	loop := ir.loop_begin(state.builder, variables[:])
	continuation := ir.jump_target_make(state.builder)
	if !push_control_target(
		state,
		{node = {state.job.procedure.body.file, node}, break_target = end, continue_target = continuation, is_loop = true},
	) { return }
	defer pop(&state.control_targets)
	if statement.cond != 0 {
		condition := lower_value(state, statement.cond)
		if state.failed || state.job.function.error != nil { return }
		branch := ir.branch_if(state.builder, condition)
		ir.enter_arm(state.builder, branch, 1)
		ir.jump_to(state.builder, end)
		ir.enter_arm(state.builder, branch, 0)
	}
	lower_scoped_statement(state, statement.body)
	if state.failed || state.job.function.error != nil { return }
	ir.jump_to(state.builder, continuation)
	if ir.seal_target(state.builder, continuation) { lower_statement(state, statement.post) }
	if state.failed || state.job.function.error != nil { return }
	ir.loop_end(state.builder, loop)
	ir.seal_target(state.builder, end)
}

@(private)
lower_branch :: proc(state: ^Procedure_State, node: syntax.Node_Index, statement: syntax.Branch_Stmt) {
	info, ok := check.expression_info(state.job.program, state.view, node)
	if !ok || info.plan == 0 { lower_fail(state, node, .Control); return }
	plan := check.plan(state.job.program, info.plan)
	assert(plan != nil)
	exit, found := plan^.(check.Exit_Plan)
	if !found || exit.target.node == 0 { lower_fail(state, node, .Control); return }
	if exit.kind != .Break && exit.kind != .Continue { lower_fail(state, node, .Control); return }
	assert(exit.kind == .Break && statement.token.kind == .Break || exit.kind == .Continue && statement.token.kind == .Continue)
	lower_branch_exit(state, node, exit)
}

@(private)
lower_branch_exit :: proc(state: ^Procedure_State, node: syntax.Node_Index, exit: check.Exit_Plan) {
	for index := len(state.control_targets) - 1; index >= 0; index -= 1 {
		target := state.control_targets[index]
		if target.node != exit.target { continue }
		if exit.kind == .Continue {
			if !target.is_loop { lower_fail(state, node, .Control); return }
			run_deferred(state, target.defers)
			ir.jump_to(state.builder, target.continue_target)
		} else {
			run_deferred(state, target.defers)
			ir.jump_to(state.builder, target.break_target)
		}
		return
	}
	lower_fail(state, node, .Control)
}

@(private)
lower_when :: proc(state: ^Procedure_State, node: syntax.Node_Index, statement: syntax.When_Stmt) {
	body, ok := check.expression_info(state.job.program, state.view, statement.body)
	if !ok { lower_fail(state, node, .Control); return }
	if body.state == .Checked { lower_when_branch(state, statement.body); return }
	if body.state != .Inactive { lower_fail(state, node, .Control); return }
	if statement.else_stmt != 0 {
		alternative, found := check.expression_info(state.job.program, state.view, statement.else_stmt)
		if !found || alternative.state != .Checked { lower_fail(state, node, .Control); return }
		lower_when_branch(state, statement.else_stmt)
	}
}

// A taken `when` branch declares into the enclosing scope, as official check_when_stmt checks it with check_stmt_list.
@(private)
lower_when_branch :: proc(state: ^Procedure_State, node: syntax.Node_Index) {
	if state.ast.nodes[node].kind != .Block_Stmt {
		lower_statement(state, node)
		return
	}
	block := syntax.node_payload(state.ast, node, syntax.Block_Stmt)
	if block.label != 0 {
		lower_scoped_statement(state, node)
		return
	}
	for statement in syntax.node_list(state.ast, block.stmts) { lower_statement(state, statement) }
}
