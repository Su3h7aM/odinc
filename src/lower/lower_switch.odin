package lower

import "core:mem/virtual"
import "oc:ir"
import "oc:syntax"

// Each case value is tested in turn and jumps to its clause body; the clauses fall through to the end, not to each other.
@(private)
lower_switch :: proc(state: ^Procedure_State, node: syntax.Node_Index, statement: syntax.Switch_Stmt) {
	scope := local_scope(state)
	defer leave_local_scope(state, scope)
	lower_statement(state, statement.init)
	if state.failed || state.job.function.error != nil || state.builder.control == 0 { return }
	tag: ir.Node_Id
	if statement.cond != 0 {
		tag_info := lower_info(state, statement.cond)
		tag = lower_value(state, statement.cond)
		if state.failed || state.job.function.error != nil { return }
		if scalar_type(state, tag_info.type) == .None { lower_fail(state, node, .Switch); return }
	}
	clauses := syntax.node_list(state.ast, state.ast.nodes[statement.body].payload.(syntax.Block_Stmt).stmts)
	allocator := virtual.arena_allocator(&state.job.function.arena)
	bodies, bodies_error := make([]ir.Jump_Target_Id, len(clauses), allocator)
	if bodies_error != nil { state.job.function.error = bodies_error; return }
	end := ir.jump_target_make(state.builder)
	if !push_control_target(state, {{state.job.procedure.body.file, node}, end, 0, false}) { return }
	defer pop(&state.control_targets)
	default_body := -1
	for clause, index in clauses {
		bodies[index] = ir.jump_target_make(state.builder)
		case_clause := state.ast.nodes[clause].payload.(syntax.Case_Clause)
		values := syntax.node_list(state.ast, case_clause.list)
		if len(values) == 0 { default_body = index }
		for value_node in values {
			condition := lower_value(state, value_node)
			if state.failed || state.job.function.error != nil { return }
			if tag != 0 { condition = ir.compare(state.job.function, .Eq, tag, condition) }
			branch := ir.branch_if(state.builder, condition)
			ir.enter_arm(state.builder, branch, 0)
			ir.jump_to(state.builder, bodies[index])
			ir.enter_arm(state.builder, branch, 1)
		}
	}
	if default_body >= 0 {
		ir.jump_to(state.builder, bodies[default_body])
	} else {
		ir.jump_to(state.builder, end)
	}
	for clause, index in clauses {
		if !ir.seal_target(state.builder, bodies[index]) { continue }
		body_scope := local_scope(state)
		case_clause := state.ast.nodes[clause].payload.(syntax.Case_Clause)
		for statement_node in syntax.node_list(state.ast, case_clause.body) { lower_statement(state, statement_node) }
		leave_local_scope(state, body_scope)
		if state.failed || state.job.function.error != nil { return }
		ir.jump_to(state.builder, end)
	}
	ir.seal_target(state.builder, end)
}
