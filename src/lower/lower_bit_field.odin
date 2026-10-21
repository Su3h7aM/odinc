package lower

import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

// A bit_field is a scalar of its backing integer. Reads shift the field to the top bits and back down,
// arithmetic for signed fields. Writes clear the field's bits and insert the masked value.
@(private)
lower_bit_field_value :: proc(state: ^Procedure_State, place: check.Place_Plan, field: types.Type_Id) -> ir.Node_Id {
	container := lower_type(state, place.path[0].type).backing
	if lower_type(state, container).kind == .Array {
		address := lower_operand_address(state, place.root)
		if place.path[0].indirect { address = lower_operand(state, place.root) }
		if state.failed { return 0 }
		return lower_bit_field_memory_read(state, address, field, place.bit_offset, place.bit_size)
	}
	container_value: ir.Node_Id
	if place.path[0].indirect {
		container_value = lower_load(state, lower_operand(state, place.root), container)
	} else {
		container_value = lower_operand(state, place.root)
	}
	if state.failed { return 0 }
	return lower_bit_field_extract(state, container_value, scalar_type(state, container), field, place.bit_offset, place.bit_size)
}

@(private)
lower_bit_field_destination :: proc(state: ^Procedure_State, place: check.Place_Plan, field: types.Type_Id) -> Assignment_Destination {
	address: ir.Node_Id
	if place.path[0].indirect {
		address = lower_operand(state, place.root)
	} else {
		address = lower_operand_address(state, place.root)
	}
	return Assignment_Destination {
		type = field,
		address = address,
		container = lower_type(state, place.path[0].type).backing,
		bit_offset = place.bit_offset,
		bit_size = place.bit_size,
	}
}

@(private)
lower_destination_read :: proc(state: ^Procedure_State, destination: Assignment_Destination) -> ir.Node_Id {
	if destination.lane_count != 0 { return lower_swizzle_read(state, destination) }
	if destination.bit_size == 0 { return lower_load(state, destination.address, destination.type) }
	if lower_type(state, destination.container).kind == .Array {
		return lower_bit_field_memory_read(state, destination.address, destination.type, destination.bit_offset, destination.bit_size)
	}
	container_value := lower_load(state, destination.address, destination.container)
	return lower_bit_field_extract(
		state,
		container_value,
		scalar_type(state, destination.container),
		destination.type,
		destination.bit_offset,
		destination.bit_size,
	)
}

@(private)
lower_bit_field_write :: proc(state: ^Procedure_State, destination: Assignment_Destination, value: ir.Node_Id) {
	if lower_type(state, destination.container).kind == .Array {
		lower_bit_field_memory_write(state, destination.address, value, destination.bit_offset, destination.bit_size)
		return
	}
	container_value := lower_load(state, destination.address, destination.container)
	updated := lower_bit_field_insert(state, container_value, value, scalar_type(state, destination.container), destination.bit_offset, destination.bit_size)
	lower_store(state, destination.address, updated, destination.container)
}

@(private)
lower_bit_field_aggregate :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Aggregate_Plan, owner: types.Type_Id) -> ir.Node_Id {
	store := check.type_store(state.job.program)
	backing := types.get(store, owner).backing
	if lower_type(state, backing).kind == .Array {
		layout := state.job.layouts[owner]
		address := ir.stack_slot(state.job.function, state.entry_control, u32(max(layout.size, 1)), u32(layout.align))
		memory := ir.add_node(
			state.job.function,
			.Mem_Set,
			.Memory,
			{
				state.builder.control,
				ir.variable_get(state.builder, ir.MEMORY_VARIABLE),
				address,
				ir.const_int(state.job.function, .I8, 0),
				ir.const_int(state.job.function, .I64, layout.size),
			},
		)
		ir.variable_set(state.builder, ir.MEMORY_VARIABLE, memory)
		for value, position in plan.values {
			index := int(plan.field_indices[position])
			field_type := types.get(store, owner).fields[index].type
			field_value: ir.Node_Id
			if position < len(plan.conversions) && plan.conversions[position] != 0 {
				field_value = lower_declared_conversion(state, node, plan.conversions[position])
			} else {
				field_value = lower_operand(state, value, field_type)
			}
			if state.failed { return 0 }
			bit_offset, bit_size := types.bit_field_slot(store, owner, index)
			lower_bit_field_memory_write(state, address, field_value, bit_offset, bit_size)
		}
		return address
	}
	scalar := scalar_type(state, backing)
	result := ir.const_int(state.job.function, scalar, 0)
	for value, position in plan.values {
		index := int(plan.field_indices[position])
		field_type := types.get(store, owner).fields[index].type
		field_value: ir.Node_Id
		if position < len(plan.conversions) && plan.conversions[position] != 0 {
			field_value = lower_declared_conversion(state, node, plan.conversions[position])
		} else {
			field_value = lower_operand(state, value, field_type)
		}
		if state.failed { return 0 }
		bit_offset, bit_size := types.bit_field_slot(store, owner, index)
		result = lower_bit_field_insert(state, result, field_value, scalar, bit_offset, bit_size)
	}
	return result
}

@(private)
lower_bit_field_extract :: proc(
	state: ^Procedure_State,
	container_value: ir.Node_Id,
	scalar: ir.Value_Type,
	field: types.Type_Id,
	bit_offset, bit_size: u32,
) -> ir.Node_Id {
	function := state.job.function
	width := i64(scalar_bits(scalar))
	signed := signed_type(state, field)
	shifted := ir.binary(function, .Shl, container_value, ir.const_int(function, scalar, width - i64(bit_offset) - i64(bit_size)))
	extracted := ir.binary(function, .Sar if signed else .Shr, shifted, ir.const_int(function, scalar, width - i64(bit_size)))
	return lower_bit_field_resize(state, extracted, scalar_type(state, field), signed)
}

@(private)
lower_bit_field_insert :: proc(state: ^Procedure_State, container_value, value: ir.Node_Id, scalar: ir.Value_Type, bit_offset, bit_size: u32) -> ir.Node_Id {
	function := state.job.function
	mask := u64(max(u64)) >> (64 - u64(bit_size))
	field := lower_bit_field_resize(state, value, scalar, false)
	field = ir.binary(function, .And, field, ir.const_int(function, scalar, i64(mask)))
	field = ir.binary(function, .Shl, field, ir.const_int(function, scalar, i64(bit_offset)))
	cleared := ir.binary(function, .And, container_value, ir.const_int(function, scalar, i64(~(mask << u64(bit_offset)))))
	return ir.binary(function, .Or, cleared, field)
}

@(private)
lower_bit_field_resize :: proc(state: ^Procedure_State, value: ir.Node_Id, to: ir.Value_Type, signed: bool) -> ir.Node_Id {
	function := state.job.function
	from := function.nodes.type[value]
	if from == to { return value }
	if to == .Bool || scalar_bits(to) < scalar_bits(from) { return ir.convert(function, .Trunc, value, to) }
	return ir.convert(function, .Sext if signed else .Zext, value, to)
}

@(private)
lower_bit_field_memory_read :: proc(state: ^Procedure_State, address: ir.Node_Id, field: types.Type_Id, bit_offset, bit_size: u32) -> ir.Node_Id {
	function := state.job.function
	first_byte := i64(bit_offset / 8)
	last_byte := i64((bit_offset + bit_size - 1) / 8)
	result := ir.const_int(function, .I64, 0)
	for byte_index in first_byte ..= last_byte {
		field_start := byte_index * 8 - i64(bit_offset)
		byte := lower_load_word(state, ir.ptr_offset(function, address, byte_index), .I8)
		wide := ir.convert(function, .Zext, byte, .I64)
		if field_start < 0 {
			wide = ir.binary(function, .Shr, wide, ir.const_int(function, .I64, -field_start))
		} else if field_start != 0 {
			wide = ir.binary(function, .Shl, wide, ir.const_int(function, .I64, field_start))
		}
		result = ir.binary(function, .Or, result, wide)
	}
	signed := signed_type(state, field)
	if bit_size < 64 {
		mask := (u64(1) << bit_size) - 1
		result = ir.binary(function, .And, result, ir.const_int(function, .I64, i64(mask)))
	}
	if signed && bit_size < 64 {
		shift := i64(64 - bit_size)
		result = ir.binary(function, .Shl, result, ir.const_int(function, .I64, shift))
		result = ir.binary(function, .Sar, result, ir.const_int(function, .I64, shift))
	}
	return lower_bit_field_resize(state, result, scalar_type(state, field), signed)
}

@(private)
lower_bit_field_memory_write :: proc(state: ^Procedure_State, address: ir.Node_Id, value: ir.Node_Id, bit_offset, bit_size: u32) {
	function := state.job.function
	wide := lower_bit_field_resize(state, value, .I64, false)
	first_byte := i64(bit_offset / 8)
	last_byte := i64((bit_offset + bit_size - 1) / 8)
	for byte_index in first_byte ..= last_byte {
		field_start := byte_index * 8 - i64(bit_offset)
		destination_start := i64(0)
		source_start := field_start
		if source_start < 0 {
			destination_start = -source_start
			source_start = 0
		}
		count := min(i64(8) - destination_start, i64(bit_size) - source_start)
		mask := (u64(1) << u64(count)) - 1
		part := wide
		if source_start != 0 { part = ir.binary(function, .Shr, part, ir.const_int(function, .I64, source_start)) }
		part = ir.binary(function, .And, part, ir.const_int(function, .I64, i64(mask)))
		if destination_start != 0 { part = ir.binary(function, .Shl, part, ir.const_int(function, .I64, destination_start)) }
		byte_mask := mask << u64(destination_start)
		part = ir.convert(function, .Trunc, part, .I8)
		byte_address := ir.ptr_offset(function, address, byte_index)
		old := lower_load_word(state, byte_address, .I8)
		cleared := ir.binary(function, .And, old, ir.const_int(function, .I8, i64(~byte_mask & 0xff)))
		updated := ir.binary(function, .Or, cleared, part)
		memory := ir.store(function, state.builder.control, ir.variable_get(state.builder, ir.MEMORY_VARIABLE), byte_address, updated, 0)
		ir.variable_set(state.builder, ir.MEMORY_VARIABLE, memory)
	}
}
