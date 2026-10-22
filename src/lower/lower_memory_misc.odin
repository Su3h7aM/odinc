package lower

import "oc:check"
import "oc:ir"
import "oc:syntax"

@(private)
lower_memory_misc :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Builtin_Plan, kind: check.Builtin_Kind) -> (ir.Node_Id, bool) {
	if kind != .Mem_Zero_Volatile && kind != .Cpu_Relax && kind != .Debug_Trap { return 0, false }
	values, ok := lower_intrinsic_operands(state, node, plan)
	if !ok { return 0, true }
	function := state.job.function
	memory := ir.variable_get(state.builder, ir.MEMORY_VARIABLE)
	if kind == .Mem_Zero_Volatile {
		if len(plan.arguments) != 2 || function.nodes.type[values[0]] != .Ptr || !is_integer_value(function, values[1]) {
			return lower_fail(state, node, .Builtin), true
		}
		memory = ir.add_node(
			function,
			.Mem_Set,
			.Memory,
			{
				state.builder.control,
				memory,
				values[0],
				ir.const_int(function, .I8, 0),
				widen_int_count(state, values[1], operand_type(state, plan.arguments[1])),
			},
			{access = {order = .Volatile}},
		)
	} else {
		if len(plan.arguments) != 0 { return lower_fail(state, node, .Builtin), true }
		operation := ir.Target_Op.Pause if kind == .Cpu_Relax else ir.Target_Op.Debug_Trap
		effect := ir.add_node(function, .Target_Op, .Tuple, {state.builder.control, memory}, {index = u32(operation)})
		memory = ir.add_node(function, .Proj, .Memory, {effect}, {index = 0})
	}
	ir.variable_set(state.builder, ir.MEMORY_VARIABLE, memory)
	return 0, true
}
