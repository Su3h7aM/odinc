package lower

import "core:mem/virtual"
import "oc:check"
import "oc:ir"
import "oc:syntax"

@(private)
range_entity :: proc(state: ^Procedure_State, node: syntax.Node_Index) -> check.Entity_Id {
	info, ok := check.expression_info(state.job.program, state.view, node)
	if !ok || info.state != .Checked || state.ast.nodes[node].kind != .Ident {
		lower_fail(state, node, .Range)
		return 0
	}
	return info.entity
}

@(private)
lower_range_iteration :: proc(state: ^Procedure_State, statement: syntax.Range_Stmt, value, index: ir.Node_Id) {
	scope := local_scope(state)
	defer leave_local_scope(state, scope)
	names := syntax.node_list(state.ast, statement.vals)
	for name, position in names {
		entity := range_entity(state, name)
		if state.failed { return }
		if entity == 0 { continue }
		bind_local(state, entity, value if position == 0 else index, true)
	}
	lower_statement(state, statement.body)
}

@(private)
lower_range :: proc(state: ^Procedure_State, node: syntax.Node_Index, statement: syntax.Range_Stmt) {
	if statement.reverse { lower_fail(state, node, .Range); return }
	expression := statement.expr
	for state.ast.nodes[expression].kind == .Paren_Expr { expression = state.ast.nodes[expression].payload.(syntax.Paren_Expr).expr }
	if state.ast.nodes[expression].kind != .Binary_Expr { lower_fail(state, node, .Range); return }
	interval := state.ast.nodes[expression].payload.(syntax.Binary_Expr)
	if interval.op.kind != .Range_Half && interval.op.kind != .Range_Full && interval.op.kind != .Ellipsis { lower_fail(state, node, .Range); return }
	names := syntax.node_list(state.ast, statement.vals)
	if len(names) > 2 { lower_fail(state, node, .Range); return }
	scope := local_scope(state)
	defer leave_local_scope(state, scope)
	lower_statement(state, statement.init)
	if state.failed || state.job.function.error != nil || state.builder.control == 0 { return }
	initial := lower_value(state, interval.left)
	if state.failed || state.job.function.error != nil { return }
	function := state.job.function
	value_type := function.nodes.type[initial]
	if value_type < .I8 || value_type > .I64 { lower_fail(state, node, .Range); return }
	counter := ir.variable_declare(state.builder, initial)
	index_variable: ir.Variable
	index_type := ir.Value_Type.None
	if len(names) == 2 {
		entity := range_entity(state, names[1])
		if state.failed { return }
		if entity != 0 {
			index_type = scalar_type(state, state.job.program.entities[entity].type)
			if index_type < .I8 || index_type > .I64 { lower_fail(state, node, .Range); return }
			index_variable = ir.variable_declare(state.builder, ir.const_int(function, index_type, 0))
		}
	}
	allocator := virtual.arena_allocator(&function.arena)
	assigned, assigned_error := make([]bool, len(state.builder.values), allocator)
	if assigned_error != nil { function.error = assigned_error; return }
	scan_assigned_variables(state, statement.body, assigned)
	assigned[counter] = true
	if index_type != .None { assigned[index_variable] = true }
	variables := make([dynamic]ir.Variable, allocator)
	for modified, position in assigned {
		if modified && position != 0 {
			if _, err := append(&variables, ir.Variable(position)); err != nil { function.error = err; return }
		}
	}
	end := ir.jump_target_make(state.builder)
	loop := ir.loop_begin(state.builder, variables[:])
	continuation := ir.jump_target_make(state.builder)
	if !push_control_target(state, {{state.job.procedure.body.file, node}, end, continuation, true}) { return }
	defer pop(&state.control_targets)
	upper := lower_value(state, interval.right)
	if state.failed || function.error != nil { return }
	if function.nodes.type[upper] != value_type { lower_fail(state, node, .Range); return }
	current := ir.variable_get(state.builder, counter)
	signed := signed_type(state, lower_info(state, interval.left).type)
	inclusive := interval.op.kind != .Range_Half
	comparison := ir.Node_Kind.SLe if signed else ir.Node_Kind.ULe
	if !inclusive { comparison = .SLt if signed else .ULt }
	condition := ir.compare(function, comparison, current, upper)
	branch := ir.branch_if(state.builder, condition)
	ir.enter_arm(state.builder, branch, 1)
	ir.jump_to(state.builder, end)
	ir.enter_arm(state.builder, branch, 0)
	index := ir.NODE_NONE
	if index_type != .None { index = ir.variable_get(state.builder, index_variable) }
	lower_range_iteration(state, statement, current, index)
	if state.failed || function.error != nil { return }
	ir.jump_to(state.builder, continuation)
	if ir.seal_target(state.builder, continuation) {
		if inclusive {
			check := ir.branch_if(state.builder, ir.compare(function, .Ne, current, upper))
			ir.enter_arm(state.builder, check, 1)
			ir.jump_to(state.builder, end)
			ir.enter_arm(state.builder, check, 0)
		}
		ir.variable_set(state.builder, counter, ir.binary(function, .Add, current, ir.const_int(function, value_type, 1)))
		if index_type != .None {
			ir.variable_set(
				state.builder,
				index_variable,
				ir.binary(function, .Add, ir.variable_get(state.builder, index_variable), ir.const_int(function, index_type, 1)),
			)
		}
	}
	ir.loop_end(state.builder, loop)
	ir.seal_target(state.builder, end)
}
