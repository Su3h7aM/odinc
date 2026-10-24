package lower

import "core:mem/virtual"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

// Mirrors the official lb_build_range_string: forward loops decode `str[offset:]` and advance offset after
// the index is taken; `#reverse` decodes `str[:offset]` from the end and moves offset to the rune's start first.
@(private)
lower_range_string :: proc(state: ^Procedure_State, node: syntax.Node_Index, parts: Range_Parts, kind: types.Kind) {
	scope := local_scope(state)
	defer leave_local_scope(state, scope)
	lower_statement(state, parts.init)
	if state.failed || state.job.function.error != nil || state.builder.control == 0 { return }
	function := state.job.function
	unit := i64(2) if kind == .String16 else i64(1)
	header := lower_value(state, parts.expr)
	if state.failed || function.error != nil { return }
	data_variable := ir.variable_declare(state.builder, lower_load_word(state, header, .Ptr))
	length_variable := ir.variable_declare(state.builder, lower_load_word(state, ir.ptr_offset(function, header, 8), .I64))
	offset_variable := ir.variable_declare(state.builder, ir.const_int(function, .I64, 0))
	if parts.reverse { ir.variable_set(state.builder, offset_variable, ir.variable_get(state.builder, length_variable)) }
	variables, variables_ok := range_loop_variables(state, parts.body, offset_variable)
	if !variables_ok { return }
	end := ir.jump_target_make(state.builder)
	loop := ir.loop_begin(state.builder, variables)
	continuation := ir.jump_target_make(state.builder)
	if !push_control_target(
		state,
		{node = {state.job.procedure.body.file, node}, break_target = end, continue_target = continuation, is_loop = true},
	) { return }
	defer pop(&state.control_targets)
	offset := ir.variable_get(state.builder, offset_variable)
	length := ir.variable_get(state.builder, length_variable)
	zero := ir.const_int(function, .I64, 0)
	condition := ir.compare(function, .ULt, zero, offset) if parts.reverse else ir.compare(function, .ULt, offset, length)
	branch := ir.branch_if(state.builder, condition)
	ir.enter_arm(state.builder, branch, 1)
	ir.jump_to(state.builder, end)
	ir.enter_arm(state.builder, branch, 0)
	data := ir.variable_get(state.builder, data_variable)
	name := range_decode_name(kind, parts.reverse)
	value, width: ir.Node_Id
	index: ir.Node_Id
	if parts.reverse {
		value, width = lower_range_decode(state, node, name, data, offset)
		if state.failed || function.error != nil { return }
		next := ir.binary(function, .Sub, offset, width)
		ir.variable_set(state.builder, offset_variable, next)
		index = next
	} else {
		value, width = lower_range_decode(state, node, name, ir.ptr_index(function, data, offset, u32(unit)), ir.binary(function, .Sub, length, offset))
		if state.failed || function.error != nil { return }
		ir.variable_set(state.builder, offset_variable, ir.binary(function, .Add, offset, width))
		index = offset
	}
	lower_range_iteration(state, parts, value, ir.NODE_NONE, index)
	if state.failed || function.error != nil { return }
	ir.jump_to(state.builder, continuation)
	ir.seal_target(state.builder, continuation)
	ir.loop_end(state.builder, loop)
	ir.seal_target(state.builder, end)
}

@(private = "file")
range_decode_name :: proc(kind: types.Kind, reverse: bool) -> check.Runtime_Helper {
	if kind == .String16 {
		return .String16_Decode_Last_Rune if reverse else .String16_Decode_Rune
	}
	return .String_Decode_Last_Rune if reverse else .String_Decode_Rune
}

// Calls a runtime decode procedure with the string passed as its data pointer and length. The rune comes back
// through a stack slot, because the procedure splits its results; the width is the final result.
@(private = "file")
lower_range_decode :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	kind: check.Runtime_Helper,
	data, length: ir.Node_Id,
) -> (
	value, width: ir.Node_Id,
) {
	function := state.job.function
	program := state.job.program
	helper := program.runtime.helpers[kind]
	if helper == 0 || checked_procedure_symbol(program, helper) == 0 {
		lower_fail(state, node, .Range)
		return 0, 0
	}
	store := check.type_store(program)
	allocator := virtual.arena_allocator(&function.arena)
	signature := types.resolve_named(store, program.entities[helper].type)
	plan, plan_error := types.plan_abi(store, signature, allocator = allocator)
	if plan_error != .None {
		lower_fail(state, node, .Range)
		return 0, 0
	}
	abi, abi_error := abi_signature(plan, allocator)
	if abi_error != nil {
		function.error = abi_error
		return 0, 0
	}
	if len(abi.params) != 3 || len(abi.results) != 1 {
		lower_fail(state, node, .Call_Argument)
		return 0, 0
	}
	rune_slot := ir.stack_slot(function, state.entry_control, 4, 4)
	arguments, arguments_error := make([]ir.Node_Id, 3, allocator)
	if arguments_error != nil {
		function.error = arguments_error
		return 0, 0
	}
	arguments[0], arguments[1], arguments[2] = data, length, rune_slot
	callee := ir.symbol_addr(function, state.job.symbols[program.entity_symbols[helper]])
	id := ir.add_signature(function, abi)
	call := ir.call(function, state.builder.control, ir.variable_get(state.builder, ir.MEMORY_VARIABLE), callee, id, arguments)
	memory := ir.add_node(function, .Proj, .Memory, {call}, {index = 0})
	ir.variable_set(state.builder, ir.MEMORY_VARIABLE, memory)
	width = ir.add_node(function, .Proj, abi.results[0].type, {call}, {index = 1})
	value = lower_load_word(state, rune_slot, .I32)
	return value, width
}
