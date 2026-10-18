package lower

import "oc:ir"
import "oc:syntax"
import "oc:types"

@(private)
lower_cstring_to_string :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	value: ir.Node_Id,
	unit_size: i64,
	unit_type: ir.Value_Type,
	target: types.Type_Id,
) -> ir.Node_Id {
	function := state.job.function
	builder := state.builder
	layout := state.job.layouts[target]
	if layout.error != .None || layout.size < 16 { return lower_fail(state, node, .Conversion) }
	result := ir.stack_slot(function, state.entry_control, u32(layout.size), u32(layout.align))
	result_end := ir.jump_target_make(builder)
	length := ir.variable_declare(builder, ir.const_int(function, .I64, 0))
	nil_check := ir.branch_if(builder, ir.compare(function, .Eq, value, ir.const_int(function, .Ptr, 0)))
	ir.enter_arm(builder, nil_check, 0)
	lower_store_word(state, result, ir.const_int(function, .Ptr, 0))
	lower_store_word(state, ir.ptr_offset(function, result, 8), ir.const_int(function, .I64, 0))
	ir.jump_to(builder, result_end)
	ir.enter_arm(builder, nil_check, 1)
	cursor := ir.variable_declare(builder, value)
	scan_end := ir.jump_target_make(builder)
	loop := ir.loop_begin(builder, []ir.Variable{cursor, length})
	unit := ir.load(function, builder.control, ir.variable_get(builder, ir.MEMORY_VARIABLE), ir.variable_get(builder, cursor), unit_type, 0)
	terminator := ir.branch_if(builder, ir.compare(function, .Eq, unit, ir.const_int(function, unit_type, 0)))
	ir.enter_arm(builder, terminator, 0)
	ir.jump_to(builder, scan_end)
	ir.enter_arm(builder, terminator, 1)
	ir.variable_set(builder, cursor, ir.ptr_offset(function, ir.variable_get(builder, cursor), unit_size))
	ir.variable_set(builder, length, ir.binary(function, .Add, ir.variable_get(builder, length), ir.const_int(function, .I64, 1)))
	ir.loop_end(builder, loop)
	ir.seal_target(builder, scan_end)
	lower_store_word(state, result, value)
	lower_store_word(state, ir.ptr_offset(function, result, 8), ir.variable_get(builder, length))
	ir.jump_to(builder, result_end)
	ir.seal_target(builder, result_end)
	return result
}
