package lower

import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

// The whole-element Soa_Plan behind `soa[i]` when a by-reference loop ranges
// over its lanes. Only the reference form routes here; the by-value form
// keeps the generic container path.
@(private)
lower_soa_element_plan :: proc(state: ^Procedure_State, node: syntax.Node_Index) -> (plan: check.Soa_Plan, ok: bool) {
	info := lower_info(state, node)
	if state.failed || info.plan == 0 { return {}, false }
	element, is_soa := check.plan(state.job.program, info.plan)^.(check.Soa_Plan)
	if !is_soa || element.field != nil { return {}, false }
	store := check.type_store(state.job.program)
	elem := types.get(store, types.resolve_named(store, types.get(store, element.soa).soa_elem))
	if elem.kind != .Array { return {}, false }
	return element, true
}

// `for &v[, j] in soa[i]`: the element index is bounds-checked once then a
// counter walks the lanes, addressing each through the element's Soa_Plan,
// as the official lb_build_range_indexed does for its soa_elem case. The
// value and index names bind like any other reference loop.
@(private)
lower_range_soa_element :: proc(state: ^Procedure_State, node: syntax.Node_Index, parts: Range_Parts, plan: check.Soa_Plan) {
	scope := local_scope(state)
	defer leave_local_scope(state, scope)
	lower_statement(state, parts.init)
	if state.failed || state.job.function.error != nil || state.builder.control == 0 { return }
	function := state.job.function
	store := check.type_store(state.job.program)
	descriptor := types.get(store, types.resolve_named(store, plan.soa))
	core := types.get(store, types.core_type(store, descriptor.soa_elem))
	address := lower_soa_container_address(state, plan.container)
	if state.failed || function.error != nil { return }
	element := lower_soa_index_value(state, node, plan)
	if state.failed || function.error != nil { return }
	if plan.policy != .Disabled {
		length := lower_soa_length(state, node, plan.soa, address)
		if state.failed || function.error != nil { return }
		lower_check(state, ir.compare(function, .ULt, element, length))
		if state.failed || function.error != nil { return }
	}
	count := ir.const_int(function, .I64, core.count)
	counter := ir.variable_declare(state.builder, ir.const_int(function, .I64, 0))
	variables, variables_ok := range_loop_variables(state, parts.body, counter)
	if !variables_ok { return }
	end := ir.jump_target_make(state.builder)
	loop := ir.loop_begin(state.builder, variables)
	continuation := ir.jump_target_make(state.builder)
	if !push_control_target(
		state,
		{node = {state.job.procedure.body.file, node}, break_target = end, continue_target = continuation, is_loop = true},
	) { return }
	defer pop(&state.control_targets)
	current := ir.variable_get(state.builder, counter)
	branch := ir.branch_if(state.builder, ir.compare(function, .ULt, current, count))
	ir.enter_arm(state.builder, branch, 1)
	ir.jump_to(state.builder, end)
	ir.enter_arm(state.builder, branch, 0)
	position := current
	if parts.reverse {
		last := ir.binary(function, .Sub, count, ir.const_int(function, .I64, 1))
		position = ir.binary(function, .Sub, last, current)
	}
	lane := lower_soa_reference_lane(state, node, plan, address, element, position, int(core.count))
	if state.failed || function.error != nil { return }
	lower_range_iteration(state, parts, lower_load(state, lane, core.elem), lane, position)
	if state.failed || function.error != nil { return }
	ir.jump_to(state.builder, continuation)
	if ir.seal_target(state.builder, continuation) {
		next := ir.binary(function, .Add, ir.variable_get(state.builder, counter), ir.const_int(function, .I64, 1))
		ir.variable_set(state.builder, counter, next)
	}
	ir.loop_end(state.builder, loop)
	ir.seal_target(state.builder, end)
}

// One lane of a scattered element at a runtime position: the same select
// chain over the spread components that lower_soa_component_base builds for
// a runtime field operand, but driven by the loop counter directly.
@(private)
lower_soa_reference_lane :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	plan: check.Soa_Plan,
	address, element, position: ir.Node_Id,
	spread: int,
) -> ir.Node_Id {
	function := state.job.function
	base := lower_soa_component_ptr(state, node, plan.soa, address, element, 0)
	if state.failed || function.error != nil { return 0 }
	for candidate in 1 ..< spread {
		other := lower_soa_component_ptr(state, node, plan.soa, address, element, candidate)
		if state.failed || function.error != nil { return 0 }
		selected := ir.compare(function, .Eq, position, ir.const_int(function, .I64, i64(candidate)))
		base = ir.select(function, selected, other, base)
	}
	return base
}
