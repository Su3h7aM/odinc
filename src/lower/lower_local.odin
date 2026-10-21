package lower

import "base:runtime"
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
Address_Scan :: struct {
	program:       ^check.Checked_Program,
	address_taken: []bool,
}

@(private)
view_ast :: proc(program: ^check.Checked_Program, view: check.View_Id) -> ^syntax.Ast {
	return check.sources(program)[int(program.typed_views[view].file) - 1].ast
}

@(private)
mark_address_taken :: proc(scan: ^Address_Scan, operand: check.Operand) {
	#partial switch value in operand {
	case check.Entity_Id:
		scan.address_taken[value] = true
	case check.Expression_Ref:
		info, ok := check.expression_info(scan.program, value.view, value.node)
		assert(ok)
		if info.entity != 0 { scan.address_taken[info.entity] = true; return }
		ast := view_ast(scan.program, value.view)
		#partial switch ast.nodes[value.node].kind {
		case .Paren_Expr:
			mark_address_taken(scan, check.Expression_Ref{value.view, ast.nodes[value.node].payload.(syntax.Paren_Expr).expr})
		case .Selector_Expr:
			mark_address_taken(scan, check.Expression_Ref{value.view, ast.nodes[value.node].payload.(syntax.Selector_Expr).expr})
		case .Index_Expr:
			mark_address_taken(scan, check.Expression_Ref{value.view, ast.nodes[value.node].payload.(syntax.Index_Expr).expr})
		}
	case check.Projection:
		mark_address_taken(scan, value.expression)
	case:
	}
}

@(private)
scan_view_addresses :: proc(scan: ^Address_Scan, view: check.View_Id) {
	typed := &scan.program.typed_views[view]
	if typed.file == 0 { return }
	ast := view_ast(scan.program, view)
	for status, index in typed.nodes.states {
		if status != .Checked { continue }
		node := typed.first_node + syntax.Node_Index(index)
		assert(int(node) < len(ast.nodes))
		ast_node := ast.nodes[node]
		#partial switch ast_node.kind {
		case .Unary_Expr:
			unary := ast_node.payload.(syntax.Unary_Expr)
			if unary.op.kind == .And { mark_address_taken(scan, check.Expression_Ref{view, unary.expr}) }
		case .Slice_Expr:
			mark_address_taken(scan, check.Expression_Ref{view, ast_node.payload.(syntax.Slice_Expr).expr})
		}
		if typed.nodes.plans[index] == 0 { continue }
		plan := check.plan(scan.program, typed.nodes.plans[index])
		if plan == nil && (ast_node.kind == .Call_Expr || ast_node.kind == .Selector_Call_Expr) { continue }
		assert(plan != nil)
		#partial switch value in plan^ {
		case check.Conversion_Plan:
			if value.kind == .Box { mark_address_taken(scan, value.source) }
		case check.Place_Plan:
			if value.bit_size != 0 && !value.path[0].indirect { mark_address_taken(scan, value.root) }
		case check.Call_Plan:
			for argument in value.arguments {
				if argument.parameter == 0 || int(argument.parameter) >= len(scan.program.entities) { continue }
				parameter := &scan.program.entities[argument.parameter]
				if .By_Pointer in parameter.flags { mark_address_taken(scan, argument.value) }
			}
		case:
		}
	}
}

@(private)
scan_address_taken :: proc(program: ^check.Checked_Program, allocator: runtime.Allocator) -> (address_taken: []bool, err: runtime.Allocator_Error) {
	address_taken = make([]bool, len(program.entities), allocator) or_return
	scan := Address_Scan {
		program       = program,
		address_taken = address_taken,
	}
	for view in 1 ..< len(program.typed_views) { scan_view_addresses(&scan, check.View_Id(view)) }
	return address_taken, nil
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
			if !initialize { initial = ir.undef(state.job.function, scalar) } else if scalar == .F32 || scalar == .F64 { initial = ir.const_float(state.job.function, scalar, 0) } else { initial = ir.const_int(state.job.function, scalar, 0) }
		}
		state.locals[entity] = {
			kind     = .Variable,
			variable = ir.variable_declare(state.builder, initial),
		}
		return
	}
	layout := state.job.layouts[type]
	assert(layout.error == .None && layout.size >= 0 && layout.size <= i64(max(u32)))
	address := ir.stack_slot(state.job.function, state.entry_control, u32(max(layout.size, 1)), u32(layout.align))
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
	if len(values) == 1 && len(names) > 1 {
		lower_multi_declaration(state, node, names, values[0])
		return
	}
	if len(values) != 0 && len(values) != len(names) { lower_fail(state, node, .Local); return }
	allocator := virtual.arena_allocator(&state.job.function.arena)
	initials, err := make([]ir.Node_Id, len(names), allocator)
	if err != nil { state.job.function.error = err; return }
	conversions: []check.Plan_Id
	initializes: []bool
	if declared, declared_found := check.expression_info(state.job.program, state.view, node); declared_found && declared.plan != 0 {
		plan := check.plan(state.job.program, declared.plan)
		if plan == nil { lower_fail(state, node, .Local); return }
		assignment, found := plan^.(check.Assignment_Plan)
		if !found { lower_fail(state, node, .Local); return }
		conversions = assignment.conversions
		initializes = assignment.initializes
	}
	for value, index in values {
		initialize_value := len(initializes) == 0 || initializes[index]
		if !initialize_value {
			continue
		} else if index < len(conversions) && conversions[index] != 0 {
			initials[index] = lower_declared_conversion(state, value, conversions[index])
		} else {
			initials[index] = lower_value(state, value)
		}
	}
	if state.failed { return }
	for name, index in names {
		info := lower_info(state, name)
		if info.entity == 0 { continue }
		initialize := len(values) == 0 || len(initializes) == 0 || initializes[index]
		bind_local(state, info.entity, initials[index], initialize)
	}
}

@(private)
lower_declared_conversion :: proc(state: ^Procedure_State, value: syntax.Node_Index, plan_id: check.Plan_Id) -> ir.Node_Id {
	plan := check.plan(state.job.program, plan_id)
	if plan == nil { lower_fail(state, value, .Conversion); return 0 }
	converted, found := plan^.(check.Conversion_Plan)
	if !found { lower_fail(state, value, .Conversion); return 0 }
	return lower_conversion(state, converted, value)
}

@(private)
lower_multi_declaration :: proc(state: ^Procedure_State, node: syntax.Node_Index, names: []syntax.Node_Index, value: syntax.Node_Index) {
	info := lower_info(state, value)
	if info.plan == 0 { lower_fail(state, node, .Local); return }
	plan := check.plan(state.job.program, info.plan)
	if plan == nil { lower_fail(state, node, .Local); return }
	allocator := virtual.arena_allocator(&state.job.function.arena)
	results, err := make([]ir.Node_Id, len(names), allocator)
	if err != nil { state.job.function.error = err; return }
	#partial switch variant in plan^ {
	case check.Call_Plan:
		if len(variant.results) != len(names) { lower_fail(state, node, .Local); return }
		lower_call_results(state, value, info, variant, results)
	case check.Builtin_Plan:
		if len(variant.results) != len(names) { lower_fail(state, node, .Local); return }
		lower_intrinsic_tuple(state, value, variant, state.job.program.builtin_kinds[variant.builtin], results)
	case check.Type_Assertion_Plan:
		if len(names) != 2 || !variant.comma_ok { lower_fail(state, node, .Local); return }
		asserted, ok := lower_type_assertion(state, value, variant)
		results[0] = asserted
		results[1] = ok
	case check.Map_Index_Plan:
		if len(names) != 2 || !variant.comma_ok { lower_fail(state, node, .Local); return }
		indexed, ok := lower_map_index(state, value, variant)
		results[0] = indexed
		results[1] = ok
	case check.Propagation_Plan:
		if state.ast.nodes[value].kind == .Or_Branch_Expr {
			if !lower_or_branch_values(state, value, variant, results) { return }
		} else if state.ast.nodes[value].kind == .Or_Return_Expr {
			if !lower_or_return_values(state, value, variant, results) { return }
		} else {
			lower_fail(state, node, .Local)
			return
		}
	case:
		lower_fail(state, node, .Local)
		return
	}
	if state.failed || state.job.function.error != nil { return }
	for name, index in names {
		entity := lower_info(state, name).entity
		if entity == 0 { continue }
		bind_local(state, entity, results[index], true)
	}
}

@(private)
Assignment_Destination :: struct {
	lanes:                [4]ir.Node_Id,
	lane_count:           u8,
	entity:               check.Entity_Id,
	type:                 types.Type_Id,
	address:              ir.Node_Id,
	container:            types.Type_Id,
	bit_offset, bit_size: u32,
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
		if info.plan != 0 {
			plan := check.plan(state.job.program, info.plan)
			if swizzle, is_swizzle := plan^.(check.Swizzle_Plan); is_swizzle { return lower_swizzle_destination(state, swizzle, info.type) }
			if place, is_place := plan^.(check.Place_Plan); is_place && place.bit_size != 0 { return lower_bit_field_destination(state, place, info.type) }
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
	if destination.lane_count != 0 { lower_swizzle_write(state, destination, value); return }
	if destination.bit_size != 0 {
		lower_bit_field_write(state, destination, value)
		return
	}
	if destination.entity !=
	   0 { ir.variable_set(state.builder, state.locals[destination.entity].variable, value) } else { lower_store(state, destination.address, value, destination.type) }
}

@(private)
lower_assignment_plan :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Assignment_Plan) {
	if len(plan.destinations) != len(plan.values) { lower_fail(state, node, .Local); return }
	assert(len(plan.conversions) == 0 || len(plan.conversions) == len(plan.values))
	if len(plan.destinations) == 1 {
		if destination, is_expression := plan.destinations[0].(check.Expression_Ref); is_expression {
			info := check.expression_info(state.job.program, destination.view, destination.node)
			if info.mode == .Map_Index && info.plan != 0 {
				retained := check.plan(state.job.program, info.plan)
				assert(retained != nil)
				if map_index, is_map_index := retained^.(check.Map_Index_Plan); is_map_index {
					value: ir.Node_Id
					if len(plan.conversions) != 0 && plan.conversions[0] != 0 {
						conversion := check.plan(state.job.program, plan.conversions[0])
						assert(conversion != nil)
						if converted, is_conversion := conversion^.(check.Conversion_Plan); is_conversion {
							value = lower_conversion(state, converted, node)
						} else {
							lower_fail(state, node, .Conversion)
							return
						}
					} else {
						value = lower_operand(state, plan.values[0], info.type)
					}
					if state.failed || state.job.function.error != nil { return }
					lower_map_store(state, node, map_index, value)
					return
				}
			}
		}
	}
	if lower_soa_assignment_plan(state, node, plan) { return }
	allocator := virtual.arena_allocator(&state.job.function.arena)
	destinations, err := make([]Assignment_Destination, len(plan.destinations), allocator)
	if err != nil { state.job.function.error = err; return }
	values, value_error := make([]ir.Node_Id, len(plan.values), allocator)
	if value_error != nil { state.job.function.error = value_error; return }
	for destination, index in plan.destinations { destinations[index] = lower_destination(state, destination) }
	projected_until := 0
	for value, index in plan.values {
		if index < projected_until { continue }
		if projection, projected := value.(check.Projection); projected {
			projected_until = lower_assignment_results(state, node, plan, projection, index, values)
			if state.failed || state.job.function.error != nil { return }
			continue
		}
		if len(plan.conversions) != 0 && plan.conversions[index] != 0 {
			conversion := check.plan(state.job.program, plan.conversions[index])
			assert(conversion != nil)
			if converted, ok := conversion^.(check.Conversion_Plan);
			   ok { values[index] = lower_conversion(state, converted, node) } else { lower_fail(state, node, .Conversion); return }
		} else {
			values[index] = lower_operand(state, value, destinations[index].type)
			if !state.failed && destinations[index].type != 0 && scalar_type(state, destinations[index].type) == .None {
				values[index] = lower_same_layout_conversion(
					state,
					node,
					check.Conversion_Plan{target = destinations[index].type},
					destinations[index].type,
					values[index],
				)
			}
		}
	}
	if state.failed { return }
	for destination, index in destinations { write_destination(state, destination, values[index], node) }
}

@(private)
lower_local_assignment :: proc(state: ^Procedure_State, node: syntax.Node_Index, assignment: syntax.Assign_Stmt) {
	rebind_context_for_assignment(state, assignment)
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
