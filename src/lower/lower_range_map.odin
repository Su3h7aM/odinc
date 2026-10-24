package lower

import "core:mem/virtual"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

@(private)
lower_range_map :: proc(state: ^Procedure_State, node: syntax.Node_Index, parts: Range_Parts) {
	if parts.reverse { lower_fail(state, node, .Range); return }
	scope := local_scope(state)
	defer leave_local_scope(state, scope)
	lower_statement(state, parts.init)
	if state.failed || state.job.function.error != nil || state.builder.control == 0 { return }
	info := lower_info(state, parts.expr)
	store := check.type_store(state.job.program)
	map_type := types.resolve_named(store, info.type)
	map_descriptor := types.get(store, map_type)
	if map_descriptor.kind == .Pointer {
		map_type = types.resolve_named(store, map_descriptor.elem)
		map_descriptor = types.get(store, map_type)
	}
	if map_descriptor.kind != .Map { lower_fail(state, node, .Range); return }
	map_value := lower_operand(state, check.Expression_Ref{state.view, parts.expr})
	if state.failed || state.job.function.error != nil { return }
	map_info := lower_map_info_of(state, node, check.Map_Info_Plan{type = map_type})
	capacity := lower_map_runtime_call(state, node, check.Runtime_Helper.Map_Cap, []ir.Node_Id{map_value})
	keys, values, hashes, data_ok := lower_map_range_data(state, node, map_value, map_info)
	if !data_ok || state.failed || state.job.function.error != nil { return }
	key_info := lower_map_range_cell_info(state, node, map_descriptor.index)
	value_info := lower_map_range_cell_info(state, node, map_descriptor.elem)
	if key_info == 0 || value_info == 0 { return }
	hash_entity := lower_map_range_helper(state, check.Runtime_Helper.Map_Hash_Is_Valid)
	if hash_entity == 0 { lower_fail(state, node, .Range); return }
	hash_type := types.get(store, types.resolve_named(store, state.job.program.entities[hash_entity].type)).params[0]
	hash_layout := state.job.layouts[hash_type]
	hash_value_type := scalar_type(state, hash_type)
	if hash_layout.error != .None || hash_layout.size <= 0 || hash_value_type == .None {
		lower_fail(state, node, .Range)
		return
	}
	function := state.job.function
	counter := ir.variable_declare(state.builder, ir.const_int(function, .I64, 0))
	variables, variables_ok := range_loop_variables(state, parts.body, counter)
	if !variables_ok { return }
	end := ir.jump_target_make(state.builder)
	loop := ir.loop_begin(state.builder, variables)
	continuation := ir.jump_target_make(state.builder)
	if !push_control_target(
		state,
		{node = {state.job.procedure.body.file, node}, break_target = end, continue_target = continuation, is_loop = true},
	) { return }
	defer pop(&state.control_targets)
	current := ir.variable_get(state.builder, counter)
	in_bounds := ir.compare(function, .ULt, current, capacity)
	bounds_branch := ir.branch_if(state.builder, in_bounds)
	ir.enter_arm(state.builder, bounds_branch, 1)
	ir.jump_to(state.builder, end)
	ir.enter_arm(state.builder, bounds_branch, 0)
	hash_address := ir.ptr_index(function, hashes, current, u32(hash_layout.size))
	hash := lower_load_word(state, hash_address, hash_value_type)
	valid := lower_map_runtime_call(state, node, check.Runtime_Helper.Map_Hash_Is_Valid, []ir.Node_Id{hash})
	if state.failed || function.error != nil { return }
	valid_branch := ir.branch_if(state.builder, valid)
	ir.enter_arm(state.builder, valid_branch, 1)
	ir.jump_to(state.builder, continuation)
	ir.enter_arm(state.builder, valid_branch, 0)
	key_raw := lower_map_runtime_call(state, node, check.Runtime_Helper.Map_Cell_Index_Dynamic, []ir.Node_Id{keys, key_info, current})
	value_raw := lower_map_runtime_call(state, node, check.Runtime_Helper.Map_Cell_Index_Dynamic, []ir.Node_Id{values, value_info, current})
	if state.failed || function.error != nil { return }
	key_address := ir.convert(function, .Bitcast, key_raw, .Ptr)
	value_address := ir.convert(function, .Bitcast, value_raw, .Ptr)
	key_value := lower_load(state, key_address, map_descriptor.index)
	map_element := lower_load(state, value_address, map_descriptor.elem)
	lower_map_range_iteration(state, parts, key_value, key_address, map_element, value_address)
	if state.failed || function.error != nil { return }
	ir.jump_to(state.builder, continuation)
	if ir.seal_target(state.builder, continuation) {
		next := ir.binary(function, .Add, ir.variable_get(state.builder, counter), ir.const_int(function, .I64, 1))
		ir.variable_set(state.builder, counter, next)
	}
	ir.loop_end(state.builder, loop)
	ir.seal_target(state.builder, end)
}

@(private)
lower_map_range_iteration :: proc(state: ^Procedure_State, parts: Range_Parts, key, key_address, value, value_address: ir.Node_Id) {
	scope := local_scope(state)
	defer leave_local_scope(state, scope)
	for name, position in parts.names {
		entity := range_entity(state, name)
		if state.failed { return }
		if entity == 0 { continue }
		_, by_reference := range_name_node(state, name)
		if by_reference {
			bind_reference_local(state, entity, value_address)
		} else if position == 0 {
			bind_local(state, entity, key, true)
		} else {
			bind_local(state, entity, value, true)
		}
	}
	lower_statement(state, parts.body)
}

@(private)
lower_map_range_cell_info :: proc(state: ^Procedure_State, node: syntax.Node_Index, type: types.Type_Id) -> ir.Node_Id {
	for entry in check.runtime_requirements(state.job.program).map_cell_info {
		if entry.type == type { return ir.symbol_addr(state.job.function, state.job.symbols[entry.symbol]) }
	}
	return lower_fail(state, node, .Range)
}

@(private)
lower_map_range_helper :: proc(state: ^Procedure_State, helper: check.Runtime_Helper) -> check.Entity_Id {
	return state.job.program.runtime.helpers[helper]
}

@(private)
lower_map_range_data :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	map_value, map_info: ir.Node_Id,
) -> (
	keys, values, hashes: ir.Node_Id,
	ok: bool,
) {
	helper := lower_map_range_helper(state, check.Runtime_Helper.Map_Kvh_Data_Dynamic)
	if helper == 0 || int(helper) >= len(state.job.declarations) || checked_procedure_symbol(state.job.program, helper) == 0 {
		lower_fail(state, node, .Range)
		return
	}
	declaration := state.job.declarations[helper]
	store := check.type_store(state.job.program)
	descriptor := types.get(store, types.resolve_named(store, declaration.type))
	if descriptor.kind != .Procedure || len(descriptor.params) != 2 || len(descriptor.results) != 5 || declaration.signature.cc != .Contextless {
		lower_fail(state, node, .Range)
		return
	}
	function := state.job.function
	allocator := virtual.arena_allocator(&function.arena)
	arguments, allocation_error := make([]ir.Node_Id, len(declaration.signature.params), allocator)
	if allocation_error != nil { function.error = allocation_error; return }
	split_count := len(descriptor.results) - 1
	split_base := len(declaration.signature.params) - split_count
	if split_base < len(descriptor.params) || len(declaration.abi_params) != len(arguments) || len(declaration.signature.results) != 1 {
		lower_fail(state, node, .Range)
		return
	}
	slots: [4]ir.Node_Id
	for index in 0 ..< split_count {
		layout := state.job.layouts[descriptor.results[index]]
		if layout.error != .None {
			lower_fail(state, node, .Range)
			return
		}
		slots[index] = ir.stack_slot(function, state.entry_control, u32(max(layout.size, 1)), u32(max(layout.align, 1)))
		arguments[split_base + index] = slots[index]
	}
	inputs := [2]ir.Node_Id{map_value, map_info}
	for input, index in inputs {
		first := source_index(declaration.abi_params, index)
		if first < 0 {
			lower_fail(state, node, .Range)
			return
		}
		span := parameter_span(declaration.abi_params[first:])
		type := descriptor.params[index]
		if is_aggregate(state, type) {
			if !pass_aggregate_argument(state, input, type, declaration.abi_params[first:first + span], arguments[first:first + span]) {
				lower_fail(state, node, .Range)
				return
			}
		} else {
			if span != 1 || declaration.abi_params[first].attr != .Direct || function.nodes.type[input] != piece_type(declaration.abi_params[first].type) {
				lower_fail(state, node, .Range)
				return
			}
			arguments[first] = input
		}
	}
	for argument in arguments {
		if argument == 0 {
			lower_fail(state, node, .Range)
			return
		}
	}
	signature := call_signature(state, declaration)
	if function.error != nil { return }
	callee := ir.symbol_addr(function, declaration.symbol)
	call := ir.call(function, state.builder.control, ir.variable_get(state.builder, ir.MEMORY_VARIABLE), callee, signature, arguments)
	memory := ir.add_node(function, .Proj, .Memory, {call}, {index = 0})
	ir.variable_set(state.builder, ir.MEMORY_VARIABLE, memory)
	for result, index in declaration.signature.results {
		_ = ir.add_node(function, .Proj, result.type, {call}, {index = u32(index + 1)})
	}
	keys = lower_load(state, slots[0], descriptor.results[0])
	values = lower_load(state, slots[1], descriptor.results[1])
	hashes = lower_load(state, slots[2], descriptor.results[2])
	return keys, values, hashes, !state.failed && function.error == nil
}
