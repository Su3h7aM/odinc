package lower

import "core:mem/virtual"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

// Dynamic array and map literals allocate through the context allocator, like make does. A dynamic array literal
// reserves its element count and appends a stack-built backing store; a map literal reserves twice its entry
// count and inserts every pair. Empty literals stay zero.
@(private)
lower_dynamic_array_literal :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Dynamic_Array_Literal_Plan) -> ir.Node_Id {
	if state.failed || state.job.function.error != nil { return 0 }
	function := state.job.function
	store := check.type_store(state.job.program)
	descriptor := types.get(store, types.resolve_named(store, plan.type))
	if descriptor.kind != .Dynamic_Array && descriptor.kind != .Fixed_Capacity_Array { return lower_fail(state, node, .Expression) }
	backing_descriptor := types.get(store, plan.backing.type)
	if backing_descriptor.kind != .Array || backing_descriptor.elem != descriptor.elem { return lower_fail(state, node, .Expression) }
	layout := state.job.layouts[plan.type]
	if layout.error != .None || layout.size > i64(max(u32)) { return lower_fail(state, node, .Expression) }
	header := ir.stack_slot(function, state.entry_control, u32(max(layout.size, 1)), u32(layout.align))
	lower_zero_memory(state, header, layout.size)
	count := backing_descriptor.count
	if count == 0 { return header }
	if descriptor.kind == .Fixed_Capacity_Array {
		backing_size := state.job.layouts[plan.backing.type].size
		lower_aggregate_into(state, node, plan.backing, header, backing_size)
		if state.failed || function.error != nil { return 0 }
		length_offset := (backing_size / count * descriptor.count + 7) / 8 * 8
		lower_store_word(state, ir.ptr_offset(function, header, length_offset), ir.const_int(function, .I64, count))
		return header
	}
	element_layout := state.job.layouts[descriptor.elem]
	if element_layout.error != .None || element_layout.size < 0 || element_layout.size > i64(max(u32)) {
		return lower_fail(state, node, .Expression)
	}
	backing_layout := state.job.layouts[plan.backing.type]
	if backing_layout.error != .None || backing_layout.size > i64(max(u32)) { return lower_fail(state, node, .Expression) }
	element_size := ir.const_int(function, .I64, element_layout.size)
	element_align := ir.const_int(function, .I64, element_layout.align)
	item_count := ir.const_int(function, .I64, count)
	lower_literal_runtime_call(state, node, check.Runtime_Helper.Dynamic_Array_Reserve, {header, element_size, element_align, item_count})
	if state.failed || function.error != nil { return 0 }
	items := ir.stack_slot(function, state.entry_control, u32(max(backing_layout.size, 1)), u32(backing_layout.align))
	lower_aggregate_into(state, node, plan.backing, items, backing_layout.size)
	if state.failed || function.error != nil { return 0 }
	lower_literal_runtime_call(state, node, check.Runtime_Helper.Dynamic_Array_Append, {header, element_size, element_align, items, item_count})
	if state.failed || function.error != nil { return 0 }
	return header
}

@(private)
lower_map_literal :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Map_Literal_Plan) -> ir.Node_Id {
	if state.failed || state.job.function.error != nil { return 0 }
	function := state.job.function
	store := check.type_store(state.job.program)
	map_type := types.resolve_named(store, plan.type)
	descriptor := types.get(store, map_type)
	if descriptor.kind != .Map { return lower_fail(state, node, .Expression) }
	layout := state.job.layouts[plan.type]
	if layout.error != .None || layout.size > i64(max(u32)) { return lower_fail(state, node, .Expression) }
	header := ir.stack_slot(function, state.entry_control, u32(max(layout.size, 1)), u32(layout.align))
	lower_zero_memory(state, header, layout.size)
	if len(plan.keys) == 0 { return header }
	if len(plan.keys) != len(plan.values) { return lower_fail(state, node, .Expression) }
	map_info := lower_map_info_of(state, node, check.Map_Info_Plan{type = map_type})
	if state.failed || function.error != nil { return 0 }
	lower_literal_runtime_call(
		state,
		node,
		check.Runtime_Helper.Dynamic_Map_Reserve,
		{header, map_info, ir.const_int(function, .I64, 2 * i64(len(plan.keys)))},
	)
	if state.failed || function.error != nil { return 0 }
	key_layout := state.job.layouts[descriptor.index]
	value_layout := state.job.layouts[descriptor.elem]
	if key_layout.error != .None || value_layout.error != .None { return lower_fail(state, node, .Expression) }
	seed := lower_map_runtime_call(state, node, check.Runtime_Helper.Map_Seed, {header})
	if state.failed || function.error != nil { return 0 }
	for key, position in plan.keys {
		key_value := lower_operand(state, key, descriptor.index)
		if state.failed || function.error != nil { return 0 }
		inserted_value := lower_operand(state, plan.values[position], descriptor.elem)
		if state.failed || function.error != nil { return 0 }
		key_address := ir.stack_slot(function, state.entry_control, u32(max(key_layout.size, 1)), u32(max(key_layout.align, 1)))
		value_address := ir.stack_slot(function, state.entry_control, u32(max(value_layout.size, 1)), u32(max(value_layout.align, 1)))
		lower_store(state, key_address, key_value, descriptor.index)
		lower_store(state, value_address, inserted_value, descriptor.elem)
		if state.failed || function.error != nil { return 0 }
		key_hash := lower_map_key_hash(state, node, map_type, key_address, seed)
		if key_hash == 0 || state.failed || function.error != nil { return 0 }
		lower_map_set_call(state, node, header, map_info, key_hash, key_address, value_address)
		if state.failed || function.error != nil { return 0 }
	}
	return header
}

@(private)
lower_runtime_procedure :: proc(state: ^Procedure_State, helper: check.Runtime_Helper) -> (declaration: Procedure_Declaration, found: bool) {
	program := state.job.program
	target := program.runtime.helpers[helper]
	if target == 0 || int(target) >= len(state.job.declarations) || program.entity_symbols[target] == 0 { return {}, false }
	return state.job.declarations[target], true
}

// A call to a named runtime procedure taking scalar arguments plus a trailing caller location, for helpers the
// checker did not plan. The arguments pass positionally; a context is added for Odin-convention procedures.
@(private)
lower_literal_runtime_call :: proc(state: ^Procedure_State, node: syntax.Node_Index, helper: check.Runtime_Helper, values: []ir.Node_Id) {
	declaration, found := lower_runtime_procedure(state, helper)
	if !found {
		lower_fail(state, node, .Expression)
		return
	}
	store := check.type_store(state.job.program)
	descriptor := types.get(store, types.resolve_named(store, declaration.type))
	if descriptor.kind != .Procedure || len(descriptor.params) != len(values) + 1 || len(descriptor.results) != 1 {
		lower_fail(state, node, .Call)
		return
	}
	if scalar_type(state, descriptor.results[0]) == .None { lower_fail(state, node, .Result); return }
	location := lower_caller_location(state, node, descriptor.params[len(descriptor.params) - 1])
	if state.failed || state.job.function.error != nil { return }
	function := state.job.function
	allocator := virtual.arena_allocator(&function.arena)
	operands, operands_error := make([]ir.Node_Id, len(values) + 1, allocator)
	if operands_error != nil { function.error = operands_error; return }
	copy(operands, values)
	operands[len(values)] = location
	arguments, arguments_error := make([]ir.Node_Id, len(declaration.signature.params), allocator)
	if arguments_error != nil { function.error = arguments_error; return }
	context_count := 0
	if declaration.signature.cc == .Odin {
		context_count = 1
	} else if declaration.signature.cc != .Contextless {
		lower_fail(state, node, .Call)
		return
	}
	if len(declaration.abi_params) != len(arguments) { lower_fail(state, node, .Call_Argument); return }
	if context_count == 1 {
		arguments[len(arguments) - 1] = state.context_pointer
		if arguments[len(arguments) - 1] == 0 { arguments[len(arguments) - 1] = ir.symbol_addr(function, state.job.default_context) }
	}
	for value, index in operands {
		first := source_index(declaration.abi_params, index)
		if first < 0 { lower_fail(state, node, .Call_Argument); return }
		span := parameter_span(declaration.abi_params[first:])
		type := descriptor.params[index]
		if is_aggregate(state, type) {
			if !pass_aggregate_argument(state, value, type, declaration.abi_params[first:first + span], arguments[first:first + span]) {
				lower_fail(state, node, .Call_Argument)
				return
			}
		} else {
			if span != 1 || declaration.abi_params[first].attr != .Direct || function.nodes.type[value] != piece_type(declaration.abi_params[first].type) {
				lower_fail(state, node, .Call_Argument)
				return
			}
			arguments[first] = value
		}
	}
	for argument in arguments {
		if argument == 0 { lower_fail(state, node, .Call_Argument); return }
	}
	call_signature_id := call_signature(state, declaration)
	if function.error != nil { return }
	callee := ir.symbol_addr(function, declaration.symbol)
	call := ir.call(function, state.builder.control, ir.variable_get(state.builder, ir.MEMORY_VARIABLE), callee, call_signature_id, arguments)
	memory := ir.add_node(function, .Proj, .Memory, {call}, {index = 0})
	ir.variable_set(state.builder, ir.MEMORY_VARIABLE, memory)
	_ = ir.add_node(function, .Proj, declaration.signature.results[0].type, {call}, {index = 1})
}
