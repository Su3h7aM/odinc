package lower

import "oc:ir"
import "oc:syntax"

// `context` is the address of the current binding. An assignment rooted in it first rebinds the
// procedure to a stack copy, as official lb_push_context_onto_stack does; leave_local_scope restores the outer binding.
@(private)
rebind_context_for_assignment :: proc(state: ^Procedure_State, assignment: syntax.Assign_Stmt) {
	left := syntax.node_list(state.ast, assignment.lhs)
	if len(left) != 1 { return }
	current := left[0]
	for state.ast.nodes[current].kind == .Selector_Expr {
		current = syntax.node_payload(state.ast, current, syntax.Selector_Expr).expr
	}
	if state.ast.nodes[current].kind != .Implicit { return }
	push_context(state, current)
}

@(private)
push_context :: proc(state: ^Procedure_State, implicit: syntax.Node_Index) {
	if state.failed || state.job.function.error != nil { return }
	type := lower_info(state, implicit).type
	layout := state.job.layouts[type]
	slot := ir.stack_slot(state.job.function, state.entry_control, u32(layout.size), u32(layout.align))
	lower_store(state, slot, state.context_pointer, type)
	state.context_pointer = slot
}

// Runs the runtime's __init_context on the default context before any other startup code, so that
// contextless callers and main see a real default context.
@(private)
call_init_context :: proc(state: ^Procedure_State) {
	entity := state.job.program.runtime.init_context
	if entity == 0 { return }
	function := state.job.function
	declaration := state.job.declarations[entity]
	if declaration.type == 0 || declaration.signature.cc != .Contextless || len(declaration.signature.params) != 1 {
		lower_fail(state, state.job.procedure.body.node, .Startup)
		return
	}
	arguments := [1]ir.Node_Id{state.context_pointer}
	id := call_signature(state, declaration)
	if function.error != nil { return }
	callee := ir.symbol_addr(function, declaration.symbol)
	call := ir.call(function, state.builder.control, ir.variable_get(state.builder, ir.MEMORY_VARIABLE), callee, id, arguments[:])
	memory := ir.add_node(function, .Proj, .Memory, {call}, {index = 0})
	ir.variable_set(state.builder, ir.MEMORY_VARIABLE, memory)
}
