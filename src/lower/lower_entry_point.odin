package lower

import "oc:ir"
import "oc:syntax"

// Calls the program's entry procedure, as the official runtime's __entry_point does. A program without one
// has nothing to call, so the intrinsic emits nothing.
@(private)
lower_entry_point_call :: proc(state: ^Procedure_State, node: syntax.Node_Index) {
	entity := state.job.program.runtime.entry_point
	if entity == 0 { return }
	function := state.job.function
	declaration := state.job.declarations[entity]
	signature := declaration.signature
	if declaration.type == 0 ||
	   signature.cc != .Odin ||
	   len(signature.params) != 1 ||
	   signature.params[0].attr != .Context ||
	   len(lower_type(state, declaration.type).results) != 0 {
		lower_fail(state, node, .Startup)
		return
	}
	id := call_signature(state, declaration)
	if function.error != nil { return }
	context_pointer := state.context_pointer
	if context_pointer == 0 { context_pointer = ir.symbol_addr(function, state.job.default_context) }
	arguments := [1]ir.Node_Id{context_pointer}
	callee := ir.symbol_addr(function, declaration.symbol)
	call := ir.call(function, state.builder.control, ir.variable_get(state.builder, ir.MEMORY_VARIABLE), callee, id, arguments[:])
	ir.variable_set(state.builder, ir.MEMORY_VARIABLE, ir.add_node(function, .Proj, .Memory, {call}, {index = 0}))
}
