package lower

import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

// `for value, index in EnumType` visits the members in declaration order, the index being the member's position.
@(private)
lower_range_enum :: proc(state: ^Procedure_State, node: syntax.Node_Index, parts: Range_Parts) {
	scope := local_scope(state)
	defer leave_local_scope(state, scope)
	lower_statement(state, parts.init)
	if state.failed || state.job.function.error != nil || state.builder.control == 0 { return }
	function := state.job.function
	store := check.type_store(state.job.program)
	enum_type := types.resolve_named(store, lower_info(state, parts.expr).type)
	members, found := range_enum_members(state, enum_type)
	if !found {
		lower_fail(state, node, .Range)
		return
	}
	value_type := scalar_type(state, enum_type)
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
	count := ir.const_int(function, .I64, i64(len(members)))
	branch := ir.branch_if(state.builder, ir.compare(function, .ULt, current, count))
	ir.enter_arm(state.builder, branch, 1)
	ir.jump_to(state.builder, end)
	ir.enter_arm(state.builder, branch, 0)
	value := range_enum_value(state, members, current, value_type)
	lower_range_iteration(state, parts, value, ir.NODE_NONE, current)
	if state.failed || function.error != nil { return }
	ir.jump_to(state.builder, continuation)
	if ir.seal_target(state.builder, continuation) {
		next := ir.binary(function, .Add, ir.variable_get(state.builder, counter), ir.const_int(function, .I64, 1))
		ir.variable_set(state.builder, counter, next)
	}
	ir.loop_end(state.builder, loop)
	ir.seal_target(state.builder, end)
}

// The members come from the runtime enum table, which the checker fills for every enum it iterates.
@(private)
range_enum_members :: proc(state: ^Procedure_State, enum_type: types.Type_Id) -> (members: []check.Enum_Member, found: bool) {
	for entry in state.job.program.runtime.enum_members {
		if entry.type == enum_type { return entry.members, true }
	}
	return nil, false
}

// Selects the value of the member at `current` with a chain of comparisons against each position.
@(private)
range_enum_value :: proc(state: ^Procedure_State, members: []check.Enum_Member, current: ir.Node_Id, value_type: ir.Value_Type) -> ir.Node_Id {
	function := state.job.function
	if len(members) == 0 { return ir.const_int(function, value_type, 0) }
	value := ir.const_int(function, value_type, members[0].value)
	for member, position in members[1:] {
		is_position := ir.compare(function, .Eq, current, ir.const_int(function, .I64, i64(position + 1)))
		value = ir.select(function, is_position, ir.const_int(function, value_type, member.value), value)
	}
	return value
}
