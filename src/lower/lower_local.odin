package lower

import "core:mem/virtual"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

@(private)
Local_Kind :: enum u8 {
	None,
	Variable,
	Address,
}

@(private)
Local_Binding :: struct {
	kind:     Local_Kind,
	variable: ir.Variable,
	address:  ir.Node_Id,
}

@(private)
mark_address_taken :: proc(state: ^Procedure_State, operand: check.Operand) {
	#partial switch value in operand {
	case check.Entity_Id:
		state.address_taken[value] = true
	case check.Expression_Ref:
		info, ok := check.expression_info(state.job.program, value.view, value.node)
		assert(ok)
		if info.entity != 0 { state.address_taken[info.entity] = true; return }
		ast := state.ast
		#partial switch ast.nodes[value.node].kind {
		case .Paren_Expr:
			mark_address_taken(state, check.Expression_Ref{value.view, ast.nodes[value.node].payload.(syntax.Paren_Expr).expr})
		case .Selector_Expr:
			mark_address_taken(state, check.Expression_Ref{value.view, ast.nodes[value.node].payload.(syntax.Selector_Expr).expr})
		case .Index_Expr:
			mark_address_taken(state, check.Expression_Ref{value.view, ast.nodes[value.node].payload.(syntax.Index_Expr).expr})
		}
	case check.Projection:
		mark_address_taken(state, value.expression)
	case:
	}
}

@(private)
scan_addresses :: proc(state: ^Procedure_State) {
	view := state.job.procedure.view
	if view == 0 { return }
	assert(int(view) < len(state.job.program.typed_views))
	typed := &state.job.program.typed_views[view]
	for status, index in typed.nodes.states {
		if status != .Checked { continue }
		node := typed.first_node + syntax.Node_Index(index)
		assert(int(node) < len(state.ast.nodes))
		ast_node := state.ast.nodes[node]
		#partial switch ast_node.kind {
		case .Unary_Expr:
			unary := ast_node.payload.(syntax.Unary_Expr)
			if unary.op.kind == .And { mark_address_taken(state, check.Expression_Ref{view, unary.expr}) }
		case .Slice_Expr:
			mark_address_taken(state, check.Expression_Ref{view, ast_node.payload.(syntax.Slice_Expr).expr})
		}
		if typed.nodes.plans[index] == 0 { continue }
		plan := check.plan(state.job.program, typed.nodes.plans[index])
		assert(plan != nil)
		#partial switch value in plan^ {
		case check.Conversion_Plan:
			if value.kind == .Box { mark_address_taken(state, value.source) }
		case check.Call_Plan:
			for argument in value.arguments {
				if argument.parameter == 0 { continue }
				parameter := &state.job.program.entities[argument.parameter]
				if .By_Pointer in parameter.flags { mark_address_taken(state, argument.value) }
			}
		case:
		}
	}
}

@(private)
bind_local :: proc(state: ^Procedure_State, entity: check.Entity_Id, value: ir.Node_Id, initialize: bool) {
	assert(entity != 0 && state.locals[entity].kind == .None)
	if _, err := append(&state.local_entities, entity); err != nil { state.job.function.error = err; return }
	type := state.job.program.entities[entity].type
	if value != 0 && scalar_type(state, type) != .None && state.job.function.nodes.type[value] != scalar_type(state, type) {
		lower_fail(state, state.job.procedure.body.node, .Conversion)
		return
	}
	if scalar_type(state, type) != .None && !state.address_taken[entity] {
		initial := value
		if initial == 0 {
			scalar := scalar_type(state, type)
			if !initialize { initial = ir.undef(state.job.function, scalar) } else if scalar == .F16 || scalar == .F32 || scalar == .F64 { initial = ir.const_float(state.job.function, scalar, 0) } else { initial = ir.const_int(state.job.function, scalar, 0) }
		}
		state.locals[entity] = {
			kind     = .Variable,
			variable = ir.variable_declare(state.builder, initial),
		}
		return
	}
	layout := state.job.layouts[type]
	assert(layout.error == .None && layout.size >= 0 && layout.size <= i64(max(u32)))
	address := ir.stack_slot(state.job.function, state.entry_control, u32(layout.size), u32(layout.align))
	state.locals[entity] = {
		kind    = .Address,
		address = address,
	}
	if value != 0 { lower_store(state, address, value, type); return }
	if !initialize { return }
	function := state.job.function
	memory := ir.add_node(
		function,
		.Mem_Set,
		.Memory,
		{
			state.builder.control,
			ir.variable_get(state.builder, ir.MEMORY_VARIABLE),
			address,
			ir.const_int(function, .I8, 0),
			ir.const_int(function, .I64, layout.size),
		},
	)
	ir.variable_set(state.builder, ir.MEMORY_VARIABLE, memory)
}

@(private)
lower_local_declaration :: proc(state: ^Procedure_State, node: syntax.Node_Index, declaration: syntax.Value_Decl) {
	if !declaration.is_mutable { return }
	names := syntax.node_list(state.ast, declaration.names)
	values := syntax.node_list(state.ast, declaration.values)
	if len(values) != 0 && len(values) != len(names) { lower_fail(state, node, .Local); return }
	allocator := virtual.arena_allocator(&state.job.function.arena)
	initials, err := make([]ir.Node_Id, len(names), allocator)
	if err != nil { state.job.function.error = err; return }
	for value, index in values {
		if state.ast.nodes[value].kind != .Undef { initials[index] = lower_value(state, value) }
	}
	if state.failed { return }
	for name, index in names {
		info := lower_info(state, name)
		if info.entity == 0 { continue }
		initialize := len(values) == 0 || state.ast.nodes[values[index]].kind != .Undef
		bind_local(state, info.entity, initials[index], initialize)
	}
}

@(private)
Assignment_Destination :: struct {
	entity:  check.Entity_Id,
	type:    types.Type_Id,
	address: ir.Node_Id,
}

@(private)
lower_destination :: proc(state: ^Procedure_State, operand: check.Operand) -> Assignment_Destination {
	#partial switch value in operand {
	case check.Entity_Id:
		if value == 0 { return {} }
		if state.locals[value].kind == .Variable { return {entity = value, type = state.job.program.entities[value].type} }
		return {type = state.job.program.entities[value].type, address = lower_operand_address(state, operand)}
	case check.Expression_Ref:
		info, ok := check.expression_info(state.job.program, value.view, value.node)
		assert(ok && info.state == .Checked)
		if info.mode == .No_Value && info.entity == 0 { return {} }
		if state.ast.nodes[value.node].kind == .Ident && info.entity != 0 && state.locals[info.entity].kind == .Variable {
			return {entity = info.entity, type = info.type}
		}
		return {type = info.type, address = lower_operand_address(state, operand)}
	case:
		lower_fail(state, state.job.procedure.body.node, .Place)
		return {}
	}
}

@(private)
write_destination :: proc(state: ^Procedure_State, destination: Assignment_Destination, value: ir.Node_Id, node: syntax.Node_Index) {
	if destination.type == 0 || state.failed || state.job.function.error != nil { return }
	scalar := scalar_type(state, destination.type)
	if scalar != .None && state.job.function.nodes.type[value] != scalar { lower_fail(state, node, .Conversion); return }
	if destination.entity !=
	   0 { ir.variable_set(state.builder, state.locals[destination.entity].variable, value) } else { lower_store(state, destination.address, value, destination.type) }
}

@(private)
lower_assignment_plan :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Assignment_Plan) {
	if len(plan.destinations) != len(plan.values) { lower_fail(state, node, .Local); return }
	assert(len(plan.conversions) == 0 || len(plan.conversions) == len(plan.values))
	allocator := virtual.arena_allocator(&state.job.function.arena)
	destinations, err := make([]Assignment_Destination, len(plan.destinations), allocator)
	if err != nil { state.job.function.error = err; return }
	values, value_error := make([]ir.Node_Id, len(plan.values), allocator)
	if value_error != nil { state.job.function.error = value_error; return }
	for destination, index in plan.destinations { destinations[index] = lower_destination(state, destination) }
	for value, index in plan.values {
		if len(plan.conversions) != 0 && plan.conversions[index] != 0 {
			conversion := check.plan(state.job.program, plan.conversions[index])
			assert(conversion != nil)
			if converted, ok := conversion^.(check.Conversion_Plan);
			   ok { values[index] = lower_conversion(state, converted, node) } else { lower_fail(state, node, .Conversion); return }
		} else {
			values[index] = lower_operand(state, value, destinations[index].type)
		}
	}
	if state.failed { return }
	for destination, index in destinations { write_destination(state, destination, values[index], node) }
}

@(private)
lower_local_assignment :: proc(state: ^Procedure_State, node: syntax.Node_Index, assignment: syntax.Assign_Stmt) {
	if assignment.op.kind != .Eq { lower_compound_assignment(state, node, assignment); return }
	info, ok := check.expression_info(state.job.program, state.view, node)
	if ok && info.plan != 0 {
		plan := check.plan(state.job.program, info.plan)
		assert(plan != nil)
		if value, found := plan^.(check.Assignment_Plan); found { lower_assignment_plan(state, node, value) } else { lower_fail(state, node, .Local) }
		return
	}
	left := syntax.node_list(state.ast, assignment.lhs)
	right := syntax.node_list(state.ast, assignment.rhs)
	if len(left) != len(right) { lower_fail(state, node, .Local); return }
	allocator := virtual.arena_allocator(&state.job.function.arena)
	destinations, err := make([]Assignment_Destination, len(left), allocator)
	if err != nil { state.job.function.error = err; return }
	values, value_error := make([]ir.Node_Id, len(right), allocator)
	if value_error != nil { state.job.function.error = value_error; return }
	for target, index in left { destinations[index] = lower_destination(state, check.Expression_Ref{state.view, target}) }
	for value, index in right { values[index] = lower_value(state, value) }
	if state.failed { return }
	for destination, index in destinations { write_destination(state, destination, values[index], node) }
}
