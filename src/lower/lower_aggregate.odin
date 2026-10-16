package lower

import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

// A literal lives in its own stack slot; the value is that slot's address, as for every aggregate.
@(private)
lower_aggregate :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Aggregate_Plan) -> ir.Node_Id {
	if state.failed || state.job.function.error != nil { return 0 }
	store := check.type_store(state.job.program)
	owner := types.resolve_named(store, plan.type)
	layout := state.job.layouts[plan.type]
	if layout.error != .None || layout.size > i64(max(u32)) || len(plan.field_indices) != len(plan.values) { return lower_fail(state, node, .Expression) }
	function := state.job.function
	address := ir.stack_slot(function, state.entry_control, u32(layout.size), u32(layout.align))
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
	for value, position in plan.values {
		index := int(plan.field_indices[position])
		field_type := types.get(store, owner).fields[index].type
		offset, offset_error := types.field_offset(store, owner, index)
		if offset_error != .None { return lower_fail(state, node, .Expression) }
		field_value := lower_operand(state, value, field_type)
		if state.failed { return 0 }
		lower_store(state, ir.ptr_offset(function, address, offset), field_value, field_type)
		if state.failed { return 0 }
	}
	return address
}
