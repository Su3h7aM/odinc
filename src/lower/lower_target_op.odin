package lower

import "oc:ir"
import "oc:syntax"

// Emits a raw machine operation with its memory effect; `results` receive its non-memory results in order.
@(private)
lower_target_op :: proc(state: ^Procedure_State, node: syntax.Node_Index, operation: ir.Target_Op, arguments: []ir.Node_Id, results: []ir.Node_Id) -> bool {
	function := state.job.function
	info := ir.target_op_info[operation]
	if len(arguments) != int(info.arg_count) || len(results) != int(info.result_count) {
		lower_fail(state, node, .Builtin)
		return false
	}
	for argument, index in arguments {
		if function.nodes.type[argument] != info.args[index] {
			lower_fail(state, node, .Builtin)
			return false
		}
	}
	memory := ir.variable_get(state.builder, ir.MEMORY_VARIABLE)
	inputs := [4]ir.Node_Id{state.builder.control, memory, 0, 0}
	copy(inputs[2:], arguments)
	effect := ir.add_node(function, .Target_Op, .Tuple, inputs[:2 + len(arguments)], {index = u32(operation)})
	ir.variable_set(state.builder, ir.MEMORY_VARIABLE, ir.add_node(function, .Proj, .Memory, {effect}, {index = 0}))
	for &result, index in results {
		result = ir.add_node(function, .Proj, info.results[index], {effect}, {index = u32(index + 1)})
	}
	return true
}
