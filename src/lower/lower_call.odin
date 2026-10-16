package lower

import "core:mem/virtual"
import "core:slice"
import "oc:check"
import "oc:ir"
import "oc:syntax"

@(private)
Call_Argument_Order :: struct {
	argument_index:   int,
	parameter_index:  int,
	evaluation_order: u32,
}

@(private)
call_operand_valid :: proc(state: ^Procedure_State, operand: check.Operand) -> bool {
	program := state.job.program
	type_count := len(check.type_store(program).types)
	switch value in operand {
	case check.Expression_Ref:
		info, ok := check.expression_info(program, value.view, value.node)
		return(
			ok &&
			info.state == .Checked &&
			info.type != 0 &&
			int(info.type) < type_count &&
			program.typed_views[value.view].file == state.job.procedure.body.file &&
			int(value.node) < len(state.ast.nodes) \
		)
	case check.Entity_Id:
		return value != 0 && int(value) < len(program.entities) && program.entities[value].type != 0 && int(program.entities[value].type) < type_count
	case check.Const_Id:
		constant := check.constant(program, value)
		return constant != nil && constant.type != 0 && int(constant.type) < type_count
	case check.Projection:
		return false
	}
	return false
}

@(private)
same_call_operand :: proc(left, right: check.Operand) -> bool {
	switch value in left {
	case check.Expression_Ref:
		other, ok := right.(check.Expression_Ref)
		return ok && value == other
	case check.Entity_Id:
		other, ok := right.(check.Entity_Id)
		return ok && value == other
	case check.Const_Id:
		other, ok := right.(check.Const_Id)
		return ok && value == other
	case check.Projection:
		return false
	}
	return false
}

@(private)
direct_call_callee :: proc(state: ^Procedure_State, plan: check.Call_Plan) -> bool {
	#partial switch value in plan.callee {
	case check.Entity_Id:
		return value == plan.entity
	case check.Expression_Ref:
		if !call_operand_valid(state, value) { return false }
		info := check.expression_info(state.job.program, value.view, value.node)
		return info.entity == plan.entity && state.ast.nodes[value.node].kind == .Ident && info.plan == 0
	case:
		return false
	}
}

@(private)
lower_call :: proc(state: ^Procedure_State, node: syntax.Node_Index, info: check.Expression_Info, plan: check.Call_Plan) -> ir.Node_Id {
	if plan.context_plan != 0 { return lower_fail(state, node, .Context) }
	if plan.entity == 0 || int(plan.entity) >= len(state.job.declarations) { return lower_fail(state, node, .Call) }
	declaration := state.job.declarations[plan.entity]
	if declaration.type == 0 || !direct_call_callee(state, plan) { return lower_fail(state, node, .Call) }
	signature := declaration.signature
	if signature.cc == .Odin { return lower_fail(state, node, .Context) }
	if signature.cc != .Contextless || signature.variadic || plan.variadic { return lower_fail(state, node, .Call) }
	descriptor := lower_type(state, declaration.type)
	if len(plan.results) != len(descriptor.results) ||
	   len(plan.results) > 1 ||
	   len(signature.results) != len(plan.results) { return lower_fail(state, node, .Result) }
	for result, index in plan.results {
		if result != descriptor.results[index] ||
		   info.type != result ||
		   scalar_type(state, result) == .None ||
		   !call_scalar_type(signature.results[index].type) { return lower_fail(state, node, .Result) }
	}
	if len(plan.results) == 0 && info.mode != .No_Value { return lower_fail(state, node, .Result) }
	count := len(declaration.parameters)
	if len(plan.arguments) != count ||
	   len(signature.params) != count ||
	   len(declaration.abi_params) != count { return lower_fail(state, node, .Call_Argument) }
	for parameter, index in signature.params {
		if parameter.attr != .Direct ||
		   !call_scalar_type(parameter.type) ||
		   declaration.abi_params[index].source != i32(index) ||
		   scalar_type(state, descriptor.params[index]) == .None { return lower_fail(state, node, .Call_Argument) }
	}
	function := state.job.function
	allocator := virtual.arena_allocator(&function.arena)
	ordered, ordered_error := make([]Call_Argument_Order, count, allocator)
	arguments, arguments_error := make([]ir.Node_Id, count, allocator)
	if ordered_error != nil { function.error = ordered_error; return 0 }
	if arguments_error != nil { function.error = arguments_error; return 0 }
	for argument, index in plan.arguments {
		if !call_operand_valid(state, argument.value) { return lower_fail(state, node, .Call_Argument) }
		position := -1
		for parameter, source in declaration.parameters {
			if parameter == argument.parameter { position = source; break }
		}
		if position < 0 { return lower_fail(state, node, .Call_Argument) }
		for previous in ordered[:index] {
			if previous.parameter_index == position { return lower_fail(state, node, .Call_Argument) }
		}
		ordered[index] = {index, position, argument.evaluation_order}
		if argument.conversion != 0 {
			retained := check.plan(state.job.program, argument.conversion)
			if retained == nil { return lower_fail(state, node, .Conversion) }
			conversion, ok := retained^.(check.Conversion_Plan)
			if !ok ||
			   conversion.kind == .Invalid ||
			   conversion.target != descriptor.params[position] ||
			   !same_call_operand(conversion.source, argument.value) { return lower_fail(state, node, .Conversion) }
		}
	}
	slice.sort_by(ordered, proc(left, right: Call_Argument_Order) -> bool { return left.evaluation_order < right.evaluation_order })
	for entry, index in ordered {
		if index > 0 && ordered[index - 1].evaluation_order == entry.evaluation_order { return lower_fail(state, node, .Call_Argument) }
	}
	callee := ir.symbol_addr(function, declaration.symbol)
	for entry in ordered {
		argument := plan.arguments[entry.argument_index]
		position := entry.parameter_index
		value: ir.Node_Id
		if argument.conversion != 0 {
			value = lower_conversion(state, check.plan(state.job.program, argument.conversion)^.(check.Conversion_Plan), node)
		} else {
			value = lower_operand(state, argument.value)
		}
		if state.failed || function.error != nil { return 0 }
		if function.nodes.type[value] == .Bool && signature.params[position].type == .I8 { value = ir.convert(function, .Zext, value, .I8) }
		if function.error != nil { return 0 }
		if function.nodes.type[value] != signature.params[position].type { return lower_fail(state, node, .Call_Argument) }
		arguments[position] = value
	}
	id := call_signature(state, declaration)
	if function.error != nil { return 0 }
	call := ir.call(function, state.builder.control, ir.variable_get(state.builder, ir.MEMORY_VARIABLE), callee, id, arguments)
	memory := ir.add_node(function, .Proj, .Memory, {call}, {index = 0})
	ir.variable_set(state.builder, ir.MEMORY_VARIABLE, memory)
	if len(signature.results) == 0 { return 0 }
	value := ir.add_node(function, .Proj, signature.results[0].type, {call}, {index = 1})
	if scalar_type(state, plan.results[0]) == .Bool { return ir.convert(function, .Trunc, value, .Bool) }
	return value
}

@(private)
lower_builtin :: proc(state: ^Procedure_State, node: syntax.Node_Index, info: check.Expression_Info, plan: check.Builtin_Plan) -> ir.Node_Id {
	if check.builtin_kind(state.job.program, plan.builtin) == .Len { return lower_length(state, node, info, plan) }
	if check.builtin_kind(state.job.program, plan.builtin) != .Syscall || len(plan.helpers) != 0 { return lower_fail(state, node, .Builtin) }
	if info.type == 0 ||
	   scalar_type(state, info.type) != .I64 ||
	   len(plan.arguments) < 1 ||
	   len(plan.arguments) > 7 { return lower_fail(state, node, .Syscall) }
	function := state.job.function
	inputs: [9]ir.Node_Id
	for operand, index in plan.arguments {
		if !call_operand_valid(state, operand) { return lower_fail(state, node, .Syscall) }
		value := lower_operand(state, operand)
		if state.failed || function.error != nil { return 0 }
		if function.nodes.type[value] != .I64 { return lower_fail(state, node, .Syscall) }
		inputs[index + 2] = value
	}
	inputs[0] = state.builder.control
	inputs[1] = ir.variable_get(state.builder, ir.MEMORY_VARIABLE)
	call := ir.add_node(function, .Syscall, .Tuple, inputs[:len(plan.arguments) + 2])
	memory := ir.add_node(function, .Proj, .Memory, {call}, {index = 0})
	ir.variable_set(state.builder, ir.MEMORY_VARIABLE, memory)
	return ir.add_node(function, .Proj, .I64, {call}, {index = 1})
}
