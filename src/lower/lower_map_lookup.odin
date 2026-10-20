package lower

import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

@(private)
lower_map_index :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Map_Index_Plan) -> (value, ok: ir.Node_Id) {
	map_expression, is_expression := plan.map_value.(check.Expression_Ref)
	if !is_expression { lower_fail(state, node, .Expression); return }
	map_info := lower_info(state, map_expression.node)
	store := check.type_store(state.job.program)
	map_type := types.resolve_named(store, map_info.type)
	map_descriptor := types.get(store, map_type)
	if map_descriptor.kind == .Pointer {
		map_type = types.resolve_named(store, map_descriptor.elem)
		map_descriptor = types.get(store, map_type)
	}
	if map_descriptor.kind != .Map { lower_fail(state, node, .Expression); return }
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
	data := lower_load_word(state, map_value, .I64)
	seed := lower_map_runtime_call(state, node, "map_seed_from_map_data", []ir.Node_Id{data})
	map_info_value := lower_map_info_of(state, node, check.Map_Info_Plan{type = map_type})
	key_hash := ir.Node_Id(0)
	for entry in check.runtime_requirements(state.job.program).map_info {
		if entry.type != map_type { continue }
		hasher := state.job.symbols[entry.key_hasher]
		hasher_type := check.symbols(state.job.program)[int(entry.key_hasher) - 1].type
		key_hash = generated_procedure_call(state, hasher, hasher_type, []ir.Node_Id{key_address, seed})
		break
	}
	if key_hash == 0 || state.failed || state.job.function.error != nil { return }
	found_pointer := lower_map_runtime_call(state, node, "__dynamic_map_get", []ir.Node_Id{map_value, map_info_value, key_hash, key_address})
	if state.failed || state.job.function.error != nil { return }
	function := state.job.function
	ok = ir.compare(function, .Ne, found_pointer, ir.const_int(function, .Ptr, 0))
	value_type := map_descriptor.elem
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
lower_map_runtime_call :: proc(state: ^Procedure_State, node: syntax.Node_Index, name: string, arguments: []ir.Node_Id) -> ir.Node_Id {
	program := state.job.program
	for entity in program.runtime.helper_entities {
		if program.entities[entity].name != name { continue }
		symbol := state.job.symbols[program.entity_symbols[entity]]
		return generated_procedure_call(state, symbol, program.entities[entity].type, arguments)
	}
	return lower_fail(state, node, .Expression)
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
