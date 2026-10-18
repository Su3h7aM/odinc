package lower

import "core:mem/virtual"
import "oc:check"
import "oc:ir"
import "oc:syntax"

// `snapshot` makes a dynamic array read its data and length once, as `#unroll(N)` does.
@(private)
Range_Parts :: struct {
	init, expr, body: syntax.Node_Index,
	names:            []syntax.Node_Index,
	snapshot:         bool,
	reverse:          bool,
}

@(private)
range_name_node :: proc(state: ^Procedure_State, node: syntax.Node_Index) -> (ident: syntax.Node_Index, by_reference: bool) {
	if state.ast.nodes[node].kind == .Unary_Expr {
		unary := state.ast.nodes[node].payload.(syntax.Unary_Expr)
		if unary.op.kind == .And { return unary.expr, true }
	}
	return node, false
}

@(private)
range_entity :: proc(state: ^Procedure_State, node: syntax.Node_Index) -> check.Entity_Id {
	ident, _ := range_name_node(state, node)
	info, ok := check.expression_info(state.job.program, state.view, ident)
	if !ok || info.state != .Checked || state.ast.nodes[ident].kind != .Ident {
		lower_fail(state, node, .Range)
		return 0
	}
	return info.entity
}

@(private)
bind_reference_local :: proc(state: ^Procedure_State, entity: check.Entity_Id, address: ir.Node_Id) {
	assert(entity != 0 && state.locals[entity].kind == .None)
	if _, err := append(&state.local_entities, entity); err != nil {
		state.job.function.error = err
		return
	}
	state.locals[entity] = {
		kind    = .Address,
		address = address,
	}
}

// `value` binds the first name (by value, or by reference through `address`); `index` binds the second.
@(private)
lower_range_iteration :: proc(state: ^Procedure_State, parts: Range_Parts, value, address, index: ir.Node_Id) {
	scope := local_scope(state)
	defer leave_local_scope(state, scope)
	for name, position in parts.names {
		entity := range_entity(state, name)
		if state.failed { return }
		if entity == 0 { continue }
		if position == 1 {
			bind_local(state, entity, index, true)
			continue
		}
		if _, by_reference := range_name_node(state, name); by_reference {
			bind_reference_local(state, entity, address)
		} else {
			bind_local(state, entity, value, true)
		}
	}
	lower_statement(state, parts.body)
}

@(private)
range_value_type :: proc(value_type: ir.Value_Type) -> bool {
	return value_type >= .I8 && value_type <= .I64 || value_type == .F32 || value_type == .F64
}

// The variables a loop carries: those its body assigns, plus the hidden ones its header updates.
@(private)
range_loop_variables :: proc(state: ^Procedure_State, body: syntax.Node_Index, hidden: ..ir.Variable) -> (variables: []ir.Variable, ok: bool) {
	function := state.job.function
	allocator := virtual.arena_allocator(&function.arena)
	assigned, assigned_error := make([]bool, len(state.builder.values), allocator)
	if assigned_error != nil {
		function.error = assigned_error
		return nil, false
	}
	scan_assigned_variables(state, body, assigned)
	for variable in hidden { assigned[variable] = true }
	list := make([dynamic]ir.Variable, allocator)
	for modified, position in assigned {
		if modified && position != 0 {
			if _, err := append(&list, ir.Variable(position)); err != nil {
				function.error = err
				return nil, false
			}
		}
	}
	return list[:], true
}

@(private)
lower_range :: proc(state: ^Procedure_State, node: syntax.Node_Index, statement: syntax.Range_Stmt) {
	lower_range_parts(
		state,
		node,
		Range_Parts {
			init = statement.init,
			expr = statement.expr,
			body = statement.body,
			names = syntax.node_list(state.ast, statement.vals),
			reverse = statement.reverse,
		},
	)
}

@(private)
lower_unroll_range :: proc(state: ^Procedure_State, node: syntax.Node_Index, statement: syntax.Unroll_Range_Stmt) {
	names_buffer: [2]syntax.Node_Index
	count := 0
	if statement.val0 != 0 {
		names_buffer[count] = statement.val0
		count += 1
	}
	if statement.val1 != 0 {
		names_buffer[count] = statement.val1
		count += 1
	}
	lower_range_parts(
		state,
		node,
		Range_Parts {
			expr = statement.expr,
			body = statement.body,
			names = names_buffer[:count],
			snapshot = len(syntax.node_list(state.ast, statement.args)) > 0,
		},
	)
}

@(private)
lower_range_parts :: proc(state: ^Procedure_State, node: syntax.Node_Index, parts: Range_Parts) {
	expression := parts.expr
	for state.ast.nodes[expression].kind == .Paren_Expr { expression = state.ast.nodes[expression].payload.(syntax.Paren_Expr).expr }
	if state.ast.nodes[expression].kind == .Binary_Expr {
		interval := state.ast.nodes[expression].payload.(syntax.Binary_Expr)
		if interval.op.kind == .Range_Half || interval.op.kind == .Range_Full {
			if parts.reverse {
				lower_fail(state, node, .Range)
				return
			}
			lower_range_interval(state, node, parts, interval)
			return
		}
	}
	info := lower_info(state, parts.expr)
	if info.mode == check.Addressing_Mode.Type {
		lower_range_enum(state, node, parts)
		return
	}
	if lower_type(state, info.type).kind == .Bit_Set {
		lower_range_bit_set(state, node, parts)
		return
	}
	if kind := lower_type(state, info.type).kind; kind == .String || kind == .String16 {
		lower_range_string(state, node, parts, kind)
		return
	}
	lower_range_container(state, node, parts)
}

@(private)
lower_range_interval :: proc(state: ^Procedure_State, node: syntax.Node_Index, parts: Range_Parts, interval: syntax.Binary_Expr) {
	scope := local_scope(state)
	defer leave_local_scope(state, scope)
	lower_statement(state, parts.init)
	if state.failed || state.job.function.error != nil || state.builder.control == 0 { return }
	initial := lower_value(state, interval.left)
	if state.failed || state.job.function.error != nil { return }
	function := state.job.function
	value_type := function.nodes.type[initial]
	if !range_value_type(value_type) { lower_fail(state, node, .Range); return }
	is_float := value_type == .F32 || value_type == .F64
	counter := ir.variable_declare(state.builder, initial)
	index_variable: ir.Variable
	index_type := ir.Value_Type.None
	if len(parts.names) == 2 {
		entity := range_entity(state, parts.names[1])
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
	scan_assigned_variables(state, parts.body, assigned)
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
	if !push_control_target(
		state,
		{node = {state.job.procedure.body.file, node}, break_target = end, continue_target = continuation, is_loop = true},
	) { return }
	defer pop(&state.control_targets)
	upper := lower_value(state, interval.right)
	if state.failed || function.error != nil { return }
	if function.nodes.type[upper] != value_type { lower_fail(state, node, .Range); return }
	current := ir.variable_get(state.builder, counter)
	signed := signed_type(state, lower_info(state, interval.left).type)
	inclusive := interval.op.kind != .Range_Half
	comparison: ir.Node_Kind
	switch {
	case is_float:
		comparison = .FLe if inclusive else .FLt
	case signed:
		comparison = .SLe if inclusive else .SLt
	case:
		comparison = .ULe if inclusive else .ULt
	}
	condition := ir.compare(function, comparison, current, upper)
	branch := ir.branch_if(state.builder, condition)
	ir.enter_arm(state.builder, branch, 1)
	ir.jump_to(state.builder, end)
	ir.enter_arm(state.builder, branch, 0)
	index := ir.NODE_NONE
	if index_type != .None { index = ir.variable_get(state.builder, index_variable) }
	lower_range_iteration(state, parts, current, ir.NODE_NONE, index)
	if state.failed || function.error != nil { return }
	ir.jump_to(state.builder, continuation)
	if ir.seal_target(state.builder, continuation) {
		if inclusive {
			equal_kind := ir.Node_Kind.FNe if is_float else ir.Node_Kind.Ne
			check := ir.branch_if(state.builder, ir.compare(function, equal_kind, current, upper))
			ir.enter_arm(state.builder, check, 1)
			ir.jump_to(state.builder, end)
			ir.enter_arm(state.builder, check, 0)
		}
		step: ir.Node_Id
		if is_float {
			one_bits: u64 = 0x3FF0000000000000 if value_type == .F64 else 0x3F800000
			step = ir.binary(function, .FAdd, ir.variable_get(state.builder, counter), ir.const_float(function, value_type, one_bits))
		} else {
			step = ir.binary(function, .Add, ir.variable_get(state.builder, counter), ir.const_int(function, value_type, 1))
		}
		ir.variable_set(state.builder, counter, step)
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
