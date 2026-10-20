package lower

import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

// `for member in set` takes the lowest set bit each iteration, or the highest under `#reverse`, and clears it.
@(private)
lower_range_bit_set :: proc(state: ^Procedure_State, node: syntax.Node_Index, parts: Range_Parts) {
	scope := local_scope(state)
	defer leave_local_scope(state, scope)
	lower_statement(state, parts.init)
	if state.failed || state.job.function.error != nil || state.builder.control == 0 { return }
	function := state.job.function
	store := check.type_store(state.job.program)
	set_id := types.resolve_named(store, lower_info(state, parts.expr).type)
	set := types.get(store, set_id)
	mask := scalar_type(state, set_id)
	element := scalar_type(state, set.elem)
	if is_wide_integer(state, set_id) {
		lower_range_wide_bit_set(state, node, parts, set.elem, set.lower_bound)
		return
	}
	if mask == .None || element == .None {
		lower_fail(state, node, .Range)
		return
	}
	mask_bits := scalar_bits(mask)
	remaining := ir.variable_declare(state.builder, lower_value(state, parts.expr))
	variables, variables_ok := range_loop_variables(state, parts.body, remaining)
	if !variables_ok { return }
	end := ir.jump_target_make(state.builder)
	loop := ir.loop_begin(state.builder, variables)
	continuation := ir.jump_target_make(state.builder)
	if !push_control_target(
		state,
		{node = {state.job.procedure.body.file, node}, break_target = end, continue_target = continuation, is_loop = true},
	) { return }
	defer pop(&state.control_targets)
	current := ir.variable_get(state.builder, remaining)
	branch := ir.branch_if(state.builder, ir.compare(function, .Ne, current, ir.const_int(function, mask, 0)))
	ir.enter_arm(state.builder, branch, 1)
	ir.jump_to(state.builder, end)
	ir.enter_arm(state.builder, branch, 0)
	bit_position: ir.Node_Id
	if parts.reverse {
		from_top := ir.unary(function, .Clz, current)
		bit_position = ir.binary(function, .Sub, ir.const_int(function, mask, i64(mask_bits - 1)), from_top)
		bit := ir.binary(function, .Shl, ir.const_int(function, mask, 1), bit_position)
		ir.variable_set(state.builder, remaining, ir.binary(function, .Xor, current, bit))
	} else {
		bit_position = ir.unary(function, .Ctz, current)
		lower_bit := ir.binary(function, .Sub, current, ir.const_int(function, mask, 1))
		ir.variable_set(state.builder, remaining, ir.binary(function, .And, current, lower_bit))
	}
	if element_bits := scalar_bits(element); element_bits != mask_bits {
		resize := ir.Node_Kind.Trunc
		if element_bits > mask_bits { resize = .Zext }
		bit_position = ir.convert(function, resize, bit_position, element)
	}
	member := ir.binary(function, .Add, bit_position, ir.const_int(function, element, set.lower_bound))
	lower_range_iteration(state, parts, member, ir.NODE_NONE, ir.NODE_NONE)
	if state.failed || function.error != nil { return }
	ir.jump_to(state.builder, continuation)
	ir.seal_target(state.builder, continuation)
	ir.loop_end(state.builder, loop)
	ir.seal_target(state.builder, end)
}

// A wide set is walked by bit index 0..<128 (or downward under `#reverse`), with its two words in loop variables.
@(private)
lower_range_wide_bit_set :: proc(state: ^Procedure_State, node: syntax.Node_Index, parts: Range_Parts, element_type: types.Type_Id, lower_bound: i64) {
	function := state.job.function
	element := scalar_type(state, element_type)
	if element == .None {
		lower_fail(state, node, .Range)
		return
	}
	words := wide_load(state, lower_value(state, parts.expr))
	low := ir.variable_declare(state.builder, words.low)
	high := ir.variable_declare(state.builder, words.high)
	position := ir.variable_declare(state.builder, ir.const_int(function, .I64, 0))
	variables, variables_ok := range_loop_variables(state, parts.body, low, high, position)
	if !variables_ok { return }
	end := ir.jump_target_make(state.builder)
	loop := ir.loop_begin(state.builder, variables)
	continuation := ir.jump_target_make(state.builder)
	if !push_control_target(
		state,
		{node = {state.job.procedure.body.file, node}, break_target = end, continue_target = continuation, is_loop = true},
	) { return }
	defer pop(&state.control_targets)
	in_bounds := ir.branch_if(state.builder, ir.compare(function, .ULt, ir.variable_get(state.builder, position), ir.const_int(function, .I64, 128)))
	ir.enter_arm(state.builder, in_bounds, 1)
	ir.jump_to(state.builder, end)
	ir.enter_arm(state.builder, in_bounds, 0)
	current := Wide_Words {
		low  = ir.variable_get(state.builder, low),
		high = ir.variable_get(state.builder, high),
	}
	bit_index := ir.variable_get(state.builder, position)
	if parts.reverse { bit_index = ir.binary(function, .Sub, ir.const_int(function, .I64, 127), bit_index) }
	present := ir.branch_if(state.builder, wide_bit_test(function, current, bit_index))
	ir.enter_arm(state.builder, present, 0)
	member := bit_index
	if element != .I64 { member = ir.convert(function, .Trunc, member, element) }
	member = ir.binary(function, .Add, member, ir.const_int(function, element, lower_bound))
	lower_range_iteration(state, parts, member, ir.NODE_NONE, ir.NODE_NONE)
	if state.failed || function.error != nil { return }
	ir.jump_to(state.builder, continuation)
	ir.enter_arm(state.builder, present, 1)
	ir.jump_to(state.builder, continuation)
	if ir.seal_target(state.builder, continuation) {
		ir.variable_set(state.builder, position, ir.binary(function, .Add, ir.variable_get(state.builder, position), ir.const_int(function, .I64, 1)))
	}
	ir.loop_end(state.builder, loop)
	ir.seal_target(state.builder, end)
}

// `element in set` for a bit_set: the element's offset from the lower bound is tested in the set's words.
@(private)
lower_bit_set_membership :: proc(state: ^Procedure_State, node: syntax.Node_Index, expression: syntax.Binary_Expr, element, set: ir.Node_Id) -> ir.Node_Id {
	function := state.job.function
	store := check.type_store(state.job.program)
	set_type := types.resolve_named(store, lower_info(state, expression.right).type)
	descriptor := types.get(store, set_type)
	if descriptor.kind != .Bit_Set { return lower_fail(state, node, .Operator) }
	words: Wide_Words
	if is_wide_integer(state, set_type) {
		words = wide_load(state, set)
	} else {
		if scalar_type(state, set_type) == .None { return lower_fail(state, node, .Operator) }
		words = Wide_Words {
			low  = widen_to_word(state, set, set_type),
			high = ir.const_int(function, .I64, 0),
		}
	}
	element_type := lower_info(state, expression.left).type
	offset := ir.binary(function, .Sub, widen_to_word(state, element, element_type), ir.const_int(function, .I64, descriptor.lower_bound))
	in_range := ir.compare(function, .ULt, offset, ir.const_int(function, .I64, 128))
	return ir.binary(function, .And, in_range, wide_bit_test(function, words, offset))
}
