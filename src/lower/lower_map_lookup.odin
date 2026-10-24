package lower

import "core:mem/virtual"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

@(private)
Map_Operands :: struct {
	map_value, key_address: ir.Node_Id,
}

@(private)
lower_map_descriptor :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	plan: check.Map_Index_Plan,
) -> (
	map_type: types.Type_Id,
	descriptor: ^types.Type,
) {
	map_expression, is_expression := plan.map_value.(check.Expression_Ref)
	if !is_expression { lower_fail(state, node, .Expression); return 0, nil }
	store := check.type_store(state.job.program)
	map_type = types.resolve_named(store, lower_info(state, map_expression.node).type)
	descriptor = types.get(store, map_type)
	if descriptor.kind == .Pointer {
		map_type = types.resolve_named(store, descriptor.elem)
		descriptor = types.get(store, map_type)
	}
	if descriptor.kind != .Map { lower_fail(state, node, .Expression); return 0, nil }
	return map_type, descriptor
}

@(private)
lower_map_key_hash :: proc(state: ^Procedure_State, node: syntax.Node_Index, map_type: types.Type_Id, key_address, seed: ir.Node_Id) -> ir.Node_Id {
	key_hash := ir.Node_Id(0)
	for entry in check.runtime_requirements(state.job.program).map_info {
		if entry.type != map_type { continue }
		hasher := state.job.symbols[entry.key_hasher]
		hasher_type := check.symbols(state.job.program)[int(entry.key_hasher) - 1].type
		key_hash = generated_procedure_call(state, hasher, hasher_type, []ir.Node_Id{key_address, seed})
		break
	}
	if key_hash == 0 || state.failed || state.job.function.error != nil { return 0 }
	return key_hash
}

@(private)
lower_map_entry :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	plan: check.Map_Index_Plan,
	operands: ^Map_Operands = nil,
) -> (
	found_pointer, ok: ir.Node_Id,
	value_type: types.Type_Id,
) {
	map_type, map_descriptor := lower_map_descriptor(state, node, plan)
	if state.failed || state.job.function.error != nil { return }
	map_value := lower_operand(state, plan.map_value)
	key_value := lower_operand(state, plan.key, map_descriptor.index)
	if state.failed || state.job.function.error != nil { return }
	key_layout := state.job.layouts[map_descriptor.index]
	if key_layout.error != .None || key_layout.size < 0 || key_layout.size > i64(max(u32)) {
		lower_fail(state, node, .Expression)
		return
	}
	key_address := ir.stack_slot(state.job.function, state.entry_control, u32(max(key_layout.size, 1)), u32(max(key_layout.align, 1)))
	lower_store(state, key_address, key_value, map_descriptor.index)
	if state.failed || state.job.function.error != nil { return }
	if operands != nil { operands^ = {map_value, key_address} }
	seed := lower_map_runtime_call(state, node, check.Runtime_Helper.Map_Seed, []ir.Node_Id{map_value})
	map_info_value := lower_map_info_of(state, node, check.Map_Info_Plan{type = map_type})
	key_hash := lower_map_key_hash(state, node, map_type, key_address, seed)
	if key_hash == 0 || state.failed || state.job.function.error != nil { return }
	found_pointer = lower_map_runtime_call(state, node, check.Runtime_Helper.Dynamic_Map_Get, []ir.Node_Id{map_value, map_info_value, key_hash, key_address})
	if state.failed || state.job.function.error != nil { return }
	function := state.job.function
	ok = ir.compare(function, .Ne, found_pointer, ir.const_int(function, .Ptr, 0))
	return found_pointer, ok, map_descriptor.elem
}

@(private)
lower_map_index :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	plan: check.Map_Index_Plan,
	operands: ^Map_Operands = nil,
) -> (
	value, ok: ir.Node_Id,
) {
	found_pointer, found, value_type := lower_map_entry(state, node, plan, operands)
	if state.failed || state.job.function.error != nil { return }
	ok = found
	function := state.job.function
	if scalar := scalar_type(state, value_type); scalar != .None {
		zero := ir.const_int(function, scalar, 0)
		if scalar == .F32 || scalar == .F64 { zero = ir.const_float(function, scalar, 0) }
		count := len(state.builder.values)
		result := ir.variable_declare(state.builder, zero)
		end := ir.jump_target_make(state.builder)
		branch := ir.branch_if(state.builder, ok)
		ir.enter_arm(state.builder, branch, 0)
		loaded := lower_load(state, found_pointer, value_type)
		ir.variable_set(state.builder, result, loaded)
		ir.jump_to(state.builder, end)
		ir.enter_arm(state.builder, branch, 1)
		ir.jump_to(state.builder, end)
		ir.seal_target(state.builder, end)
		value = ir.variable_get(state.builder, result)
		ir.variables_truncate(state.builder, count)
		return
	}
	layout := state.job.layouts[value_type]
	if layout.error != .None || layout.size < 0 || layout.size > i64(max(u32)) {
		lower_fail(state, node, .Expression)
		return
	}
	value = ir.stack_slot(function, state.entry_control, u32(max(layout.size, 1)), u32(max(layout.align, 1)))
	lower_zero_memory(state, value, layout.size)
	end := ir.jump_target_make(state.builder)
	branch := ir.branch_if(state.builder, ok)
	ir.enter_arm(state.builder, branch, 0)
	lower_store(state, value, lower_load(state, found_pointer, value_type), value_type)
	ir.jump_to(state.builder, end)
	ir.enter_arm(state.builder, branch, 1)
	ir.jump_to(state.builder, end)
	ir.seal_target(state.builder, end)
	return
}

@(private)
lower_map_runtime_call :: proc(state: ^Procedure_State, node: syntax.Node_Index, helper: check.Runtime_Helper, arguments: []ir.Node_Id) -> ir.Node_Id {
	program := state.job.program
	entity := program.runtime.helpers[helper]
	if entity == 0 || checked_procedure_symbol(program, entity) == 0 { return lower_fail(state, node, .Expression) }
	symbol := state.job.symbols[program.entity_symbols[entity]]
	return generated_procedure_call(state, symbol, program.entities[entity].type, arguments)
}

@(private)
lower_zero_memory :: proc(state: ^Procedure_State, address: ir.Node_Id, size: i64) {
	function := state.job.function
	zero := ir.add_node(
		function,
		.Mem_Set,
		.Memory,
		{
			state.builder.control,
			ir.variable_get(state.builder, ir.MEMORY_VARIABLE),
			address,
			ir.const_int(function, .I8, 0),
			ir.const_int(function, .I64, size),
		},
	)
	ir.variable_set(state.builder, ir.MEMORY_VARIABLE, zero)
}

@(private)
lower_map_store :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Map_Index_Plan, value: ir.Node_Id, operands := Map_Operands{}) {
	map_type, map_descriptor := lower_map_descriptor(state, node, plan)
	if state.failed || state.job.function.error != nil { return }
	map_value := operands.map_value
	key_value: ir.Node_Id
	if map_value == 0 { map_value = lower_operand(state, plan.map_value) }
	if operands.key_address == 0 { key_value = lower_operand(state, plan.key, map_descriptor.index) }
	if state.failed || state.job.function.error != nil { return }
	function := state.job.function
	key_layout := state.job.layouts[map_descriptor.index]
	value_type := map_descriptor.elem
	value_layout := state.job.layouts[value_type]
	if key_layout.error != .None || value_layout.error != .None {
		lower_fail(state, node, .Expression)
		return
	}
	key_address := operands.key_address
	if key_address == 0 {
		key_address = ir.stack_slot(function, state.entry_control, u32(max(key_layout.size, 1)), u32(max(key_layout.align, 1)))
		lower_store(state, key_address, key_value, map_descriptor.index)
	}
	value_address := ir.stack_slot(function, state.entry_control, u32(max(value_layout.size, 1)), u32(max(value_layout.align, 1)))
	lower_store(state, value_address, value, value_type)
	if state.failed || function.error != nil { return }
	seed := lower_map_runtime_call(state, node, check.Runtime_Helper.Map_Seed, []ir.Node_Id{map_value})
	map_info_value := lower_map_info_of(state, node, check.Map_Info_Plan{type = map_type})
	key_hash := lower_map_key_hash(state, node, map_type, key_address, seed)
	if key_hash == 0 || state.failed || function.error != nil { return }
	lower_map_set_call(state, node, map_value, map_info_value, key_hash, key_address, value_address)
}

@(private)
lower_map_set_call :: proc(state: ^Procedure_State, node: syntax.Node_Index, map_value, map_info_value, hash, key_address, value_address: ir.Node_Id) {
	program := state.job.program
	helper := program.runtime.helpers[.Dynamic_Map_Set]
	if helper == 0 || int(helper) >= len(state.job.declarations) || checked_procedure_symbol(program, helper) == 0 {
		lower_fail(state, node, .Expression)
		return
	}
	declaration := state.job.declarations[helper]
	store := check.type_store(program)
	descriptor := types.get(store, types.resolve_named(store, declaration.type))
	if descriptor.kind != .Procedure || len(descriptor.params) != 6 || len(descriptor.results) != 2 {
		lower_fail(state, node, .Call)
		return
	}
	location := lower_caller_location(state, node, descriptor.params[5])
	if state.failed || state.job.function.error != nil { return }
	values := [6]ir.Node_Id{map_value, map_info_value, hash, key_address, value_address, location}
	function := state.job.function
	allocator := virtual.arena_allocator(&function.arena)
	arguments, allocation_error := make([]ir.Node_Id, len(declaration.signature.params), allocator)
	if allocation_error != nil { function.error = allocation_error; return }
	context_count := 0
	if declaration.signature.cc == .Odin {
		context_count = 1
	} else if declaration.signature.cc != .Contextless {
		lower_fail(state, node, .Call)
		return
	}
	split_count := len(descriptor.results) - 1
	split_base := len(declaration.signature.params) - context_count - split_count
	if split_base < len(descriptor.params) || len(declaration.abi_params) != len(arguments) {
		lower_fail(state, node, .Call_Argument)
		return
	}
	if context_count == 1 {
		arguments[len(arguments) - 1] = state.context_pointer
		if arguments[len(arguments) - 1] == 0 { arguments[len(arguments) - 1] = ir.symbol_addr(function, state.job.default_context) }
	}
	for result_index in 0 ..< split_count {
		result_type := descriptor.results[result_index]
		layout := state.job.layouts[result_type]
		if layout.error != .None { lower_fail(state, node, .Result); return }
		arguments[split_base + result_index] = ir.stack_slot(function, state.entry_control, u32(max(layout.size, 1)), u32(max(layout.align, 1)))
	}
	for value, index in values {
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
	for result, index in declaration.signature.results {
		_ = ir.add_node(function, .Proj, result.type, {call}, {index = u32(index + 1)})
	}
}
