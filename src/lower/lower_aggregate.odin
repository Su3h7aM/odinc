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
	if types.get(store, owner).kind == .Bit_Field { return lower_bit_field_aggregate(state, node, plan, owner) }
	layout := state.job.layouts[plan.type]
	if layout.error != .None || layout.size > i64(max(u32)) || len(plan.field_indices) != len(plan.values) { return lower_fail(state, node, .Expression) }
	address := ir.stack_slot(state.job.function, state.entry_control, u32(max(layout.size, 1)), u32(layout.align))
	return lower_aggregate_into(state, node, plan, address, layout.size)
}

// Fills the size bytes at address with the plan's values, zeroing the rest first.
@(private)
lower_aggregate_into :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Aggregate_Plan, address: ir.Node_Id, size: i64) -> ir.Node_Id {
	if state.failed || state.job.function.error != nil { return 0 }
	store := check.type_store(state.job.program)
	owner := types.resolve_named(store, plan.type)
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
			ir.const_int(function, .I64, size),
		},
	)
	ir.variable_set(state.builder, ir.MEMORY_VARIABLE, memory)
	for value, position in plan.values {
		index := int(plan.field_indices[position])
		descriptor := types.get(store, owner)
		field_type := descriptor.elem
		offset: i64
		if descriptor.kind == .Array || descriptor.kind == .Enumerated_Array || descriptor.kind == .Simd_Vector || descriptor.kind == .Matrix {
			element_layout := state.job.layouts[field_type]
			if element_layout.error != .None { return lower_fail(state, node, .Expression) }
			offset = i64(index) * element_layout.size
		} else {
			found: bool
			field_type, found = types.field_type(store, owner, index)
			if !found { return lower_fail(state, node, .Expression) }
			field_offset, offset_error := types.field_offset(store, owner, index)
			if offset_error != .None { return lower_fail(state, node, .Expression) }
			offset = field_offset
		}
		field_value: ir.Node_Id
		if position < len(plan.conversions) && plan.conversions[position] != 0 {
			field_value = lower_declared_conversion(state, node, plan.conversions[position])
		} else {
			field_value = lower_operand(state, value, field_type)
		}
		if state.failed { return 0 }
		lower_store(state, ir.ptr_offset(function, address, offset), field_value, field_type)
		if state.failed { return 0 }
	}
	return address
}
