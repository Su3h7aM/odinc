package lower

import "oc:ir"
import "oc:syntax"

@(private)
lower_cstring_length :: proc(state: ^Procedure_State, node: syntax.Node_Index, value: ir.Node_Id) -> ir.Node_Id {
	function := state.job.function
	builder := state.builder
	length := ir.variable_declare(builder, ir.const_int(function, .I64, 0))
	end := ir.jump_target_make(builder)
	nil_check := ir.branch_if(builder, ir.compare(function, .Eq, value, ir.const_int(function, .Ptr, 0)))
	ir.enter_arm(builder, nil_check, 0)
	ir.jump_to(builder, end)
	ir.enter_arm(builder, nil_check, 1)
	cursor := ir.variable_declare(builder, value)
	loop := ir.loop_begin(builder, []ir.Variable{cursor, length})
	unit := ir.load(function, builder.control, ir.variable_get(builder, ir.MEMORY_VARIABLE), ir.variable_get(builder, cursor), .I8, 0)
	terminator := ir.branch_if(builder, ir.compare(function, .Eq, unit, ir.const_int(function, .I8, 0)))
	ir.enter_arm(builder, terminator, 0)
	ir.jump_to(builder, end)
	ir.enter_arm(builder, terminator, 1)
	ir.variable_set(builder, cursor, ir.ptr_offset(function, ir.variable_get(builder, cursor), 1))
	ir.variable_set(builder, length, ir.binary(function, .Add, ir.variable_get(builder, length), ir.const_int(function, .I64, 1)))
	ir.loop_end(builder, loop)
	ir.seal_target(builder, end)
	return ir.variable_get(builder, length)
}
