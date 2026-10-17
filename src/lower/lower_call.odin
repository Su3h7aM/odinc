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

// lower_call returns the single result, or 0 for void and multiple results. Multiple results
// are read through lower_call_results.
@(private)
lower_call :: proc(state: ^Procedure_State, node: syntax.Node_Index, info: check.Expression_Info, plan: check.Call_Plan) -> ir.Node_Id {
	single: [1]ir.Node_Id
	values := single[:]
	count := len(plan.results)
	if count > 1 {
		allocated, err := make([]ir.Node_Id, count, virtual.arena_allocator(&state.job.function.arena))
		if err != nil {
			state.job.function.error = err
			return 0
		}
		values = allocated
	}
	lower_call_results(state, node, info, plan, values[:count])
	if count != 1 { return 0 }
	return single[0]
}

// lower_call_results fills values with the call's results. A register-passed aggregate argument
// spans one physical argument per piece; an aggregate result comes back through a hidden pointer
// or in registers. Split results go through stack slots.
@(private)
lower_call_results :: proc(state: ^Procedure_State, node: syntax.Node_Index, info: check.Expression_Info, plan: check.Call_Plan, values: []ir.Node_Id) {
	if plan.context_plan != 0 { lower_fail(state, node, .Context); return }
	declaration, valid := call_declaration(state, node, plan)
	if !valid { return }
	signature := declaration.signature
	context_count := 0
	if signature.cc == .Odin {
		context_count = 1
	} else if signature.cc != .Contextless {
		lower_fail(state, node, .Call); return
	}
	if signature.variadic { lower_fail(state, node, .Call); return }
	descriptor := lower_type(state, declaration.type)
	result_count := len(plan.results)
	split_count := max(result_count - 1, 0)
	if len(descriptor.results) != result_count ||
	   (result_count == 0 && info.mode != .No_Value) ||
	   (result_count == 1 && info.type != plan.results[0]) { lower_fail(state, node, .Result); return }
	for result, index in plan.results {
		if result != descriptor.results[index] { lower_fail(state, node, .Result); return }
	}
	count := len(declaration.parameters)
	split_base := len(signature.params) - context_count - split_count
	if len(plan.arguments) != count || len(declaration.abi_params) != len(signature.params) || split_base < count {
		lower_fail(state, node, .Call_Argument); return
	}
	if context_count == 1 && signature.params[len(signature.params) - 1].attr != .Context { lower_fail(state, node, .Call_Argument); return }
	for index in 0 ..< split_count {
		if signature.params[split_base + index].attr != .Direct ||
		   signature.params[split_base + index].type != .Ptr { lower_fail(state, node, .Call_Argument); return }
	}
	function := state.job.function
	allocator := virtual.arena_allocator(&function.arena)
	ordered, ordered_error := make([]Call_Argument_Order, count, allocator)
	arguments, arguments_error := make([]ir.Node_Id, len(signature.params), allocator)
	slots, slots_error := make([]ir.Node_Id, split_count, allocator)
	if ordered_error != nil { function.error = ordered_error; return }
	if arguments_error != nil { function.error = arguments_error; return }
	if slots_error != nil { function.error = slots_error; return }
	struct_return := struct_return_index(declaration.abi_params)
	result_slot: ir.Node_Id
	if result_count > 0 && scalar_type(state, plan.results[result_count - 1]) == .None {
		layout := state.job.layouts[plan.results[result_count - 1]]
		if layout.error != .None { lower_fail(state, node, .Result); return }
		result_slot = ir.stack_slot(function, state.entry_control, u32(layout.size), u32(layout.align))
		if struct_return >= 0 { arguments[struct_return] = result_slot }
	}
	for index in 0 ..< split_count {
		layout := state.job.layouts[plan.results[index]]
		if layout.error != .None { lower_fail(state, node, .Result); return }
		slots[index] = ir.stack_slot(function, state.entry_control, u32(layout.size), u32(layout.align))
		arguments[split_base + index] = slots[index]
	}
	for argument, index in plan.arguments {
		if !argument.caller_location &&
		   !argument.variadic_pack &&
		   !call_operand_valid(state, argument.value) { lower_fail(state, node, .Call_Argument); return }
		position := index
		if plan.entity != 0 {
			position = -1
			for parameter, source in declaration.parameters {
				if parameter == argument.parameter { position = source; break }
			}
		}
		if position < 0 { lower_fail(state, node, .Call_Argument); return }
		for previous in ordered[:index] {
			if previous.parameter_index == position { lower_fail(state, node, .Call_Argument); return }
		}
		ordered[index] = {index, position, argument.evaluation_order}
		if argument.conversion != 0 {
			retained := check.plan(state.job.program, argument.conversion)
			if retained == nil { lower_fail(state, node, .Conversion); return }
			conversion, ok := retained^.(check.Conversion_Plan)
			if !ok ||
			   conversion.kind == .Invalid ||
			   conversion.target != descriptor.params[position] ||
			   !same_call_operand(conversion.source, argument.value) { lower_fail(state, node, .Conversion); return }
		}
	}
	slice.sort_by(ordered, proc(left, right: Call_Argument_Order) -> bool { return left.evaluation_order < right.evaluation_order })
	for entry, index in ordered {
		if index > 0 && ordered[index - 1].evaluation_order == entry.evaluation_order { lower_fail(state, node, .Call_Argument); return }
	}
	callee: ir.Node_Id
	if plan.entity == 0 {
		callee = lower_operand(state, plan.callee)
	} else {
		callee = ir.symbol_addr(function, declaration.symbol)
	}
	if state.failed || function.error != nil { return }
	last := len(arguments) - 1
	if context_count == 1 {
		arguments[last] = state.context_pointer
		if arguments[last] == 0 { arguments[last] = ir.symbol_addr(function, state.job.default_context) }
	}
	for entry in ordered {
		argument := plan.arguments[entry.argument_index]
		position := entry.parameter_index
		first := source_index(declaration.abi_params, position)
		if first < 0 { lower_fail(state, node, .Call_Argument); return }
		span := parameter_span(declaration.abi_params[first:])
		value: ir.Node_Id
		if argument.variadic_pack {
			value = lower_variadic_slice(state, node, argument, descriptor.params[position])
		} else if argument.conversion != 0 {
			value = lower_conversion(state, check.plan(state.job.program, argument.conversion)^.(check.Conversion_Plan), node)
		} else if argument.caller_location {
			value = lower_caller_location(state, node, descriptor.params[position])
		} else {
			value = lower_operand(state, argument.value, descriptor.params[position])
		}
		if state.failed || function.error != nil { return }
		if is_aggregate(state, descriptor.params[position]) {
			if !pass_aggregate_argument(state, value, descriptor.params[position], declaration.abi_params[first:first + span], arguments[first:first + span]) {
				lower_fail(state, node, .Call_Argument)
				return
			}
			continue
		}
		if span != 1 || signature.params[first].attr != .Direct { lower_fail(state, node, .Call_Argument); return }
		if function.nodes.type[value] == .Bool && signature.params[first].type == .I8 { value = ir.convert(function, .Zext, value, .I8) }
		if function.error != nil { return }
		if function.nodes.type[value] != signature.params[first].type { lower_fail(state, node, .Call_Argument); return }
		arguments[first] = value
	}
	for argument in arguments {
		if argument == 0 { lower_fail(state, node, .Call_Argument); return }
	}
	id := call_signature(state, declaration)
	if function.error != nil { return }
	call := ir.call(function, state.builder.control, ir.variable_get(state.builder, ir.MEMORY_VARIABLE), callee, id, arguments)
	memory := ir.add_node(function, .Proj, .Memory, {call}, {index = 0})
	ir.variable_set(state.builder, ir.MEMORY_VARIABLE, memory)
	if result_count == 0 { return }
	if scalar_type(state, plan.results[result_count - 1]) != .None {
		if len(signature.results) != 1 || !call_scalar_type(signature.results[0].type) { lower_fail(state, node, .Result); return }
		value := ir.add_node(function, .Proj, signature.results[0].type, {call}, {index = 1})
		if scalar_type(state, plan.results[result_count - 1]) == .Bool { value = ir.convert(function, .Trunc, value, .Bool) }
		values[result_count - 1] = value
	} else {
		values[result_count - 1] = result_slot
		if struct_return < 0 {
			layout := state.job.layouts[plan.results[result_count - 1]]
			if layout.error != .None || !results_tile(signature.results, layout.size) { lower_fail(state, node, .Result); return }
			offset := i64(0)
			for result, index in signature.results {
				piece := ir.add_node(function, .Proj, result.type, {call}, {index = u32(index + 1)})
				lower_store_word(state, ir.ptr_offset(function, result_slot, offset), piece)
				offset += i64(result.size)
			}
		}
	}
	for index in 0 ..< split_count {
		values[index] = lower_load(state, slots[index], plan.results[index])
	}
}

@(private)
pick_ordered :: proc(function: ^ir.Function, less_kind: ir.Node_Kind, left, right: ir.Node_Id, want_min: bool) -> ir.Node_Id {
	less := ir.compare(function, less_kind, left, right)
	if want_min { return ir.select(function, less, left, right) }
	return ir.select(function, less, right, left)
}

@(private)
lower_numeric_builtin :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Builtin_Plan, kind: check.Builtin_Kind) -> ir.Node_Id {
	count := len(plan.arguments)
	if count < 1 || count > 3 { return lower_fail(state, node, .Builtin) }
	values: [3]ir.Node_Id
	for argument, index in plan.arguments {
		if !call_operand_valid(state, argument) { return lower_fail(state, node, .Builtin) }
		values[index] = lower_operand(state, argument)
	}
	if state.failed || state.job.function.error != nil { return 0 }
	function := state.job.function
	type := function.nodes.type[values[0]]
	for index in 1 ..< count {
		if function.nodes.type[values[index]] != type { return lower_fail(state, node, .Builtin) }
	}
	floating := type == .F32 || type == .F64
	signed := signed_type(state, operand_type(state, plan.arguments[0]))
	less_kind := ir.Node_Kind.FLt if floating else (ir.Node_Kind.SLt if signed else ir.Node_Kind.ULt)
	#partial switch kind {
	case .Min:
		return pick_ordered(function, less_kind, values[0], values[1], true)
	case .Max:
		return pick_ordered(function, less_kind, values[0], values[1], false)
	case .Clamp:
		upper := pick_ordered(function, less_kind, values[0], values[1], false)
		return pick_ordered(function, less_kind, upper, values[2], true)
	case .Abs:
		if !floating && !signed { return values[0] }
		zero := ir.const_float(function, type, 0) if floating else ir.const_int(function, type, 0)
		negative := ir.compare(function, less_kind, values[0], zero)
		flipped := ir.unary(function, .FNeg, values[0]) if floating else ir.binary(function, .Sub, zero, values[0])
		return ir.select(function, negative, flipped, values[0])
	case:
		return lower_fail(state, node, .Builtin)
	}
}

@(private)
lower_builtin :: proc(state: ^Procedure_State, node: syntax.Node_Index, info: check.Expression_Info, plan: check.Builtin_Plan) -> ir.Node_Id {
	if kind := check.builtin_kind(state.job.program, plan.builtin); kind == .Min || kind == .Max || kind == .Abs || kind == .Clamp {
		return lower_numeric_builtin(state, node, plan, kind)
	}
	if check.builtin_kind(state.job.program, plan.builtin) == .Trap {
		if len(plan.arguments) != 0 { return lower_fail(state, node, .Builtin) }
		ir.emit_trap(state.builder)
		return 0
	}
	if check.builtin_kind(state.job.program, plan.builtin) == .Unreachable {
		if len(plan.arguments) != 0 { return lower_fail(state, node, .Builtin) }
		ir.emit_unreachable(state.builder)
		return 0
	}
	if check.builtin_kind(state.job.program, plan.builtin) == .Len { return lower_length(state, node, info, plan) }
	if value, handled := lower_simd_builtin(state, node, info, plan, check.builtin_kind(state.job.program, plan.builtin)); handled {
		return value
	}
	if kind := check.builtin_kind(state.job.program, plan.builtin); kind != .Syscall { return lower_intrinsic(state, node, info, plan, kind) }
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
