package lower

import "oc:ir"
import "oc:syntax"

// A slice, or any dynamic array under `#unroll(N)`, snapshots its data pointer and length; other
// dynamic and fixed-capacity arrays read their data and length on every iteration. `#reverse` counts
// the position down from the last element.
@(private)
lower_range_container :: proc(state: ^Procedure_State, node: syntax.Node_Index, parts: Range_Parts) {
	scope := local_scope(state)
	defer leave_local_scope(state, scope)
	lower_statement(state, parts.init)
	if state.failed || state.job.function.error != nil || state.builder.control == 0 { return }
	function := state.job.function
	container := lower_type(state, lower_info(state, parts.expr).type)
	kind := container.kind
	element_type := container.elem
	array_count := container.count
	element_size := state.job.layouts[element_type].size
	if kind != .Array && kind != .Enumerated_Array && kind != .Slice && kind != .Dynamic_Array && kind != .Fixed_Capacity_Array {
		lower_fail(state, node, .Range)
		return
	}
	is_array := kind == .Array || kind == .Enumerated_Array
	snapshot := kind == .Slice || (kind == .Dynamic_Array && parts.snapshot)
	base_variable, count_variable, header_variable: ir.Variable
	if is_array {
		base_variable = ir.variable_declare(state.builder, lower_array_base(state, parts.expr))
	} else if snapshot {
		header := lower_value(state, parts.expr)
		base := lower_load_word(state, header, .Ptr)
		count := lower_load_word(state, ir.ptr_offset(function, header, 8), .I64)
		if state.failed || function.error != nil { return }
		base_variable = ir.variable_declare(state.builder, base)
		count_variable = ir.variable_declare(state.builder, count)
	} else {
		header_variable = ir.variable_declare(state.builder, lower_value(state, parts.expr))
	}
	if state.failed || function.error != nil { return }
	length_offset := (element_size * array_count + 7) / 8 * 8
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
	base, count: ir.Node_Id
	if is_array {
		base = ir.variable_get(state.builder, base_variable)
		count = ir.const_int(function, .I64, array_count)
	} else if snapshot {
		base = ir.variable_get(state.builder, base_variable)
		count = ir.variable_get(state.builder, count_variable)
	} else {
		header := ir.variable_get(state.builder, header_variable)
		if kind == .Dynamic_Array {
			base = lower_load_word(state, header, .Ptr)
			count = lower_load_word(state, ir.ptr_offset(function, header, 8), .I64)
		} else {
			base = header
			count = lower_load_word(state, ir.ptr_offset(function, header, length_offset), .I64)
		}
	}
	if state.failed || function.error != nil { return }
	branch := ir.branch_if(state.builder, ir.compare(function, .ULt, current, count))
	ir.enter_arm(state.builder, branch, 1)
	ir.jump_to(state.builder, end)
	ir.enter_arm(state.builder, branch, 0)
	position := current
	if parts.reverse {
		last := ir.binary(function, .Sub, count, ir.const_int(function, .I64, 1))
		position = ir.binary(function, .Sub, last, current)
	}
	index := position
	if kind == .Enumerated_Array {
		index_type := scalar_type(state, container.index)
		if index_type != .I64 { index = ir.convert(function, .Trunc, position, index_type) }
	}
	address := ir.ptr_index(function, base, position, u32(element_size))
	lower_range_iteration(state, parts, lower_load(state, address, element_type), address, index)
	if state.failed || function.error != nil { return }
	ir.jump_to(state.builder, continuation)
	if ir.seal_target(state.builder, continuation) {
		next := ir.binary(function, .Add, ir.variable_get(state.builder, counter), ir.const_int(function, .I64, 1))
		ir.variable_set(state.builder, counter, next)
	}
	ir.loop_end(state.builder, loop)
	ir.seal_target(state.builder, end)
}
