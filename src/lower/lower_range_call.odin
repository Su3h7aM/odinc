package lower

import "core:mem/virtual"
import "oc:check"
import "oc:ir"
import "oc:syntax"

@(private)
lower_range_call :: proc(state: ^Procedure_State, node: syntax.Node_Index, parts: Range_Parts, plan: check.Range_Call_Plan) {
	scope := local_scope(state)
	defer leave_local_scope(state, scope)
	lower_statement(state, parts.init)
	if state.failed || state.job.function.error != nil || state.builder.control == 0 { return }
	variables, ok := range_loop_variables(state, parts.body)
	if !ok { return }
	end := ir.jump_target_make(state.builder)
	loop := ir.loop_begin(state.builder, variables)
	continuation := ir.jump_target_make(state.builder)
	if !push_control_target(
		state,
		{node = {state.job.procedure.body.file, node}, break_target = end, continue_target = continuation, is_loop = true},
	) { return }
	defer pop(&state.control_targets)
	previous_view := state.view
	state.view = plan.call.view
	info := lower_info(state, plan.call.node)
	call, found := check.plan(state.job.program, info.plan)^.(check.Call_Plan)
	if !found { lower_fail(state, node, .Range); return }
	results, allocation_error := make([]ir.Node_Id, len(call.results), virtual.arena_allocator(&state.job.function.arena))
	if allocation_error != nil { state.job.function.error = allocation_error; return }
	lower_call_results(state, plan.call.node, info, call, results)
	state.view = previous_view
	if state.failed || state.job.function.error != nil { return }
	branch := ir.branch_if(state.builder, results[plan.condition_index])
	ir.enter_arm(state.builder, branch, 1)
	ir.jump_to(state.builder, end)
	ir.enter_arm(state.builder, branch, 0)
	iteration_scope := local_scope(state)
	for name, index in parts.names {
		entity := range_entity(state, name)
		if state.failed { return }
		if entity != 0 { bind_local(state, entity, results[index], true) }
	}
	lower_statement(state, parts.body)
	leave_local_scope(state, iteration_scope)
	if state.failed || state.job.function.error != nil { return }
	ir.jump_to(state.builder, continuation)
	ir.seal_target(state.builder, continuation)
	ir.loop_end(state.builder, loop)
	ir.seal_target(state.builder, end)
}
